import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection_keeper/src/app/settings.dart';
import 'package:collection_keeper/src/data/database.dart';
import 'package:collection_keeper/src/data/media_store.dart';
import 'package:collection_keeper/src/data/model.dart';
import 'package:collection_keeper/src/data/repository.dart';
import 'package:collection_keeper/src/sync/sync_api.dart';
import 'package:collection_keeper/src/sync/sync_controller.dart';
import 'package:collection_keeper/src/sync/sync_engine.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// A server that follows docs/sync-protocol.md, in memory: last writer wins,
/// a change sequence for cursors, a device's own writes left out of its
/// pulls, and blobs by SHA-256.
class FakeServer {
  int seq = 0;
  final records = <String, ({String kind, Map<String, dynamic> data, int seq, String device})>{};
  final blobs = <String, Uint8List>{};
  bool refuseTokens = false;

  FakeApi device(String name) => FakeApi(this, name);

  /// Stores a record as if some other device had pushed it.
  void put(String kind, Map<String, dynamic> data, {String device = 'elsewhere'}) =>
      records['$kind/${data['id']}'] = (kind: kind, data: data, seq: ++seq, device: device);
}

class FakeApi implements SyncApi {
  FakeApi(this.server, this.name);
  final FakeServer server;
  final String name;
  int pushes = 0;

  void _auth() {
    if (server.refuseTokens) throw const Unauthorized('token revoked');
  }

  @override
  Future<List<PushResult>> push(List<SyncRecord> records) async {
    _auth();
    pushes++;
    return [
      for (final r in records) _push(SyncRecord(r.kind, jsonDecode(jsonEncode(r.data)))),
    ];
  }

  PushResult _push(SyncRecord r) {
    PushResult result(String status, [String? error]) =>
        (kind: r.kind, id: r.id, status: status, error: error);
    final sha = r.data['sha256'] as String? ?? '';
    if (r.kind == 'media' && r.data['deleted'] != true && sha.isNotEmpty && !server.blobs.containsKey(sha)) {
      return result('rejected', 'missing blob');
    }
    final existing = server.records['${r.kind}/${r.id}'];
    if (existing != null && (existing.data['updatedAt'] as int) >= r.updatedAt) return result('stale');
    server.put(r.kind, r.data, device: name);
    return result('accepted');
  }

  @override
  Future<PullPage> pull(int since, {int limit = 500}) async {
    _auth();
    final changes = server.records.values.where((r) => r.seq > since).toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    final out = <SyncRecord>[];
    var cursor = since, scanned = 0;
    for (final r in changes) {
      if (out.length == limit) break;
      scanned++;
      cursor = r.seq;
      if (r.device != name) out.add(SyncRecord(r.kind, jsonDecode(jsonEncode(r.data))));
    }
    return (records: out, cursor: cursor, more: scanned < changes.length);
  }

  @override
  Future<bool> hasBlob(String sha256) async {
    _auth();
    return server.blobs.containsKey(sha256);
  }

  @override
  Future<void> putBlob(String sha256Hex, File file, String contentType) async {
    _auth();
    final bytes = await file.readAsBytes();
    if (sha256.convert(bytes).toString() != sha256Hex) throw const ServerError(400, 'hash mismatch');
    server.blobs[sha256Hex] = bytes;
  }

  @override
  Future<void> getBlob(String sha256, File dest) async {
    _auth();
    final bytes = server.blobs[sha256];
    if (bytes == null) throw const ServerError(404, 'no such blob');
    await dest.parent.create(recursive: true);
    await dest.writeAsBytes(bytes);
  }
}

Future<Uint8List?> _thumb(File source, MediaKind kind) async => Uint8List.fromList([7]);

class Device {
  Device(Directory root, this.api)
      : db = AppDatabase(NativeDatabase.memory()),
        store = MediaStore(Directory(p.join(root.path, api.name))..createSync(recursive: true),
            thumbnailer: _thumb) {
    repo = Repository(db, store);
  }
  final FakeApi api;
  final AppDatabase db;
  final MediaStore store;
  late final Repository repo;
  int cursor = 0;
  late SyncResult last;

  SyncEngine get engine => SyncEngine(repo, api);

  Future<SyncResult> sync() async {
    last = await engine.syncOnce(cursor);
    cursor = last.cursor;
    return last;
  }

