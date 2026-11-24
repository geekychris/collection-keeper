import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../app/platform_io.dart' as platform;
import '../app/providers.dart';
import '../data/database.dart';
import '../data/model.dart';
import '../data/repository.dart';
import '../exchange/exchange.dart';
import 'collection_settings_screen.dart';
import 'common.dart';
import 'item_detail.dart';
import 'item_edit_screen.dart';

class CollectionScreen extends ConsumerStatefulWidget {
  const CollectionScreen({super.key, required this.collectionId});
  final String collectionId;

  @override
  ConsumerState<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends ConsumerState<CollectionScreen> {
  final _search = TextEditingController();
  String _query = '';
  String? _locationId;
  String? _selectedId;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final collection = ref.watch(collectionProvider(widget.collectionId)).value;
    final fields = ref.watch(fieldsProvider(widget.collectionId)).value ?? const [];
    final locations = ref.watch(locationsProvider).value ?? const <Location>[];
    final items = ref.watch(itemsProvider((
      collectionId: widget.collectionId,
      search: _query,
      locationId: _locationId,
    )));
    final wide = isWide(context);

    final list = AsyncBody(
      value: items,
      builder: (items) {
        if (items.isEmpty) {
          return _query.isEmpty && _locationId == null
              ? EmptyState(
                  icon: Icons.add_a_photo_outlined,
                  title: 'Nothing here yet',
                  message: 'Add the first item: a name is enough, photos and details can follow.',
                  action: FilledButton.icon(
                    onPressed: _addItem,
                    icon: const Icon(Icons.add),
                    label: const Text('Add item'),
                  ),
                )
              : const EmptyState(icon: Icons.search_off, title: 'No matching items');
        }
        return ListView.separated(
          padding: const EdgeInsets.only(bottom: 96),
          itemCount: items.length,
          separatorBuilder: (_, _) => const Divider(height: 1, indent: 88),
          itemBuilder: (context, i) {
            final item = items[i];
            return ListTile(
              selected: wide && item.id == _selectedId,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              leading: MediaThumb(mediaId: item.coverMediaId),
              title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                _subtitle(item, fields, locations, collection?.currency ?? 'USD'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _open(item.id),
            );
          },
        );
      },
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(collection?.name ?? ''),
        actions: [
          IconButton(
            tooltip: 'Fields and settings',
            icon: const Icon(Icons.tune),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => CollectionSettingsScreen(collectionId: widget.collectionId),
              ),
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'export') _export();
              if (v == 'delete') _delete();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'export', child: Text('Export…')),
              PopupMenuItem(value: 'delete', child: Text('Delete collection…')),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(children: [
              Expanded(
                child: SearchBar(
                  controller: _search,
                  hintText: 'Search names, notes and fields',
                  leading: const Icon(Icons.search),
                  elevation: const WidgetStatePropertyAll(0),
                  trailing: [
                    if (_query.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(() {
                          _search.clear();
                          _query = '';
                        }),
                      ),
                  ],
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              const SizedBox(width: 8),
              _LocationFilter(
                locations: locations,
                selected: _locationId,
                onChanged: (id) => setState(() => _locationId = id),
              ),
            ]),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addItem,
        icon: const Icon(Icons.add),
        label: const Text('Add item'),
      ),
      body: wide
          ? Row(children: [
              SizedBox(width: 400, child: list),
              const VerticalDivider(width: 1),
              Expanded(
                child: _selectedId == null
                    ? const EmptyState(icon: Icons.touch_app_outlined, title: 'Select an item')
                    : ItemDetail(key: ValueKey(_selectedId), itemId: _selectedId!, embedded: true),
              ),
            ])
          : list,
    );
  }

  String _subtitle(Item item, List<FieldDef> fields, List<Location> locations, String currency) {
    final values = item.values;
    final parts = <String>[];
    for (final f in fields) {
      if (f.fieldType == FieldType.longText) continue;
      final shown = formatFieldValue(f, values[f.id], currency: currency);
      if (shown != null && f.fieldType != FieldType.boolean) parts.add(shown);
      if (parts.length == 3) break;
    }
    final location = locations.where((l) => l.id == item.locationId).firstOrNull;
    if (location != null) parts.add('📍 ${locationPath(location, locations)}');
    return parts.join(' · ');
  }

  void _open(String itemId) {
    if (isWide(context)) {
      setState(() => _selectedId = itemId);
    } else {
      Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => ItemDetail(itemId: itemId)),
      );
    }
  }

  Future<void> _addItem() async {
    final id = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => ItemEditScreen(
          collectionId: widget.collectionId,
          initialLocationId: _locationId,
        ),
      ),
    );
    if (id != null && mounted) _open(id);
  }

  Future<void> _export() async {
    final exchange = Exchange(ref.read(repositoryProvider));
    if (platform.isMobile) {
      final file = await withProgress(context, 'Exporting…', () async {
        final dir = await Directory.systemTemp.createTemp('ck-share-');
        return exchange.exportZip(widget.collectionId, dir);
      });
      if (file != null) await platform.openExternally(file);
    } else {
      final dir = await platform.pickDirectory(title: 'Export to folder');
      if (dir == null || !mounted) return;
      final file = await withProgress(
        context,
        'Exporting…',
        () => exchange.exportZip(widget.collectionId, dir),
      );
      if (file != null && mounted) showMessage(context, 'Saved ${p.basename(file.path)}');
    }
  }

  Future<void> _delete() async {
    final name = ref.read(collectionProvider(widget.collectionId)).value?.name ?? 'this collection';
    final ok = await confirm(
      context,
      title: 'Delete $name?',
      message: 'This deletes every item in it and their photos and videos. '
          'Export it first if you might want it back.',
    );
    if (!ok || !mounted) return;
    await ref.read(repositoryProvider).deleteCollection(widget.collectionId);
    if (mounted) Navigator.pop(context);
  }
}

class _LocationFilter extends StatelessWidget {
  const _LocationFilter({required this.locations, required this.selected, required this.onChanged});
  final List<Location> locations;
  final String? selected;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    if (locations.isEmpty) return const SizedBox.shrink();
    final current = locations.where((l) => l.id == selected).firstOrNull;
    final sorted = [...locations]
      ..sort((a, b) => locationPath(a, locations).compareTo(locationPath(b, locations)));
    return PopupMenuButton<String?>(
      tooltip: 'Filter by location',
      initialValue: selected,
      onSelected: (v) => onChanged(v == '' ? null : v),
      itemBuilder: (_) => [
        const PopupMenuItem(value: '', child: Text('All locations')),
        for (final l in sorted)
          PopupMenuItem(value: l.id, child: Text(locationPath(l, locations))),
      ],
      child: Chip(
        avatar: const Icon(Icons.place_outlined, size: 18),
        label: Text(current?.name ?? 'All'),
      ),
    );
  }
}
