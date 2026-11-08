// The app shell and its tabs: Brief, Research, Productions, Opinions, Brainstorm, Settings.
import { AGENTS, CATEGORIES, PANELISTS, PROVIDERS, SECTIONS, VOICE_ROLES, agentColor, capitalize, futureWork, hypeWatch, itemsIn, laneOpportunities, parseStructure, quickTLDR, quickTakeaways, sentences, spokenScript, technicalDetails, topSignals, verdict, keyPoints, byScore } from './shared.js';
import { Reader, SPEEDS } from './reader.js';
import { Room } from './room.js';
import { api, h, icon, inline, markdown, request, store, timeAgo } from './ui.js';

const main = document.getElementById('main');
const top = document.getElementById('top');
const tabsBottom = document.getElementById('tabs-bottom');
const sheet = document.getElementById('sheet');

let S = null; // the server's latest snapshot
const reader = new Reader();
const room = new Room();
const detail = new Map(); // per-story page state, kept while you move around
let sequence = []; // the list the open story came from, for Previous / Next
const lanes = store.get('lanes', {});
const scrollByRoute = new Map();
let meetingBuilt = null;

const TABS = [
  ['brief', 'Brief'], ['research', 'Research'], ['productions', 'Productions'], ['opinions', 'Opinions'], ['brainstorm', 'Brainstorm'], ['settings', 'Settings'],
];

function route() {
  const parts = location.hash.replace(/^#\/?/, '').split('/');
  return { name: parts[0] || 'brief', arg: parts.slice(1).join('/') };
}

const itemHref = (item) => `#/item/${encodeURIComponent(item.url)}`;
const isSaved = (item) => S.saved.includes(item.url);
const isOnPlan = (p) => S.providers[p].configured;

// MARK: Appearance

const APPEARANCE = { textSize: 'medium', theme: 'system', accent: 'ink', font: 'serif' };
const TEXT_SIZES = { small: ['Small', 0.9], medium: ['Default', 1], large: ['Large', 1.12], xLarge: ['Extra large', 1.25], xxLarge: ['Huge', 1.4] };
const look = { ...APPEARANCE, ...store.get('appearance', {}) };

function applyAppearance() {
  const root = document.documentElement;
  root.dataset.accent = look.accent;
  root.dataset.font = look.font;
  if (look.theme === 'system') delete root.dataset.theme; else root.dataset.theme = look.theme;
  root.style.setProperty('--scale', TEXT_SIZES[look.textSize]?.[1] ?? 1);
}

// MARK: Shared pieces

const eyebrow = (text, cls = '') => h('div', { class: `eyebrow ${cls}` }, text);
const sectionRule = (title, trailing) => h('div', { class: 'rule' }, h('div', { class: 'rule-row' }, h('h2', { class: 'eyebrow strong' }, title), trailing ? eyebrow(trailing) : null));

function itemEyebrow(item, showLane = true) {
  const parts = [];
  if (showLane) parts.push(CATEGORIES[item.category].title);
  if (item.category === 'voices' && item.author) parts.push(item.author);
  parts.push(item.source);
  if (item.category === 'voices' && item.tags[0]) parts.push(item.tags[0]);
  return h('div', { class: 'item-eyebrow' }, h('span', { class: 'dot', style: { background: CATEGORIES[item.category].tint } }), h('span', { class: 'eyebrow' }, parts.join('  ·  ')));
}

function signalMeter(a) {
  const v = verdict(a);
  const pos = Math.max(0.03, Math.min(0.97, 0.5 + (a.signal - a.hype) / 2)) * 100;
  return h('div', { class: 'meter' },
    h('div', { class: 'meter-top' }, h('strong', { class: 'headline' }, v.label), h('span', { class: 'caption mono' }, `Signal ${Math.floor(a.signal * 100)}  ·  Hype ${Math.floor(a.hype * 100)}`)),
    h('div', { class: `meter-track tone-${v.tone}` }, h('div', { class: 'meter-fill', style: { width: `${pos}%` } }), h('div', { class: 'meter-knob', style: { left: `${pos}%` } })),
    h('div', { class: 'meter-top' }, eyebrow('Hype'), eyebrow('Signal')));
}

function spinner(text) {
  return h('div', { class: 'working' }, h('span', { class: 'spin', 'aria-hidden': 'true' }), h('span', {}, text));
}

/** TL;DR, Takeaways, Mathematical analysis, Potential opportunities. */
function structured({ tldr, takeaways = [], math = [], opportunities = [], opportunitiesLoading = false, header = null }) {
  return h('div', { class: 'structured' },
    h('div', { class: 'tldr' }, eyebrow('TL;DR', 'accent'), h('p', {}, inline(tldr))),
    takeaways.length || header ? h('section', {}, sectionRule('Takeaways'), header,
      takeaways.map((t, i) => h('div', { class: 'takeaway' }, h('span', { class: 'num' }, String(i + 1).padStart(2, '0')), h('p', {}, inline(t))))) : null,
    math.length ? h('section', {}, sectionRule('Mathematical analysis'), math.map(mathLine)) : null,
    opportunitiesLoading ? h('section', {}, sectionRule('Potential opportunities'), spinner('Writing ideas for this story (about 30 s)')) : null,
    opportunities.length ? h('section', {}, sectionRule('Potential opportunities'),
      opportunities.map((t) => h('div', { class: 'takeaway' }, h('span', { class: 'num accent' }, icon('bulb', 17)), h('p', {}, inline(t))))) : null);
}

function mathLine(text) {
  const t = text.trim();
  if (t.length > 2 && t.startsWith('`') && t.endsWith('`') && !t.slice(1, -1).includes('`')) {
    return h('div', { class: 'equation' }, t.slice(1, -1).replace(/_\{([^}]*)\}/g, '[$1]'));
  }
  return h('p', { class: 'math-prose' }, inline(text));
}

function structuredText(text) {
  const p = parseStructure(text);
  return p ? structured(p) : h('div', { class: 'serif' }, markdown(text));
}

function saveButton(item, { label = false } = {}) {
  const on = isSaved(item);
  return h('button', {
    class: `icon-btn${on ? ' on' : ''}`, title: on ? 'Remove from Saved' : 'Save', 'aria-label': on ? 'Remove from Saved' : 'Save', 'aria-pressed': String(on),
    onclick: async (e) => { e.preventDefault(); e.stopPropagation(); await api('/api/saved', { id: item.url }); },
  }, icon('bookmark', 17), label ? (on ? 'Saved' : 'Save') : null);
}

