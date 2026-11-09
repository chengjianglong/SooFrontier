// A never-ending roundtable between agents on local models. No framework: one loop, and each agent is a persona
// with its own model and its own private memory. Ollama is stateless, so "its own context" means every prompt is
// built from that agent's persona, its own notes and the recent turns, kept small enough for a short context window.
import { EventEmitter } from 'node:events';
import { readFileSync } from 'node:fs';
import { PANELISTS } from '../public/shared.js';
import { makeLocalClient } from './llm.mjs';
import { cleanReply } from './prompts.mjs';

// Order, sizes and thresholds live in public/live-config.json, not here.
const CONFIG = JSON.parse(readFileSync(new URL('../public/live-config.json', import.meta.url), 'utf8'));
const ORDER = CONFIG.order;
const T = CONFIG.tuning;
const PRESETS = CONFIG.presets; // length, pace and memory choices, each with its values


const sleep = (ms, signal) => new Promise((resolve) => {
  const t = setTimeout(resolve, ms);
  signal?.addEventListener('abort', () => { clearTimeout(t); resolve(); }, { once: true });
});

const grams = (s) => {
  const w = s.toLowerCase().replace(/[^a-z0-9\s]/g, ' ').split(/\s+/).filter(Boolean);
  return new Set(w.slice(0, -2).map((_, i) => `${w[i]} ${w[i + 1]} ${w[i + 2]}`));
};
/** Share of 3-word phrases two texts have in common; high means one is repeating the other. */
export function overlap(a, b) {
  const x = grams(a), y = grams(b);
  if (!x.size || !y.size) return 0;
  let shared = 0;
  for (const g of x) if (y.has(g)) shared++;
  return shared / Math.min(x.size, y.size);
}

export class AgentRoom extends EventEmitter {
  #config; #persist; #ctl = null; #gen = 0; #override = null;
  id = null; topic = ''; status = 'idle'; speaking = null; error = null; turns = []; agents = {}; cursor = 0; stale = false; draft = null; options = { ...CONFIG.defaults };

  /**
   * config() → { url, installed, main } or throws; persist(state) saves; saved is the last saved state.
   * The room owns each agent's model and characteristic: configure() is the one way to change them.
   */
  constructor({ config, persist, saved }) {
    super();
    this.#config = config;
    this.#persist = persist;
    this.agents = this.#blank();
    if (saved) for (const id of ORDER) Object.assign(this.agents[id], saved.agents?.[id]);
    for (const key of Object.keys(PRESETS)) if (PRESETS[key][saved?.options?.[key]]) this.options[key] = saved.options[key];
    if (saved?.topic) {
      Object.assign(this, { id: saved.id, topic: saved.topic, turns: saved.turns ?? [], cursor: saved.cursor ?? 0 });
      this.status = saved.status === 'idle' ? 'idle' : 'paused'; // a restart never resumes on its own
    }
  }

