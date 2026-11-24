# Sync protocol, version 1

How the app and a Collection Keeper server (`server/`) keep a person's
library the same on every device. The server is optional: the app works
without one, and anyone can run their own and point the app at it
(Settings › Sync server).

A **library** is everything one person owns: their collections, fields,
locations, items and media. Each device keeps the whole library locally;
the server keeps a copy plus the media files, and hands out changes.

## Basics

- Base URL: whatever the person types in the app, e.g.
  `https://collections.hitorro.com`. Every API path is under `/api/v1/`.
- JSON in and out (`Content-Type: application/json`), except blob bodies.
- Errors: a non-2xx status with `{"error": "message"}`. `401` means the
  device token is missing, wrong or revoked: the app stops syncing and asks
  to connect again.
- Device requests carry `Authorization: Bearer <token>`. Tokens start with
  `ckt_`, are made by pairing (below), and last until revoked on the web.

## Records

Every synced row travels as

```json
{ "kind": "item", "data": { "id": "…", "updatedAt": 1764000000000, "deleted": false, … } }
```

`kind` is `collection`, `field`, `location`, `item` or `media`. `data` is the
record exactly as in the collection format (docs/collection-format.md):

| kind | data |
|---|---|
| `collection` | the `collection` object of collection.json |
| `field` | one entry of `fields` |
| `location` | one entry of `locations` |
| `item` | an items/<id>.json **without** `media` (`fieldValues` is an object) |
| `media` | one entry of an item's `media` |

`data.id` (a UUID), `data.updatedAt` (ms, UTC) and `data.deleted` are
required; the server reads nothing else from `data` except `sha256` on media
(to check the blob) and the ids the web pages use to link records. Deletions
are records with `deleted: true` and travel like any other change.

**Conflicts:** last writer wins, by `updatedAt`. A record replaces the stored
one only when its `updatedAt` is later; an equal or older one is `stale` and
ignored. Devices apply what they pull by the same rule.

## Pairing a device

The app never sees a password. It asks for a code, the person approves it in
a browser where they are signed in, and the app collects a token.

`GET /api/v1/info` (no auth)

```json
{ "service": "collection-keeper", "apiVersion": 1, "version": "0.1.0", "name": "Collection Keeper" }
```

`POST /api/v1/pair/start` (no auth)

```json
→ { "deviceName": "Chris's iPhone", "platform": "ios", "appVersion": "1.0.0" }
← { "deviceCode": "…", "userCode": "KQ7M-4TXP", "verifyUrl": "https://…/pair?code=KQ7M-4TXP",
    "expiresIn": 600, "interval": 3 }
```

The app shows `userCode`, opens `verifyUrl` in the browser (and shows it as
a QR code, so a phone can approve a desktop), then polls:

`POST /api/v1/pair/poll` (no auth) `{ "deviceCode": "…" }` →

```json
{ "status": "pending" }
{ "status": "approved", "token": "ckt_…", "user": { "id": "…", "username": "chris", "name": "Chris" } }
{ "status": "denied" }
{ "status": "expired" }
```

The token is handed out once; after that the code is `expired`. Poll no
faster than `interval` seconds.

`GET /api/v1/me` → `{ "user": {…}, "device": { "id": "…", "name": "…" } }`

## Pushing changes

`POST /api/v1/sync/push`

```json
→ { "records": [ { "kind": "collection", "data": {…} }, … ] }      (at most 500 records, 8 MB)
← { "results": [ { "kind": "collection", "id": "…", "status": "accepted" }, … ] }
```

`status` is `accepted`, `stale` (the server has a version at least as new;
nothing changed) or `rejected` with an `error` (the record is malformed; the
app logs it and drops it from its outbox). A media record is `rejected` when
its blob hasn't been uploaded yet (`error: "missing blob"`), so upload first.

## Pulling changes

`GET /api/v1/sync/pull?since=<cursor>&limit=<n>` (limit ≤ 1000, default 500)

```json
← { "records": [ { "kind": "item", "data": {…} }, … ], "cursor": 4711, "more": false }
```

Records changed since `cursor` (0 for everything), oldest change first,
leaving out ones this device wrote itself. Keep pulling with the returned
cursor while `more` is true; store the cursor only once everything has been
applied.

A record may arrive before one it refers to (an item edited long ago in a
collection renamed today). Apply a whole pull in one transaction, in the
order collection, location, field, item, media.

## Media files

Files are stored by their SHA-256 (lower-case hex), which media records
carry as `sha256`.

| | |
|---|---|
| `HEAD /api/v1/blobs/<sha256>` | 200 when this library has it, else 404 |
| `PUT /api/v1/blobs/<sha256>` | the file as the body, with its `Content-Type`; 400 if the hash doesn't match; 201 (or 200 if it was there) |
| `GET /api/v1/blobs/<sha256>` | the file; supports `Range` |

## What the app does

1. **Push** the outbox: every row written locally since the last push.
   Media first upload their file (HEAD, then PUT when missing).
2. **Pull** until `more` is false and apply it in one transaction.
3. **Download** the files of media records whose file isn't on the device.

It syncs on start, when it comes back to the foreground, a few seconds after
a local change, and every few minutes while open. With no connection it
simply tries again later; nothing is lost, since the outbox is in the
database.

When a device first connects to a server (or to another account), everything
it has goes into its outbox and its cursor starts at 0, so two devices with
existing libraries merge.
