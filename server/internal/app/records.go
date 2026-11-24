package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// Kinds of record, in the order a device applies them (docs/sync-protocol.md).
var Kinds = []string{"collection", "location", "field", "item", "media"}

func validKind(k string) bool {
	for _, x := range Kinds {
		if x == k {
			return true
		}
	}
	return false
}

// Record is one synced row as it travels.
type Record struct {
	Kind string          `json:"kind"`
	Data json.RawMessage `json:"data"`
}

// recordHead is what the server reads out of a record's data.
type recordHead struct {
	ID        string `json:"id"`
	UpdatedAt *int64 `json:"updatedAt"`
	Deleted   bool   `json:"deleted"`
	SHA256    string `json:"sha256"`
}

var sha256Re = regexp.MustCompile(`^[0-9a-f]{64}$`)

const maxRecordBytes = 512 << 10

func parseRecord(r Record) (recordHead, error) {
	var h recordHead
	if !validKind(r.Kind) {
		return h, fmt.Errorf("unknown kind %q", r.Kind)
	}
	if len(r.Data) == 0 || r.Data[0] != '{' {
		return h, errors.New("data must be an object")
	}
	if len(r.Data) > maxRecordBytes {
		return h, fmt.Errorf("data is larger than %d bytes", maxRecordBytes)
	}
	if err := json.Unmarshal(r.Data, &h); err != nil {
		return h, fmt.Errorf("data: %v", err)
	}
	h.ID = strings.ToLower(h.ID)
	if !isUUID(h.ID) {
		return h, errors.New("data.id must be a UUID")
	}
	if h.UpdatedAt == nil {
		return h, errors.New("data.updatedAt is missing")
	}
	if r.Kind == "media" && !h.Deleted && !sha256Re.MatchString(h.SHA256) {
		return h, errors.New("media needs its file's sha256")
	}
	return h, nil
}

// PushResult is the outcome for one pushed record.
type PushResult struct {
	Kind   string `json:"kind"`
	ID     string `json:"id"`
	Status string `json:"status"`
	Error  string `json:"error,omitempty"`
}

// ownerLock is the advisory lock that orders writes to one library, so a
// record's seq is never visible before a lower one (pull would skip it).
const ownerLock = `SELECT pg_advisory_xact_lock(hashtext('records:' || $1))`

// Push writes records for owner, each only when newer than what is stored
// (last writer wins by updatedAt).
func (s *Store) Push(ctx context.Context, ownerID, deviceID string, recs []Record) ([]PushResult, error) {
	results := make([]PushResult, len(recs))
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(ctx, ownerLock, ownerID); err != nil {
		return nil, err
	}
	for i, r := range recs {
		res := &results[i]
		res.Kind = r.Kind
		h, err := parseRecord(r)
		res.ID = h.ID
		if err != nil {
			res.Status, res.Error = "rejected", err.Error()
			continue
		}
		if r.Kind == "media" && !h.Deleted {
			var has bool
			if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM blob_owners WHERE owner_id=$1 AND sha256=$2)`, ownerID, h.SHA256).Scan(&has); err != nil {
				return nil, err
			}
			if !has {
				res.Status, res.Error = "rejected", "missing blob"
				continue
			}
		}
		var seq int64
		err = tx.QueryRow(ctx, `INSERT INTO records (owner_id, kind, id, updated_at, deleted, data, seq, device_id)
			VALUES ($1,$2,$3,$4,$5,$6,nextval('record_seq'),$7)
			ON CONFLICT (owner_id, kind, id) DO UPDATE SET updated_at=EXCLUDED.updated_at, deleted=EXCLUDED.deleted,
				data=EXCLUDED.data, seq=EXCLUDED.seq, device_id=EXCLUDED.device_id, received_at=now()
			WHERE records.updated_at < EXCLUDED.updated_at
			RETURNING seq`, ownerID, r.Kind, h.ID, *h.UpdatedAt, h.Deleted, []byte(r.Data), nullUUID(deviceID)).Scan(&seq)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
			res.Status = "stale"
		case err != nil:
			return nil, err
		default:
			res.Status = "accepted"
		}
	}
	return results, tx.Commit(ctx)
}

// Pull returns owner's records changed after cursor, leaving out the ones
// deviceID wrote; the new cursor covers those too.
func (s *Store) Pull(ctx context.Context, ownerID, deviceID string, since int64, limit int) (recs []Record, cursor int64, more bool, err error) {
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return nil, 0, false, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	// Wait for any push in progress, so everything below the cursor we hand
	// out has been committed.
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock_shared(hashtext('records:' || $1))`, ownerID); err != nil {
		return nil, 0, false, err
	}
	rows, err := tx.Query(ctx, `SELECT kind, data, seq, coalesce(device_id::text, '') FROM records
		WHERE owner_id=$1 AND seq > $2 ORDER BY seq LIMIT $3`, ownerID, since, limit+1)
	if err != nil {
		return nil, 0, false, err
	}
	defer rows.Close()
	cursor = since
	n := 0
	recs = []Record{}
	for rows.Next() {
		var r Record
		var data []byte
		var seq int64
		var dev string
		if err := rows.Scan(&r.Kind, &data, &seq, &dev); err != nil {
			return nil, 0, false, err
		}
		if n == limit {
			more = true
			break
		}
		n++
		cursor = seq
		if dev != "" && dev == deviceID {
			continue
		}
		r.Data = data
		recs = append(recs, r)
	}
	return recs, cursor, more, rows.Err()
}

