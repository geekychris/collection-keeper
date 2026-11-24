package app

import (
	"context"
	"log/slog"
	"net/http"
	"net/url"
	"runtime"
	"strings"
	"time"
)

func (a *App) adminPage(w http.ResponseWriter, r *http.Request, s *Session) {
	ctx := r.Context()
	var users, devices, events24, errors24 int
	var dbSize int64
	_ = a.store.DB.QueryRow(ctx, `SELECT count(*) FROM users`).Scan(&users)
	_ = a.store.DB.QueryRow(ctx, `SELECT count(*) FROM devices WHERE revoked_at IS NULL`).Scan(&devices)
	_ = a.store.DB.QueryRow(ctx, `SELECT count(*), count(*) FILTER (WHERE status >= 400 OR rejected > 0) FROM sync_events WHERE at > now() - interval '24 hours'`).Scan(&events24, &errors24)
	_ = a.store.DB.QueryRow(ctx, `SELECT pg_database_size(current_database())`).Scan(&dbSize)
	kinds, _ := a.store.Counts(ctx, "")
	blobStats, _ := a.blobs.Stats(ctx)
	free, total, diskErr := a.blobs.DiskFree()
	var mem runtime.MemStats
	runtime.ReadMemStats(&mem)

	oidc := map[string]any{"Enabled": a.oidc != nil}
	if a.oidc != nil {
		ctx2, cancel := context.WithTimeout(ctx, 5*time.Second)
		ok, detail := a.oidc.Status(ctx2)
		cancel()
		oidc["OK"], oidc["Detail"] = ok, detail
		oidc["Issuer"], oidc["Backchannel"], oidc["ClientID"] = a.cfg.OIDCIssuer, a.cfg.OIDCBackchannel, a.cfg.OIDCClientID
		oidc["AdminRole"], oidc["UserRoles"] = a.cfg.OIDCAdminRole, strings.Join(a.cfg.OIDCUserRoles, ", ")
	}
	var pgVersion string
	_ = a.store.DB.QueryRow(ctx, `SHOW server_version`).Scan(&pgVersion)
	errs := a.logs.Lines(slog.LevelWarn)
	if len(errs) > 10 {
		errs = errs[:10]
	}
	a.render(w, r, s, 200, "admin", "Server", map[string]any{
		"Users": users, "Devices": devices, "Events24": events24, "Errors24": errors24,
		"DBSize": dbSize, "Kinds": kinds, "Blobs": blobStats, "Free": free, "Total": total, "DiskErr": diskErr,
		"Uptime": time.Since(a.started).Round(time.Second).String(), "Started": a.started,
		"GoVersion": runtime.Version(), "Goroutines": runtime.NumGoroutine(), "HeapBytes": mem.HeapAlloc,
		"Schema": a.store.SchemaVersion(ctx), "Postgres": pgVersion, "BlobDir": a.cfg.BlobDir,
		"OIDC": oidc, "LocalAdmin": a.cfg.AdminPassword != "", "Warnings": errs,
		"Base": publicBase(r, a.cfg.PublicURL),
	})
}

func (a *App) adminUsers(w http.ResponseWriter, r *http.Request, s *Session) {
	users, err := a.store.UserSummaries(r.Context())
	if err != nil {
		a.errorPage(w, r, s, 500, err.Error())
		return
	}
	a.render(w, r, s, 200, "admin_users", "People", map[string]any{"Users": users, "OIDC": a.oidc != nil})
}

func (a *App) adminCreateUser(w http.ResponseWriter, r *http.Request, s *Session) {
	pw := r.PostFormValue("password")
	if len(pw) < 10 {
		redirectFlashErr(w, r, "/admin/users", "A password needs at least 10 characters.")
		return
	}
	h, err := hashPassword(pw)
	if err == nil {
		_, err = a.store.CreateLocalUser(r.Context(), r.PostFormValue("username"), strings.TrimSpace(r.PostFormValue("name")), h, r.PostFormValue("admin") == "on")
	}
	if err != nil {
		redirectFlashErr(w, r, "/admin/users", err.Error())
		return
	}
	a.log.Info("local account created", "username", r.PostFormValue("username"), "by", s.User.Username)
	redirectFlash(w, r, "/admin/users", "Account "+cleanUsername(r.PostFormValue("username"))+" created.")
}

func (a *App) adminUser(w http.ResponseWriter, r *http.Request, s *Session) {
	ctx := r.Context()
	u, err := a.store.UserByID(ctx, r.PathValue("id"))
	if err != nil || u == nil {
		a.errorPage(w, r, s, http.StatusNotFound, "No such person.")
		return
	}
	devices, _ := a.store.Devices(ctx, u.ID)
	events, _ := a.store.Events(ctx, EventFilter{UserID: u.ID, Limit: 100})
	kinds, _ := a.store.Counts(ctx, u.ID)
	recent, _ := a.store.Recent(ctx, u.ID, 25)
	var blobs int
	var blobBytes int64
	_ = a.store.DB.QueryRow(ctx, `SELECT count(*), coalesce(sum(b.size),0) FROM blob_owners o JOIN blobs b USING (sha256) WHERE o.owner_id=$1`, u.ID).Scan(&blobs, &blobBytes)
	a.render(w, r, s, 200, "admin_user", u.Username, map[string]any{
		"U": u, "Devices": devices, "Events": events, "Kinds": kinds, "Recent": recent, "Blobs": blobs, "BlobBytes": blobBytes,
		"Self": u.ID == s.User.ID,
	})
}

