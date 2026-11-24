import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../app/platform_io.dart' as platform;
import '../app/providers.dart';
import '../data/codes.dart';
import '../data/database.dart';
import '../data/repository.dart';
import 'common.dart';
import 'item_detail.dart';
import 'location_detail_screen.dart';
import 'location_picker.dart';
import 'scanner.dart';

// The phone tools for walking round a collection: look things up by their
// labels, put things away, check what's on a shelf, and photograph new
// things quickly to fill in later.

/// The hub of the walk-round tools.
class WalkRoundScreen extends StatelessWidget {
  const WalkRoundScreen({super.key});

  @override
  Widget build(BuildContext context) {
    void open(Widget page) => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));
    final tiles = [
      (Icons.qr_code_scanner, 'Find', 'Scan a label to open the item or the place', () => open(const FindScreen())),
      (Icons.move_down, 'Put away', 'Scan a shelf, then each thing you put on it', () => open(const PutAwayScreen())),
      (Icons.fact_check_outlined, 'Stocktake', 'Scan a shelf, then everything on it: see what’s missing',
          () => open(const StocktakeScreen())),
      (Icons.add_a_photo_outlined, 'Quick capture', 'Photograph new things now, fill in details later',
          () => open(const QuickCaptureScreen())),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Walk round')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        for (final (icon, title, subtitle, onTap) in tiles)
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              leading: Icon(icon, size: 36),
              title: Text(title, style: Theme.of(context).textTheme.titleMedium),
              subtitle: Text(subtitle),
              onTap: onTap,
            ),
          ),
      ]),
    );
  }
}

/// What a code is, or a message when it isn't anything.
Future<(ScanTarget?, String?)> _resolve(WidgetRef ref, String code) async {
  final target = await ref.read(repositoryProvider).resolveCode(code);
  return (target, target == null ? 'Nothing here has the code “$code”' : null);
}

void _toast(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
}

// ------------------------------------------------------------------- find

class FindScreen extends ConsumerWidget {
  const FindScreen({super.key, this.camera});
  final bool? camera;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Find')),
      body: CodeScanner(
        camera: camera,
        hint: 'Type a code, or a location’s label code',
        onCode: (code) async {
          final (target, error) = await _resolve(ref, code);
          if (!context.mounted) return;
          if (target == null) return _toast(context, error!);
          await Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => target.kind == CodeKind.item
                  ? ItemDetail(itemId: target.id)
                  : LocationDetailScreen(locationId: target.id),
            ),
          );
        },
      ),
    );
  }
}

// ------------------------------------------------------------------- put away

class PutAwayScreen extends ConsumerStatefulWidget {
  const PutAwayScreen({super.key, this.camera});
  final bool? camera;

  @override
  ConsumerState<PutAwayScreen> createState() => _PutAwayScreenState();
}

class _PutAwayScreenState extends ConsumerState<PutAwayScreen> {
  Location? _target;

  /// Moved this time, newest first, with where each came from (for undo).
  final _moved = <({Item item, String? from})>[];

  Future<void> _onCode(String code) async {
    final repo = ref.read(repositoryProvider);
    final (target, error) = await _resolve(ref, code);
    if (!mounted) return;
    if (target == null) return _toast(context, error!);
    if (target.kind == CodeKind.location) {
      final l = await repo.locationById(target.id);
      setState(() => _target = l);
      if (mounted && l != null) _toast(context, 'Putting things in ${l.name}');
      return;
    }
    final item = await repo.itemById(target.id);
    if (!mounted || item == null) return;
    final to = _target;
    if (to == null) return _toast(context, 'Scan the shelf or box first');
    if (item.locationId == to.id) return _toast(context, '${item.name} is already in ${to.name}');
    await repo.moveItem(item.id, to.id);
    setState(() => _moved.insert(0, (item: item, from: item.locationId)));
    if (mounted) _toast(context, '${item.name} → ${to.name}');
  }

