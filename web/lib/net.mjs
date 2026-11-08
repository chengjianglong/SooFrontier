// Fetching, feed parsing, and reading pages. Ported from Services/Network.swift, FeedParser.swift and PaperReader.swift.
import { lookup } from 'node:dns/promises';
import { isIP } from 'node:net';

const USER_AGENT = 'SooFrontier/1.0 (AI research reader)';

export async function getResponse(url, timeout = 20_000) {
  const r = await fetch(url, { headers: { 'User-Agent': USER_AGENT }, signal: AbortSignal.timeout(timeout) });
  if (!r.ok) throw new Error(`HTTP ${r.status} from ${new URL(url).host}`);
  return r;
}

export const getText = async (url) => (await getResponse(url)).text();
export const getJSON = async (url) => (await getResponse(url)).json();

// MARK: Text

const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };

function decodeEntities(s) {
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (whole, body) => {
    if (body[0] !== '#') return ENTITIES[body.toLowerCase()] ?? whole;
    const code = body[1].toLowerCase() === 'x' ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
    return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : whole;
  });
}

/** Strips HTML tags and common entities, collapses whitespace. */
export function plain(html, limit = 600) {
  // Feeds often escape their HTML, so decode first and strip the tags that reveals.
  const s = decodeEntities(decodeEntities(html ?? '').replace(/<[^>]+>/g, ' ')).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
  return s.length > limit ? s.slice(0, limit) + '…' : s;
}

export function parseDate(s) {
  if (!s) return null;
  const t = Date.parse(s);
  return Number.isNaN(t) ? null : new Date(t).toISOString();
}

// MARK: RSS 2.0 + Atom

const unwrap = (s) => s.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1');

/** A small tag reader, enough for the well-formed feeds SooFrontier follows. */
export function parseFeed(xml) {
  const entries = [];
  for (const m of xml.matchAll(/<(item|entry)(?:\s[^>]*)?>([\s\S]*?)<\/\1>/g)) {
    const body = m[2];
    const first = (...names) => {
      for (const name of names) {
        const hit = body.match(new RegExp(`<${name}(?:\\s[^>]*)?>([\\s\\S]*?)</${name}>`));
        if (hit) { const v = unwrap(hit[1]).trim(); if (v) return v; }
      }
      return '';
    };
    // Atom: <link href="..." rel="alternate"/>; RSS: <link>...</link>.
    let link = '';
    for (const tag of body.matchAll(/<link\b([^>]*?)\/?>/g)) {
      const href = tag[1].match(/href=["']([^"']+)["']/)?.[1];
      const rel = tag[1].match(/rel=["']([^"']+)["']/)?.[1] ?? 'alternate';
      if (href && (rel === 'alternate' || !link)) link = href;
    }
    if (!link) link = first('link');
    const author = first('name', 'dc:creator') || first('author');
    const categories = [...body.matchAll(/<category\b([^>]*?)(?:\/>|>([\s\S]*?)<\/category>)/g)]
      .map((c) => c[1].match(/term=["']([^"']+)["']/)?.[1] ?? unwrap(c[2] ?? '').trim()).filter(Boolean);
    entries.push({
      title: first('title'), link: decodeEntities(link).trim(), summary: first('summary', 'description', 'content:encoded', 'content'),
      author: plain(author, 120), date: first('pubDate', 'published', 'dc:date', 'updated'), categories,
    });
  }
  return entries;
}

/** Fetches several feeds concurrently; individual failures are skipped. */
export async function fetchFeeds(feeds) {
  const results = await Promise.all(feeds.map(async ([source, url]) => {
    try { return parseFeed(await getText(url)).slice(0, 12).map((entry) => ({ source, entry })); }
    catch { return []; }
  }));
  return results.flat();
}

// MARK: Reading pages

export function arxivID(url) {
  try {
    const u = new URL(url);
    if (!u.hostname.includes('arxiv.org')) return null;
    const parts = u.pathname.split('/').filter(Boolean);
    const i = parts.findIndex((p) => ['abs', 'pdf', 'html'].includes(p));
    return i >= 0 && parts[i + 1] ? parts[i + 1].replace('.pdf', '') : null;
  } catch { return null; }
}

