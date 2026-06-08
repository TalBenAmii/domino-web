# Live Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the DOMINO web app show Hebrew transcript text live while the user is still talking, instead of only after they stop.

**Architecture:** One continuous `MediaRecorder` session split into ~30s windows. Every ~4s the current window is re-transcribed (Groq `whisper-large-v3-turbo`) and shown as dimmed *interim* text that self-corrects. When a pause is detected after 12s (or a 30s hard cap) the window is *committed*: one accurate pass (`whisper-large-v3`) freezes it as permanent text and a fresh window opens. Silence-aware commit keeps the recorder-restart gap inside pauses so no word is clipped.

**Tech Stack:** Vanilla JS in a single static file (`docs/index.html`), `MediaRecorder` + Web Audio `AnalyserNode`, Cloudflare Worker proxy (`cloudflare-worker.js`) to Groq Whisper. No build step, no runtime dependencies.

**Testing note:** This repo has no test harness and the spec keeps it that way for v1 (user-confirmed). Verification is scripted manual browser testing. The two pure helpers (`shouldCommit`, `computeRms`) are written standalone so a `node:test` suite can be added later without refactor.

**Reference spec:** `specs/2026-06-08-live-transcription-design.md`

---

## File Structure

- **`cloudflare-worker.js`** (modify) — accept `?model=turbo|v3`, default `v3`. Stays a stateless transcription proxy.
- **`docs/index.html`** (modify) — the entire feature lives in the inline `<script>` plus one CSS rule. Sections touched: constants block, new state vars, pure helpers, recorder lifecycle, interim loop, silence monitor, commit/rotate, stop/flush, `render()`, copy/clear handlers, one `.interim` style.

No new files. The change in `index.html` is one cohesive rewrite of the recording core, so it is a single task (Task 2) with ordered sub-steps rather than fake-independent fragments that would leave the file mid-broken. Task 1 (Worker) and Task 3 (device matrix + tuning) bracket it.

---

## Task 1: Worker accepts a model parameter

**Files:**
- Modify: `cloudflare-worker.js`

**Why first / graceful degradation:** The old deployed Worker ignores query params and always uses `whisper-large-v3`. So the app keeps working even before this is redeployed — it just won't get the turbo speedup on interim updates. Redeploy is a manual Cloudflare-dashboard step the user performs; it is not required for the app to function.

- [ ] **Step 1: Replace the single `MODEL` constant with a model map**

In `cloudflare-worker.js`, find:

```js
const GROQ_URL = 'https://api.groq.com/openai/v1/audio/transcriptions';
const MODEL = 'whisper-large-v3';
const LANGUAGE = 'he';
```

Replace with:

```js
const GROQ_URL = 'https://api.groq.com/openai/v1/audio/transcriptions';
const MODELS = {
  turbo: 'whisper-large-v3-turbo',
  v3: 'whisper-large-v3',
};
const DEFAULT_MODEL = 'v3';
const LANGUAGE = 'he';
```

- [ ] **Step 2: Select the model from the request URL**

Find this block inside `fetch`:

```js
    const type = request.headers.get('Content-Type') || 'audio/webm';
    const buf = await request.arrayBuffer();
    if (!buf || buf.byteLength === 0) return json({ error: 'empty audio' }, 400);
```

Replace with:

```js
    const type = request.headers.get('Content-Type') || 'audio/webm';
    const buf = await request.arrayBuffer();
    if (!buf || buf.byteLength === 0) return json({ error: 'empty audio' }, 400);

    const modelKey = new URL(request.url).searchParams.get('model');
    const model = MODELS[modelKey] || MODELS[DEFAULT_MODEL];
```

- [ ] **Step 3: Use the selected model in the form**

Find:

```js
    form.append('model', MODEL);
```

Replace with:

```js
    form.append('model', model);
```

- [ ] **Step 4: Verify by reading the diff**

Run: `git -C /home/tal/DOMINO diff cloudflare-worker.js`
Expected: `MODEL` is gone; `MODELS`/`DEFAULT_MODEL` added; `model` is derived from `?model=` with a v3 fallback; `form.append('model', model)`. No other lines changed.

