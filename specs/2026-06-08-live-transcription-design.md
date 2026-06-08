# DOMINO live transcription — design

**Date:** 2026-06-08
**Status:** Approved (pending implementation plan)
**Scope:** Web app only (`docs/index.html`) + a minor `cloudflare-worker.js` change. Flutter is no longer part of this project.

## Problem

Today transcription is **batch**: `MediaRecorder` captures the whole clip and only on **stop** does the app send one blob to the Cloudflare Worker → Groq Whisper → text is appended. Nothing appears while the user talks.

The user wants to **see the transcript update live while talking** ("pipe").

## Constraint that shapes everything

Groq Whisper has **no streaming/partial endpoint** — it transcribes complete audio files. The browser's native `SpeechRecognition` (which *is* streaming) has no Hebrew support on iOS Safari, and iOS is a required target. So "live" must be built by **chunking** audio and transcribing pieces as the user speaks.

Use pattern: **mixed length** (short and long sessions), **iOS matters**.

## Chosen approach: cumulative window with commit (Approach 2)

One continuous recording is split into ~30s **windows**:

- **Within a window**, every ~4s we re-transcribe the whole window-so-far and show it as **interim** (provisional, dimmed) text. Because each pass sees more context, the text **self-corrects** and never clips a word mid-window.
- **A window ends** ("commit") when a pause is detected after ~12s, or at a hard cap of ~30s. On commit we do one accurate final transcription, freeze it as permanent text, and open a fresh window.

Rejected alternatives:
- **Approach 1 (rolling fixed 5s segments):** ~1× cost but clips a word every 5s boundary. Too rough.
- **Approach 3 (pure cumulative, no reset):** best accuracy but O(n²) cost and growing latency. Fails the "long session" half of "mixed".

### Refinements folded in
- **Model split:** interim updates use `whisper-large-v3-turbo` (faster/cheaper); commit + end-of-recording flush use `whisper-large-v3` (most accurate).
- **Interim styling:** provisional text is dimmed/italic so the user can see what is still settling vs. committed.
- **Silence-aware commit:** preferring to commit at a pause means the brief recorder-restart gap lands in silence — so no word is ever clipped or lost at a window boundary. This is what makes "robust" hold up.

### Accepted trade-off
Cumulative interim re-sends cost ~3–5× the Groq usage of batch transcription. For a personal field tool this is still cents/hour. Accepted by the user.

## Architecture

All client logic lives in `docs/index.html` (zero-dependency vanilla JS, single file). The Worker stays a stateless transcription proxy.

### State model
- `committedText` — finalized text, never changes
- `interimText` — current window's latest provisional transcription
- `windowChunks[]` — audio chunks for the current window
- `windowId` — increments on each commit; used to discard stale interim responses
- `inFlight` — at most one transcription request at a time (overlap guard)
- existing `recording` / `busy`, plus a brief `finalizing` state

### Tunable constants (top of script)
| Constant | Default | Meaning |
|---|---|---|
| `TIMESLICE_MS` | 1000 | MediaRecorder chunk cadence |
| `INTERIM_INTERVAL_MS` | 4000 | how often the current window is re-transcribed |
| `WINDOW_SOFT_MS` | 12000 | after this, commit at the next detected pause |
| `WINDOW_HARD_MS` | 30000 | force-commit even without a pause |
| `SILENCE_RMS` | (tuned on-device) | RMS below this counts as silence |
| `SILENCE_HOLD_MS` | 350 | sustained silence needed to call it a pause |

## Recording & windowing

- `MediaRecorder.start(TIMESLICE_MS)` → chunks arrive every 1s into `windowChunks`. Concatenating chunks from window start is always a valid webm, so interim blobs need **no** recorder restart.
- **Commit trigger** = `shouldCommit(windowMs, isSilent)`:
  `windowMs ≥ WINDOW_HARD_MS` **OR** (`windowMs ≥ WINDOW_SOFT_MS` **AND** `isSilent`). One small pure function so it is easy to simplify later.
- **Silence detection:** a Web Audio `AnalyserNode` measures RMS while recording; `isSilent` is true after `SILENCE_HOLD_MS` of sustained sub-threshold audio.
- **Commit sequence:** `recorder.stop()` → in `onstop`, build the finished window blob, fire the accurate (v3) final transcription, **immediately** `start()` a new recorder, bump `windowId`, clear `windowChunks`. The restart gap is sub-100ms and (thanks to silence-aware commit) normally lands in a pause.

## Transcription pipeline

- **Interim:** every `INTERIM_INTERVAL_MS`, if not `inFlight` and `windowChunks` is non-empty, build a blob from the current window and POST with the **turbo** model. Capture `windowId` at send time; apply the response only if `windowId` is unchanged (else discard as stale).
- **Commit/final:** POST the finished window blob with the **v3** model; on success append to `committedText` and clear `interimText`.
- **Stop:** flush the final partial window (v3), append, then go idle.
- **In-flight rules:** `inFlight` gates only *interim* requests (at most one at a time; a tick that fires mid-request is skipped). A commit/final request is **not** gated by `inFlight` and always proceeds. If an interim request is still in flight when a commit fires, the commit bumps `windowId`, so that interim's eventual response is discarded as stale — no special cancellation needed.

## Worker change (`cloudflare-worker.js`)

Accept `?model=turbo|v3` on the request URL. `turbo` → `whisper-large-v3-turbo`; anything else (and the no-param default) → `whisper-large-v3`. Language `he` and temperature `0` unchanged. Backward-compatible.

## UI / rendering

- Transcript = `committedText` followed by a dimmed/italic span of `interimText`, auto-scrolled to bottom.
- Status line: recording → "מקליט… תמלול חי"; just after stop → brief "מסיים תמלול…"; idle → existing prompt.
- Mic button: pulse while recording, short spinner while finalizing.
- Copy / Clear act on `committedText + interimText` combined; Clear resets both.

## Error handling

- **Interim failure:** silently skip that tick (transient); the next tick retries with more audio.
- **Commit/final failure:** retry once; if it still fails, keep recording and show a one-time toast that part of the transcript failed. Never tear down the session on a single network blip.
- **Offline mid-session:** recording continues; because interim sends are cumulative, the next send self-heals when the network returns.
- **Mic denied / unsupported:** existing error paths unchanged.
- **Memory:** `windowChunks` is cleared on every commit, so memory stays bounded on long sessions. The audio context and stream are torn down on stop.

## Testing

The repo is a zero-dependency single-file PWA with no test harness. Verification is a **manual matrix** across desktop Chrome, Android Chrome, and iOS Safari:

1. Interim text appears within ~5s of speaking and refines in place.
2. A multi-minute session commits repeatedly without memory growth or runaway latency.
3. Stop flushes the final words into committed text.
4. Going offline mid-session and back recovers without losing the session.
5. Denying mic permission shows the existing error.

`shouldCommit` and the RMS helper are pure functions, so a tiny standalone test page could be added later — deferred as YAGNI for v1.

## Out of scope (v1)

- Punctuation/diarization, speaker labels.
- Editing committed text in place.
- A test harness / build tooling (stays a single static file).
- Switching STT providers.