function itemRow(item, list, showLane = false) {
  const a = item.assessment;
  const v = a ? verdict(a) : null;
  return h('article', { class: 'row' },
    h('a', { href: itemHref(item), onclick: () => { sequence = list; } },
      h('div', { class: 'row-top' }, itemEyebrow(item, showLane), item.date ? h('span', { class: 'caption tertiary' }, timeAgo(item.date)) : null),
      h('h3', { class: 'headline clamp3' }, item.title),
      item.summary ? h('p', { class: 'row-summary clamp2' }, item.summary) : null,
      h('div', { class: 'row-meta' },
        item.tractionLabel ? h('span', { class: 'mono' }, item.tractionLabel) : null,
        v ? h('span', { class: 'verdict' }, h('span', { class: `dot tone-bg-${v.tone}` }), v.label) : null)),
    saveButton(item));
}

function emptyState(title, note) {
  return h('div', { class: 'empty' }, h('strong', {}, title), note ? h('p', {}, note) : null);
}

const refresh = () => api('/api/refresh', {});

// MARK: Top bar

function renderChrome() {
  const r = route();
  const active = r.name === 'item' || r.name === 'saved' ? null : r.name;
  const title = TABS.find((t) => t[0] === r.name)?.[1] ?? (r.name === 'saved' ? 'Saved' : 'Story');
  const link = ([id, label], withIcon) => h('a', { href: `#/${id}`, class: `tab${active === id ? ' on' : ''}`, 'aria-current': active === id ? 'page' : null }, withIcon ? icon(id, 21) : null, h('span', {}, label));
  top.replaceChildren(h('div', { class: 'bar' },
    h('a', { class: 'brand', href: '#/brief', 'aria-label': `SooFrontier ${title}` }, h('img', { src: '/brand.png', alt: '', width: 26, height: 26 }),
      h('span', {}, h('span', { class: 'soo' }, 'Soo'), h('span', { class: 'frontier' }, 'Frontier'), h('span', { class: 'section' }, ` ${title}`))),
    h('nav', { class: 'tabs-top', 'aria-label': 'Sections' }, TABS.map((t) => link(t))),
    h('div', { class: 'bar-actions' },
      h('a', { class: 'icon-btn', href: '#/saved', title: 'Saved', 'aria-label': 'Saved' }, icon('bookmark')),
      h('button', { class: `icon-btn${S?.isRefreshing ? ' spinning' : ''}`, title: 'Dispatch agents', 'aria-label': 'Dispatch agents', disabled: S?.isRefreshing, onclick: refresh }, icon('refresh')),
      h('a', { class: 'icon-btn phone-only', href: '#/settings', title: 'Settings', 'aria-label': 'Settings' }, icon('settings')))));
  tabsBottom.replaceChildren(...TABS.slice(0, 5).map((t) => link(t, true)));
}

// MARK: Brief

function viewBrief() {
  const items = S.items;
  const s = S.status.synthesizer;
  const working = s?.state === 'working';
  const b = S.brief;
  const next = new Date(S.nextRun).toLocaleString('en-US', { weekday: 'short', hour: 'numeric', minute: '2-digit' });
  const today = new Date().toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' });
  const reading = reader.title === 'The Frontier Brief';

  const masthead = h('div', { class: 'masthead' }, eyebrow(today),
    h('p', { class: 'sub' }, `${items.length} signals · ${Object.keys(AGENTS).length} agents${S.lastRefresh ? ` · updated ${timeAgo(S.lastRefresh)}` : ''} · next update ${next}`),
    h('div', { class: 'providers' }, Object.keys(PROVIDERS).map((p) => h('span', { class: `provider${isOnPlan(p) ? ' on' : ''}` }, h('span', { class: 'dot' }), PROVIDERS[p].family))),
    h('div', { class: 'thick-rule' }));

  const brief = h('section', { class: 'stack' },
    h('div', { class: 'row-top' }, eyebrow(b?.byLLM ? `Written by ${b.byLLM}` : 'Synthesizer'),
      h('div', { class: 'inline-actions' },
        b && reader.supported ? h('button', { class: 'text-btn', onclick: () => {
          if (reading) return reader.stop();
          const p = parseStructure(b.text);
          reader.read('The Frontier Brief', ['The Frontier Brief.', ...(p ? spokenScript(p) : b.text.split('\n'))]);
        } }, icon(reading ? 'stop' : 'speaker', 15), reading ? 'Stop' : 'Listen') : null,
        h('button', { class: 'text-btn', disabled: working || !items.length, onclick: () => api('/api/brief/rewrite', {}) }, icon('refresh', 15), 'Rewrite'))),
    working ? spinner(s.label) : null,
    b ? structuredText(b.text) : !S.isRefreshing ? h('p', { class: 'muted serif' }, 'Dispatch the agents to write today’s brief.') : spinner('Agents are harvesting…'));

  const signals = topSignals(items);
  const signalList = h('section', {}, sectionRule('Top signals', 'Across all lanes'), signals.map((item, i) => h('a', { class: 'signal', href: itemHref(item), onclick: () => { sequence = signals; } },
    h('span', { class: 'num big' }, String(i + 1).padStart(2, '0')), h('div', {}, itemEyebrow(item), h('div', { class: 'signal-title clamp3' }, item.title)))));

  const hype = hypeWatch(items);
  const hypeList = hype.length ? h('section', {}, sectionRule('Hype watch', 'Flagged by the Skeptic'), hype.map((item) => h('a', { class: 'signal hype', href: itemHref(item), onclick: () => { sequence = hype; } },
    h('div', {}, itemEyebrow(item), h('div', { class: 'hype-title' }, item.title), item.assessment.flags[0] ? h('p', { class: 'caption muted italic' }, item.assessment.flags[0]) : null)))) : null;

  const crew = h('section', {}, sectionRule('The crew', S.isRefreshing ? 'On assignment' : null), h('div', { id: 'crew', class: 'crew' }, crewCards()));

  return h('div', { class: 'page wide' }, masthead, h('div', { class: 'brief-grid' },
    h('div', { class: 'stack col-main' }, brief, h('div', { class: 'desktop-only' }, crew)),
    h('div', { class: 'stack col-side' }, signalList, hypeList, h('div', { class: 'phone-only' }, crew.cloneNode(true)))));
}

function crewCards() {
  return Object.keys(AGENTS).map((a) => {
    const on = !S.agentsOff.includes(a);
    const s = S.status[a] ?? { state: 'idle', label: 'Standing by' };
    return h('div', { class: `crew-card${on ? '' : ' off'}` },
      h('span', { class: `badge${s.state === 'working' ? ' pulse' : ''}`, style: { '--agent': agentColor(a) } }, AGENTS[a].name[0]),
      h('div', { class: 'crew-text' }, h('strong', {}, AGENTS[a].name), h('span', { class: `caption clamp1 ${s.state === 'failed' ? 'red' : 'muted'}`, title: s.label }, on ? s.label : 'Off duty')));
  });
}

// MARK: Desks

const deskUI = { query: '', hideHype: false };

