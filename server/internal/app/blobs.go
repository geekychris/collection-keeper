package app

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	_ "image/png" // thumbnails of PNG photos
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"golang.org/x/image/draw"
)

// Blobs keeps media files on disk by SHA-256: <dir>/ab/cd/<sha256>, with
// web thumbnails under <dir>/thumbs.
type Blobs struct {
	Dir   string
	store *Store
}

const maxBlobBytes = 4 << 30

var errHashMismatch = errors.New("the file doesn't match its sha256")

func (b *Blobs) path(sha string) string {
	return filepath.Join(b.Dir, sha[0:2], sha[2:4], sha)
}

// Has says whether owner may read the blob (it uploaded it).
func (b *Blobs) Has(ctx context.Context, ownerID, sha string) (bool, error) {
	var has bool
	err := b.store.DB.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM blob_owners WHERE owner_id=$1 AND sha256=$2)`, ownerID, sha).Scan(&has)
	return has, err
}

// Put stores body under sha for owner, checking the hash. It returns false
// when the server had the file already.
func (b *Blobs) Put(ctx context.Context, ownerID, sha, contentType string, body io.Reader) (created bool, size int64, err error) {
	if !sha256Re.MatchString(sha) {
		return false, 0, errors.New("not a sha256")
	}
	final := b.path(sha)
	if _, err := os.Stat(final); err != nil {
		if err := os.MkdirAll(filepath.Dir(final), 0o755); err != nil {
			return false, 0, err
		}
		tmp, err := os.CreateTemp(filepath.Dir(final), ".upload-*")
		if err != nil {
			return false, 0, err
		}
		defer os.Remove(tmp.Name())
		h := sha256.New()
		size, err = io.Copy(io.MultiWriter(tmp, h), io.LimitReader(body, maxBlobBytes+1))
		if cerr := tmp.Close(); err == nil {
			err = cerr
		}
		if err != nil {
			return false, 0, err
		}
		if size > maxBlobBytes {
			return false, 0, fmt.Errorf("files are limited to %s", humanBytes(maxBlobBytes))
		}
		if hex.EncodeToString(h.Sum(nil)) != sha {
			return false, 0, errHashMismatch
		}
		if err := os.Rename(tmp.Name(), final); err != nil {
			return false, 0, err
		}
		created = true
	} else {
		// Already on disk (another library has it, or an earlier upload whose
		// row didn't commit); drain the body so the connection stays usable.
		_, _ = io.Copy(io.Discard, body)
		st, _ := os.Stat(final)
		size = st.Size()
	}
	if contentType == "" || strings.HasPrefix(contentType, "multipart/") {
		contentType = "application/octet-stream"
	}
	if _, err := b.store.DB.Exec(ctx, `INSERT INTO blobs (sha256, size, content_type) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING`, sha, size, contentType); err != nil {
		return false, 0, err
	}
	tag, err := b.store.DB.Exec(ctx, `INSERT INTO blob_owners (owner_id, sha256) VALUES ($1,$2) ON CONFLICT DO NOTHING`, ownerID, sha)
	if err != nil {
		return false, 0, err
	}
	return created || tag.RowsAffected() > 0, size, nil
}

// Open returns the file and its content type.
func (b *Blobs) Open(ctx context.Context, sha string) (*os.File, string, error) {
	var ct string
	if err := b.store.DB.QueryRow(ctx, `SELECT content_type FROM blobs WHERE sha256=$1`, sha).Scan(&ct); err != nil {
		return nil, "", err
	}
	f, err := os.Open(b.path(sha))
	return f, ct, err
}

// Thumbnail returns a small JPEG of an image blob, made once and cached, or
// an error for anything that isn't a JPEG or PNG.
func (b *Blobs) Thumbnail(ctx context.Context, sha string) (string, error) {
	out := filepath.Join(b.Dir, "thumbs", sha+".jpg")
	if _, err := os.Stat(out); err == nil {
		return out, nil
	}
	f, _, err := b.Open(ctx, sha)
	if err != nil {
		return "", err
	}
	defer f.Close()
	src, _, err := image.Decode(f)
	if err != nil {
		return "", err
	}
	const max = 480
	bounds := src.Bounds()
	w, h := bounds.Dx(), bounds.Dy()
	if w > h && w > max {
		w, h = max, h*max/w
	} else if h > max {
		w, h = w*max/h, max
	}
	dst := image.NewRGBA(image.Rect(0, 0, max1(w), max1(h)))
	draw.CatmullRom.Scale(dst, dst.Bounds(), src, bounds, draw.Src, nil)
	if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
		return "", err
	}
	tmp, err := os.CreateTemp(filepath.Dir(out), ".thumb-*")
	if err != nil {
		return "", err
	}
	defer os.Remove(tmp.Name())
	if err := jpeg.Encode(tmp, dst, &jpeg.Options{Quality: 82}); err != nil {
		tmp.Close()
		return "", err
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	return out, os.Rename(tmp.Name(), out)
}

func max1(n int) int {
	if n < 1 {
		return 1
	}
	return n
}

// DiskFree returns the free and total bytes of the blob directory's disk.
func (b *Blobs) DiskFree() (free, total uint64, err error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(b.Dir, &st); err != nil {
		return 0, 0, err
	}
	return st.Bavail * uint64(st.Bsize), st.Blocks * uint64(st.Bsize), nil
}

// BlobStats is the blob table's size.
type BlobStats struct {
	Count int
	Bytes int64
}

func (b *Blobs) Stats(ctx context.Context) (BlobStats, error) {
	var s BlobStats
	err := b.store.DB.QueryRow(ctx, `SELECT count(*), coalesce(sum(size),0) FROM blobs`).Scan(&s.Count, &s.Bytes)
	return s, err
}

// CheckReport is what an integrity check found.
type CheckReport struct {
	MediaChecked  int
	MissingBlob   []Row    // live media whose library has no such blob
	MissingFile   []string // blobs in the table with no file on disk
	WrongSize     []string // files whose size differs from the table
	Orphans       int      // blobs no live media record uses
	OrphanBytes   int64
	BlobsChecked  int
	UnknownOnDisk int // files on disk the table doesn't know
}

// Check compares media records, the blob table and the files on disk.
func (b *Blobs) Check(ctx context.Context) (*CheckReport, error) {
	r := &CheckReport{}
	media, err := b.store.rows(ctx, `r.kind='media' AND NOT r.deleted AND NOT EXISTS (
		SELECT 1 FROM blob_owners o WHERE o.owner_id=r.owner_id AND o.sha256=r.data->>'sha256') ORDER BY r.received_at DESC`)
	if err != nil {
		return nil, err
	}
	r.MissingBlob = media
	if err := b.store.DB.QueryRow(ctx, `SELECT count(*) FROM records WHERE kind='media' AND NOT deleted`).Scan(&r.MediaChecked); err != nil {
		return nil, err
	}
	if err := b.store.DB.QueryRow(ctx, `SELECT count(*), coalesce(sum(size),0) FROM blobs b WHERE NOT EXISTS (
		SELECT 1 FROM records r WHERE r.kind='media' AND NOT r.deleted AND r.data->>'sha256' = b.sha256)`).Scan(&r.Orphans, &r.OrphanBytes); err != nil {
		return nil, err
	}
	rows, err := b.store.DB.Query(ctx, `SELECT sha256, size FROM blobs`)
	if err != nil {
		return nil, err
	}
	known := map[string]bool{}
	for rows.Next() {
		var sha string
		var size int64
		if err := rows.Scan(&sha, &size); err != nil {
			rows.Close()
			return nil, err
		}
		known[sha] = true
		r.BlobsChecked++
		st, err := os.Stat(b.path(sha))
		switch {
		case err != nil:
			r.MissingFile = append(r.MissingFile, sha)
		case st.Size() != size:
			r.WrongSize = append(r.WrongSize, sha)
		}
	}
	rows.Close()
	_ = filepath.WalkDir(b.Dir, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() && d.Name() == "thumbs" {
			return filepath.SkipDir
		}
		if !d.IsDir() && sha256Re.MatchString(d.Name()) && !known[d.Name()] {
			r.UnknownOnDisk++
		}
		return nil
	})
	return r, nil
}