- [ ] **Step 5: Commit**

```bash
git -C /home/tal/DOMINO add cloudflare-worker.js
git -C /home/tal/DOMINO commit -m "Worker: accept ?model=turbo|v3 (default v3)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 6: Flag the manual redeploy**

Tell the user: the app works without redeploying (old Worker = v3 everywhere). To enable turbo on interim updates, paste the new `cloudflare-worker.js` into the Cloudflare dashboard and Deploy. This is manual and cannot be automated from here.

---

## Task 2: Streaming transcription core in the web app

**Files:**
- Modify: `docs/index.html`

This replaces the batch record→stop→transcribe core with the windowed streaming core. Do the steps in order; the file is non-working between Step 3 and Step 11, so do not stop partway. Full verification is Step 12.

- [ ] **Step 1: Add the interim text style**

In the `<style>` block, find the `.transcript` rule:

```css
    .transcript {
      flex: 1;
      overflow-y: auto;
      padding: 20px;
      font-size: 23px;
      line-height: 1.6;
      white-space: pre-wrap;
      word-break: break-word;
    }
```

Immediately after it, add:

```css
    .transcript .interim { color: var(--muted); font-style: italic; }
```

- [ ] **Step 2: Add tunable constants**

Find:

```js
    const WORKER_URL = 'https://domino-stt.talba225.workers.dev/';
    // ──────────────────────────────────────────────────────────────────────
```

Immediately after, add:

```js
    // ── Streaming tunables (dial in on-device) ────────────────────────────
    const TIMESLICE_MS        = 1000;   // MediaRecorder chunk cadence
    const INTERIM_INTERVAL_MS = 4000;   // how often the live window re-transcribes
    const WINDOW_SOFT_MS      = 12000;  // after this, commit at the next pause
    const WINDOW_HARD_MS      = 30000;  // force-commit even without a pause
    const SILENCE_RMS         = 0.012;  // RMS below this counts as silence
    const SILENCE_HOLD_MS     = 350;    // sustained silence that counts as a pause
    // ──────────────────────────────────────────────────────────────────────
```

- [ ] **Step 3: Replace the state variables**

Find:

```js
    let mediaRecorder = null;
    let mediaStream   = null;
    let chunks        = [];
    let recording     = false;  // mic is capturing
    let busy          = false;  // uploading + transcribing
    let finalText     = '';
    let errorText     = '';
```

Replace with:

```js
    let mediaRecorder = null;
    let mediaStream   = null;
    let currentMime   = '';
    let audioCtx      = null;
    let analyser      = null;
    let silenceRAF    = null;

    let windowChunks  = [];     // audio chunks for the current window
    let windowId      = 0;      // bumps on each commit; invalidates stale interims
    let windowStart   = 0;      // Date.now() when the current window opened
    let interimTimer  = null;
    let inFlight      = false;  // an interim request is in flight
    let committing    = false;  // a window rotate / final stop is in progress

    let belowSinceTs  = 0;      // when audio first dropped below SILENCE_RMS (0 = above)
    let isSilent      = false;

    let recording     = false;  // mic is capturing
    let finalizing    = false;  // stopped, flushing the final window
    let committedText = '';     // permanent text, never rewritten
    let interimText   = '';     // current window's provisional text
    let errorText     = '';
```

- [ ] **Step 4: Add the pure helpers**

Immediately after the state variables (before `function render()`), add:

```js
    // ── Pure helpers (no DOM / no IO; safe to unit-test later) ─────────────
    function shouldCommit(windowMs, silent) {
      if (windowMs >= WINDOW_HARD_MS) return true;
      if (windowMs >= WINDOW_SOFT_MS && silent) return true;
      return false;
    }
    function computeRms(samples) {
      let sum = 0;
      for (let i = 0; i < samples.length; i++) sum += samples[i] * samples[i];
      return Math.sqrt(sum / samples.length);
    }
