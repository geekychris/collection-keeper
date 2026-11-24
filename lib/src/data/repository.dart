import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'database.dart';
import 'media_store.dart';
import 'model.dart';
import 'templates.dart';

const _uuid = Uuid();
String newId() => _uuid.v4();

class CollectionSummary {
  CollectionSummary(this.collection, this.itemCount, this.coverMediaId);
  final Collection collection;
  final int itemCount;

  /// The cover photo of the most recently changed item that has one.
  final String? coverMediaId;
}

/// All reads and writes of the catalogue. Every write stamps `updatedAt`, and
/// deletes set the `deleted` tombstone rather than removing rows; reads never
/// return deleted rows.
class Repository {
  Repository(this.db, this.media);

  final AppDatabase db;
  final MediaStore media;

  // ---------------------------------------------------------------- collections

  Stream<List<CollectionSummary>> watchCollections() {
    final query = db.customSelect(
      '''
      SELECT c.*,
        (SELECT COUNT(*) FROM items i
          WHERE i.collection_id = c.id AND i.deleted = 0) AS item_count,
        (SELECT i.cover_media_id FROM items i
          WHERE i.collection_id = c.id AND i.deleted = 0
            AND i.cover_media_id IS NOT NULL
          ORDER BY i.updated_at DESC LIMIT 1) AS cover
      FROM collections c
      WHERE c.deleted = 0
      ORDER BY c.name COLLATE NOCASE
      ''',
      readsFrom: {db.collections, db.items},
    );
    return query.watch().map((rows) => [
          for (final row in rows)
            CollectionSummary(
              db.collections.map(row.data),
              row.read<int>('item_count'),
              row.readNullable<String>('cover'),
            ),
        ]);
  }

  Stream<Collection?> watchCollection(String id) => (db.select(db.collections)
        ..where((c) => c.id.equals(id) & c.deleted.equals(false)))
      .watchSingleOrNull();

  Future<Collection> createCollection({
    required String name,
    String description = '',
    String templateId = 'general',
    String currency = 'USD',
  }) async {
    final now = nowMs();
    final template = CollectionTemplate.byId(templateId);
    final collection = Collection(
      id: newId(),
      name: name,
      description: description,
      template: template.id,
      currency: currency,
      createdAt: now,
      updatedAt: now,
      deleted: false,
    );
    await db.transaction(() async {
      await db.into(db.collections).insert(collection);
      for (final (i, f) in template.fields.indexed) {
        await db.into(db.fieldDefs).insert(FieldDefsCompanion.insert(
              id: newId(),
              collectionId: collection.id,
              name: f.name,
              type: f.type.name,
              options: Value(f.choices.join('\n')),
              sortOrder: Value(i),
              createdAt: now,
              updatedAt: now,
            ));
      }
    });
    return collection;
  }

  Future<void> updateCollection(
    String id, {
    String? name,
    String? description,
    String? currency,
  }) =>
      (db.update(db.collections)..where((c) => c.id.equals(id))).write(
        CollectionsCompanion(
          name: Value.absentIfNull(name),
          description: Value.absentIfNull(description),
          currency: Value.absentIfNull(currency),
          updatedAt: Value(nowMs()),
        ),
      );

  /// Deletes a collection with its fields, items and media, and frees the
  /// space the media files took.
  Future<void> deleteCollection(String id) async {
    final now = nowMs();
    final itemIds = await (db.selectOnly(db.items)
          ..addColumns([db.items.id])
          ..where(db.items.collectionId.equals(id)))
        .map((r) => r.read(db.items.id)!)
        .get();
    final doomed = itemIds.isEmpty
        ? <MediaEntry>[]
        : await (db.select(db.media)
              ..where((m) => m.itemId.isIn(itemIds) & m.deleted.equals(false)))
            .get();
    await db.transaction(() async {
      final tomb = (deleted: const Value(true), updatedAt: Value(now));
      await (db.update(db.collections)..where((c) => c.id.equals(id)))
          .write(CollectionsCompanion(deleted: tomb.deleted, updatedAt: tomb.updatedAt));
      await (db.update(db.fieldDefs)..where((f) => f.collectionId.equals(id)))
          .write(FieldDefsCompanion(deleted: tomb.deleted, updatedAt: tomb.updatedAt));
      await (db.update(db.items)..where((i) => i.collectionId.equals(id)))
          .write(ItemsCompanion(deleted: tomb.deleted, updatedAt: tomb.updatedAt));
      if (itemIds.isNotEmpty) {
        await (db.update(db.media)..where((m) => m.itemId.isIn(itemIds)))
            .write(MediaCompanion(deleted: tomb.deleted, updatedAt: tomb.updatedAt));
      }
    });
    for (final m in doomed) {
      await media.remove(m);
    }
  }

