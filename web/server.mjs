// SooFrontier for the browser: serves the app and runs the agent crew.
//   node server.mjs        then open http://localhost:5180
// By default it only answers this machine. See README.md for reaching it from other devices.
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { createReadStream, statSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import http from 'node:http';
import { extname, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PROVIDERS, SECTIONS } from './public/shared.js';
import { FrontierStore } from './lib/store.mjs';

const ROOT = fileURLToPath(new URL('.', import.meta.url));
const PUBLIC = join(ROOT, 'public');
// The video meeting's stage is the native app's own, served as is.
const NATIVE = join(ROOT, '..', 'SooFrontier', 'Resources');
const STAGE = join(NATIVE, 'Stage');
const PORT = Number(process.env.PORT ?? 5180);
const HOST = process.env.HOST ?? '127.0.0.1';
const LOOPBACK = ['127.0.0.1', '::1', 'localhost'].includes(HOST);

// Anyone who reaches this server can spend your plan, so anything beyond this machine needs the access code.
const ACCESS_CODE = LOOPBACK ? null : process.env.SOOFRONTIER_CODE || randomBytes(12).toString('base64url');
const sessionToken = randomBytes(32).toString('base64url');
const sha = (s) => createHash('sha256').update(s).digest();

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.json': 'application/json', '.png': 'image/png', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml', '.wasm': 'application/wasm', '.task': 'application/octet-stream' };

const APP_CSP = "default-src 'self'; img-src 'self' https: http: data:; style-src 'self' 'unsafe-inline'; frame-ancestors 'self'; base-uri 'none'; form-action 'self'";
const STAGE_CSP = "default-src 'self'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval' blob:; worker-src 'self' blob:; connect-src 'self' data: blob:; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; frame-ancestors 'self'";

const store = new FrontierStore();

function sendJSON(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  res.end(JSON.stringify(body));
}

async function readBody(req) {
  const chunks = [];
  let size = 0;
  for await (const c of req) {
    size += c.length;
    if (size > 2 << 20) throw Object.assign(new Error('Request too large'), { status: 413 });
    chunks.push(c);
  }
  return chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : {};
}

function serveFile(res, file, root, csp) {
  const path = resolve(file);
  if (path !== root && !path.startsWith(root + sep)) return sendJSON(res, 403, { error: 'Forbidden' });
  let info;
  try { info = statSync(path); } catch { return sendJSON(res, 404, { error: 'Not found' }); }
  if (!info.isFile()) return sendJSON(res, 404, { error: 'Not found' });
  res.writeHead(200, { 'content-type': MIME[extname(path)] ?? 'application/octet-stream', 'content-length': info.size,
    'cache-control': 'no-cache', 'content-security-policy': csp, 'x-content-type-options': 'nosniff' });
  createReadStream(path).pipe(res);
}

async function serveStageHTML(res) {
  // Outside the native web view there is no message handler for the stage to talk to.
  // Browser windows are usually wide, so give four or five faces more columns; two would crop them to a strip.
  const wideGrid = `<style>@media (min-aspect-ratio: 1/1) {
  #stage:has(.card:nth-child(4)) { grid-template-columns: repeat(4, minmax(0, 1fr)) !important; grid-template-rows: minmax(0, 1fr) !important; }
  #stage:has(.card:nth-child(5)) { grid-template-columns: repeat(3, minmax(0, 1fr)) !important; grid-template-rows: repeat(2, minmax(0, 1fr)) !important; }
}</style>\n`;
  const html = (await readFile(join(STAGE, 'stage.html'), 'utf8')).replace('</head>', `${wideGrid}</head>`).replace('<script type="module"',
    '<script>if (!globalThis.webkit?.messageHandlers) globalThis.webkit = { messageHandlers: {} };</script>\n<script type="module"');
  res.writeHead(200, { 'content-type': MIME['.html'], 'cache-control': 'no-cache', 'content-security-policy': STAGE_CSP });
  res.end(html);
}

// Cancels a model call when the browser walks away (a new question interrupts the last one).
function abortOnClose(res) {
  const ac = new AbortController();
  res.on('close', () => { if (!res.writableEnded) ac.abort(); });
  return ac.signal;
}