// ---- reading a library, for the web pages ----

// Row is a stored record with its data decoded.
type Row struct {
	Kind       string
	ID         string
	OwnerID    string
	UpdatedAt  int64
	Deleted    bool
	Data       map[string]any
	Raw        []byte
	Seq        int64
	DeviceID   string
	DeviceName string
	ReceivedAt time.Time
}

func (r *Row) Str(key string) string {
	if v, ok := r.Data[key].(string); ok {
		return v
	}
	return ""
}

func (r *Row) Updated() time.Time { return time.UnixMilli(r.UpdatedAt) }

func (s *Store) rows(ctx context.Context, where string, args ...any) ([]Row, error) {
	rows, err := s.DB.Query(ctx, `SELECT r.kind, r.id::text, r.owner_id::text, r.updated_at, r.deleted, r.data, r.seq, coalesce(r.device_id::text,''), coalesce(d.name,''), r.received_at
		FROM records r LEFT JOIN devices d ON d.id=r.device_id WHERE `+where, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Row
	for rows.Next() {
		var r Row
		if err := rows.Scan(&r.Kind, &r.ID, &r.OwnerID, &r.UpdatedAt, &r.Deleted, &r.Raw, &r.Seq, &r.DeviceID, &r.DeviceName, &r.ReceivedAt); err != nil {
			return nil, err
		}
		_ = json.Unmarshal(r.Raw, &r.Data)
		out = append(out, r)
	}
	return out, rows.Err()
}

// Live returns owner's records of a kind that aren't deleted.
func (s *Store) Live(ctx context.Context, ownerID, kind string) ([]Row, error) {
	return s.rows(ctx, `r.owner_id=$1 AND r.kind=$2 AND NOT r.deleted ORDER BY lower(r.data->>'name'), r.id`, ownerID, kind)
}

// One returns a record (deleted or not), or nil.
func (s *Store) One(ctx context.Context, ownerID, kind, id string) (*Row, error) {
	if !isUUID(id) {
		return nil, nil
	}
	rs, err := s.rows(ctx, `r.owner_id=$1 AND r.kind=$2 AND r.id=$3`, ownerID, kind, id)
	if err != nil || len(rs) == 0 {
		return nil, err
	}
	return &rs[0], nil
}

// Where returns owner's live records of kind whose data[key] equals value.
func (s *Store) Where(ctx context.Context, ownerID, kind, key, value string) ([]Row, error) {
	return s.rows(ctx, `r.owner_id=$1 AND r.kind=$2 AND NOT r.deleted AND r.data->>$3 = $4 ORDER BY lower(r.data->>'name'), (r.data->>'sortOrder')::numeric NULLS LAST, r.id`,
		ownerID, kind, key, value)
}

// Items returns a collection's live items, optionally only those whose
// record mentions q anywhere (name, notes, field values).
func (s *Store) Items(ctx context.Context, ownerID, collectionID, q string) ([]Row, error) {
	if q == "" {
		return s.Where(ctx, ownerID, "item", "collectionId", collectionID)
	}
	return s.rows(ctx, `r.owner_id=$1 AND r.kind='item' AND NOT r.deleted AND r.data->>'collectionId' = $2 AND r.data::text ILIKE $3 ORDER BY lower(r.data->>'name')`,
		ownerID, collectionID, "%"+escapeLike(q)+"%")
}

// Recent returns owner's most recently accepted changes.
func (s *Store) Recent(ctx context.Context, ownerID string, n int) ([]Row, error) {
	return s.rows(ctx, `r.owner_id=$1 ORDER BY r.seq DESC LIMIT $2`, ownerID, n)
}

// Counts returns how many live records of each kind owner has.
func (s *Store) Counts(ctx context.Context, ownerID string) (map[string]int, error) {
	q := `SELECT kind, count(*) FROM records WHERE NOT deleted`
	args := []any{}
	if ownerID != "" {
		q += ` AND owner_id=$1`
		args = append(args, ownerID)
	}
	rows, err := s.DB.Query(ctx, q+` GROUP BY kind`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]int{}
	for rows.Next() {
		var k string
		var n int
		if err := rows.Scan(&k, &n); err != nil {
			return nil, err
		}
		out[k] = n
	}
	return out, rows.Err()
}

// ItemCounts returns the number of live items in each of owner's collections.
func (s *Store) ItemCounts(ctx context.Context, ownerID string) (map[string]int, error) {
	rows, err := s.DB.Query(ctx, `SELECT data->>'collectionId', count(*) FROM records WHERE owner_id=$1 AND kind='item' AND NOT deleted GROUP BY 1`, ownerID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]int{}
	for rows.Next() {
		var k *string
		var n int
		if err := rows.Scan(&k, &n); err != nil {
			return nil, err
		}
		if k != nil {
			out[*k] = n
		}
	}
	return out, rows.Err()
}

func escapeLike(s string) string {
	return strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(s)
}
