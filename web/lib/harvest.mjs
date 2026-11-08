// The harvesting agents. Ported from Agents/Harvesters.swift.
import { getJSON, getText, parseFeed, fetchFeeds, plain, parseDate } from './net.mjs';
import { capitalize } from '../public/shared.js';

const validURL = (s) => { try { return ['http:', 'https:'].includes(new URL(s).protocol); } catch { return false; } };

function feedItems(entries, agent, category) {
  return entries.filter(({ entry: e }) => e.title && validURL(e.link)).map(({ source, entry: e }) => ({
    title: plain(e.title, 200), summary: plain(e.summary), url: e.link, source, category, agent,
    author: e.author || null, date: parseDate(e.date), tags: e.categories.slice(0, 4), traction: 0,
  }));
}

async function arxiv(query, max) {
  const q = new URLSearchParams({ search_query: query, sortBy: 'submittedDate', sortOrder: 'descending', max_results: String(max) });
  try { return parseFeed(await getText(`https://export.arxiv.org/api/query?${q}`)); } catch { return []; }
}

const compact = new Intl.NumberFormat('en', { notation: 'compact' });
const firstPart = (id) => id.split('/')[0];

async function hackerNews(query, minPoints, agent, category) {
  const since = Math.floor(Date.now() / 1000) - 86400 * 7;
  const q = new URLSearchParams({ query, tags: 'story', numericFilters: `points>${minPoints},created_at_i>${since}`, hitsPerPage: '20' });
  const r = await getJSON(`https://hn.algolia.com/api/v1/search?${q}`);
  return r.hits.filter((h) => h.title).map((h) => {
    const discussion = `https://news.ycombinator.com/item?id=${h.objectID}`;
    return {
      title: h.title, summary: `${h.points ?? 0} points · ${h.num_comments ?? 0} comments on Hacker News`,
      url: validURL(h.url) ? h.url : discussion, source: 'Hacker News', category, agent, author: h.author ?? null,
      date: parseDate(h.created_at), tags: ['HN'], traction: h.points ?? 0, tractionLabel: `▲ ${h.points ?? 0}`,
    };
  });
}

const orEmpty = (p) => p.catch(() => []);

const LAB_FEEDS = [
  ['Google Research', 'https://research.google/blog/rss/'],
  ['Microsoft Research', 'https://www.microsoft.com/en-us/research/feed/'],
  ['NVIDIA Technical Blog', 'https://developer.nvidia.com/blog/feed'],
  ['Hugging Face', 'https://huggingface.co/blog/feed.xml'],
  ['Berkeley AI Research', 'https://bair.berkeley.edu/blog/feed.xml'],
];

const SCOUT_FEEDS = [
  ['The Verge AI', 'https://www.theverge.com/rss/ai-artificial-intelligence/index.xml'],
  ['TechCrunch AI', 'https://techcrunch.com/category/artificial-intelligence/feed/'],
  ['Ars Technica AI', 'https://arstechnica.com/ai/feed/'],
  ['VentureBeat AI', 'https://venturebeat.com/category/ai/feed/'],
  ['MIT Tech Review', 'https://www.technologyreview.com/topic/artificial-intelligence/feed'],
];

const ANALYST_FEEDS = [
  ['AWS Machine Learning', 'https://aws.amazon.com/blogs/machine-learning/feed/'],
  ['Google Cloud AI', 'https://cloudblog.withgoogle.com/products/ai-machine-learning/rss/'],
  ['Cloudflare AI', 'https://blog.cloudflare.com/tag/ai/rss/'],
  ['Hugging Face', 'https://huggingface.co/blog/feed.xml'],
];

const PUNDIT_FEEDS = [
  ['Simon Willison', 'https://simonwillison.net/atom/everything/'],
  ['Interconnects', 'https://www.interconnects.ai/feed'],
  ['Import AI', 'https://importai.substack.com/feed'],
  ['One Useful Thing', 'https://www.oneusefulthing.org/feed'],
  ['Gary Marcus', 'https://garymarcus.substack.com/feed'],
  ["Lil'Log", 'https://lilianweng.github.io/index.xml'],
  ['The Gradient', 'https://thegradient.pub/rss/'],
  ['Latent Space', 'https://www.latent.space/feed'],
];

