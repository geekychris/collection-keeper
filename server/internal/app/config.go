// Package app is the Collection Keeper sync server: the sync API the app
// talks to (docs/sync-protocol.md), and web pages for people to look at
// their library and for admins to look after the server.
package app

import (
	"fmt"
	"os"
	"strings"
	"time"
)

// Config comes from the environment (see the server README).
type Config struct {
	Addr        string // LISTEN_ADDR, default :8080
	DatabaseURL string // DATABASE_URL, a Postgres URL
	BlobDir     string // BLOB_DIR, where media files are kept
	PublicURL   string // PUBLIC_URL, optional: the base for links when no proxy says
	Name        string // SERVER_NAME, shown on pages and to the app

	// OpenID Connect (optional). Issuer is what browsers and tokens use;
	// BackchannelURL is where the server itself reaches the provider (the same
	// host on another port, at home), default the issuer.
	OIDCIssuer       string
	OIDCBackchannel  string
	OIDCClientID     string
	OIDCClientSecret string
	OIDCAdminRole    string // OIDC_ADMIN_ROLE, default admin
	OIDCUserRoles    []string

	// AdminPassword, when set, keeps a local account "admin" with this
	// password: a way in when the login service is unreachable, and the only
	// one on a server without it.
	AdminPassword string

	SessionTTL time.Duration
	Version    string
}

func ConfigFromEnv(version string) (Config, error) {
	c := Config{
		Addr:             env("LISTEN_ADDR", ":8080"),
		DatabaseURL:      os.Getenv("DATABASE_URL"),
		BlobDir:          env("BLOB_DIR", "/data/blobs"),
		PublicURL:        strings.TrimRight(os.Getenv("PUBLIC_URL"), "/"),
		Name:             env("SERVER_NAME", "Collection Keeper"),
		OIDCIssuer:       strings.TrimRight(os.Getenv("OIDC_ISSUER"), "/"),
		OIDCBackchannel:  strings.TrimRight(os.Getenv("OIDC_BACKCHANNEL_URL"), "/"),
		OIDCClientID:     os.Getenv("OIDC_CLIENT_ID"),
		OIDCClientSecret: os.Getenv("OIDC_CLIENT_SECRET"),
		OIDCAdminRole:    env("OIDC_ADMIN_ROLE", "admin"),
		OIDCUserRoles:    strings.Fields(strings.ReplaceAll(env("OIDC_USER_ROLES", "user"), ",", " ")),
		AdminPassword:    os.Getenv("ADMIN_PASSWORD"),
		SessionTTL:       30 * 24 * time.Hour,
		Version:          version,
	}
	if c.DatabaseURL == "" {
		return c, fmt.Errorf("DATABASE_URL is not set")
	}
	if c.OIDCBackchannel == "" {
		c.OIDCBackchannel = c.OIDCIssuer
	}
	if c.OIDCIssuer != "" && (c.OIDCClientID == "" || c.OIDCClientSecret == "") {
		return c, fmt.Errorf("OIDC_ISSUER is set but OIDC_CLIENT_ID or OIDC_CLIENT_SECRET isn't")
	}
	if c.OIDCIssuer == "" && c.AdminPassword == "" {
		return c, fmt.Errorf("no way to sign in: set OIDC_ISSUER (with its client) or ADMIN_PASSWORD")
	}
	return c, nil
}

// OIDCEnabled says whether people sign in through a login service.
func (c Config) OIDCEnabled() bool { return c.OIDCIssuer != "" }

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
