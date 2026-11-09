// App state + the orchestrator that dispatches the agent crew. Ported from Store/FrontierStore.swift and DailyRefresh.swift.
import { EventEmitter } from 'node:events';
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { AGENTS, CATEGORIES, COUNCIL_DEFAULT_MODELS, COUNCIL_MAX_ROUNDS, COUNCIL_SEATS, PANELISTS, PROVIDERS, SECTIONS, parseVerdict, providerInfo, tallyVerdicts, VOICE_STARTERS, assess, futureWork, itemsIn, keyPoints, parseQuickRead, quickTLDR, topSignals } from '../public/shared.js';
import { HARVESTERS } from './harvest.mjs';
import { LOCAL, cliPath, localModels, makeClient, makeLocalClient, withFallback } from './llm.mjs';
import { arxivID, keyFigures, readPaper } from './net.mjs';
import { AgentRoom } from './agentroom.mjs';
import * as P from './prompts.mjs';

const DATA_DIR = process.env.SOOFRONTIER_DATA ?? join(homedir(), '.soofrontier-web');
const PROVIDER_IDS = Object.keys(PROVIDERS);

function loadJSON(name, fallback) {
  try { return JSON.parse(readFileSync(join(DATA_DIR, name), 'utf8')); } catch { return fallback; }
}

function saveJSON(name, value) {
  mkdirSync(DATA_DIR, { recursive: true, mode: 0o700 });
  const path = join(DATA_DIR, name);
  // API keys live in settings.json, so only this user may read it.
  writeFileSync(`${path}.tmp`, JSON.stringify(value), { mode: 0o600 });
  renameSync(`${path}.tmp`, path);
}

// MARK: Daily schedule

const PACIFIC = 'America/Los_Angeles';
const HOUR = 6;