func (a *App) adminUpdateUser(w http.ResponseWriter, r *http.Request, s *Session) {
	ctx := r.Context()
	u, err := a.store.UserByID(ctx, r.PathValue("id"))
	if err != nil || u == nil {
		a.errorPage(w, r, s, http.StatusNotFound, "No such person.")
		return
	}
	back := "/admin/users/" + u.ID
	switch r.PostFormValue("action") {
	case "disable", "enable":
		if u.ID == s.User.ID {
			redirectFlashErr(w, r, back, "You can't disable yourself.")
			return
		}
		err = a.store.SetDisabled(ctx, u.ID, r.PostFormValue("action") == "disable")
	case "admin", "unadmin":
		if u.ID == s.User.ID {
			redirectFlashErr(w, r, back, "You can't change your own admin rights.")
			return
		}
		if u.OIDCSub != nil {
			redirectFlashErr(w, r, back, "Admin rights for people from the login service come from their role there; they're updated at their next sign-in.")
			return
		}
		err = a.store.SetAdmin(ctx, u.ID, r.PostFormValue("action") == "admin")
	case "password":
		pw := r.PostFormValue("password")
		if len(pw) < 10 {
			redirectFlashErr(w, r, back, "A password needs at least 10 characters.")
			return
		}
		var h string
		if h, err = hashPassword(pw); err == nil {
			err = a.store.SetPassword(ctx, u.ID, h)
		}
	default:
		redirectFlashErr(w, r, back, "Unknown action.")
		return
	}
	if err != nil {
		redirectFlashErr(w, r, back, err.Error())
		return
	}
	a.log.Info("account changed", "user", u.Username, "action", r.PostFormValue("action"), "by", s.User.Username)
	redirectFlash(w, r, back, "Saved.")
}

// adminViewAs switches the library pages to another person's library (read
// only), or back to the admin's own.
func (a *App) adminViewAs(w http.ResponseWriter, r *http.Request, s *Session) {
	id := r.PostFormValue("user")
	if id == s.User.ID {
		id = ""
	}
	if id != "" {
		if u, _ := a.store.UserByID(r.Context(), id); u == nil {
			a.errorPage(w, r, s, http.StatusNotFound, "No such person.")
			return
		}
	}
	if err := a.setViewAs(r.Context(), s, id); err != nil {
		a.errorPage(w, r, s, 500, err.Error())
		return
	}
	a.log.Info("viewing a library", "admin", s.User.Username, "as", id)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (a *App) adminDevices(w http.ResponseWriter, r *http.Request, s *Session) {
	devices, err := a.store.Devices(r.Context(), "")
	if err != nil {
		a.errorPage(w, r, s, 500, err.Error())
		return
	}
	users, _ := a.store.UserSummaries(r.Context())
	names := map[string]string{}
	for _, u := range users {
		names[u.ID] = u.Username
	}
	a.render(w, r, s, 200, "admin_devices", "Devices", map[string]any{"Devices": devices, "Names": names})
}

func (a *App) adminEvents(w http.ResponseWriter, r *http.Request, s *Session) {
	f := EventFilter{ErrorsOnly: r.URL.Query().Get("errors") != "", Limit: 300}
	if id := r.URL.Query().Get("user"); isUUID(id) {
		f.UserID = id
	}
	if id := r.URL.Query().Get("device"); isUUID(id) {
		f.DeviceID = id
	}
	events, err := a.store.Events(r.Context(), f)
	if err != nil {
		a.errorPage(w, r, s, 500, err.Error())
		return
	}
	a.render(w, r, s, 200, "admin_events", "Sync log", map[string]any{"Events": events, "F": f})
}

func (a *App) adminCheck(w http.ResponseWriter, r *http.Request, s *Session) {
	var rep *CheckReport
	var err error
	if r.URL.Query().Get("run") != "" {
		start := time.Now()
		rep, err = a.blobs.Check(r.Context())
		if err != nil {
			a.errorPage(w, r, s, 500, err.Error())
			return
		}
		a.log.Info("integrity check", "ms", time.Since(start).Milliseconds(), "missingBlob", len(rep.MissingBlob), "missingFile", len(rep.MissingFile))
	}
	users, _ := a.store.UserSummaries(r.Context())
	names := map[string]string{}
	for _, u := range users {
		names[u.ID] = u.Username
	}
	a.render(w, r, s, 200, "admin_check", "Integrity check", map[string]any{"R": rep, "Names": names})
}

func (a *App) adminLogs(w http.ResponseWriter, r *http.Request, s *Session) {
	min := slog.LevelInfo
	if r.URL.Query().Get("level") == "warn" {
		min = slog.LevelWarn
	}
	a.render(w, r, s, 200, "admin_logs", "Logs", map[string]any{"Lines": a.logs.Lines(min), "Warn": min == slog.LevelWarn})
}

func redirectFlashErr(w http.ResponseWriter, r *http.Request, to, msg string) {
	sep := "?"
	if strings.Contains(to, "?") {
		sep = "&"
	}
	http.Redirect(w, r, to+sep+"err="+url.QueryEscape(msg), http.StatusSeeOther)
}
