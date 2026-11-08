// Brainstorm Live: the never-ending roundtable. The server runs the loop; this only watches the stream and sends controls.
import { PANELISTS, agentColor } from './shared.js';
import { api, h, icon, inline } from './ui.js';

export const live = { config: { starters: [] }, state: null, turns: [], draft: null, error: null, topic: '', say: '', notes: false, onChange() {} };
let source = null;

const seat = (id) => PANELISTS.find((p) => p.id === id);

function apply(kind, data) {
  if (kind === 'reset') { live.state = data; live.turns = data.turns ?? []; live.draft = data.draft; }
  else if (kind === 'turn') { if (!live.turns.some((t) => t.n === data.turn.n)) live.turns.push(data.turn); if (live.state) live.state.total = data.turn.n; live.draft = null; }
  else if (kind === 'state') { live.state = { ...live.state, ...data }; live.draft = data.draft; }
  else if (kind === 'delta') {
    const first = live.draft?.speaker !== data.speaker;
    live.draft = data;
    // Tokens arrive many times a second: patch the open reply in place instead of rebuilding the page.
    const el = document.querySelector('.live-draft .draft-text');
    if (!first && el) {
      el.replaceChildren(inline(data.text));
      const feed = document.querySelector('.transcript');
      if (feed && feed.scrollHeight - feed.scrollTop - feed.clientHeight < 160) feed.scrollTop = feed.scrollHeight;
      return;
    }
  }
  live.onChange();
}

/** Opens the event stream once; the browser reconnects it by itself and the server sends a fresh snapshot each time. */
export function connectLive() {
  if (source) return;
  // Starter topics live in live-config.json; until it loads there are simply none to show.
  fetch('/live-config.json').then((r) => r.json()).then((c) => { live.config = c; live.onChange(); }).catch(() => {});
  source = new EventSource('/api/live/stream');
  for (const kind of ['reset', 'turn', 'state']) source.addEventListener(kind, (e) => apply(kind, JSON.parse(e.data)));
}

const act = async (path, body) => { live.error = null; try { await api(path, body ?? {}); } catch (e) { live.error = e.message; live.onChange(); } };

function bubble(t) {
  if (t.speaker === 'human') return h('div', { class: 'bubble-user' }, h('p', {}, t.text));
  const p = seat(t.speaker);
  return h('div', { class: 'bubble-agent' }, h('span', { class: 'badge', style: { '--agent': agentColor(p.agent) } }, p.name[0]),
    h('div', {}, h('div', { class: 'bubble-head' }, h('strong', {}, p.name), t.model ? h('span', { class: 'caption tertiary' }, `${t.model} · local`) : null),
      h('p', { class: 'serif' }, inline(t.text))));
}

function draftBubble(d) {
  const p = seat(d.speaker);
  return h('div', { class: 'bubble-agent live-draft' }, h('span', { class: 'badge', style: { '--agent': agentColor(p.agent) } }, p.name[0]),
    h('div', {}, h('div', { class: 'bubble-head' }, h('strong', {}, p.name), d.model ? h('span', { class: 'caption tertiary' }, `${d.model} · local`) : null),
      h('p', { class: 'serif draft-text' }, inline(d.text || '…'))));
}

function agentStrip(s) {
  return h('div', { class: 'panel-strip' }, (s?.agents ?? PANELISTS.map((p) => ({ id: p.id, model: null }))).map((a) => {
    const p = seat(a.id);
    const talking = s?.status === 'running' && s.speaking === a.id;
    return h('button', { class: `panel-chip on${talking ? ' talking' : ''}`, style: { '--agent': agentColor(p.agent) }, 'aria-label': `${p.name}${a.model ? `, ${a.model}` : ''}`,
      title: 'Show each agent’s private notes', onclick: () => { live.notes = !live.notes; live.onChange(); } },
      h('span', { class: `badge small${talking ? ' pulse' : ''}` }, p.name[0]),
      h('span', { class: 'chip-text' }, h('strong', {}, p.name), h('span', {}, a.model ? `Local · ${a.model}` : 'Local')));
  }));
}

