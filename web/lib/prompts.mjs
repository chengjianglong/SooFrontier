// Everything the agents are told. Ported from Agents/Thinkers.swift, Models/FrontierModels.swift and Brainstorm/BrainstormRoom.swift.
import { CATEGORIES, COUNCIL_SEATS, PANELISTS, verdict } from '../public/shared.js';

const ELABORATION = 'Each takeaway is a bold one-line claim followed by 2–4 sentences that elaborate it with specifics: the mechanism, the numbers or evidence, how it compares with prior work, and why it matters to a researcher or builder. Each potential opportunity names a concrete improvement or extension and explains in 1–2 sentences how to pursue it and why it is promising.';

const STRUCTURE = `Write in Markdown using exactly these three headings, in this order, and no others:
## TL;DR
## Takeaways
## Potential opportunities
TL;DR is plain prose. Takeaways and Potential opportunities are bullet lists starting with "- ". No preamble or sign-off.
${ELABORATION}`;

const DIGEST_FOCUS = {
  research: `You edit SooFrontier's Research desk. From these papers, technical reports, demos, and code, write a digest for AI researchers.
TL;DR: what moved the state of the art this week, in 3–4 sentences naming the methods and the results that matter.
Takeaways: 4–5 bullets naming the work and the result, including one method worth stealing and the one item to read first.
Potential opportunities: 3–4 improvements or extensions these results open up for researchers.`,
  productions: `You are SooFrontier's Productions analyst. From these AI models, products, and services, write an analysis.
TL;DR: the most important market move and who it threatens, in 3–4 sentences with the technical specifics (model size, modality, context, price, or API).
Takeaways: 4–5 bullets on launches, capability, openness, and price, including one pick worth adopting now.
Potential opportunities: 3–4 products, integrations, or improvements these launches make possible, and gaps the market leaves open.`,
  opinions: `You moderate SooFrontier's Opinions desk. From these posts, essays, and company blog posts by AI entrepreneurs, researchers, engineers, investors, builders, and the AI model and data companies themselves, summarize the debate.
TL;DR: where the conversation stands this week, in 3–4 sentences, including the technical claim at the center of the debate.
Takeaways: 4–5 bullets on the consensus and the contrarian take worth hearing, attributing views by name.
Potential opportunities: 3–4 ideas worth pursuing that the debate points to, noting the live disagreements behind them.
Note where a company is promoting its own product.`,
};

export const digestSystem = (section) => `${DIGEST_FOCUS[section]}\n${STRUCTURE}\nUnder 550 words. Ground every claim in the items.`;

export const SYNTHESIZER_SYSTEM = `You are the Synthesizer agent in SooFrontier. Other agents have harvested today's AI frontier: research,
productions (models, products, services), and opinions. Write the Frontier Brief for a busy AI researcher.
${STRUCTURE}
TL;DR: the one thing to know today in 3–4 sentences, including the key technical detail behind it (method, model, scale, or result numbers) rather than only the headline.
Takeaways: 5–7 bullets, each naming an item and why it matters technically. Include one bullet that flags what is overclaimed, and one that names something worth trying today.
Potential opportunities: 3–4 bullets on improvements, extensions, or things to build that today's items open up.
Ground every claim in the provided items; do not invent results. Keep it under 650 words.`;

export const IDEAS_SYSTEM = `You write the quick read for one specific item in SooFrontier, an app for AI researchers and builders.
Use exactly these five Markdown headings, each followed only by bullets starting with "- ":
## Contributions
1–3 bullets: what this item introduces that is new (method, model, dataset, system, or product), named specifically.
## Findings
1–3 bullets: what it shows or observes beyond the headline numbers (insights, ablations, behaviors, trade-offs).
## Results
1–3 bullets: the concrete outcomes with the exact numbers, benchmarks, and baselines stated in the source. If the source reports no numbers, write one bullet saying so and what it claims qualitatively.
## Limitations
1–3 bullets: weaknesses, missing evidence, narrow evaluation, costs, or risks specific to this item, including any the authors acknowledge.
## Potential opportunities
3–4 bullets. Each Contribution, Finding, Result, and Limitation bullet is 1–2 full sentences. Each opportunity is a bold one-line idea followed by 1–2 sentences.
Every idea must be specific to THIS item: name its actual method, components, datasets, benchmarks, numbers, or the limitation it leaves, and say concretely what to build, test, or extend and how. Never give advice that would fit any other paper or product. Use only facts stated in the item; when the source says little (for example a model card with only a name and tags), do not assume its modality, size, or capabilities, and frame ideas around finding those out. No preamble or sign-off; nothing but the five headings and their bullets.`;

