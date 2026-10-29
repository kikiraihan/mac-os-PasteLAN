// PasteLAN — halaman admin. Tanpa library / CDN; sesi admin di cookie HttpOnly (tidak terbaca JS).
'use strict';
(() => {
  const $ = id => document.getElementById(id);
  let settings = {};

  function toast(msg) {
    const t = $('toast');
    t.textContent = msg;
    t.classList.add('show');
    clearTimeout(toast.h);
    toast.h = setTimeout(() => t.classList.remove('show'), 2400);
  }
  function setStatus(state, text) { $('dot').className = 'dot ' + state; $('status').textContent = text; }
  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text; // selalu textContent
    return e;
  }
  const mb = n => (n / 1048576).toFixed(n < 10485760 ? 1 : 0) + ' MB';

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

  function showLogin() {
    $('app').hidden = true;
    $('login').hidden = false;
    setStatus('off', 'Belum masuk');
    $('password').focus();
  }
  $('login').onsubmit = async e => {
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

  async function load() {
    const j = await api('/api/admin/status');
    $('login').hidden = true;
    $('app').hidden = false;
    setStatus('on', 'Admin');
    $('version').textContent = 'Server PasteLAN ' + j.version;
    $('usage').textContent = `Sekarang: ${j.items} item, ${mb(j.bytes)} di memori.`;
    showSettings(j.settings);
    showDevices(j.devices);
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
    $('pwInfo').textContent = !s.devicePasswordOK ? 'Belum ada password perangkat. Isi di bawah untuk membuatnya.'
      : s.passwordFromEnv ? 'Password sekarang: PASTELAN_PASSWORD dari server. Isi di bawah untuk menggantinya.'
      : 'Password sekarang: dibuat dari halaman admin. Isi di bawah untuk menggantinya.';
  }
  function syncAutoClear() { $('retention').disabled = $('retentionUnit').disabled = !$('autoClear').checked; }
  $('autoClear').onchange = syncAutoClear;

  $('clipForm').onsubmit = async e => {
    e.preventDefault();
    try {
      const j = await api('/api/admin/settings', { method: 'PUT', json: {
        autoClear: $('autoClear').checked,
        retentionMinutes: Math.round(Number($('retention').value) * Number($('retentionUnit').value)),
        maxItems: Number($('maxItems').value),
        maxTotalMB: Number($('maxTotalMB').value),
        setupLinkMinutes: Number($('setupLinkMinutes').value)
      } });
      showSettings(j.settings);
      toast('Pengaturan disimpan ✓');
      load().catch(() => {});
    } catch (err) { toast(err.message); }
  };
  $('clearItems').onclick = async () => {
    if (!confirm('Hapus semua riwayat clipboard di server (untuk semua perangkat)?')) return;
    try { await api('/api/admin/items', { method: 'DELETE' }); toast('Riwayat dihapus'); load().catch(() => {}); }
    catch (err) { toast(err.message); }
  };

  $('pwForm').onsubmit = async e => {
    e.preventDefault();
    const want = $('passwordLogin').checked; // dibaca dulu: showSettings di bawah menimpa centangnya
    try {
      const pw = $('newPassword').value;
      if (pw) {
        const j = await api('/api/admin/password', { method: 'POST', json: { password: pw } });
        $('newPassword').value = '';
        showSettings(j.settings);
      }
      if (want !== settings.passwordLogin) {
        const j = await api('/api/admin/settings', { method: 'PUT', json: { passwordLogin: want } });
        showSettings(j.settings);
      }
      toast('Disimpan ✓');
    } catch (err) { toast(err.message); showSettings(settings); }
  };

  $('newLink').onclick = async () => {
    try {
      const j = await api('/api/admin/setup-link', { method: 'POST' });
      $('link').value = location.origin + '/#pair=' + j.code;
      const exp = new Date(j.expires).toLocaleTimeString('id-ID', { hour: '2-digit', minute: '2-digit' });
      $('linkExp').textContent = `Sekali pakai, berlaku sampai ${exp}. Jangan bagikan ke orang lain.`;
      $('linkBox').hidden = false;
      $('link').select();
    } catch (err) { toast(err.message); }
  };
  $('copyLink').onclick = async () => {
    try { await navigator.clipboard.writeText($('link').value); toast('Link tersalin ✓'); }
    catch (e) { $('link').select(); toast('Tekan ⌘C / salin manual'); }
  };

  function showDevices(list) {
    const box = $('devices');
    box.textContent = '';
    if (!list.length) box.append(el('div', 'hint', 'Belum ada perangkat yang masuk.'));
    for (const d of list) {
      const row = el('div', 'dev');
      const info = el('span', '', d.name);
      info.append(el('small', '', 'Masuk ' + new Date(d.created).toLocaleString('id-ID') +
        ' · terakhir aktif ' + new Date(d.lastSeen).toLocaleString('id-ID')));
      const b = el('button', 'ghost danger', 'Cabut');
      b.type = 'button';
      b.onclick = async () => {
        if (!confirm(`Cabut akses "${d.name}"?`)) return;
        try { await api('/api/admin/devices/' + encodeURIComponent(d.id), { method: 'DELETE' }); load(); }
        catch (err) { toast(err.message); }
      };
      row.append(info, b);
      box.append(row);
    }
  }
  $('revokeAll').onclick = async () => {
    if (!confirm('Cabut SEMUA perangkat? Semua Mac & HP harus masuk lagi (link setup / password).')) return;
    try { await api('/api/admin/devices', { method: 'DELETE' }); toast('Semua perangkat dicabut'); load(); }
    catch (err) { toast(err.message); }
  };

  $('logout').onclick = async () => {
    try { await api('/api/admin/logout', { method: 'POST' }); } catch (e) {}
    showLogin();
  };

  load().catch(() => {});
})();
