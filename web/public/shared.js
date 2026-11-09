// Used by both the server and the browser: the taxonomy, ranking, the Skeptic's checks, and the house structure.
// Ported from Models/FrontierModels.swift, Agents/Thinkers.swift and Services/PaperReader.swift.

export const SECTIONS = {
  research: { title: 'Research', digestLabel: 'Research digest', lanes: ['papers', 'reports', 'demos', 'code'] },
  productions: { title: 'Productions', digestLabel: "Analyst's take", lanes: ['models', 'products', 'services'] },
  opinions: { title: 'Opinions', digestLabel: 'Consensus & dissent', lanes: ['voices', 'essays', 'companies'] },
};

export const CATEGORIES = {
  papers: { title: 'SOTA papers', section: 'research', tint: '#007aff' },
  reports: { title: 'Tech reports', section: 'research', tint: '#5856d6' },
  demos: { title: 'Demos', section: 'research', tint: '#ff2d55' },
  code: { title: 'Code', section: 'research', tint: '#34c759' },
  models: { title: 'Models', section: 'productions', tint: '#af52de' },
  products: { title: 'Products', section: 'productions', tint: '#ff9500' },
  services: { title: 'Services', section: 'productions', tint: '#32ade6' },
  voices: { title: 'Voices on X', section: 'opinions', tint: '#30b0c7' },
  essays: { title: 'Essays', section: 'opinions', tint: '#a2845e' },
  companies: { title: 'Company blogs', section: 'opinions', tint: '#8e8e93' },
};

export const AGENTS = {
  archivist: { name: 'Archivist', role: 'SOTA papers from arXiv and HF Daily Papers, plus lab technical reports', lanes: ['papers', 'reports'] },
  showrunner: { name: 'Showrunner', role: 'Demos worth trying', lanes: ['demos'] },
  librarian: { name: 'Librarian', role: 'Rising open-source code', lanes: ['code'] },
  curator: { name: 'Curator', role: 'Trending open-weight models', lanes: ['models'] },
  scout: { name: 'Scout', role: 'AI product launches across the tech press', lanes: ['products'] },
  analyst: { name: 'Analyst', role: 'AI platform and cloud services', lanes: ['services'] },
  listener: { name: 'Listener', role: 'What the voices you follow on X are saying, via Grok', lanes: ['voices'] },
  pundit: { name: 'Pundit', role: 'Essays and newsletters', lanes: ['essays'] },
  correspondent: { name: 'Correspondent', role: 'Blogs from AI model and data companies', lanes: ['companies'] },
  skeptic: { name: 'Skeptic', role: 'Separates signal from hype', lanes: [], color: '#ff3b30' },
  synthesizer: { name: 'Synthesizer', role: 'Writes your Frontier Brief and desk digests', lanes: [], color: '#5856d6' },
};

export const agentColor = (kind) => AGENTS[kind].color ?? CATEGORIES[AGENTS[kind].lanes[0]]?.tint ?? '#8e8e93';

export const PROVIDERS = {
  anthropic: {
    name: 'Anthropic', family: 'Claude', defaultModel: 'claude-opus-5-5', keyHelp: 'console.anthropic.com → API Keys',
    suggestedModels: ['claude-opus-5-5', 'claude-sonnet-5-5', 'claude-haiku-5-5', 'claude-fable-5-1'],
    cliName: 'claude', loginCommand: 'claude', planName: 'Claude Pro/Max', cliModels: ['opus', 'sonnet', 'haiku'], defaultCLIModel: 'opus',
  },
  openai: {
    name: 'OpenAI', family: 'GPT', defaultModel: 'gpt-5', keyHelp: 'platform.openai.com → API keys',
    suggestedModels: ['gpt-5', 'gpt-5-mini'],
    cliName: 'codex', loginCommand: 'codex login', planName: 'ChatGPT Plus/Pro', cliModels: ['', 'gpt-6-astra'], defaultCLIModel: '',
  },
  xai: {
    name: 'xAI', family: 'Grok', defaultModel: 'grok-4', keyHelp: 'console.x.ai → API Keys',
    suggestedModels: ['grok-4', 'grok-4-fast'],
    cliName: 'grok', loginCommand: 'grok login', planName: 'SuperGrok', cliModels: ['', 'grok-build-0.1'], defaultCLIModel: '',
  },
};

