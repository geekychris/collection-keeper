import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../data/database.dart';
import '../labels/label_content.dart';
import 'common.dart';
import 'location_detail_screen.dart';
import 'location_picker.dart';
import 'print_labels_screen.dart';

/// The tree of places things are kept, shared by every collection.
class LocationsScreen extends ConsumerWidget {
  const LocationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locations = ref.watch(locationsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Locations'),
        actions: [
          IconButton(
            tooltip: 'Print labels for all locations',
            icon: const Icon(Icons.qr_code_2),
            onPressed: () {
              final all = ref.read(locationsProvider).value ?? const <Location>[];
              if (all.isEmpty) return;
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => PrintLabelsScreen(
                    labels: [for (final (l, _) in flattenLocations(all)) locationLabel(l, all)],
                  ),
                ),
              );
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref, parentId: null),
        icon: const Icon(Icons.add),
        label: const Text('Add location'),
      ),
      body: AsyncBody(
        value: locations,
        builder: (all) {
          if (all.isEmpty) {
            return const EmptyState(
              icon: Icons.warehouse_outlined,
              title: 'No locations yet',
              message:
                  'Add the places you keep things, from the building down to the box: '
                  'Warehouse › Aisle 3 › Shelf 2.',
            );
          }
          final rows = flattenLocations(all);
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: rows.length,
            itemBuilder: (context, i) {
              final (location, depth) = rows[i];
              return ListTile(
                contentPadding: EdgeInsets.only(left: 16 + depth * 24.0, right: 8),
                leading: Icon(depth == 0 ? Icons.warehouse_outlined : Icons.subdirectory_arrow_right),
                title: Text(location.name),
                subtitle: location.code.isEmpty && location.notes.isEmpty
                    ? null
                    : Text(
                        [location.code, location.notes].where((s) => s.isNotEmpty).join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => LocationDetailScreen(locationId: location.id)),
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'add') _edit(context, ref, parentId: location.id);
                    if (v == 'edit') _edit(context, ref, location: location);
                    if (v == 'label') {
                      Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => PrintLabelsScreen(labels: [locationLabel(location, all)]),
                        ),
                      );
                    }
                    if (v == 'delete') {
                      final ok = await confirm(
                        context,
                        title: 'Delete ${location.name}?',
                        message: 'Places inside it, and items kept there, move up one level.',
                      );
                      if (ok) await ref.read(repositoryProvider).deleteLocation(location.id);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'add', child: Text('Add a place inside')),
                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(value: 'label', child: Text('Print label')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, {Location? location, String? parentId}) =>
      editLocation(context, ref, location: location, parentId: parentId);
}

/// Adds a location (inside [parentId]) or edits [location].
Future<void> editLocation(BuildContext context, WidgetRef ref, {Location? location, String? parentId}) async {
  final result = await showDialog<({String name, String code, String notes})>(
    context: context,
    builder: (_) => _LocationDialog(location: location),
  );
  if (result == null) return;
  final repo = ref.read(repositoryProvider);
  if (location == null) {
    await repo.addLocation(name: result.name, code: result.code, notes: result.notes, parentId: parentId);
  } else {
    await repo.updateLocation(location.id, name: result.name, code: result.code, notes: result.notes);
  }
}

class _LocationDialog extends StatefulWidget {
  const _LocationDialog({this.location});
  final Location? location;

  @override
  State<_LocationDialog> createState() => _LocationDialogState();
}

class _LocationDialogState extends State<_LocationDialog> {
  late final _name = TextEditingController(text: widget.location?.name ?? '');
  late final _code = TextEditingController(text: widget.location?.code ?? '');
  late final _notes = TextEditingController(text: widget.location?.notes ?? '');

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _submit() {
    if (_name.text.trim().isEmpty) return;
    Navigator.pop(context, (name: _name.text.trim(), code: _code.text.trim(), notes: _notes.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.location == null ? 'New location' : 'Edit location'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Shelf 2'),
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _code,
              decoration: const InputDecoration(labelText: 'Label code (optional)', hintText: 'e.g. A3-S2'),
              textCapitalization: TextCapitalization.characters,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notes,
              decoration: const InputDecoration(labelText: 'Notes (optional)'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}
