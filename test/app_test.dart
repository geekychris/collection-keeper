import 'dart:io';
import 'dart:typed_data';

import 'package:collection_keeper/main.dart';
import 'package:collection_keeper/src/app/providers.dart';
import 'package:collection_keeper/src/app/settings.dart';
import 'package:collection_keeper/src/data/codes.dart';
import 'package:collection_keeper/src/data/database.dart';
import 'package:collection_keeper/src/data/media_store.dart';
import 'package:collection_keeper/src/data/model.dart';
import 'package:collection_keeper/src/data/repository.dart';
import 'package:collection_keeper/src/labels/label_content.dart';
import 'package:collection_keeper/src/ui/print_labels_screen.dart';
import 'package:collection_keeper/src/ui/sync_screen.dart';
import 'package:collection_keeper/src/ui/walk_round.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // Each test opens a fresh in-memory database.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  late AppDatabase db;
  late Repository repo;
  late Settings settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await Settings.load();
    tmp = await Directory.systemTemp.createTemp('ck-widget-');
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(
      db,
      MediaStore(tmp, thumbnailer: (File _, MediaKind _) async => Uint8List(0)),
    );
  });

  tearDown(() => tmp.delete(recursive: true));

  /// Unmounts the app and lets the zero-length timers drift schedules when
  /// its streams are cancelled fire before the test ends. (Closing the
  /// in-memory database inside the fake-async zone hangs, so it is left to
  /// the garbage collector.)
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await tester.pump(Duration.zero);
  }

  /// Drift streams finish on real timers, so let them run between frames.
  /// (pumpAndSettle would wait forever on a loading spinner.)
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpApp(WidgetTester tester, {Size size = const Size(420, 900), Widget? home}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        settingsProvider.overrideWithValue(settings),
      ],
      child: home == null ? const CollectionKeeperApp() : MaterialApp(home: home),
    ));
    await settle(tester);
  }

  /// Types a code into the scanner's field, as a keyboard-wedge scanner does.
  Future<void> typeCode(WidgetTester tester, String code) async {
    await tester.enterText(find.byType(TextField).last, code);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await settle(tester);
  }

  testWidgets('create a collection from a template and add an item (phone layout)', (tester) async {
    await pumpApp(tester);
    expect(find.text('No collections yet'), findsOneWidget);

    await tester.tap(find.text('New collection').first);
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Computers');
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await settle(tester);
    await tester.tap(find.text('Retro computers').last);
    await settle(tester);
    await tester.tap(find.text('Create'));
    await settle(tester);

    expect(find.text('Computers'), findsOneWidget, reason: 'opened the new collection');
    expect(find.text('Nothing here yet'), findsOneWidget);

    await tester.tap(find.text('Add item').first);
    await settle(tester);
    expect(find.text('Working status'), findsOneWidget, reason: 'template fields are on the form');
    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'Amiga 1200');
    await tester.enterText(find.widgetWithText(TextFormField, 'CPU'), 'MC68EC020');
    await tester.tap(find.text('Save'));
    await settle(tester);

    // The new item opens; its field value is shown.
    expect(find.text('Amiga 1200'), findsWidgets);
    expect(find.text('MC68EC020'), findsOneWidget);
    expect(find.text('Add photos'), findsOneWidget);

    final c = (await tester.runAsync(() => repo.watchCollections().first))!.single;
    expect(c.collection.name, 'Computers');
    expect(c.itemCount, 1);
    await finish(tester);
  });

  testWidgets('wide screens show the list and the selected item side by side', (tester) async {
    await tester.runAsync(() async {
      final c = await repo.createCollection(name: 'Software', templateId: 'software');
      await repo.createItem(c.id, name: 'Deluxe Paint', notes: 'Boxed, with manual');
    });
    await pumpApp(tester, size: const Size(1280, 800));

    await tester.tap(find.text('Software'));
    await settle(tester);
    expect(find.text('Select an item'), findsOneWidget);

    await tester.tap(find.text('Deluxe Paint'));
    await settle(tester);
    expect(find.text('Boxed, with manual'), findsOneWidget);
    expect(find.text('Select an item'), findsNothing);
    await finish(tester);
  });

  testWidgets('put away: scan a shelf, then things to put on it, with undo', (tester) async {
    late Item amiga;
    late Location shelf;
    await tester.runAsync(() async {
      final c = await repo.createCollection(name: 'Computers');
      shelf = await repo.addLocation(name: 'Shelf 2', code: 'A3-S2');
      amiga = await repo.createItem(c.id, name: 'Amiga 1200');
    });
    await pumpApp(tester, home: const PutAwayScreen(camera: false));
    expect(find.text('Scan a shelf or box first'), findsOneWidget);

    await typeCode(tester, labelCode(CodeKind.item, amiga.id));
    expect(find.text('Scan the shelf or box first'), findsOneWidget, reason: 'no target yet');

    await typeCode(tester, 'a3-s2');
    expect(find.text('Putting things in Shelf 2'), findsWidgets);
    await typeCode(tester, labelCode(CodeKind.item, amiga.id));
    expect(find.text('Moved (1)'), findsOneWidget);
    expect((await tester.runAsync(() => repo.itemById(amiga.id)))!.locationId, shelf.id);

    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect((await tester.runAsync(() => repo.itemById(amiga.id)))!.locationId, isNull);
    await finish(tester);
  });

  testWidgets('stocktake: found, missing, and a stray moved here', (tester) async {
    late Item a, b, stray;
    late Location shelf;
    await tester.runAsync(() async {
      final c = await repo.createCollection(name: 'Computers');
      shelf = await repo.addLocation(name: 'Shelf 2');
      final other = await repo.addLocation(name: 'Garage');
      a = await repo.createItem(c.id, name: 'Amiga 1200', locationId: shelf.id);
      b = await repo.createItem(c.id, name: 'Atari 800XL', locationId: shelf.id);
      stray = await repo.createItem(c.id, name: 'BBC Micro', locationId: other.id);
    });
    await pumpApp(tester, home: StocktakeScreen(locationId: shelf.id, camera: false));
    expect(find.text('0 of 2 found'), findsOneWidget);

    await typeCode(tester, labelCode(CodeKind.item, a.id));
    expect(find.text('1 of 2 found'), findsOneWidget);
    expect(find.text('Not found yet (1)'), findsOneWidget);
    expect((await tester.runAsync(() => repo.itemById(a.id)))!.lastSeenAt, isNotNull);
    expect((await tester.runAsync(() => repo.itemById(b.id)))!.lastSeenAt, isNull);

    await typeCode(tester, labelCode(CodeKind.item, stray.id));
    expect(find.text('Not recorded here'), findsOneWidget);
    await tester.tap(find.text('Move here'));
    await settle(tester);
    expect(find.text('2 of 3 found'), findsOneWidget);
    expect((await tester.runAsync(() => repo.itemById(stray.id)))!.locationId, shelf.id);
    await finish(tester);
  });

  testWidgets('print labels shows a preview and offers the other-printer route', (tester) async {
    late Item item;
    late Collection c;
    await tester.runAsync(() async {
      c = await repo.createCollection(name: 'Computers');
      item = await repo.createItem(c.id, name: 'Amiga 1200');
    });
    await pumpApp(tester, home: PrintLabelsScreen(labels: [itemLabel(item, collection: c)]));
    expect(find.text('Print label'), findsOneWidget);
    expect(find.text('Print…'), findsOneWidget, reason: 'no printer used before: PDF first');
    expect(find.byType(RawImage), findsOneWidget, reason: 'the 1-bit preview rendered');

    await tester.tap(find.text('NIIMBOT'));
    await settle(tester);
    expect(find.text('Find a printer nearby'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('the sync screen offers servers and warns about plain http', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byType(SyncButton));
    await settle(tester);
    expect(find.text('Server address'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    await tester.tap(find.textContaining('collections.hitorro.com:8443'));
    await settle(tester);
    expect(find.text('https://collections.hitorro.com:8443'), findsOneWidget);
    expect(find.textContaining('isn\'t encrypted'), findsNothing);
    await tester.enterText(find.byType(TextField).first, 'http://collections.example.com');
    await settle(tester);
    expect(find.textContaining('isn\'t encrypted'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'http://192.168.1.219:31870');
    await settle(tester);
    expect(find.textContaining('isn\'t encrypted'), findsNothing);
    await finish(tester);
  });
}