function pacificParts(date) {
  const parts = new Intl.DateTimeFormat('en-US', { timeZone: PACIFIC, hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', second: 'numeric' }).formatToParts(date);
  const get = (t) => Number(parts.find((p) => p.type === t).value);
  return { y: get('year'), m: get('month'), d: get('day'), h: get('hour'), min: get('minute'), s: get('second') };
}

/** 6:00 am Pacific on the given Pacific calendar day (handles daylight saving through the formatter). */
function sixAmPacific(y, m, d) {
  let guess = Date.UTC(y, m - 1, d, HOUR);
  for (let i = 0; i < 2; i++) {
    const p = pacificParts(new Date(guess));
    guess -= Date.UTC(p.y, p.m - 1, p.d, p.h, p.min, p.s) - Date.UTC(y, m - 1, d, HOUR);
  }
  return guess;
}

/** The most recent 6:00 am Pacific at or before `now`. */
export function lastRun(now = Date.now()) {
  const p = pacificParts(new Date(now));
  const today = sixAmPacific(p.y, p.m, p.d);
  if (today <= now) return today;
  const y = new Date(Date.UTC(p.y, p.m - 1, p.d - 1));
  return sixAmPacific(y.getUTCFullYear(), y.getUTCMonth() + 1, y.getUTCDate());
}

export function nextRun(now = Date.now()) {
  const p = pacificParts(new Date(lastRun(now)));
  const t = new Date(Date.UTC(p.y, p.m - 1, p.d + 1));
  return sixAmPacific(t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate());
}

// MARK: Store

export class FrontierStore extends EventEmitter {
  items = [];
  brief = null;
  lastRefresh = null;
  digests = {};
  quickReads = {};
  status = {};
  isRefreshing = false;
  digestsInProgress = new Set();
  #quickInFlight = new Map();
  /** Models on the local server, refreshed every minute; null when it can't be reached. */
  localInstalled = null;
  #papers = new Map();

  constructor() {
    super();
    const s = loadJSON('settings.json', {});
    this.settings = {
      keys: s.keys ?? {}, models: s.models ?? {}, modes: s.modes ?? {}, cliModels: s.cliModels ?? {},
      synthesizerProvider: s.synthesizerProvider ?? 'anthropic', skepticProvider: s.skepticProvider ?? 'openai',
      agentsOff: s.agentsOff ?? [], saved: s.saved ?? [], voices: s.voices ?? VOICE_STARTERS,
      local: { url: LOCAL.defaultURL, model: LOCAL.defaultModel, fastModel: LOCAL.defaultFastModel, prefer: false, ...s.local,
        councilModels: { ...COUNCIL_DEFAULT_MODELS, ...s.local?.councilModels } },
    };
    const c = loadJSON('cache.json', {});
    this.items = c.items ?? [];
    this.brief = c.brief ?? null;
    this.lastRefresh = c.lastRefresh ?? null;
    this.digests = c.digests ?? {};
    this.quickReads = c.quickReads ?? {};
    this.live = new AgentRoom({ config: () => this.liveConfig(), persist: (state) => saveJSON('live-room.json', state), saved: loadJSON('live-room.json', null) });
  }

  /** What the live room needs from the local server. Each agent's own model and characteristic live in the room. */
  liveConfig() {
    const l = this.settings.local;
    const have = this.localInstalled;
    if (!l.url || !have) throw new Error(`Can't reach the local model server${l.url ? ` at ${l.url}` : ''}. Set it up in Settings → Local models.`);
    if (!have.includes(l.model)) throw new Error(`The main local model ${l.model} isn't on the server. Choose one in Settings → Local models.`);
    return { url: l.url, installed: have, main: l.model };
  }

  // MARK: Providers

  mode = (p) => this.settings.modes[p] ?? 'subscription';
  cliModel = (p) => this.settings.cliModels[p] ?? PROVIDERS[p].defaultCLIModel;
  model = (p) => this.settings.models[p] ?? PROVIDERS[p].defaultModel;

  client(p) {
    const mode = this.mode(p);
    const apiKey = this.settings.keys[p] ?? '';
    if (mode === 'subscription' ? !cliPath(PROVIDERS[p].cliName) : !apiKey) return null;
    return makeClient(p, { mode, apiKey, model: this.model(p), cliModel: this.cliModel(p) });
  }

  configuredProviders = () => PROVIDER_IDS.filter((p) => this.client(p));

  /** The local model server, when it's reachable and has the chosen model. */
  localClient({ fast = false } = {}) {
    const l = this.settings.local;
    if (!l.url || !this.localInstalled?.includes(l.model)) return null;
    const fastModel = this.localInstalled.includes(l.fastModel) ? l.fastModel : l.model;
    const c = makeLocalClient({ url: l.url, model: l.model, fastModel });
    return fast ? c.withModel() : c;
  }

  /** The local client for a council seat: its own model when that's downloaded, otherwise the main model. */
  seatClient(seatId) {
    const main = this.localClient();
    const own = this.settings.local.councilModels?.[seatId];
    if (!main || !own || own === main.model || !this.localInstalled?.includes(own)) return main;
    return makeLocalClient({ url: this.settings.local.url, model: own });
  }

  async refreshLocal() {
    const before = JSON.stringify(this.localInstalled);
    this.localInstalled = this.settings.local.url ? await localModels(this.settings.local.url) : null;
    if (JSON.stringify(this.localInstalled) !== before) this.#changed();
  }

  /**
   * Preferred provider for a role, falling back to any configured one. The local server answers first when
   * "Prefer local models" is on, and otherwise steps in when the provider can't be reached.
   * `fast` picks each side's quick model (Claude Haiku, the local fast model).
   */
  roleClient(preferred, { fast = false } = {}) {
    let remote = this.client(preferred) ?? this.configuredProviders().map((p) => this.client(p))[0] ?? null;
    if (fast && remote?.provider === 'anthropic') remote = remote.withModel('haiku', 'claude-haiku-5-5');
    const local = this.localClient({ fast });
    if (!remote || !local) return remote ?? local;
    return this.settings.local.prefer ? withFallback(local, remote) : withFallback(remote, local);
  }

  /** What the browser may see. API keys never leave the server. */
  snapshot() {
    const s = this.settings;
    return {
      items: this.items, brief: this.brief, lastRefresh: this.lastRefresh, digests: this.digests, quickReads: this.quickReads,
      status: this.status, isRefreshing: this.isRefreshing, digestsInProgress: [...this.digestsInProgress], nextRun: new Date(nextRun()).toISOString(),
      saved: s.saved, voices: s.voices, agentsOff: s.agentsOff, synthesizerProvider: s.synthesizerProvider, skepticProvider: s.skepticProvider,
      providers: Object.fromEntries(PROVIDER_IDS.map((p) => [p, {
        mode: this.mode(p), model: this.model(p), cliModel: this.cliModel(p), hasKey: Boolean(s.keys[p]),
        cliPath: cliPath(PROVIDERS[p].cliName), configured: Boolean(this.client(p)),
      }])),
      local: { ...s.local, installed: this.localInstalled ?? [], reachable: this.localInstalled !== null, configured: Boolean(this.localClient()) },
    };
  }

  #changed() { this.emit('changed'); }

  #setStatus(agent, state, label) {
    this.status[agent] = { state, label };
    this.emit('status', this.liveStatus());
  }

  liveStatus() {
    return { status: this.status, isRefreshing: this.isRefreshing, digestsInProgress: [...this.digestsInProgress] };
  }

  saveSettings() { saveJSON('settings.json', this.settings); this.#changed(); }

  saveCache() {
    saveJSON('cache.json', { items: this.items, brief: this.brief, lastRefresh: this.lastRefresh, digests: this.digests, quickReads: this.quickReads });
    this.#changed();
  }

  updateSettings(patch) {
    const s = this.settings;
    for (const p of PROVIDER_IDS) {
      const c = patch.providers?.[p];
      if (!c) continue;
      if (['subscription', 'apiKey'].includes(c.mode)) s.modes[p] = c.mode;
      if (typeof c.model === 'string' && c.model.trim()) s.models[p] = c.model.trim();
      if (typeof c.cliModel === 'string' && PROVIDERS[p].cliModels.includes(c.cliModel)) s.cliModels[p] = c.cliModel;
      if (typeof c.key === 'string') s.keys[p] = c.key.trim();
    }
    const l = patch.local;
    let localChanged = false;
    if (l && typeof l === 'object') {
      if (typeof l.url === 'string') { s.local.url = l.url.trim().replace(/\/+$/, ''); localChanged = true; }
      for (const k of ['model', 'fastModel']) if (typeof l[k] === 'string' && l[k].trim()) s.local[k] = l[k].trim();
      if (typeof l.prefer === 'boolean') s.local.prefer = l.prefer;
      if (l.councilModels && typeof l.councilModels === 'object') {
        for (const seat of COUNCIL_SEATS) {
          const m = l.councilModels[seat.id];
          if (m === '') delete s.local.councilModels[seat.id];
          else if (typeof m === 'string' && m.trim()) s.local.councilModels[seat.id] = m.trim();
        }
      }
    }
    if (localChanged) this.refreshLocal();
    if (PROVIDER_IDS.includes(patch.synthesizerProvider)) s.synthesizerProvider = patch.synthesizerProvider;
    if (PROVIDER_IDS.includes(patch.skepticProvider)) s.skepticProvider = patch.skepticProvider;
    if (Array.isArray(patch.agentsOff)) s.agentsOff = patch.agentsOff.filter((a) => AGENTS[a]);
    if (Array.isArray(patch.voices)) {
      s.voices = patch.voices.filter((v) => /^\w{1,15}$/.test(v?.handle ?? '') && typeof v.role === 'string').map((v) => ({ handle: v.handle, role: v.role }));
    }
    if (patch.resetVoices) s.voices = VOICE_STARTERS;
    this.saveSettings();
  }

  toggleSaved(id) {
    const saved = new Set(this.settings.saved);
    if (!saved.delete(id)) saved.add(id);
    this.settings.saved = [...saved];
    this.saveSettings();
  }

  item(id) { return this.items.find((i) => i.url === id); }

  // MARK: Orchestration

  isDue(now = Date.now()) {
    return (this.lastRefresh ? Date.parse(this.lastRefresh) : 0) < lastRun(now);
  }

  async refresh() {
    if (this.isRefreshing) return;
    this.isRefreshing = true;
    const off = new Set(this.settings.agentsOff);
    const crew = Object.keys(HARVESTERS).filter((k) => !off.has(k));
    for (const a of Object.keys(AGENTS)) this.status[a] = off.has(a) ? { state: 'idle', label: 'Standing by' } : { state: 'working', label: 'Briefed, heading out…' };
    this.emit('status', this.liveStatus());
    try {
      // Fan out: every harvester runs in parallel and reports progress back.
      const harvested = [];
      const pending = new Set(crew);
      await Promise.all(crew.map(async (kind) => {
        const lanes = AGENTS[kind].lanes;
        try {
          const found = await HARVESTERS[kind]((msg) => this.#setStatus(kind, 'working', msg), { voices: this.settings.voices, grok: this.client('xai') });
          this.#setStatus(kind, 'done', `Delivered ${found.length}`);
          harvested.push(...found);
        } catch (e) {
          this.#setStatus(kind, 'failed', e.message);
          // Keep what this agent found last time rather than emptying its lanes.
          harvested.push(...this.items.filter((i) => lanes.includes(i.category)));
        }
        pending.delete(kind);
        // Publish as each agent reports, keeping lanes still in flight from the last run.
        const waiting = this.items.filter((i) => [...pending].some((k) => AGENTS[k].lanes.includes(i.category)));
        this.#publish([...harvested, ...waiting]);
      }));
      this.#setStatus('skeptic', 'done', `Delivered ${this.items.length}`);
      this.lastRefresh = new Date().toISOString();
      this.saveCache();

      await this.synthesize();
      // Desk digests that were written before this harvest are now stale; rewrite them too.
      for (const section of Object.keys(SECTIONS)) {
        const d = this.digests[section];
        if (d && Date.parse(d.generatedAt) < Date.parse(this.lastRefresh)) await this.writeDigest(section).catch(() => {});
      }
    } finally {
      this.isRefreshing = false;
      this.emit('status', this.liveStatus());
    }
  }

  /** Skeptic pass: dedupe, assess, and keep saved items even if they fell off the feeds. */
  #publish(harvested) {
    this.#setStatus('skeptic', 'working', `Cross-examining ${harvested.length} claims…`);
    const saved = new Set(this.settings.saved);
    const seen = new Set();
    const merged = [];
    for (const item of [...harvested, ...this.items.filter((i) => saved.has(i.url))]) {
      const key = item.title.toLowerCase().replace(/[^\p{L}]/gu, '').slice(0, 60);
      if (seen.has(key) || seen.has(item.url)) continue;
      seen.add(key);
      seen.add(item.url);
      merged.push({ ...item, assessment: assess(item) });
    }
    if (merged.length) { this.items = merged; this.#changed(); }
  }

  #offline() {
    const tops = Object.keys(CATEGORIES).map((c) => itemsIn(this.items, c)[0]).filter(Boolean);
    return { text: P.offlineBrief(tops), generatedAt: new Date().toISOString(), byLLM: null };
  }

  async synthesize() {
    if (this.settings.agentsOff.includes('synthesizer') || !this.items.length) return;
    const llm = this.roleClient(this.settings.synthesizerProvider);
    if (!llm) {
      this.brief = this.#offline();
      this.#setStatus('synthesizer', 'done', 'Delivered 1');
      this.saveCache();
      return;
    }
    this.#setStatus('synthesizer', 'working', `Drafting the brief with ${providerInfo(llm.provider).family}…`);
    // Give the synthesizer a balanced slate: the top items from every lane.
    const slate = Object.keys(CATEGORIES).flatMap((c) => itemsIn(this.items, c).slice(0, 3));
    try {
      const text = await llm.complete({ system: P.SYNTHESIZER_SYSTEM, prompt: P.briefPrompt(slate, this.brief) });
      this.brief = { text, generatedAt: new Date().toISOString(), byLLM: llm.label };
      this.#setStatus('synthesizer', 'done', 'Delivered 1');
    } catch (e) {
      this.brief = this.#offline();
      this.#setStatus('synthesizer', 'failed', e.message);
    }
    this.saveCache();
  }

  /** Writes the desk-level digest for Research, Productions, or Opinions. */
  async writeDigest(section) {
    const llm = this.roleClient(this.settings.synthesizerProvider);
    if (!llm) throw new Error('Connect a model in Settings.');
    const slate = SECTIONS[section].lanes.flatMap((c) => itemsIn(this.items, c).slice(0, 6));
    if (!slate.length) throw new Error('Nothing to analyze yet. Dispatch the agents first.');
    this.digestsInProgress.add(section);
    this.emit('status', this.liveStatus());
    try {
      const text = await llm.complete({ system: P.digestSystem(section), prompt: `Items:\n\n${P.digestItems(slate)}` });
      this.digests[section] = { text, generatedAt: new Date().toISOString(), byLLM: llm.label };
      this.saveCache();
    } finally {
      this.digestsInProgress.delete(section);
      this.emit('status', this.liveStatus());
    }
  }

  // MARK: One story

  /** Reads the paper once per story and keeps the last few in memory. */
  paper(item) {
    if (!['papers', 'reports'].includes(item.category) && !arxivID(item.url)) return Promise.resolve(null);
    let p = this.#papers.get(item.url);
    if (!p) {
      p = readPaper(item);
      this.#papers.set(item.url, p);
      if (this.#papers.size > 40) this.#papers.delete(this.#papers.keys().next().value);
    }
    return p;
  }

  async paperSummary(item) {
    const paper = await this.paper(item);
    return {
      figures: keyFigures(paper?.figures ?? []),
      keyPoints: keyPoints(item.summary, paper?.text, quickTLDR(item)),
      futureWork: futureWork(paper?.text),
    };
  }

  /** The story's quick read, written by a fast model and cached per story. */
  quickRead(item) {
    if (this.quickReads[item.url]) return Promise.resolve(this.quickReads[item.url]);
    // Share one request per story (the page and the next-story prefetch may ask at the same time).
    let running = this.#quickInFlight.get(item.url);
    if (!running) {
      running = this.#writeQuickRead(item).finally(() => this.#quickInFlight.delete(item.url));
      this.#quickInFlight.set(item.url, running);
    }
    return running;
  }

  async #writeQuickRead(item) {
    // Prefer Claude Haiku (or the local fast model) for speed; otherwise whichever model writes analyses.
    const llm = this.roleClient(this.client('anthropic') ? 'anthropic' : this.settings.skepticProvider, { fast: true });
    if (!llm) return null;
    const paper = await this.paper(item);
    let prompt = P.itemPrompt(item);
    const points = keyPoints(item.summary, paper?.text, quickTLDR(item));
    if (points.length) prompt += `\n\nKey points:\n${points.map((k) => `- ${k}`).join('\n')}`;
    if (paper) {
      const captions = keyFigures(paper.figures, 4).map((f) => `- ${f.caption}`).join('\n');
      if (captions) prompt += `\n\nKey figures:\n${captions}`;
      prompt += `\n\nExcerpt:\n${paper.text.slice(0, 6000)}`;
    }
    try {
      const read = parseQuickRead(await llm.complete({ system: P.IDEAS_SYSTEM, prompt, maxTokens: 3000 }));
      if (read) { this.quickReads[item.url] = read; this.saveCache(); }
      return read;
    } catch { return null; }
  }

  /**
   * The Frontier Council, on the local models only (no plan or API cost). The members give opening statements,
   * then debate in rebuttal rounds, each speaking in turn and answering the others, until they all hold the same
   * verdict (after at least one rebuttal) or COUNCIL_MAX_ROUNDS is reached. The moderator then rules.
   * Events: {round}, {speaking}, {turn}, {outcome}, {ruling}.
   */
  async convene(item, onEvent, signal) {
    const llm = this.localClient();
    if (!llm) throw new Error('The Council runs on your local models. Set up Local models in Settings (and download the main model).');
    const turns = [];
    let outcome = null;
    for (let round = 1; round <= COUNCIL_MAX_ROUNDS; round++) {
      onEvent({ round });
      const before = [...turns];
      const thisRound = [];
      for (const seat of COUNCIL_SEATS) {
        if (signal?.aborted) throw new Error('Cancelled');
        onEvent({ speaking: { seat: seat.id, round } });
        // Opening statements are independent; in rebuttals each member hears everything said so far, this round included.
        const heard = round === 1 ? before : turns;
        const voice = this.seatClient(seat.id);
        let turn;
        try {
          const raw = await voice.complete({ system: P.councilSeatSystem(seat, round), prompt: P.councilTurnPrompt(item, heard), maxTokens: 1500, temperature: 0.8, signal });
          turn = { seat: seat.id, round, model: voice.model, ...parseVerdict(raw) };
          // No verdict line means no change of mind: keep the member's last verdict.
          if (!turn.verdict) {
            const last = turns.findLast((t) => t.seat === seat.id && t.verdict);
            if (last) Object.assign(turn, { verdict: last.verdict, kept: true });
          }
        } catch (e) {
          if (signal?.aborted) throw e;
          turn = { seat: seat.id, round, model: voice.model, text: e.message, verdict: null, failed: true };
        }
        turns.push(turn);
        thisRound.push(turn);
        onEvent({ turn });
      }
      const spoke = thisRound.filter((t) => !t.failed);
      if (!spoke.length) throw new Error(`No council member could answer: ${thisRound[0]?.text ?? 'unknown error'}`);
      outcome = { ...tallyVerdicts(spoke), rounds: round };
      if (outcome.agreed && round >= 2) break;
    }
    onEvent({ outcome });
    const ruling = await llm.complete({ system: P.MODERATOR_SYSTEM, prompt: P.moderatorPrompt(item, turns, outcome), maxTokens: 4000, signal });
    onEvent({ ruling, by: llm.label });
  }

  // MARK: Brainstorm

  #panelPrompts({ panelistId, members, messages, optional, summary, useFrontier }) {
    const panelist = PANELISTS.find((p) => p.id === panelistId);
    if (!panelist) throw new Error('Unknown panelist');
    return {
      panelist, maxTokens: summary ? 3000 : 800,
      system: P.panelSystem(panelist, members, { summary, frontier: useFrontier ? topSignals(this.items) : null }),
      prompt: P.panelPrompt(panelist, messages, { optional, summary }),
    };
  }

  #brainstormClient() {
    const llm = this.localClient();
    if (!llm) throw new Error('Brainstorm runs on your local models. Set up Local models in Settings (and download the main model).');
    return llm;
  }

  /**
   * One panelist's turn, always on the local main model (no plan or API cost, and no fallback to a provider).
   * The browser owns the room and asks for one reply at a time.
   */
  async panelTurn(args, signal) {
    const { panelist, system, prompt, maxTokens } = this.#panelPrompts(args);
    const llm = this.#brainstormClient();
    const text = await llm.complete({ system, prompt, maxTokens, signal });
    return { text: P.cleanReply(text, panelist.name), by: llm.label };
  }

  /** The same turn, streamed token by token. */
  async panelTurnStream(args, onDelta, signal) {
    const { panelist, system, prompt, maxTokens } = this.#panelPrompts(args);
    const llm = this.#brainstormClient();
    const text = await llm.stream({ system, prompt, maxTokens, signal, onDelta: (t) => onDelta(P.cleanReply(t, panelist.name)) });
    return { text: P.cleanReply(text, panelist.name), by: llm.label };
  }

  async testProvider(p) {
    if (p === 'local') await this.refreshLocal();
    const llm = p === 'local' ? this.localClient() : this.client(p);
    const l = this.settings.local;
    if (!llm && p === 'local') throw new Error(this.localInstalled ? `${l.model} isn't on the server yet. Run “ollama pull ${l.model}” there.` : `Can't reach ${l.url || 'a local server'}.`);
    if (!llm) throw new Error('Not set up yet.');
    return llm.complete({ system: 'Reply with exactly: ready', prompt: 'Status check.', maxTokens: 300 });
  }

  /** Refreshes at 6:00 am Pacific, and on start or after sleep if that run was missed. */
  startSchedule() {
    // Tests set this so starting the server never goes out to the news feeds.
    if (process.env.SOOFRONTIER_NO_REFRESH) { this.refreshLocal(); return; }
    const check = () => { if (this.isDue()) this.refresh(); };
    this.refreshLocal().then(() => { if (!this.items.length) this.refresh(); else check(); });
    setInterval(() => this.refreshLocal(), 60_000).unref?.();
    setInterval(check, 60_000).unref?.();
  }
}

