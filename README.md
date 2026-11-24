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

### Walking round the collection (phones)

**Walk round** (the scanner button on the home screen) gathers the tools for
working among the shelves, all offline:

- **Find:** scan an item's or a location's label to open it.
- **Put away:** scan a shelf or box, then each thing you put there; each scan
  moves the item, with undo.
- **Stocktake:** scan a shelf, then everything on it. Shows what's still
  missing, stamps each thing found with today's date ("checked today"), and
  offers to move things that turn up but belong elsewhere. Things without a
  label can be ticked by hand.
- **Quick capture:** pick the collection and place once, then photograph
  thing after thing; each photo becomes a new item to name later.

Scanning uses the camera on iOS, Android and macOS. Every scan screen also
has a field for typing a code, which is also how a USB or Bluetooth barcode
scanner (one that types like a keyboard) works, including on Windows.
Locations' own label codes (e.g. `A3-S2`) can be typed too.

### Labels

Items and locations get labels with a QR code, the name, and where the thing
is (or, for a location, its code and the places it's inside). Print one from
an item or location, all of a collection's (filtered) items from its menu, or
every location from the Locations screen.

- **NIIMBOT printers** over Bluetooth, on every platform: the app finds the
  printer, reads its model, battery and loaded roll, and prints in 1-bit at
  the printer's resolution. The protocol is ported from parts-inventory-apple
  (itself from [NiimBlue](https://github.com/MultiMote/niimbluelib)) and
  covers the D11/D110/D101/H1 family, B1, B21, B3S and the newer models.
- **Any other printer** through a PDF: one label per page for label printers
  with a system driver (Brother, Dymo, Zebra), or a grid on A4 or Letter
  sheets. Print directly or share the PDF.

## Roadmap

1. **Done:** local app (above).
2. **Done:** walk-round tools and labels (above). Not yet tried against a
   real NIIMBOT printer: the protocol is tested byte for byte against dumps
   from real printers and a simulated one.
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
  `flutter build windows`. There is no camera scanning on Windows (type codes
  or use a keyboard-style barcode scanner); Bluetooth printing needs Windows
  10 or later.
- **Permissions:** camera (scanning and photos), photo library, and Bluetooth
  (the label printer) are declared for iOS, Android and macOS.

## Layout

```
lib/main.dart                     app entry: opens the database and media store
lib/src/data/database.dart        tables (drift / SQLite); database.g.dart is generated
lib/src/data/repository.dart      every read and write; soft deletes and timestamps
lib/src/data/media_store.dart     full-size files and thumbnails on disk
lib/src/data/templates.dart       starting fields for each kind of collection
lib/src/data/codes.dart           what a label's QR code holds
lib/src/exchange/exchange.dart    export / import of the collection format
lib/src/labels/niimbot.dart       NIIMBOT protocol: packets, models, image encoding, print jobs
lib/src/labels/niimbot_session.dart  request/reply exchange, handshake, running a print job
lib/src/labels/niimbot_ble.dart   Bluetooth link (universal_ble) and the app's printer controller
lib/src/labels/label.dart         label sizes, layout and 1-bit rendering
lib/src/labels/pdf_labels.dart    labels as a PDF for other printers
lib/src/app/                      providers, settings and platform helpers (camera, files, sharing)
lib/src/ui/                       screens (walk_round.dart: find, put away, stocktake, quick capture)
assets/fonts/                     Noto Sans for PDF labels (SIL Open Font Licence, OFL.txt)
test/                             data, export/import, protocol, printing and widget tests
```

Data lives in the app's Application Support directory: `collection_keeper.sqlite`
and `media/` (full-size files, plus `media/thumbs/`).
