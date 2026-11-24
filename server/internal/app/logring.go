package app

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"
)

// LogRing keeps the last few hundred log lines for the admin's Logs page,
// and passes every record on to another handler (stdout).
type LogRing struct {
	mu    sync.Mutex
	lines []LogLine
	next  int
	full  bool
}

type LogLine struct {
	At      time.Time
	Level   slog.Level
	Message string
	Attrs   string
}

func NewLogRing(n int) *LogRing { return &LogRing{lines: make([]LogLine, n)} }

func (l *LogRing) add(line LogLine) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.lines[l.next] = line
	l.next = (l.next + 1) % len(l.lines)
	if l.next == 0 {
		l.full = true
	}
}

// Lines returns the kept lines, newest first, at or above min.
func (l *LogRing) Lines(min slog.Level) []LogLine {
	l.mu.Lock()
	defer l.mu.Unlock()
	n := l.next
	if l.full {
		n = len(l.lines)
	}
	out := make([]LogLine, 0, n)
	for i := 1; i <= n; i++ {
		line := l.lines[(l.next-i+len(l.lines))%len(l.lines)]
		if line.Level >= min {
			out = append(out, line)
		}
	}
	return out
}

// Handler wraps next so records also land in the ring.
func (l *LogRing) Handler(next slog.Handler) slog.Handler { return &ringHandler{next: next, ring: l} }

type ringHandler struct {
	next  slog.Handler
	ring  *LogRing
	attrs []slog.Attr
}

func (h *ringHandler) Enabled(ctx context.Context, lv slog.Level) bool {
	return h.next.Enabled(ctx, lv)
}

func (h *ringHandler) Handle(ctx context.Context, r slog.Record) error {
	var b strings.Builder
	write := func(a slog.Attr) bool {
		fmt.Fprintf(&b, "%s=%v ", a.Key, a.Value)
		return true
	}
	for _, a := range h.attrs {
		write(a)
	}
	r.Attrs(write)
	h.ring.add(LogLine{At: r.Time, Level: r.Level, Message: r.Message, Attrs: strings.TrimSpace(b.String())})
	return h.next.Handle(ctx, r)
}

func (h *ringHandler) WithAttrs(as []slog.Attr) slog.Handler {
	return &ringHandler{next: h.next.WithAttrs(as), ring: h.ring, attrs: append(append([]slog.Attr{}, h.attrs...), as...)}
}

func (h *ringHandler) WithGroup(name string) slog.Handler {
	return &ringHandler{next: h.next.WithGroup(name), ring: h.ring, attrs: h.attrs}
}
