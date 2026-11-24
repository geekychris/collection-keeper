# Collection Keeper sync server

Optional. It keeps every device's copy of a person's library in step
([docs/sync-protocol.md](../docs/sync-protocol.md)) and holds their photos and
files. It also serves web pages:

- **Library:** collections, items with their photos, locations, and each
  record as stored. `/i/<id>` and `/l/<id>` accept the ids on printed labels.
- **Devices:** a person's paired phones and computers, their recent syncs,
  and a Disconnect button. `/pair` approves a device the app is connecting.
- **Admin** (`/admin`, admins only):
  - Server status: storage, disk, sign-in health and recent warnings.
  - People: add password accounts, disable people, reset passwords, and view
    anyone's library read-only.
  - All devices, the sync log (with a filter for problems), an integrity check
    of media records against files, and the process's recent logs.

One Go binary with Postgres for records and a directory for files.

## Signing in

- **OpenID Connect** (`OIDC_ISSUER`, …). At home this is the lab's login
  service at `https://auth.hitorro.com`. A person needs the `user` or
  `admin` role for the client. Their account is made the first time they
  sign in, and the `admin` role makes them an admin here.
- **Local accounts with a password:**
  - `ADMIN_PASSWORD` keeps an account `admin` with that password, which is
    how to get in when the login service is down.
  - Admins can add more accounts on the People page. On a server without a
    login service, these are everyone's accounts.

Devices never see a password. The app asks for a pairing code, the person
approves it at `/pair` while signed in, and the app gets a device token. The
server stores only the token's hash; disconnecting the device revokes it.

## Settings

| Variable | |
|---|---|
| `DATABASE_URL` | Postgres, e.g. `postgres://ck:…@db:5432/collectionkeeper?sslmode=disable` (required) |
| `BLOB_DIR` | where files go (`/data/blobs`) |
| `LISTEN_ADDR` | `:8080` |
| `SERVER_NAME` | shown on pages and in the app (`Collection Keeper`) |
| `PUBLIC_URL` | a fallback base for links; normally the request's own host (and `X-Forwarded-Host`/`-Proto` from a proxy) is used |
| `OIDC_ISSUER`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` | the login service |
| `OIDC_BACKCHANNEL_URL` | where the server itself reaches the provider, when that differs from the issuer (at home `https://auth.hitorro.com:8443`) |
| `OIDC_ADMIN_ROLE`, `OIDC_USER_ROLES` | `admin`; `user` (comma-separated) |
| `ADMIN_PASSWORD` | the local `admin` account's password |

You need either `OIDC_ISSUER` or `ADMIN_PASSWORD`.

## Running it

```sh
docker run -d --name ck-pg -e POSTGRES_PASSWORD=pw -e POSTGRES_DB=ck -p 15433:5432 postgres:16-alpine
DATABASE_URL='postgres://postgres:pw@127.0.0.1:15433/ck?sslmode=disable' \
  ADMIN_PASSWORD=change-me BLOB_DIR=/tmp/ck-blobs go run ./cmd/ckserver
# http://localhost:8080, sign in as admin
```

The image is built from `Dockerfile` in this directory. At home it is
deployed to mp2 by cloud-stack's `deploy/collection-keeper/deploy.sh`, which
builds it, makes the secrets, registers the OpenID Connect client and runs a
smoke test.

## Tests

```sh
docker run -d --name ck-test-pg -e POSTGRES_PASSWORD=test -e POSTGRES_DB=ck -p 15433:5432 postgres:16-alpine
go test ./...        # wipes that database; set CK_TEST_DATABASE_URL to use another
```

Without a reachable Postgres, the tests skip.

What the tests cover:
- Pairing, approved and denied.
- Last-writer-wins pushes and tombstones.
- Pull cursors under concurrent pushes.
- Files, including keeping them private to their library.
- Every web and admin page.
- Viewing as another person.
- CSRF protection.
- Sign-in against a simulated login service: PKCE, the `:8443` LAN port, the back channel, and roles.

`test/live_server_test.dart` in the app runs the app's real sync code
against a running server.

## Layout

```
cmd/ckserver/                 main: configuration, logging, HTTP server
internal/app/api.go           the app's API: info, pairing, push, pull, files
internal/app/records.go       storing and reading records (last writer wins, change numbers)
internal/app/blobs.go         files on disk by SHA-256, thumbnails, the integrity check
internal/app/auth.go          sessions, passwords, device tokens, pairing
internal/app/oidc.go          OpenID Connect sign-in
internal/app/web.go           library, devices and pairing pages
internal/app/admin.go         admin pages
internal/app/web/             templates and stylesheet (embedded)
internal/app/migrations/      the Postgres schema
```
