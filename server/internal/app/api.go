package app

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	maxPushRecords = 500
	maxPushBytes   = 8 << 20
	apiVersion     = 1
)

func (a *App) apiInfo(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"service": "collection-keeper", "apiVersion": apiVersion, "version": a.cfg.Version, "name": a.cfg.Name,
	})
}

func (a *App) apiPairStart(w http.ResponseWriter, r *http.Request) {
	var in struct {
		DeviceName string `json:"deviceName"`
		Platform   string `json:"platform"`
		AppVersion string `json:"appVersion"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "expected {deviceName, platform, appVersion}")
		return
	}
	in.DeviceName = clip(strings.TrimSpace(in.DeviceName), 80)
	if in.DeviceName == "" {
		in.DeviceName = "A device"
	}
	deviceCode, userCode, err := a.store.StartPairing(r.Context(), in.DeviceName, clip(in.Platform, 20), clip(in.AppVersion, 40))
	if err != nil {
		a.serverError(w, r, err)
		return
	}
	a.log.Info("pairing started", "device", in.DeviceName, "platform", in.Platform)
	writeJSON(w, http.StatusOK, map[string]any{
		"deviceCode": deviceCode,
		"userCode":   userCode,
		"verifyUrl":  publicBase(r, a.cfg.PublicURL) + "/pair?code=" + userCode,
		"expiresIn":  int(pairingTTL.Seconds()),
		"interval":   3,
	})
}

func (a *App) apiPairPoll(w http.ResponseWriter, r *http.Request) {
	var in struct {
		DeviceCode string `json:"deviceCode"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&in); err != nil || in.DeviceCode == "" {
		writeError(w, http.StatusBadRequest, "expected {deviceCode}")
		return
	}
	status, token, user, err := a.store.PollPairing(r.Context(), in.DeviceCode)
	if err != nil {
		a.serverError(w, r, err)
		return
	}
	out := map[string]any{"status": status}
	if status == "approved" {
		out["token"] = token
		out["user"] = userJSON(user)
		a.log.Info("device paired", "user", user.Username)
	}
	writeJSON(w, http.StatusOK, out)
}

func userJSON(u *User) map[string]any {
	return map[string]any{"id": u.ID, "username": u.Username, "name": u.DisplayName()}
}

func (a *App) apiMe(w http.ResponseWriter, r *http.Request) {
	d := deviceFrom(r)
	writeJSON(w, http.StatusOK, map[string]any{
		"user":   userJSON(d.User),
		"device": map[string]any{"id": d.Device.ID, "name": d.Device.Name},
	})
}

