// Sync against a real Collection Keeper server (server/), end to end over
// HTTP. Skipped unless CK_SERVER_URL and CK_ADMIN_PASSWORD are set:
//
//   cd server && DATABASE_URL=… ADMIN_PASSWORD=… BLOB_DIR=/tmp/ck LISTEN_ADDR=:18080 go run ./cmd/ckserver
//   CK_SERVER_URL=http://127.0.0.1:18080 CK_ADMIN_PASSWORD=… flutter test test/live_server_test.dart
//
// It signs in to the web pages as the local admin to approve the pairing,
// the way a person would in a browser.
import 'dart:io';
import 'dart:typed_data';

import 'package:collection_keeper/src/data/database.dart';
import 'package:collection_keeper/src/data/media_store.dart';
import 'package:collection_keeper/src/data/model.dart';
import 'package:collection_keeper/src/data/repository.dart';
import 'package:collection_keeper/src/sync/sync_api.dart';
import 'package:collection_keeper/src/sync/sync_engine.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

final _server = Platform.environment['CK_SERVER_URL'];
final _password = Platform.environment['CK_ADMIN_PASSWORD'];

/// Signs in as admin and approves [userCode], like a person in a browser.
Future<void> approve(String userCode) async {
  final client = http.Client();
  try {
    final login = http.Request('POST', Uri.parse('$_server/login'))
      ..followRedirects = false
      ..bodyFields = {'username': 'admin', 'password': _password!, 'next': '/'};
    final res = await client.send(login);
    expect(res.statusCode, 303, reason: 'admin sign-in');
    final cookie = res.headers['set-cookie']!.split(';').first;
    final page = await client.get(Uri.parse('$_server/pair?code=$userCode'), headers: {'Cookie': cookie});
    final csrf = RegExp(r'name="csrf" value="([^"]+)"').firstMatch(page.body)!.group(1)!;
    final ok = await client.post(Uri.parse('$_server/pair'),
        headers: {'Cookie': cookie},
        body: {'csrf': csrf, 'code': userCode, 'decision': 'approve'});
    expect(ok.body, contains('Connected'));
  } finally {
    client.close();
  }
}

Future<String> pair(String name) async {
  final api = HttpSyncApi(_server!);
  final start = await api.pairStart(deviceName: name, platform: 'test', appVersion: 'test');
  expect((await api.pairPoll(start.deviceCode)).status, 'pending');
  await approve(start.userCode);
  final done = await api.pairPoll(start.deviceCode);
  expect(done.status, 'approved');
  return done.token!;
}

class LiveDevice {
  LiveDevice(Directory root, String name, String token)
      : api = HttpSyncApi(_server!, token: token),
        db = AppDatabase(NativeDatabase.memory()),
        store = MediaStore(Directory(p.join(root.path, name))..createSync(recursive: true),
            thumbnailer: (f, k) async => Uint8List.fromList([1])) {
    repo = Repository(db, store);
  }
  final HttpSyncApi api;
  final AppDatabase db;
  final MediaStore store;
  late final Repository repo;
  int cursor = 0;

  Future<SyncResult> sync() async {
    final r = await SyncEngine(repo, api).syncOnce(cursor);
    cursor = r.cursor;
    return r;
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('two devices sync through a real server', () async {
    final tmp = await Directory.systemTemp.createTemp('ck-live-');
    final phone = LiveDevice(tmp, 'phone', await pair('Live test phone'));
    final mac = LiveDevice(tmp, 'mac', await pair('Live test Mac'));
    expect((await phone.api.me()).username, 'admin');

    final c = await phone.repo.createCollection(name: 'Live computers', templateId: 'retro-computers');
    final shelf = await phone.repo.addLocation(name: 'Live shelf', code: 'L1');
    final item = await phone.repo.createItem(c.id, name: 'Amiga 4000', locationId: shelf.id);
    final photo = File(p.join(tmp.path, 'a4000.jpg'))
      ..writeAsBytesSync(List.generate(300000, (i) => (i * 7) % 256));
    await phone.repo.addMedia(item.id, [photo]);

    final up = await phone.sync();
    expect(up.rejected, 0, reason: '$up');
    expect(up.uploaded, 1);

    final down = await mac.sync();
    expect(down.downloaded, 1, reason: '$down');
    final got = (await mac.repo.itemById(item.id))!;
    expect(got.name, 'Amiga 4000');
    final media = (await mac.repo.mediaFor(item.id)).single;
    expect(await mac.store.fileFor(media).readAsBytes(), await photo.readAsBytes());
    expect(media.kind, MediaKind.photo.name);

    // An edit on the Mac comes back to the phone; nothing echoes.
    await mac.repo.updateItem(item.id, name: 'Amiga 4000T');
    await mac.sync();
    final back = await phone.sync();
    expect(back.pulled, 1);
    expect((await phone.repo.itemById(item.id))!.name, 'Amiga 4000T');
    expect((await mac.sync()).pulled, 0);

    await phone.db.close();
    await mac.db.close();
    await tmp.delete(recursive: true);
  }, skip: _server == null || _password == null ? 'set CK_SERVER_URL and CK_ADMIN_PASSWORD' : false);
}