function viewDesk(section, laneArg) {
  const desk = SECTIONS[section];
  const lane = desk.lanes.includes(laneArg) ? laneArg : (lanes[section] ?? desk.lanes[0]);
  lanes[section] = lane;
  store.set('lanes', lanes);
  const list = h('div', { class: 'list' });

  const renderList = () => {
    const q = deskUI.query.toLowerCase();
    const items = itemsIn(S.items, lane).filter((i) =>
      (!q || i.title.toLowerCase().includes(q) || (i.summary ?? '').toLowerCase().includes(q) || i.source.toLowerCase().includes(q))
      && (!deskUI.hideHype || !i.assessment || verdict(i.assessment).label !== 'Hype alert'));
    list.replaceChildren(...(items.length ? items.map((i) => itemRow(i, items))
      : [S.isRefreshing ? spinner('Agents are harvesting…') : emptyState(q ? `No results for “${deskUI.query}”` : lane === 'voices' && S.status.listener?.state === 'failed' ? `Couldn't hear voices on X. ${S.status.listener.label}` : 'Nothing here yet')]));
  };
  renderList();

  return h('div', { class: 'page' },
    h('div', { class: 'filter-row' },
      h('input', { type: 'search', class: 'field', placeholder: `Filter ${desk.title.toLowerCase()}`, 'aria-label': `Filter ${desk.title.toLowerCase()}`, value: deskUI.query, oninput: (e) => { deskUI.query = e.target.value; renderList(); } }),
      h('label', { class: 'check', title: 'Hide items the Skeptic flags as hype' }, h('input', { type: 'checkbox', checked: deskUI.hideHype, onchange: (e) => { deskUI.hideHype = e.target.checked; renderList(); } }), 'Hide hype')),
    h('nav', { class: 'lane-tabs', 'aria-label': `${desk.title} lanes` }, desk.lanes.map((c) => h('a', { href: `#/${section}/${c}`, class: `lane${c === lane ? ' on' : ''}`, 'aria-current': c === lane ? 'page' : null },
      CATEGORIES[c].title, h('span', { class: 'count' }, String(itemsIn(S.items, c).length))))),
    digestBar(section), list);
}

const digestErrors = {};

function digestBar(section) {
  const desk = SECTIONS[section];
  const d = S.digests[section];
  const working = S.digestsInProgress.includes(section);
  const openDigest = () => {
    const digest = S.digests[section];
    openSheet(h('div', { class: 'sheet-body' }, eyebrow(desk.title), h('h2', { class: 'display' }, desk.digestLabel),
      h('p', { class: 'caption muted' }, `Written by ${digest.byLLM}`), h('hr'), structuredText(digest.text)));
  };
  const status = working ? 'Writing…' : digestErrors[section] ?? (d ? `Updated ${timeAgo(d.generatedAt)}` : `Across every lane in ${desk.title}`);
  return h('div', { class: 'digest-bar' },
    h('div', { class: 'digest-text' }, eyebrow(desk.digestLabel, 'strong'), h('span', { class: `caption clamp1 ${!working && digestErrors[section] ? 'red' : 'muted'}` }, status)),
    working ? h('span', { class: 'spin', 'aria-hidden': 'true' }) : null,
    d ? h('button', { class: 'btn small', onclick: openDigest }, 'Read') : null,
    h('button', { class: 'text-btn', disabled: working, onclick: async () => {
      delete digestErrors[section];
      try { await api('/api/digest', { section }); openDigest(); }
      catch (e) { digestErrors[section] = e.message; render(); }
    } }, d ? 'Rewrite' : 'Write'));
}

function openSheet(content) {
  const close = () => { sheet.replaceChildren(); document.removeEventListener('keydown', onKey); };
  const onKey = (e) => { if (e.key === 'Escape') close(); };
  document.addEventListener('keydown', onKey);
  const panel = h('div', { class: 'sheet-panel', role: 'dialog', 'aria-modal': 'true' },
    h('button', { class: 'icon-btn sheet-close', 'aria-label': 'Close', onclick: close }, icon('close')), content);
  sheet.replaceChildren(h('div', { class: 'sheet-scrim', onclick: (e) => { if (e.target === e.currentTarget) close(); } }, panel));
  panel.querySelector('button').focus();
}

// MARK: Saved

function viewSaved() {
  const items = S.items.filter(isSaved);
  return h('div', { class: 'page' }, h('h1', { class: 'display' }, 'Saved'),
    h('div', { class: 'list' }, items.length ? items.map((i) => itemRow(i, items, true)) : emptyState('Nothing saved yet', 'Tap the bookmark on any story to keep it here.')));
}

// MARK: One story

function storyState(id) {
  if (!detail.has(id)) detail.set(id, { critique: null, by: null, critiquing: false, council: [], ruling: null, convening: false, error: null, paper: null, paperLoaded: false, quick: null, ideasLoading: false });
  return detail.get(id);
}

const stillOn = (item) => route().name === 'item' && decodeURIComponent(route().arg) === item.url;

async function loadStory(item, next) {
  const st = storyState(item.url);
  if (st.paperLoaded || st.loading) return;
  st.loading = true;
  st.quick = S.quickReads[item.url] ?? null;
  if (!st.quick) st.ideasLoading = true;
  api('/api/item/paper', { id: item.url }).then((paper) => { st.paper = paper; }).catch(() => {}).finally(() => { st.paperLoaded = true; if (stillOn(item)) render(); });
  if (!st.quick) {
    st.quick = (await api('/api/item/quick', { id: item.url }).catch(() => ({}))).quick ?? null;
    st.ideasLoading = false;
    if (stillOn(item)) render();
  }
  // Prepare the next story's ideas in the background so Next shows them right away.
  if (next && !S.quickReads[next.url]) api('/api/item/quick', { id: next.url }).catch(() => {});
}

function storyParts(item, st) {
  const tldr = quickTLDR(item);
  let takeaways = st.quick && quickTakeaways(st.quick).length ? quickTakeaways(st.quick) : st.paper?.keyPoints?.length ? st.paper.keyPoints : keyPoints(item.summary, null, tldr);
  if (!takeaways.length) takeaways = sentences(item.summary ?? '').filter((s) => !tldr.includes(s)).slice(0, 2);
  takeaways = [...takeaways];
  let origin = `**Where it comes from:** Published by ${item.source}`;
  if (item.date) origin += ` ${timeAgo(item.date)}`;
  origin += item.author ? `, credited to ${item.author}.` : '.';
  if (item.tractionLabel) origin += ` It has ${item.tractionLabel} so far, a rough signal of how much attention it is getting, not of whether it holds up.`;
  takeaways.push(origin);
  if (item.tags.length && !technicalDetails(item)) takeaways.push(`**Topics:** It is tagged ${item.tags.join(', ')}, which places it among related ${CATEGORIES[item.category].title.toLowerCase()}.`);
  const a = item.assessment;
  if (a) {
    const why = a.signal > a.hype ? 'The evidence outweighs the promotional language, so it is worth reading closely.' : 'The language runs ahead of the evidence, so treat its claims as unverified until someone reproduces them.';
    takeaways.push(`**Skeptic's verdict: ${verdict(a).label}.** It scores ${Math.floor(a.signal * 100)} for signal and ${Math.floor(a.hype * 100)} for hype. ${why}`);
    takeaways.push(...a.flags.map((f) => `**Watch out:** ${f}.`));
  }
  let opportunities = st.quick?.opportunities ?? [];
  if (!opportunities.length) opportunities = st.paper?.futureWork?.length ? st.paper.futureWork : st.ideasLoading ? [] : laneOpportunities(item.category);
  return { tldr, takeaways, opportunities };
}

