package app

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"runtime/debug"
	"strings"
	"time"
)

// App is the whole server.
type App struct {
	cfg     Config
	store   *Store
	blobs   *Blobs
	oidc    *oidcClient
	log     *slog.Logger
	logs    *LogRing
	started time.Time
	pages   *pages
}

func New(ctx context.Context, cfg Config, logger *slog.Logger, logs *LogRing) (*App, error) {
	store, err := OpenStore(ctx, cfg.DatabaseURL)
	if err != nil {
		return nil, err
	}
	a := &App{cfg: cfg, store: store, blobs: &Blobs{Dir: cfg.BlobDir, store: store}, log: logger, logs: logs, started: time.Now()}
	if cfg.OIDCEnabled() {
		a.oidc = &oidcClient{cfg: cfg}
		if err := a.oidc.discover(ctx); err != nil {
			// Not fatal: the login service may come up after us.
			logger.Warn("OpenID Connect provider not reachable yet", "err", err)
		}
	}
	if err := a.ensureAdmin(ctx); err != nil {
		store.Close()
		return nil, err
	}
	if a.pages, err = loadPages(); err != nil {
		store.Close()
		return nil, err
	}
	go a.housekeeping(ctx)
	return a, nil
}

func (a *App) Close() { a.store.Close() }

func (a *App) housekeeping(ctx context.Context) {
	t := time.NewTicker(time.Hour)
	defer t.Stop()
	for {
		a.store.Prune(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// Handler is every route.
func (a *App) Handler() http.Handler {
	mux := http.NewServeMux()

	// The app's API (docs/sync-protocol.md).
	mux.HandleFunc("GET /api/v1/info", a.apiInfo)
	mux.HandleFunc("POST /api/v1/pair/start", a.apiPairStart)
	mux.HandleFunc("POST /api/v1/pair/poll", a.apiPairPoll)
	mux.HandleFunc("GET /api/v1/me", a.requireDevice(a.apiMe))
	mux.HandleFunc("POST /api/v1/sync/push", a.requireDevice(a.apiPush))
	mux.HandleFunc("GET /api/v1/sync/pull", a.requireDevice(a.apiPull))
	mux.HandleFunc("HEAD /api/v1/blobs/{sha}", a.requireDevice(a.apiBlobHead))
	mux.HandleFunc("GET /api/v1/blobs/{sha}", a.requireDevice(a.apiBlobGet))
	mux.HandleFunc("PUT /api/v1/blobs/{sha}", a.requireDevice(a.apiBlobPut))
	mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) { writeError(w, http.StatusNotFound, "no such API") })

	mux.HandleFunc("GET /healthz", a.healthz)
	mux.Handle("GET /static/", http.StripPrefix("/static/", staticFiles()))

	// Signing in and out.
	mux.HandleFunc("GET /login", a.loginPage)
	mux.HandleFunc("POST /login", a.loginPassword)
	mux.HandleFunc("GET /login/oidc", a.loginOIDC)
	mux.HandleFunc("GET "+oidcCallbackPath, a.oidcCallback)
	mux.HandleFunc("POST /logout", a.logout)

	// A person's own pages.
	mux.HandleFunc("GET /{$}", a.web(a.homePage))
	mux.HandleFunc("GET /c/{id}", a.web(a.collectionPage))
	mux.HandleFunc("GET /i/{id}", a.web(a.itemPage))
	mux.HandleFunc("GET /l/{id}", a.web(a.locationPage))
	mux.HandleFunc("GET /locations", a.web(a.locationsPage))
	mux.HandleFunc("GET /record/{kind}/{id}", a.web(a.recordPage))
	mux.HandleFunc("GET /media/{sha}", a.web(a.mediaFile))
	mux.HandleFunc("GET /devices", a.web(a.devicesPage))
	mux.HandleFunc("POST /devices/{id}/revoke", a.web(a.revokeDevice))
	mux.HandleFunc("GET /pair", a.web(a.pairPage))
	mux.HandleFunc("POST /pair", a.web(a.pairDecide))
	mux.HandleFunc("GET /help", a.web(a.helpPage))

	// Admin.
	mux.HandleFunc("GET /admin", a.admin(a.adminPage))
	mux.HandleFunc("GET /admin/users", a.admin(a.adminUsers))
	mux.HandleFunc("POST /admin/users", a.admin(a.adminCreateUser))
	mux.HandleFunc("GET /admin/users/{id}", a.admin(a.adminUser))
	mux.HandleFunc("POST /admin/users/{id}", a.admin(a.adminUpdateUser))
	mux.HandleFunc("POST /admin/view-as", a.admin(a.adminViewAs))
	mux.HandleFunc("GET /admin/devices", a.admin(a.adminDevices))
	mux.HandleFunc("GET /admin/events", a.admin(a.adminEvents))
	mux.HandleFunc("GET /admin/check", a.admin(a.adminCheck))
	mux.HandleFunc("GET /admin/logs", a.admin(a.adminLogs))

	return a.middleware(mux)
}

// middleware adds security headers, recovers from panics and logs requests.
func (a *App) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: 200}
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "same-origin")
		if !strings.HasPrefix(r.URL.Path, "/api/") {
			h.Set("X-Frame-Options", "DENY")
			h.Set("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; media-src 'self'; style-src 'self'; script-src 'self'; frame-ancestors 'none'; form-action 'self' https:")
		}
		defer func() {
			if p := recover(); p != nil {
				a.log.Error("panic", "path", r.URL.Path, "panic", fmt.Sprint(p), "stack", string(debug.Stack()))
				if rec.status == 200 && !rec.wrote {
					writeError(rec, http.StatusInternalServerError, "internal error")
				}
			}
			if r.URL.Path == "/healthz" || strings.HasPrefix(r.URL.Path, "/static/") {
				return
			}
			level := slog.LevelInfo
			if rec.status >= 500 {
				level = slog.LevelError
			}
			// Never the query string: it can hold a pairing or sign-in code.
			a.log.Log(r.Context(), level, "request", "method", r.Method, "path", r.URL.Path, "status", rec.status,
				"ms", time.Since(start).Milliseconds(), "ip", clientIP(r))
		}()
		next.ServeHTTP(rec, r)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
	wrote  bool
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status, s.wrote = code, true
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusRecorder) Write(b []byte) (int, error) {
	s.wrote = true
	return s.ResponseWriter.Write(b)
}