  /** Fresh notes for every agent; model and viewpoint null mean "the main model" and "the persona's default". */
  #blank(keep = {}) {
    return Object.fromEntries(ORDER.map((id) => [id, { memory: '', upTo: 0, spoke: 0, model: keep[id]?.model ?? null, viewpoint: keep[id]?.viewpoint ?? null }]));
  }

  snapshot(last = 300) {
    let cfg = { installed: [], main: null };
    try { cfg = this.#config(); } catch {}
    return {
      id: this.id, topic: this.topic, status: this.status, speaking: this.speaking, error: this.error, total: this.turns.length, draft: this.draft,
      turns: last ? this.turns.slice(-last) : [], // slice(-0) would return everything
      installed: cfg.installed, main: cfg.main, options: this.options,
      agents: ORDER.map((id) => {
        const a = this.agents[id], seat = PANELISTS.find((p) => p.id === id);
        return { id, name: seat.name, model: this.#modelOf(a, cfg), customModel: Boolean(a.model), viewpoint: a.viewpoint ?? seat.viewpoint, custom: Boolean(a.viewpoint),
          defaultViewpoint: seat.viewpoint, memory: a.memory, turns: a.spoke };
      }),
    };
  }

  #modelOf(a, cfg) { return a.model && cfg.installed.includes(a.model) ? a.model : cfg.main; }

  #emit(kind, data = {}) { this.emit('change', { kind, ...data }); }
  #save() {
    this.#persist({ id: this.id, topic: this.topic, status: this.status, cursor: this.cursor, agents: this.agents, options: this.options, turns: this.turns.slice(-T.maxKeptTurns) });
  }

  start(topic) {
    topic = String(topic ?? '').trim().slice(0, T.topicMaxChars);
    if (!topic) throw new Error('Type a topic first.');
    this.#config(); // fail now, with a clear message, if the local server isn't ready
    this.#ctl?.abort();
    Object.assign(this, { id: Date.now().toString(36), topic, turns: [], cursor: 0, stale: false, error: null, speaking: null, status: 'running',
      agents: this.#blank(this.agents) }); // a new topic starts with clean notes but keeps each agent's model and characteristic
    this.#save();
    this.#emit('reset');
    this.#run();
  }

  pause() { if (this.status !== 'running') return; this.status = 'paused'; this.#ctl?.abort(); this.#save(); this.#emit('state'); }

  resume() {
    if (this.status !== 'paused' && this.status !== 'error') return;
    this.#config();
    this.status = 'running'; this.error = null;
    this.#save(); this.#emit('state'); this.#run();
  }

  stop() { if (!this.topic) return; this.status = 'stopped'; this.speaking = null; this.#ctl?.abort(); this.#save(); this.#emit('state'); }

  /** The human joins in; the next agent to speak answers them first. */
  say(text) {
    text = String(text ?? '').trim().slice(0, T.sayMaxChars);
    if (!text || !this.topic) return;
    this.#add({ speaker: 'human', text });
  }

  /** Changes one agent's model and/or characteristic; it takes effect on that agent's next turn, which comes up next. */
  configure(id, { model, viewpoint } = {}) {
    const a = this.agents[id], seat = PANELISTS.find((p) => p.id === id);
    if (!a || !seat) throw new Error('Unknown agent');
    let cfg = { installed: [], main: null };
    try { cfg = this.#config(); } catch {}
    const notes = [];
    if (model !== undefined) {
      const next = model && model !== cfg.main ? String(model) : null; // null means the main model
      if (next && cfg.installed.length && !cfg.installed.includes(next)) throw new Error(`${next} isn't on the model server.`);
      if (next !== a.model) { a.model = next; notes.push(`now speaks with ${next ?? cfg.main ?? 'the main model'}`); }
    }
    if (viewpoint !== undefined) {
      const v = String(viewpoint).trim().slice(0, 600);
      const next = v && v !== seat.viewpoint ? v : null; // null means the persona's default
      if (next !== a.viewpoint) {
        a.viewpoint = next;
        // Old notes were written in the old character and would pull it back, so start them again from here.
        a.memory = ''; a.upTo = this.turns.at(-1)?.n ?? 0;
        notes.push(next ? `has a new characteristic: ${next.length > 140 ? `${next.slice(0, 140)}…` : next}` : 'is back to the default characteristic');
      }
    }
    if (!notes.length) return;
    if (this.status === 'running') this.#override = id;
    if (this.topic) this.#add({ speaker: 'system', text: `${seat.name} ${notes.join(' and ')}.` });
    else this.#save();
    this.#emit('state');
  }

  /** Reply length, pace and memory for the whole room; each takes effect on the next turn. */
  setOptions(patch = {}) {
    for (const key of Object.keys(PRESETS)) {
      if (patch[key] === undefined) continue;
      if (!PRESETS[key][patch[key]]) throw new Error(`Unknown ${key} setting: ${patch[key]}`);
      this.options[key] = patch[key];
    }
    this.#save();
    this.#emit('state');
  }

  #length() { return PRESETS.length[this.options.length]; }
  #memoryTurns() { return PRESETS.memory[this.options.memory].turns; }

  #add(turn) {
    const t = { n: (this.turns.at(-1)?.n ?? 0) + 1, at: new Date().toISOString(), ...turn };
    this.turns.push(t);
    if (turn.speaker !== 'system') this.draft = null; // a note must not cut off a reply that is still streaming
    this.#save();
    this.#emit('turn', { turn: t });
    return t;
  }

  // MARK: The loop

  async #run() {
    // Each run has a token, so a loop that was paused or replaced exits without touching the new one's state.
    const token = ++this.#gen;
    this.#ctl?.abort();
    let fails = 0;
    const ctl = this.#ctl = new AbortController();
    try {
      while (this.status === 'running' && !ctl.signal.aborted && token === this.#gen) {
        if (this.#override) { this.cursor = ORDER.indexOf(this.#override); this.#override = null; }
        const seat = PANELISTS.find((p) => p.id === ORDER[this.cursor % ORDER.length]);
        this.speaking = seat.id; this.#emit('state');
        try {
          const { text, model } = await this.#speak(seat, ctl.signal);
          if (ctl.signal.aborted) break;
          fails = 0; this.error = null;
          if (seat.id === 'synthesizer') this.stale = false;
          this.agents[seat.id].spoke++;
          this.cursor++;
          this.#add({ speaker: seat.id, text, model });
          await sleep(PRESETS.pace[this.options.pace].delayMs, ctl.signal);
        } catch (e) {
          this.draft = null;
          if (ctl.signal.aborted || this.status !== 'running') break;
          this.error = e.message; this.#emit('state');
          if (++fails >= T.maxFailures) { this.status = 'error'; this.#save(); break; }
          await sleep(T.retryDelayMs * fails, ctl.signal);
        }
      }
    } finally {
      if (token === this.#gen) { this.speaking = null; this.draft = null; this.#emit('state'); }
    }
  }

  #viewpoint(seat) { return this.agents[seat.id].viewpoint ?? seat.viewpoint; }

  #client(seat) {
    const cfg = this.#config();
    return makeLocalClient({ url: cfg.url, model: this.#modelOf(this.agents[seat.id], cfg) });
  }

  /** Who a turn is from, for the transcript an agent reads. */
  #who(t) { return t.speaker === 'human' ? 'Human' : t.speaker === 'system' ? 'Note' : PANELISTS.find((p) => p.id === t.speaker).name; }

  #window() {
    const lines = this.turns.slice(-this.#memoryTurns()).map((t) => `${this.#who(t)}: ${t.text}`);
    let out = lines.join('\n\n');
    if (out.length > T.windowChars) out = '…' + out.slice(-T.windowChars);
    return out;
  }

  /** The agent rewrites its own private notes, on its own model, from what it has heard since last time. */
  async #updateNotes(seat, llm, signal) {
    const a = this.agents[seat.id];
    const heard = this.turns.filter((t) => t.n > a.upTo);
    if (heard.length < T.notesEvery) return;
    const body = heard.map((t) => `${this.#who(t)}: ${t.text}`).join('\n\n').slice(-T.windowChars);
    const text = await llm.complete({
      system: `You keep private notes for ${seat.name}, a member of a roundtable discussing "${this.topic}". ${this.#viewpoint(seat)}`,
      prompt: `${a.memory ? `Your notes so far:\n${a.memory}\n\n` : ''}What was said since:\n${body}\n\nRewrite your notes in at most 120 words, in first person: your current stance, points you have conceded, open questions you want answered, and arguments already made that you must not repeat.`,
      maxTokens: T.notesMaxTokens, signal,
    });
    if (text.trim()) a.memory = text.trim().slice(0, T.notesMaxChars);
    a.upTo = this.turns.at(-1)?.n ?? a.upTo;
  }

  async #speak(seat, signal) {
    const llm = this.#client(seat);
    await this.#updateNotes(seat, llm, signal);
    const others = PANELISTS.filter((p) => p.id !== seat.id).map((p) => p.name).join(', ');
    const humanSpoke = this.turns.slice(-this.#memoryTurns()).some((t) => t.speaker === 'human');
    const role = seat.id === 'synthesizer'
      ? `You moderate: name the real disagreement in a sentence, then push the group to a sharper question or a decision.${this.stale ? ' The discussion has started repeating itself, so open a genuinely new angle or sub-question.' : ''}`
      : 'Move the argument forward with a point nobody has made yet.';
    const system = `You are ${seat.name} in a never-ending roundtable with ${others} on the topic: "${this.topic}". ${this.#viewpoint(seat)}
Speak in first person as ${seat.name}, in ${this.#length().words[0]} to ${this.#length().words[1]} words of plain prose: no headings, no bullet lists, no name prefix. Respond to something specific another member or the human just said. ${role} Never repeat what has been said. Disagree when you really do, and concede when convinced.${humanSpoke ? ' The human has spoken: answer them directly before anything else.' : ''}`;
    const a = this.agents[seat.id];
    const prompt = `${a.memory ? `Your private notes:\n${a.memory}\n\n` : ''}${this.turns.length ? `Recent discussion:\n${this.#window()}` : `The topic is: ${this.topic}\nYou open the discussion.`}\n\nIt is your turn, ${seat.name}.`;

    // Tokens stream out to every viewer as they arrive; the finished reply becomes a turn.
    const say = async (sys) => {
      this.draft = { speaker: seat.id, text: '', model: llm.model };
      const out = await llm.stream({ system: sys, prompt, maxTokens: this.#length().maxTokens, signal, onDelta: (partial) => {
        if (this.draft) this.draft.text = cleanReply(partial, seat.name);
        this.#emit('delta', { speaker: seat.id, text: cleanReply(partial, seat.name), model: llm.model });
      } });
      return cleanReply(out, seat.name);
    };
    let text = await say(system);
    const recent = this.turns.slice(-T.overlapLookback).map((t) => t.text);
    if (recent.some((r) => overlap(text, r) > T.overlapThreshold)) {
      // Repeating someone: ask once more, and if it still does, have the moderator change the subject next time.
      text = await say(`${system}\nYour last attempt repeated points already made. Say something new.`);
      if (recent.some((r) => overlap(text, r) > T.overlapThreshold)) this.stale = true;
    }
    return { text, model: llm.model };
  }
}
