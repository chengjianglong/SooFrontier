# SooFrontier for the browser

The same crew, desks, and Brainstorm panel as the native app, in any browser. A small Node server does what a browser can't: it fetches the feeds and runs your models. It needs Node 22 or newer and installs nothing else.

```bash
cd web
node server.mjs
```

Then open http://localhost:5180. If the cache is empty, or it predates the latest 6:00 am Pacific, the crew goes out right away.

## Models

Settings works as it does on the Mac. Each provider runs either on your plan, through its official CLI (`claude`, `codex`, `grok`), or on a metered API key. Plans need the CLI signed in on the computer running this server.

## What's stored where

- `~/.soofrontier-web/settings.json`: API keys, saved stories, voices, roles. Readable only by your user. Keys are never sent to the browser.
- `~/.soofrontier-web/cache.json`: the harvest, brief, digests, and quick reads.
- Appearance and Brainstorm options stay in each browser.

Set `SOOFRONTIER_DATA` to keep these somewhere else.

## Reaching it from another device

By default the server only answers this computer. Anyone who reaches it can spend your plan, so anything wider requires an access code, which is printed at startup (or set your own with `SOOFRONTIER_CODE`):

```bash
HOST=0.0.0.0 node server.mjs
```

This serves plain HTTP, so only use it on a network you trust. Browsers also turn off the microphone on plain HTTP, except on localhost; for voice on another device, put the server behind HTTPS.

## Differences from the native apps

- **Refresh:** the 6:00 am Pacific refresh runs on the server, so it happens only while the server is running. It catches up as soon as it next runs or the computer wakes.
- **Mac bridge:** native only. Here, models run where the server runs, or on your local model server.
- **Local models:** point Settings → Local models at an Ollama server (default `http://localhost:11434`, or set `SOOFRONTIER_LOCAL_URL`). Here the local server also takes a Council seat, the Open-Weights Advocate.
- **Listening:** read-aloud uses the browser's voices. It has no lock-screen controls, and may stop when a phone browser goes to the background.
- **Voice input:** needs Chrome or Safari. Other browsers can still type.
- **Video meeting:** uses the native app's stage, read from `../SooFrontier/Resources`, so keep the `web` folder next to it.
