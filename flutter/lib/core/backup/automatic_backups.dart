import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../support/document_files.dart';
import '../support/swift_json.dart';
import 'backup_container.dart';
import 'backup_retention.dart';
import 'backup_vault.dart';
import 'update_backup.dart';

enum BackupDownload {
  /// The file is on this device.
  onDevice,
  downloading,

  /// Only in Google Drive; restoring or exporting downloads it first.
  inCloud,
}

/// One backup, wherever it is kept.
class BackupItem {
  const BackupItem({
    required this.id,
    required this.kind,
    required this.createdAt,
    required this.dataVersion,
    required this.dataBuild,
    required this.appVersion,
    required this.appBuild,
    required this.size,
    required this.deviceID,
    required this.deviceName,
    required this.isThisDevice,
    required this.isProtected,
    required this.places,
    required this.download,
  });

  /// The file name; the same backup in two vaults is one item.
  final String id;
  final BackupKind kind;
  final DateTime createdAt;

  /// The version that last wrote the data; null when unknown (the update from a version without backups).
  final String? dataVersion;
  final String? dataBuild;

  /// The version that made the backup; read from the file once it is on this device, else null.
  final String? appVersion;
  final String? appBuild;
  final int size;
  final String deviceID;

  /// The making device's name; read from the file once it is on this device, else null.
  final String? deviceName;
  final bool isThisDevice;

  /// Kept whatever the total size (the newest backups from before updates).
  final bool isProtected;
  final Set<BackupPlace> places;
  final BackupDownload download;
}

/// What the Automatic Backups screen shows and does. Every vault is merged into one list.
class AutomaticBackups extends ChangeNotifier {
  AutomaticBackups({required this.setup, required this.databases, this.drive, this.flushPreferences}) : _local = LocalBackupVault(setup.vault) {
    _pendingRestore = UpdateBackup.pendingRestore(setup);
  }

  final BackupSetup setup;

  /// The open databases, read when a manual or safety backup is made.
  final OpenDatabases Function() databases;

  /// The Google Drive vault, where Drive sync is configured; null elsewhere.
  final BackupVault? drive;

  /// Writes pending preference changes to the store first (`AppPreferences.flush`), so a snapshot has them.
  final Future<void> Function()? flushPreferences;
  final LocalBackupVault _local;

  /// The size retention keeps all backups under.
  static const limit = BackupRetention.limit;

  List<BackupItem> _items = [];
  bool _driveAvailable = false;
  bool _keepInDrive = true;
  BackupFailure? _lastFailure;
  BackupRestoreReport? _lastRestore;
  PendingBackupRestore? _pendingRestore;
  Future<void> _queue = Future.value();
  int _running = 0;
  final _details = <String, BackupManifest>{};

  /// Every backup, newest first.
  List<BackupItem> get items => List.unmodifiable(_items);

  /// All backups together, each counted once.
  int get totalSize => _items.fold(0, (sum, item) => sum + item.size);

  /// Whether Google Drive can hold backups now (configured and signed in).
  bool get driveAvailable => _driveAvailable;

  /// Copies new backups to Google Drive when on (the default). Independent of library sync.
  bool get keepInDrive => _keepInDrive;

  /// The last backup before an update that could not be made. A restore that rolled back is [lastRestore], not this.
  BackupFailure? get lastFailure => _lastFailure;

  /// How the last restore went, from the launch that applied it.
  BackupRestoreReport? get lastRestore => _lastRestore;

  /// A restore waiting for the app to be closed and opened again.
  PendingBackupRestore? get pendingRestore => _pendingRestore;

  /// Whether an action or background pass is running.
  bool get isWorking => _running > 0;

  // MARK: Actions

  /// Turns the Drive copy on or off; turning it on copies what is already there.
  Future<void> setKeepInDrive(bool value) async {
    _keepInDrive = value;
    notifyListeners();
    await setup.preferences.set(UpdateBackup.keepInDriveKey, value);
    if (value) {
      await _quietly(
        () => _serial(() async {
          await _copyToDrive();
          await _reload();
        }),
      );
    }
  }

  /// Packs what the launch step staged, copies backups to Drive and applies retention. Runs once the app is up.
  Future<void> afterLaunch() => _quietly(
    () => _serial(() async {
      await _loadSettings();
      final packed = <String>{};
      for (final snapshot in UpdateBackup.stagedSnapshots(setup)) {
        try {
          packed.add((await UpdateBackup.pack(snapshot, setup: setup)).manifest.fileName);
        } on Object catch (error) {
          await UpdateBackup.recordFailure(setup, error is BackupError ? error.message : '$error');
          // A snapshot that can never be packed would fail on every launch.
          if (error == BackupError.tooLarge && snapshot.existsSync()) snapshot.deleteSync(recursive: true);
        }
      }
      // Files of a pass cut off earlier; a staged restore stays.
      if (setup.work.existsSync()) setup.work.deleteSync(recursive: true);
      if (setup.restore.existsSync()) {
        for (final entity in setup.restore.listSync()) {
          if (entity is Directory && entity.uri.pathSegments.where((part) => part.isNotEmpty).last.startsWith('incoming-')) entity.deleteSync(recursive: true);
        }
      }
      await _copyToDrive();
      await _applyRetention(keeping: packed);
      await _reload();
    }),
  );

