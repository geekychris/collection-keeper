import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../data/database.dart';
import '../data/model.dart';
import '../data/repository.dart';

/// The open collection format (docs/collection-format.md): a zip, or a plain
/// folder, holding
///
///     collection.json       format marker, the collection, its fields and the
///                           locations its items use (with their ancestors)
///     items/<id>.json       one file per item, with its media list
///     media/<file name>     the full-size media files
///
/// Rows keep their ids and timestamps, so importing merges: a row is written
/// when it is new or newer than the local copy, and skipped otherwise.
const formatName = 'collection-keeper';
const formatVersion = 1;

class ImportResult {
  int collections = 0, fields = 0, locations = 0, items = 0, media = 0, skipped = 0;

  @override
  String toString() =>
      '$items items, $media media files, $fields fields and $locations locations '
      'imported${skipped > 0 ? ' ($skipped older or unchanged records skipped)' : ''}';
}

class Exchange {
  Exchange(this.repo);
  final Repository repo;
  AppDatabase get _db => repo.db;

  /// Writes the collection as a folder under [parent] and returns it.
  Future<Directory> exportFolder(String collectionId, Directory parent) async {
    final c = await (_db.select(_db.collections)..where((t) => t.id.equals(collectionId)))
        .getSingle();
    final dir = Directory(p.join(parent.path, _safeName(c.name)));
    if (await dir.exists()) await dir.delete(recursive: true);
    await Directory(p.join(dir.path, 'items')).create(recursive: true);
    await Directory(p.join(dir.path, 'media')).create(recursive: true);

    final fields = await (_db.select(_db.fieldDefs)
          ..where((f) => f.collectionId.equals(collectionId) & f.deleted.equals(false))
          ..orderBy([(f) => OrderingTerm(expression: f.sortOrder)]))
        .get();
    final items = await (_db.select(_db.items)
          ..where((i) => i.collectionId.equals(collectionId) & i.deleted.equals(false)))
        .get();

    final allLocations = await _db.select(_db.locations).get();
    final byId = {for (final l in allLocations) l.id: l};
    final used = <String, Location>{};
    for (final item in items) {
      var id = item.locationId;
      while (id != null && byId[id] != null && !used.containsKey(id)) {
        used[id] = byId[id]!;
        id = byId[id]!.parentId;
      }
    }

    await _writeJson(File(p.join(dir.path, 'collection.json')), {
      'format': formatName,
      'version': formatVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'collection': c.toJson(),
      'fields': [for (final f in fields) f.toJson()],
      'locations': [for (final l in used.values) l.toJson()],
    });

    for (final item in items) {
      final media = await repo.mediaFor(item.id);
      final json = item.toJson();
      // Values are stored as a JSON string; export them as a real object so
      // the files are pleasant to read and diff.
      json['fieldValues'] = item.values;
      json['media'] = [for (final m in media) m.toJson()];
      await _writeJson(File(p.join(dir.path, 'items', '${item.id}.json')), json);
      for (final m in media) {
        final src = repo.media.fileFor(m);
        if (await src.exists()) {
          await src.copy(p.join(dir.path, 'media', m.fileName));
        }
      }
    }
    return dir;
  }

  /// Exports the collection as `<name>.zip` in [parent] and returns the file.
  /// Media are streamed from disk, so large videos don't need to fit in memory.
  Future<File> exportZip(String collectionId, Directory parent) async {
    final staging = await Directory.systemTemp.createTemp('ck-export-');
    try {
      final folder = await exportFolder(collectionId, staging);
      final zip = File(p.join(parent.path, '${p.basename(folder.path)}.zip'));
      final encoder = ZipFileEncoder()..create(zip.path);
      await encoder.addDirectory(folder, includeDirName: false);
      await encoder.close();
      return zip;
    } finally {
      await staging.delete(recursive: true);
    }
  }