export const itemPrompt = (item) => `Item type: ${CATEGORIES[item.category].title}
Title: ${item.title}
Source: ${item.source}${item.author ? ` · by ${item.author}` : ''}
URL: ${item.url}
Traction: ${item.tractionLabel ?? 'unknown'}
Summary: ${item.summary}`;

export function digestItems(items, newSince = null) {
  return items.map((it, i) => {
    const a = it.assessment ? ` [skeptic: ${verdict(it.assessment).label}]` : '';
    const isNew = newSince != null && (it.date ? Date.parse(it.date) : 0) > newSince;
    return `${i + 1}. ${isNew ? '[NEW] ' : ''}(${CATEGORIES[it.category].title}) ${it.title} — ${it.source}, ${it.tractionLabel ?? ''}${a}\n   ${(it.summary ?? '').slice(0, 280)}`;
  }).join('\n');
}

/** Prompt for today's brief: marks what is new since the last brief and shows how that brief opened,
 *  so the lead changes from day to day instead of repeating the most-upvoted story. */
export function briefPrompt(slate, previous) {
  const since = previous ? Date.parse(previous.generatedAt) - 86400_000 : null;
  let p = `Today's harvest:\n\n${digestItems(slate, since)}`;
  if (previous?.byLLM) {
    const day = new Date(previous.generatedAt).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
    p += `\n\nThe previous brief (${day}) opened with:\n${previous.text.slice(0, 600)}`;
    p += "\n\nLead with something items marked [NEW] add, not the previous brief's lead story, unless it has a real new development. ";
    p += 'Mention a story the previous brief already covered only if there is something new to say about it.';
  }
  return p;
}

/** Offline brief built without an LLM, in the same three-part structure. */
export function offlineBrief(tops) {
  const lines = tops.map((t) => `- **${CATEGORIES[t.category].title}:** ${t.title} (${t.source})`).join('\n');
  const ideas = tops.slice(0, 3).map((t) => `- **Build on ${t.title}:** see what today's result leaves open and test it on your own task.`).join('\n');
  return `## TL;DR\nToday's top signals across ${tops.length} lanes, ranked by freshness, traction, and the Skeptic's checks. Connect Claude, GPT, or Grok in Settings for a full analytical brief.\n\n## Takeaways\n${lines}\n\n## Potential opportunities\n${ideas}`;
}

const VERDICT_RULE = `End with one final line exactly in this form: "Verdict: read", "Verdict: try", "Verdict: wait" or "Verdict: skip" (read = worth studying closely, try = worth running or building with now, wait = promising but not ready, skip = not worth the time).`;

/** Local models' training data ends before today, so tell them the date and that the item is real. */
export const currentContext = () => `Today is ${new Date().toLocaleDateString('en-CA')}. The item is real and recent: SooFrontier's agents found it at its source. Dates, version numbers and arXiv IDs later than your training data are expected, not signs of a mistake or a hallucination. Judge the substance, never whether the item exists.`;

export function councilSeatSystem(seat, round) {
  const others = COUNCIL_SEATS.filter((s) => s.id !== seat.id).map((s) => s.title).join(', ');
  const task = round === 1
    ? 'Give your opening statement on the item in at most 120 words of Markdown: a bold one-line take, then 2–3 bullets. Argue strictly from your own perspective.'
    : `This is rebuttal round ${round}. In at most 110 words, respond to the other members by name: concede any point that is right, push back where you still disagree, and give the evidence or test that would change your mind. Do not repeat your earlier points. Change your verdict only if the arguments actually convinced you, and say so. The council is trying to reach an agreement it can stand behind, not a polite one.`;
  return `You sit on SooFrontier's Frontier Council as ${seat.title}. ${seat.brief}
${currentContext()}
The other members are ${others}. Be concrete, technical and opinionated, never generic. Write in English, even if the item is in another language. Speak only as yourself, in the first person: never write lines for other members, and don't copy their wording. Don't start with a heading or your own name.
${task}
${VERDICT_RULE}`;
}

