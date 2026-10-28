import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../data/backup_codec.dart';
import '../data/drive_auth.dart';
import '../data/drive_repository.dart';
import '../data/sync_snapshot.dart';
import 'app_controller.dart';
import 'app_features.dart';

enum DriveResolution { useDevice, useDrive, combine }

class DriveConflict {
  const DriveConflict(this.revisions, this.localFingerprint);
  final List<DriveRevision> revisions;
  final String localFingerprint;
}

/// Foreground, opt-in two-way metadata synchronization. Native JSON files are
/// immutable revisions; sibling revisions are explicit conflicts, never a
/// last-writer-wins overwrite. Device-only state stays outside the snapshots.
class DriveSyncController extends ChangeNotifier {
  DriveSyncController({
    required this.library,
    required this.stateDirectory,
    DriveAuth? auth,
    this.featureEnabled = AppFeatures.googleDriveSyncEnabled,
    DriveRepository Function(DriveAuth)? repositoryFactory,
  }) : auth = auth ?? GoogleDriveAuth(),
       _repositoryFactory = repositoryFactory ?? GoogleDriveRepository.new;

  final bool featureEnabled;
  final AppController library;
  final Directory stateDirectory;
  final DriveAuth auth;
  final DriveRepository Function(DriveAuth) _repositoryFactory;
  DriveRepository? _repository;
  Map<String, dynamic>? _baseline;
  Timer? _debounce, _poll;
  int _epoch = 0;
  bool _disposed = false, _foreground = true, _applying = false;
  bool busy = false;
  String? error;
  DateTime? lastSync;
  DriveConflict? conflict;
  bool get configured => featureEnabled && auth.configured;
  bool get connected =>
      featureEnabled && auth.identity != null && _repository != null;
  String? get accountEmail => auth.identity?.email;
  String? get configurationMessage => featureEnabled
      ? auth.configurationMessage
      : 'Google Drive sync is temporarily disabled.';
  bool get autoSync =>
      featureEnabled && library.store.setting('drive.autoSync', false) == true;

  Future<void> initialize() async {
    if (!featureEnabled) return;
    library.addListener(_libraryChanged);
    try {
      await stateDirectory.create(recursive: true);
    } on FileSystemException {
      error = 'Unable to sync. Your local library is available; try again.';
      return;
    }
    if (configured && library.store.setting('drive.connected', false) == true) {
      unawaited(_restoreConnection());
    }
  }

  Future<void> _restoreConnection() => _run(() async {
    final epoch = _epoch;
    if (!await auth.restore()) return;
    _check(epoch);
    await _connected();
    _schedule();
  });

  Future<void> connect() => _run(() async {
    final epoch = _epoch;
    await auth.connect();
    _check(epoch);
    await _connected();
  });

  Future<void> _connected() async {
    final epoch = _epoch;
    await stateDirectory.create(recursive: true);
    _check(epoch);
    _repository?.dispose();
    _repository = _repositoryFactory(auth);
    _baseline = null;
    lastSync = null;
    conflict = null;
    final previousAccount =
        library.store.setting('drive.lastAccount') as String?;
    final switchedAccount =
        previousAccount != null && previousAccount != auth.identity!.id;
    if (switchedAccount) {
      // Local metadata belongs to this device, not the newly connected account.
      // Require fresh review before publishing it to a different Drive.
      library.store.setSetting('drive.autoSync', false);
    }
    final file = _stateFile;
    if (!switchedAccount && await file.exists()) {
      try {
        final data =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        if (data['account'] == auth.identity!.id &&
            data['localHash'] is String &&
            data['heads'] is Map) {
          data['heads'] = Map<String, String>.from(data['heads'] as Map);
          _baseline = data;
          lastSync = DateTime.tryParse(data['syncedAt'] as String? ?? '');
        }
      } on FormatException {
        // A missing/corrupt baseline forces first-sync conflict review. It must
        // never be interpreted as authority to discard either library.
      } on TypeError {
        // Treat an obsolete baseline schema as a first synchronization.
      }
    }
    _check(epoch);
    library.store.setSetting('drive.connected', true);
    library.store.setSetting('drive.lastAccount', auth.identity!.id);
    _startPolling();
  }

  File get _stateFile {
    final account = auth.identity?.id;
    if (account == null) {
      throw const DriveSyncException('Connect Google Drive first.');
    }
    final key = sha256.convert(utf8.encode(account));
    return File('${stateDirectory.path}/state-$key.json');
  }

  Future<void> disconnect() async {
    if (!featureEnabled) return;
    if (busy) return;
    ++_epoch;
    _debounce?.cancel();
    _poll?.cancel();
    _repository?.dispose();
    _repository = null;
    _baseline = null;
    lastSync = null;
    conflict = null;
    error = null;
    library.store.setSetting('drive.connected', false);
    await _run(auth.disconnect);
  }

  void setForeground(bool value) {
    _foreground = value;
    if (!value) {
      _debounce?.cancel();
      _poll?.cancel();
    } else {
      _startPolling();
      _schedule();
    }
  }

