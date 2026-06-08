// Service worker: caches the app shell so the PWA is installable and the UI
// loads offline. Uses a NETWORK-FIRST strategy and forces same-origin requests
// to BYPASS the browser HTTP cache (GitHub Pages pins these files to
// max-age=600), so a fresh deploy shows up on a normal reload — no hard reset.
// It deliberately does NOT auto-activate: a new version waits until the page
// asks it to (SKIP_WAITING), which keeps the in-app "refresh" pill fully
// user-controlled so an update never interrupts a recording. Transcription
// always needs the network; it POSTs to the cloud Worker, which is never cached.
const CACHE = 'domino-stt-v4';
const ASSETS = ['./', './index.html', './manifest.json', './icon.svg'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS)));
  // No skipWaiting() — the new version waits until the user taps the in-app
  // refresh pill, which posts SKIP_WAITING (see the message handler below).
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('message', (e) => {
  if (e.data && e.data.type === 'SKIP_WAITING') self.skipWaiting();
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;            // never cache POSTs to the Worker
  const sameOrigin = new URL(req.url).origin === self.location.origin;

  e.respondWith(
    (async () => {
      try {
        // Re-fetch from the network with no-store so the browser's 10-minute
        // HTTP cache can't pin a stale shell.
        const res = req.mode === 'navigate'
          ? await fetch(req.url, { cache: 'no-store', credentials: 'same-origin' })
          : await fetch(req, sameOrigin ? { cache: 'no-store' } : undefined);
        // Keep an offline fallback copy of same-origin assets up to date.
        if (res && res.ok && sameOrigin) {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(req, copy));
        }
        return res;
      } catch (err) {
        // Offline: serve the last good copy, falling back to the app shell.
        const cached = await caches.match(req);
        return cached || caches.match('./index.html');
      }
    })()
  );
});
