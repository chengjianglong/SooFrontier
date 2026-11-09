Tools Available:
- markitdown: convert PDFs and documents to Markdown
- agent-browser: browse and interact with web pages from the shell
- gh: GitHub CLI; repo owner is dev-ansung, so use GH_TOKEN="$(gh auth token --user dev-ansung)"
- git, node, pnpm, npx, uv, python3, ffmpeg, jq, rg, dig, curl: standard CLIs
- wrangler: Cloudflare Workers, D1, R2
- vercel: not installed; use pnpm dlx vercel@65.11.0
- BeatBrowser MCP: drives the user's logged-in Chrome (reconnect the extension if dropped)
- .mcp.json MCPs: shadcn, context7, chrome-devtools, vercel, cloudflare (docs, observability, bindings)
- Claude Docs and Artifact (Design, Design System, Dashboard, Docs, Motion, Slides)
- Skills: frontend-design, design-system, ui-skills-root, shadcn

Rule
- Never write UI code, always use components and abstractions
- Data should always be separated from presentation and code
- Never create fake data/ui, it is better to leave it as stubbed content when not implemented so it doesnt mislead implementer on what is implemented
- For non-trivial task, always look for agent skill then suggest me to install it if not already available.