package app

import (
	"bytes"
	"embed"
	"errors"
	"fmt"
	"html/template"
	"io/fs"
	"math"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

//go:embed web/templates/*.html
var templateFiles embed.FS

//go:embed web/static
var staticFS embed.FS

func staticFiles() http.Handler {
	sub, _ := fs.Sub(staticFS, "web/static")
	return http.FileServer(http.FS(sub))
}

type pages struct {
	t map[string]*template.Template
}

var funcs = template.FuncMap{
	"ago":  ago,
	"when": func(t time.Time) string { return t.Local().Format("2 Jan 2006 15:04") },
	"whenp": func(t *time.Time) string {
		if t == nil {
			return "never"
		}
		return ago(*t)
	},
	"ms": func(ms int64) time.Time { return time.UnixMilli(ms) },
	"msp": func(v any) string {
		f, ok := v.(float64)
		if !ok || f == 0 {
			return ""
		}
		return time.UnixMilli(int64(f)).Local().Format("2 Jan 2006")
	},
	"bytes": func(n any) string { return humanBytes(toInt64(n)) },
	"lower": strings.ToLower,
	"title": func(s string) string {
		if s == "" {
			return s
		}
		return strings.ToUpper(s[:1]) + s[1:]
	},
	"pct": func(a, b uint64) int {
		if b == 0 {
			return 0
		}
		return int(100 * (b - a) / b)
	},
	"add": func(a, b int) int { return a + b },
	"short": func(s string) string {
		if len(s) > 8 {
			return s[:8]
		}
		return s
	},
	"query":   url.QueryEscape,
	"isImage": func(m Row) bool { return m.Str("kind") == "photo" },
	"isVideo": func(m Row) bool { return m.Str("kind") == "video" },
	// dict2 bundles a device list for the "devicetable" partial.
	"dict2": func(devices []Device, s *Session, back string) map[string]any {
		return map[string]any{"Devices": devices, "S": s, "Back": back}
	},
	"dict3": func(devices []Device, s *Session, back string, owners map[string]string) map[string]any {
		return map[string]any{"Devices": devices, "S": s, "Back": back, "Owners": owners}
	},
}

func loadPages() (*pages, error) {
	p := &pages{t: map[string]*template.Template{}}
	layout, err := templateFiles.ReadFile("web/templates/layout.html")
	if err != nil {
		return nil, err
	}
	partials, err := templateFiles.ReadFile("web/templates/partials.html")
	if err != nil {
		return nil, err
	}
	entries, _ := templateFiles.ReadDir("web/templates")
	for _, e := range entries {
		name := strings.TrimSuffix(e.Name(), ".html")
		if name == "layout" || name == "partials" {
			continue
		}
		body, _ := templateFiles.ReadFile("web/templates/" + e.Name())
		t, err := template.New("layout").Funcs(funcs).Parse(string(layout))
		if err == nil {
			_, err = t.Parse(string(partials))
		}
		if err == nil {
			_, err = t.Parse(string(body))
		}
		if err != nil {
			return nil, fmt.Errorf("template %s: %w", name, err)
		}
		p.t[name] = t
	}
	return p, nil
}

// view is what every page template gets.
type view struct {
	Title   string
	Server  string
	Version string
	S       *Session
	Nav     string
	Flash   string
	Error   string
	Data    any
}

func (a *App) render(w http.ResponseWriter, r *http.Request, s *Session, status int, name, title string, data any) {
	t, ok := a.pages.t[name]
	if !ok {
		http.Error(w, "no page "+name, http.StatusInternalServerError)
		return
	}
	v := view{Title: title, Server: a.cfg.Name, Version: a.cfg.Version, S: s, Nav: strings.SplitN(name, "_", 2)[0], Data: data,
		Flash: r.URL.Query().Get("flash"), Error: r.URL.Query().Get("err")}
	var buf bytes.Buffer
	if err := t.ExecuteTemplate(&buf, "layout", v); err != nil {
		a.log.Error("rendering a page", "page", name, "err", err)
		http.Error(w, "couldn't show this page: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_, _ = buf.WriteTo(w)
}

func (a *App) errorPage(w http.ResponseWriter, r *http.Request, s *Session, status int, msg string) {
	a.render(w, r, s, status, "error", http.StatusText(status), msg)
}

type pageFunc func(w http.ResponseWriter, r *http.Request, s *Session)

// web requires a signed-in browser (sending others to the login page) and
// a matching CSRF token on forms.
func (a *App) web(h pageFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		s, err := a.session(r)
		if err != nil {
			a.log.Error("reading the session", "err", err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		if s == nil {
			if r.Method != http.MethodGet {
				http.Error(w, "signed out", http.StatusUnauthorized)
				return
			}
			http.Redirect(w, r, "/login?next="+url.QueryEscape(r.URL.RequestURI()), http.StatusFound)
			return
		}
		if r.Method == http.MethodPost && !checkCSRF(r, s) {
			a.errorPage(w, r, s, http.StatusForbidden, "This form has expired. Go back, reload the page and try again.")
			return
		}
		h(w, r, s)
	}
}

func (a *App) admin(h pageFunc) http.HandlerFunc {
	return a.web(func(w http.ResponseWriter, r *http.Request, s *Session) {
		if !s.User.Admin {
			a.errorPage(w, r, s, http.StatusForbidden, "Only administrators can see this page.")
			return
		}
		h(w, r, s)
	})
}

func redirectFlash(w http.ResponseWriter, r *http.Request, to, flash string) {
	sep := "?"
	if strings.Contains(to, "?") {
		sep = "&"
	}
	http.Redirect(w, r, to+sep+"flash="+url.QueryEscape(flash), http.StatusSeeOther)
}

// safeNext keeps a post-login redirect on this site.
func safeNext(next string) string {
	if next == "" || !strings.HasPrefix(next, "/") || strings.HasPrefix(next, "//") || strings.HasPrefix(next, "/\\") {
		return "/"
	}
	return next
}

// ---- signing in ----

func (a *App) loginPage(w http.ResponseWriter, r *http.Request) {
	if s, _ := a.session(r); s != nil {
		http.Redirect(w, r, safeNext(r.URL.Query().Get("next")), http.StatusFound)
		return
	}
	a.render(w, r, nil, http.StatusOK, "login", "Sign in", map[string]any{
		"Next": safeNext(r.URL.Query().Get("next")), "OIDC": a.oidc != nil, "Local": true,
	})
}

func (a *App) loginPassword(w http.ResponseWriter, r *http.Request) {
	next := safeNext(r.PostFormValue("next"))
	u, err := a.checkPassword(r.Context(), r.PostFormValue("username"), r.PostFormValue("password"))
	if err != nil {
		a.log.Error("checking a password", "err", err)
	}
	if u == nil {
		a.log.Warn("password sign-in refused", "username", clip(r.PostFormValue("username"), 60), "ip", clientIP(r))
		time.Sleep(500 * time.Millisecond)
		a.render(w, r, nil, http.StatusUnauthorized, "login", "Sign in", map[string]any{
			"Next": next, "OIDC": a.oidc != nil, "Local": true, "Failed": true,
		})
		return
	}
	if err := a.newSession(r.Context(), w, r, u); err != nil {
		a.errorPage(w, r, nil, http.StatusInternalServerError, err.Error())
		return
	}
	a.log.Info("signed in with a password", "user", u.Username)
	http.Redirect(w, r, next, http.StatusSeeOther)
}

func (a *App) loginOIDC(w http.ResponseWriter, r *http.Request) {
	if a.oidc == nil {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}
	if err := a.oidc.start(w, r, safeNext(r.URL.Query().Get("next"))); err != nil {
		a.log.Error("starting an OIDC sign-in", "err", err)
		a.errorPage(w, r, nil, http.StatusBadGateway, "The login service isn't reachable right now ("+err.Error()+"). An administrator can still sign in with a password.")
	}
}

func (a *App) oidcCallback(w http.ResponseWriter, r *http.Request) {
	if a.oidc == nil {
		http.NotFound(w, r)
		return
	}
	id, next, err := a.oidc.finish(r)
	if errors.Is(err, errNoRole) {
		a.log.Warn("signed in without a role for this app", "user", id.Username, "roles", strings.Join(id.Roles, ","))
		a.errorPage(w, r, nil, http.StatusForbidden, fmt.Sprintf("You (%s) are signed in, but haven't been given access to this app. Ask the site's administrator for the %q role.", id.Username, a.cfg.OIDCUserRoles[0]))
		return
	}
	if err != nil {
		a.log.Warn("OIDC sign-in failed", "err", err)
		a.errorPage(w, r, nil, http.StatusBadRequest, "Signing in failed: "+err.Error())
		return
	}
	u, err := a.store.UpsertOIDCUser(r.Context(), id.Sub, id.Username, id.Name, id.Email, containsStr(id.Roles, a.cfg.OIDCAdminRole))
	if err == nil && u.Disabled {
		a.errorPage(w, r, nil, http.StatusForbidden, "Your account on this server is disabled.")
		return
	}
	if err == nil {
		err = a.newSession(r.Context(), w, r, u)
	}
	if err != nil {
		a.errorPage(w, r, nil, http.StatusInternalServerError, err.Error())
		return
	}
	a.log.Info("signed in", "user", u.Username, "admin", u.Admin)
	http.Redirect(w, r, next, http.StatusSeeOther)
}

func (a *App) logout(w http.ResponseWriter, r *http.Request) {
	s, _ := a.session(r)
	if s != nil && !checkCSRF(r, s) {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	a.endSession(w, r, s)
	http.Redirect(w, r, "/login?flash="+url.QueryEscape("Signed out."), http.StatusSeeOther)
}

// ---- the library ----

// library is one person's records, indexed for the pages.
type library struct {
	Collections []Row
	Locations   map[string]*Row
}

func (a *App) loadLocations(r *http.Request, owner string) (map[string]*Row, error) {
	rows, err := a.store.Live(r.Context(), owner, "location")
	if err != nil {
		return nil, err
	}
	m := make(map[string]*Row, len(rows))
	for i := range rows {
		m[rows[i].ID] = &rows[i]
	}
	return m, nil
}

// locationPath is "Warehouse › Aisle 3 › Shelf 2".
func locationPath(locs map[string]*Row, id string) string {
	var parts []string
	for seen := 0; id != "" && seen < 20; seen++ {
		l := locs[id]
		if l == nil {
			break
		}
		parts = append([]string{l.Str("name")}, parts...)
		id = l.Str("parentId")
	}
	return strings.Join(parts, " › ")
}

func (a *App) homePage(w http.ResponseWriter, r *http.Request, s *Session) {
	ctx, owner := r.Context(), s.Owner().ID
	cols, err := a.store.Live(ctx, owner, "collection")
	if err != nil {
		a.errorPage(w, r, s, 500, err.Error())
		return
	}
	counts, _ := a.store.ItemCounts(ctx, owner)
	kinds, _ := a.store.Counts(ctx, owner)
	recent, _ := a.store.Recent(ctx, owner, 15)
	devices, _ := a.store.Devices(ctx, owner)
	live := 0
	for _, d := range devices {
		if d.RevokedAt == nil {
			live++
		}
	}
	var mediaBytes int64
	_ = a.store.DB.QueryRow(ctx, `SELECT coalesce(sum(b.size),0) FROM blob_owners o JOIN blobs b USING (sha256) WHERE o.owner_id=$1`, owner).Scan(&mediaBytes)
	a.render(w, r, s, 200, "home", "Library", map[string]any{
		"Collections": cols, "ItemCounts": counts, "Kinds": kinds, "Recent": recent, "Devices": live, "MediaBytes": mediaBytes,
	})
}

func (a *App) collectionPage(w http.ResponseWriter, r *http.Request, s *Session) {
	ctx, owner := r.Context(), s.Owner().ID
	c, err := a.store.One(ctx, owner, "collection", r.PathValue("id"))
	if err != nil || c == nil {
		a.errorPage(w, r, s, http.StatusNotFound, "There's no such collection in this library.")
		return
	}
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	items, err := a.store.Items(ctx, owner, c.ID, q)
	if err != nil {
		a.errorPage(w, r, s, 500, err.Error())
		return
	}
	fields := a.fields(r, owner, c.ID)
	locs, _ := a.loadLocations(r, owner)
	shown := fields
	if len(shown) > 4 {
		shown = shown[:4]
	}
	type line struct {
		Item     Row
		Location string
		Values   []string
		Thumb    string
	}
	covers := a.coverThumbs(r, owner, items)
	lines := make([]line, len(items))
	for i, it := range items {
		vals := it.fieldValues()
		l := line{Item: it, Location: locationPath(locs, it.Str("locationId")), Thumb: covers[it.ID]}
		for _, f := range shown {
			l.Values = append(l.Values, formatValue(f, vals[f.ID], c.Str("currency")))
		}
		lines[i] = l
	}
	a.render(w, r, s, 200, "collection", c.Str("name"), map[string]any{"C": c, "Fields": shown, "Lines": lines, "Q": q, "Deleted": c.Deleted})
}

// coverThumbs maps item id → the sha256 of its cover photo (or first photo).
func (a *App) coverThumbs(r *http.Request, owner string, items []Row) map[string]string {
	media, err := a.store.rows(r.Context(), `r.owner_id=$1 AND r.kind='media' AND NOT r.deleted AND r.data->>'kind'='photo' ORDER BY (r.data->>'sortOrder')::numeric NULLS LAST`, owner)
	out := map[string]string{}
	if err != nil {
		return out
	}
	want := map[string]string{}
	for _, it := range items {
		want[it.ID] = it.Str("coverMediaId")
	}
	for _, m := range media {
		item := m.Str("itemId")
		cover, ok := want[item]
		if !ok {
			continue
		}
		if m.ID == cover || out[item] == "" {
			out[item] = m.Str("sha256")
		}
	}
	return out
}

type fieldDef struct {
	ID, Name, Type string
}

func (a *App) fields(r *http.Request, owner, collectionID string) []fieldDef {
	rows, _ := a.store.Where(r.Context(), owner, "field", "collectionId", collectionID)
	sort.SliceStable(rows, func(i, j int) bool { return toFloat(rows[i].Data["sortOrder"]) < toFloat(rows[j].Data["sortOrder"]) })
	out := make([]fieldDef, len(rows))
	for i, f := range rows {
		out[i] = fieldDef{ID: f.ID, Name: f.Str("name"), Type: f.Str("type")}
	}
	return out
}

// fieldValues reads an item's values: an object, or (from older apps) a
// JSON string holding one.
func (r *Row) fieldValues() map[string]any {
	switch v := r.Data["fieldValues"].(type) {
	case map[string]any:
		return v
	case string:
		var m map[string]any
		_ = jsonUnmarshalString(v, &m)
		return m
	}
	return nil
}

func formatValue(f fieldDef, v any, currency string) string {
	if v == nil {
		return ""
	}
	switch f.Type {
	case "boolean":
		if b, ok := v.(bool); ok {
			if b {
				return "Yes"
			}
			return "No"
		}
	case "currency":
		if n, ok := v.(float64); ok {
			return fmt.Sprintf("%s %.2f", currency, n)
		}
	case "number":
		if n, ok := v.(float64); ok {
			if n == math.Trunc(n) {
				return strconv.FormatInt(int64(n), 10)
			}
			return strconv.FormatFloat(n, 'f', -1, 64)
		}
	}
	return fmt.Sprint(v)
}

func (a *App) itemPage(w http.ResponseWriter, r *http.Request, s *Session) {
	ctx, owner := r.Context(), s.Owner().ID
	it, err := a.store.One(ctx, owner, "item", unpackID(r.PathValue("id")))
	if err != nil || it == nil {
		a.errorPage(w, r, s, http.StatusNotFound, "There's no such item in this library.")
		return
	}
	c, _ := a.store.One(ctx, owner, "collection", it.Str("collectionId"))
	locs, _ := a.loadLocations(r, owner)
	vals := it.fieldValues()
	currency := ""
	if c != nil {
		currency = c.Str("currency")
	}
	type fv struct{ Name, Value, Type string }
	var values []fv
	for _, f := range a.fields(r, owner, it.Str("collectionId")) {
		if v := formatValue(f, vals[f.ID], currency); v != "" {
			values = append(values, fv{f.Name, v, f.Type})
		}
	}
	media, _ := a.store.Where(ctx, owner, "media", "itemId", it.ID)
	sort.SliceStable(media, func(i, j int) bool { return toFloat(media[i].Data["sortOrder"]) < toFloat(media[j].Data["sortOrder"]) })
	a.render(w, r, s, 200, "item", it.Str("name"), map[string]any{
		"I": it, "C": c, "Values": values, "Media": media, "Location": locationPath(locs, it.Str("locationId")), "LocationID": it.Str("locationId"),
	})
}

func (a *App) locationPage(w http.ResponseWriter, r *http.Request, s *Session) {
	ctx, owner := r.Context(), s.Owner().ID
	locs, _ := a.loadLocations(r, owner)
	l := locs[unpackID(r.PathValue("id"))]
	if l == nil {
		a.errorPage(w, r, s, http.StatusNotFound, "There's no such location in this library.")
		return
	}
	var children []*Row
	for _, x := range locs {
		if x.Str("parentId") == l.ID {
			children = append(children, x)
		}
	}
	sort.Slice(children, func(i, j int) bool {
		return strings.ToLower(children[i].Str("name")) < strings.ToLower(children[j].Str("name"))
	})
	items, _ := a.store.Where(ctx, owner, "item", "locationId", l.ID)
	cols, _ := a.store.Live(ctx, owner, "collection")
	colNames := map[string]string{}
	for _, c := range cols {
		colNames[c.ID] = c.Str("name")
	}
	a.render(w, r, s, 200, "location", l.Str("name"), map[string]any{
		"L": l, "Path": locationPath(locs, l.Str("parentId")), "Children": children, "Items": items, "Collections": colNames,
	})
}

func (a *App) locationsPage(w http.ResponseWriter, r *http.Request, s *Session) {
	locs, err := a.loadLocations(r, s.Owner().ID)
	if err != nil {
		a.errorPage(w, r, s, 500, err.Error())
		return
	}
	type node struct {
		Row   *Row
		Depth int
	}
	children := map[string][]*Row{}
	for _, l := range locs {
		p := l.Str("parentId")
		if locs[p] == nil {
			p = ""
		}
		children[p] = append(children[p], l)
	}
	var out []node
	var walk func(parent string, depth int)
	walk = func(parent string, depth int) {
		kids := children[parent]
		sort.Slice(kids, func(i, j int) bool {
			return strings.ToLower(kids[i].Str("name")) < strings.ToLower(kids[j].Str("name"))
		})
		for _, k := range kids {
			out = append(out, node{k, depth})
			if depth < 20 {
				walk(k.ID, depth+1)
			}
		}
	}
	walk("", 0)
	a.render(w, r, s, 200, "locations", "Locations", out)
}

// recordPage shows a record as stored, for diagnostics.
func (a *App) recordPage(w http.ResponseWriter, r *http.Request, s *Session) {
	kind := r.PathValue("kind")
	if !validKind(kind) {
		a.errorPage(w, r, s, http.StatusNotFound, "No such kind of record.")
		return
	}
	row, err := a.store.One(r.Context(), s.Owner().ID, kind, r.PathValue("id"))
	if err != nil || row == nil {
		a.errorPage(w, r, s, http.StatusNotFound, "There's no such record in this library.")
		return
	}
	var pretty bytes.Buffer
	_ = jsonIndent(&pretty, row.Raw)
	a.render(w, r, s, 200, "record", kind+" "+row.ID, map[string]any{"R": row, "JSON": pretty.String()})
}

func (a *App) mediaFile(w http.ResponseWriter, r *http.Request, s *Session) {
	sha := strings.ToLower(r.PathValue("sha"))
	if !sha256Re.MatchString(sha) {
		http.NotFound(w, r)
		return
	}
	has, err := a.blobs.Has(r.Context(), s.Owner().ID, sha)
	if err != nil || !has {
		http.NotFound(w, r)
		return
	}
	if r.URL.Query().Get("thumb") != "" {
		if p, err := a.blobs.Thumbnail(r.Context(), sha); err == nil {
			w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
			http.ServeFile(w, r, p)
			return
		}
	}
	a.serveBlob(w, r, sha)
}

// ---- devices and pairing ----

func (a *App) devicesPage(w http.ResponseWriter, r *http.Request, s *Session) {
	owner := s.Owner().ID
	devices, err := a.store.Devices(r.Context(), owner)
	if err != nil {
		a.errorPage(w, r, s, 500, err.Error())
		return
	}
	events, _ := a.store.Events(r.Context(), EventFilter{UserID: owner, Limit: 50})
	a.render(w, r, s, 200, "devices", "Devices", map[string]any{"Devices": devices, "Events": events})
}

func (a *App) revokeDevice(w http.ResponseWriter, r *http.Request, s *Session) {
	d, err := a.store.DeviceByID(r.Context(), r.PathValue("id"))
	if err != nil || d == nil || (d.UserID != s.User.ID && !s.User.Admin) {
		a.errorPage(w, r, s, http.StatusNotFound, "No such device.")
		return
	}
	if err := a.store.RevokeDevice(r.Context(), d.ID); err != nil {
		a.errorPage(w, r, s, 500, err.Error())
		return
	}
	a.log.Info("device disconnected", "device", d.Name, "by", s.User.Username)
	back := r.PostFormValue("back")
	redirectFlash(w, r, safeNext(back), d.Name+" is disconnected. It keeps its own copy, but can't sync until it's paired again.")
}

func (a *App) pairPage(w http.ResponseWriter, r *http.Request, s *Session) {
	raw := r.URL.Query().Get("code")
	code := normalizeUserCode(raw)
	var p *Pairing
	if code != "" {
		p, _ = a.store.PairingByUserCode(r.Context(), code)
	}
	a.render(w, r, s, 200, "pair", "Connect a device", map[string]any{"Code": code, "Raw": raw, "P": p})
}

func (a *App) pairDecide(w http.ResponseWriter, r *http.Request, s *Session) {
	code := normalizeUserCode(r.PostFormValue("code"))
	approve := r.PostFormValue("decision") == "approve"
	ok, err := a.store.DecidePairing(r.Context(), code, s.User.ID, approve)
	if err != nil {
		a.errorPage(w, r, s, 500, err.Error())
		return
	}
	if !ok {
		a.errorPage(w, r, s, http.StatusGone, "That code has expired or was already used. Start connecting again in the app.")
		return
	}
	a.log.Info("pairing decided", "user", s.User.Username, "approved", approve)
	a.render(w, r, s, 200, "paired", "Connect a device", map[string]any{"Approved": approve})
}

func (a *App) helpPage(w http.ResponseWriter, r *http.Request, s *Session) {
	a.render(w, r, s, 200, "help", "Connecting the app", map[string]any{"Base": publicBase(r, a.cfg.PublicURL)})
}

// ---- small helpers ----

func ago(t time.Time) string {
	d := time.Since(t)
	switch {
	case d < 0:
		return t.Local().Format("2 Jan 2006 15:04")
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return plural(int(d.Minutes()), "minute") + " ago"
	case d < 24*time.Hour:
		return plural(int(d.Hours()), "hour") + " ago"
	case d < 7*24*time.Hour:
		return plural(int(d.Hours()/24), "day") + " ago"
	}
	return t.Local().Format("2 Jan 2006")
}

func plural(n int, unit string) string {
	if n == 1 {
		return "1 " + unit
	}
	return fmt.Sprintf("%d %ss", n, unit)
}

func toInt64(v any) int64 {
	switch n := v.(type) {
	case int:
		return int64(n)
	case int64:
		return n
	case uint64:
		return int64(n)
	case float64:
		return int64(n)
	}
	return 0
}

func toFloat(v any) float64 {
	if f, ok := v.(float64); ok {
		return f
	}
	return 0
}

func containsStr(xs []string, s string) bool {
	for _, x := range xs {
		if x == s {
			return true
		}
	}
	return false
}
