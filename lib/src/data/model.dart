import 'dart:convert';

import 'database.dart';

enum FieldType {
  text('Text'),
  longText('Long text'),
  number('Number'),
  currency('Money'),
  date('Date'),
  boolean('Yes / no'),
  url('Link'),
  choice('Choice');

  const FieldType(this.label);
  final String label;

  static FieldType parse(String name) =>
      FieldType.values.firstWhere((t) => t.name == name, orElse: () => text);
}

enum MediaKind {
  photo,
  video,
  document;

  static MediaKind parse(String name) =>
      MediaKind.values.firstWhere((k) => k.name == name, orElse: () => document);

  static MediaKind fromExtension(String ext) {
    switch (ext.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'heic':
      case 'heif':
      case 'webp':
      case 'gif':
      case 'bmp':
      case 'tif':
      case 'tiff':
        return photo;
      case 'mov':
      case 'mp4':
      case 'm4v':
      case 'avi':
      case 'mkv':
      case 'webm':
      case '3gp':
        return video;
      default:
        return document;
    }
  }
}

int nowMs() => DateTime.now().toUtc().millisecondsSinceEpoch;

extension FieldDefX on FieldDef {
  FieldType get fieldType => FieldType.parse(type);

  List<String> get choices => options
      .split('\n')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}

extension ItemX on Item {
  Map<String, Object?> get values {
    try {
      final decoded = jsonDecode(fieldValues);
      return decoded is Map<String, dynamic> ? decoded : {};
    } on FormatException {
      return {};
    }
  }
}

extension MediaEntryX on MediaEntry {
  MediaKind get mediaKind => MediaKind.parse(kind);
}

/// Renders a stored field value for display, or null when it is empty.
String? formatFieldValue(FieldDef def, Object? value, {String currency = 'USD'}) {
  if (value == null) return null;
  switch (def.fieldType) {
    case FieldType.boolean:
      return value == true ? 'Yes' : 'No';
    case FieldType.number:
      return value is num ? _trimNumber(value) : value.toString();
    case FieldType.currency:
      return value is num ? '$currency ${value.toStringAsFixed(2)}' : value.toString();
    default:
      final s = value.toString();
      return s.isEmpty ? null : s;
  }
}

String _trimNumber(num n) =>
    n == n.roundToDouble() ? n.toInt().toString() : n.toString();
