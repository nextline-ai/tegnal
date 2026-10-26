import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/content.dart';
import 'library_store.dart';
import 'session_client.dart';

enum DownloadStatus { queued, downloading, paused, complete, failed }

class DownloadEntry {
  DownloadEntry({
    required this.item,
    required List<ReaderPage> pages,
    this.completed = 0,
    this.status = DownloadStatus.queued,
    this.error,
    Map<int, Map<String, dynamic>>? verifiedFiles,
  }) : pages = List.of(pages),
       verifiedFiles = verifiedFiles ?? {};
  final ContentItem item;
  final List<ReaderPage> pages;
  final Map<int, Map<String, dynamic>> verifiedFiles;
  int completed;
  DownloadStatus status;
  String? error;
  Map<String, dynamic> toJson() => {
    'item': item.toJson(),
    'pages': pages
        .map(
          (p) => {
            'url': p.url.toString(), 'width': p.width, 'height': p.height,
            // Browser cookies/authorization are looked up for each request, never saved.
            'headers': {
              for (final h in p.headers.entries)
                if ({'referer', 'accept'}.contains(h.key.toLowerCase()))
                  h.key: h.value,
            },
          },
        )
        .toList(),
    'verifiedFiles': {
      for (final entry in verifiedFiles.entries)
        entry.key.toString(): entry.value,
    },
    'completed': completed,
    'status': status.name,
    'error': error,
  };
  factory DownloadEntry.fromJson(Map<String, dynamic> j) => DownloadEntry(
    item: ContentItem.fromJson(Map<String, dynamic>.from(j['item'] as Map)),
    pages: (j['pages'] as List)
        .map(
          (v) => ReaderPage.fromJson({
            ...Map<String, dynamic>.from(v as Map),
            'headers': {
              for (final h in ((v['headers'] as Map?) ?? {}).entries)
                if ({
                  'referer',
                  'accept',
                }.contains(h.key.toString().toLowerCase()))
                  h.key.toString(): h.value,
            },
          }),
        )
        .toList(),
    completed: j['completed'] as int,
    status: DownloadStatus.values.byName(j['status'] as String),
    error: j['error'] as String?,
    verifiedFiles: {
      for (final entry in (j['verifiedFiles'] as Map? ?? {}).entries)
        int.parse(entry.key as String): Map<String, dynamic>.from(
          entry.value as Map,
        ),
    },
  );
}

/// Foreground-only transfers. Backgrounding clears pending resume intents;
/// returning to the foreground never starts network work without a user action.
class DownloadManager extends ChangeNotifier {
  DownloadManager(
    this.store,
    this.directory, {
    http.Client Function()? clientFactory,
    this.refreshPages,
  }) : _clientFactory = clientFactory ?? http.Client.new {
    for (final payload in store.downloads()) {
      final entry = DownloadEntry.fromJson(payload);
      if (entry.status == DownloadStatus.downloading ||
          entry.status == DownloadStatus.queued) {
        entry.status = DownloadStatus.paused;
      }
      // Also drops historical persisted browser headers from old manifests.
      store.saveDownload(entry.item.key, entry.toJson());
      _entries[entry.item.key] = entry;
    }
  }
  final LibraryStore store;
  final Directory directory;
  final http.Client Function() _clientFactory;
  final Future<List<ReaderPage>> Function(ContentItem)? refreshPages;
  final Map<String, DownloadEntry> _entries = {};
  final Set<String> _cancelled = {},
      _resumeIntents = {},
      _refreshNeeded = {},
      _removing = {};
  http.Client? _activeClient;
  String? _activeKey;
  Completer<void>? _activeDone;
  bool _running = false, _disposed = false, _foreground = true;
  List<DownloadEntry> get entries => _entries.values.toList();
  DownloadEntry? entry(ContentItem item) => _entries[item.key];
  Directory _folder(ContentItem item) =>
      Directory('${directory.path}/${sha256.convert(utf8.encode(item.key))}');
  File _file(ContentItem item, int index) =>
      File('${_folder(item).path}/$index.media');
  bool _mayRun(DownloadEntry entry) =>
      !_disposed &&
      _foreground &&
      !_cancelled.contains(entry.item.key) &&
      !_removing.contains(entry.item.key);
  void _publish(DownloadEntry entry) {
    store.saveDownload(entry.item.key, entry.toJson());
    if (!_disposed) notifyListeners();
  }

  void setForeground(bool foreground) {
    if (_disposed) return;
    _foreground = foreground;
    if (!foreground) pauseAll();
  }

  static void _validatePages(List<ReaderPage> pages) {
    if (pages.isEmpty || pages.length > 10000) {
      throw const ContentException('This work has no downloadable pages.');
    }
    for (final page in pages) {
      if (page.url.scheme != 'https' ||
          page.url.host.isEmpty ||
          page.url.userInfo.isNotEmpty) {
        throw const ContentException(
          'Only secure media addresses can be downloaded.',
        );
      }
    }
  }

