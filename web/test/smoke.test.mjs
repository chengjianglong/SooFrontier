// Boots the real server against a fake Ollama, so it needs no network, no GPU box and none of your saved data.
// Run with `npm test` in web/.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import http from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, test } from 'node:test';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const MODELS = ['m-main', 'm-other'];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const freePort = () => new Promise((resolve) => { const s = http.createServer().listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => resolve(port)); }); });

let fake, child, base, events = [], stream;

/** An Ollama stand-in: model list, and chat replies that name the model that wrote them, streamed word by word. */
function startFakeOllama(port) {
  let count = 0;
  fake = http.createServer(async (req, res) => {
    if (req.url === '/api/tags') { res.end(JSON.stringify({ models: MODELS.map((name) => ({ name })) })); return; }
    let raw = '';
    for await (const c of req) raw += c;
    const body = JSON.parse(raw || '{}');
    const text = `${body.model} says reply number ${++count} with a few more words.`;
    if (!body.stream) { res.setHeader('content-type', 'application/json'); res.end(JSON.stringify({ choices: [{ message: { content: text }, finish_reason: 'stop' }] })); return; }
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    for (const word of text.split(' ')) { res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: `${word} ` } }] })}\n\n`); await sleep(3); }
    res.write(`data: ${JSON.stringify({ choices: [{ delta: {}, finish_reason: 'stop' }] })}\n\ndata: [DONE]\n\n`);
    res.end();
  });
  return new Promise((resolve) => fake.listen(port, '127.0.0.1', resolve));
}

const get = async (path) => (await fetch(base + path)).json();
const post = (path, body = {}) => fetch(base + path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
const live = () => get('/api/live');
async function until(fn, what, ms = 15000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { const v = await fn(); if (v) return v; await sleep(50); }
  assert.fail(`Timed out waiting for ${what}`);
}

before(async () => {
  const [fakePort, appPort] = [await freePort(), await freePort()];
  await startFakeOllama(fakePort);
  const data = mkdtempSync(join(tmpdir(), 'soofrontier-test-'));
  writeFileSync(join(data, 'settings.json'), JSON.stringify({ local: { url: `http://127.0.0.1:${fakePort}`, model: 'm-main', fastModel: 'm-main' } }));
  child = spawn(process.execPath, ['server.mjs'], { cwd: ROOT, stdio: 'ignore',
    env: { ...process.env, PORT: String(appPort), SOOFRONTIER_DATA: data, SOOFRONTIER_NO_REFRESH: '1', SOOFRONTIER_LOCAL_URL: `http://127.0.0.1:${fakePort}` } });
  base = `http://127.0.0.1:${appPort}`;
  await until(async () => { try { return (await get('/api/state')).local?.configured; } catch { return false; } }, 'the server to come up with the fake model server');

  // Watch the live event stream the way the page does.
  stream = new AbortController();
  const r = await fetch(`${base}/api/live/stream`, { signal: stream.signal });
  (async () => {
    let buf = '';
    try { for await (const chunk of r.body) { buf += Buffer.from(chunk).toString(); const parts = buf.split('\n\n'); buf = parts.pop();
      for (const p of parts) { const m = /^event: (\w+)\ndata: (.*)$/s.exec(p); if (m) events.push({ kind: m[1], data: JSON.parse(m[2]) }); } } } catch {}
  })();
});

after(() => { stream?.abort(); child?.kill(); fake?.close(); });

test('serves the app, its data and the provider state', async () => {
  for (const path of ['/', '/app.js', '/live.js', '/live-config.json']) assert.equal((await fetch(base + path)).status, 200, path);
  assert.ok((await get('/live-config.json')).starters.length > 0);
  const state = await get('/api/state');
  assert.deepEqual(Object.keys(state.providers).sort(), ['anthropic', 'openai', 'xai']);
  assert.deepEqual(state.local.installed, MODELS);
});

test('a discussion streams token by token and finishes as turns', async () => {
  assert.equal((await post('/api/live/start', { topic: '' })).status, 500, 'an empty topic is refused');
  assert.equal((await post('/api/live/start', { topic: 'Is this test fast?' })).status, 200);
  const snap = await until(async () => { const s = await live(); return s.total >= 3 && s; }, 'three turns');
  assert.ok(snap.turns.every((t) => t.model === 'm-main'), 'every agent starts on the main model');
  assert.ok(events.filter((e) => e.kind === 'delta').length > 5, 'tokens arrive as delta events');
  assert.ok(events.some((e) => e.kind === 'turn'));
  const deltas = events.filter((e) => e.kind === 'delta').map((e) => e.data.text);
  assert.ok(deltas.some((t, i) => deltas[i + 1]?.startsWith(t) && deltas[i + 1].length > t.length), 'each delta carries the text so far');
});

test('changing an agent takes effect on its next turn and shows in the state at once', async () => {
  const bad = await post('/api/live/agent', { id: 'nobody', model: 'm-other' });
  assert.equal(bad.status, 500);
  assert.match((await bad.json()).error, /Unknown agent/);
  assert.equal((await post('/api/live/agent', { id: 'skeptic', model: 'not-installed' })).status, 500);

  const before = (await live()).total;
  assert.equal((await post('/api/live/agent', { id: 'contrarian', model: 'm-other', viewpoint: 'A pirate captain.' })).status, 200);
  const now = (await live()).agents.find((a) => a.id === 'contrarian');
  assert.equal(now.model, 'm-other');
  assert.equal(now.customModel, true);
  assert.equal(now.custom, true);
  assert.equal(now.viewpoint, 'A pirate captain.');

  const snap = await until(async () => { const s = await live(); return s.turns.some((t) => t.n > before && t.speaker === 'contrarian') && s; }, 'the contrarian to speak again');
  assert.ok(snap.turns.some((t) => t.speaker === 'system' && /Contrarian/.test(t.text)), 'a note records the change');
  assert.equal(snap.turns.filter((t) => t.speaker === 'contrarian').at(-1).model, 'm-other');
  assert.ok(snap.turns.filter((t) => t.speaker === 'skeptic').every((t) => t.model === 'm-main'), 'other agents are untouched');

  await post('/api/live/agent', { id: 'contrarian', model: 'm-main', viewpoint: '' });
  const reset = (await live()).agents.find((a) => a.id === 'contrarian');
  assert.equal(reset.customModel, false);
  assert.equal(reset.custom, false);
});

test('discussion settings are validated, applied and kept', async () => {
  const defaults = (await live()).options;
  assert.deepEqual(defaults, { length: 'medium', pace: 'fast', memory: 'normal' });
  const bad = await post('/api/live/options', { length: 'enormous' });
  assert.equal(bad.status, 500);
  assert.match((await bad.json()).error, /Unknown length/);
  assert.equal((await post('/api/live/options', { length: 'long', memory: 'short' })).status, 200);
  assert.deepEqual((await live()).options, { length: 'long', pace: 'fast', memory: 'short' });
  assert.ok(events.some((e) => e.kind === 'state' && e.data.options?.length === 'long'), 'the change is pushed to the page');
  await post('/api/live/options', { length: 'medium', memory: 'normal' });
});

test('pause stops new turns and resume continues', async () => {
  await post('/api/live/pause');
  assert.equal((await live()).status, 'paused');
  await sleep(300); // let a turn that was already streaming settle
  const total = (await live()).total;
  await sleep(500);
  assert.equal((await live()).total, total, 'no turns while paused');
  await post('/api/live/resume');
  await until(async () => (await live()).total > total, 'turns after resume');
  await post('/api/live/stop');
  assert.equal((await live()).status, 'stopped');
});