  Future<void> _undo(int i) async {
    final m = _moved[i];
    await ref.read(repositoryProvider).moveItem(m.item.id, m.from);
    setState(() => _moved.removeAt(i));
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(locationsProvider).value ?? const <Location>[];
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Put away')),
      body: Column(children: [
        Material(
          color: _target == null ? scheme.tertiaryContainer : scheme.primaryContainer,
          child: ListTile(
            leading: const Icon(Icons.place),
            title: Text(_target == null ? 'Scan a shelf or box first' : 'Putting things in ${_target!.name}'),
            subtitle: Text(_target == null ? 'Or choose it from the list' : locationPath(_target!, all)),
            trailing: const Icon(Icons.edit_location_alt_outlined),
            onTap: () async {
              final picked = await chooseLocation(context, title: 'Put things in…');
              if (picked?.location != null) setState(() => _target = picked!.location);
            },
          ),
        ),
        Expanded(
          flex: 3,
          child: CodeScanner(
            camera: widget.camera,
            hint: _target == null ? 'Scan or type a location code' : 'Scan or type an item code',
            onCode: _onCode,
          ),
        ),
        if (_moved.isNotEmpty)
          Expanded(
            flex: 2,
            child: ListView(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text('Moved (${_moved.length})', style: Theme.of(context).textTheme.titleSmall),
              ),
              for (final (i, m) in _moved.indexed)
                ListTile(
                  dense: true,
                  leading: MediaThumb(mediaId: m.item.coverMediaId, size: 40),
                  title: Text(m.item.name),
                  subtitle: Text(
                    'from ${all.where((l) => l.id == m.from).firstOrNull?.name ?? 'no location'}',
                  ),
                  trailing: TextButton(onPressed: () => _undo(i), child: const Text('Undo')),
                ),
            ]),
          ),
      ]),
    );
  }
}

// ------------------------------------------------------------------- stocktake

/// Checks what's at a location against the catalogue: scan everything there,
/// then see what wasn't found and what turned up that belongs elsewhere.
/// Each thing found is stamped as seen today.
class StocktakeScreen extends ConsumerStatefulWidget {
  const StocktakeScreen({super.key, this.locationId, this.camera});
  final String? locationId;
  final bool? camera;

  @override
  ConsumerState<StocktakeScreen> createState() => _StocktakeScreenState();
}

class _StocktakeScreenState extends ConsumerState<StocktakeScreen> {
  late String? _locationId = widget.locationId;
  bool _inside = true;
  final _found = <String>{};

  /// When each found item was last seen before this stocktake, for unticking.
  final _before = <String, int?>{};

  /// Things scanned here that the catalogue puts somewhere else.
  final _strays = <Item>[];

  Future<void> _onCode(String code) async {
    final repo = ref.read(repositoryProvider);
    final (target, error) = await _resolve(ref, code);
    if (!mounted) return;
    if (target == null) return _toast(context, error!);
    if (_locationId == null) {
      if (target.kind != CodeKind.location) return _toast(context, 'Scan the shelf or box first');
      setState(() => _locationId = target.id);
      return;
    }
    if (target.kind == CodeKind.location) {
      if (target.id == _locationId) return;
      return _toast(context, 'That’s another location. Finish this stocktake first.');
    }
    final item = await repo.itemById(target.id);
    if (!mounted || item == null) return;
    final expected = _expectedIds();
    if (expected.contains(item.locationId)) {
      if (_found.add(item.id)) {
        _before.putIfAbsent(item.id, () => item.lastSeenAt);
        await repo.markSeen([item.id]);
        setState(() {});
      }
      if (mounted) _toast(context, 'Found ${item.name}');
    } else if (!_strays.any((s) => s.id == item.id)) {
      setState(() => _strays.insert(0, item));
      if (mounted) _toast(context, '${item.name} belongs somewhere else');
    }
  }

  Set<String> _expectedIds() {
    final all = ref.read(locationsProvider).value ?? const <Location>[];
    return _inside ? locationAndDescendants(_locationId!, all) : {_locationId!};
  }