/** Spoken script for later stories, from what's already here. */
function scriptFor(item) {
  const quick = S.quickReads[item.url];
  const tldr = sentences(item.summary ?? '').slice(0, 3).join(' ') || item.title;
  let takeaways = quick ? quickTakeaways(quick) : [];
  if (!takeaways.length) takeaways = keyPoints(item.summary, null, tldr);
  if (!takeaways.length) takeaways = item.assessment?.flags ?? [];
  return spokenScript({ tldr, takeaways, opportunities: quick?.opportunities ?? [] });
}

function viewStory(id) {
  const item = S.items.find((i) => i.url === id);
  if (!item) return h('div', { class: 'page' }, emptyState('That story has left the feed', 'It was in an earlier harvest. Save a story to keep it.'));
  const list = sequence.some((i) => i.url === id) ? sequence : itemsIn(S.items, item.category);
  const fresh = (i) => S.items.find((x) => x.url === i.url) ?? i;
  const index = list.findIndex((i) => i.url === id);
  const previous = index > 0 ? fresh(list[index - 1]) : null;
  const next = index >= 0 && index + 1 < list.length ? fresh(list[index + 1]) : null;
  const st = storyState(id);
  loadStory(item, next);

  const analysis = st.critique ? parseStructure(st.critique) : null;
  const quick = storyParts(item, st);
  const reading = reader.isActive && reader.currentItemID === id;

  const move = (target) => {
    if (!target) return;
    if (reading) reader.jump(target.url);
    sequence = list;
    location.hash = itemHref(target);
  };

  const runCritique = async () => {
    st.critiquing = true; st.error = null; render();
    try { const r = await api('/api/item/analyze', { id }); st.critique = r.text; st.by = r.by; }
    catch (e) { st.error = e.message; }
    st.critiquing = false;
    if (stillOn(item)) render();
  };

  const runCouncil = async () => {
    st.convening = true; st.error = null; st.council = []; st.ruling = null; render();
    try {
      const r = await request('/api/item/council', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ id }) });
      if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error ?? 'The council could not meet.');
      const decoder = new TextDecoderStream();
      let buffer = '';
      for await (const chunk of r.body.pipeThrough(decoder)) {
        buffer += chunk;
        const lines = buffer.split('\n');
        buffer = lines.pop();
        for (const line of lines) {
          const e = JSON.parse(line);
          if (e.turn) st.council.push(e.turn);
          if (e.ruling) st.ruling = e.ruling;
          if (e.error) st.error = e.error;
          if (stillOn(item)) render();
        }
      }
    } catch (e) { st.error = e.message; }
    st.convening = false;
    if (stillOn(item)) render();
  };

  const listen = () => {
    const here = spokenScript(analysis ?? quick);
    reader.play(index < 0 ? [item] : list.map(fresh), Math.max(0, index), (it) => (it.url === id ? here : scriptFor(it)));
  };

  const action = (title, iconName, onclick, disabled = false) => h('button', { class: 'action', onclick, disabled }, icon(iconName, 20), h('span', {}, title));
  const seats = Object.keys(PROVIDERS).filter(isOnPlan);

  return h('div', { class: 'page reading' },
    h('div', { class: 'story-bar' },
      h('button', { class: 'text-btn', onclick: () => history.length > 1 ? history.back() : (location.hash = `#/${CATEGORIES[item.category].section}`) }, icon('left', 15), CATEGORIES[item.category].title),
      h('div', { class: 'inline-actions' }, saveButton(item))),
    h('header', { class: 'story-head' },
      itemEyebrow(item),
      h('h1', { class: 'display' }, item.title),
      h('p', { class: 'sub' }, [item.author ? `By ${item.author}` : null, item.date ? new Date(item.date).toLocaleDateString('en-US', { month: 'long', day: 'numeric', year: 'numeric' }) : null, item.tractionLabel].filter(Boolean).join(' · ')),
      h('div', { class: 'found-by' }, h('span', { class: 'caption tertiary' }, `Found by the ${AGENTS[item.agent].name}`),
        h('a', { class: 'btn accent small', href: item.url, target: '_blank', rel: 'noopener noreferrer' }, 'Read the source', icon('link', 14))),
      item.tags.length ? h('p', { class: 'caption muted' }, item.tags.join('  ·  ')) : null),
    h('hr'),
    h('div', { class: 'actions' },
      action(st.critiquing ? 'Analyzing…' : st.critique ? 'Re-analyze' : 'Analyze', 'glasses', runCritique, st.critiquing),
      action(st.convening ? 'In session…' : 'Council', 'people', runCouncil, st.convening),
      reader.supported ? action(reading ? 'Stop' : 'Listen', reading ? 'stop' : 'speaker', () => (reading ? reader.stop() : listen())) : null),
    st.error ? h('p', { class: 'red callout', role: 'alert' }, st.error) : null,
    st.critiquing ? spinner('Writing a detailed analysis…') : null,
    analysis && st.by ? eyebrow(`Analysis by ${st.by}`) : !st.critique ? eyebrow('Quick read · tap Analyze for the full analysis with math') : null,
    st.critique && !analysis ? h('div', { class: 'serif' }, markdown(st.critique)) : structured({
      ...(analysis ?? quick),
      opportunitiesLoading: !analysis && st.ideasLoading && !quick.opportunities.length,
      header: [item.assessment ? signalMeter(item.assessment) : null, keyFiguresView(st.paper?.figures ?? [])],
    }),
    st.convening || st.council.length ? h('section', { class: 'council' }, sectionRule('The Frontier Council'),
      seats.map((p) => {
        const t = st.council.find((x) => x.provider === p);
        return h('div', { class: 'seat' }, h('div', { class: 'seat-name' }, eyebrow(PROVIDERS[p].seat.title, 'strong'), eyebrow(`· ${PROVIDERS[p].family}`)),
          t ? (t.failed ? h('p', { class: 'red callout' }, t.text) : h('div', { class: 'serif' }, markdown(t.text))) : spinner('Deliberating…'));
      }),
      st.ruling ? h('div', { class: 'ruling' }, eyebrow('The ruling', 'accent'), structuredText(st.ruling))
        : st.convening && st.council.length === seats.length ? spinner('The moderator is ruling…') : null) : null,
    index >= 0 && list.length > 1 ? h('div', { class: 'pager' },
      h('button', { class: 'btn', disabled: !previous, onclick: () => move(previous) }, icon('left', 15), 'Previous'),
      h('span', { class: 'caption mono muted' }, `${index + 1} of ${list.length}`),
      h('button', { class: 'btn', disabled: !next, onclick: () => move(next) }, 'Next', icon('right', 15))) : null);
}

