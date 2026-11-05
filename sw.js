// CareerK — Service Worker for the main user site (careerk.net)
// Keep this SW file separate from the admin panel's SW to avoid cross-app confusion.
// Bump CACHE_NAME whenever you deploy a new index.html so users get the update.

const CACHE_NAME = 'careerk-user-v7';
const CORE_ASSETS = [
  '/',
  '/index.html',
  '/install.html',
  '/manifest.json',
  '/icon-192.png',
  '/icon-512.png',
  '/icon-96.png'
];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache => cache.addAll(CORE_ASSETS).catch(() => {}))
  );
  self.skipWaiting();
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k)))
    )
  );
  self.clients.claim();
});

// Allow the page to prompt an immediate takeover when a fix arrives.
self.addEventListener('message', event => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});

self.addEventListener('fetch', event => {
  // Network-first for HTML (so app updates arrive quickly)
  if (event.request.mode === 'navigate' || event.request.destination === 'document') {
    event.respondWith(
      fetch(event.request)
        .then(res => {
          const clone = res.clone();
          caches.open(CACHE_NAME).then(c => c.put(event.request, clone)).catch(() => {});
          return res;
        })
        .catch(() => caches.match(event.request).then(hit => hit || caches.match('/index.html')))
    );
    return;
  }
  const url = new URL(event.request.url);
  if (event.request.method !== 'GET') return;
  // Supabase API / realtime / storage: never touch — always live data.
  if (url.hostname.endsWith('supabase.co')) return;
  // Fonts + the pinned supabase-js build are immutable: serve from cache instantly.
  const isStaticCdn = url.hostname === 'fonts.gstatic.com' || url.hostname === 'fonts.googleapis.com' || url.hostname === 'cdn.jsdelivr.net';
  if (url.origin !== self.location.origin && !isStaticCdn) return;
  event.respondWith(
    caches.match(event.request).then(hit => {
      const net = fetch(event.request).then(res => {
        if (res && (res.ok || res.type === 'opaque')) {
          const clone = res.clone();
          caches.open(CACHE_NAME).then(c => c.put(event.request, clone)).catch(() => {});
        }
        return res;
      }).catch(() => hit);
      return hit || net;   // cache first, refresh in the background
    })
  );
});

// Tapping a CareerK notification: focus an open tab (and route it), or open the site.
self.addEventListener('notificationclick', event => {
  event.notification.close();
  const link = (event.notification.data && event.notification.data.link) || '';
  const hash = link.startsWith('job:') ? '#job-' + link.slice(4)
             : link.startsWith('relief:') ? '#relief-' + link.slice(7)
             : '';
  event.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of all) {
      if ('focus' in c) {
        await c.focus();
        c.postMessage({ type: 'OPEN_LINK', link });
        return;
      }
    }
    await self.clients.openWindow('/' + hash);
  })());
});