  Future<void> _toggle(Item item) async {
    final repo = ref.read(repositoryProvider);
    if (_found.remove(item.id)) {
      setState(() {});
      // Put back the previous date: unticking is a correction, not news.
      await repo.setLastSeen(item.id, _before[item.id]);
    } else {
      _found.add(item.id);
      _before.putIfAbsent(item.id, () => item.lastSeenAt);
      setState(() {});
      await repo.markSeen([item.id]);
    }
  }

  Future<void> _moveHere(Item item) async {
    final repo = ref.read(repositoryProvider);
    await repo.moveItem(item.id, _locationId);
    await repo.markSeen([item.id]);
    setState(() {
      _strays.removeWhere((s) => s.id == item.id);
      _found.add(item.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(locationsProvider).value ?? const <Location>[];
    final location = all.where((l) => l.id == _locationId).firstOrNull;
    final theme = Theme.of(context);

    if (location == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Stocktake')),
        body: Column(children: [
          ListTile(
            leading: const Icon(Icons.place_outlined),
            title: const Text('Scan the shelf or box to check'),
            subtitle: const Text('Or choose it from the list'),
            trailing: const Icon(Icons.list),
            onTap: () async {
              final picked = await chooseLocation(context, title: 'Stocktake of…');
              if (picked?.location != null) setState(() => _locationId = picked!.location!.id);
            },
          ),
          Expanded(child: CodeScanner(camera: widget.camera, hint: 'Scan or type a location code', onCode: _onCode)),
        ]),
      );
    }

    final ids = _inside ? locationAndDescendants(location.id, all) : {location.id};
    final expected = ref.watch(itemsAtProvider(locationKey(ids))).value ?? const <Item>[];
    final missing = expected.where((i) => !_found.contains(i.id)).toList();
    final found = expected.where((i) => _found.contains(i.id)).toList();
    final hasChildren = all.any((l) => l.parentId == location.id);

    Widget row(Item item, {Widget? trailing}) => ListTile(
          dense: true,
          leading: MediaThumb(mediaId: item.coverMediaId, size: 40),
          title: Text(item.name),
          subtitle: Text([
            if (item.locationId != location.id) ?all.where((l) => l.id == item.locationId).firstOrNull?.name,
            item.lastSeenAt == null ? 'never checked' : 'checked ${lastSeenText(item.lastSeenAt!)}',
          ].join(' · ')),
          trailing: trailing,
        );

    return Scaffold(
      appBar: AppBar(title: Text('Stocktake: ${location.name}')),
      body: Column(children: [
        Material(
          color: theme.colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(children: [
              Expanded(
                child: Text('${found.length} of ${expected.length} found'
                    '${_strays.isEmpty ? '' : ' · ${_strays.length} from elsewhere'}',
                    style: theme.textTheme.titleMedium),
              ),
              if (hasChildren) ...[
                const Text('Places inside'),
                Switch(value: _inside, onChanged: (v) => setState(() => _inside = v)),
              ],
            ]),
          ),
        ),
        Expanded(
          flex: 3,
          child: CodeScanner(camera: widget.camera, hint: 'Scan or type an item code', onCode: _onCode),
        ),
        Expanded(
          flex: 3,
          child: ListView(children: [
            if (_strays.isNotEmpty) ...[
              _section(context, 'Not recorded here'),
              for (final s in _strays)
                row(s, trailing: TextButton(onPressed: () => _moveHere(s), child: const Text('Move here'))),
            ],
            _section(context, missing.isEmpty ? 'Nothing missing' : 'Not found yet (${missing.length})'),
            for (final i in missing)
              row(i, trailing: IconButton(
                tooltip: 'Found it (no label)',
                icon: const Icon(Icons.check_box_outline_blank),
                onPressed: () => _toggle(i),
              )),
            if (found.isNotEmpty) ...[
              _section(context, 'Found (${found.length})'),
              for (final i in found)
                row(i, trailing: IconButton(
                  tooltip: 'Not found after all',
                  icon: const Icon(Icons.check_box),
                  onPressed: () => _toggle(i),
                )),
            ],
          ]),
        ),
      ]),
    );
  }

  Widget _section(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );
}

// ------------------------------------------------------------------- quick capture

/// Photographs new things one after another, each becoming an item named by
/// the time, in the chosen collection and place. Details can follow later.
class QuickCaptureScreen extends ConsumerStatefulWidget {
  const QuickCaptureScreen({super.key});

