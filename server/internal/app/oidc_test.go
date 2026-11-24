package app

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"html"
	"net/http"
	"net/http/httptest"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/go-jose/go-jose/v4"
)

// fakeProvider is a small OpenID Connect provider shaped like the lab's
// (docs/ACCESS.md in cloud-stack): issuer https://auth.example.test, reached
// by the server on a back channel (this httptest server), PKCE S256 required,
// roles in the ID token.
type fakeProvider struct {
	t      *testing.T
	srv    *httptest.Server
	key    *rsa.PrivateKey
	issuer string
	secret string

	mu    sync.Mutex
	codes map[string]fakeGrant
	roles []string
	sub   string
}

type fakeGrant struct {
	challenge, nonce, redirect string
}

func newFakeProvider(t *testing.T) *fakeProvider {
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	p := &fakeProvider{t: t, key: key, issuer: "https://auth.example.test", secret: "s3cret", codes: map[string]fakeGrant{}, roles: []string{"admin"}, sub: "pau_chris"}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /.well-known/openid-configuration", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{
			"issuer":                                p.issuer,
			"authorization_endpoint":                p.issuer + "/oidc/authorize",
			"token_endpoint":                        p.issuer + "/oidc/token",
			"jwks_uri":                              p.issuer + "/oidc/keys",
			"userinfo_endpoint":                     p.issuer + "/oidc/userinfo",
			"id_token_signing_alg_values_supported": []string{"RS256"},
		})
	})
	mux.HandleFunc("GET /oidc/keys", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, jose.JSONWebKeySet{Keys: []jose.JSONWebKey{{Key: &key.PublicKey, KeyID: "k1", Algorithm: "RS256", Use: "sig"}}})
	})
	mux.HandleFunc("POST /oidc/token", p.token)
	p.srv = httptest.NewServer(mux)
	t.Cleanup(p.srv.Close)
	return p
}

// authorize plays the provider's authorization step: checks the request
// and returns where it would send the browser back to.
func (p *fakeProvider) authorize(authURL string) string {
	p.t.Helper()
	u, err := url.Parse(authURL)
	if err != nil {
		p.t.Fatal(err)
	}
	q := u.Query()
	if q.Get("code_challenge_method") != "S256" || q.Get("code_challenge") == "" || q.Get("client_id") != "collection-keeper" || q.Get("nonce") == "" {
		p.t.Fatalf("authorize request missing PKCE, client or nonce: %s", authURL)
	}
	code := randomToken(16)
	p.mu.Lock()
	p.codes[code] = fakeGrant{q.Get("code_challenge"), q.Get("nonce"), q.Get("redirect_uri")}
	p.mu.Unlock()
	return q.Get("redirect_uri") + "?code=" + code + "&state=" + url.QueryEscape(q.Get("state"))
}

func (p *fakeProvider) token(w http.ResponseWriter, r *http.Request) {
	id, secret, ok := r.BasicAuth()
	if !ok || id != "collection-keeper" || secret != p.secret {
		writeJSON(w, 401, map[string]string{"error": "invalid_client"})
		return
	}
	_ = r.ParseForm()
	p.mu.Lock()
	g, ok := p.codes[r.PostForm.Get("code")]
	delete(p.codes, r.PostForm.Get("code"))
	p.mu.Unlock()
	sum := sha256.Sum256([]byte(r.PostForm.Get("code_verifier")))
	if !ok || base64.RawURLEncoding.EncodeToString(sum[:]) != g.challenge || r.PostForm.Get("redirect_uri") != g.redirect {
		writeJSON(w, 400, map[string]string{"error": "invalid_grant"})
		return
	}
	signer, _ := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: jose.JSONWebKey{Key: p.key, KeyID: "k1"}}, nil)
	claims, _ := json.Marshal(map[string]any{
		"iss": p.issuer, "aud": "collection-keeper", "sub": p.sub, "nonce": g.nonce,
		"exp": time.Now().Add(5 * time.Minute).Unix(), "iat": time.Now().Unix(),
		"preferred_username": "chris", "name": "Chris Collins", "email": "chris@example.test", "roles": p.roles,
	})
	jws, _ := signer.Sign(claims)
	idToken, _ := jws.CompactSerialize()
	writeJSON(w, 200, map[string]any{"access_token": "opaque", "token_type": "Bearer", "expires_in": 600, "id_token": idToken})
}