function keyFiguresView(figures) {
  if (!figures.length) return null;
  return h('div', { class: 'figures' }, eyebrow('Key figures', 'accent'), figures.map((f) => h('figure', {},
    h('button', { class: 'figure-btn', 'aria-label': `Enlarge: ${f.caption.slice(0, 60)}`, onclick: () => openSheet(h('div', { class: 'sheet-body' },
      h('img', { class: 'figure-img', src: f.url, alt: f.caption, referrerpolicy: 'no-referrer' }), h('p', { class: 'callout' }, f.caption))) },
    h('img', { class: 'figure-img', src: f.url, alt: f.caption, loading: 'lazy', referrerpolicy: 'no-referrer' })),
    h('figcaption', { class: 'caption muted clamp4' }, f.caption))));
}

// MARK: Brainstorm

const STARTERS = [
  "What's the most important thing in today's frontier, and is it overhyped?",
  'What should an AI researcher build this week?',
  'Is scaling still the main driver of progress? Everyone weigh in.',
  'Debate: will small specialized models beat frontier models for most companies?',
];

const brainstormUI = { draft: '', showTranscript: false, showKeyboard: false, options: false };

function bubble(m) {
  if (m.speaker === 'user') return h('div', { class: 'bubble-user' }, h('p', {}, m.text));
  const p = PANELISTS.find((x) => x.id === m.speaker);
  return h('div', { class: 'bubble-agent' }, h('span', { class: 'badge', style: { '--agent': agentColor(p.agent) } }, p.name[0]),
    h('div', {}, h('div', { class: 'bubble-head' }, h('strong', {}, m.isSummary ? `${p.name} · wrap-up` : p.name), m.model ? h('span', { class: 'caption tertiary' }, m.model) : null),
      m.isSummary ? structuredText(m.text) : h('p', { class: 'serif' }, inline(m.text))));
}

function roomStatus() {
  const ph = room.phase;
  if (ph.kind === 'thinking') return spinner(`${ph.name} is thinking…`);
  if (ph.kind === 'speaking') return h('p', { class: 'callout muted' }, `${ph.name} is speaking · tap the mic to interrupt`);
  if (ph.kind === 'listening') return h('p', { class: 'callout accent-text' }, room.liveCaption ? `“${room.liveCaption}”` : 'Listening…');
  return room.error ? h('p', { class: 'callout red', role: 'alert' }, room.error) : null;
}

function panelStrip() {
  return h('div', { class: 'panel-strip' }, PANELISTS.map((p) => {
    const on = room.members.has(p.id);
    const busy = room.phase.name === p.name;
    return h('button', { class: `panel-chip${on ? ' on' : ''}`, style: { '--agent': agentColor(p.agent) }, 'aria-pressed': String(on), 'aria-label': `${p.name}, ${on ? 'on the panel' : 'off the panel'}`, onclick: () => room.toggleMember(p.id) },
      h('span', { class: `badge small${busy ? ' pulse' : ''}` }, p.name[0]),
      h('span', { class: 'chip-text' }, h('strong', {}, p.name), h('span', {}, isOnPlan(p.provider) ? PROVIDERS[p.provider].family : 'Fallback')));
  }));
}

function brainstormOptions() {
  const toggle = (label, key, storageKey) => h('label', { class: 'check' }, h('input', { type: 'checkbox', checked: room[key], onchange: (e) => room.setOption(key, storageKey, e.target.checked) }), label);
  return h('div', { class: 'options-menu' },
    toggle('Read replies aloud', 'speakReplies', 'brainstorm.speak'),
    toggle('Hands-free voice', 'handsFree', 'brainstorm.handsFree'),
    toggle("Use today's frontier as context", 'useFrontierContext'),
    h('div', { class: 'inline-actions' },
      h('button', { class: 'btn small', disabled: !room.messages.length, onclick: () => room.wrapUp() }, 'Wrap up'),
      h('button', { class: 'btn small danger', onclick: () => room.reset() }, 'New session')));
}

function viewBrainstorm() {
  const sendDraft = () => { const t = brainstormUI.draft; brainstormUI.draft = ''; room.send(t); };
  const modeTabs = h('div', { class: 'segmented', role: 'group', 'aria-label': 'Mode' },
    [['chat', 'Group chat', 'brainstorm'], ['video', 'Video meeting', 'video']].map(([id, label, ic]) =>
      h('button', { class: room.mode === id ? 'on' : '', 'aria-pressed': String(room.mode === id), onclick: () => room.setOption('mode', 'brainstorm.mode', id) }, icon(ic, 16), label)));

  const header = h('div', { class: 'brainstorm-head' }, h('div', { class: 'mode-row' }, modeTabs,
    h('button', { class: `icon-btn${brainstormUI.options ? ' on' : ''}`, 'aria-label': 'Options', 'aria-expanded': String(brainstormUI.options), onclick: () => { brainstormUI.options = !brainstormUI.options; render(); } }, icon('options'))),
    brainstormUI.options ? brainstormOptions() : null, panelStrip());

  if (room.mode === 'video') return h('div', { class: 'brainstorm video' }, header, meetingView(sendDraft));

  const composerInput = h('textarea', { class: 'field composer-input', rows: 1, placeholder: 'Ask the panel…', 'aria-label': 'Ask the panel', value: brainstormUI.draft,
    oninput: (e) => { brainstormUI.draft = e.target.value; },
    onkeydown: (e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendDraft(); } } });
  return h('div', { class: 'brainstorm' }, header,
    h('div', { class: 'transcript' }, h('div', { class: 'transcript-inner' },
      room.messages.length ? null : h('div', { class: 'stack' }, eyebrow('Brainstorm', 'accent'), h('h1', { class: 'display' }, 'Put a question to the whole panel.'),
        h('p', { class: 'serif muted' }, 'Name an agent to ask them directly, say “everyone” for every view, or tap the mic and talk. Open the options for Wrap up, which writes a summary.'),
        STARTERS.map((s) => h('button', { class: 'starter', onclick: () => room.send(s) }, s))),
      room.messages.map(bubble), roomStatus())),
    h('div', { class: 'composer' }, composerInput,
      h('button', { class: `round-btn${room.phase.kind === 'listening' ? ' live' : ''}`, 'aria-label': room.phase.kind === 'listening' ? 'Stop listening' : 'Talk to the panel', onclick: () => { reader.stop(); room.micTapped(); } }, icon('mic', 20)),
      h('button', { class: 'round-btn accent', 'aria-label': 'Send', onclick: sendDraft }, icon('send', 20))));
}