  @override
  ConsumerState<QuickCaptureScreen> createState() => _QuickCaptureScreenState();
}

class _QuickCaptureScreenState extends ConsumerState<QuickCaptureScreen> {
  String? _collectionId;
  Location? _location;
  final _captured = <String>[];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _collectionId = ref.read(settingsProvider).captureCollectionId;
  }

  Future<void> _capture(Future<List<File>> Function() source, {required bool onePerFile}) async {
    final collectionId = _collectionId;
    if (collectionId == null) return;
    final List<File> files;
    try {
      files = await source();
    } catch (e) {
      if (mounted) _toast(context, '$e');
      return;
    }
    if (files.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final repo = ref.read(repositoryProvider);
      final groups = onePerFile ? [for (final f in files) [f]] : [files];
      for (final group in groups) {
        final item = await repo.createItem(
          collectionId,
          name: 'New item ${DateFormat('d MMM HH:mm:ss').format(DateTime.now())}',
          locationId: _location?.id,
        );
        await repo.addMedia(item.id, group);
        _captured.insert(0, item.id);
      }
    } catch (e) {
      if (mounted) _toast(context, 'Couldn’t save: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final collections = ref.watch(collectionsProvider).value ?? const <CollectionSummary>[];
    final all = ref.watch(locationsProvider).value ?? const <Location>[];
    if (_collectionId != null && collections.isNotEmpty && !collections.any((c) => c.collection.id == _collectionId)) {
      _collectionId = null;
    }
    _collectionId ??= collections.firstOrNull?.collection.id;
    final ready = _collectionId != null && !_busy;

    return Scaffold(
      appBar: AppBar(title: const Text('Quick capture')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (collections.isEmpty)
          const EmptyState(icon: Icons.inventory_2_outlined, title: 'Make a collection first')
        else ...[
          DropdownButtonFormField<String>(
            initialValue: _collectionId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Add to'),
            items: [
              for (final c in collections)
                DropdownMenuItem(value: c.collection.id, child: Text(c.collection.name)),
            ],
            onChanged: (id) {
              setState(() => _collectionId = id);
              ref.read(settingsProvider).captureCollectionId = id;
            },
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.place_outlined),
            title: Text(_location == null ? 'No location' : locationPath(_location!, all)),
            subtitle: const Text('Where the things are'),
            trailing: const Icon(Icons.edit_location_alt_outlined),
            onTap: () async {
              final picked = await chooseLocation(context, title: 'Where are they?', allowNone: true);
              if (picked != null) setState(() => _location = picked.location);
            },
          ),
          const SizedBox(height: 16),
          if (platform.canUseCamera)
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(64)),
              onPressed: ready ? () => _capture(() async => [?await platform.takePhoto()], onePerFile: true) : null,
              icon: const Icon(Icons.photo_camera, size: 28),
              label: const Text('Take a photo of the next thing'),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: ready
                ? () => _capture(platform.isMobile ? platform.pickFromLibrary : platform.pickFiles, onePerFile: true)
                : null,
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text('Choose photos: one new item each'),
          ),
          if (_busy) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
          if (_captured.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Captured (${_captured.length}): tap one to name it', style: Theme.of(context).textTheme.titleSmall),
            for (final id in _captured) _CapturedTile(itemId: id),
          ],
        ],
      ]),
    );
  }
}

class _CapturedTile extends ConsumerWidget {
  const _CapturedTile({required this.itemId});
  final String itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(itemProvider(itemId)).value;
    if (item == null) return const SizedBox();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: MediaThumb(mediaId: item.coverMediaId, size: 48),
      title: Text(item.name),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ItemDetail(itemId: item.id))),
    );
  }
}