  // --------------------------------------------------------------------- fields

  Stream<List<FieldDef>> watchFields(String collectionId) =>
      (db.select(db.fieldDefs)
            ..where((f) =>
                f.collectionId.equals(collectionId) & f.deleted.equals(false))
            ..orderBy([(f) => OrderingTerm(expression: f.sortOrder)]))
          .watch();

  Future<List<FieldDef>> fields(String collectionId) =>
      watchFields(collectionId).first;

  Future<FieldDef> addField(
    String collectionId, {
    required String name,
    required FieldType type,
    List<String> choices = const [],
  }) async {
    final existing = await fields(collectionId);
    final now = nowMs();
    final def = FieldDef(
      id: newId(),
      collectionId: collectionId,
      name: name,
      type: type.name,
      options: choices.join('\n'),
      sortOrder: existing.isEmpty ? 0 : existing.last.sortOrder + 1,
      createdAt: now,
      updatedAt: now,
      deleted: false,
    );
    await db.into(db.fieldDefs).insert(def);
    return def;
  }

  Future<void> updateField(String id, {String? name, List<String>? choices}) =>
      (db.update(db.fieldDefs)..where((f) => f.id.equals(id))).write(
        FieldDefsCompanion(
          name: Value.absentIfNull(name),
          options: choices == null ? const Value.absent() : Value(choices.join('\n')),
          updatedAt: Value(nowMs()),
        ),
      );

  /// Stores [orderedIds] as the field order.
  Future<void> reorderFields(List<String> orderedIds) async {
    final now = nowMs();
    await db.transaction(() async {
      for (final (i, id) in orderedIds.indexed) {
        await (db.update(db.fieldDefs)..where((f) => f.id.equals(id))).write(
          FieldDefsCompanion(sortOrder: Value(i), updatedAt: Value(now)),
        );
      }
    });
  }

  /// Removes a field from the schema. Items keep the value in their stored
  /// JSON (harmless, and recoverable), but it is no longer shown.
  Future<void> deleteField(String id) =>
      (db.update(db.fieldDefs)..where((f) => f.id.equals(id))).write(
        FieldDefsCompanion(deleted: const Value(true), updatedAt: Value(nowMs())),
      );

  // ---------------------------------------------------------------------- items

