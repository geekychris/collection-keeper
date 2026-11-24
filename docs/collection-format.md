# Collection format, version 1

A collection exports as a zip (or a plain folder) that any program can read.
It is also how a collection moves between devices when no server is used, and
it will be the shape of a collection in backups.

```
collection.json        the collection, its fields, and the locations its items use
items/<item id>.json   one file per item, including its media list
media/<file name>      the full-size photos, videos and documents
```

A zip may hold these at its top level or inside a single folder.

## collection.json

```json
{
  "format": "collection-keeper",
  "version": 1,
  "exportedAt": "2026-11-24T18:00:00.000Z",
  "collection": { "id": "…", "name": "Retro computers", "description": "",
                  "template": "retro-computers", "currency": "USD",
                  "createdAt": 1764000000000, "updatedAt": 1764000000000, "deleted": false },
  "fields": [
    { "id": "…", "collectionId": "…", "name": "CPU", "type": "text", "options": "",
      "sortOrder": 5, "createdAt": …, "updatedAt": …, "deleted": false }
  ],
  "locations": [
    { "id": "…", "parentId": null, "name": "Warehouse", "code": "", "notes": "", … }
  ]
}
```

Field `type` is one of `text`, `longText`, `number`, `currency`, `date`,
`boolean`, `url`, `choice`. A `choice` field lists its choices in `options`,
one per line. `locations` holds every location an item uses plus their
ancestors, so the path (Warehouse › Aisle 3 › Shelf 2) survives.

## items/<id>.json

```json
{
  "id": "…", "collectionId": "…", "name": "Amiga 1200", "locationId": "…",
  "fieldValues": { "<field id>": "MC68EC020", "<field id>": 1992, "<field id>": true },
  "notes": "", "coverMediaId": "…", "lastSeenAt": null,
  "createdAt": …, "updatedAt": …, "deleted": false,
  "media": [
    { "id": "…", "itemId": "…", "kind": "photo", "fileName": "<media id>.jpg",
      "mimeType": "image/jpeg", "sizeBytes": 2483011, "sha256": "…", "caption": "",
      "sortOrder": 0, "createdAt": …, "updatedAt": …, "deleted": false }
  ]
}
```

`fieldValues` maps a field id to its value: a string for text, long text,
link and choice fields; a number for number and money fields; `yyyy-MM-dd`
for dates; `true`/`false` for yes/no fields. A field with no value is absent.

`lastSeenAt` is when a stocktake last found the item where it should be
(milliseconds, UTC), or null. It was added after the first release; readers
treat a missing `lastSeenAt` as null, so the format version stays 1.

Media `kind` is `photo`, `video` or `document`. `sha256` is the hash of the
file in `media/`.

## Rules

- Ids are random UUIDs and never change. Timestamps are milliseconds since
  the epoch, UTC.
- Importing merges by id: a record is written when it is new, or when its
  `updatedAt` is later than the local copy's; otherwise it is skipped. So
  importing the same export twice changes nothing, and importing an older
  export never overwrites newer local edits.
- Deletions are records with `"deleted": true` (tombstones), so they can
  travel like any other change. Exports currently leave deleted records out.
- A reader must refuse a `version` higher than it understands.

## Label codes

Labels printed by the app carry a QR code holding `ck:i:<id>` for an item or
`ck:l:<id>` for a location, where `<id>` is the record's UUID as 16 bytes in
URL-safe base64 without padding (22 characters), to keep the code small
enough for 12 mm labels. Readers also accept `…/i/<id>` and `…/l/<id>` at the
end of an http(s) link, a bare UUID, and a location's own `code`.