const needItem = (id) => {
  const item = store.item(id);
  if (!item) throw Object.assign(new Error('That story is no longer in the feed.'), { status: 404 });
  return item;
};

const ROUTES = {
  'GET /api/state': (req, res) => sendJSON(res, 200, store.snapshot()),

  'GET /api/events': (req, res) => {
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store', connection: 'keep-alive' });
    const send = (event, data) => res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
    const onStatus = (s) => send('status', s);
    const onChanged = () => send('changed', {});
    store.on('status', onStatus);
    store.on('changed', onChanged);
    send('status', store.liveStatus());
    const ping = setInterval(() => res.write(': ping\n\n'), 25_000);
    req.on('close', () => { clearInterval(ping); store.off('status', onStatus); store.off('changed', onChanged); });
  },

  'POST /api/refresh': (req, res) => { store.refresh(); sendJSON(res, 202, {}); },
  'POST /api/brief/rewrite': async (req, res) => { await store.synthesize(); sendJSON(res, 200, {}); },

  'POST /api/digest': async (req, res, body) => {
    if (!SECTIONS[body.section]) return sendJSON(res, 400, { error: 'Unknown desk' });
    await store.writeDigest(body.section);
    sendJSON(res, 200, {});
  },

  'POST /api/saved': (req, res, body) => { store.toggleSaved(needItem(body.id).url); sendJSON(res, 200, {}); },
  'POST /api/settings': (req, res, body) => { store.updateSettings(body); sendJSON(res, 200, {}); },

  'POST /api/provider/test': async (req, res, body) => {
    if (!PROVIDERS[body.provider] && body.provider !== 'local') return sendJSON(res, 400, { error: 'Unknown provider' });
    sendJSON(res, 200, { text: await store.testProvider(body.provider) });
  },

  'POST /api/item/paper': async (req, res, body) => sendJSON(res, 200, await store.paperSummary(needItem(body.id))),
  'POST /api/item/quick': async (req, res, body) => sendJSON(res, 200, { quick: await store.quickRead(needItem(body.id)) }),

  // One JSON object per line: each panelist as they finish, then the ruling.
  'POST /api/item/council': async (req, res, body) => {
    const item = needItem(body.id);
    res.writeHead(200, { 'content-type': 'application/x-ndjson', 'cache-control': 'no-store' });
    const write = (o) => res.write(JSON.stringify(o) + '\n');
    try { await store.convene(item, write, abortOnClose(res)); }
    catch (e) { write({ error: e.message }); }
    res.end();
  },

  // Brainstorm Live: a never-ending roundtable on local models. State, then a stream of changes.
  'GET /api/live': (req, res) => sendJSON(res, 200, store.live.snapshot()),
  'GET /api/live/stream': (req, res) => {
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store', connection: 'keep-alive' });
    const send = (event, data) => res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
    const onChange = (c) => send(c.kind, c.kind === 'turn' ? { turn: c.turn } : c.kind === 'delta' ? { speaker: c.speaker, text: c.text, model: c.model } : store.live.snapshot(0));
    send('reset', store.live.snapshot());
    store.live.on('change', onChange);
    const ping = setInterval(() => res.write(': ping\n\n'), 25_000);
    req.on('close', () => { clearInterval(ping); store.live.off('change', onChange); });
  },
  'POST /api/live/start': (req, res, body) => { store.live.start(body.topic); sendJSON(res, 200, {}); },
  'POST /api/live/pause': (req, res) => { store.live.pause(); sendJSON(res, 200, {}); },
  'POST /api/live/resume': (req, res) => { store.live.resume(); sendJSON(res, 200, {}); },
  'POST /api/live/stop': (req, res) => { store.live.stop(); sendJSON(res, 200, {}); },
  'POST /api/live/agent': (req, res, body) => { store.live.configure(body.id, { model: body.model, viewpoint: body.viewpoint }); sendJSON(res, 200, {}); },
  'POST /api/live/say': (req, res, body) => { store.live.say(body.text); sendJSON(res, 200, {}); },

  // One JSON object per line: {delta} as text arrives, then {done: {text, by}} or {error}.
  'POST /api/brainstorm/turn/stream': async (req, res, body) => {
    res.writeHead(200, { 'content-type': 'application/x-ndjson', 'cache-control': 'no-store' });
    const write = (o) => res.write(JSON.stringify(o) + '\n');
    try { write({ done: await store.panelTurnStream(body, (delta) => write({ delta }), abortOnClose(res)) }); }
    catch (e) { write({ error: e.message }); }
    res.end();
  },
  'POST /api/brainstorm/turn': async (req, res, body) => sendJSON(res, 200, await store.panelTurn(body, abortOnClose(res))),
};