  Future<ImportResult> importZip(File zip) async {
    final staging = await Directory.systemTemp.createTemp('ck-import-');
    try {
      await extractFileToDisk(zip.path, staging.path);
      return await importFolder(await _findRoot(staging));
    } finally {
      await staging.delete(recursive: true);
    }
  }

  Future<ImportResult> importFolder(Directory dir) async {
    final manifestFile = File(p.join(dir.path, 'collection.json'));
    if (!await manifestFile.exists()) {
      throw const FormatException('Not a collection: collection.json is missing');
    }
    final manifest = jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    if (manifest['format'] != formatName) {
      throw const FormatException('Not a collection-keeper export');
    }
    final version = manifest['version'] as int? ?? 0;
    if (version > formatVersion) {
      throw FormatException(
          'Made by a newer version of the app (format $version); please update');
    }

    final result = ImportResult();
    final itemFiles = await Directory(p.join(dir.path, 'items'))
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .cast<File>()
        .toList();
    final itemJson = [
      for (final f in itemFiles) jsonDecode(await f.readAsString()) as Map<String, dynamic>,
    ];
    final newMedia = <MediaEntry>[];

    await _db.transaction(() async {
      if (await _upsert(_db.collections, Collection.fromJson(manifest['collection']))) {
        result.collections++;
      } else {
        result.skipped++;
      }
      for (final f in manifest['fields'] as List) {
        await _upsert(_db.fieldDefs, FieldDef.fromJson(f)) ? result.fields++ : result.skipped++;
      }
      for (final l in manifest['locations'] as List) {
        await _upsert(_db.locations, Location.fromJson(l))
            ? result.locations++
            : result.skipped++;
      }
      for (final json in itemJson) {
        final mediaJson = (json.remove('media') as List?) ?? const [];
        json['fieldValues'] = jsonEncode(json['fieldValues'] ?? const {});
        await _upsert(_db.items, Item.fromJson(json)) ? result.items++ : result.skipped++;
        for (final m in mediaJson) {
          final entry = MediaEntry.fromJson(m);
          if (await _upsert(_db.media, entry)) newMedia.add(entry);
        }
      }
    });

    for (final m in newMedia) {
      final src = File(p.join(dir.path, 'media', m.fileName));
      final dest = repo.media.fileFor(m);
      if (m.deleted) {
        await repo.media.remove(m);
      } else if (await src.exists() && !await dest.exists()) {
        await dest.parent.create(recursive: true);
        await src.copy(dest.path);
        await repo.media.makeThumbnail(m.id, dest, m.mediaKind);
        result.media++;
      }
    }
    return result;
  }

  /// Inserts [row], or replaces the local row with the same id when [row] is
  /// newer. Returns whether anything was written.
  Future<bool> _upsert<T extends Table, D extends DataClass>(
    TableInfo<T, D> table,
    Insertable<D> row,
  ) async {
    final incoming = row as dynamic;
    final String id = incoming.id;
    final int updatedAt = incoming.updatedAt;
    final existing = await _db.customSelect(
      'SELECT updated_at FROM ${table.actualTableName} WHERE id = ?',
      variables: [Variable.withString(id)],
    ).getSingleOrNull();
    if (existing != null && existing.read<int>('updated_at') >= updatedAt) return false;
    await _db.into(table).insertOnConflictUpdate(row);
    return true;
  }

  Future<void> _writeJson(File file, Object json) =>
      file.writeAsString(const JsonEncoder.withIndent('  ').convert(json));

  /// A zip may hold the collection at its top level or inside one folder.
  Future<Directory> _findRoot(Directory dir) async {
    if (await File(p.join(dir.path, 'collection.json')).exists()) return dir;
    final subdirs = await dir.list().where((e) => e is Directory).cast<Directory>().toList();
    for (final d in subdirs) {
      if (await File(p.join(d.path, 'collection.json')).exists()) return d;
    }
    return dir;
  }
}

String _safeName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[^\w\s\-.]'), '').trim().replaceAll(RegExp(r'\s+'), '-');
  return cleaned.isEmpty ? 'collection' : cleaned;
}
