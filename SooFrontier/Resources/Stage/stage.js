// Avatar stage for the iOS app. Native code owns conversation, audio and lipsync
// analysis; it calls SooStage.setAgents() when the room changes and SooStage.frame()
// every display frame with who is speaking and the current mouth shape.

import { ProceduralAvatar } from './avatar/procedural.js';
import { PhotoAvatar } from './avatar/photo.js';

globalThis.SOOTALKY_FACE_MODEL = '/models/face_landmarker.task';
const ZERO = { open: 0, wide: 0, round: 0, energy: 0 };
const stage = document.getElementById('stage');
let cards = [];
let state = { speaking: null, thinking: null, phase: 'idle', mouth: ZERO };
const diag = { frames: 0, speakingFrames: 0, maxOpen: 0, errors: [] };
const post = (msg) => webkit.messageHandlers.stage?.postMessage(msg);
addEventListener("error", (e) => { diag.errors.push(String(e.message || e)); });

function layout() {
  const n = cards.length;
  const portrait = innerHeight > innerWidth;
  let cols = 1, rows = 1;
  if (n === 2) [cols, rows] = portrait ? [1, 2] : [2, 1];
  else if (n === 3) [cols, rows] = portrait ? [2, 2] : [3, 1];
  else if (n >= 4) [cols, rows] = [2, Math.ceil(n / 2)];
  stage.style.gridTemplateColumns = `repeat(${cols}, minmax(0, 1fr))`;
  stage.style.gridTemplateRows = `repeat(${rows}, minmax(0, 1fr))`;
  cards.forEach((c, i) => (c.el.style.gridColumn = n === 3 && portrait && i === 0 ? 'span 2' : ''));
}

function fit(canvas) {
  const dpr = Math.min(devicePixelRatio || 1, 2);
  const w = Math.max(1, Math.round(canvas.clientWidth * dpr));
  const h = Math.max(1, Math.round(canvas.clientHeight * dpr));
  if (canvas.width !== w || canvas.height !== h) {
    canvas.width = w;
    canvas.height = h;
  }
}

function makeRenderer(canvas, avatar) {
  if (avatar.kind === 'photo' && avatar.landmarks) {
    try {
      return new PhotoAvatar(canvas, avatar);
    } catch (err) {
      diag.errors.push(`photo avatar: ${err.message}`);
    }
  }
  return new ProceduralAvatar(canvas, avatar.style || {});
}

// If a face photo can't load, fall back to the illustrated look instead of a blank card.
function watchPhoto(card, avatar) {
  if (!(card.renderer instanceof PhotoAvatar)) return;
  const started = performance.now();
  const check = () => {
    if (card.renderer.ready) return report();
    if (card.renderer.failed || performance.now() - started > 8000) {
      diag.errors.push(`photo for ${card.id} did not load`);
      card.renderer.destroy?.();
      const fresh = document.createElement('canvas');
      card.canvas.replaceWith(fresh);
      card.canvas = fresh;
      card.renderer = new ProceduralAvatar(fresh, avatar.style || {});
      return report();
    }
    setTimeout(check, 100);
  };
  check();
}

function report() {
  post({
    type: 'status',
    cards: cards.map((c) => ({ id: c.id, renderer: c.renderer instanceof PhotoAvatar ? 'photo' : 'illustrated', ready: c.renderer instanceof PhotoAvatar ? !!c.renderer.ready : true })),
    frames: diag.frames,
    speakingFrames: diag.speakingFrames,
    maxOpen: Math.round(diag.maxOpen * 100) / 100,
    errors: diag.errors.slice(-5),
  });
}
setInterval(report, 5000);

let last = performance.now();
function tick(now) {
  const dt = Math.min(0.05, (now - last) / 1000);
  last = now;
  for (const c of cards) {
    fit(c.canvas);
    const speaking = state.speaking === c.id;
    const mode = speaking ? 'speaking' : state.thinking === c.id ? 'thinking' : state.phase === 'listening' ? 'listening' : 'idle';
    c.el.classList.toggle('speaking', speaking);
    c.el.classList.toggle('thinking', mode === 'thinking');
    c.renderer.render(dt, mode, speaking ? state.mouth : ZERO);
  }
  requestAnimationFrame(tick);
}

globalThis.SooStage = {
  setAgents(list) {
    for (const c of cards) c.renderer.destroy?.();
    stage.innerHTML = '';
    cards = list.map((a) => {
      const el = document.createElement('div');
      el.className = 'card';
      el.innerHTML = '<canvas></canvas><div class="dots"><i></i><i></i><i></i></div><div class="name"></div>';
      el.querySelector('.name').textContent = a.name;
      stage.append(el);
      const canvas = el.querySelector('canvas');
      return { id: a.id, el, canvas, avatar: a.avatar, renderer: makeRenderer(canvas, a.avatar) };
    });
    layout();
    cards.forEach((c) => watchPhoto(c, c.avatar));
    report();
  },
  frame(s) {
    state = s;
    diag.frames++;
    if (s.speaking) {
      diag.speakingFrames++;
      diag.maxOpen = Math.max(diag.maxOpen, s.mouth.open);
    }
  },
  // Finds face landmarks in an image (data URL) entirely offline.
  async detectFace(dataUrl) {
    const { prepareAvatarImage } = await import('./avatar/landmarks.js');
    const blob = await (await fetch(dataUrl)).blob();
    return prepareAvatarImage(new File([blob], 'upload.jpg', { type: blob.type }));
  },
};
addEventListener('resize', layout);
requestAnimationFrame(tick);
post({ type: 'ready' });
