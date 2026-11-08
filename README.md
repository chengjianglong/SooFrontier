<p align="center">
  <img src="design/icon-ios-1024.png" alt="SooFrontier app icon" width="128">
</p>

<h1 align="center">SooFrontier</h1>

<p align="center">
  A crew of AI agents that reads the AI frontier for you, every morning.<br>
  Mac · iPhone · iPad · Web
</p>

For people who work on AI: papers, tech reports, demos, code, models, products, essays, company blogs and voices on X, gathered, checked and summarized in one place.

## Demos

Recorded on iPhone. Click a preview to watch the full video; the longer ones are sped up here.

| Brief | Research | Opinions | Video meeting |
| :---: | :---: | :---: | :---: |
| [<img src="docs/media/brief.gif" alt="Scrolling the morning Brief" width="200">](design/demo/brief.mp4) | [<img src="docs/media/research.gif" alt="Opening a paper and reading its structured summary" width="200">](design/demo/research.mp4) | [<img src="docs/media/opinions.gif" alt="Voices on X, then company blogs" width="200">](design/demo/opinions.mp4) | [<img src="docs/media/meeting.gif" alt="A Brainstorm video meeting: the Skeptic answers while the Builder waits" width="200">](design/demo/meeting.mp4) |
| The day's read, written by the Council | From a paper list to a structured read | What the people you follow are saying | Panelists speak their answers |

## How it works

```mermaid
flowchart LR
  subgraph Sources
    S1[arXiv · HF Daily Papers]
    S2[Hugging Face · GitHub]
    S3[Lab and company blogs]
    S4[Product and service news]
    S5[Essays]
    S6[X, via Grok search]
  end
  subgraph Harvesters["Nine harvesters"]
    H[Archivist · Librarian · Showrunner<br>Scout · Curator · Analyst<br>Pundit · Correspondent · Listener]
  end
  subgraph Thinkers
    K[Skeptic<br>rates signal and hype]
    Y[Synthesizer<br>desk digests]
    C[Council<br>morning Brief]
  end
  subgraph Desks
    D1[Brief]
    D2[Research]
    D3[Productions]
    D4[Opinions]
    D5[Brainstorm]
  end
  Sources --> H --> K --> Y --> Desks
  K --> C --> D1
```

Every morning at 6:00 am Pacific the harvesters run in parallel and publish as they finish. The Skeptic dedupes and scores each story, then the Synthesizer and the Council write on top of the harvest.

## What it does

- **Eleven agents.** Nine harvesters pull from arXiv, Hugging Face, GitHub, lab and company blogs, product news and X (through Grok search). The Skeptic rates each story and flags hype, and the Synthesizer writes each desk's digest.
- **Five desks.** Brief, Research, Productions, Opinions and Brainstorm, each with lanes, a filter, a digest you can listen to, and Previous / Next paging.
- **A structured read of every story.** A quick read (contributions, findings, results, limitations) and a deeper analysis with takeaways, mathematical analysis and opportunities, plus key figures from the paper.
- **Brainstorm.** A group chat or a video meeting with five model panelists (Skeptic, Builder, Contrarian, Archivist, Synthesizer) whose faces speak their answers, rendered on device with MediaPipe face landmarks.
<p align="center">
  <img src="design/brainstorm-faces.png" alt="The five Brainstorm panelists: Skeptic, Builder, Contrarian, Archivist and Synthesizer" width="720">
</p>

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

![The morning Brief in a browser: the TL;DR, takeaways and top signals across all lanes](docs/media/web-brief.png)

| A story page | Opinions |
| :---: | :---: |
| ![A paper's story page with Analyze, Council and Listen, and the quick read](docs/media/web-story.png) | ![Voices on X, each tagged with the Skeptic's verdict](docs/media/web-opinions.png) |

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
| `docs/media` | README previews and screenshots |

## License

[MIT](LICENSE)
