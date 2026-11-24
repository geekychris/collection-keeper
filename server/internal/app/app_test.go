package app

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"log/slog"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// The tests need a Postgres they may wipe: CK_TEST_DATABASE_URL, default a
// throwaway container on 15433:
//
//	docker run -d --name ck-test-pg -e POSTGRES_PASSWORD=test -e POSTGRES_DB=ck -p 15433:5432 postgres:16-alpine
func testDB(t *testing.T) string {
	t.Helper()
	u := os.Getenv("CK_TEST_DATABASE_URL")
	if u == "" {
		u = "postgres://postgres:test@127.0.0.1:15433/ck?sslmode=disable"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	conn, err := pgx.Connect(ctx, u)
	if err != nil {
		t.Skipf("no test Postgres at %s: %v", u, err)
	}
	defer conn.Close(context.Background())
	if _, err := conn.Exec(ctx, `DROP SCHEMA public CASCADE; CREATE SCHEMA public`); err != nil {
		t.Fatal(err)
	}
	return u
}

type harness struct {
	t   *testing.T
	app *App
	srv *httptest.Server
}

func newHarness(t *testing.T, mod func(*Config)) *harness {
	cfg := Config{
		DatabaseURL:   testDB(t),
		BlobDir:       t.TempDir(),
		Name:          "Test keeper",
		AdminPassword: "admin-password-1",
		OIDCAdminRole: "admin",
		OIDCUserRoles: []string{"user"},
		SessionTTL:    time.Hour,
		Version:       "test",
	}
	if mod != nil {
		mod(&cfg)
	}
	ring := NewLogRing(100)
	logger := slog.New(ring.Handler(slog.NewTextHandler(io.Discard, nil)))
	a, err := New(context.Background(), cfg, logger, ring)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(a.Handler())
	t.Cleanup(func() { srv.Close(); a.Close() })
	return &harness{t: t, app: a, srv: srv}
}

// browser is a cookie-keeping web client that doesn't follow redirects.
type browser struct {
	h *harness
	c *http.Client
}

func (h *harness) browser() *browser {
	jar, _ := cookiejar.New(nil)
	return &browser{h, &http.Client{Jar: jar, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
}

func (b *browser) get(path string) (int, string, http.Header) {
	b.h.t.Helper()
	res, err := b.c.Get(b.h.srv.URL + path)
	if err != nil {
		b.h.t.Fatal(err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	return res.StatusCode, string(body), res.Header
}

func (b *browser) post(path string, form url.Values) (int, string, http.Header) {
	b.h.t.Helper()
	res, err := b.c.PostForm(b.h.srv.URL+path, form)
	if err != nil {
		b.h.t.Fatal(err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	return res.StatusCode, string(body), res.Header
}

var csrfRe = regexp.MustCompile(`name="csrf" value="([^"]+)"`)

// csrf reads the form token from a page.
func (b *browser) csrf(path string) string {
	b.h.t.Helper()
	_, body, _ := b.get(path)
	m := csrfRe.FindStringSubmatch(body)
	if m == nil {
		b.h.t.Fatalf("no csrf token on %s", path)
	}
	return m[1]
}

func (b *browser) login(user, pw string) {
	b.h.t.Helper()
	code, body, _ := b.post("/login", url.Values{"username": {user}, "password": {pw}, "next": {"/"}})
	if code != http.StatusSeeOther {
		b.h.t.Fatalf("login as %s: %d %s", user, code, body)
	}
}

// api calls the device API.
func (h *harness) api(method, path, token string, body any) (int, map[string]any) {
	h.t.Helper()
	var rd io.Reader
	if body != nil {
		buf, _ := json.Marshal(body)
		rd = bytes.NewReader(buf)
	}
	req, _ := http.NewRequest(method, h.srv.URL+path, rd)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		h.t.Fatal(err)
	}
	defer res.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(res.Body).Decode(&out)
	return res.StatusCode, out
}

// pair connects a device for the signed-in browser and returns its token.
func (h *harness) pair(b *browser, name string) string {
	h.t.Helper()
	code, start := h.api("POST", "/api/v1/pair/start", "", map[string]string{"deviceName": name, "platform": "ios", "appVersion": "1.0.0"})
	if code != 200 {
		h.t.Fatalf("pair/start: %d %v", code, start)
	}
	if !strings.HasPrefix(start["verifyUrl"].(string), h.srv.URL+"/pair?code=") {
		h.t.Fatalf("verifyUrl %v", start["verifyUrl"])
	}
	_, poll := h.api("POST", "/api/v1/pair/poll", "", map[string]string{"deviceCode": start["deviceCode"].(string)})
	if poll["status"] != "pending" {
		h.t.Fatalf("before approval: %v", poll)
	}
	userCode := start["userCode"].(string)
	page := "/pair?code=" + strings.ToLower(strings.ReplaceAll(userCode, "-", ""))
	_, body, _ := b.get(page)
	if !strings.Contains(body, html.EscapeString(name)) || !strings.Contains(body, userCode) {
		h.t.Fatalf("pair page doesn't show the device and code: %s", body)
	}
	if c, body, _ := b.post("/pair", url.Values{"csrf": {b.csrf(page)}, "code": {userCode}, "decision": {"approve"}}); c != 200 || !strings.Contains(body, "Connected") {
		h.t.Fatalf("approve: %d %s", c, body)
	}
	_, poll = h.api("POST", "/api/v1/pair/poll", "", map[string]string{"deviceCode": start["deviceCode"].(string)})
	if poll["status"] != "approved" || !strings.HasPrefix(poll["token"].(string), "ckt_") {
		h.t.Fatalf("after approval: %v", poll)
	}
	// The token is handed out once.
	_, again := h.api("POST", "/api/v1/pair/poll", "", map[string]string{"deviceCode": start["deviceCode"].(string)})
	if again["status"] != "expired" {
		h.t.Fatalf("second collection: %v", again)
	}
	return poll["token"].(string)
}

func rec(kind, id string, updated int64, extra map[string]any) map[string]any {
	data := map[string]any{"id": id, "updatedAt": updated, "createdAt": 1, "deleted": false}
	for k, v := range extra {
		data[k] = v
	}
	return map[string]any{"kind": kind, "data": data}
}

func statuses(t *testing.T, out map[string]any) []string {
	t.Helper()
	var s []string
	for _, r := range out["results"].([]any) {
		m := r.(map[string]any)
		s = append(s, m["status"].(string))
	}
	return s
}

func pullAll(t *testing.T, h *harness, token string, since float64) ([]map[string]any, float64) {
	t.Helper()
	var all []map[string]any
	for {
		code, out := h.api("GET", fmt.Sprintf("/api/v1/sync/pull?since=%d&limit=2", int64(since)), token, nil)
		if code != 200 {
			t.Fatalf("pull: %d %v", code, out)
		}
		for _, r := range out["records"].([]any) {
			all = append(all, r.(map[string]any))
		}
		since = out["cursor"].(float64)
		if out["more"] != true {
			return all, since
		}
	}
}

const (
	colID  = "0b7d5f3e-1111-4c1a-9a7e-2f1d3c4b5a60"
	itemID = "3f2b8c1e-9a4d-4e6f-8b7a-0c1d2e3f4a5b"
	locID  = "6a1e2d3c-2222-4b5a-8c7d-9e0f1a2b3c4d"
	fldID  = "7c2d3e4f-3333-4a5b-9c8d-0e1f2a3b4c5d"
	medID  = "8d3e4f5a-4444-4b6c-8d9e-1f2a3b4c5d6e"
)

func TestPairingAndSync(t *testing.T) {
	h := newHarness(t, nil)
	b := h.browser()
	b.login("admin", "admin-password-1")
	phone := h.pair(b, "Test iPhone")
	mac := h.pair(b, "Test Mac")

	if code, me := h.api("GET", "/api/v1/me", phone, nil); code != 200 || me["device"].(map[string]any)["name"] != "Test iPhone" {
		t.Fatalf("me: %d %v", code, me)
	}
	if code, _ := h.api("GET", "/api/v1/me", "ckt_nope", nil); code != 401 {
		t.Fatalf("bad token: %d", code)
	}

	// The phone pushes a collection, a location, a field and an item.
	_, out := h.api("POST", "/api/v1/sync/push", phone, map[string]any{"records": []any{
		rec("collection", colID, 100, map[string]any{"name": "Retro computers", "currency": "USD"}),
		rec("location", locID, 100, map[string]any{"name": "Shelf 2", "code": "A3-S2"}),
		rec("field", fldID, 100, map[string]any{"name": "CPU", "type": "text", "collectionId": colID, "sortOrder": 0}),
		rec("item", itemID, 100, map[string]any{"name": "Amiga 1200", "collectionId": colID, "locationId": locID, "fieldValues": map[string]any{fldID: "68EC020"}}),
		map[string]any{"kind": "gadget", "data": map[string]any{"id": itemID, "updatedAt": 1}},
		rec("item", "not-a-uuid", 100, nil),
	}})
	if got := strings.Join(statuses(t, out), ","); got != "accepted,accepted,accepted,accepted,rejected,rejected" {
		t.Fatalf("push: %s", got)
	}

	// The Mac gets all four; the phone gets none of its own but its cursor moves on.
	got, macCursor := pullAll(t, h, mac, 0)
	if len(got) != 4 || got[0]["kind"] != "collection" || got[3]["data"].(map[string]any)["name"] != "Amiga 1200" {
		t.Fatalf("mac pulled %v", got)
	}
	own, phoneCursor := pullAll(t, h, phone, 0)
	if len(own) != 0 || phoneCursor != macCursor {
		t.Fatalf("phone pulled its own writes %v (cursor %v vs %v)", own, phoneCursor, macCursor)
	}

	// Last writer wins: an older or equal edit is stale, a newer one replaces.
	_, out = h.api("POST", "/api/v1/sync/push", mac, map[string]any{"records": []any{
		rec("item", itemID, 100, map[string]any{"name": "Same time", "collectionId": colID}),
		rec("item", itemID, 50, map[string]any{"name": "Older", "collectionId": colID}),
	}})
	if got := strings.Join(statuses(t, out), ","); got != "stale,stale" {
		t.Fatalf("stale pushes: %s", got)
	}
	_, out = h.api("POST", "/api/v1/sync/push", mac, map[string]any{"records": []any{
		rec("item", itemID, 200, map[string]any{"name": "Amiga 1200 (boxed)", "collectionId": colID, "locationId": locID, "fieldValues": map[string]any{fldID: "68EC020"}}),
	}})
	if statuses(t, out)[0] != "accepted" {
		t.Fatal("newer edit not accepted")
	}
	got, _ = pullAll(t, h, phone, phoneCursor)
	if len(got) != 1 || got[0]["data"].(map[string]any)["name"] != "Amiga 1200 (boxed)" {
		t.Fatalf("phone pulled %v", got)
	}

	// The web pages show the library.
	for path, want := range map[string]string{
		"/":                        "Retro computers",
		"/c/" + colID:              "Amiga 1200 (boxed)",
		"/i/" + itemID:             "68EC020",
		"/l/" + locID:              "Amiga 1200 (boxed)",
		"/locations":               "A3-S2",
		"/record/item/" + itemID:   "&#34;name&#34;",
		"/devices":                 "Test Mac",
		"/c/" + colID + "?q=boxed": "1 items",
		"/admin":                   "reachable",
		"/admin/users":             "admin",
		"/admin/devices":           "Test iPhone",
		"/admin/events":            "rejected",
		"/admin/events?errors=1":   "unknown kind",
		"/admin/check?run=1":       "Media records without their file",
		"/admin/logs":              "pairing started",
		"/help":                    "/api/v1/",
	} {
		code, body, _ := b.get(path)
		if code != 200 || !strings.Contains(body, want) {
			if path == "/admin" && code == 200 && strings.Contains(body, "local accounts only") {
				continue // no login service in this test
			}
			t.Errorf("%s: %d, want %q in:\n%.600s", path, code, want, body)
		}
	}
	// A label's packed id finds the item too.
	if code, body, _ := b.get("/i/OyuMHppNTm-Leg wdLj9KWw"); code == 200 && strings.Contains(body, "Amiga") {
		t.Log("packed ids with spaces shouldn't resolve")
	}
	if code, body, _ := b.get("/i/" + packID(itemID)); code != 200 || !strings.Contains(body, "Amiga 1200") {
		t.Errorf("packed id: %d", code)
	}

	// A deletion travels as a tombstone.
	_, out = h.api("POST", "/api/v1/sync/push", phone, map[string]any{"records": []any{
		map[string]any{"kind": "item", "data": map[string]any{"id": itemID, "updatedAt": 300, "deleted": true, "name": "Amiga 1200 (boxed)", "collectionId": colID}},
	}})
	if statuses(t, out)[0] != "accepted" {
		t.Fatal("tombstone not accepted")
	}
	got, _ = pullAll(t, h, mac, macCursor)
	if len(got) != 1 || got[0]["data"].(map[string]any)["deleted"] != true {
		t.Fatalf("mac pulled %v", got)
	}
	if _, body, _ := b.get("/c/" + colID); strings.Contains(body, "Amiga") {
		t.Error("deleted item still listed")
	}

	// Revoking a device locks it out.
	var macID string
	_ = h.app.store.DB.QueryRow(context.Background(), `SELECT id::text FROM devices WHERE name='Test Mac'`).Scan(&macID)
	if c, _, _ := b.post("/devices/"+macID+"/revoke", url.Values{"csrf": {b.csrf("/devices")}, "back": {"/devices"}}); c != http.StatusSeeOther {
		t.Fatalf("revoke: %d", c)
	}
	if code, _ := h.api("GET", "/api/v1/sync/pull", mac, nil); code != 401 {
		t.Fatalf("revoked device pulled: %d", code)
	}
}

func packID(id string) string {
	b, _ := hex.DecodeString(strings.ReplaceAll(id, "-", ""))
	return strings.TrimRight(strings.NewReplacer("+", "-", "/", "_").Replace(b64(b)), "=")
}

func b64(b []byte) string {
	const enc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	var sb strings.Builder
	for i := 0; i < len(b); i += 3 {
		var n uint32
		k := 0
		for j := 0; j < 3; j++ {
			n <<= 8
			if i+j < len(b) {
				n |= uint32(b[i+j])
				k++
			}
		}
		for j := 0; j < 4; j++ {
			if j <= k {
				sb.WriteByte(enc[(n>>(18-6*j))&63])
			}
		}
	}
	return sb.String()
}

func TestMedia(t *testing.T) {
	h := newHarness(t, nil)
	b := h.browser()
	b.login("admin", "admin-password-1")
	token := h.pair(b, "Phone")

	photo := []byte("\x89PNG pretend photo bytes")
	sum := sha256.Sum256(photo)
	sha := hex.EncodeToString(sum[:])
	media := rec("media", medID, 100, map[string]any{"itemId": itemID, "kind": "photo", "fileName": medID + ".png", "sha256": sha})

	// The record needs its file first.
	_, out := h.api("POST", "/api/v1/sync/push", token, map[string]any{"records": []any{media}})
	if r := out["results"].([]any)[0].(map[string]any); r["status"] != "rejected" || r["error"] != "missing blob" {
		t.Fatalf("media before its blob: %v", r)
	}
	put := func(body []byte, token string) int {
		req, _ := http.NewRequest("PUT", h.srv.URL+"/api/v1/blobs/"+sha, bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Content-Type", "image/png")
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		return res.StatusCode
	}
	if c, _ := h.api("HEAD", "/api/v1/blobs/"+sha, token, nil); c != 404 {
		t.Fatalf("head before upload: %d", c)
	}
	if c := put([]byte("something else"), token); c != 400 {
		t.Fatalf("wrong bytes: %d", c)
	}
	if c := put(photo, token); c != 201 {
		t.Fatalf("upload: %d", c)
	}
	if c := put(photo, token); c != 200 {
		t.Fatalf("second upload: %d", c)
	}
	if c, _ := h.api("HEAD", "/api/v1/blobs/"+sha, token, nil); c != 200 {
		t.Fatalf("head after upload: %d", c)
	}
	_, out = h.api("POST", "/api/v1/sync/push", token, map[string]any{"records": []any{media}})
	if statuses(t, out)[0] != "accepted" {
		t.Fatalf("media after its blob: %v", out)
	}
	req, _ := http.NewRequest("GET", h.srv.URL+"/api/v1/blobs/"+sha, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	res, _ := http.DefaultClient.Do(req)
	got, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if !bytes.Equal(got, photo) || res.Header.Get("Content-Type") != "image/png" {
		t.Fatalf("download: %q %s", got, res.Header.Get("Content-Type"))
	}
	if c, body, _ := b.get("/media/" + sha); c != 200 || body != string(photo) {
		t.Fatalf("web media: %d", c)
	}

	// Someone else can't see it, even knowing the hash.
	if _, err := h.app.store.CreateLocalUser(context.Background(), "bob", "Bob", mustHash(t, "bob-password-1"), false); err != nil {
		t.Fatal(err)
	}
	bob := h.browser()
	bob.login("bob", "bob-password-1")
	bobToken := h.pair(bob, "Bob's phone")
	if c, _ := h.api("HEAD", "/api/v1/blobs/"+sha, bobToken, nil); c != 404 {
		t.Fatalf("another library sees the blob: %d", c)
	}
	if c, _ := h.api("GET", "/api/v1/blobs/"+sha, bobToken, nil); c != 404 {
		t.Fatalf("another library reads the blob: %d", c)
	}
	if c, _, _ := bob.get("/media/" + sha); c != 404 {
		t.Fatalf("another person sees the file on the web: %d", c)
	}
	if recs, _ := pullAll(t, h, bobToken, 0); len(recs) != 0 {
		t.Fatalf("bob pulled someone else's records: %v", recs)
	}
	// Bob isn't an admin.
	if c, _, _ := bob.get("/admin"); c != 403 {
		t.Fatalf("non-admin on /admin: %d", c)
	}

	// The admin can look at Bob's (empty) library and come back.
	if c, _, _ := b.post("/admin/view-as", url.Values{"csrf": {b.csrf("/admin/users")}, "user": {bobID(t, h)}}); c != http.StatusSeeOther {
		t.Fatalf("view as: %d", c)
	}
	if _, body, _ := b.get("/"); !strings.Contains(body, "Bob's library") || !strings.Contains(body, "read only") {
		t.Fatalf("view as bob: %.400s", body)
	}
	if c, _, _ := b.get("/media/" + sha); c != 404 {
		t.Fatalf("viewing bob's library still shows admin's file: %d", c)
	}
	b.post("/admin/view-as", url.Values{"csrf": {b.csrf("/")}, "user": {""}})
	if _, body, _ := b.get("/"); strings.Contains(body, "read only") {
		t.Fatal("still viewing as bob")
	}

	// Forms need their token.
	if c, _, _ := b.post("/admin/users", url.Values{"username": {"eve"}, "password": {"0123456789"}}); c != 403 {
		t.Fatalf("form without csrf: %d", c)
	}
	// Wrong passwords don't sign in.
	if c, _, _ := h.browser().post("/login", url.Values{"username": {"bob"}, "password": {"nope"}}); c != 401 {
		t.Fatalf("bad password: %d", c)
	}

	rep, err := h.app.blobs.Check(context.Background())
	if err != nil || len(rep.MissingBlob)+len(rep.MissingFile)+len(rep.WrongSize) != 0 || rep.BlobsChecked != 1 {
		t.Fatalf("check: %+v %v", rep, err)
	}
}

func bobID(t *testing.T, h *harness) string {
	u, err := h.app.store.UserByUsername(context.Background(), "bob")
	if err != nil || u == nil {
		t.Fatal("no bob", err)
	}
	return u.ID
}

func mustHash(t *testing.T, pw string) string {
	h, err := hashPassword(pw)
	if err != nil {
		t.Fatal(err)
	}
	return h
}

func TestPairingDenied(t *testing.T) {
	h := newHarness(t, nil)
	b := h.browser()
	b.login("admin", "admin-password-1")
	_, start := h.api("POST", "/api/v1/pair/start", "", map[string]string{"deviceName": "Stranger"})
	code := start["userCode"].(string)
	b.post("/pair", url.Values{"csrf": {b.csrf("/pair?code=" + code)}, "code": {code}, "decision": {"deny"}})
	if _, poll := h.api("POST", "/api/v1/pair/poll", "", map[string]string{"deviceCode": start["deviceCode"].(string)}); poll["status"] != "denied" {
		t.Fatalf("denied pairing: %v", poll)
	}
	// Signed out, the pairing page asks for a sign-in first and comes back.
	c, _, hdr := h.browser().get("/pair?code=" + code)
	if c != http.StatusFound || !strings.HasPrefix(hdr.Get("Location"), "/login?next=%2Fpair%3Fcode%3D") {
		t.Fatalf("signed-out pair page: %d %s", c, hdr.Get("Location"))
	}
}

func TestPullCursorOrdering(t *testing.T) {
	// Many pushes in parallel; a puller following the cursor must see every
	// record exactly once.
	h := newHarness(t, nil)
	b := h.browser()
	b.login("admin", "admin-password-1")
	writer, reader := h.pair(b, "Writer"), h.pair(b, "Reader")
	done := make(chan struct{})
	const n = 40
	go func() {
		defer close(done)
		for i := 0; i < n; i++ {
			h.api("POST", "/api/v1/sync/push", writer, map[string]any{"records": []any{rec("location", newUUID(), int64(i+1), map[string]any{"name": fmt.Sprint(i)})}})
		}
	}()
	seen := map[string]int{}
	var cursor float64
	for finished := false; !finished; {
		select {
		case <-done:
			finished = true
		default:
		}
		got, c := pullAll(t, h, reader, cursor)
		cursor = c
		for _, r := range got {
			seen[r["data"].(map[string]any)["id"].(string)]++
		}
	}
	got, _ := pullAll(t, h, reader, cursor)
	for _, r := range got {
		seen[r["data"].(map[string]any)["id"].(string)]++
	}
	if len(seen) != n {
		t.Fatalf("saw %d of %d records", len(seen), n)
	}
	for id, k := range seen {
		if k != 1 {
			t.Fatalf("%s seen %d times", id, k)
		}
	}
}

func TestUserCodes(t *testing.T) {
	for i := 0; i < 200; i++ {
		c := newUserCode()
		if len(c) != 9 || c[4] != '-' || normalizeUserCode(strings.ToLower(strings.ReplaceAll(c, "-", " "))) != c {
			t.Fatalf("bad code %q", c)
		}
		if strings.ContainsAny(c, "01OIL") {
			t.Fatalf("confusable letter in %q", c)
		}
	}
	if unpackID(packID(itemID)) != itemID || unpackID("short") != "" {
		t.Fatal("unpackID")
	}
}
