import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

// Every table carries the same bookkeeping columns so that sync can be added
// without a schema rewrite: a random UUID primary key, created/updated times in
// milliseconds since the epoch (UTC), and a `deleted` tombstone instead of a
// hard delete, so a deletion can travel to other devices like any other edit.

mixin Tracked on Table {
  TextColumn get id => text()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('Collection')
class Collections extends Table with Tracked {
  TextColumn get name => text()();
  TextColumn get description => text().withDefault(const Constant(''))();

  /// The template the collection was created from (see templates.dart).
  TextColumn get template => text().withDefault(const Constant('general'))();

  /// ISO 4217 code used to display currency fields.
  TextColumn get currency => text().withDefault(const Constant('USD'))();
}

/// One field in a collection's schema, e.g. "CPU" or "Date acquired".
@DataClassName('FieldDef')
class FieldDefs extends Table with Tracked {
  TextColumn get collectionId => text().references(Collections, #id)();
  TextColumn get name => text()();

  /// A [FieldType] name.
  TextColumn get type => text()();

  /// Choices for a `choice` field, one per line.
  TextColumn get options => text().withDefault(const Constant(''))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

/// A place things are kept: a warehouse, an aisle, a shelf, a box. Locations
/// form a tree and are shared by all collections.
@DataClassName('Location')
class Locations extends Table with Tracked {
  TextColumn get parentId => text().nullable()();
  TextColumn get name => text()();

  /// A short code printed on labels, e.g. "A3-S2".
  TextColumn get code => text().withDefault(const Constant(''))();
  TextColumn get notes => text().withDefault(const Constant(''))();
}

@DataClassName('Item')
class Items extends Table with Tracked {
  TextColumn get collectionId => text().references(Collections, #id)();
  TextColumn get name => text()();
  TextColumn get locationId => text().nullable()();

  /// JSON object mapping a field definition id to its value: a string for
  /// text, long text, URL and choice fields, a number for number and currency
  /// fields, `yyyy-MM-dd` for dates and a bool for yes/no fields.
  TextColumn get fieldValues => text().withDefault(const Constant('{}'))();
  TextColumn get notes => text().withDefault(const Constant(''))();
  TextColumn get coverMediaId => text().nullable()();

  /// When a stocktake last found the item where it should be (ms, UTC).
  IntColumn get lastSeenAt => integer().nullable()();
}

/// A photo, video or document attached to an item. The file itself lives in
/// the media directory under `fileName`, which is relative to that directory
/// so the library survives the app container moving.
@DataClassName('MediaEntry')
class Media extends Table with Tracked {
  TextColumn get itemId => text().references(Items, #id)();

  /// A [MediaKind] name.
  TextColumn get kind => text()();
  TextColumn get fileName => text()();
  TextColumn get mimeType => text().withDefault(const Constant(''))();
  IntColumn get sizeBytes => integer().withDefault(const Constant(0))();
  TextColumn get sha256 => text().withDefault(const Constant(''))();
  TextColumn get caption => text().withDefault(const Constant(''))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

/// Rows written on this device that the sync server hasn't had yet: one row
/// per record (`kind` is the sync protocol's: collection, field, location,
/// item, media). Triggers fill it on every insert and update, so no write
/// path can forget it; pushes empty it (lib/src/sync/sync_engine.dart).
@DataClassName('OutboxEntry')
class SyncOutbox extends Table {
  TextColumn get kind => text()();
  TextColumn get id => text()();

  @override
  Set<Column> get primaryKey => {kind, id};
}

/// Holds a row only while changes pulled from a server are being applied, so
/// the outbox triggers leave those writes out.
class SyncApplying extends Table {
  IntColumn get flag => integer()();
}

/// The sync protocol's name for each synced table.
const syncKinds = {
  'collections': 'collection',
  'locations': 'location',
  'field_defs': 'field',
  'items': 'item',
  'media': 'media',
};

@DriftDatabase(tables: [Collections, FieldDefs, Locations, Items, Media, SyncOutbox, SyncApplying])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// Opens the app's database file in the application support directory,
  /// next to the media directory (not Documents, which users can see).
  factory AppDatabase.open() => AppDatabase(driftDatabase(
        name: 'collection_keeper',
        native: const DriftNativeOptions(databaseDirectory: getApplicationSupportDirectory),
      ));

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createOutboxTriggers();
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) await m.addColumn(items, items.lastSeenAt);
          if (from < 3) {
            await m.createTable(syncOutbox);
            await m.createTable(syncApplying);
            await _createOutboxTriggers();
          }
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  Future<void> _createOutboxTriggers() async {
    for (final MapEntry(key: table, value: kind) in syncKinds.entries) {
      for (final event in ['insert', 'update']) {
        await customStatement('CREATE TRIGGER IF NOT EXISTS ${table}_outbox_$event '
            'AFTER ${event.toUpperCase()} ON $table '
            'WHEN NOT EXISTS (SELECT 1 FROM sync_applying) '
            // Not INSERT OR IGNORE: inside a trigger, the conflict clause of
            // the statement that fired it (an upsert's) would override it.
            "BEGIN INSERT INTO sync_outbox (kind, id) SELECT '$kind', NEW.id "
            "WHERE NOT EXISTS (SELECT 1 FROM sync_outbox WHERE kind = '$kind' AND id = NEW.id); END");
      }
    }
  }
}
