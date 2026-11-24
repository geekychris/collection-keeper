import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// The server answered 401: the device token is missing, wrong or revoked.
class Unauthorized implements Exception {
  const Unauthorized([this.message = 'Not signed in']);
  final String message;
  @override
  String toString() => message;
}

/// The server answered with an error other than 401.
class ServerError implements Exception {
  const ServerError(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => 'Server error $status: $message';
}

/// The server couldn't be reached (offline, wrong address, TLS failure…).
class NetworkError implements Exception {
  const NetworkError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One synced record: its protocol kind and its data in the collection
/// format's shape (docs/sync-protocol.md).
class SyncRecord {
  const SyncRecord(this.kind, this.data);
  final String kind;
  final Map<String, dynamic> data;

  String get id => data['id'] as String;
  int get updatedAt => (data['updatedAt'] as num).toInt();

  Map<String, dynamic> toJson() => {'kind': kind, 'data': data};
  factory SyncRecord.fromJson(Map<String, dynamic> json) =>
      SyncRecord(json['kind'] as String, (json['data'] as Map).cast<String, dynamic>());
}

typedef ServerInfo = ({String service, int apiVersion, String version, String name});
typedef SyncUser = ({String id, String username, String name});
typedef PairStart = ({
  String deviceCode,
  String userCode,
  String verifyUrl,
  int expiresIn,
  int interval,
});

/// `status` is pending, approved, denied or expired; [token] and [user] come
/// with approved.
typedef PairPoll = ({String status, String? token, SyncUser? user});
typedef PushResult = ({String kind, String id, String status, String? error});
typedef PullPage = ({List<SyncRecord> records, int cursor, bool more});

/// What the sync engine needs from a server. [HttpSyncApi] is the real one;
/// tests use a fake.
abstract class SyncApi {
  Future<List<PushResult>> push(List<SyncRecord> records);
  Future<PullPage> pull(int since, {int limit = 500});
  Future<bool> hasBlob(String sha256);
  Future<void> putBlob(String sha256, File file, String contentType);

  /// Downloads a blob into [dest] (written to a temporary file first).
  Future<void> getBlob(String sha256, File dest);
}

/// The sync protocol over HTTP, version 1.
class HttpSyncApi implements SyncApi {
  HttpSyncApi(String baseUrl, {this.token, http.Client? client})
      : base = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/'),
        _client = client ?? http.Client();

  final Uri base;
  final String? token;
  final http.Client _client;

  static const _timeout = Duration(seconds: 30);

  void close() => _client.close();

  Uri _url(String path, [Map<String, String>? query]) =>
      base.resolve('api/v1/$path').replace(queryParameters: query);

  Map<String, String> get _auth => {if (token != null) 'Authorization': 'Bearer $token'};

  Future<http.Response> _send(Future<http.Response> Function() request,
      {Duration timeout = _timeout}) async {
    try {
      return await request().timeout(timeout);
    } on TimeoutException {
      throw const NetworkError('The server took too long to answer');
    } on SocketException catch (e) {
      throw NetworkError('Can\'t reach the server: ${e.message}');
    } on HandshakeException catch (e) {
      throw NetworkError('Secure connection failed: ${e.message}');
    } on http.ClientException catch (e) {
      throw NetworkError('Can\'t reach the server: ${e.message}');
    }
  }

  dynamic _json(http.Response r) {
    _check(r.statusCode, r.body);
    try {
      return jsonDecode(utf8.decode(r.bodyBytes));
    } on FormatException {
      throw ServerError(r.statusCode, 'Not a Collection Keeper server (the answer isn\'t JSON)');
    }
  }

  void _check(int status, String body) {
    if (status >= 200 && status < 300) return;
    var message = body;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is String) message = decoded['error'] as String;
    } on FormatException {
      if (message.length > 200) message = '${message.substring(0, 200)}…';
    }
    if (status == 401) throw Unauthorized(message.isEmpty ? 'Not signed in' : message);
    throw ServerError(status, message);
  }

  Future<dynamic> _get(String path, [Map<String, String>? query]) async =>
      _json(await _send(() => _client.get(_url(path, query), headers: _auth)));

  Future<dynamic> _post(String path, Object body) async => _json(await _send(() => _client.post(
        _url(path),
        headers: {..._auth, 'Content-Type': 'application/json'},
        body: jsonEncode(body),
      )));