/** The open-weight models on your own GPU box (an Ollama server), shown alongside the three providers. */
export const LOCAL_PROVIDER = {
  name: 'Local', family: 'Local',
};
/** Display info for a provider id, including 'local'. */
export const providerInfo = (p) => PROVIDERS[p] ?? LOCAL_PROVIDER;

// MARK: Frontier Council: five perspectives, played by the local models, debating until they agree.

export const COUNCIL_SEATS = [
  { id: 'skeptic', title: 'The Skeptic', brief: 'Rigorous methodologist. Hunt for missing baselines, eval leakage, cherry-picked results, and unstated limitations.' },
  { id: 'builder', title: 'The Builder', brief: "Pragmatic engineer. Judge what this enables today, what it costs to run, and how you'd actually ship with it." },
  { id: 'contrarian', title: 'The Contrarian', brief: 'Provocative outsider. Challenge the consensus narrative, name who benefits from the hype, and say what everyone is missing.' },
  { id: 'advocate', title: 'The Open-Weights Advocate', brief: 'Hands-on open-model practitioner. Judge whether this can be reproduced, run and fine-tuned on hardware you own, and what the closed labs are not telling you.' },
  { id: 'edge', title: 'The Edge Engineer', brief: 'On-device and small-model specialist. Judge whether this works on phones, laptops and edge chips, what it costs in memory and latency, and whether a small model could do the job.' },
];
/** Seats played by their own local model by default; the rest use the main local model. */
export const COUNCIL_DEFAULT_MODELS = { edge: 'hf.co/LiquidAI/LFM3-1.7B-GGUF:BF16' };
/** A model tag short enough for a label: "hf.co/LiquidAI/LFM3-1.7B-GGUF:BF16" → "LFM3-1.7B". */
export const shortModel = (m) => (m ?? '').split('/').at(-1).replace(/-GGUF(:.*)?$/i, '');
export const VERDICTS = ['read', 'try', 'wait', 'skip'];
export const COUNCIL_MAX_ROUNDS = 4;

