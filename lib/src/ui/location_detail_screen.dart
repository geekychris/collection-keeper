import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../data/repository.dart';
import '../labels/label_content.dart';
import 'common.dart';
import 'item_detail.dart';
import 'locations_screen.dart';
import 'print_labels_screen.dart';
import 'walk_round.dart';

/// One location: where it is, the places inside it, and what's kept there
/// (from every collection).
class LocationDetailScreen extends ConsumerStatefulWidget {
  const LocationDetailScreen({super.key, required this.locationId});
  final String locationId;

  @override
  ConsumerState<LocationDetailScreen> createState() => _LocationDetailScreenState();
}

class _LocationDetailScreenState extends ConsumerState<LocationDetailScreen> {
  bool _inside = true;

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(locationsProvider).value;
    if (all == null) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    final location = all.where((l) => l.id == widget.locationId).firstOrNull;
    if (location == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(icon: Icons.delete_outline, title: 'This location was deleted'),
      );
    }
    final ids = _inside ? locationAndDescendants(location.id, all) : {location.id};
    final items = ref.watch(itemsAtProvider(locationKey(ids)));
    final collections = {
      for (final c in ref.watch(collectionsProvider).value ?? const <CollectionSummary>[])
        c.collection.id: c.collection,
    };
    final children = all.where((l) => l.parentId == location.id).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(location.name), actions: [
        IconButton(
          tooltip: 'Print label',
          icon: const Icon(Icons.qr_code_2),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => PrintLabelsScreen(labels: [locationLabel(location, all)])),
          ),
        ),
        IconButton(
          tooltip: 'Stocktake',
          icon: const Icon(Icons.fact_check_outlined),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => StocktakeScreen(locationId: location.id)),
          ),
        ),
        IconButton(
          tooltip: 'Edit',
          icon: const Icon(Icons.edit_outlined),
          onPressed: () => editLocation(context, ref, location: location),
        ),
      ]),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        ListTile(
          leading: const Icon(Icons.place_outlined),
          title: Text(locationPath(location, all)),
          subtitle: Text([
            if (location.code.isNotEmpty) 'Code ${location.code}',
            if (location.notes.isNotEmpty) location.notes,
          ].join(' · ').ifEmpty('No label code')),
        ),
        if (children.isNotEmpty) ...[
          _Header('Places inside'),
          for (final c in children)
            ListTile(
              leading: const Icon(Icons.subdirectory_arrow_right),
              title: Text(c.name),
              subtitle: c.code.isEmpty ? null : Text(c.code),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => LocationDetailScreen(locationId: c.id)),
              ),
            ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
          child: Row(children: [
            Expanded(child: Text('Kept here', style: theme.textTheme.titleSmall)),
            if (children.isNotEmpty) ...[
              Text('Include places inside', style: theme.textTheme.bodySmall),
              Switch(value: _inside, onChanged: (v) => setState(() => _inside = v)),
            ],
          ]),
        ),
        ...items.when(
          loading: () => [const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))],
          error: (e, _) => [Text('Error: $e')],
          data: (items) => items.isEmpty
              ? [const Padding(padding: EdgeInsets.all(24), child: Text('Nothing is recorded here.'))]
              : [
                  for (final item in items)
                    ListTile(
                      leading: MediaThumb(mediaId: item.coverMediaId, size: 48),
                      title: Text(item.name),
                      subtitle: Text([
                        ?collections[item.collectionId]?.name,
                        if (item.locationId != location.id)
                          ?all.where((l) => l.id == item.locationId).firstOrNull?.name,
                        if (item.lastSeenAt != null) 'checked ${lastSeenText(item.lastSeenAt!)}',
                      ].join(' · ')),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(builder: (_) => ItemDetail(itemId: item.id)),
                      ),
                    ),
                ],
        ),
      ]),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );
}

/// "today", "yesterday" or the date.
String lastSeenText(int ms) {
  final seen = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(seen.year, seen.month, seen.day)).inDays;
  if (days == 0) return 'today';
  if (days == 1) return 'yesterday';
  return DateFormat.yMMMd().format(seen);
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
