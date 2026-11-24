-- People. Someone signed in through OpenID Connect has oidc_sub; a local
-- account (for a server without a login service, or the bootstrap admin)
-- has password_hash. Each person owns one library.
CREATE TABLE users (
    id            uuid PRIMARY KEY,
    username      text NOT NULL UNIQUE,
    name          text NOT NULL DEFAULT '',
    email         text NOT NULL DEFAULT '',
    oidc_sub      text UNIQUE,
    password_hash text,
    admin         boolean NOT NULL DEFAULT false,
    disabled      boolean NOT NULL DEFAULT false,
    created_at    timestamptz NOT NULL DEFAULT now(),
    last_login_at timestamptz
);

-- Every synced record, as the app sends it (docs/sync-protocol.md). seq is
-- the order changes were accepted in; devices pull by it.
CREATE SEQUENCE record_seq;

CREATE TABLE records (
    owner_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind        text NOT NULL,
    id          uuid NOT NULL,
    updated_at  bigint NOT NULL,
    deleted     boolean NOT NULL DEFAULT false,
    data        jsonb NOT NULL,
    seq         bigint NOT NULL,
    device_id   uuid,
    received_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (owner_id, kind, id)
);
CREATE INDEX records_owner_seq ON records (owner_id, seq);

-- Media files by SHA-256; the bytes live on disk (BLOB_DIR). A library may
-- read a blob only once it has uploaded it.
CREATE TABLE blobs (
    sha256       text PRIMARY KEY,
    size         bigint NOT NULL,
    content_type text NOT NULL DEFAULT '',
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE blob_owners (
    owner_id   uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    sha256     text NOT NULL REFERENCES blobs(sha256),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (owner_id, sha256)
);

-- A paired device and its token (stored as its SHA-256 only).
CREATE TABLE devices (
    id           uuid PRIMARY KEY,
    user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name         text NOT NULL,
    platform     text NOT NULL DEFAULT '',
    app_version  text NOT NULL DEFAULT '',
    token_hash   text NOT NULL UNIQUE,
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz,
    last_sync_at timestamptz,
    last_ip      text NOT NULL DEFAULT '',
    revoked_at   timestamptz
);

-- A pairing in progress: the app holds the device code, the person types or
-- follows the user code in a browser.
CREATE TABLE pairings (
    device_code_hash text PRIMARY KEY,
    user_code        text NOT NULL UNIQUE,
    device_name      text NOT NULL,
    platform         text NOT NULL DEFAULT '',
    app_version      text NOT NULL DEFAULT '',
    created_at       timestamptz NOT NULL DEFAULT now(),
    expires_at       timestamptz NOT NULL,
    status           text NOT NULL DEFAULT 'pending',
    user_id          uuid REFERENCES users(id) ON DELETE CASCADE
);

-- Browser sign-ins (the cookie holds the id; this holds its hash).
CREATE TABLE sessions (
    id_hash    text PRIMARY KEY,
    user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    csrf       text NOT NULL,
    view_as    uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL
);

-- One row per sync call, for the diagnostics pages. Kept 30 days.
CREATE TABLE sync_events (
    id          bigserial PRIMARY KEY,
    at          timestamptz NOT NULL DEFAULT now(),
    user_id     uuid REFERENCES users(id) ON DELETE CASCADE,
    device_id   uuid REFERENCES devices(id) ON DELETE CASCADE,
    op          text NOT NULL,
    records_in  int NOT NULL DEFAULT 0,
    accepted    int NOT NULL DEFAULT 0,
    stale       int NOT NULL DEFAULT 0,
    rejected    int NOT NULL DEFAULT 0,
    records_out int NOT NULL DEFAULT 0,
    bytes       bigint NOT NULL DEFAULT 0,
    duration_ms int NOT NULL DEFAULT 0,
    status      int NOT NULL DEFAULT 200,
    error       text NOT NULL DEFAULT ''
);
CREATE INDEX sync_events_at ON sync_events (at DESC);
CREATE INDEX sync_events_user ON sync_events (user_id, at DESC);