function notesView(s) {
  return h('div', { class: 'live-notes' }, h('p', { class: 'caption muted' }, 'Each agent’s private notes: what it keeps in mind between turns, rewritten every few turns on its own model.'),
    (s?.agents ?? []).map((a) => h('div', {}, h('strong', {}, seat(a.id).name), h('span', { class: 'caption muted' }, ` · ${a.turns} turns`),
      h('p', { class: 'caption' }, a.memory || 'Nothing yet.'))));
}

export function liveView() {
  const s = live.state;
  const status = s?.status ?? 'idle';
  const active = ['running', 'paused', 'error'].includes(status);
  const speaker = s?.speaking ? seat(s.speaking)?.name : null;
  const err = live.error ?? s?.error;

  const start = (topic) => { topic = topic.trim(); if (topic) { live.topic = ''; act('/api/live/start', { topic }); } };
  const send = () => { const t = live.say.trim(); live.say = ''; if (t) act('/api/live/say', { text: t }); live.onChange(); };

  const stateLine = status === 'running' ? (speaker ? `${speaker} is thinking…` : 'Starting…')
    : status === 'paused' ? 'Paused' : status === 'stopped' ? 'Stopped' : status === 'error' ? 'Stopped after repeated errors' : '';

  const feed = h('div', { class: 'transcript' }, h('div', { class: 'transcript-inner' },
    s?.topic ? h('div', { class: 'live-topic' }, h('span', { class: 'eyebrow accent' }, 'Topic'), h('strong', {}, s.topic), h('span', { class: 'caption muted' }, `${s.total} turns`)) : null,
    s?.topic ? null : h('div', { class: 'stack' }, h('span', { class: 'eyebrow accent' }, 'Live discussion'),
      h('h1', { class: 'display' }, 'Give them a topic and let them talk.'),
      h('p', { class: 'serif muted' }, 'Five agents debate on your local models and never stop until you do. Each has its own model and its own private notes. Jump in at any time and they will answer you.'),
      live.config.starters.map((t) => h('button', { class: 'starter', onclick: () => start(t) }, t))),
    live.notes ? notesView(s) : null,
    live.turns.map(bubble),
    live.draft && status === 'running' ? draftBubble(live.draft) : null,
    stateLine && !(live.draft && status === 'running') ? h('p', { class: `callout ${status === 'running' ? 'muted' : ''}` }, stateLine) : null,
    err ? h('p', { class: 'callout red', role: 'alert' }, err) : null));

  const topicInput = h('textarea', { class: 'field composer-input', rows: 1, placeholder: 'Type a topic for them to discuss…', 'aria-label': 'Topic', value: live.topic,
    oninput: (e) => { live.topic = e.target.value; },
    onkeydown: (e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); start(live.topic); } } });
  const sayInput = h('textarea', { class: 'field composer-input', rows: 1, placeholder: 'Jump in…', 'aria-label': 'Say something to the room', value: live.say,
    oninput: (e) => { live.say = e.target.value; },
    onkeydown: (e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); } } });

  const controls = active ? h('div', { class: 'live-controls' },
    status === 'running'
      ? h('button', { class: 'btn small', onclick: () => act('/api/live/pause') }, icon('stop', 14), 'Pause')
      : h('button', { class: 'btn small', onclick: () => act('/api/live/resume') }, 'Resume'),
    h('button', { class: 'btn small danger', onclick: () => act('/api/live/stop') }, 'Stop'),
    h('button', { class: 'btn small', onclick: () => { live.notes = !live.notes; live.onChange(); } }, live.notes ? 'Hide notes' : 'Agent notes')) : null;

  return [feed, controls,
    h('div', { class: 'composer' }, active ? sayInput : topicInput,
      h('button', { class: 'round-btn accent', 'aria-label': active ? 'Send' : 'Start', onclick: () => (active ? send() : start(live.topic)) }, icon('send', 20)))];
}

export { agentStrip };
