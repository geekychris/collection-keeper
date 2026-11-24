import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/platform_io.dart' as platform;
import '../app/providers.dart';
import '../data/database.dart';
import '../data/model.dart';
import '../data/repository.dart';
import 'common.dart';
import 'item_edit_screen.dart';
import 'media_viewer.dart';

/// An item's photos, fields and notes. Shown as a page on phones and as the
/// right-hand pane on wide screens ([embedded]).
class ItemDetail extends ConsumerWidget {
  const ItemDetail({super.key, required this.itemId, this.embedded = false});
  final String itemId;
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(itemProvider(itemId));
    return AsyncBody(
      value: item,
      builder: (item) {
        if (item == null) {
          return embedded
              ? const EmptyState(icon: Icons.delete_outline, title: 'This item was deleted')
              : Scaffold(appBar: AppBar());
        }
        final actions = [
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => ItemEditScreen(collectionId: item.collectionId, item: item),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(context, ref, item),
          ),
        ];
        final body = _ItemBody(item: item);
        if (embedded) {
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 8, 0),
              child: Row(children: [
                Expanded(
                  child: Text(item.name,
                      style: Theme.of(context).textTheme.headlineSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ),
                ...actions,
              ]),
            ),
            Expanded(child: body),
          ]);
        }
        return Scaffold(appBar: AppBar(title: Text(item.name), actions: actions), body: body);
      },
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Item item) async {
    final ok = await confirm(
      context,
      title: 'Delete ${item.name}?',
      message: 'Its photos and videos are deleted too.',
    );
    if (!ok) return;
    await ref.read(repositoryProvider).deleteItem(item.id);
    if (!embedded && context.mounted) Navigator.pop(context);
  }
}

class _ItemBody extends ConsumerWidget {
  const _ItemBody({required this.item});
  final Item item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final fields = ref.watch(fieldsProvider(item.collectionId)).value ?? const [];
    final collection = ref.watch(collectionProvider(item.collectionId)).value;
    final locations = ref.watch(locationsProvider).value ?? const <Location>[];
    final location = locations.where((l) => l.id == item.locationId).firstOrNull;
    final values = item.values;
    final shown = [
      for (final f in fields)
        if (formatFieldValue(f, values[f.id], currency: collection?.currency ?? 'USD')
            case final text?)
          (f, text),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 32),
      children: [
        _MediaStrip(itemId: item.id, coverId: item.coverMediaId),
        if (location != null)
          ListTile(
            leading: const Icon(Icons.place_outlined),
            title: Text(locationPath(location, locations)),
            subtitle: location.code.isEmpty ? null : Text(location.code),
          ),
        if (shown.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Table(
              columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
              defaultVerticalAlignment: TableCellVerticalAlignment.top,
              children: [
                for (final (field, text) in shown)
                  TableRow(children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 24, bottom: 10),
                      child: Text(field.name,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: SelectableText(text, style: theme.textTheme.bodyLarge),
                    ),
                  ]),
              ],
            ),
          ),
        if (item.notes.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
            child: Text('Notes', style: theme.textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: SelectableText(item.notes, style: theme.textTheme.bodyLarge),
          ),
        ],
      ],
    );
  }
}

class _MediaStrip extends ConsumerWidget {
  const _MediaStrip({required this.itemId, required this.coverId});
  final String itemId;
  final String? coverId;

  static const _size = 132.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final media = ref.watch(mediaProvider(itemId)).value ?? const [];
    return SizedBox(
      height: _size + 16,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          for (final (i, m) in media.indexed)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => MediaViewer(itemId: itemId, initialIndex: i),
                  ),
                ),
                child: Stack(children: [
                  MediaThumb(mediaId: m.id, kind: m.mediaKind, size: _size, radius: 12),
                  if (m.id == coverId)
                    const Positioned(
                      left: 6,
                      top: 6,
                      child: Icon(Icons.star, color: Colors.amber, size: 20),
                    ),
                  if (m.mediaKind == MediaKind.video)
                    const Positioned.fill(
                      child: Center(
                        child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 40),
                      ),
                    ),
                ]),
              ),
            ),
          _AddMediaTile(itemId: itemId, size: _size),
        ],
      ),
    );
  }
}

class _AddMediaTile extends ConsumerWidget {
  const _AddMediaTile({required this.itemId, required this.size});
  final String itemId;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => addMediaTo(context, ref, itemId),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outlineVariant, width: 1.5),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.add_a_photo_outlined, color: scheme.primary),
          const SizedBox(height: 6),
          Text('Add photos', style: TextStyle(color: scheme.primary)),
        ]),
      ),
    );
  }
}

/// Lets the user take or choose photos, videos or files and attaches them.
Future<void> addMediaTo(BuildContext context, WidgetRef ref, String itemId) async {
  final source = await showModalBottomSheet<Future<List<File>> Function()>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (platform.canUseCamera) ...[
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Take photo'),
            onTap: () => Navigator.pop(context, () async => [?await platform.takePhoto()]),
          ),
          ListTile(
            leading: const Icon(Icons.videocam_outlined),
            title: const Text('Record video'),
            onTap: () => Navigator.pop(context, () async => [?await platform.recordVideo()]),
          ),
        ],
        if (platform.isMobile)
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose from photo library'),
            onTap: () => Navigator.pop(context, platform.pickFromLibrary),
          ),
        ListTile(
          leading: const Icon(Icons.folder_open_outlined),
          title: const Text('Choose files'),
          onTap: () => Navigator.pop(context, platform.pickFiles),
        ),
      ]),
    ),
  );
  if (source == null) return;
  final files = await source();
  if (files.isEmpty || !context.mounted) return;
  await withProgress(
    context,
    files.length == 1 ? 'Adding 1 file…' : 'Adding ${files.length} files…',
    () => ref.read(repositoryProvider).addMedia(itemId, files),
  );
}
