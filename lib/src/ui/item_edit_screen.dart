import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../data/database.dart';
import '../data/model.dart';
import '../data/repository.dart';

/// Creates an item (when [item] is null) or edits one. Pops with the item id.
class ItemEditScreen extends ConsumerStatefulWidget {
  const ItemEditScreen({super.key, required this.collectionId, this.item, this.initialLocationId});
  final String collectionId;
  final Item? item;
  final String? initialLocationId;

  @override
  ConsumerState<ItemEditScreen> createState() => _ItemEditScreenState();
}

class _ItemEditScreenState extends ConsumerState<ItemEditScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.item?.name ?? '');
  late final _notes = TextEditingController(text: widget.item?.notes ?? '');
  late String? _locationId = widget.item?.locationId ?? widget.initialLocationId;
  late final Map<String, Object?> _values = {...?widget.item?.values};
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    _form.currentState!.save();
    setState(() => _saving = true);
    final repo = ref.read(repositoryProvider);
    final existing = widget.item;
    final String id;
    if (existing == null) {
      id = (await repo.createItem(
        widget.collectionId,
        name: _name.text.trim(),
        locationId: _locationId,
        values: _values,
        notes: _notes.text.trim(),
      ))
          .id;
    } else {
      id = existing.id;
      await repo.updateItem(
        id,
        name: _name.text.trim(),
        locationId: Value(_locationId),
        values: _values,
        notes: _notes.text.trim(),
      );
    }
    if (mounted) Navigator.pop(context, id);
  }

  @override
  Widget build(BuildContext context) {
    final fields = ref.watch(fieldsProvider(widget.collectionId)).value ?? const [];
    final locations = ref.watch(locationsProvider).value ?? const <Location>[];
    final currency = ref.watch(collectionProvider(widget.collectionId)).value?.currency ?? 'USD';
    final sortedLocations = [...locations]
      ..sort((a, b) => locationPath(a, locations).compareTo(locationPath(b, locations)));

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.item == null ? 'New item' : 'Edit item'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: _saving ? null : _save, child: const Text('Save')),
          ),
        ],
      ),
      body: Form(
        key: _form,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextFormField(
                  controller: _name,
                  autofocus: widget.item == null,
                  decoration: const InputDecoration(labelText: 'Name'),
                  textCapitalization: TextCapitalization.sentences,
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Give it a name' : null,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String?>(
                  initialValue: locations.any((l) => l.id == _locationId) ? _locationId : null,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Location',
                    prefixIcon: Icon(Icons.place_outlined),
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('Not set')),
                    for (final l in sortedLocations)
                      DropdownMenuItem(value: l.id, child: Text(locationPath(l, locations))),
                  ],
                  onChanged: (v) => setState(() => _locationId = v),
                ),
                for (final f in fields) ...[
                  const SizedBox(height: 16),
                  FieldEditor(
                    key: ValueKey(f.id),
                    field: f,
                    currency: currency,
                    value: _values[f.id],
                    onChanged: (v) => _values[f.id] = v,
                  ),
                ],
                const SizedBox(height: 16),
                TextFormField(
                  controller: _notes,
                  decoration: const InputDecoration(labelText: 'Notes', alignLabelWithHint: true),
                  minLines: 3,
                  maxLines: 12,
                  textCapitalization: TextCapitalization.sentences,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The input for one field, chosen by its type. Reports null for "empty".
class FieldEditor extends StatefulWidget {
  const FieldEditor({
    super.key,
    required this.field,
    required this.value,
    required this.onChanged,
    this.currency = 'USD',
  });
  final FieldDef field;
  final Object? value;
  final ValueChanged<Object?> onChanged;
  final String currency;

  @override
  State<FieldEditor> createState() => _FieldEditorState();
}

class _FieldEditorState extends State<FieldEditor> {
  late final _text = TextEditingController(text: _initialText());
  late Object? _value = widget.value;

  String _initialText() {
    final v = widget.value;
    if (v == null) return '';
    if (v is num) return v == v.roundToDouble() ? v.toInt().toString() : v.toString();
    return v.toString();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _set(Object? v) {
    setState(() => _value = v);
    widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.field;
    switch (f.fieldType) {
      case FieldType.text:
      case FieldType.url:
      case FieldType.longText:
        final long = f.fieldType == FieldType.longText;
        return TextFormField(
          controller: _text,
          decoration: InputDecoration(labelText: f.name, alignLabelWithHint: long),
          keyboardType: f.fieldType == FieldType.url ? TextInputType.url : null,
          minLines: long ? 2 : 1,
          maxLines: long ? 8 : 1,
          textCapitalization:
              f.fieldType == FieldType.url ? TextCapitalization.none : TextCapitalization.sentences,
          onChanged: (s) => widget.onChanged(s.trim().isEmpty ? null : s.trim()),
        );
      case FieldType.number:
      case FieldType.currency:
        return TextFormField(
          controller: _text,
          decoration: InputDecoration(
            labelText: f.name,
            prefixText: f.fieldType == FieldType.currency ? '${widget.currency} ' : null,
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          validator: (s) {
            final t = (s ?? '').trim().replaceAll(',', '');
            return t.isEmpty || num.tryParse(t) != null ? null : 'Enter a number';
          },
          onChanged: (s) => widget.onChanged(num.tryParse(s.trim().replaceAll(',', ''))),
        );
      case FieldType.date:
        final date = _value is String ? DateTime.tryParse(_value as String) : null;
        return InkWell(
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: date ?? DateTime.now(),
              firstDate: DateTime(1900),
              lastDate: DateTime(2200),
            );
            if (picked != null) _set(DateFormat('yyyy-MM-dd').format(picked));
          },
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: f.name,
              suffixIcon: date == null
                  ? const Icon(Icons.calendar_today_outlined)
                  : IconButton(icon: const Icon(Icons.clear), onPressed: () => _set(null)),
            ),
            isEmpty: date == null,
            child: date == null ? null : Text(DateFormat.yMMMd().format(date)),
          ),
        );
      case FieldType.boolean:
        return DropdownButtonFormField<bool?>(
          initialValue: _value is bool ? _value as bool : null,
          decoration: InputDecoration(labelText: f.name),
          items: const [
            DropdownMenuItem(value: null, child: Text('Not set')),
            DropdownMenuItem(value: true, child: Text('Yes')),
            DropdownMenuItem(value: false, child: Text('No')),
          ],
          onChanged: _set,
        );
      case FieldType.choice:
        final choices = f.choices;
        final current = _value?.toString();
        return DropdownButtonFormField<String?>(
          initialValue: current,
          isExpanded: true,
          decoration: InputDecoration(labelText: f.name),
          items: [
            const DropdownMenuItem(value: null, child: Text('Not set')),
            for (final c in choices) DropdownMenuItem(value: c, child: Text(c)),
            // Keep a value that is no longer one of the choices selectable.
            if (current != null && !choices.contains(current))
              DropdownMenuItem(value: current, child: Text(current)),
          ],
          onChanged: _set,
        );
    }
  }
}