```

- [ ] **Step 5: Rewrite `render()` for committed + interim**

Find the whole existing `function render() { ... }` (from `function render() {` through its closing `}` before `function showToast`). Replace it with:

```js
    function render() {
      const safe = s => s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
      const hasText = !!(committedText.trim() || interimText.trim());
      if (hasText) {
        let html = safe(committedText);
        if (interimText) {
          html = (html ? html + ' ' : '') + '<span class="interim">' + safe(interimText) + '</span>';
        }
        transEl.innerHTML = html;
        transEl.scrollTop = transEl.scrollHeight;
      } else {
        transEl.innerHTML =
          '<div class="placeholder">' +
          '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 14a3 3 0 0 0 3-3V5a3 3 0 0 0-6 0v6a3 3 0 0 0 3 3z"/><path d="M17 11a5 5 0 0 1-10 0H5a7 7 0 0 0 6 6.92V21h2v-3.08A7 7 0 0 0 19 11h-2z"/></svg>' +
          '<div>הטקסט שלך יופיע כאן</div></div>';
      }

      copyBtn.classList.toggle('show', hasText);
      clearBtn.classList.toggle('show', hasText);

      micBtn.classList.toggle('recording', recording);
      micBtn.classList.toggle('busy', finalizing);
      micIcon.innerHTML = finalizing ? ICON_SPIN : (recording ? ICON_STOP : ICON_MIC);

      document.body.classList.toggle('is-recording', recording);
      document.body.classList.toggle('is-busy', finalizing);

      statusEl.className = 'status';
      if (errorText)        { statusEl.textContent = errorText;                statusEl.classList.add('error'); }
      else if (finalizing)  { statusEl.textContent = 'מסיים תמלול…';            statusEl.classList.add('active'); }
      else if (recording)   { statusEl.textContent = 'מקליט… תמלול חי';         statusEl.classList.add('active'); }
      else                  { statusEl.textContent = 'הקש על המיקרופון כדי להתחיל'; }
    }
```

- [ ] **Step 6: Add the shared transcription POST helper**

Immediately after `function pickMime() { ... }`, add:

```js
    // POST one audio blob to the Worker with a chosen model; returns trimmed text.
    async function transcribeBlob(blob, modelKey) {
      const type = blob.type || currentMime || 'audio/webm';
      const url = WORKER_URL + (WORKER_URL.indexOf('?') >= 0 ? '&' : '?') + 'model=' + modelKey;
      const res = await fetch(url, { method: 'POST', headers: { 'Content-Type': type }, body: blob });
      if (!res.ok) throw new Error('HTTP ' + res.status);
      const data = await res.json();
      return (data && data.text ? String(data.text) : '').trim();
    }
