# DOMINO — Hebrew Speech-to-Text PWA

A dead-simple, single-screen web app: tap one button, speak Hebrew, and watch the
text appear live as you talk. Installable as a PWA and works in every browser
(including iOS Safari) — no app store, no native build.

**Live:** https://talbenamii.github.io/domino-web/

## How it works

Live (streaming) transcription over [Groq](https://groq.com) Whisper:

1. The browser records continuously via `getUserMedia` + `MediaRecorder`, split
   into ~30s windows.
2. While you talk, the current window is re-transcribed every few seconds with
   `whisper-large-v3-turbo` and shown as dimmed *interim* text that self-corrects
   as more context arrives.
3. At a natural pause (or a 30s cap) the window is *committed*: an accurate
   `whisper-large-v3` pass freezes it into permanent text and a fresh window
   opens. Tapping stop flushes the final window the same way.
4. All audio is POSTed to a Cloudflare Worker that proxies Groq (`language=he`)
   and holds the API key; the model is chosen per request via `?model=turbo|v3`.

Whisper has no streaming endpoint, so "live" is built by re-transcribing the
growing window; silence-aware commits keep the window boundaries off mid-word.

This replaced an earlier browser Web Speech API approach, which failed in Firefox
(unsupported), Edge/Android (no engine), and gave persistent "network" errors on
desktop.

## Project layout

| Path | Purpose |
|------|---------|
| `docs/index.html` | The entire frontend — UI + live transcription logic |
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
`docs/index.html`). The model is chosen per request (`?model=turbo|v3`, default
`v3`); to change the defaults or prompt, edit `cloudflare-worker.js`, paste it
into the Cloudflare dashboard "Edit code", and Deploy. The
`GROQ_API_KEY` secret is set in the Cloudflare dashboard — **never** committed to
this repo.

## Verify it works

Open the live URL, tap the mic, grant the permission prompt, speak Hebrew —
the transcript appears live (right-aligned, RTL) as you speak, settling into
final text at each pause; tapping stop flushes the last words.
