// Model access: your plan through the official CLI, or a metered API key. Ported from Services/LLM.swift and Subscriptions.swift.
import { spawn } from 'node:child_process';
import { accessSync, constants, createWriteStream } from 'node:fs';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { PROVIDERS } from '../public/shared.js';

const home = homedir();
const SEARCH_DIRS = [`${home}/.local/bin`, '/opt/homebrew/bin', '/usr/local/bin', `${home}/.npm-global/bin`, `${home}/.bun/bin`,
  `${home}/.claude/local`, '/usr/bin', '/bin', ...(process.env.PATH ?? '').split(':').filter(Boolean)];

export function cliPath(name) {
  for (const dir of SEARCH_DIRS) {
    const path = join(dir, name);
    try { accessSync(path, constants.X_OK); return path; } catch {}
  }
  return null;
}

function launch(exe, args, { env, cwd, signal, timeout = 300_000 }) {
  return new Promise((resolve, reject) => {
    const errPath = join(cwd, 'stderr.txt');
    const errFile = createWriteStream(errPath);
    errFile.once('open', () => {
      const p = spawn(exe, args, { env, cwd, stdio: ['ignore', 'pipe', errFile], signal, timeout });
      const chunks = [];
      p.stdout.on('data', (d) => chunks.push(d));
      p.on('error', (e) => { errFile.end(); reject(e.name === 'AbortError' ? new Error('Cancelled') : e); });
      p.on('close', async (status) => {
        errFile.end();
        resolve({ status, stdout: Buffer.concat(chunks).toString(), stderr: await readFile(errPath, 'utf8').catch(() => '') });
      });
    });
  });
}

const tail = (s) => s.trim().slice(-300) || 'no output';

const grokAuthPath = join(home, '.grok', 'auth.json');

// Latest expiry among the sign-ins in Grok's auth file, or null if there is no file to read.
async function grokExpiry() {
  try {
    const dates = Object.values(JSON.parse(await readFile(grokAuthPath, 'utf8'))).map((a) => Date.parse(a?.expires_at));
    return Math.max(...dates.filter(Number.isFinite));
  } catch { return null; }
}

// The strict sandbox can't write to Grok's auth lock, so with an expired token Grok waits forever instead of
// failing. Renew it first, outside the sandbox, with a fixed prompt. Parallel calls share one renewal.
let grokRenewal = null;
function renewGrokSignIn(exe, env, cwd) {
  grokRenewal ??= (async () => {
    const expiry = await grokExpiry();
    if (expiry === null || expiry - Date.now() > 10 * 60_000) return;
    await launch(exe, ['--no-auto-update', '--no-alt-screen', '--max-turns', '1', '--cwd', cwd, '--disable-web-search', '-p', 'Reply with exactly: ready'], { env, cwd, timeout: 60_000 });
    if ((await grokExpiry()) <= Date.now()) throw new Error("Grok's sign-in has expired. Run `grok login`, then refresh.");
  })().finally(() => { grokRenewal = null; });
  return grokRenewal;
}