```

- [ ] **Step 7: Replace `startRecording` / `stopRecording` and add the recorder lifecycle**

Find both `async function startRecording() { ... }` and `function stopRecording() { ... }` and replace the pair with:

```js
    function startWindowRecorder() {
      try {
        mediaRecorder = currentMime ? new MediaRecorder(mediaStream, { mimeType: currentMime })
                                    : new MediaRecorder(mediaStream);
      } catch (_) {
        mediaRecorder = new MediaRecorder(mediaStream);
      }
      windowChunks = [];
      windowStart  = Date.now();
      mediaRecorder.ondataavailable = (e) => {
        if (e.data && e.data.size) windowChunks.push(e.data);
        maybeCommit();
      };
      mediaRecorder.onstop = onWindowStop;
      mediaRecorder.start(TIMESLICE_MS);
    }

    function maybeCommit() {
      if (committing || finalizing || !recording) return;
      if (shouldCommit(Date.now() - windowStart, isSilent)) {
        committing = true;
        try { mediaRecorder.stop(); } catch (_) { committing = false; }
      }
    }

    function onWindowStop() {
      const type = currentMime || (windowChunks[0] && windowChunks[0].type) || 'audio/webm';
      const blob = windowChunks.length ? new Blob(windowChunks, { type }) : null;
      windowId++;             // any interim still in flight for the old window is now stale
      windowChunks = [];
      interimText  = '';      // cleared synchronously so the next window starts clean
      committing   = false;
      const wasFinalizing = finalizing;

      if (wasFinalizing) cleanupStream();
      else               startWindowRecorder();   // open the next window immediately

      if (blob && blob.size) commitTranscribe(blob, wasFinalizing);
      else if (wasFinalizing) finishIdle();
      else render();
    }

    // Accurate (v3) transcription of a finished window; appends to permanent text.
    async function commitTranscribe(blob, isFinal) {
      let text = '';
      for (let attempt = 0; attempt < 2; attempt++) {       // one retry on failure
        try { text = await transcribeBlob(blob, 'v3'); break; }
        catch (_) { if (attempt === 1) showToast('חלק מהתמלול נכשל'); }
      }
      if (text) committedText = committedText ? (committedText + ' ' + text) : text;
      if (isFinal) finishIdle();
      else render();
    }

    function finishIdle() {
      finalizing = false;
      render();
    }

    function cleanupStream() {
      if (mediaStream) { mediaStream.getTracks().forEach(t => t.stop()); mediaStream = null; }
    }

    async function startRecording() {
      errorText = '';
      try {
        mediaStream = await navigator.mediaDevices.getUserMedia({ audio: true });
      } catch (_) {
        errorText = 'נא לאשר גישה למיקרופון';
        render();
        return;
      }
      currentMime = pickMime();
      interimText = '';
      recording   = true;
      finalizing  = false;
      startWindowRecorder();
      startSilenceMonitor();
      startInterimTimer();
      render();
    }

    function stopRecording() {
      recording  = false;
      finalizing = true;
      stopInterimTimer();
      stopSilenceMonitor();
      render();   // show the finalizing spinner
      if (mediaRecorder && mediaRecorder.state !== 'inactive') {
        committing = true;
        try { mediaRecorder.stop(); }            // onstop flushes the final window + finishIdle
        catch (_) { committing = false; cleanupStream(); finishIdle(); }
      } else {
        cleanupStream();
        finishIdle();
      }
    }
```

- [ ] **Step 8: Add the interim loop**

Immediately after `stopRecording`, add:

```js
    function startInterimTimer() {
      stopInterimTimer();
      interimTimer = setInterval(interimTick, INTERIM_INTERVAL_MS);
    }
    function stopInterimTimer() {
      if (interimTimer) { clearInterval(interimTimer); interimTimer = null; }
    }
    async function interimTick() {
      if (inFlight || committing || !windowChunks.length) return;
      const type  = currentMime || windowChunks[0].type || 'audio/webm';
      const blob  = new Blob(windowChunks, { type });
      const reqId = windowId;          // capture the window this request belongs to
      inFlight = true;
      try {
        const text = await transcribeBlob(blob, 'turbo');
        if (reqId === windowId) {       // still the same window → apply; else discard
          interimText = text;
          render();
        }
      } catch (_) {
        // transient: skip this tick, the next one has more audio
      } finally {
        inFlight = false;
      }
    }
```

- [ ] **Step 9: Add the silence monitor**

Immediately after `interimTick`, add:

```js
    function startSilenceMonitor() {
      belowSinceTs = 0;
      isSilent = false;
      try {
        const Ctx = window.AudioContext || window.webkitAudioContext;
        audioCtx = new Ctx();
        audioCtx.resume && audioCtx.resume().catch(() => {});
        const src = audioCtx.createMediaStreamSource(mediaStream);
        analyser = audioCtx.createAnalyser();
        analyser.fftSize = 1024;
        src.connect(analyser);
        const buf = new Float32Array(analyser.fftSize);
        const tick = () => {
          if (!recording || !analyser) return;
          analyser.getFloatTimeDomainData(buf);
          const now = Date.now();
          if (computeRms(buf) < SILENCE_RMS) {
            if (!belowSinceTs) belowSinceTs = now;
            isSilent = (now - belowSinceTs) >= SILENCE_HOLD_MS;
          } else {
            belowSinceTs = 0;
            isSilent = false;
          }
          silenceRAF = requestAnimationFrame(tick);
        };
        silenceRAF = requestAnimationFrame(tick);
      } catch (_) {
        // No Web Audio → isSilent stays false → windows commit at the hard cap only.
        audioCtx = null; analyser = null;
      }
    }
    function stopSilenceMonitor() {
      if (silenceRAF) cancelAnimationFrame(silenceRAF);
      silenceRAF = null;
      analyser = null;
      if (audioCtx) { audioCtx.close().catch(() => {}); audioCtx = null; }
    }
