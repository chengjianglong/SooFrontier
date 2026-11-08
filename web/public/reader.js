// Reads stories and briefs aloud, and can carry on to the next story when one finishes. Ported from Services/Reader.swift.
import { sentences, speakable } from './shared.js';
import { store } from './ui.js';

export const SPEEDS = [0.85, 1, 1.2, 1.4];

function bestVoice() {
  const english = speechSynthesis.getVoices().filter((v) => v.lang === 'en-US');
  return english.find((v) => /premium|enhanced|natural/i.test(v.name)) ?? english.find((v) => v.localService) ?? english[0] ?? null;
}

export class Reader {
  title = null;
  isPaused = false;
  currentItemID = null;
  autoAdvance = store.get('reader.autoAdvance', true);
  speed = store.get('reader.speed', 1);
  onChange = () => {};
  #playlist = [];
  #index = 0;
  #script = null;
  #run = 0;
  #onFinish = null;

  get supported() { return 'speechSynthesis' in window; }
  get isActive() { return this.title != null; }

  setAutoAdvance(v) { this.autoAdvance = v; store.set('reader.autoAdvance', v); this.onChange(); }
  setSpeed(v) { this.speed = v; store.set('reader.speed', v); this.onChange(); }

  /** Reads `items` from `start`, continuing through the list when auto-advance is on. */
  play(items, start, script) {
    if (!items[start]) return;
    this.#playlist = items;
    this.#index = start;
    this.#script = script;
    this.#speakCurrent();
  }

  /** Moves the playlist to another story (when the reader taps Previous / Next while listening). */
  jump(id) {
    const i = this.#playlist.findIndex((x) => x.url === id);
    if (i < 0 || i === this.#index) return;
    this.#index = i;
    this.#speakCurrent();
  }

  #speakCurrent() {
    const item = this.#playlist[this.#index];
    if (!item) return this.stop();
    const [list, index, script] = [this.#playlist, this.#index, this.#script];
    this.read(item.title, [item.title, ...script(item)], () => {
      if (!this.autoAdvance || index + 1 >= list.length) return;
      this.#playlist = list;
      this.#index = index + 1;
      this.#script = script;
      this.#speakCurrent();
    });
    [this.#playlist, this.#index, this.#script] = [list, index, script];
    this.currentItemID = item.url;
    this.onChange();
  }

  /** Reads the parts in order; `onFinish` runs only if reading reached the end (not when stopped). */
  read(title, parts, onFinish = null) {
    this.stop();
    if (!this.supported) return;
    this.title = title;
    this.#onFinish = onFinish;
    const run = ++this.#run;
    // Short utterances, since some browsers cut long ones off after about 15 seconds.
    const queue = parts.map(speakable).filter(Boolean).flatMap(sentences);
    const voice = bestVoice();
    let next = 0;
    const speakNext = () => {
      if (run !== this.#run) return;
      if (next >= queue.length) return this.#finished();
      const u = new SpeechSynthesisUtterance(queue[next++]);
      u.voice = voice;
      u.lang = 'en-US';
      u.rate = this.speed;
      u.onend = speakNext;
      u.onerror = (e) => { if (e.error !== 'canceled' && e.error !== 'interrupted') speakNext(); };
      speechSynthesis.speak(u);
    };
    speakNext();
    this.onChange();
  }

  #finished() {
    const next = this.#onFinish;
    this.#onFinish = null;
    this.title = null;
    this.currentItemID = null;
    this.onChange();
    next?.();
  }

  togglePause() {
    if (this.isPaused) speechSynthesis.resume(); else speechSynthesis.pause();
    this.isPaused = !this.isPaused;
    this.onChange();
  }

  stop() {
    this.#run++;
    this.#onFinish = null;
    this.#playlist = [];
    this.#script = null;
    this.currentItemID = null;
    this.title = null;
    this.isPaused = false;
    if (this.supported) speechSynthesis.cancel();
    this.onChange();
  }

  /** Ends the current reading as if it had finished, so auto-advance moves on. */
  skip() {
    this.#run++;
    speechSynthesis.cancel();
    this.isPaused = false;
    this.#finished();
  }
}