  Future<void> enqueue(ContentItem item, List<ReaderPage> pages) async {
    if (_disposed) return;
    if (_removing.contains(item.key)) {
      throw const ContentException(
        'This download is being removed. Try again shortly.',
      );
    }
    final existing = _entries[item.key];
    if (existing != null) {
      if (existing.item.sourceId.isNotEmpty &&
          item.sourceId.isNotEmpty &&
          existing.item.sourceId != item.sourceId) {
        throw const ContentException(
          'This download belongs to another website. Remove it before downloading from a different source.',
        );
      }
      resume(item);
      return;
    }
    _validatePages(pages);
    final entry = DownloadEntry(
      item: item,
      pages: pages,
      status: _foreground ? DownloadStatus.queued : DownloadStatus.paused,
    );
    _entries[item.key] = entry;
    _publish(entry);
    if (_foreground) unawaited(_drain());
  }

  void pause(ContentItem item) {
    _resumeIntents.remove(item.key);
    _refreshNeeded.remove(item.key);
    final entry = _entries[item.key];
    if (entry == null || entry.status == DownloadStatus.complete) return;
    _cancelled.add(item.key);
    entry.status = DownloadStatus.paused;
    _publish(entry);
    if (_activeKey == item.key) _activeClient?.close();
  }

  void pauseAll() {
    // Includes a paused worker with a queued resume intent while it unwinds.
    _resumeIntents.clear();
    for (final entry in entries) {
      if (entry.status == DownloadStatus.downloading ||
          entry.status == DownloadStatus.queued ||
          _activeKey == entry.item.key) {
        pause(entry.item);
      }
    }
  }

  void resume(ContentItem item) {
    if (_disposed || _removing.contains(item.key)) return;
    final entry = _entries[item.key];
    if (entry == null || entry.status == DownloadStatus.complete) return;
    if (!_foreground) {
      pause(item);
      return;
    }
    if ((entry.status == DownloadStatus.downloading ||
            entry.status == DownloadStatus.queued) &&
        !_cancelled.contains(item.key)) {
      return;
    }
    if (refreshPages != null) _refreshNeeded.add(item.key);
    entry.error = null;
    if (_activeKey == item.key) {
      // Consumed exactly once after the cancelled worker closes its sink/client.
      _resumeIntents.add(item.key);
      entry.status = DownloadStatus.queued;
      _publish(entry);
      return;
    }
    _cancelled.remove(item.key);
    entry.status = DownloadStatus.queued;
    _publish(entry);
    unawaited(_drain());
  }

  Future<void> remove(ContentItem item) async {
    if (!_removing.add(item.key)) return;
    try {
      pause(item);
      if (_activeKey == item.key) await _activeDone?.future;
      _entries.remove(item.key);
      store.removeDownload(item.key);
      final folder = _folder(item);
      if (await folder.exists()) await folder.delete(recursive: true);
      _cancelled.remove(item.key);
      _refreshNeeded.remove(item.key);
      if (!_disposed) notifyListeners();
    } finally {
      _removing.remove(item.key);
    }
  }

  Future<List<ReaderPage>?> offlinePages(ContentItem item) async {
    final entry = _entries[item.key];
    if (entry == null || entry.status != DownloadStatus.complete) return null;
    if (entry.item.sourceId.isNotEmpty &&
        item.sourceId.isNotEmpty &&
        entry.item.sourceId != item.sourceId) {
      return null;
    }
    final result = <ReaderPage>[];
    for (var i = 0; i < entry.pages.length; i++) {
      final file = _file(item, i);
      // Historical completed downloads remain readable; resume requires hashes.
      if (!await file.exists() || await file.length() == 0) {
        entry.completed = i;
        entry.status = DownloadStatus.failed;
        entry.error =
            'A downloaded page is missing. Resume to download it again.';
        _publish(entry);
        return null;
      }
      result.add(
        ReaderPage(
          url: file.uri,
          width: entry.pages[i].width,
          height: entry.pages[i].height,
        ),
      );
    }
    return result;
  }

  static String _identity(ReaderPage page) => sha256
      .convert(
        utf8.encode(jsonEncode([page.url.toString(), page.width, page.height])),
      )
      .toString();

  Future<bool> _verified(DownloadEntry entry, int index) async {
    final record = entry.verifiedFiles[index];
    if (record == null || record['identity'] != _identity(entry.pages[index])) {
      return false;
    }
    final file = _file(entry.item, index);
    if (!await file.exists() || await file.length() != record['bytes']) {
      return false;
    }
    return (await sha256.bind(file.openRead()).first).toString() ==
        record['sha256'];
  }