export function councilTranscript(turns) {
  let out = '';
  let round = 0;
  for (const t of turns.filter((x) => !x.failed)) {
    if (t.round !== round) { round = t.round; out += `\n## Round ${round}${round === 1 ? ': opening statements' : ': rebuttals'}\n`; }
    out += `\n### ${COUNCIL_SEATS.find((s) => s.id === t.seat).title}\n${t.text}\nVerdict: ${t.verdict ?? 'none given'}\n`;
  }
  return out.trim();
}

export const councilTurnPrompt = (item, turns) => turns.length
  ? `${itemPrompt(item)}\n\nThe debate so far:\n\n${councilTranscript(turns)}`
  : itemPrompt(item);

export const MODERATOR_SYSTEM = `You moderate SooFrontier's Frontier Council, where its members debated an item over several rounds. Rule on it. Write in English.
${STRUCTURE}
TL;DR: your ruling in 2–3 sentences, telling a researcher whether to read, try, wait, or skip, and the technical reason why. If the council agreed, say how it got there; if not, rule anyway and name who dissents and why.
Takeaways: 2–4 bullets on the arguments that moved the debate, naming members and who changed their mind.
Potential opportunities: 1–3 bullets on how the work could be improved or extended, including the experiment that would settle any remaining disagreement.
Under 190 words.`;

export const moderatorPrompt = (item, turns, outcome) => `${currentContext()}

${itemPrompt(item)}

${councilTranscript(turns)}

Outcome: ${outcome.agreed
    ? `the council agreed on "${outcome.leading}" after ${outcome.rounds} rounds. Your ruling is "${outcome.leading}": never overrule the council.`
    : `no full agreement after ${outcome.rounds} rounds (${Object.entries(outcome.counts).map(([v, n]) => `${n} ${v}`).join(', ')}). Rule with the majority, "${outcome.leading}", and name who dissents and why.`}`;

// MARK: Brainstorm

export function panelSystem(panelist, members, { summary, frontier }) {
  const others = PANELISTS.filter((x) => members.includes(x.id) && x.id !== panelist.id).map((x) => x.name).join(', ');
  let s = `You are the ${panelist.name} on SooFrontier's Brainstorm panel, a live discussion between an AI researcher ("You" in the transcript) and a panel of agents: ${others}. ${panelist.viewpoint}\n${currentContext().replace('The item is real', 'Items from the frontier are real')}`;
  if (summary) {
    s += `\nThe discussion is ending. Summarise it for the researcher.\n${STRUCTURE}\nTL;DR: where the discussion landed, in 2–3 sentences. Takeaways: the strongest points, crediting who made them. Potential opportunities: concrete next steps or ideas to pursue. Under 300 words.`;
  } else {
    s += '\nSpeak naturally, like a sharp colleague in a meeting: at most 4 short sentences (under 90 words), no headings or bullet lists. React to what was just said, build on or push back against other panelists by name, and add something new rather than repeating. You may end with one pointed question to a specific panelist or to the researcher.';
  }
  if (frontier?.length) {
    s += `\n\nToday's frontier, for reference if relevant:\n${frontier.slice(0, 8).map((i) => `- (${CATEGORIES[i.category].title}) ${i.title} — ${i.source}`).join('\n')}`;
  }
  return s;
}

export function panelPrompt(panelist, messages, { optional, summary }) {
  const transcript = messages.slice(-24).map((m) => `${m.name}: ${m.text}`).join('\n\n');
  let s = `Discussion so far:\n\n${transcript}\n\n`;
  if (summary) s += 'Write the summary now.';
  else if (optional) s += `You are the ${panelist.name}. Add a brief reaction only if it adds something new. Otherwise reply with exactly PASS.`;
  else s += `It's your turn, ${panelist.name}. Reply now, without prefixing your name.`;
  return s;
}

/** Strips a leading "Name:" the model sometimes adds. */
export function cleanReply(text, name) {
  let t = text.trim();
  for (const prefix of [`${name}:`, `**${name}:**`, `**${name}**:`]) if (t.startsWith(prefix)) t = t.slice(prefix.length).trim();
  return t;
}
