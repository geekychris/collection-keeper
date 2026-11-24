import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/platform_io.dart' as platform;
import '../app/providers.dart';
import '../data/repository.dart';
import '../data/templates.dart';
import '../exchange/exchange.dart';
import 'collection_screen.dart';
import 'common.dart';
import 'locations_screen.dart';
import 'sync_screen.dart';
import 'walk_round.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collections = ref.watch(collectionsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Collections'),
        actions: [
          IconButton(
            tooltip: 'Walk round: scan, put away, stocktake',
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const WalkRoundScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Locations',
            icon: const Icon(Icons.warehouse_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const LocationsScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Import a collection',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: () => _import(context, ref),
          ),
          const SyncButton(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _create(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('New collection'),
      ),
      body: AsyncBody(
        value: collections,
        builder: (list) => list.isEmpty
            ? EmptyState(
                icon: Icons.inventory_2_outlined,
                title: 'No collections yet',
                message: 'Make one for each kind of thing you collect: '
                    'retro computers, software, stamps…',
                action: FilledButton.icon(
                  onPressed: () => _create(context, ref),
                  icon: const Icon(Icons.add),
                  label: const Text('New collection'),
                ),
              )
            : GridView.builder(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 280,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 0.85,
                ),
                itemCount: list.length,
                itemBuilder: (context, i) => _CollectionCard(summary: list[i]),
              ),
      ),
    );
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final created = await showDialog<String>(
      context: context,
      builder: (_) => const NewCollectionDialog(),
    );
    if (created != null && context.mounted) {
      Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => CollectionScreen(collectionId: created)),
      );
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final zip = await platform.pickZip();
    if (zip == null || !context.mounted) return;
    final result = await withProgress(
      context,
      'Importing…',
      () => Exchange(ref.read(repositoryProvider)).importZip(zip),
    );
    if (result != null && context.mounted) showMessage(context, result.toString());
  }
}

class _CollectionCard extends StatelessWidget {
  const _CollectionCard({required this.summary});
  final CollectionSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = summary.collection;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => CollectionScreen(collectionId: c.id)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => MediaThumb(
                mediaId: summary.coverMediaId,
                size: box.maxWidth,
                radius: 0,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.name,
                  style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(
                summary.itemCount == 1 ? '1 item' : '${summary.itemCount} items',
                style: theme.textTheme.bodySmall,
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Asks for a name and template and creates the collection. Pops with its id.
class NewCollectionDialog extends ConsumerStatefulWidget {
  const NewCollectionDialog({super.key});

  @override
  ConsumerState<NewCollectionDialog> createState() => _NewCollectionDialogState();
}

class _NewCollectionDialogState extends ConsumerState<NewCollectionDialog> {
  final _name = TextEditingController();
  final _currency = TextEditingController(text: 'USD');
  String _template = collectionTemplates.first.id;

  @override
  void dispose() {
    _name.dispose();
    _currency.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final c = await ref.read(repositoryProvider).createCollection(
          name: name,
          templateId: _template,
          currency: _currency.text.trim().toUpperCase().ifEmpty('USD'),
        );
    if (mounted) Navigator.pop(context, c.id);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New collection'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
              textCapitalization: TextCapitalization.sentences,
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _template,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Start from'),
              items: [
                for (final t in collectionTemplates)
                  DropdownMenuItem(value: t.id, child: Text(t.name)),
              ],
              onChanged: (v) => setState(() => _template = v ?? _template),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${CollectionTemplate.byId(_template).description} '
                'Fields: ${CollectionTemplate.byId(_template).fields.map((f) => f.name).join(', ')}. '
                'You can change them later.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _currency,
              decoration: const InputDecoration(labelText: 'Currency', helperText: 'e.g. USD, GBP, EUR'),
              textCapitalization: TextCapitalization.characters,
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
