import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/repository.dart';
import '../labels/niimbot_ble.dart';
import 'settings.dart';

/// Supplied by main() (or a test) through a ProviderScope override.
final repositoryProvider = Provider<Repository>(
  (ref) => throw UnimplementedError('repositoryProvider must be overridden'),
);

final collectionsProvider = StreamProvider.autoDispose<List<CollectionSummary>>(
  (ref) => ref.watch(repositoryProvider).watchCollections(),
);

final collectionProvider = StreamProvider.autoDispose.family<Collection?, String>(
  (ref, id) => ref.watch(repositoryProvider).watchCollection(id),
);

final fieldsProvider = StreamProvider.autoDispose.family<List<FieldDef>, String>(
  (ref, collectionId) => ref.watch(repositoryProvider).watchFields(collectionId),
);

typedef ItemQuery = ({String collectionId, String search, String? locationId});

final itemsProvider = StreamProvider.autoDispose.family<List<Item>, ItemQuery>(
  (ref, q) => ref
      .watch(repositoryProvider)
      .watchItems(q.collectionId, search: q.search, locationId: q.locationId),
);

final itemProvider = StreamProvider.autoDispose.family<Item?, String>(
  (ref, id) => ref.watch(repositoryProvider).watchItem(id),
);

final mediaProvider = StreamProvider.autoDispose.family<List<MediaEntry>, String>(
  (ref, itemId) => ref.watch(repositoryProvider).watchMedia(itemId),
);

final locationsProvider = StreamProvider.autoDispose<List<Location>>(
  (ref) => ref.watch(repositoryProvider).watchLocations(),
);

/// Supplied by main() (or a test) through a ProviderScope override.
final settingsProvider = Provider<Settings>(
  (ref) => throw UnimplementedError('settingsProvider must be overridden'),
);

/// The label printer, kept for the life of the app.
final printerProvider = Provider<PrinterController>((ref) {
  final printer = PrinterController();
  ref.onDispose(printer.dispose);
  return printer;
});

/// Items kept at any of these locations, from every collection. The key is
/// [locationKey] of the ids (sets aren't equal by value, so can't be keys).
final itemsAtProvider = StreamProvider.autoDispose.family<List<Item>, String>(
  (ref, key) => ref
      .watch(repositoryProvider)
      .watchItemsAt(key.isEmpty ? const {} : key.split(',').toSet()),
);

String locationKey(Set<String> ids) => (ids.toList()..sort()).join(',');
