import 'model.dart';

class FieldTemplate {
  const FieldTemplate(this.name, this.type, [this.choices = const []]);
  final String name;
  final FieldType type;
  final List<String> choices;
}

/// A starting schema for a new collection. Fields can be changed afterwards.
class CollectionTemplate {
  const CollectionTemplate({
    required this.id,
    required this.name,
    required this.description,
    required this.fields,
  });
  final String id;
  final String name;
  final String description;
  final List<FieldTemplate> fields;

  static CollectionTemplate byId(String id) =>
      collectionTemplates.firstWhere((t) => t.id == id, orElse: () => _general);
}

const _condition = FieldTemplate('Condition', FieldType.choice,
    ['Mint', 'Excellent', 'Good', 'Fair', 'Poor', 'For parts']);
const _acquired = FieldTemplate('Date acquired', FieldType.date);
const _cost = FieldTemplate('Cost', FieldType.currency);
const _value = FieldTemplate('Current value', FieldType.currency);
const _provenance = FieldTemplate('Provenance', FieldType.longText);

const _general = CollectionTemplate(
  id: 'general',
  name: 'General',
  description: 'Anything: the basic fields every collection needs.',
  fields: [
    FieldTemplate('Manufacturer', FieldType.text),
    _condition,
    _acquired,
    _cost,
    _value,
  ],
);

const _retroComputers = CollectionTemplate(
  id: 'retro-computers',
  name: 'Retro computers',
  description: 'Computers, consoles and peripherals.',
  fields: [
    FieldTemplate('Manufacturer', FieldType.text),
    FieldTemplate('Model', FieldType.text),
    FieldTemplate('Year', FieldType.number),
    FieldTemplate('Serial number', FieldType.text),
    FieldTemplate('Board revision', FieldType.text),
    FieldTemplate('CPU', FieldType.text),
    FieldTemplate('Memory', FieldType.text),
    FieldTemplate('Working status', FieldType.choice,
        ['Working', 'Partly working', 'Not working', 'Untested']),
    _condition,
    FieldTemplate('Recapped', FieldType.boolean),
    FieldTemplate('Battery removed', FieldType.boolean),
    _acquired,
    _cost,
    _value,
    _provenance,
  ],
);

const _software = CollectionTemplate(
  id: 'software',
  name: 'Software and games',
  description: 'Boxed software, disks, cartridges and manuals.',
  fields: [
    FieldTemplate('Publisher', FieldType.text),
    FieldTemplate('Platform', FieldType.text),
    FieldTemplate('Year', FieldType.number),
    FieldTemplate('Media', FieldType.choice,
        ['Floppy disk', 'Cartridge', 'Cassette', 'CD', 'DVD', 'Other']),
    FieldTemplate('Complete in box', FieldType.boolean),
    FieldTemplate('Manual', FieldType.boolean),
    _condition,
    _acquired,
    _cost,
    _value,
  ],
);

const _vehicles = CollectionTemplate(
  id: 'vehicles',
  name: 'Vehicles',
  description: 'Cars, motorcycles and bicycles.',
  fields: [
    FieldTemplate('Make', FieldType.text),
    FieldTemplate('Model', FieldType.text),
    FieldTemplate('Year', FieldType.number),
    FieldTemplate('VIN / frame number', FieldType.text),
    FieldTemplate('Registration', FieldType.text),
    FieldTemplate('Mileage', FieldType.number),
    _condition,
    _acquired,
    _cost,
    _value,
    _provenance,
  ],
);

const _stamps = CollectionTemplate(
  id: 'stamps',
  name: 'Stamps and coins',
  description: 'Philately and numismatics.',
  fields: [
    FieldTemplate('Country', FieldType.text),
    FieldTemplate('Year', FieldType.number),
    FieldTemplate('Catalogue number', FieldType.text),
    FieldTemplate('Denomination', FieldType.text),
    _condition,
    _acquired,
    _cost,
    _value,
  ],
);

const List<CollectionTemplate> collectionTemplates = [
  _general,
  _retroComputers,
  _software,
  _vehicles,
  _stamps,
];