  /// Reads the list again and applies retention, as when the screen opens.
  Future<void> refresh() => _quietly(
    () => _serial(() async {
      await _loadSettings();
      await _applyRetention(keeping: const {});
      await _reload();
    }),
  );

  /// Backs up the open databases now (kind `manual`).
  Future<void> backUpNow() => _serial(() async {
    final name = await _backUp(BackupKind.manual);
    await _copyToDrive();
    await _applyRetention(keeping: {name});
    await _reload();
  });

  /// Checks the backup, backs up the current data (kind `safety`) and stages the restore for the next
  /// launch. Nothing changes until then.
  Future<void> restore(BackupItem item) => _serial(() async {
    final file = await _fetch(item);
    try {
      final (:folder, :manifest) = await UpdateBackup.prepareRestore(file, setup: setup);
      final String safety;
      try {
        safety = await _backUp(BackupKind.safety);
      } on Object {
        if (folder.existsSync()) folder.deleteSync(recursive: true);
        throw BackupError.safetyBackupFailed;
      }
      await UpdateBackup.stageRestore(folder, manifest: manifest, setup: setup);
      _pendingRestore = UpdateBackup.pendingRestore(setup);
      await _copyToDrive();
      await _applyRetention(keeping: {safety, item.id});
      await _reload();
    } finally {
      _discard(file.parent);
    }
  });

  /// Drops the staged restore; the data stays as it is.
  void cancelPendingRestore() {
    UpdateBackup.cancelPendingRestore(setup);
    _pendingRestore = UpdateBackup.pendingRestore(setup);
    notifyListeners();
  }

  /// Deletes the backup from every vault holding it, protected or not.
  Future<void> delete(BackupItem item) => _serial(() async {
    await _local.delete(item.id);
    if (item.places.contains(BackupPlace.drive)) await drive?.delete(item.id);
    await _reload();
  });

  /// A local copy of the backup, downloading it first if needed. The caller deletes the copy's folder
  /// ([File.parent]) when done.
  Future<File> export(BackupItem item) => _serial(() async {
    final copy = await _fetch(item);
    return copy;
  });

  /// Asks where to save the backup (the system "create document" screen) and writes it there.
  /// False when the person cancels.
  Future<bool> exportToFile(BackupItem item, {DocumentFiles files = const DocumentFiles()}) async {
    final copy = await export(item);
    try {
      return await files.createDocument(name: item.id, source: copy, mimeType: 'application/octet-stream');
    } finally {
      _discard(copy.parent);
    }
  }

  /// Asks for a backup file (the system "open document" screen) and adds it to the list. Null when
  /// the person cancels.
  Future<BackupItem?> importFromFile({DocumentFiles files = const DocumentFiles()}) async {
    final picked = await files.openDocument();
    if (picked == null) return null;
    try {
      return await importFile(picked);
    } finally {
      if (picked.existsSync()) picked.deleteSync();
    }
  }

  /// Checks a backup file chosen by the person and adds it to the list. The file itself is left as it is.
  Future<BackupItem?> importFile(File source) => _serial(() async {
    // Checked before a byte is copied.
    if (source.lengthSync() > BackupContainer.fileLimit) throw BackupError.tooLarge;
    final folder = Directory('${setup.work.path}/import-${uuidString()}')..createSync(recursive: true);
    try {
      final copy = await source.copy('${folder.path}/import.${BackupName.fileExtension}');
      final archive = BackupArchive.open(copy);
      if (archive.manifest.platform != setup.platform) throw BackupError.otherPlatform;
      archive.requireLibrary();
      await UpdateBackup.checkOnly(archive);
      final name = archive.manifest.fileName;
      if (!_items.any((item) => item.id == name)) {
        await _local.add(copy, name);
        _details[name] = archive.manifest;
      }
      await _copyToDrive();
      await _applyRetention(keeping: {name});
      await _reload();
      return _items.where((item) => item.id == name).firstOrNull;
    } finally {
      _discard(folder);
    }
  });

  /// Hides the note about how the last restore went.
  Future<void> dismissRestoreReport() async {
    await setup.preferences.set(UpdateBackup.restoreReportKey, null);
    _lastRestore = null;
    notifyListeners();
  }

  /// Hides the failure note.
  Future<void> dismissFailure() async {
    await setup.preferences.set(UpdateBackup.failureKey, null);
    _lastFailure = null;
    notifyListeners();
  }

  // MARK: Work

