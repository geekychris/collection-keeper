package app

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"golang.org/x/crypto/bcrypt"
)

const sessionCookie = "ck_session"

// Session is a signed-in browser.
type Session struct {
	User   *User
	CSRF   string
	ViewAs *User // an admin looking at someone else's library
	idHash string
}

// Owner is whose library the pages show.
func (s *Session) Owner() *User {
	if s.ViewAs != nil {
		return s.ViewAs
	}
	return s.User
}

func (a *App) newSession(ctx context.Context, w http.ResponseWriter, r *http.Request, u *User) error {
	id := randomToken(32)
	if _, err := a.store.DB.Exec(ctx, `INSERT INTO sessions (id_hash, user_id, csrf, expires_at) VALUES ($1,$2,$3,$4)`,
		sha256Hex(id), u.ID, randomToken(24), time.Now().Add(a.cfg.SessionTTL)); err != nil {
		return err
	}
	http.SetCookie(w, &http.Cookie{
		Name: sessionCookie, Value: id, Path: "/", HttpOnly: true, SameSite: http.SameSiteLaxMode,
		Secure: requestScheme(r) == "https", MaxAge: int(a.cfg.SessionTTL.Seconds()),
	})
	a.store.TouchLogin(ctx, u.ID)
	return nil
}

func (a *App) session(r *http.Request) (*Session, error) {
	c, err := r.Cookie(sessionCookie)
	if err != nil || c.Value == "" {
		return nil, nil
	}
	ctx := r.Context()
	s := &Session{idHash: sha256Hex(c.Value)}
	var userID string
	var viewAs *string
	err = a.store.DB.QueryRow(ctx, `SELECT user_id::text, csrf, view_as::text FROM sessions WHERE id_hash=$1 AND expires_at > now()`, s.idHash).
		Scan(&userID, &s.CSRF, &viewAs)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if s.User, err = a.store.UserByID(ctx, userID); err != nil || s.User == nil || s.User.Disabled {
		return nil, err
	}
	if viewAs != nil && s.User.Admin {
		if s.ViewAs, err = a.store.UserByID(ctx, *viewAs); err != nil {
			return nil, err
		}
	}
	return s, nil
}

func (a *App) endSession(w http.ResponseWriter, r *http.Request, s *Session) {
	if s != nil {
		_, _ = a.store.DB.Exec(r.Context(), `DELETE FROM sessions WHERE id_hash=$1`, s.idHash)
	}
	http.SetCookie(w, &http.Cookie{Name: sessionCookie, Value: "", Path: "/", MaxAge: -1, HttpOnly: true})
}

func (a *App) setViewAs(ctx context.Context, s *Session, userID string) error {
	_, err := a.store.DB.Exec(ctx, `UPDATE sessions SET view_as=$2 WHERE id_hash=$1`, s.idHash, nullUUID(userID))
	return err
}

// checkCSRF compares a form's token with the session's.
func checkCSRF(r *http.Request, s *Session) bool {
	return subtle.ConstantTimeCompare([]byte(r.PostFormValue("csrf")), []byte(s.CSRF)) == 1
}

// ---- passwords ----

func hashPassword(pw string) (string, error) {
	h, err := bcrypt.GenerateFromPassword([]byte(pw), bcrypt.DefaultCost)
	return string(h), err
}

// checkPassword signs a local account in, or returns nil.
func (a *App) checkPassword(ctx context.Context, username, pw string) (*User, error) {
	u, err := a.store.UserByUsername(ctx, username)
	if err != nil {
		return nil, err
	}
	if u == nil || u.Disabled || !u.HasPassword {
		// Spend the same time either way.
		_ = bcrypt.CompareHashAndPassword([]byte("$2a$10$7EqJtq98hPqEX7fNZaFWoOhi5BWX4Z0J9w.gqH6xXo1qNt8JgX2.e"), []byte(pw))
		return nil, nil
	}
	h, err := a.store.PasswordHash(ctx, u.ID)
	if err != nil {
		return nil, err
	}
	if bcrypt.CompareHashAndPassword([]byte(h), []byte(pw)) != nil {
		return nil, nil
	}
	return u, nil
}

// ensureAdmin keeps the local "admin" account's password equal to
// ADMIN_PASSWORD (so rotating the secret rotates the password).
func (a *App) ensureAdmin(ctx context.Context) error {
	if a.cfg.AdminPassword == "" {
		return nil
	}
	u, err := a.store.UserByUsername(ctx, "admin")
	if err != nil {
		return err
	}
	h, err := hashPassword(a.cfg.AdminPassword)
	if err != nil {
		return err
	}
	if u == nil {
		_, err = a.store.CreateLocalUser(ctx, "admin", "Administrator", h, true)
		return err
	}
	if u.OIDCSub != nil {
		// Someone signed in through the login service as "admin": leave them be.
		return nil
	}
	if old, _ := a.store.PasswordHash(ctx, u.ID); old != "" && bcrypt.CompareHashAndPassword([]byte(old), []byte(a.cfg.AdminPassword)) == nil {
		return nil
	}
	if err := a.store.SetPassword(ctx, u.ID, h); err != nil {
		return err
	}
	return a.store.SetAdmin(ctx, u.ID, true)
}

// ---- devices ----

