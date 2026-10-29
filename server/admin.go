package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"
)

// Halaman admin (/admin): masuk dengan PASTELAN_ADMIN_PASSWORD → sesi admin di cookie terpisah (HttpOnly, Secure,
// SameSite=Strict, hanya untuk /api/admin). Admin bisa membuat link setup, mengelola perangkat, password bersama,
// dan batas riwayat clipboard.

const adminCookie = "pl_admin"

func (a *app) adminRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/admin/login", a.adminLogin)
	mux.HandleFunc("POST /api/admin/logout", a.admin(a.adminLogout))
	mux.HandleFunc("GET /api/admin/status", a.admin(a.adminStatus))
	mux.HandleFunc("PUT /api/admin/settings", a.admin(a.adminSettings))
	mux.HandleFunc("POST /api/admin/password", a.admin(a.adminPassword))
	mux.HandleFunc("POST /api/admin/setup-link", a.admin(a.adminSetupLink))
	mux.HandleFunc("DELETE /api/admin/devices/{id}", a.admin(a.adminRevoke))
	mux.HandleFunc("DELETE /api/admin/devices", a.admin(a.adminRevokeAll))
	mux.HandleFunc("DELETE /api/admin/items", a.admin(a.adminClearItems))
}

func setAdminCookie(w http.ResponseWriter, value string, maxAge int) {
	http.SetCookie(w, &http.Cookie{Name: adminCookie, Value: value, Path: "/api/admin", MaxAge: maxAge,
		HttpOnly: true, Secure: true, SameSite: http.SameSiteStrictMode})
}

func adminToken(r *http.Request) string {
	if c, err := r.Cookie(adminCookie); err == nil {
		return c.Value
	}
	return ""
}

func (a *app) admin(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !a.auth.checkAdmin(adminToken(r)) {
			jsonError(w, http.StatusUnauthorized, "admin belum login")
			return
		}
		h(w, r)
	}
}

func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(v); err != nil {
		jsonError(w, http.StatusBadRequest, "format salah")
		return false
	}
	return true
}

func (a *app) adminLogin(w http.ResponseWriter, r *http.Request) {
	var req struct{ Password string }
	if !decode(w, r, &req) {
		return
	}
	token, err := a.auth.adminLogin(clientIP(r), req.Password)
	switch {
	case errors.Is(err, errLocked):
		jsonError(w, http.StatusTooManyRequests, err.Error())
	case errors.Is(err, errBadPassword):
		jsonError(w, http.StatusUnauthorized, err.Error())
	case errors.Is(err, errNoAdmin):
		jsonError(w, http.StatusForbidden, err.Error())
	case err != nil:
		jsonError(w, http.StatusInternalServerError, err.Error())
	default:
		setAdminCookie(w, token, int(adminTTL.Seconds()))
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	}
}

