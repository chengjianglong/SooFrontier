# SooFrontier

A crew of AI agents that reads the AI frontier for you, every morning. For people who work on AI: papers, tech reports, demos, code, models, products, essays, company blogs and voices on X, gathered, checked and summarized in one place.

Mac, iPhone and iPad from one SwiftUI codebase, plus a browser version.

## What it does

- **Eleven agents.** Nine harvesters pull from arXiv, Hugging Face, GitHub, lab and company blogs, product news and X (through Grok search). The Skeptic rates each story and flags hype, and the Synthesizer writes each desk's digest.
- **Five desks.** Brief, Research, Productions, Opinions and Brainstorm, each with lanes, a filter, a digest you can listen to, and Previous / Next paging.
- **A structured read of every story.** A quick read (contributions, findings, results, limitations) and a deeper analysis with takeaways, mathematical analysis and opportunities, plus key figures from the paper.
- **Brainstorm.** A group chat or a video meeting with five model panelists (Skeptic, Builder, Contrarian, Archivist, Synthesizer) whose faces speak their answers, rendered on device with MediaPipe face landmarks.
- **A daily rhythm.** A fresh harvest at 6:00 am Pacific, and read-aloud that keeps going on the lock screen.

## Models

Each provider runs either on a plan you already pay for, through its official CLI on the Mac (`claude`, `codex`, `grok`), or on an API key. iPhone and iPad can pair with a Mac on the same network and use its plans. With no connection, Gemma runs on device through [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM).

## Building the apps

Requires Xcode 16 or newer, iOS 18 and macOS 15. The project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen), and the generated project is checked in.

```bash
open SooFrontier.xcodeproj
```

Set your own team under Signing & Capabilities (or `DEVELOPMENT_TEAM` in `project.yml`) before running on a device.

## The browser version

Lives in [`web/`](web/README.md): a zero-dependency Node 22 server plus a plain JavaScript UI.

```bash
cd web
node server.mjs
```

Then open http://localhost:5180.

## Layout

| Path | What's there |
| --- | --- |
| `SooFrontier/Agents` | Harvesters and thinkers |
| `SooFrontier/Services` | Feeds, model access, CLI runner, Mac bridge, on-device Gemma |
| `SooFrontier/Store` | App state, daily refresh, appearance |
| `SooFrontier/Views`, `Brainstorm` | The desks, story pages and the meeting room |
| `SooFrontier/Resources` | The video meeting stage and panelist portraits |
| `web` | The browser version |
| `design` | App icon sources and demo recordings |
