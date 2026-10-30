// PasteLAN — halaman web (PWA). Tanpa library / CDN; semua request lewat HTTPS ke server yang sama.
'use strict';
(() => {
  const $ = id => document.getElementById(id);
  const MAX_BYTES = 30 * 1024 * 1024;
  let maxItems = 20; // dari server (diatur di halaman admin)
  let after = 0, session = '', rev = -1, me = '', polling = false, ctrl = null;
  let pendingCopy = 0, notifChecked = false; // id clip dari notifikasi yang harus disalin begitu muncul

  function toast(msg) {
    const t = $('toast');
    t.textContent = msg;
    t.classList.add('show');
    clearTimeout(toast.h);
    toast.h = setTimeout(() => t.classList.remove('show'), 2200);
  }
  function setStatus(state, text) { $('dot').className = 'dot ' + state; $('status').textContent = text; }
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text; // selalu textContent → isi clipboard tidak pernah jadi HTML
    return e;
  }
  function button(label, cls, onclick) {
    const b = el('button', cls, label);
    b.type = 'button';
    b.onclick = () => onclick(b);
    return b;
  }

  // Header X-PasteLAN wajib (perlindungan CSRF); login disimpan sebagai cookie HttpOnly (tidak terbaca JS)
  async function api(path, opts = {}, raw = false) {
    opts.headers = Object.assign({ 'X-PasteLAN': '1' }, opts.headers || {});
    opts.credentials = 'same-origin';
    const r = await fetch(path, opts);
    if (r.status === 401 && path !== '/api/login' && path !== '/api/pair/claim') { showLogin(); throw new Error('belum login'); }
    if (!r.ok) {
      const j = await r.json().catch(() => ({}));
      throw new Error(j.error || ('HTTP ' + r.status));
    }
    return raw ? r : r.json();
  }

  // ---------- login ----------
  function guessName() {
    const ua = navigator.userAgent;
    if (/iPhone/.test(ua)) return 'iPhone';
    if (/iPad/.test(ua)) return 'iPad';
    if (/Android/.test(ua)) return 'HP Android';
    return 'Browser';
  }
  // Jenis perangkat untuk server: "hp" (HP / tablet, termasuk iPad yang mengaku Mac) atau "browser" (komputer)
  function clientKind() {
    const ua = navigator.userAgent;
    if (/iPhone|iPad|Android|Mobile/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)) return 'hp';
    return 'browser';
  }
  const KINDS = { mac: 'Mac (menu bar)', hp: 'HP', browser: 'Browser' };
  function showLogin() {
    polling = false;
    notifChecked = false;
    if (ctrl) ctrl.abort();
    clearList();
    $('app').hidden = true;
    $('login').hidden = false;
    setStatus('off', 'Belum masuk');
    $('devname').value = localStorage.getItem('pastelan-name') || guessName();
    $('password').focus();
    // login dengan password bisa dimatikan admin → hanya link setup / QR
    api('/api/config').then(c => {
      $('pwLabel').hidden = $('loginBtn').hidden = !c.passwordLogin;
      $('password').required = c.passwordLogin;
      $('loginHint').textContent = c.passwordLogin
        ? 'Masukkan password server PasteLAN (cukup sekali per perangkat), atau scan QR "Tambah HP" dari menu PasteLAN di Mac.'
        : 'Masuk dengan scan QR "Tambah HP" dari menu PasteLAN di Mac, atau buka link setup dari halaman admin.';
    }).catch(() => {});
  }
  function showApp() {
    $('login').hidden = true;
    $('app').hidden = false;
    showEmpty();
    if (!polling) poll();
  }
  $('login').onsubmit = async e => {
    e.preventDefault();
    $('loginErr').textContent = '';
    $('loginBtn').disabled = true;
    const name = $('devname').value.trim() || guessName();
    try {
      const j = await api('/api/login', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ password: $('password').value, name, client: clientKind() })
      });
      try { localStorage.setItem('pastelan-name', name); } catch (e) {}
      me = j.device.id;
      $('password').value = '';
      showApp();
    } catch (err) {
      $('loginErr').textContent = err.message;
    } finally { $('loginBtn').disabled = false; }
  };

  // ---------- menerima (long-poll) ----------
  function clearList() {
    for (const c of $('list').children) if (c.blobURL) URL.revokeObjectURL(c.blobURL);
    $('list').textContent = '';
    after = 0;
  }
  function removeCard(card) {
    if (card.blobURL) URL.revokeObjectURL(card.blobURL);
    card.remove();
  }
  // buang kartu yang sudah tidak ada di server (dihapus perangkat lain / kedaluwarsa)
  function syncIds(ids) {
    const keep = new Set(ids);
    for (const c of [...$('list').children]) if (c.itemId && !keep.has(c.itemId)) removeCard(c);
  }
  function showEmpty() {
    if (!$('list').children.length) $('list').append(el('div', 'empty', 'Belum ada apa-apa. Copy sesuatu di Mac (⌘C), atau kirim dari sini.'));
    filter();
  }
  // ---------- pencarian (isi teks; gambar cocok dengan "gambar") ----------
  function filter() {
    const q = $('search').value.trim().toLowerCase();
    let shown = 0, total = 0;
    for (const c of $('list').children) {
      if (c.searchText == null) continue;
      total++;
      const hit = !q || c.searchText.includes(q);
      c.classList.toggle('hide', !hit);
      if (hit) shown++;
    }
    $('noMatch').hidden = !q || !total || shown > 0;
    $('noMatch').textContent = `Tidak ada clip yang cocok dengan "${$('search').value.trim()}".`;
  }
  $('search').addEventListener('input', filter);
  async function poll() {
    polling = true;
    while (polling) {
      ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), 35000);
      try {
        const j = await api(`/api/items?after=${after}&s=${encodeURIComponent(session)}&r=${rev}&wait=1`, { signal: ctrl.signal });
        me = j.you;
        if (j.max) maxItems = j.max;
        if (j.session !== session) { session = j.session; clearList(); }
        rev = j.rev == null ? -1 : j.rev;
        setStatus('on', 'Terhubung');
        for (const it of j.items) { add(it); after = Math.max(after, it.id); }
        if (j.ids) syncIds(j.ids);
        showEmpty();
        if (pendingCopy && j.ids && !j.ids.includes(pendingCopy)) { pendingCopy = 0; toast('Clip itu sudah tidak ada di server'); }
        if (!notifChecked) { notifChecked = true; updateNotif(); }
      } catch (e) {
        if (!polling) return;
        if (e.name !== 'AbortError') { setStatus('off', 'Terputus, mencoba lagi…'); await sleep(3000); }
      } finally { clearTimeout(timer); }
    }
  }
  // kembali ke aplikasi → jangan tunggu request lama yang mungkin sudah mati
  document.addEventListener('visibilitychange', () => { if (!document.hidden && ctrl) ctrl.abort(); });

  function add(it) {
    const list = $('list');
    const empty = list.querySelector('.empty');
    if (empty) empty.remove();
    const card = el('div', 'card item');
    card.itemId = it.id;
    card.searchText = (it.kind === 'text' ? it.text : 'gambar image ' + (it.mime || '')).toLowerCase();
    const meta = el('div', 'meta');
    const time = new Date(it.time).toLocaleTimeString('id-ID', { hour: '2-digit', minute: '2-digit' });
    meta.append(el('span', '', it.device === me ? 'Dari perangkat ini' : 'Dari ' + it.from), el('span', '', time));
    card.append(meta);
    const row = el('div', 'row');
    if (it.kind === 'text') {
      const t = el('div', 'txt', it.text);
      card.append(t);
      card.copy = auto => copyText(it.text, auto);
      row.append(button('Salin', 'grow', () => copyText(it.text)));
      if (it.text.length > 300 || it.text.split('\n').length > 6) {
        row.append(button('Selengkapnya', 'ghost', b => {
          t.classList.toggle('full');
          b.textContent = t.classList.contains('full') ? 'Ringkas' : 'Selengkapnya';
        }));
      }
    } else {
      const img = el('img');
      img.alt = 'Gambar';
      card.append(img);
      const ext = (it.mime || 'image/png').split('/')[1].replace('jpeg', 'jpg');
      const save = el('a', 'btn ghost', 'Simpan');
      save.download = `pastelan-${it.id}.${ext}`;
      const copy = button('Salin gambar', 'grow', () => copyImage(card.blob));
      copy.disabled = true;
      if (window.ClipboardItem && navigator.clipboard && navigator.clipboard.write) row.append(copy);
      row.append(save);
      // gambar diambil lewat fetch (butuh header X-PasteLAN) lalu ditampilkan sebagai blob:
      const ready = api(`/api/image/${it.id}?s=${encodeURIComponent(session)}`, {}, true)
        .then(r => r.blob())
        .then(b => {
          card.blob = b;
          card.blobURL = img.src = save.href = URL.createObjectURL(b);
          copy.disabled = false;
          return b;
        }).catch(() => { img.alt = 'Gambar gagal dimuat'; return null; });
      card.copy = async auto => copyImage(await ready, auto);
    }
    // hapus item ini dari server → hilang juga di semua perangkat
    row.append(button('Hapus', 'ghost danger del', async b => {
      b.disabled = true;
      try {
        await api('/api/items/' + it.id, { method: 'DELETE' });
        removeCard(card);
        showEmpty();
      } catch (e) { b.disabled = false; toast(e.message); }
    }));
    card.append(row);
    list.prepend(card);
    while (list.children.length > maxItems) removeCard(list.lastChild);
    filter();
    if (it.id === pendingCopy) copyFromCard(card);
  }

  // ---------- salin dari notifikasi ----------
  // Notifikasi diketuk → service worker membuka halaman ini (#copy=<id>) atau mengirim pesan; clip disalin begitu ada.
  function copyFromNotif(id) {
    if (!id) return;
    pendingCopy = id;
    const card = [...$('list').children].find(c => c.itemId === id);
    if (card) copyFromCard(card);
  }
  async function copyFromCard(card) {
    pendingCopy = 0;
    if ($('search').value) { $('search').value = ''; filter(); }
    card.scrollIntoView({ block: 'center' });
    card.classList.add('flash');
    setTimeout(() => card.classList.remove('flash'), 3000);
    // tanpa ketukan di halaman, beberapa browser (Safari iPhone) menolak menulis clipboard → minta ketuk "Salin"
    if (!card.copy || !await card.copy(true)) toast('Ketuk "Salin" untuk menyalin');
  }
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.addEventListener('message', e => copyFromNotif(Number(e.data && e.data.copy) || 0));
  }

  // auto = disalin otomatis (dari notifikasi): gagal → false tanpa cadangan execCommand / pesan gagal
  async function copyText(text, auto) {
    try { await navigator.clipboard.writeText(text); toast('Tersalin ✓'); return true; } catch (e) {}
    if (auto) return false;
    // cadangan untuk browser lama
    const ta = el('textarea');
    ta.value = text;
    Object.assign(ta.style, { position: 'fixed', top: '0', left: '0', opacity: '0' });
    document.body.append(ta);
    ta.select();
    let ok = false;
    try { ok = document.execCommand('copy'); } catch (e) {}
    ta.remove();
    toast(ok ? 'Tersalin ✓' : 'Gagal menyalin. Tekan lama teksnya untuk menyalin manual.');
    return ok;
  }

  // clipboard browser hanya menerima PNG → gambar lain diubah dulu lewat canvas
  async function copyImage(blob, auto) {
    if (!blob) return false;
    try {
      let png = blob;
      if (blob.type !== 'image/png') {
        const bmp = await createImageBitmap(blob);
        const c = document.createElement('canvas');
        c.width = bmp.width; c.height = bmp.height;
        c.getContext('2d').drawImage(bmp, 0, 0);
        png = await new Promise(r => c.toBlob(r, 'image/png'));
      }
      await navigator.clipboard.write([new ClipboardItem({ 'image/png': png })]);
      toast('Gambar tersalin ✓');
      return true;
    } catch (e) {
      if (!auto) toast('Gagal menyalin gambar. Tekan lama gambarnya untuk menyalin.');
      return false;
    }
  }

  // ---------- mengirim ----------
  async function sendText() {
    const text = $('input').value;
    if (!text.trim()) { toast('Tulis atau tempel teks dulu'); $('input').focus(); return; }
    $('send').disabled = true;
    try {
      await api('/api/text', { method: 'POST', headers: { 'Content-Type': 'text/plain;charset=utf-8' }, body: text });
      $('input').value = '';
      toast('Terkirim ✓');
    } catch (e) { toast('Gagal mengirim: ' + e.message); }
    finally { $('send').disabled = false; }
  }
  async function sendImage(file) {
    if (file.size > MAX_BYTES) return toast('Gambar terlalu besar (maks 30 MB)');
    toast('Mengirim gambar…');
    try {
      await api('/api/image', { method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: file });
      toast('Gambar terkirim ✓');
    } catch (e) { toast('Gagal mengirim gambar: ' + e.message); }
  }
  $('send').onclick = sendText;
  $('input').addEventListener('keydown', e => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); sendText(); } });
  $('pick').onclick = () => $('file').click();
  $('file').onchange = async e => {
    for (const f of [...e.target.files]) await sendImage(f);
    e.target.value = '';
  };
  $('input').addEventListener('paste', e => {
    const files = [...((e.clipboardData && e.clipboardData.items) || [])]
      .filter(i => i.kind === 'file' && i.type.startsWith('image/'))
      .map(i => i.getAsFile()).filter(Boolean);
    if (files.length) { e.preventDefault(); files.reduce((p, f) => p.then(() => sendImage(f)), Promise.resolve()); }
  });

  // ---------- pengaturan ----------
  async function loadDevices() {
    const box = $('devices');
    try {
      const j = await api('/api/devices');
      box.textContent = '';
      for (const d of j.devices) {
        const row = el('div', 'dev');
        const info = el('span', '', d.name + (d.current ? ' (perangkat ini)' : ''));
        info.append(el('small', '', (KINDS[d.kind] ? KINDS[d.kind] + ' · ' : '') + (d.push ? 'Notifikasi aktif · ' : '') +
          'Terakhir aktif ' + new Date(d.lastSeen).toLocaleString('id-ID')));
        row.append(info);
        if (!d.current) {
          row.append(button('Cabut', 'ghost danger', async () => {
            if (!confirm(`Cabut akses "${d.name}"? Perangkat itu harus masuk lagi (link setup / QR / password).`)) return;
            try { await api('/api/devices/' + encodeURIComponent(d.id), { method: 'DELETE' }); loadDevices(); }
            catch (e) { toast(e.message); }
          }));
        }
        box.append(row);
      }
    } catch (e) { box.textContent = 'Gagal memuat: ' + e.message; }
  }
  $('settings').addEventListener('toggle', () => { if ($('settings').open) loadDevices(); });
  $('clear').onclick = async () => {
    if (!confirm('Hapus semua riwayat clipboard di server (untuk semua perangkat)?')) return;
    try { await api('/api/items', { method: 'DELETE' }); toast('Riwayat dihapus'); } catch (e) { toast(e.message); }
  };
  $('logout').onclick = async () => {
    if (!confirm('Keluar dari perangkat ini? Perlu link setup / QR / password untuk masuk lagi.')) return;
    try { await api('/api/logout', { method: 'POST' }); } catch (e) {}
    try { const sub = await pushSubscription(); if (sub) await sub.unsubscribe(); } catch (e) {}
    showLogin();
  };

  // QR dari menu Mac / link setup dari admin: https://server/#pair=<kode> → masuk tanpa mengetik password (sekali pakai)
  async function claimFromQR() {
    const code = new URLSearchParams(location.hash.slice(1)).get('pair');
    if (!code) return true;
    history.replaceState(null, '', location.pathname); // kode tidak tertinggal di riwayat / layar
    let name = guessName();
    try { name = localStorage.getItem('pastelan-name') || name; } catch (e) {}
    try {
      const j = await api('/api/pair/claim', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ code, name, client: clientKind() })
      });
      me = j.device.id;
      toast('Perangkat ini sudah masuk ✓');
      return true;
    } catch (err) {
      showLogin();
      $('loginErr').textContent = err.message;
      return false;
    }
  }

  // ---------- install (PWA) ----------
  const standalone = () => matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
  const isIOS = () => /iPhone|iPad|iPod/.test(navigator.userAgent) || (/Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1);
  let installEvt = null; // Chrome / Edge / Android: dialog install bawaan browser
  window.addEventListener('beforeinstallprompt', e => { e.preventDefault(); installEvt = e; updateInstall(); });
  window.addEventListener('appinstalled', () => { installEvt = null; updateInstall(); toast('PasteLAN ter-install ✓'); });
  function updateInstall() {
    $('install').hidden = !installEvt || standalone();
    $('installHint').textContent = standalone() ? 'PasteLAN sudah ter-install dan terbuka sebagai aplikasi.'
      : installEvt ? 'Install PasteLAN supaya terbuka seperti aplikasi biasa (ikon di layar utama / dock).'
      : isIOS() ? 'Install di iPhone / iPad: buka di Safari → tombol Bagikan → "Tambahkan ke Layar Utama".'
      : 'Install lewat menu browser → "Install aplikasi" / "Tambahkan ke layar utama".';
  }
  $('install').onclick = async () => {
    if (!installEvt) return;
    installEvt.prompt();
    try { await installEvt.userChoice; } catch (e) {}
    installEvt = null;
    updateInstall();
  };

  // ---------- notifikasi push ----------
  // Hanya untuk kiriman manual dari Mac (⇧ + klik di menu); clip dari autosync tidak memunculkan notifikasi.
  const pushSupported = () => 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
  const b64uBytes = s => {
    const b = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - s.length % 4) % 4));
    return Uint8Array.from(b, c => c.charCodeAt(0));
  };
  async function pushSubscription() {
    if (!pushSupported()) return null;
    const reg = await navigator.serviceWorker.ready;
    return reg.pushManager.getSubscription();
  }
  // langganan dibuat dengan kunci server yang lain (kunci di server berganti) → tidak berlaku lagi
  function sameKey(sub, key) {
    const k = sub.options && sub.options.applicationServerKey;
    if (!k) return true;
    const a = new Uint8Array(k), b = b64uBytes(key);
    return a.length === b.length && a.every((x, i) => x === b[i]);
  }
  const saveSub = sub => api('/api/push/subscribe', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(sub.toJSON())
  });
  let pushOn = false;
  function laterDismissed() { try { return localStorage.getItem('pastelan-notif-later') === '1'; } catch (e) { return false; } }
  async function updateNotif() {
    updateInstall();
    const btn = $('notifBtn'), hint = $('notifHint'), card = $('notifCard');
    btn.hidden = card.hidden = true;
    pushOn = false;
    if (!pushSupported()) {
      if (isIOS() && !standalone()) {
        hint.textContent = 'Notifikasi di iPhone / iPad bisa setelah PasteLAN di-install ke Layar Utama (iOS 16.4+) lalu dibuka dari ikonnya.';
        $('notifText').textContent = 'Mau notifikasi saat Mac mengirim clip? Install PasteLAN dulu: Safari → Bagikan → "Tambahkan ke Layar Utama", lalu buka dari ikonnya.';
        $('notifEnable').hidden = true;
        card.hidden = laterDismissed();
      } else hint.textContent = 'Browser ini tidak mendukung notifikasi push.';
      return;
    }
    if (Notification.permission === 'denied') {
      hint.textContent = 'Notifikasi diblokir. Izinkan lewat pengaturan situs di browser / HP, lalu muat ulang halaman.';
      return;
    }
    let sub, j;
    try {
      sub = await pushSubscription();
      j = await api('/api/push/key');
      if (sub && !sameKey(sub, j.key)) { await sub.unsubscribe().catch(() => {}); sub = null; }
      // langganan masih ada di browser tapi server belum tahu (mis. login ulang) → daftarkan lagi
      if (sub && !j.subscribed && Notification.permission === 'granted') { await saveSub(sub); j.subscribed = true; }
    } catch (e) { hint.textContent = 'Notifikasi belum tersedia: ' + e.message; return; }
    pushOn = !!sub && j.subscribed;
    btn.hidden = false;
    btn.textContent = pushOn ? 'Matikan notifikasi' : 'Aktifkan notifikasi';
    hint.textContent = pushOn
      ? 'Aktif: notifikasi muncul saat Mac mengirim clip secara manual (⇧ + klik di menu PasteLAN). Ketuk "Salin" di notifikasi untuk menyalin.'
      : 'Notifikasi saat Mac mengirim clip secara manual (⇧ + klik di menu PasteLAN), dengan potongan teks dan tombol "Salin". Clip dari autosync tidak memunculkan notifikasi.';
    $('notifText').textContent = 'Aktifkan notifikasi supaya clip yang dikirim manual dari Mac (⇧ + klik di menu PasteLAN) langsung muncul, lengkap dengan tombol "Salin".';
    $('notifEnable').hidden = false;
    card.hidden = pushOn || Notification.permission !== 'default' || laterDismissed();
  }
  async function enablePush() {
    try {
      // izin harus diminta langsung dari ketukan pengguna
      if (await Notification.requestPermission() !== 'granted') { toast('Izin notifikasi tidak diberikan'); return; }
      const reg = await navigator.serviceWorker.ready;
      const j = await api('/api/push/key');
      let sub = await reg.pushManager.getSubscription();
      if (sub && !sameKey(sub, j.key)) { await sub.unsubscribe(); sub = null; }
      if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64uBytes(j.key) });
      await saveSub(sub);
      toast('Notifikasi aktif ✓');
    } catch (e) { toast('Gagal mengaktifkan notifikasi: ' + e.message); }
    finally { updateNotif(); }
  }
  async function disablePush() {
    try {
      const sub = await pushSubscription();
      if (sub) await sub.unsubscribe();
      await api('/api/push/subscribe', { method: 'DELETE' });
      toast('Notifikasi dimatikan');
    } catch (e) { toast(e.message); }
    finally { updateNotif(); }
  }
  $('notifBtn').onclick = () => (pushOn ? disablePush() : enablePush());
  $('notifEnable').onclick = enablePush;
  $('notifLater').onclick = () => {
    try { localStorage.setItem('pastelan-notif-later', '1'); } catch (e) {}
    $('notifCard').hidden = true;
  };

  if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => {});
  // dibuka dari notifikasi (service worker membuka /#copy=<id>)
  {
    const id = Number(new URLSearchParams(location.hash.slice(1)).get('copy')) || 0;
    if (id) { pendingCopy = id; history.replaceState(null, '', location.pathname); }
  }
  updateInstall();
  // belum login → request pertama dijawab 401 → form login muncul
  claimFromQR().then(ok => { if (ok) showApp(); });
})();