func (a *app) adminLogout(w http.ResponseWriter, r *http.Request) {
	a.auth.adminLogout(adminToken(r))
	setAdminCookie(w, "", -1)
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// adminView: pengaturan tanpa hash password
func (a *app) adminView(s settings) map[string]any {
	return map[string]any{
		"passwordLogin":    s.PasswordLogin,
		"devicePasswordOK": s.DevicePassword != "" || a.auth.hasEnvPw,
		"passwordFromEnv":  s.DevicePassword == "" && a.auth.hasEnvPw,
		"autoClear":        s.AutoClear,
		"retentionMinutes": s.RetentionMinutes,
		"maxItems":         s.MaxItems,
		"maxTotalMB":       s.MaxTotalMB,
		"setupLinkMinutes": s.SetupLinkMinutes,
	}
}

func (a *app) adminStatus(w http.ResponseWriter, r *http.Request) {
	type dev struct {
		ID       string `json:"id"`
		Name     string `json:"name"`
		Created  int64  `json:"created"`
		LastSeen int64  `json:"lastSeen"`
	}
	devs := []dev{}
	for _, x := range a.auth.list() {
		devs = append(devs, dev{x.ID, x.Name, x.Created.UnixMilli(), x.LastSeen.UnixMilli()})
	}
	count, bytes := a.store.stats()
	writeJSON(w, http.StatusOK, map[string]any{
		"version":  version,
		"settings": a.adminView(a.settings.get()),
		"devices":  devs,
		"items":    count,
		"bytes":    bytes,
	})
}

// adminSettings: hanya field yang dikirim yang diubah
func (a *app) adminSettings(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PasswordLogin    *bool `json:"passwordLogin"`
		AutoClear        *bool `json:"autoClear"`
		RetentionMinutes *int  `json:"retentionMinutes"`
		MaxItems         *int  `json:"maxItems"`
		MaxTotalMB       *int  `json:"maxTotalMB"`
		SetupLinkMinutes *int  `json:"setupLinkMinutes"`
	}
	if !decode(w, r, &req) {
		return
	}
	s, err := a.settings.update(func(s *settings) error {
		if req.PasswordLogin != nil {
			if *req.PasswordLogin && s.DevicePassword == "" && !a.auth.hasEnvPw {
				return errors.New("buat password perangkat dulu sebelum mengaktifkan login dengan password")
			}
			s.PasswordLogin = *req.PasswordLogin
		}
		set := func(dst *int, v *int) {
			if v != nil {
				*dst = *v
			}
		}
		if req.AutoClear != nil {
			s.AutoClear = *req.AutoClear
		}
		set(&s.RetentionMinutes, req.RetentionMinutes)
		set(&s.MaxItems, req.MaxItems)
		set(&s.MaxTotalMB, req.MaxTotalMB)
		set(&s.SetupLinkMinutes, req.SetupLinkMinutes)
		return nil
	})
	if err != nil {
		jsonError(w, http.StatusBadRequest, err.Error())
		return
	}
	a.store.setLimits(s.limits())
	writeJSON(w, http.StatusOK, map[string]any{"settings": a.adminView(s)})
}

// adminPassword mengganti password bersama perangkat (disimpan sebagai hash PBKDF2). Perangkat yang sudah login tetap.
func (a *app) adminPassword(w http.ResponseWriter, r *http.Request) {
	var req struct{ Password string }
	if !decode(w, r, &req) {
		return
	}
	if err := checkNewPassword(req.Password); err != nil {
		jsonError(w, http.StatusBadRequest, err.Error())
		return
	}
	if a.auth.hasAdmin && sha256Equal(req.Password, a.auth.adminHash) {
		jsonError(w, http.StatusBadRequest, "password perangkat harus berbeda dari password admin")
		return
	}
	hashSlots <- struct{}{}
	h, err := hashPassword(req.Password)
	<-hashSlots
	if err != nil {
		jsonError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s, err := a.settings.update(func(s *settings) error {
		s.DevicePassword = h
		return nil
	})
	if err != nil {
		jsonError(w, http.StatusInternalServerError, "gagal menyimpan: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"settings": a.adminView(s)})
}

// adminSetupLink: kode sekali pakai untuk perangkat baru (Mac: tempel link; HP: buka link)
func (a *app) adminSetupLink(w http.ResponseWriter, r *http.Request) {
	ttl := time.Duration(a.settings.get().SetupLinkMinutes) * time.Minute
	code, exp := a.auth.newPair(ttl)
	writeJSON(w, http.StatusOK, map[string]any{"code": code, "expires": exp.UnixMilli()})
}

func (a *app) adminRevoke(w http.ResponseWriter, r *http.Request) {
	if !a.auth.revoke(r.PathValue("id")) {
		jsonError(w, http.StatusNotFound, "perangkat tidak ditemukan")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (a *app) adminRevokeAll(w http.ResponseWriter, r *http.Request) {
	if err := a.auth.revokeAll(); err != nil {
		jsonError(w, http.StatusInternalServerError, "gagal menyimpan: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (a *app) adminClearItems(w http.ResponseWriter, r *http.Request) {
	a.store.clear()
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}