```

- [ ] **Step 10: Update the mic click guard**

Find:

```js
    micBtn.addEventListener('click', () => {
      if (busy) return;
      recording ? stopRecording() : startRecording();
    });
```

Replace with:

```js
    micBtn.addEventListener('click', () => {
      if (finalizing) return;
      recording ? stopRecording() : startRecording();
    });
```

- [ ] **Step 11: Update clear & copy to act on committed + interim**

Find:

```js
    clearBtn.addEventListener('click', () => {
      finalText = '';
      errorText = '';
      render();
    });

    copyBtn.addEventListener('click', async () => {
      const text = finalText.trim();
      if (!text) return;
      try { await navigator.clipboard.writeText(text); showToast('הטקסט הועתק'); }
      catch (_) { showToast('ההעתקה נכשלה'); }
    });
```

Replace with:

```js
    clearBtn.addEventListener('click', () => {
      committedText = '';
      interimText   = '';
      errorText     = '';
      render();
    });

    copyBtn.addEventListener('click', async () => {
      const text = (committedText + (interimText ? ' ' + interimText : '')).trim();
      if (!text) return;
      try { await navigator.clipboard.writeText(text); showToast('הטקסט הועתק'); }
      catch (_) { showToast('ההעתקה נכשלה'); }
    });
```

- [ ] **Step 12: Verify there are no stale references to old names**

Run: `grep -nE 'finalText|\bbusy\b|\bchunks\b|onstop = transcribe|function transcribe\b' /home/tal/DOMINO/docs/index.html`
Expected: **no output**. (Every old identifier — `finalText`, `busy`, the old `chunks`, the old `transcribe()` and its `onstop` wiring — must be gone. If anything prints, it is a leftover from the old core; remove it.)

- [ ] **Step 13: Manual verification in a desktop browser**

Because GitHub Pages serves `/docs`, the app references relative paths; the service worker needs a real origin. Serve the folder locally and open it:

Run: `cd /home/tal/DOMINO/docs && python3 -m http.server 8000`
Then open `http://localhost:8000/` in Chrome (allow mic when prompted). Confirm, in order:

1. **Live updates:** Tap mic, speak Hebrew continuously for ~15s. Dimmed interim text appears within ~5s and refines in place; after ~12s a pause turns part of it into solid (committed) text.
2. **Commit at pause:** Pause for ~1s after 12s of speech — a commit happens at the pause (interim solidifies) rather than mid-word.
3. **Stop flush:** Speak a final few words, tap stop. The spinner shows "מסיים תמלול…", then the last words land in committed text and it returns to idle.
4. **Copy / Clear:** Both buttons appear when there is text; Copy puts committed+interim on the clipboard; Clear empties the panel.
5. **No runaway:** Talk for ~90s; commits keep happening and the page stays responsive (open DevTools → Memory is steady, not climbing without bound).
6. **Offline recovery:** With DevTools Network set to Offline mid-session, interim stops updating but recording continues; set back to Online and the next window transcribes normally.

Stop the server with Ctrl-C when done.

- [ ] **Step 14: Commit**

