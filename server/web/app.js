// PasteLAN — halaman web (PWA). Tanpa library / CDN; semua request lewat HTTPS ke server yang sama.
'use strict';
(() => {
  const $ = id => document.getElementById(id);
  const MAX_ITEMS = 20, MAX_BYTES = 30 * 1024 * 1024;
  let after = 0, session = '', me = '', polling = false, ctrl = null;

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
    if (r.status === 401 && path !== '/api/login') { showLogin(); throw new Error('belum login'); }
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
  function showLogin() {
    polling = false;
    if (ctrl) ctrl.abort();
    clearList();
    $('app').hidden = true;
    $('login').hidden = false;
    setStatus('off', 'Belum masuk');
    $('devname').value = localStorage.getItem('pastelan-name') || guessName();
    $('password').focus();
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
        body: JSON.stringify({ password: $('password').value, name })
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
  function showEmpty() {
    if (!$('list').children.length) $('list').append(el('div', 'empty', 'Belum ada apa-apa. Copy sesuatu di Mac (⌘C), atau kirim dari sini.'));
  }
  async function poll() {
    polling = true;
    while (polling) {
      ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), 35000);
      try {
        const j = await api(`/api/items?after=${after}&s=${encodeURIComponent(session)}&wait=1`, { signal: ctrl.signal });
        me = j.you;
        if (j.session !== session) { session = j.session; clearList(); }
        setStatus('on', 'Terhubung');
        for (const it of j.items) { add(it); after = Math.max(after, it.id); }
        showEmpty();
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
    const meta = el('div', 'meta');
    const time = new Date(it.time).toLocaleTimeString('id-ID', { hour: '2-digit', minute: '2-digit' });
    meta.append(el('span', '', it.device === me ? 'Dari perangkat ini' : 'Dari ' + it.from), el('span', '', time));
    card.append(meta);
    const row = el('div', 'row');
    if (it.kind === 'text') {
      const t = el('div', 'txt', it.text);
      card.append(t);
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
      api(`/api/image/${it.id}?s=${encodeURIComponent(session)}`, {}, true)
        .then(r => r.blob())
        .then(b => {
          card.blob = b;
          card.blobURL = img.src = save.href = URL.createObjectURL(b);
          copy.disabled = false;
        }).catch(() => { img.alt = 'Gambar gagal dimuat'; });
    }
    card.append(row);
    list.prepend(card);
    while (list.children.length > MAX_ITEMS) {
      if (list.lastChild.blobURL) URL.revokeObjectURL(list.lastChild.blobURL);
      list.lastChild.remove();
    }
  }

  async function copyText(text) {
    try { await navigator.clipboard.writeText(text); return toast('Tersalin ✓'); } catch (e) {}
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
  }

  // clipboard browser hanya menerima PNG → gambar lain diubah dulu lewat canvas
  async function copyImage(blob) {
    if (!blob) return;
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
    } catch (e) { toast('Gagal menyalin gambar. Tekan lama gambarnya untuk menyalin.'); }
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
        info.append(el('small', '', 'Terakhir aktif ' + new Date(d.lastSeen).toLocaleString('id-ID')));
        row.append(info);
        if (!d.current) {
          row.append(button('Cabut', 'ghost danger', async () => {
            if (!confirm(`Cabut akses "${d.name}"? Perangkat itu harus login ulang dengan password.`)) return;
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
    if (!confirm('Keluar dari perangkat ini? Perlu password untuk masuk lagi.')) return;
    try { await api('/api/logout', { method: 'POST' }); } catch (e) {}
    showLogin();
  };

  if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => {});
  showApp(); // belum login → request pertama dijawab 401 → form login muncul
})();
