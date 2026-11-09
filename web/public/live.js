// Brainstorm Live: the never-ending roundtable. The server runs the loop; this only watches the stream and sends controls.
import { PANELISTS, agentColor } from './shared.js';
import { api, h, icon, inline } from './ui.js';

export const live = { config: { starters: [], presets: {} }, optionsOpen: null, editing: null, edit: null, state: null, turns: [], draft: null, error: null, topic: '', say: '', notes: false, onChange() {} };
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
  for (const kind of ['reset', 'turn', 'state', 'delta']) source.addEventListener(kind, (e) => apply(kind, JSON.parse(e.data)));
}

const act = async (path, body) => { live.error = null; try { await api(path, body ?? {}); } catch (e) { live.error = e.message; live.onChange(); } };

function bubble(t) {
  if (t.speaker === 'system') return h('p', { class: 'caption muted live-note' }, t.text);
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

/** The popover under a chip: switch that agent's model and its characteristic (the persona it speaks from). */
function agentPopover(s, a) {
  const p = seat(a.id);
  const d = live.edit;
  const models = [...new Set([...(s.installed ?? []), a.model].filter(Boolean))];
  const close = () => { live.editing = null; live.edit = null; live.onChange(); };
  const save = async () => { await act('/api/live/agent', { id: a.id, model: d.model, viewpoint: d.viewpoint }); close(); };
  return h('div', { class: 'popover', role: 'dialog', 'aria-label': `${p.name} settings`, style: { left: `${d.left}px`, top: `${d.top}px` }, onclick: (e) => e.stopPropagation() },
    h('div', { class: 'popover-head' }, h('strong', {}, p.name), h('button', { class: 'icon-btn', 'aria-label': 'Close', onclick: close }, icon('close', 16))),
    h('label', { class: 'popover-field' }, h('span', { class: 'eyebrow strong' }, 'Model'),
      h('select', { class: 'field', 'aria-label': `${p.name} model`, onchange: (e) => { d.model = e.target.value; } },
        models.map((m) => h('option', { value: m, selected: m === d.model }, m === s.main ? `${m} (main)` : m)))),
    h('label', { class: 'popover-field' }, h('span', { class: 'eyebrow strong' }, 'Characteristic'),
      h('textarea', { class: 'field', rows: 5, 'aria-label': `${p.name} characteristic`, value: d.viewpoint, oninput: (e) => { d.viewpoint = e.target.value; } })),
    a.memory ? h('p', { class: 'caption muted' }, h('strong', {}, 'Notes: '), a.memory) : null,
    h('div', { class: 'popover-actions' },
      h('button', { class: 'btn small accent', onclick: save }, 'Save'),
      h('button', { class: 'btn small', disabled: !a.custom && d.viewpoint === a.defaultViewpoint, onclick: () => { d.viewpoint = a.defaultViewpoint; live.onChange(); } }, 'Reset characteristic')),
    h('p', { class: 'caption muted' }, 'Applies from this agent’s next turn.'));
}

const OPTION_ROWS = [['length', 'Reply length'], ['pace', 'Pace'], ['memory', 'Memory']];

/** Room-wide settings. Their choices and values come from live-config.json; each click applies from the next turn. */
function optionsPopover(s) {
  const presets = live.config.presets;
  return h('div', { class: 'popover', role: 'dialog', 'aria-label': 'Discussion settings', style: { left: `${live.optionsOpen.left}px`, top: `${live.optionsOpen.top}px` }, onclick: (e) => e.stopPropagation() },
    h('div', { class: 'popover-head' }, h('strong', {}, 'Discussion settings'),
      h('button', { class: 'icon-btn', 'aria-label': 'Close', onclick: () => { live.optionsOpen = null; live.onChange(); } }, icon('close', 16))),
    OPTION_ROWS.map(([key, label]) => h('div', { class: 'popover-field' }, h('span', { class: 'eyebrow strong' }, label),
      h('div', { class: 'segmented', role: 'group', 'aria-label': label }, Object.entries(presets[key] ?? {}).map(([id, p]) =>
        h('button', { class: s?.options?.[key] === id ? 'on' : '', 'aria-pressed': String(s?.options?.[key] === id), onclick: () => act('/api/live/options', { [key]: id }) }, p.label))))),
    h('p', { class: 'caption muted' }, 'Applies from the next turn. What an agent remembers is also capped by size, so prompts fit a small model’s context window.'));
}

function agentStrip(s) {
  return h('div', { class: 'panel-strip' }, (s?.agents ?? PANELISTS.map((p) => ({ id: p.id, model: null }))).map((a) => {
    const p = seat(a.id);
    const talking = s?.status === 'running' && s.speaking === a.id;
    const open = live.editing === a.id && s?.agents;
    return h('div', { class: 'chip-wrap' },
      h('button', { class: `panel-chip on${talking ? ' talking' : ''}${open ? ' open' : ''}`, style: { '--agent': agentColor(p.agent) }, 'aria-haspopup': 'dialog', 'aria-expanded': String(Boolean(open)),
        'aria-label': `${p.name}${a.model ? `, ${a.model}` : ''}. Change model and characteristic`, title: 'Change model and characteristic',
        onclick: (e) => {
          e.stopPropagation();
          live.optionsOpen = null;
          if (live.editing === a.id) { live.editing = null; live.edit = null; }
          else {
            // Fixed coordinates from the chip, because the strip scrolls sideways and would clip an absolute popover.
            const r = e.currentTarget.getBoundingClientRect();
            live.editing = a.id;
            live.edit = { model: a.model ?? s?.main, viewpoint: a.viewpoint ?? '', left: Math.max(16, Math.min(r.left, innerWidth - 356)), top: r.bottom + 8 };
          }
          live.onChange();
        } },
        h('span', { class: `badge small${talking ? ' pulse' : ''}` }, p.name[0]),
        h('span', { class: 'chip-text' }, h('strong', {}, p.name), h('span', {}, a.model ? `Local · ${a.model}` : 'Local'))),
      open ? agentPopover(s, a) : null);
  }).concat(h('div', { class: 'chip-wrap' },
    h('button', { class: `panel-chip on${live.optionsOpen ? ' open' : ''}`, 'aria-haspopup': 'dialog', 'aria-expanded': String(Boolean(live.optionsOpen)), 'aria-label': 'Discussion settings', title: 'Discussion settings',
      onclick: (e) => {
        e.stopPropagation();
        live.editing = null; live.edit = null;
        if (live.optionsOpen) live.optionsOpen = null;
        else { const r = e.currentTarget.getBoundingClientRect(); live.optionsOpen = { left: Math.max(16, Math.min(r.left, innerWidth - 356)), top: r.bottom + 8 }; }
        live.onChange();
      } },
      h('span', { class: 'chip-text' }, h('strong', {}, 'Settings'), h('span', {}, s?.options ? `${live.config.presets.length?.[s.options.length]?.label ?? ''} replies` : '…'))),
    live.optionsOpen && s?.options ? optionsPopover(s) : null)));
}

// A click anywhere else, or Escape, closes the popover.
document.addEventListener('click', () => { if (live.editing || live.optionsOpen) { live.editing = null; live.edit = null; live.optionsOpen = null; live.onChange(); } });
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && (live.editing || live.optionsOpen)) { live.editing = null; live.edit = null; live.optionsOpen = null; live.onChange(); } });

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