  /// Items in a collection, newest change first. [search] matches the name,
  /// notes and any field value; [locationId] limits to one location.
  Stream<List<Item>> watchItems(
    String collectionId, {
    String search = '',
    String? locationId,
  }) {
    final q = db.select(db.items)
      ..where((i) => i.collectionId.equals(collectionId) & i.deleted.equals(false));
    final term = search.trim();
    if (term.isNotEmpty) {
      final like = '%${term.replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
      q.where((i) =>
          i.name.like(like, escapeChar: r'\') |
          i.notes.like(like, escapeChar: r'\') |
          i.fieldValues.like(like, escapeChar: r'\'));
    }
    if (locationId != null) q.where((i) => i.locationId.equals(locationId));
    q.orderBy([(i) => OrderingTerm.desc(i.updatedAt)]);
    return q.watch();
  }

  Stream<Item?> watchItem(String id) =>
      (db.select(db.items)..where((i) => i.id.equals(id) & i.deleted.equals(false)))
          .watchSingleOrNull();

  Future<Item> createItem(
    String collectionId, {
    required String name,
    String? locationId,
    Map<String, Object?> values = const {},
    String notes = '',
  }) async {
    final now = nowMs();
    final item = Item(
      id: newId(),
      collectionId: collectionId,
      name: name,
      locationId: locationId,
      fieldValues: _encodeValues(values),
      notes: notes,
      coverMediaId: null,
      createdAt: now,
      updatedAt: now,
      deleted: false,
    );
    await db.into(db.items).insert(item);
    return item;
  }

  Future<void> updateItem(
    String id, {
    String? name,
    Value<String?> locationId = const Value.absent(),
    Map<String, Object?>? values,
    String? notes,
  }) =>
      (db.update(db.items)..where((i) => i.id.equals(id))).write(
        ItemsCompanion(
          name: Value.absentIfNull(name),
          locationId: locationId,
          fieldValues: values == null ? const Value.absent() : Value(_encodeValues(values)),
          notes: Value.absentIfNull(notes),
          updatedAt: Value(nowMs()),
        ),
      );

  Future<void> deleteItem(String id) async {
    final doomed = await mediaFor(id);
    final now = nowMs();
    await db.transaction(() async {
      await (db.update(db.items)..where((i) => i.id.equals(id))).write(
        ItemsCompanion(deleted: const Value(true), updatedAt: Value(now)),
      );
      await (db.update(db.media)..where((m) => m.itemId.equals(id))).write(
        MediaCompanion(deleted: const Value(true), updatedAt: Value(now)),
      );
    });
    for (final m in doomed) {
      await media.remove(m);
    }
  }

  String _encodeValues(Map<String, Object?> values) =>
      jsonEncode({for (final e in values.entries) if (e.value != null) e.key: e.value});

  // ---------------------------------------------------------------------- media

  Stream<List<MediaEntry>> watchMedia(String itemId) => (db.select(db.media)
        ..where((m) => m.itemId.equals(itemId) & m.deleted.equals(false))
        ..orderBy([
          (m) => OrderingTerm(expression: m.sortOrder),
          (m) => OrderingTerm(expression: m.createdAt),
        ]))
      .watch();

  Future<List<MediaEntry>> mediaFor(String itemId) => watchMedia(itemId).first;

  /// Copies [files] into the media store and attaches them to the item. The
  /// first photo becomes the item's cover if it has none.
  Future<List<MediaEntry>> addMedia(String itemId, List<File> files) async {
    final existing = await mediaFor(itemId);
    var order = existing.isEmpty ? 0 : existing.last.sortOrder + 1;
    final added = <MediaEntry>[];
    for (final file in files) {
      final id = newId();
      final kind = MediaKind.fromExtension(file.path.split('.').last);
      final stored = await media.add(file, id, kind);
      final now = nowMs();
      final entry = MediaEntry(
        id: id,
        itemId: itemId,
        kind: kind.name,
        fileName: stored.fileName,
        mimeType: _mimeFor(stored.fileName),
        sizeBytes: stored.sizeBytes,
        sha256: stored.sha256,
        caption: '',
        sortOrder: order++,
        createdAt: now,
        updatedAt: now,
        deleted: false,
      );
      await db.into(db.media).insert(entry);
      added.add(entry);
    }
    final item = await watchItem(itemId).first;
    if (item != null && item.coverMediaId == null) {
      final firstPhoto = added.where((m) => m.mediaKind == MediaKind.photo).firstOrNull;
      if (firstPhoto != null) await setCover(itemId, firstPhoto.id);
    } else if (added.isNotEmpty) {
      await _touchItem(itemId);
    }
    return added;
  }

  Future<void> updateCaption(String mediaId, String caption) =>
      (db.update(db.media)..where((m) => m.id.equals(mediaId))).write(
        MediaCompanion(caption: Value(caption), updatedAt: Value(nowMs())),
      );

  Future<void> setCover(String itemId, String? mediaId) =>
      (db.update(db.items)..where((i) => i.id.equals(itemId))).write(
        ItemsCompanion(coverMediaId: Value(mediaId), updatedAt: Value(nowMs())),
      );

  Future<void> deleteMedia(MediaEntry entry) async {
    await (db.update(db.media)..where((m) => m.id.equals(entry.id))).write(
      MediaCompanion(deleted: const Value(true), updatedAt: Value(nowMs())),
    );
    final item = await watchItem(entry.itemId).first;
    if (item?.coverMediaId == entry.id) {
      final next = (await mediaFor(entry.itemId))
          .where((m) => m.mediaKind == MediaKind.photo)
          .firstOrNull;
      await setCover(entry.itemId, next?.id);
    } else {
      await _touchItem(entry.itemId);
    }
    await media.remove(entry);
  }

  Future<void> _touchItem(String itemId) =>
      (db.update(db.items)..where((i) => i.id.equals(itemId)))
          .write(ItemsCompanion(updatedAt: Value(nowMs())));

  // ------------------------------------------------------------------ locations

  Stream<List<Location>> watchLocations() => (db.select(db.locations)
        ..where((l) => l.deleted.equals(false))
        ..orderBy([(l) => OrderingTerm(expression: l.name, mode: OrderingMode.asc)]))
      .watch();

  Future<Location> addLocation({
    required String name,
    String? parentId,
    String code = '',
    String notes = '',
  }) async {
    final now = nowMs();
    final location = Location(
      id: newId(),
      parentId: parentId,
      name: name,
      code: code,
      notes: notes,
      createdAt: now,
      updatedAt: now,
      deleted: false,
    );
    await db.into(db.locations).insert(location);
    return location;
  }

  Future<void> updateLocation(
    String id, {
    String? name,
    String? code,
    String? notes,
    Value<String?> parentId = const Value.absent(),
  }) =>
      (db.update(db.locations)..where((l) => l.id.equals(id))).write(
        LocationsCompanion(
          name: Value.absentIfNull(name),
          code: Value.absentIfNull(code),
          notes: Value.absentIfNull(notes),
          parentId: parentId,
          updatedAt: Value(nowMs()),
        ),
      );

  /// Deletes a location. Its children move up to its parent, and items kept
  /// there move to the parent too (or to no location).
  Future<void> deleteLocation(String id) async {
    final location = await (db.select(db.locations)..where((l) => l.id.equals(id)))
        .getSingleOrNull();
    if (location == null) return;
    final now = nowMs();
    await db.transaction(() async {
      await (db.update(db.locations)..where((l) => l.parentId.equals(id))).write(
        LocationsCompanion(parentId: Value(location.parentId), updatedAt: Value(now)),
      );
      await (db.update(db.items)..where((i) => i.locationId.equals(id))).write(
        ItemsCompanion(locationId: Value(location.parentId), updatedAt: Value(now)),
      );
      await (db.update(db.locations)..where((l) => l.id.equals(id))).write(
        LocationsCompanion(deleted: const Value(true), updatedAt: Value(now)),
      );
    });
  }
}

String _mimeFor(String fileName) {
  final ext = fileName.split('.').last.toLowerCase();
  return const {
        'jpg': 'image/jpeg',
        'jpeg': 'image/jpeg',
        'png': 'image/png',
        'heic': 'image/heic',
        'heif': 'image/heif',
        'webp': 'image/webp',
        'gif': 'image/gif',
        'mov': 'video/quicktime',
        'mp4': 'video/mp4',
        'm4v': 'video/x-m4v',
        'pdf': 'application/pdf',
      }[ext] ??
      'application/octet-stream';
}

/// "Warehouse › Aisle 3 › Shelf 2" for a location, using [all] to walk up.
String locationPath(Location location, List<Location> all) {
  final byId = {for (final l in all) l.id: l};
  final parts = <String>[location.name];
  var parent = location.parentId == null ? null : byId[location.parentId];
  final seen = {location.id};
  while (parent != null && seen.add(parent.id)) {
    parts.insert(0, parent.name);
    parent = parent.parentId == null ? null : byId[parent.parentId];
  }
  return parts.join(' › ');
}
