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
  #config; #persist; #ctl = null; #gen = 0;
  id = null; topic = ''; status = 'idle'; speaking = null; error = null; turns = []; agents = {}; cursor = 0; stale = false; draft = null;

  /** config() → { url, models: {agentId: model} } or throws; persist(state) saves; saved is the last saved state. */
  constructor({ config, persist, saved }) {
    super();
    this.#config = config;
    this.#persist = persist;
    if (saved?.topic) {
      Object.assign(this, { id: saved.id, topic: saved.topic, turns: saved.turns ?? [], agents: saved.agents ?? {}, cursor: saved.cursor ?? 0 });
      this.status = saved.status === 'idle' ? 'idle' : 'paused'; // a restart never resumes on its own
    }
  }

  snapshot(last = 300) {
    let models = {};
    try { models = this.#config().models; } catch {}
    return {
      id: this.id, topic: this.topic, status: this.status, speaking: this.speaking, error: this.error, total: this.turns.length, draft: this.draft,
      turns: last ? this.turns.slice(-last) : [], // slice(-0) would return everything
      agents: ORDER.map((id) => ({ id, model: models[id] ?? null, memory: this.agents[id]?.memory ?? '', turns: this.agents[id]?.spoke ?? 0 })),
    };
  }

  #emit(kind, data = {}) { this.emit('change', { kind, ...data }); }
  #save() {
    this.#persist({ id: this.id, topic: this.topic, status: this.status, cursor: this.cursor, agents: this.agents, turns: this.turns.slice(-T.maxKeptTurns) });
  }

  start(topic) {
    topic = String(topic ?? '').trim().slice(0, T.topicMaxChars);
    if (!topic) throw new Error('Type a topic first.');
    this.#config(); // fail now, with a clear message, if the local server isn't ready
    this.#ctl?.abort();
    Object.assign(this, { id: Date.now().toString(36), topic, turns: [], cursor: 0, stale: false, error: null, speaking: null, status: 'running',
      agents: Object.fromEntries(ORDER.map((id) => [id, { memory: '', upTo: 0, spoke: 0 }])) });
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

  #add(turn) {
    const t = { n: (this.turns.at(-1)?.n ?? 0) + 1, at: new Date().toISOString(), ...turn };
    this.turns.push(t);
    this.draft = null;
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

  #client(seat) {
    const { url, models } = this.#config();
    return makeLocalClient({ url, model: models[seat.id] });
  }

  #window() {
    const lines = this.turns.slice(-T.windowTurns).map((t) => `${t.speaker === 'human' ? 'Human' : PANELISTS.find((p) => p.id === t.speaker).name}: ${t.text}`);
    let out = lines.join('\n\n');
    if (out.length > T.windowChars) out = '…' + out.slice(-T.windowChars);
    return out;
  }

  /** The agent rewrites its own private notes, on its own model, from what it has heard since last time. */
  async #updateNotes(seat, llm, signal) {
    const a = this.agents[seat.id];
    const heard = this.turns.filter((t) => t.n > a.upTo);
    if (heard.length < T.notesEvery) return;
    const body = heard.map((t) => `${t.speaker === 'human' ? 'Human' : PANELISTS.find((p) => p.id === t.speaker).name}: ${t.text}`).join('\n\n').slice(-T.windowChars);
    const text = await llm.complete({
      system: `You keep private notes for ${seat.name}, a member of a roundtable discussing "${this.topic}". ${seat.viewpoint}`,
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
    const humanSpoke = this.turns.slice(-T.windowTurns).some((t) => t.speaker === 'human');
    const role = seat.id === 'synthesizer'
      ? `You moderate: name the real disagreement in a sentence, then push the group to a sharper question or a decision.${this.stale ? ' The discussion has started repeating itself, so open a genuinely new angle or sub-question.' : ''}`
      : 'Move the argument forward with a point nobody has made yet.';
    const system = `You are ${seat.name} in a never-ending roundtable with ${others} on the topic: "${this.topic}". ${seat.viewpoint}
Speak in first person as ${seat.name}, in ${T.replyWords[0]} to ${T.replyWords[1]} words of plain prose: no headings, no bullet lists, no name prefix. Respond to something specific another member or the human just said. ${role} Never repeat what has been said. Disagree when you really do, and concede when convinced.${humanSpoke ? ' The human has spoken: answer them directly before anything else.' : ''}`;
    const a = this.agents[seat.id];
    const prompt = `${a.memory ? `Your private notes:\n${a.memory}\n\n` : ''}${this.turns.length ? `Recent discussion:\n${this.#window()}` : `The topic is: ${this.topic}\nYou open the discussion.`}\n\nIt is your turn, ${seat.name}.`;

    // Tokens stream out to every viewer as they arrive; the finished reply becomes a turn.
    const say = async (sys) => {
      this.draft = { speaker: seat.id, text: '', model: llm.model };
      const out = await llm.stream({ system: sys, prompt, maxTokens: T.replyMaxTokens, signal, onDelta: (partial) => {
        this.draft.text = cleanReply(partial, seat.name);
        this.#emit('delta', { speaker: seat.id, text: this.draft.text, model: llm.model });
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
