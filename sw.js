// CareerK — Service Worker for the main user site (careerk.net)
// Keep this SW file separate from the admin panel's SW to avoid cross-app confusion.
// Bump CACHE_NAME whenever you deploy a new index.html so users get the update.

const CACHE_NAME = 'careerk-user-v3';
const CORE_ASSETS = [
  '/',
  '/index.html',
  '/install.html',
  '/manifest.json',
  '/icon-192.png',
  '/icon-512.png'
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
  // Cache-first for everything else
  event.respondWith(
    caches.match(event.request).then(hit => hit || fetch(event.request).catch(() => hit))
  );
});
