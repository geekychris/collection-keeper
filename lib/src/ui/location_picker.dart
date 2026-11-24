import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../data/codes.dart';
import '../data/database.dart';
import 'scanner.dart';

/// Depth-first order of the location tree, children sorted by name, each
/// with its depth. A location whose parent is gone counts as a root.
List<(Location, int)> flattenLocations(List<Location> all) {
  final ids = {for (final l in all) l.id};
  final children = <String?, List<Location>>{};
  for (final l in all) {
    final parent = ids.contains(l.parentId) ? l.parentId : null;
    children.putIfAbsent(parent, () => []).add(l);
  }
  final out = <(Location, int)>[];
  final seen = <String>{};
  void walk(String? parent, int depth) {
    final kids = [...?children[parent]]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    for (final k in kids) {
      if (!seen.add(k.id)) continue;
      out.add((k, depth));
      walk(k.id, depth + 1);
    }
  }

  walk(null, 0);
  return out;
}

/// Asks for a location: scan its label or choose it from the tree. Returns
/// null when cancelled, and a record with a null location for "no location"
/// when [allowNone].
Future<({Location? location})?> chooseLocation(
  BuildContext context, {
  String title = 'Choose a location',
  bool allowNone = false,
}) =>
    showModalBottomSheet<({Location? location})>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _LocationSheet(title: title, allowNone: allowNone),
    );

class _LocationSheet extends ConsumerWidget {
  const _LocationSheet({required this.title, required this.allowNone});
  final String title;
  final bool allowNone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(locationsProvider).value ?? const <Location>[];
    final rows = flattenLocations(all);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(controller: scroll, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        ListTile(
          leading: const Icon(Icons.qr_code_scanner),
          title: const Text('Scan its label'),
          onTap: () async {
            final scanned = await Navigator.push<Location>(
              context,
              MaterialPageRoute(builder: (_) => const _ScanLocationPage()),
            );
            if (scanned != null && context.mounted) Navigator.pop(context, (location: scanned));
          },
        ),
        if (allowNone)
          ListTile(
            leading: const Icon(Icons.not_listed_location_outlined),
            title: const Text('No location'),
            onTap: () => Navigator.pop(context, (location: null)),
          ),
        const Divider(),
        if (rows.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('No locations yet. Add them under Locations on the home screen.'),
          ),
        for (final (l, depth) in rows)
          ListTile(
            contentPadding: EdgeInsets.only(left: 24 + depth * 20.0, right: 16),
            leading: Icon(depth == 0 ? Icons.warehouse_outlined : Icons.subdirectory_arrow_right),
            title: Text(l.name),
            subtitle: l.code.isEmpty ? null : Text(l.code),
            onTap: () => Navigator.pop(context, (location: l)),
          ),
      ]),
    );
  }
}

class _ScanLocationPage extends ConsumerWidget {
  const _ScanLocationPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan a location label')),
      body: CodeScanner(
        hint: 'Type a location code',
        onCode: (code) async {
          final repo = ref.read(repositoryProvider);
          final target = await repo.resolveCode(code);
          if (!context.mounted) return;
          if (target?.kind != CodeKind.location) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(target == null ? 'No location has that code' : 'That’s an item, not a location'),
            ));
            return;
          }
          final location = await repo.locationById(target!.id);
          if (context.mounted) Navigator.pop(context, location);
        },
      ),
    );
  }
}