/** Talking faces in a meeting grid, with captions and a dock underneath. The stage lives across re-renders. */
function meetingView(sendDraft) {
  if (!meetingBuilt) meetingBuilt = buildStage();
  const ph = room.phase;
  const m = room.captionMessage;
  const dockBtn = (title, ic, on, onclick, disabled = false) => h('button', { class: `dock-btn${on ? ' on' : ''}`, onclick, disabled, 'aria-pressed': String(Boolean(on)) }, h('span', { class: 'dock-round' }, icon(ic, 19)), h('span', { class: 'caption' }, title));
  const statusText = ph.kind === 'listening' ? "I'm listening… take your time" : ph.kind === 'thinking' ? `${ph.name} is thinking…` : ph.kind === 'speaking' ? 'Tap a face or Stop to jump in' : 'Tap the mic to talk';
  return [
    h('div', { class: 'stage-wrap' }, meetingBuilt.holder,
      brainstormUI.showTranscript ? h('div', { class: 'meeting-transcript' }, room.messages.length ? room.messages.map(bubble) : h('p', { class: 'muted callout' }, 'Nothing said yet.')) : null),
    h('div', { class: 'captions', 'aria-live': 'polite' },
      m ? h('p', {}, h('strong', { class: 'accent-text' }, `${m.name}  `), m.isSummary ? 'Wrap-up ready. Open the transcript to read it.' : m.text.replace(/\*\*|`/g, '')) : null,
      ph.kind === 'listening' && room.liveCaption ? h('p', { class: 'callout muted' }, `“${room.liveCaption}”`) : room.error && ph.kind === 'idle' ? h('p', { class: 'callout red' }, room.error) : null),
    brainstormUI.showKeyboard ? h('div', { class: 'composer flush' },
      h('input', { class: 'field', placeholder: 'Type a message', 'aria-label': 'Type a message', value: brainstormUI.draft, oninput: (e) => { brainstormUI.draft = e.target.value; }, onkeydown: (e) => { if (e.key === 'Enter') sendDraft(); } }),
      h('button', { class: 'round-btn accent', 'aria-label': 'Send', onclick: sendDraft }, icon('send', 20))) : null,
    h('div', { class: 'dock' },
      dockBtn('Transcript', 'text', brainstormUI.showTranscript, () => { brainstormUI.showTranscript = !brainstormUI.showTranscript; render(); }),
      dockBtn('Type', 'keyboard', brainstormUI.showKeyboard, () => { brainstormUI.showKeyboard = !brainstormUI.showKeyboard; render(); }),
      h('button', { class: `mic${ph.kind === 'listening' ? ' live' : ''}`, 'aria-label': 'Microphone', onclick: () => { reader.stop(); room.micTapped(); } }, icon('mic', 30)),
      dockBtn('Stop', 'stop', false, () => room.stopTapped(), ph.kind === 'idle'),
      dockBtn('Progress', 'chart', false, showProgress)),
    h('p', { class: 'caption muted dock-status' }, statusText)];
}

function showProgress() {
  const words = (list) => list.reduce((n, m) => n + m.text.split(/\s+/).filter(Boolean).length, 0);
  const you = room.messages.filter((m) => m.speaker === 'user');
  openSheet(h('div', { class: 'sheet-body' }, h('h2', { class: 'display' }, 'Progress'),
    h('div', { class: 'progress-row' }, h('strong', {}, 'You'), h('span', { class: 'mono muted' }, `${you.length} turns · ${words(you)} words`)),
    PANELISTS.map((p) => { const said = room.messages.filter((m) => m.speaker === p.id); return h('div', { class: 'progress-row' }, h('span', {}, p.name), h('span', { class: 'mono muted' }, `${said.length} turns · ${words(said)} words`)); })));
}

function buildStage() {
  const frame = h('iframe', { src: '/stage.html', title: 'Video meeting', class: 'stage' });
  const holder = h('div', { class: 'stage-holder', onclick: () => { if (room.phase.kind === 'speaking') room.micTapped(); } }, frame);
  const faces = {};
  let lastPanel = null;
  let last = performance.now();
  let ready = false;

  const syncPanel = () => {
    const stage = frame.contentWindow?.SooStage;
    if (!stage || !ready) return;
    const payload = room.panel.map((p) => ({ id: p.id, name: p.name, avatar: faces[p.id]
      ? { kind: 'photo', src: `/portraits/${p.id}.jpg`, ...faces[p.id] } : { kind: 'illustrated', style: {} } }));
    const json = JSON.stringify(payload);
    if (json !== lastPanel) { lastPanel = json; stage.setAgents(payload); }
  };

  // Face landmarks for each portrait: kept after the first detection, found in the browser otherwise.
  const loadFaces = async () => {
    for (const p of PANELISTS) {
      const cached = store.get(`face.${p.id}`, null);
      if (cached) { faces[p.id] = cached; continue; }
      try {
        const blob = await (await fetch(`/portraits/${p.id}.jpg`)).blob();
        const dataUrl = await new Promise((resolve) => { const r = new FileReader(); r.onload = () => resolve(r.result); r.readAsDataURL(blob); });
        const f = await frame.contentWindow.SooStage.detectFace(dataUrl);
        faces[p.id] = { width: f.width, height: f.height, landmarks: f.landmarks };
        store.set(`face.${p.id}`, faces[p.id]);
        syncPanel();
      } catch (e) { console.warn(`No face landmarks for ${p.id}`, e); }
    }
    syncPanel();
  };

  frame.addEventListener('load', () => { ready = true; lastPanel = null; syncPanel(); loadFaces(); });

  const tick = (now) => {
    const dt = Math.min(0.05, (now - last) / 1000);
    last = now;
    const stage = frame.contentWindow?.SooStage;
    if (stage && frame.isConnected) {
      syncPanel();
      const ph = room.phase;
      const thinking = ph.kind === 'thinking' ? PANELISTS.find((p) => p.name === ph.name)?.id ?? null : null;
      stage.frame({ speaking: room.voice.speakingPanelist, thinking, phase: ph.kind === 'listening' ? 'listening' : ph.kind === 'speaking' ? 'speaking' : 'idle', mouth: { ...room.voice.mouth(dt) } });
    }
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
  return { holder, frame };
}

// MARK: Settings

function viewSettings() {
  const section = (title, ...children) => h('section', { class: 'settings-section' }, h('h2', { class: 'eyebrow strong' }, title), ...children);
  const segmented = (label, options, value, onchange) => h('div', { class: 'setting-row' }, h('span', {}, label), h('div', { class: 'segmented', role: 'group', 'aria-label': label },
    options.map(([id, text]) => h('button', { class: value === id ? 'on' : '', 'aria-pressed': String(value === id), onclick: () => onchange(id) }, text))));
  const select = (label, options, value, onchange) => h('label', { class: 'setting-row' }, h('span', {}, label), h('select', { class: 'field auto', onchange: (e) => onchange(e.target.value) },
    options.map(([id, text]) => h('option', { value: id, selected: id === value }, text))));
  const setLook = (k, v) => { look[k] = v; store.set('appearance', look); applyAppearance(); render(); };

  const appearance = section('Appearance',
    select('Text size', Object.entries(TEXT_SIZES).map(([id, [text]]) => [id, text]), look.textSize, (v) => setLook('textSize', v)),
    segmented('Theme', ['system', 'light', 'dark'].map((t) => [t, capitalize(t)]), look.theme, (v) => setLook('theme', v)),
    segmented('Accent colour', ['ink', 'teal', 'gold', 'rose'].map((t) => [t, capitalize(t)]), look.accent, (v) => setLook('accent', v)),
    segmented('Reading font', [['serif', 'Serif'], ['sans', 'Sans serif']], look.font, (v) => setLook('font', v)),
    h('div', { class: 'preview' }, eyebrow('Preview', 'accent'), h('div', { class: 'headline' }, 'Intrinsic Distribution Matching'),
      h('p', { class: 'serif muted' }, 'One-step and few-step text-to-image generation must accurately render the details in the prompt.')));

  const provider = (p) => {
    const info = PROVIDERS[p];
    const c = S.providers[p];
    const set = (patch) => api('/api/settings', { providers: { [p]: patch } });
    const result = h('span', { class: 'caption muted' });
    const test = h('button', { class: 'btn small', disabled: !c.configured, onclick: async (e) => {
      e.target.disabled = true; result.textContent = 'Testing…';
      try { const r = await api('/api/provider/test', { provider: p }); result.textContent = `✓ ${r.text.slice(0, 40)}`; }
      catch (err) { result.textContent = `✗ ${err.message}`; }
      e.target.disabled = false;
    } }, 'Test connection');
    return section(`${info.name} · ${info.family}`,
      segmented('Access', [['subscription', 'Subscription'], ['apiKey', 'API key']], c.mode, (mode) => set({ mode })),
      c.mode === 'subscription' ? [
        h('div', { class: 'setting-row' }, h('span', {}, `${info.cliName} CLI`), h('code', { class: `caption clamp1 ${c.cliPath ? 'muted' : 'red'}` }, c.cliPath ?? 'Not found')),
        select('Model', info.cliModels.map((m) => [m, m || 'CLI default']), c.cliModel, (cliModel) => set({ cliModel })),
        h('p', { class: 'caption muted' }, `Uses your ${info.planName} plan via ${info.cliName} on the computer running this server. Sign in once in Terminal with “${info.loginCommand}”. Plan usage limits apply, with no per-token charges.`),
      ] : [
        h('label', { class: 'setting-row' }, h('span', {}, 'API key'), h('input', { class: 'field', type: 'password', autocomplete: 'off', placeholder: c.hasKey ? 'Saved. Type to replace.' : 'Paste your key', onchange: (e) => set({ key: e.target.value }) })),
        h('label', { class: 'setting-row' }, h('span', {}, 'Model'), h('input', { class: 'field', list: `models-${p}`, value: c.model, autocomplete: 'off', onchange: (e) => set({ model: e.target.value }) }), h('datalist', { id: `models-${p}` }, info.suggestedModels.map((m) => h('option', { value: m })))),
        h('p', { class: 'caption muted' }, `Metered API billing. Get a key at ${info.keyHelp}. Keys stay on the server and are never sent back to the browser.`),
      ],
      h('div', { class: 'setting-row start' }, test, result));
  };

  const familyOptions = Object.keys(PROVIDERS).map((p) => [p, PROVIDERS[p].family]);
  const roles = section('Roles',
    select('Synthesizer & moderator', familyOptions, S.synthesizerProvider, (v) => api('/api/settings', { synthesizerProvider: v })),
    select('Story analysis (Analyze)', familyOptions, S.skepticProvider, (v) => api('/api/settings', { skepticProvider: v })));

  const agents = section('Agents',
    h('p', { class: 'caption muted' }, 'The harvesters fan out in parallel. The Skeptic cross-examines everything they bring back, and the Synthesizer turns the best of it into your brief.'),
    Object.keys(AGENTS).map((a) => h('label', { class: 'setting-row' }, h('span', { class: 'agent-line' }, h('span', { class: 'badge small', style: { '--agent': agentColor(a) } }, AGENTS[a].name[0]), h('span', {}, h('strong', {}, AGENTS[a].name), h('span', { class: 'caption muted block' }, AGENTS[a].role))),
      h('input', { type: 'checkbox', class: 'switch', 'aria-label': AGENTS[a].name, checked: !S.agentsOff.includes(a), onchange: (e) => {
        const off = new Set(S.agentsOff);
        if (e.target.checked) off.delete(a); else off.add(a);
        api('/api/settings', { agentsOff: [...off] });
      } }))));

  let newRole = 'researcher';
  const handles = h('textarea', { class: 'field', rows: 2, placeholder: '@handle, x.com/handle, or a pasted list', 'aria-label': 'Handles to add', spellcheck: 'false' });
  const addVoices = () => {
    const have = new Set(S.voices.map((v) => v.handle.toLowerCase()));
    const added = [];
    for (const raw of handles.value.split(/[\s,;]+/)) {
      const h1 = raw.replace(/^.*(?:x\.com|twitter\.com)\//, '').replace(/^[@/ ]+/, '').split('/')[0];
      if (/^\w{1,15}$/.test(h1) && !have.has(h1.toLowerCase())) { have.add(h1.toLowerCase()); added.push({ handle: h1, role: newRole }); }
    }
    if (added.length) api('/api/settings', { voices: [...S.voices, ...added] });
    handles.value = '';
  };
  const voiceSection = section(`Voices on X · ${S.voices.length}`,
    h('p', { class: 'caption muted' }, 'The Listener asks Grok, on your SuperGrok plan, what these people said about AI this week. Paste the handles you follow here.'),
    handles,
    h('div', { class: 'setting-row start' },
      h('select', { class: 'field auto', 'aria-label': 'Role', onchange: (e) => { newRole = e.target.value; } }, VOICE_ROLES.map((r) => h('option', { value: r, selected: r === newRole }, capitalize(r)))),
      h('button', { class: 'btn small', onclick: addVoices }, 'Add'),
      h('button', { class: 'text-btn', onclick: () => api('/api/settings', { resetVoices: true }) }, 'Reset to starters')),
    VOICE_ROLES.map((r) => {
      const people = S.voices.filter((v) => v.role === r);
      return people.length ? h('div', { class: 'voice-group' }, eyebrow(`${capitalize(r)}s · ${people.length}`), h('div', { class: 'voice-chips' }, people.map((v) => h('span', { class: 'voice-chip' },
        h('a', { href: `https://x.com/${v.handle}`, target: '_blank', rel: 'noopener noreferrer' }, `@${v.handle}`),
        h('button', { 'aria-label': `Remove @${v.handle}`, onclick: () => api('/api/settings', { voices: S.voices.filter((x) => x !== v) }) }, icon('close', 12)))))) : null;
    }));

  return h('div', { class: 'page settings' }, h('h1', { class: 'display' }, 'Settings'), appearance, Object.keys(PROVIDERS).map(provider), roles, agents, voiceSection,
    section('About the web version', h('p', { class: 'caption muted' }, 'This server runs the crew and refreshes at 6:00 am Pacific while it is running. On-device Gemma and the Mac bridge belong to the native apps: here, models run on the computer running this server.')));
}

