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

/** AbortSignal.any (Node 20+), with a fallback so the server also runs on older Node such as Ubuntu's Node 18. */
function anySignal(signals) {
  if (typeof AbortSignal.any === 'function') return AbortSignal.any(signals);
  const controller = new AbortController();
  for (const s of signals) {
    if (s.aborted) { controller.abort(s.reason); break; }
    s.addEventListener('abort', () => controller.abort(s.reason), { once: true });
  }
  return controller.signal;
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
    signal: signal ? anySignal([signal, timeout]) : timeout });
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

// MARK: Local models: an Ollama server on your GPU box (e.g. a DGX Spark / GB10), reached over the LAN or a VPN.

export const LOCAL = {
  defaultURL: process.env.SOOFRONTIER_LOCAL_URL ?? 'http://localhost:11434',
  // The strongest model that fits a 128 GB GB10, and a fast mixture-of-experts model for short jobs.
  defaultModel: 'gpt-oss:120b',
  defaultFastModel: 'qwen3.6:35b-a3b',
  suggestedModels: ['gpt-oss:120b', 'qwen3.8:27b', 'qwen3.6:35b-a3b', 'qwen3-next:80b', 'gemma4:31b', 'gpt-oss:20b'],
};

const trimURL = (url) => url.trim().replace(/\/+$/, '');

/** Models the local server has downloaded, or null when it can't be reached. */
export async function localModels(url) {
  try {
    const r = await fetch(`${trimURL(url)}/api/tags`, { signal: AbortSignal.timeout(3000) });
    return ((await r.json()).models ?? []).map((m) => m.name).sort();
  } catch { return null; }
}

export function makeLocalClient({ url, model, fastModel = model }) {
  return {
    provider: 'local', mode: 'local', model, label: `${model} · local`,
    /** The same server with its fast model, for quick jobs. */
    withModel() { return makeLocalClient({ url, model: fastModel || model, fastModel }); },
    /** Like complete(), but calls onDelta(textSoFar) as tokens arrive (OpenAI-style server-sent events). */
    async stream({ system, prompt, maxTokens = 8000, temperature, signal, onDelta }, thinking = maxTokens > 4000) {
      const timeout = AbortSignal.timeout(600_000);
      const body = { model, max_tokens: maxTokens, stream: true, messages: [{ role: 'system', content: system }, { role: 'user', content: prompt }] };
      if (temperature !== undefined) body.temperature = temperature;
      // Same as complete(): thinking models such as Qwen3 skip thinking on short jobs, which would otherwise eat the token budget.
      if (model.startsWith('gpt-oss')) body.reasoning_effort = maxTokens <= 3000 ? 'low' : 'medium';
      else if (!thinking) body.reasoning_effort = 'none';
      let r;
      try {
        r = await fetch(`${trimURL(url)}/v1/chat/completions`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
          signal: signal ? anySignal([signal, timeout]) : timeout });
      } catch (e) {
        if (signal?.aborted) throw new Error('Cancelled');
        throw new Error(`Can't reach the local model server at ${url} (${e.cause?.code ?? e.message}).`);
      }
      if (r.status !== 200) {
        const json = await r.json().catch(() => ({}));
        throw new Error(`Local model (${model}): ${json.error?.message ?? json.error ?? `HTTP ${r.status}`}`);
      }
      let text = '', buffer = '', finish = null;
      const decoder = new TextDecoder();
      try {
        for await (const chunk of r.body) {
          buffer += decoder.decode(chunk, { stream: true });
          const lines = buffer.split('\n');
          buffer = lines.pop();
          for (const line of lines) {
            if (!line.startsWith('data:') || line.includes('[DONE]')) continue;
            let j; try { j = JSON.parse(line.slice(5)); } catch { continue; }
            const c = j.choices?.[0];
            if (c?.finish_reason) finish = c.finish_reason;
            const piece = c?.delta?.content;
            if (piece) { text += piece; onDelta?.(text); }
          }
        }
      } catch (e) {
        if (signal?.aborted) throw new Error('Cancelled');
        throw new Error(`Lost the local model stream (${e.cause?.code ?? e.message}).`);
      }
      text = text.trim();
      if (!text) throw new Error(`Local model (${model}) returned no text (${finish ?? 'empty'}).`);
      return text;
    },
    async complete({ system, prompt, maxTokens = 8000, temperature, signal }, thinking = maxTokens > 4000) {
      const timeout = AbortSignal.timeout(600_000);
      const body = { model, max_tokens: maxTokens, messages: [{ role: 'system', content: system }, { role: 'user', content: prompt }] };
      if (temperature !== undefined) body.temperature = temperature;
      // Thinking spends the same token budget as the answer. gpt-oss always reasons, so keep that short;
      // thinking models such as Qwen3 skip it on short jobs.
      if (model.startsWith('gpt-oss')) body.reasoning_effort = maxTokens <= 3000 ? 'low' : 'medium';
      else if (!thinking) body.reasoning_effort = 'none';
      let r;
      try {
        r = await fetch(`${trimURL(url)}/v1/chat/completions`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
          signal: signal ? anySignal([signal, timeout]) : timeout });
      } catch (e) {
        if (signal?.aborted) throw new Error('Cancelled');
        throw new Error(`Can't reach the local model server at ${url} (${e.cause?.code ?? e.message}).`);
      }
      const json = await r.json().catch(() => ({}));
      if (r.status !== 200) throw new Error(`Local model (${model}): ${json.error?.message ?? json.error ?? `HTTP ${r.status}`}`);
      const choice = json.choices?.[0];
      const text = (choice?.message?.content ?? '').trim();
      // Ran out of budget while thinking: answer again without thinking.
      if (!text && choice?.finish_reason === 'length' && thinking && !model.startsWith('gpt-oss')) return this.complete({ system, prompt, maxTokens, temperature, signal }, false);
      if (!text) throw new Error(`Local model (${model}) returned no text (${choice?.finish_reason ?? 'empty'}).`);
      return text;
    },
  };
}

const UNREACHABLE = /can't reach|enotfound|econnrefused|econnreset|etimedout|network|timed out|timeout|fetch failed|couldn't find the `/i;

/** Tries `first`, and on an unreachable/missing provider, `second`. Research jobs never switch. */
export function withFallback(first, second) {
  if (!second) return first;
  return {
    ...first,
    withModel: (cli, api) => withFallback(first.withModel(cli, api), second.withModel(cli, api)),
    async complete(args) {
      try { return await first.complete(args); } catch (e) {
        if (args.research || args.signal?.aborted || !UNREACHABLE.test(e.message)) throw e;
        return second.complete(args);
      }
    },
  };
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