```bash
git -C /home/tal/DOMINO add docs/index.html
git -C /home/tal/DOMINO commit -m "Web app: live (streaming) Hebrew transcription

Windowed cumulative re-transcription with silence-aware commit:
turbo interim updates every ~4s shown dimmed, accurate v3 commit at a
pause/30s cap, final flush on stop. Replaces the batch record→stop→
transcribe core.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Device matrix verification and constant tuning

**Files:**
- Modify (only if tuning is needed): `docs/index.html`

- [ ] **Step 1: Deploy the branch to a test surface the phone can reach**

Live updates need a microphone, which browsers only grant on `https://` or `localhost`. A phone cannot hit your laptop's `localhost`. Pick one:
- Push the branch and merge to `main` later, but for testing use a tunnel: `cd /home/tal/DOMINO/docs && python3 -m http.server 8000` then expose it (e.g. `cloudflared tunnel --url http://localhost:8000`) and open the HTTPS URL on the phone, **or**
- Temporarily push to the live Pages site on a test path.

State which method was used.

- [ ] **Step 2: Run the matrix**

On each of **desktop Chrome**, **Android Chrome**, **iOS Safari**, confirm:
1. Interim text appears within ~5s and refines in place.
2. A ~90s session commits repeatedly without memory growth or growing latency.
3. Stop flushes the final words.
4. Offline mid-session and back recovers.
5. Denying mic permission shows "נא לאשר גישה למיקרופון".

Record pass/fail per cell. iOS Safari is the one to watch: confirm it records `audio/mp4` and that interim blobs decode (text actually appears).

- [ ] **Step 3: Tune constants if needed**

If interim feels too slow, lower `INTERIM_INTERVAL_MS` (e.g. 3000) — costs more Groq. If commits clip words, raise `SILENCE_HOLD_MS` or lower `SILENCE_RMS` (quieter rooms need a lower threshold; if it never detects silence, raise it). Change only the constants block from Task 2 Step 2.

- [ ] **Step 4: Commit any tuning**

```bash
git -C /home/tal/DOMINO add docs/index.html
git -C /home/tal/DOMINO commit -m "Tune live-transcription windowing constants for on-device feel

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

If no tuning was needed, skip this step and note it.

---

## Self-Review

**Spec coverage:**
- Cumulative window + interim re-transcription → Task 2 Steps 7, 8. ✓
- Commit at pause / 30s cap → `shouldCommit` (Step 4) + `maybeCommit` (Step 7). ✓
- Silence-aware commit via AnalyserNode/RMS → Steps 4, 9. ✓
- Model split (turbo interim / v3 commit+final) → `interimTick` turbo (Step 8), `commitTranscribe` v3 (Step 7), Worker `?model=` (Task 1). ✓
- `windowId` staleness discard → Steps 7, 8. ✓
- In-flight rules (interim gated, commit not gated, stale discard) → `inFlight` guard in `interimTick`, ungated `commitTranscribe`, `windowId` bump. ✓
- Interim dimmed styling → Step 1 CSS + Step 5 render. ✓
- Status / mic states → Step 5. ✓
- Copy/Clear on committed+interim → Step 11. ✓
- Error handling: interim skip (Step 8 catch), commit one-retry + toast (Step 7), offline self-heal (cumulative resend), mic denied (startRecording catch). ✓
- Bounded memory: `windowChunks` cleared each commit (Step 7). ✓
- Worker backward-compatible default v3 → Task 1. ✓
- Manual test matrix → Task 3. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; `SILENCE_RMS` has a concrete default (0.012) with on-device tuning called out in Task 3.

**Type/name consistency:** `committedText`, `interimText`, `windowChunks`, `windowId`, `windowStart`, `currentMime`, `inFlight`, `committing`, `finalizing`, `isSilent`, `belowSinceTs` used consistently across Steps 3–11. `shouldCommit`/`computeRms`/`transcribeBlob`/`startWindowRecorder`/`maybeCommit`/`onWindowStop`/`commitTranscribe`/`finishIdle`/`cleanupStream`/`startInterimTimer`/`stopInterimTimer`/`interimTick`/`startSilenceMonitor`/`stopSilenceMonitor` all defined before use. Old names (`finalText`, `busy`, `chunks`, `transcribe`) removed and guarded by the Step 12 grep.
