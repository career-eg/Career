const CAREERK_CACHE = 'careerk-pwa-v54';

const CAREERK_ASSETS = [
  './',
  './index.html',
  './install.html',
  './manifest.json',
  './icon-192.png',
  './icon-512.png',
  './careerk-logo.png',
  './careerk-logo-horizontal.png'
];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CAREERK_CACHE)
      .then(cache => cache.addAll(CAREERK_ASSETS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys =>
        Promise.all(
          keys
            .filter(key => key !== CAREERK_CACHE)
            .map(key => caches.delete(key))
        )
      )
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', event => {
  const request = event.request;

  if (request.method !== 'GET') return;

  const url = new URL(request.url);

  if (url.origin !== self.location.origin) return;

  event.respondWith(
    fetch(request)
      .then(response => {
        const copy = response.clone();
        caches.open(CAREERK_CACHE).then(cache => cache.put(request, copy));
        return response;
      })
      .catch(() => caches.match(request))
  );
});
