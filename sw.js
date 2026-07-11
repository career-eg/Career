const CAREERK_CACHE = 'careerk-pwa-v52';
const CAREERK_ASSETS = [
  './',
  './index.html',
  './install.html',
  './manifest.json',
  './icon-192.png',
  './icon-512.png'
];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CAREERK_CACHE)
      .then(cache => cache.addAll(CAREERK_ASSETS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('
