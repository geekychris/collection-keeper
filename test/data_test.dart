import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection_keeper/src/data/database.dart';
import 'package:collection_keeper/src/data/media_store.dart';
import 'package:collection_keeper/src/data/model.dart';
import 'package:collection_keeper/src/data/repository.dart';
import 'package:collection_keeper/src/exchange/exchange.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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
}