const LOGIN_PAGE = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>SooFrontier</title>
<style>body{font:16px system-ui;display:grid;place-items:center;min-height:100vh;margin:0}form{display:grid;gap:12px;padding:16px;max-width:320px}input,button{font:inherit;padding:10px}</style>
<form method="post" action="/login"><strong>SooFrontier</strong><label>Access code <input name="code" type="password" autofocus required style="width:100%;box-sizing:border-box"></label><button>Open</button></form>`;

const hasSession = (req) => (req.headers.cookie ?? '').split(/;\s*/).includes(`soofrontier=${sessionToken}`);

async function handle(req, res) {
  const url = new URL(req.url, 'http://server');
  const hostName = (req.headers.host ?? '').replace(/:\d+$/, '').replace(/^\[|\]$/g, '');

  // A web page you visit can aim requests at localhost; only answer ones addressed to this app, from this app.
  if (LOOPBACK && !['localhost', '127.0.0.1', '::1'].includes(hostName)) return sendJSON(res, 403, { error: 'Forbidden' });
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    const origin = req.headers.origin;
    if (origin && new URL(origin).host !== req.headers.host) return sendJSON(res, 403, { error: 'Forbidden' });
  }

  if (ACCESS_CODE && !hasSession(req)) {
    if (req.method === 'POST' && url.pathname === '/login') {
      const chunks = [];
      for await (const c of req) { chunks.push(c); if (chunks.length > 8) break; }
      const code = new URLSearchParams(Buffer.concat(chunks).toString()).get('code') ?? '';
      if (timingSafeEqual(sha(code), sha(ACCESS_CODE))) {
        res.writeHead(303, { location: '/', 'set-cookie': `soofrontier=${sessionToken}; HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000` });
        return res.end();
      }
    }
    if (url.pathname.startsWith('/api/')) return sendJSON(res, 401, { error: 'Sign in first' });
    res.writeHead(200, { 'content-type': MIME['.html'] });
    return res.end(LOGIN_PAGE);
  }

  const route = ROUTES[`${req.method} ${url.pathname}`];
  if (route) {
    const body = req.method === 'POST' ? await readBody(req) : null;
    return route(req, res, body);
  }
  if (req.method !== 'GET' && req.method !== 'HEAD') return sendJSON(res, 404, { error: 'Not found' });

  const path = decodeURIComponent(url.pathname);
  if (path === '/stage.html') return serveStageHTML(res);
  if (path === '/stage.js' || /^\/(avatar|vendor|models)\//.test(path)) return serveFile(res, join(STAGE, path), STAGE, STAGE_CSP);
  if (path.startsWith('/portraits/')) return serveFile(res, join(NATIVE, 'Portraits', path.slice(11)), join(NATIVE, 'Portraits'), STAGE_CSP);
  return serveFile(res, join(PUBLIC, path === '/' ? 'index.html' : path), PUBLIC, APP_CSP);
}

const server = http.createServer((req, res) => {
  handle(req, res).catch((e) => {
    if (e.message === 'Cancelled' || e.name === 'AbortError') return res.destroy();
    if (res.headersSent) return res.end();
    sendJSON(res, e.status ?? 500, { error: e.message });
  });
});

server.on('error', (e) => {
  if (e.code !== 'EADDRINUSE') throw e;
  console.error(`Port ${PORT} is already in use, so SooFrontier may already be running: try http://localhost:${PORT}.\nTo run a second copy, pick another port: PORT=5181 node server.mjs`);
  process.exit(1);
});

server.listen(PORT, HOST, () => {
  console.log(`SooFrontier is running at http://${HOST === '127.0.0.1' ? 'localhost' : HOST}:${PORT}`);
  if (ACCESS_CODE) console.log(`Access code: ${ACCESS_CODE}`);
  store.startSchedule();
});