  /// One action at a time; each waits for the one before it.
  Future<T> _serial<T>(Future<T> Function() work) {
    final run = _queue.then((_) async {
      _running += 1;
      notifyListeners();
      try {
        return await work();
      } finally {
        _running -= 1;
        notifyListeners();
      }
    });
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _quietly(Future<void> Function() work) async {
    try {
      await work();
    } on Object catch (error) {
      debugPrint('Backup pass failed: $error');
    }
  }

  void _discard(Directory folder) {
    try {
      if (folder.existsSync()) folder.deleteSync(recursive: true);
    } on FileSystemException {
      // A leftover temporary folder is cleared after the next launch.
    }
  }

  Future<void> _loadSettings() async {
    final saved = await setup.preferences.get(UpdateBackup.keepInDriveKey);
    _keepInDrive = saved is bool ? saved : true;
  }

  Future<String> _backUp(BackupKind kind) async {
    // A preference set a moment ago reaches the store asynchronously.
    await flushPreferences?.call();
    final folder = await UpdateBackup.takeSnapshot(setup, kind: kind, dataVersion: setup.appVersion, dataBuild: setup.appBuild, databases: databases());
    return (await UpdateBackup.pack(folder, setup: setup)).manifest.fileName;
  }

  Future<File> _fetch(BackupItem item) async {
    final folder = Directory('${setup.work.path}/fetch-${uuidString()}');
    if (item.places.contains(BackupPlace.local)) return _local.fetch(item.id, folder);
    final drive = this.drive;
    if (drive == null) throw BackupError.unavailable;
    return drive.fetch(item.id, folder);
  }

  /// Backups are written locally first and copied to Drive when it is on and available.
  Future<void> _copyToDrive() async {
    final drive = this.drive;
    if (!_keepInDrive || drive == null) return;
    try {
      if (!await drive.available()) return;
      final present = {for (final file in await drive.list()) file.name};
      for (final file in await _local.list()) {
        if (present.contains(file.name)) continue;
        try {
          await drive.add(File('${_local.folder.path}/${file.name}'), file.name);
        } on Object catch (error) {
          debugPrint('Backup not copied to Drive: $error');
        }
      }
    } on Object catch (error) {
      debugPrint('Backup Drive copy failed: $error');
    }
  }

  Future<List<BackupVaultFile>> _files() async {
    final local = await _local.list();
    var remote = <BackupVaultFile>[];
    try {
      remote = await drive?.list() ?? [];
    } on Object {
      // Drive can be unreachable; the local backups still show.
    }
    return [...local, ...remote];
  }

  BackupVault? _vault(BackupPlace place) => place == BackupPlace.local ? _local : drive;

  static List<BackupRetentionItem> _candidates(List<BackupVaultFile> files) => [
    for (final file in files)
      if (BackupName.tryParse(file.name) case final name?)
        BackupRetentionItem(name: file.name, size: file.size, device: name.deviceID, kind: name.kind, date: name.createdAt),
  ];

  Future<void> _applyRetention({required Set<String> keeping}) async {
    final files = await _files();
    for (final name in BackupRetention.expired(_candidates(files), keeping: keeping)) {
      for (final file in files.where((file) => file.name == name)) {
        try {
          await _vault(file.place)?.delete(name);
        } on Object catch (error) {
          debugPrint('Backup not deleted: $error');
        }
      }
    }
  }

  Future<void> _reload() async {
    try {
      _driveAvailable = await drive?.available() ?? false;
    } on Object {
      _driveAvailable = false;
    }
    final files = await _files();
    // Version and device name come from the file's head, read once for each file on this device.
    for (final file in files) {
      if (!file.downloaded || _details.containsKey(file.name)) continue;
      final detail = await _vault(file.place)?.manifest(file.name);
      if (detail != null) _details[file.name] = detail;
    }
    final byName = <String, List<BackupVaultFile>>{};
    for (final file in files) {
      byName.putIfAbsent(file.name, () => []).add(file);
    }
    final protected = BackupRetention.protected(_candidates(files));
    final items = <BackupItem>[];
    for (final MapEntry(key: name, value: copies) in byName.entries) {
      final parsed = BackupName.tryParse(name);
      if (parsed == null) continue;
      final detail = _details[name];
      final download = copies.any((copy) => copy.downloaded)
          ? BackupDownload.onDevice
          : copies.any((copy) => copy.downloading)
          ? BackupDownload.downloading
          : BackupDownload.inCloud;
      items.add(
        BackupItem(
          id: name,
          kind: parsed.kind,
          createdAt: parsed.createdAt,
          dataVersion: parsed.dataVersion,
          dataBuild: parsed.dataBuild,
          appVersion: detail?.appVersion,
          appBuild: detail?.appBuild,
          size: copies.map((copy) => copy.size).reduce((a, b) => a > b ? a : b),
          deviceID: parsed.deviceID,
          deviceName: detail?.device.name,
          isThisDevice: parsed.deviceID == setup.device.id,
          isProtected: protected.contains(name),
          places: {for (final copy in copies) copy.place},
          download: download,
        ),
      );
    }
    items.sort((a, b) {
      final byDate = b.createdAt.compareTo(a.createdAt);
      return byDate != 0 ? byDate : b.id.compareTo(a.id);
    });
    _items = items;
    _lastFailure = await UpdateBackup.lastFailure(setup);
    _lastRestore = await UpdateBackup.lastRestore(setup);
    _pendingRestore = UpdateBackup.pendingRestore(setup);
  }
}
