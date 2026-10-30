// Service worker PasteLAN: hanya menyimpan tampilan aplikasi (HTML/CSS/JS/ikon) supaya bisa di-install
// dan terbuka cepat, plus notifikasi push. Isi clipboard (/api/) TIDAK PERNAH di-cache.
'use strict';
const CACHE = 'pastelan-v2';
const SHELL = ['/', '/app.js', '/style.css', '/manifest.webmanifest', '/icon-192.png', '/icon-512.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys()
    .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

// jaringan dulu (update server langsung terpakai), cache hanya cadangan saat offline
self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== location.origin || url.pathname.startsWith('/api/')) return;
  e.respondWith(fetch(e.request)
    .then(res => {
      if (res.ok && SHELL.includes(url.pathname)) {
        const copy = res.clone();
        caches.open(CACHE).then(c => c.put(e.request, copy));
      }
      return res;
    })
    .catch(() => caches.match(e.request).then(r => r || caches.match('/'))));
});

// ---------- notifikasi push (hanya kiriman manual dari Mac: ⇧ + klik di menu) ----------
// Isi push hanya id + potongan teks; isi lengkap diambil halaman dari server setelah notifikasi diketuk.
self.addEventListener('push', e => {
  let m = {};
  try { m = e.data ? e.data.json() : {}; } catch (err) {}
  const title = 'Clip baru dari ' + (m.from || 'Mac');
  const body = m.kind === 'image' ? 'Gambar' : (m.preview || 'Teks baru');
  e.waitUntil(self.registration.showNotification(title, {
    body,
    tag: 'pastelan-' + (m.id || 0),
    icon: '/icon-192.png',
    badge: '/icon-192.png',
    data: { id: m.id || 0 },
    // tombol "Salin" (Android / desktop; iPhone tidak mendukung tombol → ketuk notifikasinya)
    actions: [{ action: 'copy', title: m.kind === 'image' ? 'Salin gambar' : 'Salin' }]
  }));
});

// Service worker tidak bisa menulis ke clipboard → buka / fokuskan PasteLAN, halaman yang menyalin
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const id = Number(e.notification.data && e.notification.data.id) || 0;
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const w of wins) {
      if (new URL(w.url).origin !== location.origin) continue;
      await w.focus();
      w.postMessage({ copy: id });
      return;
    }
    await self.clients.openWindow('/#copy=' + id);
  })());
});