  Future<ServerInfo> info() async {
    final j = await _get('info') as Map;
    if (j['service'] != 'collection-keeper') {
      throw const ServerError(200, 'Not a Collection Keeper server');
    }
    return (
      service: j['service'] as String,
      apiVersion: (j['apiVersion'] as num).toInt(),
      version: j['version'] as String? ?? '',
      name: j['name'] as String? ?? 'Collection Keeper',
    );
  }

  Future<PairStart> pairStart({
    required String deviceName,
    required String platform,
    required String appVersion,
  }) async {
    final j = await _post('pair/start',
        {'deviceName': deviceName, 'platform': platform, 'appVersion': appVersion}) as Map;
    return (
      deviceCode: j['deviceCode'] as String,
      userCode: j['userCode'] as String,
      verifyUrl: j['verifyUrl'] as String,
      expiresIn: (j['expiresIn'] as num?)?.toInt() ?? 600,
      interval: (j['interval'] as num?)?.toInt() ?? 3,
    );
  }

  Future<PairPoll> pairPoll(String deviceCode) async {
    final j = await _post('pair/poll', {'deviceCode': deviceCode}) as Map;
    final user = j['user'] as Map?;
    return (
      status: j['status'] as String,
      token: j['token'] as String?,
      user: user == null ? null : _user(user),
    );
  }

  Future<SyncUser> me() async => _user((await _get('me') as Map)['user'] as Map);

  static SyncUser _user(Map j) => (
        id: j['id'] as String,
        username: j['username'] as String? ?? '',
        name: j['name'] as String? ?? j['username'] as String? ?? '',
      );

  @override
  Future<List<PushResult>> push(List<SyncRecord> records) async {
    final j = await _post('sync/push', {'records': [for (final r in records) r.toJson()]}) as Map;
    return [
      for (final r in (j['results'] as List).cast<Map>())
        (
          kind: r['kind'] as String,
          id: r['id'] as String,
          status: r['status'] as String,
          error: r['error'] as String?,
        ),
    ];
  }

  @override
  Future<PullPage> pull(int since, {int limit = 500}) async {
    final j = await _get('sync/pull', {'since': '$since', 'limit': '$limit'}) as Map;
    return (
      records: [
        for (final r in (j['records'] as List).cast<Map>())
          SyncRecord.fromJson(r.cast<String, dynamic>()),
      ],
      cursor: (j['cursor'] as num).toInt(),
      more: j['more'] as bool? ?? false,
    );
  }

  @override
  Future<bool> hasBlob(String sha256) async {
    final r = await _send(() => _client.head(_url('blobs/$sha256'), headers: _auth));
    if (r.statusCode == 404) return false;
    _check(r.statusCode, r.body);
    return true;
  }

  @override
  Future<void> putBlob(String sha256, File file, String contentType) async {
    final request = http.StreamedRequest('PUT', _url('blobs/$sha256'))
      ..headers.addAll({..._auth, 'Content-Type': contentType.isEmpty ? 'application/octet-stream' : contentType})
      ..contentLength = await file.length();
    // Videos can be large: no overall timeout, only one on connecting.
    final sent = _sendStreamed(request);
    file.openRead().listen(request.sink.add,
        onDone: request.sink.close, onError: request.sink.addError, cancelOnError: true);
    final response = await sent;
    _check(response.statusCode, await response.stream.bytesToString());
  }

  @override
  Future<void> getBlob(String sha256, File dest) async {
    final response =
        await _sendStreamed(http.Request('GET', _url('blobs/$sha256'))..headers.addAll(_auth));
    if (response.statusCode != 200) {
      _check(response.statusCode, await response.stream.bytesToString());
    }
    await dest.parent.create(recursive: true);
    final part = File('${dest.path}.part');
    try {
      await response.stream.pipe(part.openWrite());
      await part.rename(dest.path);
    } catch (_) {
      if (await part.exists()) await part.delete();
      rethrow;
    }
  }

  Future<http.StreamedResponse> _sendStreamed(http.BaseRequest request) async {
    try {
      return await _client.send(request).timeout(const Duration(minutes: 30));
    } on TimeoutException {
      throw const NetworkError('The transfer took too long');
    } on SocketException catch (e) {
      throw NetworkError('Can\'t reach the server: ${e.message}');
    } on HandshakeException catch (e) {
      throw NetworkError('Secure connection failed: ${e.message}');
    } on http.ClientException catch (e) {
      throw NetworkError('Can\'t reach the server: ${e.message}');
    }
  }
}
