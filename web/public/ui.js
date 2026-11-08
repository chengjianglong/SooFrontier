// Small DOM helpers. Feed and model text only ever reaches the page as text nodes.

export function h(tag, props = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props ?? {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2).toLowerCase(), v);
    else if (k === 'style' && typeof v === 'object') for (const [p, x] of Object.entries(v)) el.style.setProperty(p, x);
    else if (k === 'value') el.value = v;
    else if (v === true) el.setAttribute(k, '');
    else el.setAttribute(k, v);
  }
  el.append(...children.flat(Infinity).filter((c) => c != null && c !== false));
  return el;
}

const ICONS = {
  brief: 'M4 5h13v14H6a2 2 0 0 1-2-2zM17 9h3v8a2 2 0 0 1-2 2h-1M7 9h7M7 12h7M7 15h4',
  research: 'M9 3h6M10 3v6l-5 9a2 2 0 0 0 2 3h10a2 2 0 0 0 2-3l-5-9V3M7.5 15h9',
  productions: 'M12 3l8 4.5v9L12 21l-8-4.5v-9zM4 7.5l8 4.5 8-4.5M12 12v9',
  opinions: 'M4 5h16v11H9l-5 4zM8 10h.01M12 10h.01M16 10h.01',
  brainstorm: 'M3 4h13v9H8l-5 4zM20 9h1v11l-4-3h-7v-1',
  settings: 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-2.9 1.2V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-2.9-1.2l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0-1.2-2.9H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.2-2.9l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.9.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 2.9 1.2l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.9V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z',
  refresh: 'M20 11a8 8 0 1 0-2.3 6M20 4v7h-7',
  bookmark: 'M6 3h12v18l-6-4-6 4z',
  speaker: 'M4 9v6h4l5 4V5L8 9zM16 9a4 4 0 0 1 0 6M18.5 6.5a8 8 0 0 1 0 11',
  stop: 'M6 6h12v12H6z',
  play: 'M7 4l13 8-13 8z',
  pause: 'M7 4h3v16H7zM14 4h3v16h-3z',
  next: 'M5 4l11 8-11 8zM19 4v16',
  close: 'M5 5l14 14M19 5L5 19',
  glasses: 'M3 13a4 4 0 1 0 8 0 4 4 0 0 0-8 0zM13 13a4 4 0 1 0 8 0 4 4 0 0 0-8 0zM11 12c.7-.6 1.3-.6 2 0M3 13l2-7M21 13l-2-7',
  people: 'M9 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM3 20c0-3.3 2.7-6 6-6s6 2.700 6 6M16 11a3 3 0 0 0 0-6M17 14c2.400.4 4 2.800 4 6',
  link: 'M7 17L17 7M8 7h9v9',
  left: 'M19 12H5M11 6l-6 6 6 6',
  right: 'M5 12h14M13 6l6 6-6 6',
  mic: 'M12 3a3 3 0 0 0-3 3v6a3 3 0 0 0 6 0V6a3 3 0 0 0-3-3zM5 11a7 7 0 0 0 14 0M12 18v3',
  send: 'M12 19V5M6 11l6-6 6 6',
  chart: 'M5 20V10M12 20V4M19 20v-7',
  text: 'M4 5h16v11H9l-5 4zM8 9h8M8 12h5',
  keyboard: 'M3 6h18v12H3zM7 10h.01M11 10h.01M15 10h.01M7 14h10',
  bulb: 'M9 18h6M10 21h4M12 3a6 6 0 0 0-4 10.500c.8.800 1 1.500 1 2.500h6c0-1 .2-1.700 1-2.500A6 6 0 0 0 12 3z',
  video: 'M3 6h12v12H3zM15 10l6-3v10l-6-3z',
  options: 'M4 7h10M18 7h2M4 17h2M10 17h10M16 5v4M8 15v4',
};

export function icon(name, size = 18) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('width', size);
  svg.setAttribute('height', size);
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '1.7');
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  svg.setAttribute('aria-hidden', 'true');
  const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  path.setAttribute('d', ICONS[name] ?? '');
  svg.append(path);
  return svg;
}

const safeLink = (href) => { try { return ['http:', 'https:'].includes(new URL(href).protocol) ? href : null; } catch { return null; } };

/** Inline Markdown (bold, italics, code, links) for a single line. */
export function inline(text) {
  const out = [];
  const re = /\*\*(.+?)\*\*|`([^`]+)`|\[([^\]]+)\]\(([^)\s]+)\)|(?<![\w*])\*([^*\n]+)\*(?![\w*])/g;
  let last = 0;
  for (const m of text.matchAll(re)) {
    if (m.index > last) out.push(text.slice(last, m.index));
    if (m[1] != null) out.push(h('strong', {}, inline(m[1])));
    else if (m[2] != null) out.push(h('code', {}, m[2]));
    else if (m[3] != null) {
      const href = safeLink(m[4]);
      out.push(href ? h('a', { href, target: '_blank', rel: 'noopener noreferrer' }, m[3]) : m[3]);
    } else out.push(h('em', {}, m[5]));
    last = m.index + m[0].length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

/** Lightweight block Markdown: headings, bullets, and paragraphs. */
export function markdown(text) {
  const lines = text.split('\n').map((raw) => {
    const t = raw.trim();
    if (!t) return null;
    if (t.startsWith('#')) return h('h4', {}, inline(t.replace(/^#+\s*/, '')));
    if (/^[-*•] /.test(t)) return h('div', { class: 'md-bullet' }, h('span', { class: 'dash', 'aria-hidden': 'true' }, '—'), h('span', {}, inline(t.slice(2))));
    return h('p', {}, inline(t));
  });
  return h('div', { class: 'md' }, lines);
}

const relative = new Intl.RelativeTimeFormat('en', { numeric: 'auto' });
export function timeAgo(iso) {
  const seconds = (Date.parse(iso) - Date.now()) / 1000;
  for (const [unit, size] of [['year', 31536000], ['month', 2592000], ['week', 604800], ['day', 86400], ['hour', 3600], ['minute', 60]]) {
    if (Math.abs(seconds) >= size) return relative.format(Math.round(seconds / size), unit);
  }
  return 'just now';
}

export const store = {
  get(key, fallback) { try { const v = localStorage.getItem(key); return v == null ? fallback : JSON.parse(v); } catch { return fallback; } },
  set(key, value) { try { localStorage.setItem(key, JSON.stringify(value)); } catch {} },
};

/** fetch, with a useful message when the server can't be reached instead of the browser's "Failed to fetch". */
export async function request(path, options) {
  try { return await fetch(path, options); }
  catch (e) {
    if (e.name === 'AbortError') throw e;
    throw new Error("Can't reach the SooFrontier server. Check that it's still running (node server.mjs), then try again.");
  }
}

export async function api(path, body, options = {}) {
  const r = await request(path, body === undefined ? options : { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body), ...options });
  const json = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(json.error ?? `Request failed (${r.status})`);
  return json;
}