func (s *statusRecorder) Unwrap() http.ResponseWriter { return s.ResponseWriter }

func (a *App) healthz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	if err := a.store.DB.Ping(ctx); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "down", "db": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "version": a.cfg.Version})
}

// ---- request helpers ----

// requestScheme is https when the proxy says so (or TLS reached us).
func requestScheme(r *http.Request) string {
	if p := r.Header.Get("X-Forwarded-Proto"); p == "https" || p == "http" {
		return p
	}
	if r.TLS != nil {
		return "https"
	}
	return "http"
}

// requestHost is the host (and port) the client asked for.
func requestHost(r *http.Request) string {
	if h := r.Header.Get("X-Forwarded-Host"); h != "" {
		return strings.TrimSpace(strings.Split(h, ",")[0])
	}
	return r.Host
}

// publicBase is how the client reached us, e.g. https://collections.hitorro.com:8443,
// so links handed back (pairing, sign-in) work from where it is.
func publicBase(r *http.Request, fallback string) string {
	if h := requestHost(r); h != "" {
		return requestScheme(r) + "://" + h
	}
	return fallback
}

func clientIP(r *http.Request) string {
	if f := r.Header.Get("X-Forwarded-For"); f != "" {
		return strings.TrimSpace(strings.Split(f, ",")[0])
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func (a *App) serverError(w http.ResponseWriter, r *http.Request, err error) {
	a.log.Error("internal error", "path", r.URL.Path, "err", err)
	writeError(w, http.StatusInternalServerError, "internal error: "+err.Error())
}
