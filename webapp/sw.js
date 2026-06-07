// Service worker: caches the app shell so the PWA is installable and the UI
// loads offline. Uses a NETWORK-FIRST strategy so a freshly deployed version
// is picked up immediately (cache-first would pin users to a stale index.html).
// Transcription itself always needs the network — it calls the cloud Worker.
const CACHE = 'domino-stt-v2';
const ASSETS = ['./', './index.html', './manifest.json', './icon.svg'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS)));
  self.skipWaiting();
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;            // never cache POSTs to the Worker
  e.respondWith(
    fetch(req)
      .then((res) => {
        // Refresh the cached copy of same-origin assets as we fetch them.
        if (res && res.ok && new URL(req.url).origin === self.location.origin) {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(req, copy));
        }
        return res;
      })
      .catch(() => caches.match(req).then((cached) => cached || caches.match('./index.html')))
  );
});
