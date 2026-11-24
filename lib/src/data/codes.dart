import 'dart:convert';
import 'dart:typed_data';

/// What a label's QR code points at.
enum CodeKind { item, location }

/// A scanned or typed code, resolved to a kind and a record id.
typedef ScanTarget = ({CodeKind kind, String id});

/// The text in a label's QR code: `ck:i:<id>` for an item and `ck:l:<id>` for
/// a location, with the UUID packed into 22 URL-safe base64 characters so the
/// code stays small enough for 12 mm labels.
String labelCode(CodeKind kind, String id) =>
    'ck:${kind == CodeKind.item ? 'i' : 'l'}:${_pack(id) ?? id}';

/// Reads a code from a label. Accepts the `ck:` form, the same in a URL
/// (`…/i/<id>` or `…/l/<id>`, for links a future server may print). Returns
/// null for anything else; [Repository.resolveCode] also tries bare UUIDs and
/// location label codes.
ScanTarget? parseLabelCode(String raw) {
  final text = raw.trim();
  final m = RegExp(r'^ck:([il]):([A-Za-z0-9_\-]+)$').firstMatch(text) ??
      RegExp(r'^https?://[^ ]+/([il])/([A-Za-z0-9_\-]+)/?$').firstMatch(text);
  if (m == null) return null;
  final id = _unpack(m.group(2)!) ?? (_isUuid(m.group(2)!) ? m.group(2)!.toLowerCase() : null);
  if (id == null) return null;
  return (kind: m.group(1) == 'i' ? CodeKind.item : CodeKind.location, id: id);
}

bool isUuid(String s) => _isUuid(s.trim());

bool _isUuid(String s) =>
    RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
        .hasMatch(s);

String? _pack(String uuid) {
  if (!_isUuid(uuid)) return null;
  final hex = uuid.replaceAll('-', '');
  final bytes = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return base64Url.encode(bytes).replaceAll('=', '');
}

String? _unpack(String packed) {
  if (packed.length != 22) return null;
  try {
    final bytes = base64Url.decode('$packed==');
    if (bytes.length != 16) return null;
    final hex = [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  } on FormatException {
    return null;
  }
}