func TestOIDCSignIn(t *testing.T) {
	p := newFakeProvider(t)
	h := newHarness(t, func(c *Config) {
		c.OIDCIssuer = p.issuer
		c.OIDCBackchannel = p.srv.URL
		c.OIDCClientID = "collection-keeper"
		c.OIDCClientSecret = p.secret
	})

	// signIn walks a browser through the provider, arriving as the lab's
	// proxy forwards it (the LAN name on :8443).
	signIn := func() (*browser, int, string) {
		b := h.browser()
		// As a real browser does: a signed-in page (here the app's pairing
		// link) sends us to /login, whose button starts the sign-in.
		_, _, hdr := b.get("/pair?code=ABCD-EFGH")
		_, page, _ := b.get(hdr.Get("Location"))
		m := regexp.MustCompile(`href="(/login/oidc[^"]*)"`).FindStringSubmatch(page)
		if m == nil {
			t.Fatalf("no sign-in button on the login page: %.400s", page)
		}
		req, _ := http.NewRequest("GET", h.srv.URL+html.UnescapeString(m[1]), nil)
		req.Header.Set("X-Forwarded-Host", "collections.example.test:8443")
		req.Header.Set("X-Forwarded-Proto", "https")
		res, err := b.c.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		loc := res.Header.Get("Location")
		// The browser goes to the issuer on the port it reached us on, and
		// comes back to the registered redirect URI on that port.
		if !strings.HasPrefix(loc, "https://auth.example.test:8443/oidc/authorize?") ||
			!strings.Contains(loc, url.QueryEscape("https://collections.example.test:8443/login/oauth2/code/cloudstack")) {
			t.Fatalf("authorize redirect: %s", loc)
		}
		back := p.authorize(loc)
		u, _ := url.Parse(back)
		req, _ = http.NewRequest("GET", h.srv.URL+u.Path+"?"+u.RawQuery, nil)
		req.Header.Set("X-Forwarded-Host", "collections.example.test:8443")
		req.Header.Set("X-Forwarded-Proto", "https")
		res, err = b.c.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		var body strings.Builder
		buf := make([]byte, 4096)
		for {
			n, err := res.Body.Read(buf)
			body.Write(buf[:n])
			if err != nil {
				break
			}
		}
		// The cookie was set for the forwarded https name; give it to the
		// test server's own URL too.
		for _, c := range res.Cookies() {
			c.Secure = false
			u, _ := url.Parse(h.srv.URL)
			b.c.Jar.SetCookies(u, []*http.Cookie{c})
		}
		return b, res.StatusCode, res.Header.Get("Location") + body.String()
	}

	b, code, where := signIn()
	if code != http.StatusSeeOther || !strings.HasPrefix(where, "/pair?code=ABCD-EFGH<") {
		t.Fatalf("callback: %d %s", code, where)
	}
	if c, body, _ := b.get("/admin"); c != 200 || !strings.Contains(body, "reachable") || !strings.Contains(body, "Chris Collins") {
		t.Fatalf("admin page after OIDC sign-in: %d %.300s", c, body)
	}
	u, _ := h.app.store.UserByUsername(t.Context(), "chris")
	if u == nil || !u.Admin || u.OIDCSub == nil || *u.OIDCSub != "pau_chris" || u.Email != "chris@example.test" {
		t.Fatalf("user after sign-in: %+v", u)
	}

	// The same person signing in again keeps their account; losing the
	// admin role takes admin away.
	p.roles = []string{"user"}
	b, _, _ = signIn()
	if c, _, _ := b.get("/admin"); c != 403 {
		t.Fatalf("admin page without the role: %d", c)
	}
	var n int
	_ = h.app.store.DB.QueryRow(t.Context(), `SELECT count(*) FROM users WHERE oidc_sub='pau_chris'`).Scan(&n)
	if n != 1 {
		t.Fatalf("%d accounts for one person", n)
	}

	// No role for this app: refused.
	p.roles = []string{"labeler"}
	p.sub = "pau_other"
	_, code, body := signIn()
	if code != http.StatusForbidden || !strings.Contains(body, "access") {
		t.Fatalf("no role: %d %.200s", code, body)
	}

	// A replayed callback is refused.
	if c, _, _ := h.browser().get(oidcCallbackPath + "?code=x&state=nope"); c != http.StatusBadRequest {
		t.Fatalf("unknown state: %d", c)
	}
}
