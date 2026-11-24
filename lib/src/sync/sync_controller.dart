import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/widgets.dart';

import '../app/settings.dart';
import '../data/repository.dart';
import 'sync_api.dart';
import 'sync_engine.dart';

enum SyncStatus {
  /// No server set, or disconnected.
  off,
  idle,
  syncing,

  /// The last attempt failed (often just no connection); it tries again.
  error,

  /// The server refused the token: connect again.
  needsPairing,
}

typedef SyncApiFactory = SyncApi Function(String serverUrl, String token);

/// Keeps this device in sync with its server, if it has one: on start, when
/// the app comes back to the foreground, a few seconds after a local change,
/// and every few minutes while open. Never two syncs at once.
class SyncController extends ChangeNotifier {
  SyncController(this.repo, this.settings, {SyncApiFactory? api})
      : _apiFactory = api ?? ((url, token) => HttpSyncApi(url, token: token));

  final Repository repo;
  final Settings settings;
  final SyncApiFactory _apiFactory;

  static const period = Duration(minutes: 5);
  static const afterChange = Duration(seconds: 5);

  SyncStatus _status = SyncStatus.off;
  SyncStatus get status => _status;
  String? get error => settings.lastSyncError;
  int get lastSyncAt => settings.lastSyncAt ?? 0;
  SyncResult? lastResult;

  /// Local changes the server hasn't had yet.
  int pending = 0;

  bool get connected => settings.serverUrl != null && settings.syncToken != null;

  Future<void>? _running, _queued;
  Timer? _timer, _soon;
  StreamSubscription<int>? _outbox;
  AppLifecycleListener? _lifecycle;
  bool _disposed = false;

  /// Starts watching the outbox and, when connected, syncing.
  void start() {
    var first = true;
    _outbox ??= SyncEngine(repo, _NoApi()).watchOutboxCount().listen((count) {
      final grew = count > pending && !first;
      first = false;
      pending = count;
      _notify();
      if (grew && connected && _status != SyncStatus.needsPairing) {
        _soon?.cancel();
        _soon = Timer(afterChange, syncNow);
      }
    });
    if (!connected) return;
    _status = SyncStatus.idle;
    _timer ??= Timer.periodic(period, (_) => syncNow());
    _lifecycle ??= AppLifecycleListener(onResume: syncNow);
    unawaited(syncNow());
  }

  void _stopTimers() {
    _timer?.cancel();
    _soon?.cancel();
    _timer = _soon = null;
    _lifecycle?.dispose();
    _lifecycle = null;
  }

  /// Syncs now; while a sync is running, once more after it (the future
  /// completes when that one has).
  Future<void> syncNow() {
    if (!connected || _disposed) return Future.value();
    final running = _running;
    if (running != null) {
      return _queued ??= running.then((_) {
        _queued = null;
        return syncNow();
      });
    }
    return _running = _run().whenComplete(() => _running = null);
  }

  Future<void> _run() async {
    final url = settings.serverUrl!, token = settings.syncToken!;
    final api = _apiFactory(url, token);
    _status = SyncStatus.syncing;
    _notify();
    try {
      final result = await SyncEngine(repo, api).syncOnce(settings.syncCursor);
      settings.syncCursor = result.cursor;
      settings.lastSyncAt = DateTime.now().millisecondsSinceEpoch;
      settings.lastSyncError = null;
      lastResult = result;
      _status = SyncStatus.idle;
      developer.log('sync: $result', name: 'sync');
    } on Unauthorized catch (e) {
      settings.lastSyncError = 'The server no longer accepts this device ($e). Connect again.';
      _status = SyncStatus.needsPairing;
      _stopTimers();
    } catch (e) {
      settings.lastSyncError = '$e';
      _status = SyncStatus.error;
      developer.log('sync failed: $e', name: 'sync');
    } finally {
      if (api is HttpSyncApi) api.close();
    }
    _notify();
  }

  /// Called once pairing gave this device a token. A different server or
  /// account starts over: everything here goes into the outbox (so the two
  /// libraries merge) and the whole library is pulled.
  Future<void> connect(String serverUrl, String token, SyncUser user) async {
    final sameLibrary = settings.syncedServer == serverUrl && settings.syncUserId == user.id;
    if (!sameLibrary) {
      await SyncEngine(repo, _NoApi()).fillOutbox();
      settings.syncCursor = 0;
      settings.lastSyncAt = null;
    }
    settings
      ..serverUrl = serverUrl
      ..syncToken = token
      ..syncUserId = user.id
      ..syncUserName = user.name.isEmpty ? user.username : user.name
      ..syncedServer = serverUrl
      ..lastSyncError = null;
    _status = SyncStatus.idle;
    start();
  }

  /// Stops syncing and forgets the token. Local data stays.
  void disconnect() {
    _stopTimers();
    settings.syncToken = null;
    settings.lastSyncError = null;
    _status = SyncStatus.off;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTimers();
    _outbox?.cancel();
    super.dispose();
  }
}

/// For the engine's local-only helpers (outbox), which never call the server.
class _NoApi implements SyncApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('no server');
}
