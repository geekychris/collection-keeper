import 'dart:convert';
import 'dart:developer' as developer;

import 'package:drift/drift.dart';

import '../data/database.dart';
import '../data/model.dart';
import '../data/repository.dart';
import 'sync_api.dart';

/// Kinds in the order a pull is applied: a record after the ones it refers to.
const syncKindOrder = ['collection', 'location', 'field', 'item', 'media'];

class SyncResult {
  SyncResult(this.cursor);
  int cursor;
  int pushed = 0, stale = 0, rejected = 0, pulled = 0, downloaded = 0, uploaded = 0;

  /// Pulled records that refer to something this device doesn't have (an
  /// item whose collection never arrived); left out rather than failing the
  /// whole pull.
  int orphans = 0;

  @override
  String toString() => 'pushed $pushed ($stale stale, $rejected rejected), '
      'pulled $pulled, uploaded $uploaded, downloaded $downloaded files'
      '${orphans > 0 ? ', $orphans orphans skipped' : ''}';
}

/// One round of sync with a server (docs/sync-protocol.md): push the
/// outbox, pull everything since the cursor and apply it, then fetch the
/// media files this device lacks.
class SyncEngine {
  SyncEngine(this.repo, this.api);

  final Repository repo;
  final SyncApi api;
  AppDatabase get _db => repo.db;

  static const batchSize = 500;

  TableInfo<Table, dynamic> _table(String kind) => switch (kind) {
        'collection' => _db.collections,
        'location' => _db.locations,
        'field' => _db.fieldDefs,
        'item' => _db.items,
        'media' => _db.media,
        _ => throw ArgumentError('unknown kind $kind'),
      };

  /// Puts every record into the outbox: the first sync with a server (or
  /// another account) sends the whole library, so libraries merge.
  Future<void> fillOutbox() async {
    for (final MapEntry(key: table, value: kind) in syncKinds.entries) {
      await _db.customStatement(
          "INSERT OR IGNORE INTO sync_outbox (kind, id) SELECT '$kind', id FROM $table");
    }
  }

  Stream<int> watchOutboxCount() {
    final count = _db.syncOutbox.id.count();
    return (_db.selectOnly(_db.syncOutbox)..addColumns([count]))
        .map((row) => row.read(count) ?? 0)
        .watchSingle();
  }

  Future<SyncResult> syncOnce(int cursor) async {
    final result = SyncResult(cursor);
    await _push(result);
    await _pull(result);
    await _download(result);
    return result;
  }

  // ----------------------------------------------------------------------- push

  /// A record as the protocol carries it: the collection format's shape, so
  /// an item's field values are an object and it has no media list.
  Future<SyncRecord?> _record(String kind, String id) async {
    final table = _table(kind);
    final rows = await _db.customSelect(
      'SELECT * FROM ${table.actualTableName} WHERE id = ?',
      variables: [Variable.withString(id)],
      readsFrom: {table},
    ).get();
    if (rows.isEmpty) return null;
    final row = table.map(rows.single.data);
    final json = (row as dynamic).toJson() as Map<String, dynamic>;
    if (row is Item) json['fieldValues'] = row.values;
    return SyncRecord(kind, json);
  }

  Future<void> _push(SyncResult result) async {
    final entries = await _db.select(_db.syncOutbox).get();
    entries.sort((a, b) => syncKindOrder.indexOf(a.kind).compareTo(syncKindOrder.indexOf(b.kind)));
    for (var start = 0; start < entries.length; start += batchSize) {
      final batch = entries.sublist(start, (start + batchSize).clamp(0, entries.length));
      final records = <SyncRecord>[];
      for (final e in batch) {
        final record = await _record(e.kind, e.id);
        if (record == null) {
          await _dropFromOutbox(e.kind, e.id, null);
          continue;
        }
        if (record.kind == 'media') await _upload(record, result);
        records.add(record);
      }
      if (records.isEmpty) continue;
      final sent = {for (final r in records) '${r.kind}/${r.id}': r.updatedAt};
      final results = await api.push(records);
      await _db.transaction(() async {
        for (final r in results) {
          switch (r.status) {
            case 'accepted':
              result.pushed++;
            case 'stale':
              result.stale++;
            default:
              result.rejected++;
              developer.log('server rejected ${r.kind} ${r.id}: ${r.error}', name: 'sync');
          }
          await _dropFromOutbox(r.kind, r.id, sent['${r.kind}/${r.id}']);
        }
      });
    }
  }

