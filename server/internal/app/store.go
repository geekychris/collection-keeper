package app

import (
	"context"
	"embed"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed migrations/*.sql
var migrations embed.FS

// Store is the server's Postgres database.
type Store struct {
	DB *pgxpool.Pool
}

func OpenStore(ctx context.Context, url string) (*Store, error) {
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		return nil, err
	}
	// The database may still be starting (a fresh deploy, a node restart).
	deadline := time.Now().Add(2 * time.Minute)
	for {
		if err = pool.Ping(ctx); err == nil {
			break
		}
		if time.Now().After(deadline) {
			pool.Close()
			return nil, fmt.Errorf("database not reachable: %w", err)
		}
		time.Sleep(2 * time.Second)
	}
	s := &Store{DB: pool}
	if err := s.migrate(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() { s.DB.Close() }

// migrate applies migrations/NNN_*.sql in order, each once, in a
// transaction, under an advisory lock so two starting servers don't race.
func (s *Store) migrate(ctx context.Context) error {
	conn, err := s.DB.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock(7347001)`); err != nil {
		return err
	}
	defer conn.Exec(context.Background(), `SELECT pg_advisory_unlock(7347001)`) //nolint:errcheck
	if _, err := conn.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (version int PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`); err != nil {
		return err
	}
	entries, err := migrations.ReadDir("migrations")
	if err != nil {
		return err
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
	for _, e := range entries {
		v, err := strconv.Atoi(strings.SplitN(e.Name(), "_", 2)[0])
		if err != nil {
			return fmt.Errorf("migration %s: name must start with a number", e.Name())
		}
		var done bool
		if err := conn.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version=$1)`, v).Scan(&done); err != nil {
			return err
		}
		if done {
			continue
		}
		sql, _ := migrations.ReadFile("migrations/" + e.Name())
		tx, err := conn.Begin(ctx)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, string(sql)); err != nil {
			tx.Rollback(ctx) //nolint:errcheck
			return fmt.Errorf("migration %s: %w", e.Name(), err)
		}
		if _, err := tx.Exec(ctx, `INSERT INTO schema_migrations (version) VALUES ($1)`, v); err != nil {
			tx.Rollback(ctx) //nolint:errcheck
			return err
		}
		if err := tx.Commit(ctx); err != nil {
			return err
		}
	}
	return nil
}

// SchemaVersion is the highest migration applied.
func (s *Store) SchemaVersion(ctx context.Context) int {
	var v int
	_ = s.DB.QueryRow(ctx, `SELECT coalesce(max(version), 0) FROM schema_migrations`).Scan(&v)
	return v
}

// ---- users ----

type User struct {
	ID          string
	Username    string
	Name        string
	Email       string
	OIDCSub     *string
	HasPassword bool
	Admin       bool
	Disabled    bool
	CreatedAt   time.Time
	LastLoginAt *time.Time
}

// DisplayName is the name to show: the full name, else the username.
func (u *User) DisplayName() string {
	if u.Name != "" {
		return u.Name
	}
	return u.Username
}

const userCols = `id::text, username, name, email, oidc_sub, password_hash IS NOT NULL, admin, disabled, created_at, last_login_at`

func scanUser(row pgx.Row) (*User, error) {
	u := &User{}
	err := row.Scan(&u.ID, &u.Username, &u.Name, &u.Email, &u.OIDCSub, &u.HasPassword, &u.Admin, &u.Disabled, &u.CreatedAt, &u.LastLoginAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return u, err
}

func (s *Store) UserByID(ctx context.Context, id string) (*User, error) {
	if !isUUID(id) {
		return nil, nil
	}
	return scanUser(s.DB.QueryRow(ctx, `SELECT `+userCols+` FROM users WHERE id=$1`, id))
}

func (s *Store) UserByUsername(ctx context.Context, name string) (*User, error) {
	return scanUser(s.DB.QueryRow(ctx, `SELECT `+userCols+` FROM users WHERE lower(username)=lower($1)`, name))
}

func (s *Store) PasswordHash(ctx context.Context, userID string) (string, error) {
	var h *string
	err := s.DB.QueryRow(ctx, `SELECT password_hash FROM users WHERE id=$1`, userID).Scan(&h)
	if err != nil || h == nil {
		return "", err
	}
	return *h, nil
}

// UpsertOIDCUser finds or creates the person with this subject, refreshing
// their name, email and admin flag from the latest sign-in.
func (s *Store) UpsertOIDCUser(ctx context.Context, sub, username, name, email string, admin bool) (*User, error) {
	u, err := scanUser(s.DB.QueryRow(ctx, `UPDATE users SET name=$2, email=$3, admin=$4, last_login_at=now() WHERE oidc_sub=$1 RETURNING `+userCols,
		sub, name, email, admin))
	if err != nil || u != nil {
		return u, err
	}
	base := cleanUsername(username)
	if base == "" {
		base = "user"
	}
	for i := 0; i < 50; i++ {
		candidate := base
		if i > 0 {
			candidate = fmt.Sprintf("%s-%d", base, i+1)
		}
		u, err = scanUser(s.DB.QueryRow(ctx, `INSERT INTO users (id, username, name, email, oidc_sub, admin, last_login_at)
			VALUES ($1,$2,$3,$4,$5,$6,now()) ON CONFLICT (username) DO NOTHING RETURNING `+userCols,
			newUUID(), candidate, name, email, sub, admin))
		if err != nil || u != nil {
			return u, err
		}
	}
	return nil, fmt.Errorf("no free username for %q", base)
}

// CreateLocalUser makes an account that signs in with a password.
func (s *Store) CreateLocalUser(ctx context.Context, username, name, passwordHash string, admin bool) (*User, error) {
	username = cleanUsername(username)
	if username == "" {
		return nil, fmt.Errorf("a username needs letters or digits")
	}
	u, err := scanUser(s.DB.QueryRow(ctx, `INSERT INTO users (id, username, name, password_hash, admin)
		VALUES ($1,$2,$3,$4,$5) ON CONFLICT (username) DO NOTHING RETURNING `+userCols,
		newUUID(), username, name, passwordHash, admin))
	if err == nil && u == nil {
		err = fmt.Errorf("the username %s is taken", username)
	}
	return u, err
}

func (s *Store) SetPassword(ctx context.Context, userID, hash string) error {
	_, err := s.DB.Exec(ctx, `UPDATE users SET password_hash=$2 WHERE id=$1`, userID, hash)
	return err
}

func (s *Store) SetDisabled(ctx context.Context, userID string, disabled bool) error {
	_, err := s.DB.Exec(ctx, `UPDATE users SET disabled=$2 WHERE id=$1`, userID, disabled)
	if err == nil && disabled {
		_, err = s.DB.Exec(ctx, `DELETE FROM sessions WHERE user_id=$1`, userID)
	}
	return err
}

func (s *Store) SetAdmin(ctx context.Context, userID string, admin bool) error {
	_, err := s.DB.Exec(ctx, `UPDATE users SET admin=$2 WHERE id=$1`, userID, admin)
	return err
}

func (s *Store) TouchLogin(ctx context.Context, userID string) {
	_, _ = s.DB.Exec(ctx, `UPDATE users SET last_login_at=now() WHERE id=$1`, userID)
}

// UserSummary is a row of the admin's user list.
type UserSummary struct {
	User
	Records    int
	Items      int
	BlobBytes  int64
	Devices    int
	LastSyncAt *time.Time
}

func (s *Store) UserSummaries(ctx context.Context) ([]UserSummary, error) {
	rows, err := s.DB.Query(ctx, `SELECT `+prefixCols("u.", userCols)+`,
		(SELECT count(*) FROM records r WHERE r.owner_id=u.id AND NOT r.deleted),
		(SELECT count(*) FROM records r WHERE r.owner_id=u.id AND r.kind='item' AND NOT r.deleted),
		(SELECT coalesce(sum(b.size),0) FROM blob_owners o JOIN blobs b USING (sha256) WHERE o.owner_id=u.id),
		(SELECT count(*) FROM devices d WHERE d.user_id=u.id AND d.revoked_at IS NULL),
		(SELECT max(d.last_sync_at) FROM devices d WHERE d.user_id=u.id)
		FROM users u ORDER BY lower(u.username)`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []UserSummary
	for rows.Next() {
		var x UserSummary
		u := &x.User
		if err := rows.Scan(&u.ID, &u.Username, &u.Name, &u.Email, &u.OIDCSub, &u.HasPassword, &u.Admin, &u.Disabled, &u.CreatedAt, &u.LastLoginAt,
			&x.Records, &x.Items, &x.BlobBytes, &x.Devices, &x.LastSyncAt); err != nil {
			return nil, err
		}
		out = append(out, x)
	}
	return out, rows.Err()
}

func prefixCols(prefix, cols string) string {
	parts := strings.Split(cols, ", ")
	for i, p := range parts {
		parts[i] = prefix + p
	}
	s := strings.Join(parts, ", ")
	// "u.password_hash IS NOT NULL" and "u.id::text" read fine as they are.
	return s
}

// ---- devices ----

type Device struct {
	ID         string
	UserID     string
	Name       string
	Platform   string
	AppVersion string
	CreatedAt  time.Time
	LastSeenAt *time.Time
	LastSyncAt *time.Time
	LastIP     string
	RevokedAt  *time.Time
}

const deviceCols = `id::text, user_id::text, name, platform, app_version, created_at, last_seen_at, last_sync_at, last_ip, revoked_at`

func scanDevice(row pgx.Row) (*Device, error) {
	d := &Device{}
	err := row.Scan(&d.ID, &d.UserID, &d.Name, &d.Platform, &d.AppVersion, &d.CreatedAt, &d.LastSeenAt, &d.LastSyncAt, &d.LastIP, &d.RevokedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return d, err
}

// DeviceByToken finds the live device with this token, and its person.
func (s *Store) DeviceByToken(ctx context.Context, token string) (*Device, *User, error) {
	d, err := scanDevice(s.DB.QueryRow(ctx, `SELECT `+deviceCols+` FROM devices WHERE token_hash=$1 AND revoked_at IS NULL`, sha256Hex(token)))
	if err != nil || d == nil {
		return nil, nil, err
	}
	u, err := s.UserByID(ctx, d.UserID)
	if err != nil || u == nil || u.Disabled {
		return nil, nil, err
	}
	return d, u, nil
}

func (s *Store) CreateDevice(ctx context.Context, userID, name, platform, appVersion string) (*Device, string, error) {
	token := "ckt_" + randomToken(32)
	d, err := scanDevice(s.DB.QueryRow(ctx, `INSERT INTO devices (id, user_id, name, platform, app_version, token_hash)
		VALUES ($1,$2,$3,$4,$5,$6) RETURNING `+deviceCols, newUUID(), userID, name, platform, appVersion, sha256Hex(token)))
	return d, token, err
}

func (s *Store) Devices(ctx context.Context, userID string) ([]Device, error) {
	q := `SELECT ` + deviceCols + ` FROM devices`
	args := []any{}
	if userID != "" {
		q += ` WHERE user_id=$1`
		args = append(args, userID)
	}
	rows, err := s.DB.Query(ctx, q+` ORDER BY revoked_at IS NOT NULL, coalesce(last_seen_at, created_at) DESC`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Device
	for rows.Next() {
		d, err := scanDevice(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *d)
	}
	return out, rows.Err()
}

func (s *Store) DeviceByID(ctx context.Context, id string) (*Device, error) {
	if !isUUID(id) {
		return nil, nil
	}
	return scanDevice(s.DB.QueryRow(ctx, `SELECT `+deviceCols+` FROM devices WHERE id=$1`, id))
}

func (s *Store) RevokeDevice(ctx context.Context, id string) error {
	_, err := s.DB.Exec(ctx, `UPDATE devices SET revoked_at=now() WHERE id=$1 AND revoked_at IS NULL`, id)
	return err
}

// TouchDevice records that a device was heard from (at most once a minute
// for last_seen, every time for a sync).
func (s *Store) TouchDevice(ctx context.Context, d *Device, ip string, synced bool) {
	if synced {
		_, _ = s.DB.Exec(ctx, `UPDATE devices SET last_seen_at=now(), last_sync_at=now(), last_ip=$2 WHERE id=$1`, d.ID, ip)
		return
	}
	if d.LastSeenAt == nil || time.Since(*d.LastSeenAt) > time.Minute || d.LastIP != ip {
		_, _ = s.DB.Exec(ctx, `UPDATE devices SET last_seen_at=now(), last_ip=$2 WHERE id=$1`, d.ID, ip)
	}
}

// ---- sync events ----

type SyncEvent struct {
	ID         int64
	At         time.Time
	UserID     *string
	Username   string
	DeviceID   *string
	DeviceName string
	Op         string
	RecordsIn  int
	Accepted   int
	Stale      int
	Rejected   int
	RecordsOut int
	Bytes      int64
	DurationMs int
	Status     int
	Error      string
}

func (s *Store) LogEvent(ctx context.Context, e SyncEvent) {
	_, _ = s.DB.Exec(context.WithoutCancel(ctx), `INSERT INTO sync_events (user_id, device_id, op, records_in, accepted, stale, rejected, records_out, bytes, duration_ms, status, error)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,
		e.UserID, e.DeviceID, e.Op, e.RecordsIn, e.Accepted, e.Stale, e.Rejected, e.RecordsOut, e.Bytes, e.DurationMs, e.Status, e.Error)
}

// EventFilter narrows the event log.
type EventFilter struct {
	UserID     string
	DeviceID   string
	ErrorsOnly bool
	Limit      int
}

func (s *Store) Events(ctx context.Context, f EventFilter) ([]SyncEvent, error) {
	where, args := []string{"true"}, []any{}
	if f.UserID != "" {
		args = append(args, f.UserID)
		where = append(where, fmt.Sprintf("e.user_id=$%d", len(args)))
	}
	if f.DeviceID != "" {
		args = append(args, f.DeviceID)
		where = append(where, fmt.Sprintf("e.device_id=$%d", len(args)))
	}
	if f.ErrorsOnly {
		where = append(where, "(e.status >= 400 OR e.rejected > 0 OR e.error <> '')")
	}
	if f.Limit <= 0 || f.Limit > 1000 {
		f.Limit = 200
	}
	rows, err := s.DB.Query(ctx, `SELECT e.id, e.at, e.user_id::text, coalesce(u.username,''), e.device_id::text, coalesce(d.name,''),
		e.op, e.records_in, e.accepted, e.stale, e.rejected, e.records_out, e.bytes, e.duration_ms, e.status, e.error
		FROM sync_events e LEFT JOIN users u ON u.id=e.user_id LEFT JOIN devices d ON d.id=e.device_id
		WHERE `+strings.Join(where, " AND ")+` ORDER BY e.at DESC LIMIT `+strconv.Itoa(f.Limit), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SyncEvent
	for rows.Next() {
		var e SyncEvent
		if err := rows.Scan(&e.ID, &e.At, &e.UserID, &e.Username, &e.DeviceID, &e.DeviceName, &e.Op, &e.RecordsIn, &e.Accepted, &e.Stale,
			&e.Rejected, &e.RecordsOut, &e.Bytes, &e.DurationMs, &e.Status, &e.Error); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// Prune removes old sync events, expired sessions and pairings.
func (s *Store) Prune(ctx context.Context) {
	_, _ = s.DB.Exec(ctx, `DELETE FROM sync_events WHERE at < now() - interval '30 days'`)
	_, _ = s.DB.Exec(ctx, `DELETE FROM sessions WHERE expires_at < now()`)
	_, _ = s.DB.Exec(ctx, `DELETE FROM pairings WHERE expires_at < now() - interval '1 hour'`)
}
