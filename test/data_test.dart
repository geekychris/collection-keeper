import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection_keeper/src/data/codes.dart';
import 'package:collection_keeper/src/data/database.dart';
import 'package:collection_keeper/src/data/media_store.dart';
import 'package:collection_keeper/src/data/model.dart';
import 'package:collection_keeper/src/data/repository.dart';
import 'package:collection_keeper/src/exchange/exchange.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

Future<Uint8List?> fakeThumbnail(File source, MediaKind kind) async =>
    kind == MediaKind.photo ? Uint8List.fromList([1, 2, 3]) : null;

class Harness {
  Harness(this.dir)
      : db = AppDatabase(NativeDatabase.memory()),
        store = MediaStore(Directory(p.join(dir.path, 'media'))..createSync(recursive: true),
            thumbnailer: fakeThumbnail) {
    repo = Repository(db, store);
  }
  final Directory dir;
  final AppDatabase db;
  final MediaStore store;
  late final Repository repo;
}

void main() {
  // Each test opens two separate in-memory databases on purpose.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  late Harness h;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ck-test-');
    h = Harness(Directory(p.join(tmp.path, 'a')));
  });

  tearDown(() async {
    await h.db.close();
    await tmp.delete(recursive: true);
  });

  Future<File> sampleFile(String name, String content) async {
    final f = File(p.join(tmp.path, 'src', name));
    await f.parent.create(recursive: true);
    return f.writeAsString(content);
  }

  test('a collection starts with its template fields, in order', () async {
    final c = await h.repo.createCollection(name: 'Computers', templateId: 'retro-computers');
    final fields = await h.repo.fields(c.id);
    expect(fields.first.name, 'Manufacturer');
    expect(fields.map((f) => f.name), contains('Working status'));
    expect(fields.firstWhere((f) => f.name == 'Working status').choices, contains('Untested'));
    expect([for (final f in fields) f.sortOrder], List.generate(fields.length, (i) => i));
  });

  test('items: values, search and soft delete', () async {
    final c = await h.repo.createCollection(name: 'Computers', templateId: 'retro-computers');
    final cpu = (await h.repo.fields(c.id)).firstWhere((f) => f.name == 'CPU');
    await h.repo.createItem(c.id, name: 'Amiga 1200', values: {cpu.id: 'MC68EC020'});
    final atari = await h.repo.createItem(c.id, name: 'Atari 800XL', values: {cpu.id: '6502C'});

    expect((await h.repo.watchItems(c.id, search: '68ec').first).single.name, 'Amiga 1200');
    expect((await h.repo.watchItems(c.id, search: 'atari').first).single.id, atari.id);
    expect(await h.repo.watchItems(c.id, search: '%').first, isEmpty,
        reason: 'LIKE wildcards in the search are literal');

    await h.repo.deleteItem(atari.id);
    expect((await h.repo.watchItems(c.id).first).map((i) => i.name), ['Amiga 1200']);
    final summary = (await h.repo.watchCollections().first).single;
    expect(summary.itemCount, 1);
  });

  test('media keep the full file, and the first photo becomes the cover', () async {
    final c = await h.repo.createCollection(name: 'C');
    final item = await h.repo.createItem(c.id, name: 'Thing');
    final photo = await sampleFile('front.JPG', 'full size photo bytes');
    final video = await sampleFile('demo.mov', 'video bytes');

    final added = await h.repo.addMedia(item.id, [video, photo]);
    expect(added.map((m) => m.mediaKind), [MediaKind.video, MediaKind.photo]);
    final stored = h.store.fileFor(added[1]);
    expect(await stored.readAsString(), 'full size photo bytes');
    expect(p.basename(stored.path), '${added[1].id}.jpg');
    expect(added[1].sha256, hasLength(64));
    expect(await h.store.thumbnailFor(added[1].id).exists(), isTrue);
    expect(await h.store.thumbnailFor(added[0].id).exists(), isFalse);
    expect((await h.repo.watchItem(item.id).first)!.coverMediaId, added[1].id);

    await h.repo.deleteMedia(added[1]);
    expect(await stored.exists(), isFalse);
    expect((await h.repo.watchItem(item.id).first)!.coverMediaId, isNull);
  });

  test('deleting a location moves its children and items to its parent', () async {
    final c = await h.repo.createCollection(name: 'C');
    final warehouse = await h.repo.addLocation(name: 'Warehouse');
    final aisle = await h.repo.addLocation(name: 'Aisle 3', parentId: warehouse.id);
    final shelf = await h.repo.addLocation(name: 'Shelf 2', parentId: aisle.id);
    final item = await h.repo.createItem(c.id, name: 'Box', locationId: aisle.id);

    final all = await h.repo.watchLocations().first;
    expect(locationPath(all.firstWhere((l) => l.id == shelf.id), all),
        'Warehouse › Aisle 3 › Shelf 2');

    await h.repo.deleteLocation(aisle.id);
    final after = await h.repo.watchLocations().first;
    expect(after.map((l) => l.name), unorderedEquals(['Warehouse', 'Shelf 2']));
    expect(after.firstWhere((l) => l.id == shelf.id).parentId, warehouse.id);
    expect((await h.repo.watchItem(item.id).first)!.locationId, warehouse.id);
  });

  test('export then import into an empty library reproduces the collection', () async {
    final c = await h.repo.createCollection(name: 'My Computers!', templateId: 'retro-computers');
    final fields = await h.repo.fields(c.id);
    final year = fields.firstWhere((f) => f.name == 'Year');
    final recapped = fields.firstWhere((f) => f.name == 'Recapped');
    final shelf = await h.repo.addLocation(
        name: 'Shelf 2', parentId: (await h.repo.addLocation(name: 'Warehouse')).id);
    final item = await h.repo.createItem(c.id,
        name: 'Amiga 1200', locationId: shelf.id, values: {year.id: 1992, recapped.id: true});
    await h.repo.addMedia(item.id, [await sampleFile('a.jpg', 'photo')]);

    final zip = await Exchange(h.repo).exportZip(c.id, tmp);
    expect(p.basename(zip.path), 'My-Computers.zip');

    final other = Harness(Directory(p.join(tmp.path, 'b')));
    addTearDown(other.db.close);
    final result = await Exchange(other.repo).importZip(zip);
    expect(result.items, 1);
    expect(result.media, 1);
    expect(result.locations, 2);

    final imported = (await other.repo.watchItems(c.id).first).single;
    expect(imported.values, {year.id: 1992, recapped.id: true});
    final media = (await other.repo.mediaFor(imported.id)).single;
    expect(await other.store.fileFor(media).readAsString(), 'photo');
    expect(await other.store.thumbnailFor(media.id).exists(), isTrue);
    final locs = await other.repo.watchLocations().first;
    expect(locationPath(locs.firstWhere((l) => l.id == imported.locationId), locs),
        'Warehouse › Shelf 2');
  });

  test('import keeps the newer copy of each record', () async {
    final c = await h.repo.createCollection(name: 'C');
    final item = await h.repo.createItem(c.id, name: 'Original');
    final folder = await Exchange(h.repo).exportFolder(c.id, tmp);

    // Edit locally after the export: the export is now older and must lose.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await h.repo.updateItem(item.id, name: 'Edited here');
    var result = await Exchange(h.repo).importFolder(folder);
    expect(result.items, 0);
    expect((await h.repo.watchItem(item.id).first)!.name, 'Edited here');

    // A newer edit in the export wins.
    final file = File(p.join(folder.path, 'items', '${item.id}.json'));
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    json['name'] = 'Edited elsewhere';
    json['updatedAt'] = nowMs() + 1000;
    await file.writeAsString(jsonEncode(json));
    result = await Exchange(h.repo).importFolder(folder);
    expect(result.items, 1);
    expect((await h.repo.watchItem(item.id).first)!.name, 'Edited elsewhere');
  });

  test('import refuses something that is not a collection', () async {
    final dir = await Directory(p.join(tmp.path, 'junk')).create();
    await File(p.join(dir.path, 'collection.json')).writeAsString('{"format":"other"}');
    expect(() => Exchange(h.repo).importFolder(dir), throwsFormatException);
  });

  test('updateItem can clear the location', () async {
    final c = await h.repo.createCollection(name: 'C');
    final l = await h.repo.addLocation(name: 'Shelf');
    final item = await h.repo.createItem(c.id, name: 'X', locationId: l.id);
    await h.repo.updateItem(item.id, locationId: const Value(null));
    expect((await h.repo.watchItem(item.id).first)!.locationId, isNull);
  });

  test('codes resolve to items and locations, including a location\'s own code', () async {
    final c = await h.repo.createCollection(name: 'C');
    final shelf = await h.repo.addLocation(name: 'Shelf 2', code: 'A3-S2');
    final item = await h.repo.createItem(c.id, name: 'Amiga', locationId: shelf.id);

    expect(await h.repo.resolveCode(labelCode(CodeKind.item, item.id)), (kind: CodeKind.item, id: item.id));
    expect(await h.repo.resolveCode(labelCode(CodeKind.location, shelf.id)),
        (kind: CodeKind.location, id: shelf.id));
    expect(await h.repo.resolveCode(' a3-s2 '), (kind: CodeKind.location, id: shelf.id));
    expect(await h.repo.resolveCode(item.id.toUpperCase()), (kind: CodeKind.item, id: item.id));
    expect(await h.repo.resolveCode('nothing'), isNull);

    await h.repo.deleteItem(item.id);
    expect(await h.repo.resolveCode(labelCode(CodeKind.item, item.id)), isNull,
        reason: 'a deleted item\'s label no longer opens it');
  });

  test('items at a place and the places inside it, from every collection', () async {
    final computers = await h.repo.createCollection(name: 'Computers');
    final software = await h.repo.createCollection(name: 'Software');
    final aisle = await h.repo.addLocation(name: 'Aisle 3');
    final shelf = await h.repo.addLocation(name: 'Shelf 2', parentId: aisle.id);
    final other = await h.repo.addLocation(name: 'Elsewhere');
    await h.repo.createItem(computers.id, name: 'Amiga', locationId: shelf.id);
    await h.repo.createItem(software.id, name: 'Deluxe Paint', locationId: aisle.id);
    await h.repo.createItem(software.id, name: 'Elite', locationId: other.id);

    final all = await h.repo.watchLocations().first;
    final inside = locationAndDescendants(aisle.id, all);
    expect(inside, {aisle.id, shelf.id});
    expect((await h.repo.watchItemsAt(inside).first).map((i) => i.name), ['Amiga', 'Deluxe Paint']);
    expect((await h.repo.watchItemsAt({aisle.id}).first).map((i) => i.name), ['Deluxe Paint']);
  });

  test('stocktake stamps, moving, and undoing a stamp', () async {
    final c = await h.repo.createCollection(name: 'C');
    final shelf = await h.repo.addLocation(name: 'Shelf');
    final item = await h.repo.createItem(c.id, name: 'Box');
    expect(item.lastSeenAt, isNull);

    await h.repo.markSeen([item.id], at: 1000);
    expect((await h.repo.itemById(item.id))!.lastSeenAt, 1000);
    await h.repo.moveItem(item.id, shelf.id);
    final moved = (await h.repo.itemById(item.id))!;
    expect(moved.locationId, shelf.id);
    expect(moved.lastSeenAt, 1000);
    await h.repo.setLastSeen(item.id, null);
    expect((await h.repo.itemById(item.id))!.lastSeenAt, isNull);
  });

  test('the last-seen date travels in exports', () async {
    final c = await h.repo.createCollection(name: 'C');
    final item = await h.repo.createItem(c.id, name: 'Box');
    await h.repo.markSeen([item.id], at: 1234);
    final folder = await Exchange(h.repo).exportFolder(c.id, tmp);
    final other = Harness(Directory(p.join(tmp.path, 'b')));
    addTearDown(other.db.close);
    await Exchange(other.repo).importFolder(folder);
    expect((await other.repo.itemById(item.id))!.lastSeenAt, 1234);
  });

  test('a version 1 database gains the last-seen column and keeps its items', () async {
    final file = File(p.join(tmp.path, 'v1.sqlite'));
    // Make a current database, then turn it back into version 1.
    final v2 = AppDatabase(NativeDatabase(file));
    final repo = Repository(v2, h.store);
    final c = await repo.createCollection(name: 'Old');
    await repo.createItem(c.id, name: 'Kept');
    await v2.close();
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('ALTER TABLE items DROP COLUMN last_seen_at');
    raw.execute('PRAGMA user_version = 1');
    raw.close();

    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    final items = await Repository(upgraded, h.store).watchItems(c.id).first;
    expect(items.single.name, 'Kept');
    expect(items.single.lastSeenAt, isNull);
    await Repository(upgraded, h.store).markSeen([items.single.id], at: 5);
    expect((await upgraded.select(upgraded.items).getSingle()).lastSeenAt, 5);
  });
}