type deviceCtxKey struct{}

type deviceAuth struct {
	Device *Device
	User   *User
}

// requireDevice checks the bearer token on API requests.
func (a *App) requireDevice(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || !strings.HasPrefix(tok, "ckt_") {
			writeError(w, http.StatusUnauthorized, "this device isn't connected: pair it again")
			return
		}
		d, u, err := a.store.DeviceByToken(r.Context(), strings.TrimSpace(tok))
		if err != nil {
			a.serverError(w, r, err)
			return
		}
		if d == nil {
			writeError(w, http.StatusUnauthorized, "this device's token was revoked or is unknown: pair it again")
			return
		}
		a.store.TouchDevice(r.Context(), d, clientIP(r), false)
		next(w, r.WithContext(context.WithValue(r.Context(), deviceCtxKey{}, &deviceAuth{d, u})))
	}
}

func deviceFrom(r *http.Request) *deviceAuth {
	d, _ := r.Context().Value(deviceCtxKey{}).(*deviceAuth)
	return d
}

// ---- pairing ----

// userCodeAlphabet leaves out letters and digits people confuse (0/O, 1/I/L).
const userCodeAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

func newUserCode() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	out := make([]byte, 0, 9)
	for i, c := range b {
		if i == 4 {
			out = append(out, '-')
		}
		out = append(out, userCodeAlphabet[int(c)%len(userCodeAlphabet)])
	}
	return string(out)
}

func normalizeUserCode(s string) string {
	s = strings.ToUpper(strings.Map(func(r rune) rune {
		if r == '-' || r == ' ' {
			return -1
		}
		return r
	}, s))
	if len(s) != 8 {
		return ""
	}
	return s[:4] + "-" + s[4:]
}

type Pairing struct {
	UserCode   string
	DeviceName string
	Platform   string
	AppVersion string
	CreatedAt  time.Time
	ExpiresAt  time.Time
	Status     string
	UserID     *string
	codeHash   string
}

const pairingTTL = 10 * time.Minute

func (s *Store) StartPairing(ctx context.Context, name, platform, appVersion string) (deviceCode, userCode string, err error) {
	for i := 0; i < 5; i++ {
		deviceCode, userCode = randomToken(32), newUserCode()
		_, err = s.DB.Exec(ctx, `INSERT INTO pairings (device_code_hash, user_code, device_name, platform, app_version, expires_at)
			VALUES ($1,$2,$3,$4,$5,$6) ON CONFLICT DO NOTHING`, sha256Hex(deviceCode), userCode, name, platform, appVersion, time.Now().Add(pairingTTL))
		if err == nil {
			return
		}
	}
	return "", "", err
}

func scanPairing(row pgx.Row) (*Pairing, error) {
	p := &Pairing{}
	err := row.Scan(&p.codeHash, &p.UserCode, &p.DeviceName, &p.Platform, &p.AppVersion, &p.CreatedAt, &p.ExpiresAt, &p.Status, &p.UserID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return p, err
}

const pairingCols = `device_code_hash, user_code, device_name, platform, app_version, created_at, expires_at, status, user_id::text`

func (s *Store) PairingByUserCode(ctx context.Context, code string) (*Pairing, error) {
	return scanPairing(s.DB.QueryRow(ctx, `SELECT `+pairingCols+` FROM pairings WHERE user_code=$1 AND expires_at > now()`, code))
}

// DecidePairing approves or denies a pending pairing for user.
func (s *Store) DecidePairing(ctx context.Context, code, userID string, approve bool) (bool, error) {
	status := "denied"
	if approve {
		status = "approved"
	}
	tag, err := s.DB.Exec(ctx, `UPDATE pairings SET status=$2, user_id=$3 WHERE user_code=$1 AND status='pending' AND expires_at > now()`, code, status, userID)
	return tag.RowsAffected() == 1, err
}

// PollPairing reports a pairing's state; an approved one becomes a device
// (once) and its token is returned.
func (s *Store) PollPairing(ctx context.Context, deviceCode string) (status, token string, user *User, err error) {
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return "", "", nil, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	p, err := scanPairing(tx.QueryRow(ctx, `SELECT `+pairingCols+` FROM pairings WHERE device_code_hash=$1 FOR UPDATE`, sha256Hex(deviceCode)))
	if err != nil {
		return "", "", nil, err
	}
	switch {
	case p == nil || p.Status == "collected" || time.Now().After(p.ExpiresAt):
		return "expired", "", nil, nil
	case p.Status != "approved":
		return p.Status, "", nil, nil
	}
	token = "ckt_" + randomToken(32)
	if _, err := tx.Exec(ctx, `INSERT INTO devices (id, user_id, name, platform, app_version, token_hash) VALUES ($1,$2,$3,$4,$5,$6)`,
		newUUID(), *p.UserID, p.DeviceName, p.Platform, p.AppVersion, sha256Hex(token)); err != nil {
		return "", "", nil, err
	}
	if _, err := tx.Exec(ctx, `UPDATE pairings SET status='collected' WHERE device_code_hash=$1`, p.codeHash); err != nil {
		return "", "", nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return "", "", nil, err
	}
	user, err = s.UserByID(ctx, *p.UserID)
	return "approved", token, user, err
}