// MARK: Reader bar

function renderReaderBar() {
  const bar = document.getElementById('reader-bar');
  if (!reader.isActive) return bar.replaceChildren();
  bar.replaceChildren(h('div', { class: 'reader' },
    h('div', { class: 'reader-text' }, eyebrow(reader.isPaused ? 'Paused' : reader.autoAdvance ? 'Reading · continues to next' : 'Reading aloud'), h('strong', { class: 'clamp1' }, reader.title)),
    h('select', { class: 'speed', 'aria-label': 'Speed', onchange: (e) => reader.setSpeed(Number(e.target.value)) }, SPEEDS.map((s) => h('option', { value: s, selected: s === reader.speed }, `${s}×`))),
    h('label', { class: 'check caption', title: 'Continue to next story' }, h('input', { type: 'checkbox', checked: reader.autoAdvance, onchange: (e) => reader.setAutoAdvance(e.target.checked) }), 'Next'),
    h('button', { class: 'icon-btn', 'aria-label': reader.isPaused ? 'Resume' : 'Pause', onclick: () => reader.togglePause() }, icon(reader.isPaused ? 'play' : 'pause')),
    h('button', { class: 'icon-btn', 'aria-label': 'Skip to the next story', onclick: () => reader.skip() }, icon('next')),
    h('button', { class: 'icon-btn', 'aria-label': 'Stop reading', onclick: () => reader.stop() }, icon('close'))));
}

