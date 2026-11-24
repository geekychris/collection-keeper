package app

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

var uuidRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func isUUID(s string) bool { return uuidRe.MatchString(s) }

func newUUID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// unpackID turns a label's 22-character packed id (lib/src/data/codes.dart)
// back into a UUID; a UUID passes through.
func unpackID(s string) string {
	if isUUID(s) {
		return strings.ToLower(s)
	}
	b, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil || len(b) != 16 {
		return ""
	}
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func nullUUID(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func randomToken(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

func sha256Hex(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

var usernameRe = regexp.MustCompile(`[^a-z0-9._-]+`)

func cleanUsername(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	if i := strings.IndexByte(s, '@'); i > 0 {
		s = s[:i]
	}
	return strings.Trim(usernameRe.ReplaceAllString(s, "-"), "-.")
}

// humanBytes is 1.2 GB style.
func humanBytes(n int64) string {
	const unit = 1000
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for m := n / unit; m >= unit; m /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(n)/float64(div), "kMGTPE"[exp])
}

func jsonUnmarshalString(s string, v any) error { return json.Unmarshal([]byte(s), v) }

func jsonIndent(dst *bytes.Buffer, raw []byte) error { return json.Indent(dst, raw, "", "  ") }