  Future<void> _refreshManifest(DownloadEntry entry) async {
    final pages = await refreshPages!(entry.item);
    if (!_mayRun(entry)) return;
    _validatePages(pages);
    final oldCount = entry.pages.length;
    for (final index in entry.verifiedFiles.keys.toList()) {
      if (index >= pages.length ||
          entry.verifiedFiles[index]!['identity'] != _identity(pages[index])) {
        entry.verifiedFiles.remove(index);
      }
    }
    entry.pages
      ..clear()
      ..addAll(pages);
    entry.completed = 0;
    _publish(
      entry,
    ); // Persist invalidation before any old file could be reused.
    for (var i = 0; i < oldCount; i++) {
      if (entry.verifiedFiles.containsKey(i)) continue;
      final file = _file(entry.item, i);
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> _drain() async {
    if (_running || _disposed || !_foreground) return;
    _running = true;
    try {
      while (!_disposed && _foreground) {
        final entry = _entries.values
            .where(
              (e) =>
                  e.status == DownloadStatus.queued &&
                  !_removing.contains(e.item.key),
            )
            .firstOrNull;
        if (entry == null) break;
        _activeKey = entry.item.key;
        _activeDone = Completer<void>();
        entry.status = DownloadStatus.downloading;
        _publish(entry);
        http.Client? client;
        try {
          if (_refreshNeeded.remove(entry.item.key) && refreshPages != null) {
            await _refreshManifest(entry);
          }
          if (!_mayRun(entry)) continue;
          client = _clientFactory();
          _activeClient = client;
          await _folder(entry.item).create(recursive: true);
          for (var i = 0; i < entry.pages.length; i++) {
            if (!_mayRun(entry)) break;
            if (await _verified(entry, i)) {
              if (!_mayRun(entry)) break;
              entry.completed = i + 1;
              _publish(entry);
              continue;
            }
            final file = _file(entry.item, i);
            if (await file.exists()) await file.delete();
            entry.verifiedFiles.remove(i);
            final page = entry.pages[i];
            final headers = await BrowserSession.headersFor(page.url);
            if (!_mayRun(entry)) break;
            final request = http.Request('GET', page.url)
              ..followRedirects = false
              ..headers.addAll(page.headers)
              ..headers.addAll(headers);
            final response = await client
                .send(request)
                .timeout(const Duration(seconds: 30));
            if (response.statusCode != 200) {
              throw ContentException(
                'Download failed (HTTP ${response.statusCode}).',
              );
            }
            final mime = response.headers['content-type']?.toLowerCase() ?? '';
            if (mime.contains('text/html') ||
                mime.contains('application/json')) {
              throw const ContentException(
                'The source returned a page instead of media.',
              );
            }
            const maxBytes = 512 * 1024 * 1024;
            if ((response.contentLength ?? 0) > maxBytes) {
              throw const ContentException(
                'This media exceeds the 512 MB download limit.',
              );
            }
            final partial = File('${file.path}.part');
            final sink = partial.openWrite();
            final digest = _DigestSink();
            final hasher = sha256.startChunkedConversion(digest);
            var count = 0;
            try {
              await for (final chunk in response.stream.timeout(
                const Duration(seconds: 30),
              )) {
                if (!_mayRun(entry)) throw const ContentException('Paused');
                count += chunk.length;
                if (count > maxBytes) {
                  throw const ContentException(
                    'This media exceeds the 512 MB download limit.',
                  );
                }
                hasher.add(chunk);
                // Respect file I/O backpressure rather than buffering a whole video.
                await sink.addStream(Stream.value(chunk));
              }
              await sink.flush();
            } finally {
              hasher.close();
              await sink.close();
            }
            if (count == 0 ||
                (response.contentLength != null &&
                    count != response.contentLength)) {
              throw const ContentException('Incomplete media response.');
            }
            if (!_mayRun(entry)) break;
            await partial.rename(file.path);
            entry.verifiedFiles[i] = {
              'identity': _identity(page),
              'bytes': count,
              'sha256': digest.value.toString(),
            };
            entry.completed = i + 1;
            _publish(entry);
          }
          entry.status = _mayRun(entry)
              ? DownloadStatus.complete
              : DownloadStatus.paused;
        } catch (error) {
          if (!_mayRun(entry)) {
            entry.status = DownloadStatus.paused;
          } else {
            entry.status = DownloadStatus.failed;
            entry.error = error is ContentException
                ? error.message
                : 'Download interrupted. Check the connection and resume.';
          }
        } finally {
          client?.close();
          _activeClient = null;
          _activeKey = null;
          if (_resumeIntents.remove(entry.item.key) &&
              !_disposed &&
              _foreground &&
              !_removing.contains(entry.item.key)) {
            _cancelled.remove(entry.item.key);
            entry.status = DownloadStatus.queued;
          } else if (entry.status == DownloadStatus.downloading ||
              (!_foreground && entry.status == DownloadStatus.queued)) {
            entry.status = DownloadStatus.paused;
          }
          _publish(entry);
          _activeDone?.complete();
          _activeDone = null;
        }
      }
    } finally {
      _running = false;
    }
  }

  @override
  void dispose() {
    pauseAll();
    _disposed = true;
    _activeClient?.close();
    super.dispose();
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
