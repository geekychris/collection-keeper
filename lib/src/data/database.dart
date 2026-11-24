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

@DriftDatabase(tables: [Collections, FieldDefs, Locations, Items, Media])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// Opens the app's database file in the application support directory,
  /// next to the media directory (not Documents, which users can see).
  factory AppDatabase.open() => AppDatabase(driftDatabase(
        name: 'collection_keeper',
        native: const DriftNativeOptions(databaseDirectory: getApplicationSupportDirectory),
      ));

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}
