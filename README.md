# DOMINO — Hebrew Speech-to-Text PWA

A dead-simple, single-screen web app: tap one button, speak Hebrew, get the text
back in about a second. Installable as a PWA and works in every browser
(including iOS Safari) — no app store, no native build.

**Live:** https://talbenamii.github.io/domino-web/

## How it works

Record-then-transcribe (not live word-by-word):

1. The browser captures a short audio clip via `getUserMedia` + `MediaRecorder`.
2. The clip is POSTed to a Cloudflare Worker.
3. The Worker proxies [Groq](https://groq.com) `whisper-large-v3` (`language=he`)
   and returns the Hebrew transcript.

This replaced an earlier browser Web Speech API approach, which failed in Firefox
(unsupported), Edge/Android (no engine), and gave persistent "network" errors on
desktop.

## Project layout

| Path | Purpose |
|------|---------|
| `docs/index.html` | The entire frontend — UI + record/transcribe logic |
| `docs/manifest.json` | PWA manifest (installable, DOMINO branding) |
| `docs/sw.js` | Service worker — network-first so updates aren't pinned behind a stale cache |
| `docs/icon.svg` | App icon (dark/red DOMINO theme) |
| `cloudflare-worker.js` | Backend — proxies Groq Whisper, holds `GROQ_API_KEY` |

## Deploy

GitHub Pages serves the site from **`main` / `/docs`**. To update the live site:

```bash
# edit files in docs/, then:
git commit -am "..." && git push   # Pages redeploys automatically
```

### Backend (Cloudflare Worker)

The frontend posts clips to a Cloudflare Worker at
`https://domino-stt.talba225.workers.dev/` (constant `WORKER_URL` in
`docs/index.html`). To change the model or prompt, edit `cloudflare-worker.js`,
paste it into the Cloudflare dashboard "Edit code", and Deploy. The
`GROQ_API_KEY` secret is set in the Cloudflare dashboard — **never** committed to
this repo.

## Verify it works

Open the live URL, tap the mic, grant the permission prompt, speak Hebrew —
the transcript appears (right-aligned, RTL) within ~1s of tapping stop.