/** Splits a council turn into its argument and its "Verdict: …" line (models vary the format, so be lenient). */
export function parseVerdict(text) {
  const re = /^[\s>#*_-]*(?:my |final |updated |revised )?verdict[\s*_]*[:\-–][\s*_]*(read|try|wait|skip)\b.*$/gim;
  let verdict = null;
  for (const m of text.matchAll(re)) verdict = m[1].toLowerCase();
  const seatNames = COUNCIL_SEATS.map((s) => s.title.replace(/^The /, '')).join('|');
  const cleaned = text.replace(re, '')
    .replace(/^[ \t]*#{1,6}[^\n]*verdict[^\n]*$/gim, '')
    .replace(new RegExp(`^\\s*(?:#{1,6}\\s*|\\*\\*)(?:the )?(?:${seatNames})(?:\\*\\*)?:?\\s*$`, 'im'), '')
    .replace(/^\s*#{1,6}[^\n]*\n/, '')
    .replace(/\n{3,}/g, '\n\n');
  return { verdict, text: cleaned.trim() };
}

/** Counts verdicts; `agreed` when every member who answered holds the same one. */
export function tallyVerdicts(turns) {
  const counts = {};
  for (const t of turns) if (t.verdict) counts[t.verdict] = (counts[t.verdict] ?? 0) + 1;
  const ranked = Object.entries(counts).sort((a, b) => b[1] - a[1]);
  const voters = turns.filter((t) => t.verdict).length;
  return { counts, leading: ranked[0]?.[0] ?? null, agreed: voters > 1 && ranked.length === 1 && voters === turns.length };
}

export const PANELISTS = [
  // `voice` matches each portrait: gender picks the voice, and pitch/rate suggest age (speech voices carry no age).
  { id: 'skeptic', name: 'Skeptic', agent: 'skeptic', provider: 'anthropic', aliases: ['claude'], voice: { gender: 'female', age: 'middle', pitch: 0.97, rate: 1.0 },
    viewpoint: 'A rigorous methodologist. You test claims: missing baselines, weak evidence, hidden assumptions, and what would change your mind.' },
  { id: 'builder', name: 'Builder', agent: 'analyst', provider: 'openai', aliases: ['gpt', 'chatgpt', 'analyst'], voice: { gender: 'male', age: 'young', pitch: 1.03, rate: 1.08 },
    viewpoint: 'A pragmatic engineer and product builder. You focus on what this enables today, how you would ship it, what it costs, and concrete next steps.' },
  { id: 'contrarian', name: 'Contrarian', agent: 'pundit', provider: 'xai', aliases: ['grok', 'pundit'], voice: { gender: 'male', age: 'older', pitch: 0.82, rate: 0.95 },
    viewpoint: 'A provocative outsider. You challenge the consensus, name who benefits from the hype, and argue the unpopular side when it has merit.' },
  { id: 'archivist', name: 'Archivist', agent: 'archivist', provider: 'anthropic', aliases: ['researcher'], voice: { gender: 'female', age: 'older', pitch: 0.88, rate: 0.9 },
    viewpoint: 'A research historian. You connect the topic to prior papers, earlier waves of similar ideas, and what the literature already settled.' },
  { id: 'synthesizer', name: 'Synthesizer', agent: 'synthesizer', provider: 'anthropic', aliases: ['moderator'], voice: { gender: 'female', age: 'young', pitch: 1.08, rate: 1.05 },
    viewpoint: 'The moderator. You find common ground, sharpen the real disagreement, and steer the group toward a useful conclusion.' },
];

// MARK: Panelist voices

// Browsers don't expose a voice's gender, so read it from the name. Covers Apple (macOS/iOS), Chrome's Google
// voices, Microsoft (Windows, Edge's natural voices) and eSpeak on Linux ("+f3"/"+m3" variants).
const FEMALE_VOICES = /\b(female|woman|samantha|victoria|karen|moira|tessa|fiona|veena|serena|kate|susan|allison|ava|zoe|nicky|martha|catherine|joelle|noelle|kathy|vicki|princess|agnes|zira|aria|jenny|sonia|libby|michelle|emma|natasha|clara|hazel|susan|heera|neerja|linda|eva|mia|sara|jane|nancy|amber|ashley|cora|elizabeth|monica|ana)\b|\+f\d/i;
const MALE_VOICES = /\b(male|man|alex|daniel|fred|rishi|arthur|oliver|aaron|tom|evan|nathan|lee|gordon|ralph|bruce|junior|albert|david|mark|guy|ryan|christopher|eric|brian|andrew|roger|steffan|thomas|william|george|james|liam|davis|tony|jason|prabhat|ravi|connor|mitchell|reed|rocko|eddy)\b|\+m\d/i;
// Novelty, robotic and child voices never suit a meeting.
const UNSUITED_VOICES = /\b(grandma|grandpa|flo|eddy|fred|reed|rocko|sandy|shelley|bad news|good news|bells|boing|bubbles|cellos|jester|organ|superstar|trinoids|whisper|wobble|zarvox|albert|bahh|junior|ana|kathy|princess|ralph)\b/i;

const quality = (v) => (/natural|premium|enhanced|neural/i.test(v.name) ? 2 : /\+[fm]\d|espeak/i.test(v.name) || /^english \(/i.test(v.name) ? 0 : 1);

export function voiceGender(name) {
  // "Female"/"Male" written out wins over a first name ("Google UK English Male").
  if (/\bfemale\b/i.test(name)) return 'female';
  if (/\bmale\b/i.test(name)) return 'male';
  if (/^google us english$/i.test(name.trim())) return 'female';
  if (FEMALE_VOICES.test(name)) return 'female';
  if (MALE_VOICES.test(name)) return 'male';
  return null;
}

/**
 * Picks a distinct voice for each panelist that matches the gender of their portrait.
 * `voices` are the browser's SpeechSynthesisVoice list; returns { panelistId: { voice, pitch, rate } }.
 * When a device has no voice of the needed gender, pitch is pushed further to approximate it.
 */
export function castVoices(voices) {
  const english = voices.filter((v) => v.lang?.toLowerCase().startsWith('en') && !UNSUITED_VOICES.test(v.name));
  const seen = new Set();
  const distinct = english.filter((v) => !seen.has(v.name) && seen.add(v.name))
    // Natural-sounding first; robotic eSpeak voices last; then installed before network voices.
    .sort((a, b) => quality(b) - quality(a) || b.localService - a.localService);
  // Robotic voices only when a gender has nothing better: reusing a good voice (at another pitch) beats them.
  const poolOf = (g) => { const all = distinct.filter((v) => voiceGender(v.name) === g); const good = all.filter((v) => quality(v) > 0); return good.length ? good : all; };
  const pools = { female: poolOf('female'), male: poolOf('male') };
  const used = { female: 0, male: 0 };
  const cast = {};
  for (const p of PANELISTS) {
    const { gender, pitch, rate } = p.voice;
    const pool = pools[gender];
    if (pool.length) {
      // Distinct voices while they last; after that, pitch and rate keep the voices apart.
      cast[p.id] = { voice: pool[used[gender]++ % pool.length], pitch, rate };
    } else {
      // No voice of this gender here: use any voice and shift pitch towards the right register.
      const fallback = distinct.find((v) => !voiceGender(v.name)) ?? distinct[0] ?? null;
      cast[p.id] = { voice: fallback, pitch: +(gender === 'male' ? pitch * 0.8 : pitch * 1.2).toFixed(2), rate };
    }
  }
  return cast;
}

export const VOICE_ROLES = ['entrepreneur', 'researcher', 'engineer', 'investor', 'builder'];
const voices = (role, ...handles) => handles.map((handle) => ({ handle, role }));
export const VOICE_STARTERS = [
  ...voices('entrepreneur', 'sama', 'DarioAmodei', 'demishassabis', 'alexandr_wang'),
  ...voices('researcher', 'karpathy', 'ylecun', 'AndrewYNg', 'fchollet', 'drfeifei'),
  ...voices('engineer', 'gdb', 'JeffDean', 'simonw', 'swyx'),
  ...voices('investor', 'pmarca', 'eladgil', 'saranormous', 'nathanbenaich'),
  ...voices('builder', 'levelsio', 'amasad', 'rauchg'),
];

export const capitalize = (s) => s.charAt(0).toUpperCase() + s.slice(1);

// MARK: Ranking

export function score(item, now = Date.now()) {
  const date = item.date ? Date.parse(item.date) : now - 86400_000 * 3;
  const ageHours = Math.max(1, (now - date) / 3600_000);
  // Half-life of a day, so a new story outranks yesterday's most-upvoted one.
  const freshness = 0.5 ** (ageHours / 24);
  const pull = Math.log10((item.traction ?? 0) + 10);
  const a = item.assessment;
  const quality = 0.5 + (a ? a.signal - a.hype * 0.5 : 0);
  return freshness * pull * quality;
}

export const byScore = (items, now = Date.now()) =>
  items.map((i) => [score(i, now), i]).sort((a, b) => b[0] - a[0]).map((p) => p[1]);

export const itemsIn = (items, category) => byScore(items.filter((i) => i.category === category));

/** Round-robin across lanes so one noisy source can't crowd out the rest. */
export function topSignals(items) {
  const lanes = Object.keys(CATEGORIES).map((c) => itemsIn(items, c).slice(0, 2));
  return [0, 1].flatMap((rank) => lanes.map((l) => l[rank]).filter(Boolean)).slice(0, 10);
}

export const hypeWatch = (items) =>
  items.filter((i) => (i.assessment?.hype ?? 0) >= 0.35).sort((a, b) => b.assessment.hype - a.assessment.hype).slice(0, 5);

// MARK: Skeptic

const HYPE_WORDS = ['revolutionary', 'game-changer', 'game changer', 'agi', 'breakthrough', 'insane', 'mind-blowing', 'unprecedented',
  'destroys', 'kills', 'beats gpt', 'beats every', 'sota', 'state-of-the-art', 'state of the art', 'superhuman', '10x', '100x',
  'changes everything', 'secret', 'shocking', "you won't believe"];
const EVIDENCE_WORDS = ['benchmark', 'ablation', 'evaluation', 'we evaluate', 'dataset', 'open-source', 'open source', 'code', 'github',
  'weights', 'reproduc', 'baseline', 'limitations', 'error bars', 'human eval', 'preprint', 'peer'];

// Whole words only: as substrings, "agi" matches "imaging" and "kills" matches "skills".
const hasWord = (text, word) => new RegExp(`(^|[^a-z0-9])${word.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&')}($|[^a-z0-9])`).test(text);

export function assess(item) {
  const text = `${item.title} ${item.summary}`.toLowerCase();
  const hypeHits = HYPE_WORDS.filter((w) => hasWord(text, w));
  const evidenceHits = EVIDENCE_WORDS.filter((w) => text.includes(w));
  const flags = [];
  let hype = Math.min(1, hypeHits.length * 0.22 + (item.title.includes('!') ? 0.15 : 0));
  let signal = Math.min(1, evidenceHits.length * 0.12 + Math.min(0.4, Math.log10((item.traction ?? 0) + 1) / 8));

  if (hypeHits.length) flags.push(`Hype language: “${hypeHits.slice(0, 3).join('”, “')}”`);
  if (hypeHits.some((w) => ['sota', 'state-of-the-art', 'state of the art'].includes(w))) {
    flags.push('Claims SOTA — check which benchmarks and whether baselines are current');
  }
  switch (item.category) {
    case 'papers': case 'reports':
      signal += 0.15;
      if (!text.includes('code') && !text.includes('github')) flags.push('No code mentioned — reproducibility unknown');
      if (item.category === 'reports' && item.source !== 'arXiv') flags.push('Lab-authored report — not peer reviewed');
      break;
    case 'models':
      signal += 0.1;
      if ((item.traction ?? 0) < 50) flags.push('Low community traction so far');
      break;
    case 'products': case 'services':
      if (item.source === 'Hacker News') flags.push('Secondhand source — read the primary announcement');
      if (['AWS Machine Learning', 'Google Cloud AI', 'Cloudflare AI'].includes(item.source)) {
        flags.push('Vendor announcement — expect favorable framing');
        hype += 0.15;
      }
      break;
    case 'voices': flags.push('A post, not a paper — check the thread and who replies'); break;
    case 'essays': flags.push("Opinion piece — weigh the author's track record and incentives"); break;
    case 'companies':
      flags.push("Company's own blog — expect favorable framing of its products");
      hype += 0.1;
      break;
    case 'demos': flags.push('Demos are curated — test it on your own hard cases'); break;
    case 'code': if ((item.traction ?? 0) > 5000) signal += 0.1; break;
  }
  return { hype: Math.min(1, hype), signal: Math.min(1, signal), flags };
}

export function verdict(a) {
  const d = a.signal - a.hype;
  if (d >= 0.35) return { label: 'Strong signal', tone: 'strong' };
  if (d >= 0.05) return { label: 'Promising', tone: 'promising' };
  if (d >= -0.2) return { label: 'Unverified', tone: 'unverified' };
  return { label: 'Hype alert', tone: 'hype' };
}

/** Starting-point opportunities for the quick read, by lane. */
export function laneOpportunities(c) {
  switch (c) {
    case 'papers': return ['**Reproduce and stress-test it:** rerun the main result on a held-out benchmark or a different model scale to see whether the gain holds.',
      '**Transfer the method:** apply the core idea to an adjacent task or modality where the same bottleneck appears.',
      '**Ablate the key component:** isolate the one design choice that matters most and test whether a simpler version keeps the benefit.'];
    case 'reports': return ['**Benchmark it yourself:** run the reported model or system on your own tasks to check the claimed numbers.',
      '**Fill the disclosure gaps:** compute, data, and safety details left out of the report are open ground for independent analysis.',
      '**Build on the release:** use any released weights, tools, or datasets as a baseline for follow-up work.'];
    case 'models': return ['**Fine-tune for a niche:** adapt it with LoRA or distillation to a domain the base model underserves.',
      '**Build an evaluation:** create a focused benchmark for the task it claims to be good at.',
      '**Ship a product on it:** if the license allows, wrap it in a narrowly scoped app or API.'];
    case 'products': return ['**Serve the gap:** identify which users it leaves out, by price, privacy, platform, or workflow, and build for them.',
      '**Integrate with it:** a plugin, connector, or workflow layer can ride on its launch.',
      '**Measure it:** an independent comparison against alternatives is useful to buyers and builders alike.'];
    case 'services': return ['**Cut cost or latency:** routing, caching, or batching layers on top of the service can make it cheaper to use.',
      '**Reduce lock-in:** a portable abstraction across providers lets teams switch when prices change.',
      '**Combine it:** pair it with retrieval, tools, or agents to deliver a complete workflow.'];
    case 'demos': return ['**Turn the demo into a tool:** harden the interaction into something people can use daily.',
      '**Probe its limits:** collect failure cases and publish them as a small benchmark.',
      '**Combine it with another model:** chain it into a pipeline that solves a fuller task.'];
    case 'code': return ['**Contribute:** tests, docs, or performance work are often the fastest way to make it production-ready.',
      '**Package it:** a hosted version or integration can serve users who won\'t run it themselves.',
      '**Extend it:** add the feature or backend the issue tracker keeps asking for.'];
    default: return ['**Test the claim:** design a small experiment that would confirm or refute the central argument.',
      '**Build for the trend:** if the view is right, name the tool or product that becomes necessary.',
      '**Write the counterpoint:** a well-evidenced response adds value whichever side is right.'];
  }
}

// MARK: House structure

const lettersAndSemis = (s) => s.toLowerCase().replace(/[^\p{L};]/gu, '');

/** Splits text written in TL;DR, Takeaways, (Math), Potential opportunities; null when the parts aren't there. */
export function parseStructure(text) {
  let part = 'none';
  const tldr = [], takeaways = [], math = [], opportunities = [];
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    const key = lettersAndSemis(line);
    const isHeading = line.startsWith('#') || (line.startsWith('**') && line.length < 40) || (line.endsWith(':') && line.length < 30);
    if (isHeading || key.length < 20) {
      if (key.startsWith('tl;dr') || key.startsWith('tldr')) { part = 'tldr'; continue; }
      if (key.startsWith('takeaway') || key.startsWith('keytakeaway')) { part = 'takeaways'; continue; }
      if (['potentialopportunit', 'opportunit', 'unsolved', 'openproblem', 'openquestion'].some((k) => key.startsWith(k))) { part = 'opportunities'; continue; }
      if (key.startsWith('mathematical') || key.startsWith('math')) { part = 'math'; continue; }
    }
    if (!line || line.startsWith('#')) continue;
    let item = line;
    let isBullet = false;
    for (const marker of ['- ', '* ', '• ']) if (item.startsWith(marker)) { item = item.slice(2); isBullet = true; }
    // A paragraph under a bold claim (or a wrapped bullet) belongs to the item above it.
    const continues = !isBullet && !(item.startsWith('**') && item.endsWith('**')) && !item.startsWith('`');
    if (continues && part === 'takeaways' && takeaways.length) { takeaways[takeaways.length - 1] += ' ' + item; continue; }
    if (continues && part === 'opportunities' && opportunities.length) { opportunities[opportunities.length - 1] += ' ' + item; continue; }
    item = item.replace(/^\d+\.\s*/, '');
    if (part === 'tldr') tldr.push(line);
    else if (part === 'takeaways') takeaways.push(item);
    else if (part === 'math') math.push(item);
    else if (part === 'opportunities') opportunities.push(item);
  }
  if (!tldr.length || !takeaways.length) return null;
  return { tldr: tldr.join(' '), takeaways, math, opportunities };
}

export function parseQuickRead(text) {
  const groups = {};
  let current = '';
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    const key = line.toLowerCase().replace(/[^\p{L}]/gu, '');
    if (line.startsWith('#') || (line.endsWith(':') && line.length < 30) || (line.startsWith('**') && line.endsWith('**') && line.length < 30)) {
      for (const k of ['contribution', 'finding', 'result', 'limitation', 'opportunit']) if (key.includes(k)) current = k;
      continue;
    }
    if (!current || !(line.startsWith('- ') || line.startsWith('* '))) continue;
    (groups[current] ??= []).push(line.slice(2));
  }
  const r = { contributions: groups.contribution ?? [], findings: groups.finding ?? [], results: groups.result ?? [],
    limitations: groups.limitation ?? [], opportunities: groups.opportunit ?? [] };
  return r.contributions.length || r.opportunities.length ? r : null;
}

export const quickTakeaways = (q) => [
  ...q.contributions.map((s) => `**Contribution:** ${s}`), ...q.findings.map((s) => `**Finding:** ${s}`),
  ...q.results.map((s) => `**Result:** ${s}`), ...q.limitations.map((s) => `**Limitation:** ${s}`),
];

// MARK: Sentences and key points

const segmenter = new Intl.Segmenter('en', { granularity: 'sentence' });
export const sentences = (text) => [...segmenter.segment(text)].map((s) => s.segment.trim()).filter(Boolean);

const firstSentences = (text, n) => sentences(text).slice(0, n);

/** Technical facts drawn from the item's tags and metadata (task, library, format, language, arXiv ID). */
export function technicalDetails(item) {
  const skip = ['HN', 'demo', 'Voice', ...VOICE_ROLES.map(capitalize)];
  const tags = (item.tags ?? []).filter((t) => !skip.includes(t));
  if (!tags.length) return '';
  const list = tags.join(', ');
  switch (item.category) {
    case 'models': return `Technical details: ${list}; ${item.tractionLabel ?? ''} on Hugging Face.`;
    case 'code': return `Built with ${list}; ${item.tractionLabel ?? ''} on GitHub.`;
    case 'demos': return `Runs as a ${list} app on Hugging Face Spaces.`;
    case 'papers': case 'reports': return `Reference: ${list}.`;
    default: return '';
  }
}

/** The source's opening sentences plus the technical facts, so the quick read is a TL;DR with some substance. */
export function quickTLDR(item) {
  const opening = firstSentences(item.summary ?? '', 3);
  let tldr = opening.length ? opening.join(' ') : item.title;
  const details = technicalDetails(item);
  if (details) tldr += `${/[.!?]$/.test(tldr) ? '' : '.'} ${details}`;
  return tldr;
}

const tidy = (s) => s.replace(/\(\s+/g, '(').replace(/\s+\)/g, ')').replace(/\s+([,.;:%])/g, '$1').replace(/\s{2,}/g, ' ');
const wordSet = (t) => new Set(t.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter((w) => w.length > 3));

/** Pulls the most important sentences out of a summary and (for papers) the full text, without calling a model. */
export function keyPoints(summary, fullText, exclude, limit = 6) {
  const candidates = [];
  let order = 0;
  const consider = (source, bonus) => {
    for (const raw of sentences(source)) {
      if (raw.length <= 60 || raw.length >= 420 || !/[.!?]["”)]?$/.test(raw) || exclude.includes(raw) || /(Section|Appendix|Sec\.)\s*[A-Z0-9]/.test(raw)) continue;
      const l = raw.toLowerCase();
      let kind = null;
      let s = bonus;
      if (['we propose', 'we introduce', 'we present', 'our contribution', 'this paper', 'in this work'].some((w) => l.includes(w))) { kind = 'Contribution'; s += 3; }
      if (/\d+(\.\d+)?\s?(%|x|×|points|pp)|outperform|state-of-the-art|sota|surpass|improv(es|ement) .*by/.test(l)) { kind = 'Result'; s += 4; }
      if (!kind && /consists of|comprises|we (train|design|use|build|employ)|our (pipeline|architecture|framework|model|method)/.test(l)) { kind = 'Method'; s += 2; }
      if (!kind && /we (find|show|observe|demonstrate)|reveal|suggest/.test(l)) { kind = 'Finding'; s += 2; }
      if (!kind && /limitation|however|fails? to|does not|cannot/.test(l)) { kind = 'Limitation'; s += 1; }
      if (kind) candidates.push({ kind, text: raw, score: s, order: order++ });
    }
  };
  consider(summary ?? '', 2);
  if (fullText) consider(fullText.slice(0, 25_000), 0);

  // Best sentences, at most two of each kind, then shown in reading order.
  const perKind = {};
  const kept = [];
  const chosen = [];
  for (const c of [...candidates].sort((a, b) => b.score - a.score || a.order - b.order)) {
    const w = wordSet(c.text);
    // Skip a sentence that mostly repeats one already chosen (abstract vs. introduction).
    const repeats = kept.some((k) => [...k].filter((x) => w.has(x)).length / Math.max(1, Math.min(k.size, w.size)) > 0.4);
    if ((perKind[c.kind] ?? 0) >= 2 || repeats) continue;
    perKind[c.kind] = (perKind[c.kind] ?? 0) + 1;
    kept.push(w);
    chosen.push(c);
  }
  return chosen.slice(0, limit).sort((a, b) => a.order - b.order).map((c) => `**${c.kind}:** ${tidy(c.text)}`);
}

/** What the authors themselves say is left for future work, as opportunities. */
export function futureWork(text, limit = 3) {
  if (!text) return [];
  const re = /future work|future research|we leave|left for future|remains (open|unexplored|an open)|could be extended|promising direction|natural extension|limitation/;
  return sentences(text.slice(-30_000)).filter((raw) => raw.length > 50 && raw.length < 360 && re.test(raw.toLowerCase()))
    .slice(0, limit).map((raw) => `**From the authors:** ${raw}`);
}

/** Strips Markdown so the voice doesn't read symbols. */
export function speakable(s) {
  return s.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1').replace(/\*\*|__|`|#|\*|_/g, '').replaceAll('TL;DR', 'T L D R').trim();
}

/** Spoken script for anything in the house structure. */
export function spokenScript({ tldr, takeaways = [], math = [], opportunities = [] }) {
  const parts = ['TL;DR.', tldr];
  if (takeaways.length) parts.push('Takeaways.', ...takeaways);
  // Read the prose of the math section; equations are better seen than heard.
  const prose = math.filter((m) => !m.trim().startsWith('`'));
  if (prose.length) parts.push('Mathematical analysis.', ...prose);
  if (opportunities.length) parts.push('Potential opportunities.', ...opportunities);
  return parts;
}
