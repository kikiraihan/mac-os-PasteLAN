// PasteLAN — halaman admin. Tanpa library / CDN; sesi admin di cookie HttpOnly (tidak terbaca JS).
// Empat bagian (Ringkasan, Perangkat, Clipboard, Keamanan) dipilih lewat #hash; satu bagian tampil sekaligus.
'use strict';
(() => {
  const $ = id => document.getElementById(id);
  const $$ = sel => Array.from(document.querySelectorAll(sel));
  let settings = {};
  let status = null;
  let ticket = null; // { link, created, expires } link setup terakhir
  let ticketTimer = 0;

  // ---------- tema: ikuti sistem → terang → gelap (disimpan per browser) ----------
  const THEMES = { system: ['i-auto', 'Tema: ikuti sistem'], light: ['i-sun', 'Tema: terang'], dark: ['i-moon', 'Tema: gelap'] };
  function applyTheme(t) {
    if (!THEMES[t]) t = 'system';
    if (t === 'system') delete document.documentElement.dataset.theme;
    else document.documentElement.dataset.theme = t;
    $('themeIcon').setAttribute('href', '#' + THEMES[t][0]);
    $('theme').title = THEMES[t][1];
    $('theme').setAttribute('aria-label', THEMES[t][1]);
    return t;
  }
  let theme = 'system';
  try { theme = localStorage.getItem('pl_admin_theme') || 'system'; } catch (e) {}
  theme = applyTheme(theme);
  $('theme').onclick = () => {
    theme = applyTheme({ system: 'light', light: 'dark', dark: 'system' }[theme]);
    try { localStorage.setItem('pl_admin_theme', theme); } catch (e) {}
  };

  // ---------- bantuan ----------
  function toast(msg, bad) {
    const t = $('toast');
    t.textContent = msg;
    t.classList.toggle('bad', !!bad);
    t.classList.add('show');
    clearTimeout(toast.h);
    toast.h = setTimeout(() => t.classList.remove('show'), bad ? 3600 : 2400);
  }
  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text; // selalu textContent
    return e;
  }
  function icon(id) {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    const use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
    use.setAttribute('href', '#' + id);
    svg.append(use);
    return svg;
  }
  const mb = n => n < 1048576 ? Math.ceil(n / 1024) + ' KB' : (n / 1048576).toFixed(n < 10485760 ? 1 : 0) + ' MB';
  const num = n => Number(n || 0).toLocaleString('id-ID');
  function ago(ms) {
    const s = Math.max(0, (Date.now() - ms) / 1000);
    if (s < 90) return 'baru saja';
    if (s < 3600) return Math.round(s / 60) + ' menit lalu';
    if (s < 86400) return Math.round(s / 3600) + ' jam lalu';
    if (s < 86400 * 30) return Math.round(s / 86400) + ' hari lalu';
    return new Date(ms).toLocaleDateString('id-ID', { day: 'numeric', month: 'short', year: 'numeric' });
  }
  // Jenis perangkat: aplikasi menu bar Mac, HP (halaman web / PWA di HP), browser di komputer
  const KINDS = { mac: ['i-mac', 'Mac (menu bar)'], hp: ['i-phone', 'HP'], browser: ['i-globe', 'Browser'] };
  function kindSummary(list) {
    const n = { mac: 0, hp: 0, browser: 0, '': 0 };
    for (const d of list) n[KINDS[d.kind] ? d.kind : '']++;
    const parts = Object.keys(KINDS).filter(k => n[k]).map(k => n[k] + ' ' + KINDS[k][1].replace(' (menu bar)', ''));
    if (n['']) parts.push(n[''] + ' belum diketahui');
    return parts.join(' · ');
  }
  function duration(min) {
    if (min % 1440 === 0) return (min / 1440) + ' hari';
    if (min % 60 === 0) return (min / 60) + ' jam';
    return min + ' menit';
  }

  // Dialog konfirmasi (pengganti confirm()) → Promise<boolean>
  function ask(title, text, okText) {
    const d = $('confirm');
    $('confirmTitle').textContent = title;
    $('confirmText').textContent = text;
    $('confirmOk').textContent = okText;
    return new Promise(resolve => {
      const done = v => { d.close(); resolve(v); };
      $('confirmOk').onclick = () => done(true);
      $('confirmCancel').onclick = () => done(false);
      d.oncancel = e => { e.preventDefault(); done(false); };
      d.showModal();
      $('confirmCancel').focus();
    });
  }

  async function api(path, opts = {}) {
    opts.headers = Object.assign({ 'X-PasteLAN': '1' }, opts.headers || {});
    opts.credentials = 'same-origin';
    if (opts.json) {
      opts.headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(opts.json);
      delete opts.json;
    }
    const r = await fetch(path, opts);
    if (r.status === 401 && path !== '/api/admin/login') { showLogin(); throw new Error('admin belum login'); }
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(j.error || ('HTTP ' + r.status));
    return j;
  }

  // Tombol sibuk selama aksi berjalan (mencegah klik ganda)
  async function busy(btn, fn) {
    if (btn) btn.disabled = true;
    try { await fn(); } catch (err) { toast(err.message, true); } finally { if (btn) btn.disabled = false; }
  }

  // ---------- masuk / keluar ----------
  function showLogin() {
    $('app').hidden = true;
    $('login').hidden = false;
    $('password').focus();
  }
  $('loginForm').onsubmit = async e => {
    e.preventDefault();
    $('loginErr').textContent = '';
    $('loginBtn').disabled = true;
    try {
      await api('/api/admin/login', { method: 'POST', json: { password: $('password').value } });
      $('password').value = '';
      await load();
    } catch (err) { $('loginErr').textContent = err.message; }
    finally { $('loginBtn').disabled = false; }
  };
  async function logout() {
    try { await api('/api/admin/logout', { method: 'POST' }); } catch (e) {}
    showLogin();
  }
  $('logout').onclick = logout;
  $('logoutTop').onclick = logout;

  // ---------- navigasi (#ringkasan, #perangkat, #clipboard, #keamanan) ----------
  const PAGES = ['ringkasan', 'perangkat', 'clipboard', 'keamanan'];
  function route() {
    const page = PAGES.includes(location.hash.slice(1)) ? location.hash.slice(1) : 'ringkasan';
    for (const p of PAGES) $('page-' + p).hidden = p !== page;
    for (const a of $$('[data-page]')) {
      a.classList.toggle('on', a.dataset.page === page);
      if (a.dataset.page === page) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
    }
    $('pageTitle').textContent = $('page-' + page).dataset.title;
    document.title = $('page-' + page).dataset.title + ' · PasteLAN Admin';
    window.scrollTo(0, 0);
  }
  window.addEventListener('hashchange', route);
  route();

  // ---------- data ----------
  async function load() {
    const j = await api('/api/admin/status');
    status = j;
    $('login').hidden = true;
    $('app').hidden = false;
    $('version').textContent = 'Server ' + j.version;
    showSettings(j.settings);
    showStats(j);
    showDevices(j.devices);
  }
  $('reload').onclick = () => busy($('reload'), async () => { await load(); toast('Data diperbarui'); });

  function showStats(j) {
    const s = j.settings;
    const max = j.maxDevices || 20;
    $('stDevices').textContent = num(j.devices.length);
    const recent = j.devices.filter(d => Date.now() - d.lastSeen < 86400000).length;
    $('stDevicesSub').textContent = (j.devices.length ? kindSummary(j.devices) + ' · ' : '') + `${recent} aktif 24 jam terakhir · maks ${max}`;

    $('stItems').textContent = num(j.items) + ' item';
    const pct = Math.min(100, (j.bytes / (s.maxTotalMB * 1048576)) * 100);
    $('stMeter').style.width = pct + '%';
    $('stItemsSub').textContent = `${mb(j.bytes)} dari ${s.maxTotalMB} MB` + (s.autoClear ? ` · hapus setelah ${duration(s.retentionMinutes)}` : '');
    $('usageText').textContent = `${num(j.items)} dari ${s.maxItems} item · ${mb(j.bytes)} dari ${s.maxTotalMB} MB`;
    $('usagePct').textContent = Math.round(pct) + '%';
    $('usageMeter').style.width = pct + '%';
    $('usageMeter').parentElement.classList.toggle('warn', pct > 85);

    const on = s.passwordLogin && s.devicePasswordOK;
    $('stPw').textContent = on ? 'Aktif' : 'Mati';
    $('stPw').classList.toggle('ok', on);
    $('stPwSub').textContent = on ? 'Perangkat bisa masuk dengan password' : 'Hanya lewat link setup / QR';
  }

  function showSettings(s) {
    settings = s;
    $('autoClear').checked = s.autoClear;
    const unit = s.retentionMinutes % 1440 === 0 ? 1440 : s.retentionMinutes % 60 === 0 ? 60 : 1;
    $('retentionUnit').value = String(unit);
    $('retention').value = s.retentionMinutes / unit;
    $('maxItems').value = s.maxItems;
    $('maxTotalMB').value = s.maxTotalMB;
    $('setupLinkMinutes').value = s.setupLinkMinutes;
    syncAutoClear();
    $('passwordLogin').checked = s.passwordLogin;
    $('pwInfo').textContent = !s.devicePasswordOK ? 'Belum ada password perangkat. Buat di bawah dulu.'
      : s.passwordFromEnv ? 'Password sekarang dari PASTELAN_PASSWORD di server.'
      : 'Password sekarang dibuat dari halaman admin.';
    $('adminPwInfo').textContent = s.adminFromEnv
      ? 'Sekarang memakai PASTELAN_ADMIN_PASSWORD dari server. Setelah diganti di sini, password baru disimpan sebagai hash dan menggantikannya.'
      : 'Sudah diganti dari halaman admin (disimpan sebagai hash). PASTELAN_ADMIN_PASSWORD di server tidak dipakai lagi.';
  }
  function syncAutoClear() { $('retention').disabled = $('retentionUnit').disabled = !$('autoClear').checked; }
  $('autoClear').onchange = syncAutoClear;

  async function saveSettings(body) {
    const j = await api('/api/admin/settings', { method: 'PUT', json: body });
    showSettings(j.settings);
    load().catch(() => {});
  }

  // ---------- clipboard ----------
  $('clipForm').onsubmit = e => {
    e.preventDefault();
    busy(e.submitter, async () => {
      await saveSettings({
        autoClear: $('autoClear').checked,
        retentionMinutes: Math.round(Number($('retention').value) * Number($('retentionUnit').value)),
        maxItems: Number($('maxItems').value),
        maxTotalMB: Number($('maxTotalMB').value)
      });
      toast('Pengaturan disimpan');
    });
  };
  $('clearItems').onclick = async () => {
    if (!await ask('Hapus semua riwayat?', 'Riwayat clipboard di server dikosongkan untuk semua perangkat.', 'Hapus semua')) return;
    busy($('clearItems'), async () => { await api('/api/admin/items', { method: 'DELETE' }); toast('Riwayat dihapus'); await load(); });
  };

  // ---------- keamanan ----------
  $('showAdminPw').onchange = () => {
    for (const id of ['curAdminPw', 'newAdminPw', 'newAdminPw2']) $(id).type = $('showAdminPw').checked ? 'text' : 'password';
  };
  $('adminPwForm').onsubmit = e => {
    e.preventDefault();
    if ($('newAdminPw').value !== $('newAdminPw2').value) { toast('Password baru dan ulangannya tidak sama', true); $('newAdminPw2').focus(); return; }
    busy(e.submitter, async () => {
      const j = await api('/api/admin/admin-password', { method: 'POST', json: { current: $('curAdminPw').value, password: $('newAdminPw').value } });
      for (const id of ['curAdminPw', 'newAdminPw', 'newAdminPw2']) $(id).value = '';
      showSettings(j.settings);
      toast('Password admin diganti');
    });
  };

  $('pwForm').onsubmit = e => {
    e.preventDefault();
    const want = $('passwordLogin').checked; // dibaca dulu: showSettings di bawah menimpa centangnya
    busy(e.submitter, async () => {
      try {
        const pw = $('newPassword').value;
        if (pw) {
          const j = await api('/api/admin/password', { method: 'POST', json: { password: pw } });
          $('newPassword').value = '';
          showSettings(j.settings);
        }
        if (want !== settings.passwordLogin) await saveSettings({ passwordLogin: want });
        else load().catch(() => {});
        toast('Disimpan');
      } catch (err) { showSettings(settings); throw err; }
    });
  };

  $('linkForm').onsubmit = e => {
    e.preventDefault();
    busy(e.submitter, async () => { await saveSettings({ setupLinkMinutes: Number($('setupLinkMinutes').value) }); toast('Disimpan'); });
  };

  // ---------- link setup (tiket dengan hitung mundur) ----------
  async function newLink(btn) {
    await busy(btn, async () => {
      const j = await api('/api/admin/setup-link', { method: 'POST' });
      ticket = { link: location.origin + '/#pair=' + j.code, created: Date.now(), expires: j.expires };
      renderTicket();
      clearInterval(ticketTimer);
      ticketTimer = setInterval(tickTicket, 1000);
    });
  }
  for (const b of $$('[data-action="newLink"]')) b.onclick = () => newLink(b);

  function renderTicket() {
    for (const box of $$('[data-ticket]')) {
      box.textContent = '';
      box.hidden = !ticket;
      if (!ticket) continue;
      const link = el('div', 'link', ticket.link);
      const row = el('div', 't-row');
      const left = el('div', 'left');
      left.append(el('b', 'left-time'), el('span', 'meter'), el('small', '', 'Sekali pakai. Jangan bagikan ke orang lain.'));
      left.querySelector('.meter').append(el('span'));
      const copy = el('button', 'btn primary sm');
      copy.type = 'button';
      copy.append(icon('i-copy'), 'Salin link');
      copy.onclick = async () => {
        try { await navigator.clipboard.writeText(ticket.link); toast('Link tersalin'); }
        catch (e) { const r = document.createRange(); r.selectNodeContents(link); getSelection().removeAllRanges(); getSelection().addRange(r); toast('Tekan ⌘C / Ctrl+C untuk menyalin'); }
      };
      row.append(left, copy);
      box.append(link, row);
    }
    tickTicket();
  }
  function tickTicket() {
    if (!ticket) return;
    const left = ticket.expires - Date.now();
    const total = ticket.expires - ticket.created;
    for (const box of $$('[data-ticket]')) {
      box.classList.toggle('expired', left <= 0);
      const t = box.querySelector('.left-time');
      if (!t) continue;
      if (left <= 0) t.textContent = 'Kedaluwarsa, buat link baru';
      else {
        const m = Math.floor(left / 60000), s = Math.floor(left / 1000) % 60;
        t.textContent = `Berlaku ${m}:${String(s).padStart(2, '0')} lagi`;
      }
      box.querySelector('.meter > span').style.width = Math.max(0, left / total * 100) + '%';
      const copy = box.querySelector('button');
      if (copy) copy.disabled = left <= 0;
    }
    if (left <= 0) clearInterval(ticketTimer);
  }

  // ---------- perangkat ----------
  function deviceRow(d, withRevoke) {
    const li = el('li');
    const kind = KINDS[d.kind];
    const av = el('span', 'av' + (kind ? ' k-' + d.kind : ''), kind ? null : (d.name.trim()[0] || '?').toUpperCase());
    if (kind) { av.append(icon(kind[0])); av.title = kind[1]; }
    li.append(av);
    const info = el('div', 'info');
    const name = el('div', 'name', d.name);
    name.append(el('span', 'kind' + (kind ? ' k-' + d.kind : ''), kind ? kind[1] : 'Jenis belum diketahui'));
    info.append(name);
    const sub = el('div', 'sub');
    if (Date.now() - d.lastSeen < 5 * 60000) sub.append(el('span', 'live'));
    sub.append('Aktif ' + ago(d.lastSeen) + ' · masuk ' + new Date(d.created).toLocaleDateString('id-ID', { day: 'numeric', month: 'short' }));
    info.append(sub);
    li.append(info);
    if (withRevoke) {
      const b = el('button', 'btn danger sm', 'Cabut');
      b.type = 'button';
      b.onclick = async () => {
        if (!await ask(`Cabut "${d.name}"?`, 'Perangkat ini keluar dan harus masuk lagi lewat link setup atau password.', 'Cabut')) return;
        busy(b, async () => { await api('/api/admin/devices/' + encodeURIComponent(d.id), { method: 'DELETE' }); toast('Perangkat dicabut'); await load(); });
      };
      li.append(b);
    }
    return li;
  }
  function showDevices(list) {
    const box = $('devices'), recent = $('recentDevices');
    box.textContent = '';
    recent.textContent = '';
    $('devCount').textContent = list.length ? `${list.length} dari maks ${status.maxDevices || 20} perangkat: ${kindSummary(list)}.` : '';
    if (!list.length) {
      box.append(el('li', 'empty', 'Belum ada perangkat. Buat link setup di atas untuk menambah.'));
      recent.append(el('li', 'empty', 'Belum ada perangkat yang masuk.'));
      return;
    }
    for (const d of list) box.append(deviceRow(d, true));
    for (const d of [...list].sort((a, b) => b.lastSeen - a.lastSeen).slice(0, 3)) recent.append(deviceRow(d, false));
  }
  $('revokeAll').onclick = async () => {
    if (!await ask('Cabut semua perangkat?', 'Semua Mac dan HP keluar dan harus masuk lagi lewat link setup atau password.', 'Cabut semua')) return;
    busy($('revokeAll'), async () => { await api('/api/admin/devices', { method: 'DELETE' }); toast('Semua perangkat dicabut'); await load(); });
  };

  load().catch(() => {});
})();
