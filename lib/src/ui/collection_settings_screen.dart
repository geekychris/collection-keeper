import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../data/database.dart';
import '../data/model.dart';
import 'common.dart';

/// A collection's name, currency and fields.
class CollectionSettingsScreen extends ConsumerWidget {
  const CollectionSettingsScreen({super.key, required this.collectionId});
  final String collectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collection = ref.watch(collectionProvider(collectionId)).value;
    final fields = ref.watch(fieldsProvider(collectionId)).value ?? const <FieldDef>[];
    final repo = ref.read(repositoryProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Collection settings')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editField(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('Add field'),
      ),
      body: collection == null
          ? const SizedBox.shrink()
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: CustomScrollView(slivers: [
                  SliverList.list(children: [
                    ListTile(
                      title: const Text('Name'),
                      subtitle: Text(collection.name),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: () async {
                        final v = await _prompt(context, 'Name', collection.name);
                        if (v != null && v.isNotEmpty) await repo.updateCollection(collectionId, name: v);
                      },
                    ),
                    ListTile(
                      title: const Text('Description'),
                      subtitle: Text(collection.description.isEmpty ? 'None' : collection.description),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: () async {
                        final v = await _prompt(context, 'Description', collection.description, lines: 4);
                        if (v != null) await repo.updateCollection(collectionId, description: v);
                      },
                    ),
                    ListTile(
                      title: const Text('Currency'),
                      subtitle: Text(collection.currency),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: () async {
                        final v = await _prompt(context, 'Currency (e.g. USD, GBP)', collection.currency);
                        if (v != null && v.isNotEmpty) {
                          await repo.updateCollection(collectionId, currency: v.toUpperCase());
                        }
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
                      child: Text('Fields', style: theme.textTheme.titleMedium),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text('Every item in this collection has these. Drag to reorder.',
                          style: theme.textTheme.bodySmall),
                    ),
                  ]),
                  SliverReorderableList(
                    itemCount: fields.length,
                    onReorderItem: (from, to) {
                      final ids = fields.map((f) => f.id).toList();
                      ids.insert(to, ids.removeAt(from));
                      repo.reorderFields(ids);
                    },
                    itemBuilder: (context, i) {
                      final f = fields[i];
                      return Material(
                        key: ValueKey(f.id),
                        child: ListTile(
                          leading: ReorderableDragStartListener(
                            index: i,
                            child: const Icon(Icons.drag_indicator),
                          ),
                          title: Text(f.name),
                          subtitle: Text(f.fieldType == FieldType.choice
                              ? '${f.fieldType.label}: ${f.choices.join(', ')}'
                              : f.fieldType.label),
                          onTap: () => _editField(context, ref, f),
                          trailing: IconButton(
                            tooltip: 'Remove field',
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: () async {
                              final ok = await confirm(context,
                                  title: 'Remove ${f.name}?',
                                  message: 'Items stop showing this field.',
                                  action: 'Remove');
                              if (ok) await repo.deleteField(f.id);
                            },
                          ),
                        ),
                      );
                    },
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 96)),
                ]),
              ),
            ),
    );
  }

  Future<void> _editField(BuildContext context, WidgetRef ref, FieldDef? field) async {
    final result = await showDialog<({String name, FieldType type, List<String> choices})>(
      context: context,
      builder: (_) => _FieldDialog(field: field),
    );
    if (result == null) return;
    final repo = ref.read(repositoryProvider);
    if (field == null) {
      await repo.addField(collectionId, name: result.name, type: result.type, choices: result.choices);
    } else {
      await repo.updateField(field.id, name: result.name, choices: result.choices);
    }
  }
}

Future<String?> _prompt(BuildContext context, String label, String initial, {int lines = 1}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(label),
      content: SizedBox(
        width: 400,
        child: TextField(
          controller: controller,
          autofocus: true,
          minLines: lines,
          maxLines: lines,
          onSubmitted: lines == 1 ? (v) => Navigator.pop(context, v.trim()) : null,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}

class _FieldDialog extends StatefulWidget {
  const _FieldDialog({this.field});
  final FieldDef? field;

  @override
  State<_FieldDialog> createState() => _FieldDialogState();
}

class _FieldDialogState extends State<_FieldDialog> {
  late final _name = TextEditingController(text: widget.field?.name ?? '');
  late final _choices = TextEditingController(text: widget.field?.choices.join('\n') ?? '');
  late FieldType _type = widget.field?.fieldType ?? FieldType.text;

  @override
  void dispose() {
    _name.dispose();
    _choices.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, (
      name: name,
      type: _type,
      choices: _choices.text.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.field != null;
    return AlertDialog(
      title: Text(editing ? 'Edit field' : 'New field'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<FieldType>(
              initialValue: _type,
              decoration: InputDecoration(
                labelText: 'Type',
                helperText: editing ? 'The type can\'t change once items may use it' : null,
              ),
              items: [
                for (final t in FieldType.values) DropdownMenuItem(value: t, child: Text(t.label)),
              ],
              onChanged: editing ? null : (t) => setState(() => _type = t ?? _type),
            ),
            if (_type == FieldType.choice) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _choices,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: 'Choices',
                  helperText: 'One per line',
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: Text(editing ? 'Save' : 'Add')),
      ],
    );
  }
}
