import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../labels/pdf_labels.dart';

/// Small per-device preferences: what was used last, so the walk-round
/// screens and the label printer pick up where they left off. Not synced.
class Settings {
  Settings(this._prefs, {FlutterSecureStorage? secrets, this._syncToken}) : _secrets = secrets ?? _platformSecrets();
  final SharedPreferences _prefs;
  final FlutterSecureStorage _secrets;

  /// Reads the preferences and the device token. A token an older version
  /// kept with the preferences moves to the keychain.
  static Future<Settings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final secrets = _platformSecrets();
    var token = await _readToken(secrets);
    final old = prefs.getString(_legacyTokenKey);
    if (old != null) {
      token ??= old;
      try {
        await secrets.write(key: _tokenKey, value: token);
        await prefs.remove(_legacyTokenKey);
      } catch (_) {
        // No keychain to be had: keep using the old copy rather than lose it.
      }
    }
    return Settings(prefs, secrets: secrets, syncToken: token);
  }

  static const _tokenKey = 'syncToken', _legacyTokenKey = 'syncToken';

  /// The keychain on Apple platforms, the Keystore on Android, the
  /// Credential Manager on Windows. On macOS the legacy keychain, which needs
  /// no keychain-sharing entitlement or provisioning profile. On iOS the
  /// token stays on this device (not in backups to another one) and is
  /// readable once the phone has been unlocked after starting, so background
  /// syncs work.
  static FlutterSecureStorage _platformSecrets() => FlutterSecureStorage(
        iOptions: const IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
        mOptions: MacOsOptions(usesDataProtectionKeychain: !Platform.isMacOS),
      );

  static Future<String?> _readToken(FlutterSecureStorage secrets) async {
    try {
      return await secrets.read(key: _tokenKey);
    } catch (_) {
      return null;
    }
  }

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

  /// The device token from pairing, kept in the platform's secure storage
  /// (read once by [load]; writes go through in the background).
  String? get syncToken => _syncToken;
  String? _syncToken;
  set syncToken(String? v) {
    _syncToken = v;
    final write = v == null ? _secrets.delete(key: _tokenKey) : _secrets.write(key: _tokenKey, value: v);
    write.catchError((Object _) {});
    _prefs.remove(_legacyTokenKey);
  }

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
