import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'backup_codec.dart';
import 'drive_auth.dart';

class DriveSyncException implements Exception {
  const DriveSyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

class DriveRevision {
  const DriveRevision({
    required this.id,
    required this.parents,
    required this.checksum,
    required this.modifiedAt,
    required this.bytes,
  });
  final String id;
  final List<String> parents;
  final String checksum;
  final DateTime modifiedAt;
  final int bytes;

  factory DriveRevision.fromFile(Map<String, dynamic> file) {
    try {
      final description = jsonDecode(file['description'] as String) as Map;
      final parents = (description['parents'] as List).cast<String>();
      final checksum = description['sha256'] as String;
      final id = file['id'] as String;
      final bytes = int.parse(file['size'] as String);
      if (description['tegnalSync'] != 1 ||
          parents.length > 128 ||
          parents.toSet().length != parents.length ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(checksum) ||
          parents.any((p) => p == id || !_validId(p)) ||
          !_validId(id) ||
          bytes < 1 ||
          bytes > BackupCodec.maximumBytes) {
        throw const FormatException();
      }
      return DriveRevision(
        id: id,
        parents: parents,
        checksum: checksum,
        modifiedAt: DateTime.parse(file['modifiedTime'] as String),
        bytes: bytes,
      );
    } catch (_) {
      throw const DriveSyncException(
        'A Drive revision has invalid metadata. No library data was changed.',
      );
    }
  }
  static bool _validId(String id) =>
      RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch(id);
}

abstract interface class DriveRepository {
  Future<List<DriveRevision>> revisions();
  Future<String> read(DriveRevision revision);
  Future<DriveRevision> publish(String nativeJson, List<String> parents);
  void dispose();
}

/// Append-only native JSON revisions. Concurrent devices publish sibling heads
/// rather than overwriting one another; the next sync surfaces that conflict.
/// Drive's file scope only exposes files created/opened with this application.
class GoogleDriveRepository implements DriveRepository {
  GoogleDriveRepository(this.auth, {http.Client? client})
    : _client = client ?? http.Client(),
      _account = auth.identity?.id;
  final DriveAuth auth;
  final String? _account;
  final http.Client _client;
  static const _fileFields = 'id,description,modifiedTime,size';
  static Uri _api(String path, [Map<String, String>? query]) =>
      Uri.https('www.googleapis.com', '/drive/v3/$path', query);