  /// Removes a record from the outbox, unless it changed again after
  /// [updatedAt] was sent (then the newer version goes next time).
  Future<void> _dropFromOutbox(String kind, String id, int? updatedAt) async {
    if (updatedAt != null) {
      final now = await _db.customSelect(
        'SELECT updated_at FROM ${_table(kind).actualTableName} WHERE id = ?',
        variables: [Variable.withString(id)],
      ).getSingleOrNull();
      if (now != null && now.read<int>('updated_at') != updatedAt) return;
    }
    await (_db.delete(_db.syncOutbox)..where((o) => o.kind.equals(kind) & o.id.equals(id))).go();
  }

  /// Sends a media record's file before the record, unless the server has it.
  Future<void> _upload(SyncRecord record, SyncResult result) async {
    final m = MediaEntry.fromJson(record.data);
    if (m.deleted || m.sha256.isEmpty) return;
    final file = repo.media.fileFor(m);
    if (!await file.exists()) return; // the server rejects the record if it lacks the blob
    if (await api.hasBlob(m.sha256)) return;
    await api.putBlob(m.sha256, file, m.mimeType);
    result.uploaded++;
  }

  // ----------------------------------------------------------------------- pull

  Future<void> _pull(SyncResult result) async {
    final records = <SyncRecord>[];
    var cursor = result.cursor;
    while (true) {
      final page = await api.pull(cursor, limit: batchSize);
      records.addAll(page.records);
      cursor = page.cursor;
      if (!page.more) break;
    }
    if (records.isNotEmpty) await _apply(records, result);
    result.cursor = cursor;
  }

  Future<void> _apply(List<SyncRecord> records, SyncResult result) async {
    records.sort((a, b) => syncKindOrder.indexOf(a.kind).compareTo(syncKindOrder.indexOf(b.kind)));
    final deletedMedia = <MediaEntry>[];
    await _db.transaction(() async {
      await _db.into(_db.syncApplying).insert(SyncApplyingCompanion.insert(flag: 1));
      try {
        for (final r in records) {
          if (!syncKindOrder.contains(r.kind)) continue; // from a newer server
          final Insertable<dynamic> row;
          switch (r.kind) {
            case 'collection':
              row = Collection.fromJson(r.data);
            case 'location':
              row = Location.fromJson(r.data);
            case 'field':
              row = FieldDef.fromJson(r.data);
            case 'item':
              row = Item.fromJson({...r.data, 'fieldValues': jsonEncode(r.data['fieldValues'] ?? const {})});
            default:
              final m = MediaEntry.fromJson(r.data);
              if (m.deleted) deletedMedia.add(m);
              row = m;
          }
          try {
            if (await _upsert(_table(r.kind), row, r.id, r.updatedAt)) result.pulled++;
          } on Exception catch (e) {
            // A foreign key to a record this device never got. SQLite undoes
            // only the failed statement, so the rest still applies.
            result.orphans++;
            developer.log('skipped ${r.kind} ${r.id}: $e', name: 'sync');
          }
        }
      } finally {
        await _db.delete(_db.syncApplying).go();
      }
    });
    for (final m in deletedMedia) {
      await repo.media.remove(m);
    }
  }

  /// Last writer wins: writes [row] when it's new or newer than the local
  /// copy. The local copy now matches the server, so it leaves the outbox.
  Future<bool> _upsert(TableInfo<Table, dynamic> table, Insertable<dynamic> row, String id,
      int updatedAt) async {
    final existing = await _db.customSelect(
      'SELECT updated_at FROM ${table.actualTableName} WHERE id = ?',
      variables: [Variable.withString(id)],
    ).getSingleOrNull();
    if (existing != null && existing.read<int>('updated_at') >= updatedAt) return false;
    await _db.into(table).insertOnConflictUpdate(row);
    final kind = syncKinds[table.actualTableName]!;
    await (_db.delete(_db.syncOutbox)..where((o) => o.kind.equals(kind) & o.id.equals(id))).go();
    return true;
  }

  // ------------------------------------------------------------------- download

  /// Fetches the file of every live media record that has none on this
  /// device, so earlier failures are retried too.
  Future<void> _download(SyncResult result) async {
    final media = await (_db.select(_db.media)
          ..where((m) => m.deleted.equals(false) & m.sha256.equals('').not()))
        .get();
    for (final m in media) {
      final file = repo.media.fileFor(m);
      if (await file.exists()) continue;
      try {
        await api.getBlob(m.sha256, file);
      } on ServerError catch (e) {
        // Not on the server (yet): the device that has it will upload it.
        developer.log('no file for media ${m.id}: $e', name: 'sync');
        continue;
      }
      await repo.media.makeThumbnail(m.id, file, m.mediaKind);
      result.downloaded++;
    }
  }
}
