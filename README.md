# Collection Keeper

Catalogue collections of things (retro computers, software, stamps, vehicles,
anything) with full-size photos and videos, your own fields per collection,
and where everything is kept. Runs on **macOS, iOS, Android and Windows** from
one Flutter codebase.

It is local-first: every device keeps the whole collection and works with no
connection, which matters when you are walking around a warehouse. An
optional self-hosted server for syncing devices and sharing collections is
planned (see the roadmap).

This replaces [swift_artifact_manager](https://github.com/geekychris/swift_artifact_manager),
an Apple-only SwiftUI prototype.

## What works today

- Collections created from templates (General, Retro computers, Software and
  games, Vehicles, Stamps and coins), with fields you can add, rename, reorder
  and remove. Field types: text, long text, number, money, date, yes/no, link,
  choice.
- Items with field values, notes and a location; search across names, notes
  and every field; filter by location.
- Photos, videos and documents at full size, with thumbnails, captions and a
  cover photo. Camera and photo library on phones; files on every platform.
  Photos open full screen with zoom; videos and documents open in the
  platform's viewer.
- Locations as a tree (Warehouse › Aisle 3 › Shelf 2) shared by all
  collections.
- Export a collection to a zip and import it on another device, merging by
  record (newer wins). The format is documented in
  [docs/collection-format.md](docs/collection-format.md).
- Phone layout, and side-by-side list and detail on tablets and desktops.

## Roadmap

1. **Done:** local app (above).
2. **Phone mode for walking the collection:** QR labels for items and
   locations (printed on a NIIMBOT label printer), scan to open, quick capture
   (photo first, details later), move an item by scanning it and then a shelf,
   stocktake of a shelf.
3. **Optional sync server:** a Go service with Postgres and object storage,
   deployed to the home lab (mp2) through cloud-stack and signed in through
   the lab's passkey login (OpenID Connect at `auth.<zone>`). Devices sync
   edits and media in the background; anyone can point the app at their own
   server instead.
4. **Sharing** collections with other people (owner, editor, viewer; public
   read-only links), then maintenance and repair logs, value history, and
   reports.

## Building

Needs Flutter 3.50 or later (`brew install --cask flutter`).

```sh
flutter pub get
dart run build_runner build   # after changing lib/src/data/database.dart
flutter test
flutter run -d macos          # or an iOS simulator, Android device, windows
```

- **iOS:** set your team in Xcode (`ios/Runner.xcworkspace`) to run on a device.
- **Android:** needs the Android SDK command-line tools and accepted licences
  (`flutter doctor --android-licenses`).
- **Windows:** build on a Windows machine with Visual Studio's C++ workload:
  `flutter build windows`.

## Layout

```
lib/main.dart                     app entry: opens the database and media store
lib/src/data/database.dart        tables (drift / SQLite); database.g.dart is generated
lib/src/data/repository.dart      every read and write; soft deletes and timestamps
lib/src/data/media_store.dart     full-size files and thumbnails on disk
lib/src/data/templates.dart       starting fields for each kind of collection
lib/src/exchange/exchange.dart    export / import of the collection format
lib/src/app/                      providers and platform helpers (camera, files, sharing)
lib/src/ui/                       screens
test/                             data, export/import and widget tests
```

Data lives in the app's Application Support directory: `collection_keeper.sqlite`
and `media/` (full-size files, plus `media/thumbs/`).
