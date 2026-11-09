// The Brainstorm room: you and the agent panel, by text or by voice. Ported from Brainstorm/BrainstormRoom.swift and BrainstormVoice.swift.
import { PANELISTS, speakable, castVoices } from './shared.js';
import { api, inline, request, store } from './ui.js';

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** Speech recognition that sends after a pause, and a distinct spoken voice per panelist. */
class Voice {
  onHeard = () => {};
  onCommit = () => {};
  onError = () => {};
  onFinishedSpeaking = () => {};
  /** A panelist started or stopped speaking (the meeting's caption follows the voice). */
  onSpeakerChange = () => {};
  speakingPanelist = null;
  /** The message being spoken now, so the meeting's caption shows those words and not a later reply. */
  speakingRef = null;
  pause = 1800;
  #recognition = null;
  #silence = null;
  #text = '';
  #pending = 0;
  #run = 0;
  #word = '';
  #wordStarted = 0;
  #words = [];
  #started = 0;
  #sawBoundary = false;
  #mouth = { open: 0, wide: 0, round: 0, energy: 0 };
  #cast = null;

  static get recognitionClass() { return window.SpeechRecognition ?? window.webkitSpeechRecognition; }
  get isSpeaking() { return this.#pending > 0; }

  startListening() {
    const Recognition = Voice.recognitionClass;
    if (!Recognition) { this.onError("This browser can't do speech recognition. Use Chrome or Safari, or type instead."); return false; }
    this.stopSpeaking();
    const r = new Recognition();
    r.lang = 'en-US';
    r.continuous = true;
    r.interimResults = true;
    this.#text = '';
    this.#recognition = r;
    r.onresult = (e) => {
      this.#text = [...e.results].map((x) => x[0].transcript).join(' ').replace(/\s+/g, ' ').trim();
      this.onHeard(this.#text);
      clearTimeout(this.#silence);
      this.#silence = setTimeout(() => this.#commit(), this.pause);
    };
    r.onerror = (e) => {
      if (e.error === 'no-speech' || e.error === 'aborted') return;
      this.stopListening();
      this.onError(e.error === 'not-allowed' ? 'Brainstorm needs the microphone. Allow it for this site in your browser.' : `Speech recognition stopped (${e.error}).`);
    };
    // Recognition ends after silence or about a minute; keep listening.
    r.onend = () => { if (this.#recognition === r) { try { r.start(); } catch {} } };
    r.start();
    return true;
  }

  #commit() {
    const heard = this.#text.trim();
    if (!heard) return;
    this.stopListening();
    this.onCommit(heard);
  }

  stopListening() {
    clearTimeout(this.#silence);
    const r = this.#recognition;
    this.#recognition = null;
    r?.abort();
  }

  /** The voice, pitch and rate that fit this panelist's portrait (gender from the voice, age from pitch and pace). */
  #voiceFor(panelist) {
    if (!this.#cast) {
      const voices = speechSynthesis.getVoices();
      if (!voices.length) return null;
      this.#cast = castVoices(voices);
      // Some browsers load voices late or add more later: re-cast when the list changes.
      speechSynthesis.addEventListener?.('voiceschanged', () => { this.#cast = null; }, { once: true });
    }
    return this.#cast[panelist] ?? null;
  }

  speak(text, panelist, ref = null) {
    if (!('speechSynthesis' in window)) { queueMicrotask(() => this.onFinishedSpeaking()); return; }
    const u = new SpeechSynthesisUtterance(text);
    const cast = this.#voiceFor(panelist);
    if (cast?.voice) u.voice = cast.voice;
    u.pitch = cast?.pitch ?? 1;
    u.rate = cast?.rate ?? 1.05;
    this.#pending++;
    const run = this.#run;
    const words = text.split(/\s+/).filter(Boolean);
    u.onstart = () => {
      if (run !== this.#run) return;
      this.speakingPanelist = panelist;
      this.speakingRef = ref;
      this.#words = words;
      this.#started = performance.now();
      this.#sawBoundary = false;
      this.#word = words[0] ?? '';
      this.#wordStarted = this.#started;
      this.onSpeakerChange();
    };
    u.onboundary = (e) => {
      if (run !== this.#run || e.name !== 'word') return;
      this.#sawBoundary = true;
      this.#word = text.slice(e.charIndex).split(/\s/)[0];
      this.#wordStarted = performance.now();
    };
    const done = () => {
      if (run !== this.#run) return;
      this.#word = '';
      this.#words = [];
      this.speakingPanelist = null;
      this.speakingRef = null;
      this.#pending = Math.max(0, this.#pending - 1);
      this.onSpeakerChange();
      if (!this.#pending) this.onFinishedSpeaking();
    };
    u.onend = done;
    u.onerror = done;
    speechSynthesis.speak(u);
  }

  stopSpeaking() {
    this.#run++;
    this.#pending = 0;
    this.speakingPanelist = null;
    this.speakingRef = null;
    this.#word = '';
    this.#words = [];
    if ('speechSynthesis' in window) speechSynthesis.cancel();
  }

  /** Mouth shape for the current moment: vowels open the mouth, o/u round it, e/i widen it, and m/b/p close it. */
  mouth(dt) {
    let target = { open: 0, wide: 0, round: 0, energy: 0 };
    if (this.speakingPanelist) {
      const now = performance.now();
      // Some voices send no word events; step through the words at a typical speaking pace instead.
      if (!this.#sawBoundary && this.#words.length) {
        const i = Math.min(this.#words.length - 1, Math.floor((now - this.#started) / 340));
        if (this.#words[i] !== this.#word) { this.#word = this.#words[i]; this.#wordStarted = now; }
      }
      const letters = this.#word.toLowerCase().replace(/[^\p{L}]/gu, '');
      if (letters) {
        const c = letters[Math.floor((now - this.#wordStarted) / 1000 * 13) % letters.length];
        if (c === 'a') target = { open: 0.85, wide: 0.45, round: 0.1, energy: 0.9 };
        else if ('ouw'.includes(c)) target = { open: 0.6, wide: 0.1, round: 0.85, energy: 0.8 };
        else if ('eiy'.includes(c)) target = { open: 0.45, wide: 0.85, round: 0, energy: 0.7 };
        else if ('mbp'.includes(c)) target = { open: 0, wide: 0.2, round: 0, energy: 0.4 };
        else if ('fv'.includes(c)) target = { open: 0.15, wide: 0.4, round: 0, energy: 0.5 };
        else target = { open: 0.3, wide: 0.35, round: 0.15, energy: 0.6 };
      }
    }
    const ease = (cur, to, up, down) => cur + (to - cur) * Math.min(1, dt * (to > cur ? up : down));
    const m = this.#mouth;
    m.open = ease(m.open, target.open, 30, 16);
    m.wide = ease(m.wide, target.wide, 14, 8);
    m.round = ease(m.round, target.round, 14, 8);
    m.energy = ease(m.energy, target.energy, 20, 6);
    return m;
  }
}

export class Room {
  messages = [];
  phase = { kind: 'idle' }; // idle, listening, thinking(name), speaking(name)
  liveCaption = '';
  error = null;
  useFrontierContext = true;
  members = new Set(store.get('brainstorm.members', PANELISTS.map((p) => p.id)));
  handsFree = store.get('brainstorm.handsFree', false);
  speakReplies = store.get('brainstorm.speak', false);
  mode = store.get('brainstorm.mode2', 'live');
  draft = null;
  onChange = () => {};
  voice = new Voice();
  #turn = 0;
  #busy = false;
  #abort = null;
  #lastSpoke = {};
  #id = 0;

  constructor() {
    this.voice.onHeard = (t) => { this.liveCaption = t; this.onChange(); };
    this.voice.onCommit = (t) => this.send(t);
    this.voice.onError = (m) => { this.error = m; this.phase = { kind: 'idle' }; this.onChange(); };
    this.voice.onFinishedSpeaking = () => this.#panelDone();
    this.voice.onSpeakerChange = () => this.onChange();
  }

  get panel() { return PANELISTS.filter((p) => this.members.has(p.id)); }

  toggleMember(id) {
    if (!this.members.delete(id)) this.members.add(id);
    store.set('brainstorm.members', [...this.members]);
    this.onChange();
  }

  setOption(key, storageKey, value) {
    this[key] = value;
    if (storageKey) store.set(storageKey, value);
    this.onChange();
  }

  send(raw) {
    const text = raw.trim();
    if (!text) return;
    this.voice.stopListening();
    this.interrupt();
    this.liveCaption = '';
    this.error = null;
    this.#add({ speaker: 'user', name: 'You', text });
    this.#run(this.#pickResponders(text));
  }

  /** The Synthesizer closes the session in the house structure. */
  wrapUp() {
    if (!this.messages.some((m) => m.speaker === 'user')) return;
    this.interrupt();
    this.#run([{ panelist: PANELISTS.find((p) => p.id === 'synthesizer'), summary: true }]);
  }

  reset() {
    this.interrupt();
    this.voice.stopListening();
    this.messages = [];
    this.#lastSpoke = {};
    this.liveCaption = '';
    this.error = null;
    this.phase = { kind: 'idle' };
    this.onChange();
  }

  /** Stop: ends listening, or interrupts whoever is speaking or thinking. */
  stopTapped() {
    this.voice.stopListening();
    this.interrupt();
    this.phase = { kind: 'idle' };
    this.onChange();
  }

  /** The panelist speaking now, else the newest panelist line: drives the meeting caption. */
  get captionMessage() {
    const ref = this.voice.speakingRef;
    if (ref && this.messages.includes(ref)) return ref;
    const speaking = this.voice.speakingPanelist;
    const panelLines = this.messages.filter((m) => m.speaker !== 'user');
    return (speaking && panelLines.findLast((m) => m.speaker === speaking)) || panelLines.at(-1) || null;
  }

  interrupt() {
    this.#turn++;
    this.#abort?.abort();
    this.#abort = null;
    this.#busy = false;
    this.voice.stopSpeaking();
    if (this.phase.kind !== 'listening') this.phase = { kind: 'idle' };
    this.onChange();
  }

  micTapped() {
    if (this.phase.kind === 'listening') {
      this.voice.stopListening();
      const pending = this.liveCaption.trim();
      if (pending) this.send(pending); else { this.phase = { kind: 'idle' }; this.onChange(); }
    } else {
      this.interrupt();
      this.#listen();
    }
  }

  #listen() {
    this.liveCaption = '';
    if (this.voice.startListening()) { this.phase = { kind: 'listening' }; this.onChange(); }
  }

  #panelDone() {
    if (this.#busy) return;
    this.phase = { kind: 'idle' };
    this.onChange();
    if (this.handsFree) this.#listen();
  }

  #add(m) { this.messages.push({ id: ++this.#id, ...m }); this.onChange(); }

  // Turn-taking: mentions first, "everyone" asks all, otherwise the quietest speaks and another may chime in.
  #pickResponders(text) {
    const room = this.panel;
    if (!room.length) return [];
    const lower = text.toLowerCase();
    const mentions = (p) => {
      const hits = [p.name.toLowerCase(), ...p.aliases].map((w) => lower.search(new RegExp(`\\b${escapeRe(w)}\\b`))).filter((i) => i >= 0);
      return hits.length ? Math.min(...hits) : null;
    };
    if (/\b(everyone|everybody|all of you|you all|the panel|each of you)\b/.test(lower)) return this.#quietestFirst(room).map((panelist) => ({ panelist }));
    const named = room.map((p) => [p, mentions(p)]).filter((x) => x[1] != null).sort((a, b) => a[1] - b[1]).map((x) => ({ panelist: x[0] }));
    if (named.length) return named.slice(0, 3);
    // Opening question: let the panel each weigh in once.
    if (this.messages.filter((m) => m.speaker === 'user').length === 1) return this.#quietestFirst(room).slice(0, 4).map((panelist) => ({ panelist }));
    const order = this.#quietestFirst(room);
    return [{ panelist: order[0] }, ...(order[1] ? [{ panelist: order[1], optional: true }] : [])];
  }

  #quietestFirst(room) {
    return room.map((p, i) => [p, i]).sort((a, b) => (this.#lastSpoke[a[0].id] ?? 0) - (this.#lastSpoke[b[0].id] ?? 0) || a[1] - b[1]).map((x) => x[0]);
  }

  async #run(initial) {
    if (!initial.length) return;
    const id = ++this.#turn;
    this.#busy = true;
    const picks = [...initial];
    let followUps = 0;
    for (let i = 0; i < picks.length && id === this.#turn; i++) {
      const reply = await this.#speak(picks[i], id);
      // An agent asked another by name gets to answer, once per round.
      if (reply && i === picks.length - 1 && followUps < 1 && reply.includes('?')) {
        const addressed = this.panel.find((p) => p.id !== picks[i].panelist.id && new RegExp(`\\b${p.name}\\b`, 'i').test(reply));
        if (addressed) { picks.push({ panelist: addressed }); followUps++; }
      }
    }
    if (id !== this.#turn) return;
    this.#busy = false;
    if (!this.voice.isSpeaking) this.#panelDone();
  }

  /** Asks for the turn and shows the reply as it streams in. */
  async #streamTurn(p, optional, summary, id) {
    const r = await request('/api/brainstorm/turn/stream', { method: 'POST', headers: { 'content-type': 'application/json' }, signal: this.#abort.signal,
      body: JSON.stringify({ panelistId: p.id, members: [...this.members], optional, summary, useFrontier: this.useFrontierContext,
        messages: this.messages.slice(-24).map((m) => ({ name: m.name, text: m.text })) }) });
    if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error ?? `Request failed (${r.status})`);
    const decoder = new TextDecoder();
    let buffer = '', done = null;
    for await (const chunk of r.body) {
      buffer += decoder.decode(chunk, { stream: true });
      const lines = buffer.split('\n');
      buffer = lines.pop();
      for (const line of lines) {
        if (!line.trim()) continue;
        const e = JSON.parse(line);
        if (e.error) throw new Error(e.error);
        if (e.done) done = e.done;
        if (e.delta !== undefined && id === this.#turn) this.#showDraft(p, e.delta, optional);
      }
    }
    if (!done) throw new Error('The reply was cut off.');
    return done;
  }

  /** Tokens arrive many times a second: patch the open bubble in place instead of rebuilding the page. */
  #showDraft(p, text, optional) {
    const t = text.trim().toUpperCase();
    if (!t || (optional && 'PASS'.startsWith(t)) || t.startsWith('PASS')) return;
    const first = this.draft?.speaker !== p.id;
    this.draft = { speaker: p.id, name: p.name, text };
    const el = document.querySelector('.chat-draft .draft-text');
    if (!first && el) {
      el.replaceChildren(inline(text));
      const feed = document.querySelector('.transcript');
      if (feed && feed.scrollHeight - feed.scrollTop - feed.clientHeight < 160) feed.scrollTop = feed.scrollHeight;
    } else this.onChange();
  }

  /** One panelist's turn. Returns the reply, or null if they passed or failed. */
  async #speak({ panelist: p, optional = false, summary = false }, id) {
    this.phase = { kind: 'thinking', name: p.name };
    this.onChange();
    this.#abort = new AbortController();
    try {
      const { text, by } = await this.#streamTurn(p, optional, summary, id);
      this.draft = null;
      if (id !== this.#turn) return null;
      if (!text || text.toUpperCase().startsWith('PASS')) return null;
      this.#add({ speaker: p.id, name: p.name, text, model: by, isSummary: summary });
      this.#lastSpoke[p.id] = Date.now();
      if (this.speakReplies || this.handsFree || this.mode === 'video') {
        this.phase = { kind: 'speaking', name: p.name };
        this.voice.speak(speakable(text), p.id, this.messages.at(-1));
        this.onChange();
      }
      return text;
    } catch (e) {
      this.draft = null;
      if (id !== this.#turn || e.name === 'AbortError') return null;
      this.#add({ speaker: p.id, name: p.name, text: `(couldn't join: ${e.message})`, model: null });
      return null;
    }
  }
}