// MARK: Rendering

let lastRoute = null;
let pendingRender = false;

function render() {
  if (!S) return;
  // Don't pull a field out from under someone typing; catch up when they leave it.
  const focus = document.activeElement;
  if (focus && main.contains(focus) && focus.matches('input:not([type=checkbox]), textarea, select') && lastRoute === location.hash) {
    pendingRender = true;
    return;
  }
  pendingRender = false;
  const r = route();
  const changed = lastRoute !== location.hash;
  if (changed && lastRoute != null) scrollByRoute.set(lastRoute, scrollY);
  const keep = changed ? (scrollByRoute.get(location.hash) ?? 0) : scrollY;
  lastRoute = location.hash;

  document.body.dataset.route = r.name;
  const title = TABS.find((t) => t[0] === r.name)?.[1];
  document.title = title ? `SooFrontier ${title}` : 'SooFrontier';
  renderChrome();
  const transcriptEl = main.querySelector('.transcript');
  const wasAtBottom = !transcriptEl || transcriptEl.scrollHeight - transcriptEl.scrollTop - transcriptEl.clientHeight < 80;
  const previousTop = transcriptEl?.scrollTop;

  let view;
  if (SECTIONS[r.name]) view = viewDesk(r.name, r.arg);
  else if (r.name === 'item') view = viewStory(decodeURIComponent(r.arg));
  else if (r.name === 'saved') view = viewSaved();
  else if (r.name === 'brainstorm') view = viewBrainstorm();
  else if (r.name === 'settings') view = viewSettings();
  else view = viewBrief();

  // Keep the live stage in place instead of reloading it on every update.
  main.replaceChildren(view);
  scrollTo(0, keep);
  const nextTranscript = main.querySelector('.transcript');
  if (nextTranscript) nextTranscript.scrollTop = wasAtBottom ? nextTranscript.scrollHeight : previousTop;
}

document.addEventListener('focusout', () => setTimeout(() => { if (pendingRender) render(); }, 0));

addEventListener('hashchange', () => {
  if (route().name !== 'brainstorm') { room.interrupt(); room.voice.stopListening(); }
  sheet.replaceChildren();
  render();
});

// Previous / Next from the keyboard on a story.
addEventListener('keydown', (e) => {
  if (route().name !== 'item' || !(e.metaKey || e.ctrlKey) || !['ArrowUp', 'ArrowDown'].includes(e.key)) return;
  const id = decodeURIComponent(route().arg);
  const i = sequence.findIndex((x) => x.url === id);
  const target = sequence[i + (e.key === 'ArrowDown' ? 1 : -1)];
  if (i >= 0 && target) { e.preventDefault(); location.hash = itemHref(target); }
});

let lastReaderItem = null;
reader.onChange = () => {
  renderReaderBar();
  // Follow the reader as it moves through the list.
  const id = reader.currentItemID;
  if (id !== lastReaderItem) {
    lastReaderItem = id;
    if (route().name === 'item') {
      if (id && decodeURIComponent(route().arg) !== id && sequence.some((x) => x.url === id)) location.hash = itemHref({ url: id });
      else render();
    } else if (route().name === 'brief') render();
  } else if (['brief'].includes(route().name)) render();
};
room.onChange = () => { if (route().name === 'brainstorm') render(); };

let fetching = null;
async function loadState() {
  if (fetching) { fetching.again = true; return; }
  fetching = { again: false };
  try { S = await api('/api/state'); render(); }
  finally {
    const again = fetching.again;
    fetching = null;
    if (again) loadState();
  }
}

function connect() {
  const events = new EventSource('/api/events');
  events.addEventListener('changed', loadState);
  events.addEventListener('status', (e) => {
    if (!S) return;
    Object.assign(S, JSON.parse(e.data));
    if (route().name === 'brief' || route().name === '') {
      // Keep the crew live without rebuilding the page for every progress line.
      const crew = document.querySelectorAll('.crew');
      if (crew.length) crew.forEach((c) => c.replaceChildren(...crewCards()));
    }
    renderChrome();
  });
  events.addEventListener('open', loadState);
}

applyAppearance();
loadState().catch((e) => { main.replaceChildren(h('div', { class: 'page' }, emptyState('Can’t reach the SooFrontier server', e.message))); });
connect();