function isPrivateAddress(address) {
  if (address.includes(':')) {
    const a = address.toLowerCase();
    if (a.startsWith('::ffff:')) return isPrivateAddress(a.slice(7));
    return a === '::1' || a === '::' || a.startsWith('fc') || a.startsWith('fd') || a.startsWith('fe8') || a.startsWith('fe9') || a.startsWith('fea') || a.startsWith('feb');
  }
  const [a, b] = address.split('.').map(Number);
  return a === 0 || a === 10 || a === 127 || (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || a >= 224;
}

/** Links come from feeds, so never let one reach this machine or the local network. */
async function assertPublic(url) {
  if (!['http:', 'https:'].includes(url.protocol)) throw new Error('Unsupported link');
  const host = url.hostname.replace(/^\[|\]$/g, '');
  const addresses = isIP(host) ? [{ address: host }] : await lookup(host, { all: true });
  if (addresses.some((a) => isPrivateAddress(a.address))) throw new Error('Link points at a private address');
}

async function fetchPublic(start) {
  let url = new URL(start);
  for (let hop = 0; hop < 5; hop++) {
    await assertPublic(url);
    const r = await fetch(url, { headers: { 'User-Agent': USER_AGENT }, redirect: 'manual', signal: AbortSignal.timeout(20_000) });
    const next = r.status >= 300 && r.status < 400 ? r.headers.get('location') : null;
    if (!next) return { response: r, url };
    url = new URL(next, url);
  }
  throw new Error('Too many redirects');
}

const importance = (caption) => {
  const c = caption.toLowerCase();
  const words = ['pipeline', 'framework', 'architecture', 'overview', 'method', 'approach', 'illustration of', 'workflow'];
  let s = words.filter((w) => c.includes(w)).length * 2;
  const n = parseInt(caption.match(/^(?:Figure|Fig\.)\s*(\d+)/)?.[1] ?? '99', 10);
  if (n <= 3) s += 2; else if (n <= 6) s += 1; else if (n >= 11) s -= 4;
  return s;
};

/** The most informative figures, pipeline and framework diagrams first, in paper order. */
export function keyFigures(figures, limit = 3) {
  const picked = new Set(figures.map((f, i) => ({ f, i, s: importance(f.caption) })).filter((x) => x.s > 0)
    .sort((a, b) => b.s - a.s || a.i - b.i).slice(0, limit).map((x) => x.f));
  return figures.filter((f) => picked.has(f));
}

function parseFigures(html, base) {
  const out = [];
  const seen = new Set();
  for (const m of html.matchAll(/<figure[^>]*>([\s\S]*?)<\/figure>/g)) {
    const src = m[1].match(/<img[^>]*src="([^"]+)"/)?.[1];
    const caption = plain([...m[1].matchAll(/<figcaption[^>]*>([\s\S]*?)<\/figcaption>/g)].at(-1)?.[1] ?? '', 400);
    if (!src || src.startsWith('data:') || !/^(Figure|Fig\.)/.test(caption)) continue;
    let url;
    try { url = new URL(src, base); } catch { continue; }
    if (!['http:', 'https:'].includes(url.protocol) || seen.has(url.href)) continue;
    seen.add(url.href);
    out.push({ url: url.href, caption });
  }
  return out;
}

function bodyText(html, maxChars) {
  let h = html;
  const a = h.indexOf('<article'), b = h.lastIndexOf('</article>');
  if (a >= 0 && b > a) h = h.slice(a, b + 10);
  // arXiv math carries a hidden LaTeX copy of every value; drop it so numbers aren't doubled.
  h = h.replace(/<annotation(-xml)?[^>]*>[\s\S]*?<\/annotation(-xml)?>/gi, '');
  h = h.replace(/<(script|style|nav|header|footer)[^>]*>[\s\S]*?<\/\1>/gi, ' ');
  // Keep paragraph breaks so the model can see section structure.
  h = h.replace(/<\/(p|h[1-6]|li|figcaption|section)>/g, '\n').replace(/<[^>]+>/g, '');
  const text = h.split('\n').map((l) => plain(l, 100_000)).filter((l) => l.length > 2).join('\n');
  return text.length > maxChars ? text.slice(0, maxChars) + '\n[…truncated]' : text;
}

/** Reads arXiv papers through their HTML edition, and other links as plain web pages. */
export async function readPaper(item, maxChars = 45_000) {
  const id = arxivID(item.url);
  try {
    const { response, url } = await fetchPublic(id ? `https://arxiv.org/html/${id}` : item.url);
    if (response.status !== 200) return null;
    const html = await response.text();
    const figures = parseFigures(html, url);
    const text = bodyText(html, maxChars);
    return text.length > 500 || figures.length ? { text, figures } : null;
  } catch { return null; }
}