  Future<int> outbox() async => (await db.select(db.syncOutbox).get()).length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  late FakeServer server;
  late Device a, b;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ck-sync-');
    server = FakeServer();
    a = Device(tmp, server.device('a'));
    b = Device(tmp, server.device('b'));
  });

  tearDown(() async {
    await a.db.close();
    await b.db.close();
    await tmp.delete(recursive: true);
  });

  test('two devices converge: records, edits both ways and photos', () async {
    final c = await a.repo.createCollection(name: 'Computers', templateId: 'retro-computers');
    final shelf = await a.repo.addLocation(name: 'Shelf 2', code: 'S2');
    final amiga = await a.repo.createItem(c.id, name: 'Amiga 1200', locationId: shelf.id,
        values: {'any-field': 'MC68EC020'});
    final photo = File(p.join(tmp.path, 'amiga.jpg'))..writeAsBytesSync(List.generate(5000, (i) => i % 251));
    final media = (await a.repo.addMedia(amiga.id, [photo])).single;

    final first = await a.sync();
    expect(first.uploaded, 1);
    expect(first.pushed, greaterThan(4));
    expect(first.rejected, 0);
    expect(await a.outbox(), 0, reason: 'everything pushed leaves the outbox');

    final got = await b.sync();
    expect(got.downloaded, 1);
    expect(await b.outbox(), 0, reason: 'pulled records are not local changes');
    final item = (await b.repo.itemById(amiga.id))!;
    expect(item.name, 'Amiga 1200');
    expect(item.locationId, shelf.id);
    expect(item.values['any-field'], 'MC68EC020');
    expect(item.coverMediaId, media.id);
    expect((await b.repo.locationById(shelf.id))!.code, 'S2');
    expect((await b.repo.fields(c.id)).length, (await a.repo.fields(c.id)).length);
    final bMedia = (await b.repo.mediaFor(amiga.id)).single;
    expect(await b.store.fileFor(bMedia).readAsBytes(), await photo.readAsBytes());
    expect(b.store.thumbnailFor(bMedia.id).existsSync(), isTrue);

    // Edits on both sides meet.
    await b.repo.updateItem(amiga.id, name: 'Amiga 1200 (boxed)');
    final c64 = await a.repo.createItem(c.id, name: 'C64');
    await b.sync();
    await a.sync();
    await b.sync();
    expect((await a.repo.itemById(amiga.id))!.name, 'Amiga 1200 (boxed)');
    expect((await b.repo.itemById(c64.id))!.name, 'C64');
    expect(await a.outbox(), 0);
    expect(await b.outbox(), 0);
  });

  test('deletions travel, and take the media file with them', () async {
    final c = await a.repo.createCollection(name: 'Stuff');
    final item = await a.repo.createItem(c.id, name: 'Gone soon');
    final file = File(p.join(tmp.path, 'x.jpg'))..writeAsBytesSync([1, 2, 3, 4]);
    await a.repo.addMedia(item.id, [file]);
    await a.sync();
    await b.sync();
    final bMedia = (await b.repo.mediaFor(item.id)).single;
    expect(b.store.fileFor(bMedia).existsSync(), isTrue);

    await a.repo.deleteItem(item.id);
    await a.sync();
    final r = await b.sync();
    expect(r.pulled, 2);
    expect(await b.repo.itemById(item.id), isNull);
    expect(await b.repo.watchItems(c.id).first, isEmpty);
    expect(b.store.fileFor(bMedia).existsSync(), isFalse);
  });

  test('an item can arrive before its collection', () async {
    final c = await a.repo.createCollection(name: 'Old name');
    final item = await a.repo.createItem(c.id, name: 'Thing');
    await a.sync();
    // Renaming the collection gives it a later change than the item, so a
    // new device pulls the item first.
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await a.repo.updateCollection(c.id, name: 'New name');
    await a.sync();
    final order = server.records.values.toList()..sort((x, y) => x.seq.compareTo(y.seq));
    expect(order.indexWhere((r) => r.kind == 'item'), lessThan(order.indexWhere((r) => r.kind == 'collection')));

    await b.sync();
    expect(b.last.orphans, 0);
    expect((await b.repo.itemById(item.id))!.name, 'Thing');
    expect((await b.repo.watchCollection(c.id).first)!.name, 'New name');
  });

  test('a record whose collection never arrives is skipped, not fatal', () async {
    final c = await a.repo.createCollection(name: 'Fine');
    await a.sync();
    server.put('item', {
      'id': '00000000-0000-4000-8000-000000000001', 'collectionId': 'nowhere', 'name': 'Orphan',
      'locationId': null, 'fieldValues': <String, dynamic>{}, 'notes': '', 'coverMediaId': null,
      'lastSeenAt': null, 'createdAt': 1, 'updatedAt': 1, 'deleted': false,
    });
    final r = await b.sync();
    expect(r.orphans, 1);
    expect((await b.repo.watchCollection(c.id).first)!.name, 'Fine');
  });

  test('an older edit is stale and the newer one wins on both devices', () async {
    final c = await a.repo.createCollection(name: 'C');
    final item = await a.repo.createItem(c.id, name: 'Original');
    await a.sync();
    await b.sync();

    // B edits offline first; A edits later and syncs first.
    await b.repo.updateItem(item.id, name: 'B (older)');
    await b.db.customStatement('UPDATE items SET updated_at = 1000 WHERE id = ?', [item.id]);
    await a.repo.updateItem(item.id, name: 'A (newer)');
    await a.sync();
    final r = await b.sync();
    expect(r.stale, 1);
    expect((await b.repo.itemById(item.id))!.name, 'A (newer)');
    expect(await b.outbox(), 0);
    await a.sync();
    expect((await a.repo.itemById(item.id))!.name, 'A (newer)');
  });

  test('a change made while a push is under way is sent next time', () async {
    final c = await a.repo.createCollection(name: 'C');
    await a.sync();
    await a.repo.updateCollection(c.id, name: 'C2');
    final racing = _EditDuringPush(server, () async {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await a.repo.updateCollection(c.id, name: 'C3');
    });
    await SyncEngine(a.repo, racing).syncOnce(a.cursor);
    expect(server.records['collection/${c.id}']!.data['name'], 'C2');
    expect(await a.outbox(), 1, reason: 'C3 is still to be sent');
    await a.sync();
    expect(server.records['collection/${c.id}']!.data['name'], 'C3');
    expect(await a.outbox(), 0);
  });

  test('pulling pages through a small limit gets everything', () async {
    final c = await a.repo.createCollection(name: 'Many');
    for (var i = 0; i < 1200; i++) {
      await a.repo.createItem(c.id, name: 'Item $i');
    }
    await a.sync();
    expect(a.api.pushes, greaterThanOrEqualTo(3), reason: 'pushed in batches of 500');
    await b.sync();
    expect((await b.repo.watchItems(c.id).first).length, 1200);
  });

  test('a new device sends its whole library once filled into the outbox', () async {
    final c = await a.repo.createCollection(name: 'Before sync');
    await a.db.delete(a.db.syncOutbox).go(); // as if made before the outbox existed
    await a.engine.fillOutbox();
    expect(await a.outbox(), greaterThan(0));
    await a.sync();
    await b.sync();
    expect((await b.repo.watchCollection(c.id).first)!.name, 'Before sync');
  });

  test('a revoked token stops the controller and asks to connect again', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await Settings.load();
    await a.repo.createCollection(name: 'Mine');
    final sync = SyncController(a.repo, settings, api: (_, _) => a.api);
    addTearDown(sync.dispose);
    await sync.connect('https://example.test', 'ckt_x', (id: 'u1', username: 'chris', name: 'Chris'));
    await sync.syncNow();
    expect(sync.status, SyncStatus.idle);
    expect(settings.lastSyncAt, isNotNull);

    server.refuseTokens = true;
    await sync.syncNow();
    expect(sync.status, SyncStatus.needsPairing);
    expect(sync.error, contains('Connect again'));
    expect(settings.syncToken, 'ckt_x', reason: 'kept until the person connects again');

    // Same server and account: the cursor stays; another account starts over.
    final cursor = settings.syncCursor;
    expect(cursor, greaterThan(0));
    server.refuseTokens = false;
    await sync.connect('https://example.test', 'ckt_y', (id: 'u1', username: 'chris', name: 'Chris'));
    expect(settings.syncCursor, cursor);
    await sync.connect('https://example.test', 'ckt_z', (id: 'u2', username: 'sam', name: 'Sam'));
    expect(settings.syncCursor, 0);
    expect(await a.outbox(), greaterThan(0));
    await sync.syncNow();
    sync.disconnect();
    expect(sync.status, SyncStatus.off);
    expect(settings.syncToken, isNull);
  });
}

/// Makes a local edit while its push is on the wire.
class _EditDuringPush extends FakeApi {
  _EditDuringPush(FakeServer server, this.edit) : super(server, 'a');
  final Future<void> Function() edit;

  @override
  Future<List<PushResult>> push(List<SyncRecord> records) async {
    final results = await super.push(records);
    await edit();
    return results;
  }
}
