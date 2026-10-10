// オフラインでも起動できるようにアプリ本体をキャッシュする（更新はネット優先）
const CACHE = 'vlogcam-v7';
const ASSETS = [
  './',
  './index.html',
  './style.css',
  './manifest.webmanifest',
  './js/app.js',
  './js/ui.js',
  './js/store.js',
  './js/renderer.js',
  './js/filters.js',
  './js/recorder.js',
  './js/composer.js',
  './js/library.js',
  './js/remux.js',
  './vendor/mp4box.all.min.js',
  './vendor/mp4-muxer.mjs',
  './icons/apple-touch-icon.png',
  './icons/icon-192.png',
  './icons/icon-512.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET' || new URL(request.url).origin !== self.location.origin) return;
  event.respondWith(
    // ブラウザのキャッシュを使わず、毎回サーバーに最新か確認する
    fetch(request, { cache: 'no-cache' })
      .then((response) => {
        const copy = response.clone();
        caches.open(CACHE).then((c) => c.put(request, copy));
        return response;
      })
      .catch(() => caches.match(request)),
  );
});
