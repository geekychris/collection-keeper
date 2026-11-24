import 'dart:io';
import 'dart:typed_data';

import 'package:collection_keeper/main.dart';
import 'package:collection_keeper/src/app/providers.dart';
import 'package:collection_keeper/src/data/database.dart';
import 'package:collection_keeper/src/data/media_store.dart';
import 'package:collection_keeper/src/data/model.dart';
import 'package:collection_keeper/src/data/repository.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  // Each test opens a fresh in-memory database.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  late AppDatabase db;
  late Repository repo;

  setUp(() async {
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

  Future<void> pumpApp(WidgetTester tester, {Size size = const Size(420, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repo)],
      child: const CollectionKeeperApp(),
    ));
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
}