  Future<http.Response> _request(
    String method,
    Uri uri, {
    String? body,
    List<int>? bytes,
    Map<String, String> headers = const {},
    int maximumBytes = 4 * 1024 * 1024,
  }) async {
    if (_account == null || auth.identity?.id != _account) {
      throw const DriveSyncException(
        'The Google account changed. Reconnect before syncing.',
      );
    }
    final token = await auth.accessToken();
    if (auth.identity?.id != _account) {
      throw const DriveSyncException(
        'The Google account changed. Reconnect before syncing.',
      );
    }
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers.addAll({'Authorization': 'Bearer $token', ...headers});
    if (bytes != null) request.bodyBytes = bytes;
    if (body != null) request.body = body;
    try {
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 90));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.take(1).drain<void>();
        throw DriveSyncException(switch (response.statusCode) {
          401 => 'Google authorization expired. Reconnect Google Drive.',
          403 => 'Google Drive denied access. Check permission, storage, and API configuration.',
          404 =>
            'A Drive revision is no longer available. Refresh before syncing.',
          429 => 'Google Drive is busy. Try again later.',
          _ => 'Google Drive could not complete the request. Try again.',
        });
      }
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 60),
      )) {
        if (buffer.length + chunk.length > maximumBytes) {
          throw const DriveSyncException(
            'The Drive response exceeds the supported size.',
          );
        }
        buffer.add(chunk);
      }
      return http.Response.bytes(
        buffer.takeBytes(),
        response.statusCode,
        headers: response.headers,
      );
    } on DriveSyncException {
      rethrow;
    } on Exception {
      throw const DriveSyncException(
        'Unable to reach Google Drive. Check your connection and try again.',
      );
    }
  }

  Future<List<Map<String, dynamic>>> _files(String kind) async {
    final result = <Map<String, dynamic>>[];
    String? page;
    final visited = <String>{};
    do {
      final response = await _request(
        'GET',
        _api('files', {
          'q':
              "trashed = false and appProperties has { key='tegnalSync' and value='1' } and appProperties has { key='kind' and value='$kind' }",
          'spaces': 'drive',
          'pageSize': '1000',
          'fields':
              'nextPageToken,files(${kind == 'folder' ? 'id' : _fileFields})',
          'pageToken': ?page,
        }),
      );
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      result.addAll(
        (data['files'] as List? ?? []).cast<Map<String, dynamic>>(),
      );
      page = data['nextPageToken'] as String?;
      if (result.length > 10000 || (page != null && !visited.add(page))) {
        throw const DriveSyncException(
          'The Drive revision history is too large to sync safely.',
        );
      }
    } while (page != null);
    return result;
  }

  @override
  Future<List<DriveRevision>> revisions() async =>
      (await _files('snapshot')).map(DriveRevision.fromFile).toList();

  @override
  Future<String> read(DriveRevision revision) async {
    final response = await _request(
      'GET',
      _api('files/${revision.id}', {'alt': 'media'}),
      maximumBytes: BackupCodec.maximumBytes,
    );
    if (response.bodyBytes.length != revision.bytes ||
        sha256.convert(response.bodyBytes).toString() != revision.checksum) {
      throw const DriveSyncException(
        'The Drive file changed or is damaged. Your library was not replaced.',
      );
    }
    return utf8.decode(response.bodyBytes);
  }

  Future<String> _folder() async {
    final existing = await _files('folder');
    if (existing.isNotEmpty) {
      final ids = existing.map((f) => f['id'] as String).toList()..sort();
      return ids.first;
    }
    final response = await _request(
      'POST',
      _api('files', {'fields': 'id'}),
      headers: {'Content-Type': 'application/json; charset=utf-8'},
      body: jsonEncode({
        'name': 'TEGNAL',
        'mimeType': 'application/vnd.google-apps.folder',
        'appProperties': {'tegnalSync': '1', 'kind': 'folder'},
      }),
    );
    return (jsonDecode(response.body) as Map)['id'] as String;
  }

  @override
  Future<DriveRevision> publish(String nativeJson, List<String> parents) async {
    final bytes = utf8.encode(nativeJson);
    if (bytes.length > BackupCodec.maximumBytes ||
        parents.length > 128 ||
        parents.any((id) => !DriveRevision._validId(id))) {
      throw const DriveSyncException(
        'This library exceeds the supported sync size.',
      );
    }
    final folder = await _folder();
    final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      ':',
      '-',
    );
    final metadata = {
      'name': 'TEGNAL-$timestamp.json',
      'mimeType': 'application/json',
      'parents': [folder],
      'appProperties': {'tegnalSync': '1', 'kind': 'snapshot'},
      'description': jsonEncode({
        'tegnalSync': 1,
        'parents': parents,
        'sha256': sha256.convert(bytes).toString(),
      }),
    };
    final response = await _request(
      'POST',
      Uri.https('www.googleapis.com', '/upload/drive/v3/files', {
        'uploadType': 'resumable',
        'fields': _fileFields,
      }),
      body: jsonEncode(metadata),
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'X-Upload-Content-Type': 'application/json',
        'X-Upload-Content-Length': '${bytes.length}',
      },
    );
    final location = Uri.tryParse(response.headers['location'] ?? '');
    if (location == null ||
        location.scheme != 'https' ||
        location.host != 'www.googleapis.com' ||
        location.hasFragment ||
        location.userInfo.isNotEmpty ||
        location.port != 443 ||
        !location.path.startsWith('/upload/drive/v3/files')) {
      throw const DriveSyncException(
        'Google Drive returned an invalid upload address.',
      );
    }
    final upload = await _request(
      'PUT',
      location,
      bytes: bytes,
      headers: {'Content-Type': 'application/json'},
    );
    return DriveRevision.fromFile(
      jsonDecode(upload.body) as Map<String, dynamic>,
    );
  }

  @override
  void dispose() => _client.close();
}