  void setAutoSync(bool value) {
    if (!featureEnabled) return;
    library.store.setSetting('drive.autoSync', value);
    if (!value) {
      _debounce?.cancel();
      _poll?.cancel();
    } else {
      _startPolling();
      _schedule();
    }
    _notify();
  }

  void _startPolling() {
    _poll?.cancel();
    if (connected && autoSync && _foreground) {
      _poll = Timer.periodic(const Duration(minutes: 5), (_) => _schedule());
    }
  }

  void _libraryChanged() {
    if (!_applying) _schedule();
  }

  void _schedule() {
    if (_disposed ||
        !featureEnabled ||
        !connected ||
        !autoSync ||
        !_foreground ||
        conflict != null) {
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 5), () {
      if (!busy) unawaited(synchronize());
    });
  }

  static List<DriveRevision> heads(List<DriveRevision> revisions) {
    final records = {for (final r in revisions) r.id: r};
    if (records.length != revisions.length) {
      throw const DriveSyncException('The Drive revision history is invalid.');
    }
    final referenced = revisions.expand((r) => r.parents).toSet();
    // Kahn's algorithm also detects corrupt cycles without recursive traversal.
    final remaining = {
      for (final r in revisions)
        r.id: r.parents.where(records.containsKey).toSet(),
    };
    final children = <String, List<String>>{};
    for (final r in revisions) {
      for (final parent in r.parents) {
        children.putIfAbsent(parent, () => []).add(r.id);
      }
    }
    final ready = remaining.keys.where((id) => remaining[id]!.isEmpty).toList();
    var processed = 0;
    while (ready.isNotEmpty) {
      final id = ready.removeLast();
      processed++;
      for (final child in children[id] ?? <String>[]) {
        final parents = remaining[child]!;
        parents.remove(id);
        if (parents.isEmpty) ready.add(child);
      }
    }
    if (processed != revisions.length) {
      throw const DriveSyncException('The Drive revision history is invalid.');
    }
    return revisions.where((r) => !referenced.contains(r.id)).toList()
      ..sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
  }

  Map<String, String> _headMap(List<DriveRevision> revisions) => {
    for (final r in revisions) r.id: r.checksum,
  };

  Future<void> synchronize({
    DriveResolution? resolution,
    String? revisionId,
  }) => _run(() async {
    if (!connected) {
      throw const DriveSyncException('Connect Google Drive first.');
    }
    final epoch = _epoch;
    final remote = _repository!;
    final codec = BackupCodec(library.store);
    final local = codec.exportJson();
    final localHash = SyncSnapshot.fingerprint(local);
    final remoteHeads = heads(await remote.revisions());
    _check(epoch);
    if (remoteHeads.length > 128) {
      throw const DriveSyncException(
        'Too many concurrent Drive revisions. No data was replaced.',
      );
    }
    final remoteMap = _headMap(remoteHeads);
    final knownMap = (_baseline?['heads'] as Map?)?.cast<String, String>();
    final localChanged =
        _baseline == null || _baseline!['localHash'] != localHash;
    final remoteChanged = knownMap == null || !mapEquals(knownMap, remoteMap);

    if (resolution != null) {
      final previous = conflict;
      if (previous == null ||
          previous.localFingerprint != localHash ||
          !mapEquals(_headMap(previous.revisions), remoteMap)) {
        conflict = DriveConflict(remoteHeads, localHash);
        throw const DriveSyncException(
          'The library changed while reviewing the conflict. Review the latest copies again.',
        );
      }
    }

    if (remoteHeads.isEmpty) {
      final revision = await remote.publish(local, []);
      _check(epoch);
      await _record(localHash, [revision]);
      conflict = null;
      return;
    }
    if (!remoteChanged && !localChanged) {
      conflict = null;
      await _record(localHash, remoteHeads);
      return;
    }

    if (resolution == DriveResolution.useDevice ||
        (!remoteChanged && localChanged && remoteHeads.length == 1)) {
      final revision = await remote.publish(
        local,
        remoteHeads.map((r) => r.id).toList(),
      );
      _check(epoch);
      // Record the uploaded snapshot, not edits made while it was uploading.
      await _record(localHash, [revision]);
      conflict = null;
      return;
    }

    if (resolution == null && remoteHeads.length > 1) {
      conflict = DriveConflict(remoteHeads, localHash);
      return;
    }
    var chosen = remoteHeads.first;
    if (revisionId != null) {
      chosen =
          remoteHeads.where((r) => r.id == revisionId).firstOrNull ??
          (throw const DriveSyncException(
            'The selected Drive revision is no longer available.',
          ));
    }
    var incoming = await remote.read(chosen);
    codec.inspect(incoming);
    _check(epoch);
    final incomingHash = SyncSnapshot.fingerprint(incoming);
    if (resolution == null && localHash == incomingHash) {
      await _record(localHash, remoteHeads);
      conflict = null;
      return;
    }
    if (resolution == null &&
        localChanged &&
        (_baseline != null || !SyncSnapshot.isEmpty(local))) {
      conflict = DriveConflict(remoteHeads, localHash);
      return;
    }

    if (resolution == DriveResolution.combine) {
      if (remoteHeads.fold<int>(0, (sum, r) => sum + r.bytes) >
          256 * 1024 * 1024) {
        throw const DriveSyncException(
          'These revisions are too large to combine at once. Choose a copy instead.',
        );
      }
      incoming = local;
      for (final revision in remoteHeads.reversed) {
        final text = await remote.read(revision);
        codec.inspect(text);
        incoming = SyncSnapshot.merge(incoming, text);
      }
    }
    _check(epoch);
    _requireUnchanged(localHash);
    await _recovery(local);
    _check(epoch);
    _requireUnchanged(localHash);
    var acceptedHeads = remoteHeads;
    if (resolution == DriveResolution.combine || remoteHeads.length > 1) {
      final revision = await remote.publish(
        incoming,
        remoteHeads.map((r) => r.id).toList(),
      );
      _check(epoch);
      _requireUnchanged(localHash);
      acceptedHeads = [revision];
    }
    _applying = true;
    try {
      SyncSnapshot.replace(library.store, incoming);
      library.libraryRestored();
    } finally {
      _applying = false;
    }
    final appliedHash = SyncSnapshot.fingerprint(codec.exportJson());
    await _record(appliedHash, acceptedHeads);
    conflict = null;
  });

  void _requireUnchanged(String fingerprint) {
    if (SyncSnapshot.fingerprint(BackupCodec(library.store).exportJson()) !=
        fingerprint) {
      throw const DriveSyncException(
        'Your library changed during sync. Sync again to keep the new edits.',
      );
    }
  }

  Future<void> _recovery(String local) async {
    final directory = Directory('${stateDirectory.path}/recovery');
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}/before-${DateTime.now().microsecondsSinceEpoch}.json',
    );
    await file.writeAsString(local, flush: true);
    final files =
        (await directory
              .list()
              .where(
                (f) =>
                    f is File &&
                    RegExp(r'[/\\]before-\d+\.json$').hasMatch(f.path),
              )
              .toList())
          ..sort((a, b) => b.path.compareTo(a.path));
    for (final old in files.skip(10)) {
      await old.delete();
    }
  }

  Future<List<File>> recoveryCopies() async {
    final directory = Directory('${stateDirectory.path}/recovery');
    if (!await directory.exists()) return [];
    final files =
        (await directory
                .list()
                .where(
                  (f) =>
                      f is File &&
                      RegExp(r'[/\\]before-\d+\.json$').hasMatch(f.path),
                )
                .toList())
            .cast<File>()
          ..sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  Future<void> restoreRecovery(File file) => _run(() async {
    final epoch = _epoch;
    if (!(await recoveryCopies()).any((f) => f.path == file.path) ||
        await file.length() > BackupCodec.maximumBytes) {
      throw const DriveSyncException('The recovery copy is not available.');
    }
    final before = BackupCodec(library.store).exportJson();
    final fingerprint = SyncSnapshot.fingerprint(before);
    final text = await file.readAsString();
    BackupCodec(library.store).inspect(text);
    await _recovery(before);
    _check(epoch);
    _requireUnchanged(fingerprint);
    _applying = true;
    try {
      SyncSnapshot.replace(library.store, text);
      library.libraryRestored();
      conflict = null;
      // Restoring a local safety copy does not itself authorize uploading it.
      setAutoSync(false);
    } finally {
      _applying = false;
    }
  });

  Future<void> _record(
    String localHash,
    List<DriveRevision> remoteHeads,
  ) async {
    final epoch = _epoch;
    final now = DateTime.now().toUtc();
    final data = {
      'account': auth.identity!.id,
      'localHash': localHash,
      'heads': _headMap(remoteHeads),
      'syncedAt': now.toIso8601String(),
    };
    final target = _stateFile;
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(jsonEncode(data), flush: true);
    _check(epoch);
    await temporary.rename(target.path);
    _baseline = data;
    lastSync = now;
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (busy || _disposed) return;
    if (!featureEnabled) {
      error = 'Google Drive sync is temporarily disabled.';
      _notify();
      return;
    }
    busy = true;
    error = null;
    _notify();
    try {
      await operation();
    } catch (e) {
      if (!_disposed) {
        error = e is DriveSyncException || e is DriveAuthException
            ? e.toString()
            : e is FormatException
            ? 'The Drive backup is invalid. Your library was not replaced.'
            : 'Unable to sync. Your local library is available; try again.';
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  void _check(int epoch) {
    if (_disposed || epoch != _epoch) {
      throw const DriveSyncException('Sync was canceled.');
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    library.removeListener(_libraryChanged);
    _debounce?.cancel();
    _poll?.cancel();
    _repository?.dispose();
    auth.dispose();
    super.dispose();
  }
}
