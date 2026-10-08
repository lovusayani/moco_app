'use strict';

// Moco PWA service worker.
//
// Job: make the app installable and let an installed Moco open its shell
// offline. It is deliberately conservative:
//
// * Network first for everything it handles. A deploy is visible on the next
//   load; the cache is only a fallback for when the network is unreachable.
//   (Flutter's main.dart.js and canvaskit/ are not content-hashed, so a
//   cache-first strategy could pair a new main.dart.js with an old engine.)
// * Never touches the API, the realtime socket, the admin console, or any
//   cross-origin request (signed media URLs, fonts). Those always go straight
//   to the network — the worker never serves stale balances, chats or media.
// * Every successful network response refreshes its cache entry, so the
//   offline copy is always the last version that was actually loaded. Bump
//   CACHE when the caching scheme itself changes; activate drops old caches.
// * Each deploy loads main.dart.js and flutter_bootstrap.js under a new
//   ?v=<build> URL (tool/vercel/build_web.mjs). Entries are stored WITHOUT
//   that stamp, so a deploy replaces the previous copy instead of adding
//   another multi-megabyte one next to it.

const CACHE = 'moco-shell-v2';

// Fetched best-effort at install so an installed app can cold-start offline.
// Each entry is cached individually: one missing file must not fail install.
const SHELL = [
  './',
  'index.html',
  'flutter_bootstrap.js',
  'main.dart.js',
  'manifest.json',
  'favicon.png',
  'icons/Icon-192.png',
  'icons/Icon-512.png',
  'icons/apple-touch-icon.png',
  'canvaskit/canvaskit.js',
  'canvaskit/canvaskit.wasm',
  'canvaskit/chromium/canvaskit.js',
  'canvaskit/chromium/canvaskit.wasm',
  'assets/AssetManifest.bin.json',
  'assets/FontManifest.json',
  'assets/fonts/MaterialIcons-Regular.otf',
];

const NEVER_CACHE = ['/api/', '/socket.io/', '/admin', '/health'];

self.addEventListener('install', (event) => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(CACHE).then((cache) =>
      Promise.all(
        SHELL.map((path) =>
          fetch(new Request(path, { cache: 'reload' }))
            .then((res) => (res.ok ? cache.put(path, res) : undefined))
            .catch(() => undefined),
        ),
      ),
    ),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      const keys = await caches.keys();
      await Promise.all(
        keys
          .filter((key) => key.startsWith('moco-shell-') && key !== CACHE)
          .map((key) => caches.delete(key)),
      );
      await self.clients.claim();
    })(),
  );
});

/** The cache key for a request: its URL without the per-build ?v= stamp. */
function cacheKey(request) {
  const url = new URL(request.url);
  url.searchParams.delete('v');
  return url.href;
}

function isHandled(request) {
  if (request.method !== 'GET') return false;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return false;
  return !NEVER_CACHE.some((prefix) => url.pathname.startsWith(prefix));
}

self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (!isHandled(request)) return;

  if (request.mode === 'navigate') {
    // Any in-app path (/discovery, /chat/12, ...) is the same index.html.
    // Online: always the network's copy. Offline: the cached shell, so a
    // deep link or refresh in an installed app still opens.
    event.respondWith(
      fetch(request).catch(async () => {
        const cache = await caches.open(CACHE);
        return (
          (await cache.match('index.html')) ||
          (await cache.match('./')) ||
          new Response('Moco is offline. Reconnect and try again.', {
            status: 503,
            headers: { 'Content-Type': 'text/plain; charset=utf-8' },
          })
        );
      }),
    );
    return;
  }

  event.respondWith(
    (async () => {
      const cache = await caches.open(CACHE);
      try {
        const response = await fetch(request);
        if (response.ok && response.type === 'basic') {
          cache.put(cacheKey(request), response.clone());
        }
        return response;
      } catch (err) {
        const cached = await cache.match(cacheKey(request), { ignoreSearch: true });
        if (cached) return cached;
        throw err;
      }
    })(),
  );
});