async function runCLI(provider, { model, system, prompt, research, signal }) {
  const p = PROVIDERS[provider];
  const exe = cliPath(p.cliName);
  if (!exe) throw new Error(`Couldn't find the \`${p.cliName}\` CLI. Install it and sign in with your ${p.planName} plan.`);
  const work = await mkdtemp(join(tmpdir(), 'soofrontier-'));
  try {
    const outFile = join(work, 'out.txt');
    const combined = `<instructions>\n${system}\n</instructions>\n\n${prompt}`;
    let args;
    if (provider === 'anthropic') {
      args = ['-p', '--tools', '', '--setting-sources', '', '--no-session-persistence', '--output-format', 'json', '--system-prompt', system];
      if (model) args.push('--model', model);
      args.push(prompt);
    } else if (provider === 'openai') {
      args = ['exec', '--skip-git-repo-check', '--ephemeral', '-s', 'read-only', '-o', outFile, '-c', 'model_reasoning_effort="medium"'];
      if (model) args.push('-m', model);
      args.push(combined);
    } else {
      // The strict sandbox confines reads and writes to the empty scratch folder, and with no
      // --always-approve a headless run refuses shell commands. Research mode adds searches of X and the web.
      args = ['--no-auto-update', '--no-alt-screen', '--output-format', 'streaming-json', '--max-turns', research ? '8' : '1', '--cwd', work, '--sandbox', 'strict'];
      if (research) args.push('--allow', 'WebSearch', '--allow', 'WebFetch');
      if (model) args.push('-m', model);
      args.push('-p', combined);
    }
    // Never let a stray API key in the environment turn plan usage into metered billing.
    const env = { ...process.env, PATH: SEARCH_DIRS.join(':') };
    for (const k of ['ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'OPENAI_API_KEY', 'CODEX_API_KEY', 'XAI_API_KEY']) delete env[k];

    if (provider === 'xai') await renewGrokSignIn(exe, env, work);
    const { status, stdout, stderr } = await launch(exe, args, { env, cwd: work, signal });
    if (provider === 'anthropic') {
      let json = null;
      try { json = JSON.parse(stdout); } catch {}
      const result = json?.result ?? '';
      if (status !== 0 || json?.is_error || !result) throw new Error(`Claude CLI: ${result || tail(stderr)}`);
      return result.trim();
    }
    if (provider === 'openai') {
      const text = await readFile(outFile, 'utf8').catch(() => '');
      if (status !== 0 || !text) throw new Error(`Codex CLI: ${tail(stderr)}`);
      return text.trim();
    }
    // Keep only the text written after Grok's last tool call; earlier text is "let me check…" narration.
    let answer = '';
    for (const line of stdout.split('\n')) {
      let e;
      try { e = JSON.parse(line); } catch { continue; }
      if (e.type === 'tool_call') answer = '';
      else if (e.type === 'text') answer += e.data ?? '';
    }
    const text = answer.trim();
    if (status === null && !signal?.aborted) throw new Error("Grok didn't answer in time.");
    if (status !== 0 || !text) throw new Error(`Grok CLI: ${tail(stderr || stdout)}`);
    return text;
  } finally {
    await rm(work, { recursive: true, force: true });
  }
}

async function post(provider, url, headers, body, signal) {
  const timeout = AbortSignal.timeout(180_000);
  const r = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(body),
    signal: signal ? AbortSignal.any([signal, timeout]) : timeout });
  const json = await r.json().catch(() => ({}));
  if (r.status !== 200) {
    const msg = json.error?.message ?? (typeof json.error === 'string' ? json.error : `HTTP ${r.status}`);
    throw new Error(`${PROVIDERS[provider].name}: ${msg}`);
  }
  return json;
}

async function anthropicAPI({ apiKey, model, system, prompt, maxTokens, signal }) {
  const headers = { 'x-api-key': apiKey, 'anthropic-version': '2026-10-21' };
  const body = { model, max_tokens: maxTokens, system, messages: [{ role: 'user', content: prompt }], output_config: { effort: 'low' } };
  // Opus/Sonnet/Fable re-route safety-declined requests server-side; Haiku has no fallback.
  if (!model.includes('haiku')) {
    headers['anthropic-beta'] = 'server-side-fallback-2026-07-01';
    body.fallbacks = 'default';
  }
  const json = await post('anthropic', 'https://api.anthropic.com/v1/messages', headers, body, signal);
  if (json.stop_reason === 'refusal') throw new Error(`Claude declined this request (${json.stop_details?.category ?? 'policy'}).`);
  return (json.content ?? []).filter((b) => b.type === 'text').map((b) => b.text).join('\n').trim();
}

async function chatCompletions(provider, { apiKey, model, system, prompt, maxTokens, signal }) {
  const [base, tokenField] = provider === 'openai' ? ['https://api.openai.com/v1', 'max_completion_tokens'] : ['https://api.x.ai/v1', 'max_tokens'];
  const json = await post(provider, `${base}/chat/completions`, { authorization: `Bearer ${apiKey}` }, {
    model, [tokenField]: maxTokens, messages: [{ role: 'system', content: system }, { role: 'user', content: prompt }],
  }, signal);
  const choice = json.choices?.[0];
  const text = choice?.message?.content ?? '';
  if (!text && choice?.finish_reason) throw new Error(`${PROVIDERS[provider].family} returned no text (${choice.finish_reason}).`);
  return text.trim();
}

/** One configured provider + model, able to answer a single-turn prompt. */
export function makeClient(provider, { mode, apiKey = '', model, cliModel = '' }) {
  const p = PROVIDERS[provider];
  const plan = p.planName.split(' ').at(-1);
  return {
    provider, mode, model, cliModel,
    label: mode === 'subscription' ? `${p.family} · ${plan} plan${cliModel ? ` · ${cliModel}` : ''}` : `${p.family} · ${model}`,
    /** The same client with another model, for fast jobs. */
    withModel(nextCLI, nextAPI) { return makeClient(provider, { mode, apiKey, model: nextAPI, cliModel: nextCLI }); },
    complete({ system, prompt, maxTokens = 8000, research = false, signal }) {
      if (mode === 'subscription') return runCLI(provider, { model: cliModel, system, prompt, research, signal });
      if (!apiKey) throw new Error(`Add a ${p.name} API key in Settings.`);
      const args = { apiKey, model, system, prompt, maxTokens, signal };
      return provider === 'anthropic' ? anthropicAPI(args) : chatCompletions(provider, args);
    },
  };
}