// Companies without their own RSS feed are read through Olshansk/rss-feeds, a community project that mirrors their news pages.
const MIRROR = 'https://raw.githubusercontent.com/Olshansk/rss-feeds/main/feeds/';
const CORRESPONDENT_FEEDS = [
  // Model providers
  ['OpenAI', 'https://openai.com/news/rss.xml'],
  ['Anthropic', MIRROR + 'feed_anthropic_news.xml'],
  ['Google DeepMind', 'https://blog.google/technology/google-deepmind/rss/'],
  ['Google AI', 'https://blog.google/technology/ai/rss/'],
  ['Meta AI', MIRROR + 'feed_meta_ai.xml'],
  ['Mistral AI', MIRROR + 'feed_mistral.xml'],
  ['xAI', MIRROR + 'feed_xainews.xml'],
  ['NVIDIA', 'https://blogs.nvidia.com/feed/'],
  ['Together AI', 'https://www.together.ai/blog/rss.xml'],
  // Data companies
  ['Databricks', 'https://www.databricks.com/feed'],
  ['Snorkel AI', 'https://snorkel.ai/feed/'],
];

export const HARVESTERS = {
  async archivist(report) {
    report('Pulling HF Daily Papers…');
    const daily = await orEmpty(getJSON('https://huggingface.co/api/daily_papers?limit=40'));
    const items = daily.map((d) => ({
      title: d.paper.title, summary: plain(d.paper.summary ?? ''), url: `https://arxiv.org/abs/${d.paper.id}`, source: 'HF Daily Papers',
      category: 'papers', agent: 'archivist', author: (d.paper.authors ?? []).slice(0, 3).map((a) => a.name).filter(Boolean).join(', ') || null,
      date: parseDate(d.publishedAt), tags: [`arXiv ${d.paper.id}`],
      traction: (d.paper.upvotes ?? 0) * 10, tractionLabel: `${d.paper.upvotes ?? 0} upvotes`,
    }));
    report('Scanning arXiv for new work…');
    const cats = '(cat:cs.AI OR cat:cs.LG OR cat:cs.CL OR cat:cs.CV)';
    const asArxiv = (entries) => entries.map((entry) => ({ source: 'arXiv', entry }));
    items.push(...feedItems(asArxiv(await arxiv(cats, 25)), 'archivist', 'papers'));
    report('Collecting technical reports…');
    items.push(...feedItems(asArxiv(await arxiv(`ti:"technical report" AND ${cats}`, 20)), 'archivist', 'reports'));
    items.push(...feedItems(await fetchFeeds(LAB_FEEDS), 'archivist', 'reports'));
    return items.map((i) => ({ ...i, tags: i.tags.filter((t) => !t.startsWith('cs.') || i.source === 'arXiv') }));
  },

  async showrunner(report) {
    report('Queueing up trending Spaces…');
    const spaces = await getJSON('https://huggingface.co/api/spaces?sort=trendingScore&direction=-1&limit=36&full=true');
    return spaces.map((s) => ({
      title: s.cardData?.title ? `${s.cardData.emoji ?? '✨'} ${s.cardData.title}` : s.id,
      summary: s.cardData?.short_description ?? `Interactive demo by ${firstPart(s.id)}`,
      url: `https://huggingface.co/spaces/${s.id}`, source: 'HF Spaces', category: 'demos', agent: 'showrunner', author: firstPart(s.id),
      date: parseDate(s.lastModified ?? s.createdAt), tags: [s.sdk ?? 'demo'], traction: (s.likes ?? 0) * 3, tractionLabel: `${s.likes ?? 0} likes`,
    }));
  },

  async librarian(report) {
    report('Searching GitHub for rising repos…');
    const since = new Date(Date.now() - 86400_000 * 45).toISOString().slice(0, 10);
    // GitHub search can't OR qualifiers, so ask once per topic and merge.
    const repos = (await Promise.all(['llm', 'ai-agents', 'machine-learning'].map(async (topic) => {
      const q = new URLSearchParams({ q: `topic:${topic} created:>${since}`, sort: 'stars', order: 'desc', per_page: '15' });
      try { return (await getJSON(`https://api.github.com/search/repositories?${q}`)).items; } catch { return []; }
    }))).flat();
    if (!repos.length) throw new Error('GitHub search unavailable');
    return repos.map((r) => ({
      title: r.full_name, summary: r.description ?? 'Open-source project', url: r.html_url, source: 'GitHub', category: 'code', agent: 'librarian',
      author: firstPart(r.full_name), date: parseDate(r.created_at), tags: [r.language, ...(r.topics ?? [])].filter(Boolean).slice(0, 4),
      traction: r.stargazers_count, tractionLabel: `★ ${compact.format(r.stargazers_count)}`,
    }));
  },

  async curator(report) {
    report('Reading the Hugging Face leaderboard…');
    const models = await getJSON('https://huggingface.co/api/models?sort=trendingScore&direction=-1&limit=40');
    return models.map((m) => {
      const org = m.id.includes('/') ? firstPart(m.id) : 'community';
      const task = m.pipeline_tag?.replaceAll('-', ' ') ?? 'model';
      const downloads = m.downloads != null ? `${compact.format(m.downloads)} downloads` : '';
      const interesting = (m.tags ?? []).filter((t) => !t.includes(':') && t.length < 20).slice(0, 4);
      return {
        title: m.id, summary: `Trending ${task} from ${org}. ${downloads}`, url: `https://huggingface.co/${m.id}`, source: 'Hugging Face',
        category: 'models', agent: 'curator', author: org, date: parseDate(m.createdAt), tags: [task, ...interesting],
        traction: (m.likes ?? 0) * 5, tractionLabel: `${m.likes ?? 0} likes`,
      };
    });
  },

  async scout(report) {
    report(`Sweeping ${SCOUT_FEEDS.length} newsrooms…`);
    const items = feedItems(await fetchFeeds(SCOUT_FEEDS), 'scout', 'products');
    report('Checking launches on Hacker News…');
    return [...items, ...await orEmpty(hackerNews('AI launch OR launches OR released OR introducing', 100, 'scout', 'products'))];
  },

  async analyst(report) {
    report(`Reading ${ANALYST_FEEDS.length} platform blogs…`);
    // Hugging Face's blog is mostly research; keep only its platform and pricing posts here.
    const items = feedItems(await fetchFeeds(ANALYST_FEEDS), 'analyst', 'services')
      .filter((i) => i.source !== 'Hugging Face' || /inference|endpoint|hub/i.test(i.title));
    report('Checking API and pricing news…');
    return [...items, ...await orEmpty(hackerNews('AI API pricing OR "inference API" OR "AI platform"', 60, 'analyst', 'services'))];
  },

  async pundit(report) {
    report(`Reading ${PUNDIT_FEEDS.length} newsletters…`);
    return feedItems(await fetchFeeds(PUNDIT_FEEDS), 'pundit', 'essays');
  },

  async correspondent(report) {
    report(`Reading ${CORRESPONDENT_FEEDS.length} company blogs…`);
    const items = feedItems(await fetchFeeds(CORRESPONDENT_FEEDS), 'correspondent', 'companies');
    if (!items.length) throw new Error('Company blogs unavailable');
    return items;
  },

  /** Voices on X, read by Grok on the SuperGrok plan. */
  async listener(report, { voices, grok }) {
    if (!grok) throw new Error('Connect Grok in Settings to hear voices on X');
    if (grok.mode !== 'subscription') throw new Error('Voices on X need Grok on your SuperGrok plan');
    if (!voices.length) return [];
    const roles = new Map(voices.map((v) => [v.handle.toLowerCase(), v.role]));
    const batches = [];
    for (let i = 0; i < voices.length; i += 7) batches.push(voices.slice(i, i + 7));
    report(`Asking Grok about ${voices.length} voices on X…`);
    const system = 'You are the Listener agent in SooFrontier, an app for AI researchers. Use X search to read recent posts. Reply ONLY with a JSON array, with no prose before or after it.';
    const results = await Promise.allSettled(batches.map(async (batch) => {
      const handles = batch.map((v) => `@${v.handle}`).join(', ');
      const prompt = `Use X search on posts from these accounts in the last 7 days: ${handles}.
For each account, summarize their most notable opinion about AI.
Reply ONLY with a JSON array of objects with keys: name, handle (without @), headline (at most 12 words), summary (2 sentences), url (link to the post on x.com), date (ISO 8601).
Skip accounts with no AI posts in that window. Never invent posts or links.`;
      const text = await grok.complete({ system, prompt, maxTokens: 8000, research: true });
      const start = text.indexOf('['), end = text.lastIndexOf(']');
      if (start < 0 || end <= start) return [];
      try { return JSON.parse(text.slice(start, end + 1)); } catch { return []; }
    }));
    const posts = results.flatMap((r) => (r.status === 'fulfilled' ? r.value : []));
    const failure = results.find((r) => r.status === 'rejected');
    if (!posts.length && failure) throw failure.reason;
    return posts.filter((p) => {
      if (!validURL(p.url) || !p.handle) return false;
      const host = new URL(p.url).hostname;
      return /(^|\.)(x|twitter)\.com$/.test(host);
    }).map((p) => {
      const handle = p.handle.replace(/^[@\s]+|[@\s]+$/g, '');
      const role = roles.get(handle.toLowerCase());
      return {
        title: p.headline ?? `Post by @${handle}`, summary: p.summary ?? '', url: p.url, source: `@${handle}`, category: 'voices', agent: 'listener',
        author: p.name ?? null, date: parseDate(p.date), tags: [role ? capitalize(role) : 'Voice'], traction: 0,
      };
    });
  },
};