func (a *App) apiPush(w http.ResponseWriter, r *http.Request) {
	d := deviceFrom(r)
	start := time.Now()
	ev := SyncEvent{UserID: &d.User.ID, DeviceID: &d.Device.ID, Op: "push", Bytes: r.ContentLength}
	defer func() {
		ev.DurationMs = int(time.Since(start).Milliseconds())
		a.store.LogEvent(r.Context(), ev)
	}()
	var in struct {
		Records []Record `json:"records"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxPushBytes)).Decode(&in); err != nil {
		ev.Status, ev.Error = http.StatusBadRequest, "bad body: "+err.Error()
		writeError(w, ev.Status, ev.Error)
		return
	}
	ev.RecordsIn = len(in.Records)
	if len(in.Records) > maxPushRecords {
		ev.Status, ev.Error = http.StatusRequestEntityTooLarge, "at most 500 records per push"
		writeError(w, ev.Status, ev.Error)
		return
	}
	results, err := a.store.Push(r.Context(), d.User.ID, d.Device.ID, in.Records)
	if err != nil {
		ev.Status, ev.Error = http.StatusInternalServerError, err.Error()
		a.serverError(w, r, err)
		return
	}
	var firstErr string
	for _, res := range results {
		switch res.Status {
		case "accepted":
			ev.Accepted++
		case "stale":
			ev.Stale++
		default:
			ev.Rejected++
			if firstErr == "" {
				firstErr = res.Kind + " " + res.ID + ": " + res.Error
			}
		}
	}
	ev.Status, ev.Error = http.StatusOK, firstErr
	if ev.Rejected > 0 {
		a.log.Warn("records rejected", "user", d.User.Username, "device", d.Device.Name, "rejected", ev.Rejected, "first", firstErr)
	}
	a.store.TouchDevice(r.Context(), d.Device, clientIP(r), true)
	writeJSON(w, http.StatusOK, map[string]any{"results": results})
}

func (a *App) apiPull(w http.ResponseWriter, r *http.Request) {
	d := deviceFrom(r)
	start := time.Now()
	ev := SyncEvent{UserID: &d.User.ID, DeviceID: &d.Device.ID, Op: "pull", Status: http.StatusOK}
	defer func() {
		ev.DurationMs = int(time.Since(start).Milliseconds())
		a.store.LogEvent(r.Context(), ev)
	}()
	since, err := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
	if err != nil && r.URL.Query().Get("since") != "" {
		ev.Status, ev.Error = http.StatusBadRequest, "since must be a number"
		writeError(w, ev.Status, ev.Error)
		return
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 {
		limit = 500
	}
	limit = min(limit, 1000)
	recs, cursor, more, err := a.store.Pull(r.Context(), d.User.ID, d.Device.ID, since, limit)
	if err != nil {
		ev.Status, ev.Error = http.StatusInternalServerError, err.Error()
		a.serverError(w, r, err)
		return
	}
	ev.RecordsOut = len(recs)
	a.store.TouchDevice(r.Context(), d.Device, clientIP(r), true)
	writeJSON(w, http.StatusOK, map[string]any{"records": recs, "cursor": cursor, "more": more})
}

func blobSHA(w http.ResponseWriter, r *http.Request) (string, bool) {
	sha := strings.ToLower(r.PathValue("sha"))
	if !sha256Re.MatchString(sha) {
		writeError(w, http.StatusBadRequest, "not a sha256")
		return "", false
	}
	return sha, true
}

func (a *App) apiBlobHead(w http.ResponseWriter, r *http.Request) {
	sha, ok := blobSHA(w, r)
	if !ok {
		return
	}
	has, err := a.blobs.Has(r.Context(), deviceFrom(r).User.ID, sha)
	if err != nil {
		a.serverError(w, r, err)
		return
	}
	if !has {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	w.WriteHeader(http.StatusOK)
}

func (a *App) apiBlobGet(w http.ResponseWriter, r *http.Request) {
	sha, ok := blobSHA(w, r)
	if !ok {
		return
	}
	d := deviceFrom(r)
	has, err := a.blobs.Has(r.Context(), d.User.ID, sha)
	if err != nil {
		a.serverError(w, r, err)
		return
	}
	if !has {
		writeError(w, http.StatusNotFound, "no such file in this library")
		return
	}
	a.serveBlob(w, r, sha)
	a.store.LogEvent(r.Context(), SyncEvent{UserID: &d.User.ID, DeviceID: &d.Device.ID, Op: "download", Status: http.StatusOK})
}

func (a *App) serveBlob(w http.ResponseWriter, r *http.Request, sha string) {
	f, ct, err := a.blobs.Open(r.Context(), sha)
	if err != nil {
		a.serverError(w, r, err)
		return
	}
	defer f.Close()
	st, _ := f.Stat()
	w.Header().Set("Content-Type", ct)
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	w.Header().Set("ETag", `"`+sha+`"`)
	http.ServeContent(w, r, "", st.ModTime(), f)
}

func (a *App) apiBlobPut(w http.ResponseWriter, r *http.Request) {
	sha, ok := blobSHA(w, r)
	if !ok {
		return
	}
	d := deviceFrom(r)
	start := time.Now()
	created, size, err := a.blobs.Put(r.Context(), d.User.ID, sha, r.Header.Get("Content-Type"), r.Body)
	ev := SyncEvent{UserID: &d.User.ID, DeviceID: &d.Device.ID, Op: "upload", Bytes: size, DurationMs: int(time.Since(start).Milliseconds()), Status: http.StatusOK}
	switch {
	case errors.Is(err, errHashMismatch):
		ev.Status, ev.Error = http.StatusBadRequest, err.Error()
	case err != nil:
		ev.Status, ev.Error = http.StatusInternalServerError, err.Error()
		a.log.Error("upload failed", "user", d.User.Username, "sha256", sha, "err", err)
	case created:
		ev.Status = http.StatusCreated
	}
	a.store.LogEvent(r.Context(), ev)
	if ev.Status >= 400 {
		writeError(w, ev.Status, ev.Error)
		return
	}
	writeJSON(w, ev.Status, map[string]any{"sha256": sha, "size": size})
}

func clip(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}
