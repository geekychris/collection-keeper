// Command ckserver is the Collection Keeper sync server: see server/README.md.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/geekychris/collection-keeper/server/internal/app"
)

// version is set at build time (-ldflags "-X main.version=…").
var version = "dev"

func main() {
	ring := app.NewLogRing(500)
	logger := slog.New(ring.Handler(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))
	slog.SetDefault(logger)

	cfg, err := app.ConfigFromEnv(version)
	if err != nil {
		logger.Error("configuration", "err", err)
		os.Exit(2)
	}
	if err := os.MkdirAll(cfg.BlobDir, 0o755); err != nil {
		logger.Error("blob directory", "dir", cfg.BlobDir, "err", err)
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	a, err := app.New(ctx, cfg, logger, ring)
	if err != nil {
		logger.Error("starting", "err", err)
		os.Exit(1)
	}
	defer a.Close()

	srv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           a.Handler(),
		ReadHeaderTimeout: 20 * time.Second,
		IdleTimeout:       2 * time.Minute,
	}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdown)
	}()
	logger.Info("listening", "addr", cfg.Addr, "version", version, "oidc", cfg.OIDCEnabled(), "blobs", cfg.BlobDir)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Error("serving", "err", err)
		os.Exit(1)
	}
}
