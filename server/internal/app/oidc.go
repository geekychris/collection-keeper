package app

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"golang.org/x/oauth2"
)

// The redirect path the lab's deploy scripts register for every app.
const oidcCallbackPath = "/login/oauth2/code/cloudstack"

// oidcClient signs people in with an OpenID Connect provider (at home, the
// lab's login service at https://auth.<zone>). The browser talks to the
// issuer's host, on the same port the browser used to reach us (at home the
// LAN path is :8443); the server reaches the provider at the back-channel
// URL instead.
type oidcClient struct {
	cfg Config

	mu        sync.Mutex
	authURL   string
	tokenURL  string
	verifier  *oidc.IDTokenVerifier
	lastErr   error
	checkedAt time.Time

	pending sync.Map // state → *oidcPending
}

type oidcPending struct {
	nonce, verifier, redirectURI, next string
	expires                            time.Time
}

// discover reads the provider's configuration once it can, pointing the
// server-side endpoints at the back channel.
func (o *oidcClient) discover(ctx context.Context) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.verifier != nil {
		return nil
	}
	if o.lastErr != nil && time.Since(o.checkedAt) < 10*time.Second {
		return o.lastErr
	}
	o.checkedAt = time.Now()
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	p, err := oidc.NewProvider(oidc.InsecureIssuerURLContext(ctx, o.cfg.OIDCIssuer), o.cfg.OIDCBackchannel)
	if err != nil {
		o.lastErr = fmt.Errorf("discovery at %s: %w", o.cfg.OIDCBackchannel, err)
		return o.lastErr
	}
	var meta struct {
		JWKS string `json:"jwks_uri"`
	}
	if err := p.Claims(&meta); err != nil {
		o.lastErr = err
		return err
	}
	o.authURL = p.Endpoint().AuthURL
	o.tokenURL = o.backchannel(p.Endpoint().TokenURL)
	keys := oidc.NewRemoteKeySet(context.Background(), o.backchannel(meta.JWKS))
	o.verifier = oidc.NewVerifier(o.cfg.OIDCIssuer, keys, &oidc.Config{ClientID: o.cfg.OIDCClientID})
	o.lastErr = nil
	return nil
}

// backchannel moves a URL on the issuer onto the back-channel base.
func (o *oidcClient) backchannel(u string) string {
	if rest, ok := strings.CutPrefix(u, o.cfg.OIDCIssuer); ok {
		return o.cfg.OIDCBackchannel + rest
	}
	return u
}

// Status is for the diagnostics page.
func (o *oidcClient) Status(ctx context.Context) (ok bool, detail string) {
	if err := o.discover(ctx); err != nil {
		return false, err.Error()
	}
	return true, fmt.Sprintf("authorize %s, token %s", o.authURL, o.tokenURL)
}

// browserAuthURL is the authorization endpoint on the port the browser
// reached us on, when the issuer itself has none.
func (o *oidcClient) browserAuthURL(r *http.Request) string {
	host := requestHost(r)
	_, port, hasPort := strings.Cut(host, ":")
	u, err := url.Parse(o.authURL)
	if err != nil || !hasPort || u.Port() != "" || port == "443" || port == "80" {
		return o.authURL
	}
	u.Host = u.Hostname() + ":" + port
	return u.String()
}

func (o *oidcClient) oauth(redirectURI, authURL string) *oauth2.Config {
	return &oauth2.Config{
		ClientID:     o.cfg.OIDCClientID,
		ClientSecret: o.cfg.OIDCClientSecret,
		Endpoint:     oauth2.Endpoint{AuthURL: authURL, TokenURL: o.tokenURL, AuthStyle: oauth2.AuthStyleInHeader},
		RedirectURL:  redirectURI,
		Scopes:       []string{oidc.ScopeOpenID, "profile", "email"},
	}
}

// start sends the browser to the provider.
func (o *oidcClient) start(w http.ResponseWriter, r *http.Request, next string) error {
	if err := o.discover(r.Context()); err != nil {
		return err
	}
	o.gc()
	state, nonce, verifier := randomToken(24), randomToken(24), oauth2.GenerateVerifier()
	redirect := publicBase(r, "") + oidcCallbackPath
	o.pending.Store(state, &oidcPending{nonce: nonce, verifier: verifier, redirectURI: redirect, next: next, expires: time.Now().Add(10 * time.Minute)})
	u := o.oauth(redirect, o.browserAuthURL(r)).AuthCodeURL(state, oidc.Nonce(nonce), oauth2.S256ChallengeOption(verifier))
	http.Redirect(w, r, u, http.StatusFound)
	return nil
}

type oidcIdentity struct {
	Sub      string   `json:"sub"`
	Username string   `json:"preferred_username"`
	Name     string   `json:"name"`
	Email    string   `json:"email"`
	Roles    []string `json:"roles"`
}

var errNoRole = errors.New("no role for this app")

// finish handles the provider's redirect back: it checks the state, swaps
// the code for an ID token and checks that.
func (o *oidcClient) finish(r *http.Request) (*oidcIdentity, string, error) {
	if e := r.URL.Query().Get("error"); e != "" {
		return nil, "", fmt.Errorf("the login service said %s: %s", e, r.URL.Query().Get("error_description"))
	}
	v, ok := o.pending.LoadAndDelete(r.URL.Query().Get("state"))
	if !ok {
		return nil, "", errors.New("this sign-in expired or was already used; start again")
	}
	p := v.(*oidcPending)
	if time.Now().After(p.expires) {
		return nil, "", errors.New("this sign-in took too long; start again")
	}
	if err := o.discover(r.Context()); err != nil {
		return nil, "", err
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	tok, err := o.oauth(p.redirectURI, o.authURL).Exchange(ctx, r.URL.Query().Get("code"), oauth2.VerifierOption(p.verifier))
	if err != nil {
		return nil, "", fmt.Errorf("exchanging the code: %w", err)
	}
	raw, _ := tok.Extra("id_token").(string)
	if raw == "" {
		return nil, "", errors.New("the login service sent no ID token")
	}
	idt, err := o.verifier.Verify(ctx, raw)
	if err != nil {
		return nil, "", fmt.Errorf("checking the ID token: %w", err)
	}
	if idt.Nonce != p.nonce {
		return nil, "", errors.New("the ID token's nonce doesn't match")
	}
	var id oidcIdentity
	if err := idt.Claims(&id); err != nil {
		return nil, "", err
	}
	if id.Sub == "" {
		return nil, "", errors.New("the ID token has no subject")
	}
	if !slices.Contains(id.Roles, o.cfg.OIDCAdminRole) && !slices.ContainsFunc(id.Roles, func(r string) bool { return slices.Contains(o.cfg.OIDCUserRoles, r) }) {
		return &id, p.next, errNoRole
	}
	return &id, p.next, nil
}

func (o *oidcClient) gc() {
	now := time.Now()
	o.pending.Range(func(k, v any) bool {
		if now.After(v.(*oidcPending).expires) {
			o.pending.Delete(k)
		}
		return true
	})
}
