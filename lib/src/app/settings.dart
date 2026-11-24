import 'package:shared_preferences/shared_preferences.dart';

import '../labels/pdf_labels.dart';

/// Small per-device preferences: what was used last, so the walk-round
/// screens and the label printer pick up where they left off. Not synced.
class Settings {
  Settings(this._prefs);
  final SharedPreferences _prefs;

  static Future<Settings> load() async => Settings(await SharedPreferences.getInstance());

  String? get captureCollectionId => _prefs.getString('captureCollectionId');
  set captureCollectionId(String? v) => _set('captureCollectionId', v);

  String? get printerId => _prefs.getString('printerId');
  set printerId(String? v) => _set('printerId', v);

  String? get printerName => _prefs.getString('printerName');
  set printerName(String? v) => _set('printerName', v);

  String? get labelSizeId => _prefs.getString('labelSizeId');
  set labelSizeId(String? v) => _set('labelSizeId', v);

  int? get density => _prefs.getInt('density');
  set density(int? v) => v == null ? _prefs.remove('density') : _prefs.setInt('density', v);

  PdfLabelLayout get pdfLayout =>
      PdfLabelLayout.values.where((l) => l.name == _prefs.getString('pdfLayout')).firstOrNull ??
      PdfLabelLayout.a4;
  set pdfLayout(PdfLabelLayout v) => _prefs.setString('pdfLayout', v.name);

  // ---------------------------------------------------------------------- sync

  /// The sync server's base URL; null when this device doesn't sync.
  String? get serverUrl => _prefs.getString('serverUrl');
  set serverUrl(String? v) => _set('serverUrl', v);

  /// The device token from pairing. (Kept with the other preferences for
  /// now; the platform keychain would be better.)
  String? get syncToken => _prefs.getString('syncToken');
  set syncToken(String? v) => _set('syncToken', v);

  /// The account the token belongs to: its id decides whether a new pairing
  /// is the same library or another one.
  String? get syncUserId => _prefs.getString('syncUserId');
  set syncUserId(String? v) => _set('syncUserId', v);

  String? get syncUserName => _prefs.getString('syncUserName');
  set syncUserName(String? v) => _set('syncUserName', v);

  /// The server URL the cursor and outbox belong to.
  String? get syncedServer => _prefs.getString('syncedServer');
  set syncedServer(String? v) => _set('syncedServer', v);

  /// What this device calls itself when pairing.
  String? get deviceName => _prefs.getString('deviceName');
  set deviceName(String? v) => _set('deviceName', v);

  /// The last change pulled from the server (docs/sync-protocol.md).
  int get syncCursor => _prefs.getInt('syncCursor') ?? 0;
  set syncCursor(int v) => _prefs.setInt('syncCursor', v);

  /// When the last sync finished without an error (ms, UTC).
  int? get lastSyncAt => _prefs.getInt('lastSyncAt');
  set lastSyncAt(int? v) => v == null ? _prefs.remove('lastSyncAt') : _prefs.setInt('lastSyncAt', v);

  String? get lastSyncError => _prefs.getString('lastSyncError');
  set lastSyncError(String? v) => _set('lastSyncError', v);

  void _set(String key, String? v) => v == null ? _prefs.remove(key) : _prefs.setString(key, v);
}
