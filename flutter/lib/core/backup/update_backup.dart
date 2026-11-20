import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../booru/booru_store.dart';
import '../content/site_account.dart';
import '../content/site_favorites_sync.dart';
import '../content/site_fallback_content.dart';
import '../downloads/download_store.dart';
import '../generation/generation_store.dart';
import '../storage/app_database.dart';
import '../support/preferences.dart';
import '../support/sql_database.dart';
import '../support/swift_json.dart';
import 'backup_container.dart';
import 'backup_preferences.dart';

/// Where the backup engine reads and writes. Tests pass temporary folders and their own store.
class BackupSetup {
  BackupSetup({
    required this.dataFolder,
    required this.root,
    required this.files,
    required this.preferences,
    required this.appVersion,
    required this.appBuild,
    this.platform = 'android',
    required this.device,
    DateTime Function()? now,
    List<SiteFavoriteKeys>? favorites,
  }) : now = now ?? DateTime.now,
       favorites = favorites ?? defaultFavorites;

  /// The folder holding `memo.sqlite` and `booru.sqlite`.
  final Directory dataFolder;

  /// The engine's own folder: staging, the local vault, a pending restore.
  final Directory root;

  /// Small files outside the data folder, by entry name.
  final Map<String, File> files;

  /// The one preferences store, image mode's keys under their prefix. Also keeps the `backup.*` keys.
  final BackupPreferenceStore preferences;

  /// Which favorites sync keys live in the store, as stored (the image mode's under its prefix).
  final List<SiteFavoriteKeys> favorites;
  final String appVersion;
  final String appBuild;
  final String platform;
  final BackupDevice device;
  final DateTime Function() now;

  static const defaultFavorites = [
    SiteFavoriteKeys.manga,
    SiteFavoriteKeys('${BackupPreferences.imagePrefix}${SiteFavoriteKeys.booruStates}', '${BackupPreferences.imagePrefix}${SiteFavoriteKeys.booruDeclined}'),
  ];

  /// Tests and fixture runs never touch the installed app's data: a throwaway folder and a store in memory.
  factory BackupSetup.isolated() {
    final root = Directory.systemTemp.createTempSync('tegnal-update-backup-isolated-');
    return BackupSetup(
      dataFolder: Directory('${root.path}/Data'),
      root: Directory('${root.path}/Backups'),
      files: {for (final entry in BackupEntry.fileEntries) entry: File('${root.path}/Files/${entry.substring(6)}')},
      preferences: MemoryBackupStore(),
      appVersion: '0',
      appBuild: '0',
      device: const BackupDevice(id: 'isolated', name: 'Test device'),
    );
  }

  Directory get staging => Directory('${root.path}/Staging');
  Directory get vault => Directory('${root.path}/Vault');
  Directory get work => Directory('${root.path}/Work');
  Directory get restore => Directory('${root.path}/Restore');

  /// The app's own folders: both databases and the small files sit in the support directory, and the
  /// engine keeps `Backups/` beside them.
  static Future<BackupSetup> standard({
    required Directory support,
    required String version,
    required String build,
    required String deviceName,
    BackupPreferenceStore? preferences,
  }) async {
    final store = preferences ?? SharedPreferencesBackupStore();
    final downloads = DownloadStore.directoryIn(support);
    return BackupSetup(
      dataFolder: support,
      root: Directory('${support.path}/Backups'),
      files: {
        'files/gallery-keys': GalleryKeys.defaultFile(support),
        'files/work-missing-sites': WorkSiteMemory.defaultFile(support),
        'files/downloads.json': DownloadStore.manifestFile(downloads),
        'files/downloads-settings.json': DownloadStore.settingsFile(downloads),
        'files/generated-index.json': GenerationStore.indexFile(GenerationStore.folderIn(support)),
      },
      preferences: store,
      appVersion: version,
      appBuild: build,
      device: BackupDevice(id: await UpdateBackup.deviceID(store), name: deviceName),
    );
  }
}

/// The last thing that went wrong with a backup made on its own, shown in the backups screen.
class BackupFailure {
  const BackupFailure({required this.date, required this.message, required this.appVersion});
  final DateTime date;
  final String message;
  final String appVersion;

  String encode() => jsonEncode({'appVersion': appVersion, 'date': backupDateText(date), 'message': message});

  static BackupFailure? decode(Object? text) {
    try {
      final json = jsonDecode(text! as String) as Map<String, Object?>;
      return BackupFailure(date: DateTime.parse(json['date']! as String), message: json['message']! as String, appVersion: json['appVersion']! as String);
    } on Object {
      return null;
    }
  }
}

/// How the last restore went, written at the launch that applied it.
class BackupRestoreReport {
  const BackupRestoreReport({required this.date, required this.backup, required this.succeeded, this.message});
  final DateTime date;
  final String backup;
  final bool succeeded;
  final String? message;

  String encode() => jsonEncode({'backup': backup, 'date': backupDateText(date), 'message': message, 'succeeded': succeeded});

  static BackupRestoreReport? decode(Object? text) {
    try {
      final json = jsonDecode(text! as String) as Map<String, Object?>;
      return BackupRestoreReport(
        date: DateTime.parse(json['date']! as String),
        backup: json['backup']! as String,
        succeeded: json['succeeded']! as bool,
        message: json['message'] as String?,
      );
    } on Object {
      return null;
    }
  }
}

/// A restore that waits for the next launch.
class PendingBackupRestore {
  const PendingBackupRestore({
    required this.name,
    required this.id,
    required this.kind,
    required this.createdAt,
    required this.dataVersion,
    required this.stagedAt,
    this.attempts = 0,
  });
  final String name;
  final String id;
  final BackupKind kind;
  final DateTime createdAt;
  final String? dataVersion;
  final DateTime stagedAt;

  /// How many launches started applying this restore. A launch that finishes removes the marker, so a marker
  /// with attempts left behind means the app was killed while applying.
  final int attempts;

  PendingBackupRestore attempted() =>
      PendingBackupRestore(name: name, id: id, kind: kind, createdAt: createdAt, dataVersion: dataVersion, stagedAt: stagedAt, attempts: attempts + 1);

  String encode() => jsonEncode({
    'attempts': attempts,
    'createdAt': backupDateText(createdAt),
    'dataVersion': dataVersion,
    'id': id,
    'kind': kind.name,
    'name': name,
    'stagedAt': backupDateText(stagedAt),
  });

  static PendingBackupRestore? decode(String text) {
    try {
      final json = jsonDecode(text) as Map<String, Object?>;
      return PendingBackupRestore(
        name: json['name']! as String,
        id: json['id']! as String,
        kind: BackupKind.values.byName(json['kind']! as String),
        createdAt: DateTime.parse(json['createdAt']! as String),
        dataVersion: json['dataVersion'] as String?,
        stagedAt: DateTime.parse(json['stagedAt']! as String),
        attempts: json['attempts'] as int? ?? 0,
      );
    } on Object {
      return null;
    }
  }
}

/// Thrown by a test's [UpdateBackup.applyStep] to end a launch as if the app had been killed there.
class SimulatedKill implements Exception {
  const SimulatedKill();
}

/// What the launch step did.
class LaunchReport {
  LaunchReport({this.staged, this.failed, this.restored});

  /// The backup staged before the databases open, if any.
  BackupKind? staged;

  /// The backup that should have been staged but could not be.
  BackupKind? failed;

  /// Whether a pending restore was applied (true) or rolled back (false).
  bool? restored;
}

/// The open databases a consistent snapshot copies from.
class OpenDatabases {
  const OpenDatabases({required this.memo, required this.booru});
  final SqlDatabase memo;
  final SqlDatabase booru;
}

/// The engine: snapshots, packing, the launch step and restore. Every function takes its folders
/// and store from a [BackupSetup].
abstract final class UpdateBackup {
  static const lastVersionKey = 'backup.lastRun.version';
  static const lastBuildKey = 'backup.lastRun.build';
  static const deviceIDKey = 'backup.deviceID';
  static const failureKey = 'backup.lastFailure';
  static const restoreReportKey = 'backup.lastRestore';

  /// The Google Drive twin of iOS "Keep in iCloud".
  static const keepInDriveKey = 'backup.keepInDrive';

  /// Set by a restore; the library sync sends the restored library as the newest state.
  static const libraryReplacedKey = 'backup.libraryReplacedAt';
  static const driveSyncEnabledKey = 'drive.librarySyncEnabled';
  static const _pendingMarker = 'pending.json';
  static const _committedMarker = 'pending.committed';
  static const _previousPreferences = 'preferences.json';
  static const _snapshotInfo = 'snapshot.json';

  /// Never rolled back by a restore, whether stored plain or under the image mode's prefix.
  static bool isKept(String key) {
    final plain = key.startsWith(BackupPreferences.imagePrefix) ? key.substring(BackupPreferences.imagePrefix.length) : key;
    return plain.startsWith('backup.') ||
        plain.startsWith('privacy.') ||
        const {'icloud.installation', 'icloud.librarySyncEnabled', 'icloud.offReminderShown', 'drive.librarySyncEnabled'}.contains(plain);
  }

  /// A short id naming this device in backup file names, made once.
  static Future<String> deviceID(BackupPreferenceStore store) async {
    final saved = await store.get(deviceIDKey);
    if (saved is String && saved.isNotEmpty) return saved;
    final id = uuidString().replaceAll('-', '').substring(0, 8).toLowerCase();
    await store.set(deviceIDKey, id);
    return id;
  }

  // MARK: Versions

  static List<int> components(String version) => [
    for (final part in version.split('.'))
      if (part.isNotEmpty) int.tryParse(RegExp(r'^\d*').stringMatch(part) ?? '') ?? 0,
  ];

  static bool isNewer(String version, String build, {required String than, required String thanBuild}) {
    final a = components(version), b = components(than);
    final count = a.length > b.length ? a.length : b.length;
    while (a.length < count) {
      a.add(0);
    }
    while (b.length < count) {
      b.add(0);
    }
    for (var index = 0; index < count; index++) {
      if (a[index] != b[index]) return a[index] > b[index];
    }
    return (int.tryParse(build) ?? 0) > (int.tryParse(thanBuild) ?? 0);
  }

  /// `minor` when the first or second version number changed, or nothing says which version ran last.
  static BackupKind kind(String? from, {required String to}) {
    if (from == null) return BackupKind.minor;
    final a = [...components(from), 0, 0], b = [...components(to), 0, 0];
    return a[0] != b[0] || a[1] != b[1] ? BackupKind.minor : BackupKind.patch;
  }

  // MARK: Launch step

  /// The app's launch step, before anything reads the preferences or opens a database. It does
  /// nothing under `flutter test` unless [force] asks, and never throws.
  static Future<({BackupSetup setup, LaunchReport report})?> launch({
    required Directory support,
    required String version,
    required String build,
    required String deviceName,
    BackupPreferenceStore? preferences,
    bool force = false,
  }) async {
    if (!force && Platform.environment.containsKey('FLUTTER_TEST')) return null;
    // Without a version the marker and the backup's labels would be wrong.
    if (version.isEmpty) return null;
    try {
      final setup = await BackupSetup.standard(
        support: support,
        version: version,
        build: build.isEmpty ? '0' : build,
        deviceName: deviceName,
        preferences: preferences,
      );
      return (setup: setup, report: await runAtLaunch(setup));
    } on Object catch (error) {
      debugPrint('Backup launch step failed: $error');
      return null;
    }
  }

  /// Runs before anything opens a database or writes preferences: copies the data the previous
  /// version left when the version changed, then applies a pending restore.
  static Future<LaunchReport> runAtLaunch(BackupSetup setup) async {
    final report = LaunchReport();
    final store = setup.preferences;
    final lastVersion = _text(await store.get(lastVersionKey)), lastBuild = _text(await store.get(lastBuildKey));
    if (lastVersion != setup.appVersion || lastBuild != setup.appBuild) {
      if (hasData(setup)) {
        final kind = UpdateBackup.kind(lastVersion, to: setup.appVersion);
        try {
          await takeSnapshot(setup, kind: kind, dataVersion: lastVersion, dataBuild: lastVersion == null ? null : lastBuild);
          report.staged = kind;
        } on Object catch (error) {
          report.failed = kind;
          await recordFailure(setup, BackupError.snapshotFailed(error is BackupError ? error.message : '$error').message);
        }
      }
      // Written even after a failure: the next launch would otherwise label migrated data as the old version's.
      await store.set(lastVersionKey, setup.appVersion);
      await store.set(lastBuildKey, setup.appBuild);
    }
    if (File('${setup.restore.path}/$_pendingMarker').existsSync()) {
      report.restored = await applyPendingRestore(setup);
    } else {
      // No marker: the last restore was committed (the marker's removal is the commit), so what it left is stale.
      // `previous` is never deleted while a marker says a restore is unfinished.
      _cleanCommitted(setup);
    }
    return report;
  }

  static String? _text(Object? value) => value is String ? value : null;

  static bool hasData(BackupSetup setup) => BackupEntry.databases.any((name) => File('${setup.dataFolder.path}/$name').existsSync());

  static Future<void> recordFailure(BackupSetup setup, String message) =>
      setup.preferences.set(failureKey, BackupFailure(date: setup.now(), message: message, appVersion: setup.appVersion).encode());

  static Future<BackupFailure?> lastFailure(BackupSetup setup) async => BackupFailure.decode(await setup.preferences.get(failureKey));

  static Future<BackupRestoreReport?> lastRestore(BackupSetup setup) async => BackupRestoreReport.decode(await setup.preferences.get(restoreReportKey));

  // MARK: Snapshots

  /// Copies the data into a staging folder. Without [databases] the database files are copied as
  /// they are (nothing has them open yet); with them, `VACUUM INTO` writes each one whole and
  /// consistent. Preferences must already be flushed to the store by the caller.
  static Future<Directory> takeSnapshot(
    BackupSetup setup, {
    required BackupKind kind,
    required String? dataVersion,
    required String? dataBuild,
    OpenDatabases? databases,
  }) async {
    setup.staging.createSync(recursive: true);
    final id = _uuid();
    // A folder without its info is unfinished; renaming it is the moment it becomes a snapshot.
    final partial = Directory('${setup.staging.path}/$id.partial');
    final folder = Directory('${setup.staging.path}/$id');
    Directory('${partial.path}/db').createSync(recursive: true);
    try {
      BackupCounts? counts;
      if (databases != null) {
        for (final (name, database) in [('memo.sqlite', databases.memo), ('booru.sqlite', databases.booru)]) {
          database.execute("VACUUM INTO '${'${partial.path}/db/$name'.replaceAll("'", "''")}'");
        }
        int count(SqlDatabase database, String table) {
          try {
            return database.value<int>('SELECT COUNT(*) FROM $table') ?? 0;
          } on Object {
            return 0;
          }
        }

        counts = BackupCounts(works: count(databases.memo, 'works'), images: count(databases.booru, 'favorites'));
      } else {
        for (final entry in BackupEntry.databaseEntries) {
          final source = File('${setup.dataFolder.path}/${entry.substring(3)}');
          if (source.existsSync()) source.copySync('${partial.path}/$entry');
        }
      }
      Directory('${partial.path}/prefs').createSync(recursive: true);
      File('${partial.path}/${BackupEntry.preferences}').writeAsBytesSync(BackupPreferences.encode(await setup.preferences.all()));
      Directory('${partial.path}/files').createSync(recursive: true);
      for (final MapEntry(key: entry, value: source) in setup.files.entries) {
        if (!source.existsSync()) continue;
        source.copySync('${partial.path}/$entry');
      }
      final info = BackupManifest(
        id: id,
        kind: kind,
        platform: setup.platform,
        createdAt: setup.now(),
        dataVersion: dataVersion,
        dataBuild: dataBuild,
        appVersion: setup.appVersion,
        appBuild: setup.appBuild,
        device: setup.device,
        counts: counts,
      );
      File('${partial.path}/$_snapshotInfo').writeAsBytesSync(info.encode(), flush: true);
      partial.renameSync(folder.path);
    } on Object {
      if (partial.existsSync()) partial.deleteSync(recursive: true);
      rethrow;
    }
    return folder;
  }

  static String _uuid() => uuidString();

  /// Finished snapshots waiting to be packed, oldest first. Unfinished ones are removed.
  static List<Directory> stagedSnapshots(BackupSetup setup) {
    if (!setup.staging.existsSync()) return [];
    final ready = <(Directory, DateTime)>[];
    for (final entity in setup.staging.listSync()) {
      final folder = entity is Directory ? entity : null;
      final info = File('${entity.path}/$_snapshotInfo');
      final manifest = folder == null || entity.path.endsWith('.partial') || !info.existsSync() ? null : BackupManifest.decode(info.readAsBytesSync());
      if (folder == null || manifest == null) {
        entity.deleteSync(recursive: true);
        continue;
      }
      ready.add((folder, manifest.createdAt));
    }
    ready.sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final (folder, _) in ready) folder];
  }

  /// Packs a staged snapshot into the local vault and removes it from staging. The packing runs
  /// away from the interface.
  static Future<({File file, BackupManifest manifest})> pack(Directory snapshot, {required BackupSetup setup}) async {
    final info = BackupManifest.decode(File('${snapshot.path}/$_snapshotInfo').readAsBytesSync())!;
    setup.vault.createSync(recursive: true);
    // Two backups made in the same second would share a name.
    while (File('${setup.vault.path}/${info.fileName}').existsSync()) {
      info.createdAt = info.createdAt.add(const Duration(seconds: 1));
    }
    final destination = File('${setup.vault.path}/${info.fileName}');
    final manifest = await _write(snapshot, info, destination, setup.work);
    if (snapshot.existsSync()) snapshot.deleteSync(recursive: true);
    return (file: destination, manifest: manifest);
  }

  static Future<BackupManifest> _write(Directory folder, BackupManifest manifest, File destination, Directory work) =>
      Isolate.run(() => BackupContainer.write(folder: folder, manifest: manifest, destination: destination, work: work));

  // MARK: Restore

  /// Reads a backup, checks it and unpacks it into a folder of its own, ready to stage.
  static Future<({Directory folder, BackupManifest manifest})> prepareRestore(File file, {required BackupSetup setup}) async {
    final archive = BackupArchive.open(file);
    archive.checkRestorable(appVersion: setup.appVersion, appBuild: setup.appBuild, platform: setup.platform);
    archive.requireLibrary();
    final folder = Directory('${setup.restore.path}/incoming-${_uuid()}')..createSync(recursive: true);
    try {
      await _extract(archive, folder);
      await _check(Directory('${folder.path}/db'));
    } on Object {
      if (folder.existsSync()) folder.deleteSync(recursive: true);
      rethrow;
    }
    return (folder: folder, manifest: archive.manifest);
  }

  static Future<void> _extract(BackupArchive archive, Directory folder) => Isolate.run(() => archive.extract(folder));

  /// Checks every entry's size and checksum without writing anything.
  static Future<void> checkOnly(BackupArchive archive) => Isolate.run(() => archive.extract(null));

  static Future<void> _check(Directory folder) => Isolate.run(() {
    checkDatabases(folder);
    verifyOpens(folder);
  });

  /// Each database opens, passes `quick_check`, and lists only migrations this app knows.
  static void checkDatabases(Directory folder) {
    for (final name in BackupEntry.databases) {
      final path = '${folder.path}/$name';
      if (!File(path).existsSync()) continue;
      bool superseded;
      try {
        final database = SqlDatabase.open(path);
        try {
          if (database.value<String>('PRAGMA quick_check') != 'ok') throw BackupError.databaseUnreadable;
          superseded = (name == 'memo.sqlite' ? AppDatabase.migrator : BooruStore.migrator).hasBeenSuperseded(database);
        } finally {
          database.close();
        }
      } on Object {
        throw BackupError.databaseUnreadable;
      }
      if (superseded) throw BackupError.newerApp;
    }
  }

  /// Opens both databases the way the app does, with every migration and repair step, and closes them. The app
  /// does this at the same launch, and a database that fails here would stop the app from starting at all.
  static void verifyOpens(Directory folder) {
    AppDatabase? library;
    BooruStore? images;
    try {
      final preferences = AppPreferences.memory();
      library = AppDatabase.open(path: '${folder.path}/memo.sqlite', preferences: preferences);
      images = BooruStore(path: '${folder.path}/booru.sqlite', preferences: preferences);
    } on Object {
      throw BackupError.databaseUnreadable;
    } finally {
      library?.dbWriter.close();
      images?.database.close();
    }
  }

  /// Moves a prepared folder into place and writes the marker the next launch looks for.
  static Future<void> stageRestore(Directory folder, {required BackupManifest manifest, required BackupSetup setup}) async {
    // A restore the last launch could not finish still holds the only copy of the original databases.
    if (Directory('${setup.restore.path}/previous').existsSync()) throw BackupError.unavailable;
    cancelPendingRestore(setup);
    folder.renameSync('${setup.restore.path}/pending');
    _writeMarker(
      setup,
      PendingBackupRestore(
        name: manifest.fileName,
        id: manifest.id,
        kind: manifest.kind,
        createdAt: manifest.createdAt,
        dataVersion: manifest.dataVersion,
        stagedAt: setup.now(),
      ),
    );
  }

  /// Written beside the marker and renamed over it, so the marker is never half written.
  static void _writeMarker(BackupSetup setup, PendingBackupRestore pending) {
    final marker = File('${setup.restore.path}/$_pendingMarker');
    final partial = File('${marker.path}.tmp')..writeAsStringSync(pending.encode(), flush: true);
    partial.renameSync(marker.path);
  }

  static PendingBackupRestore? pendingRestore(BackupSetup setup) {
    final marker = File('${setup.restore.path}/$_pendingMarker');
    return marker.existsSync() ? PendingBackupRestore.decode(marker.readAsStringSync()) : null;
  }

  /// Drops a staged restore that has not started. Once a launch has moved the original databases aside, the
  /// marker is that launch's to resolve, and this does nothing.
  static void cancelPendingRestore(BackupSetup setup) {
    if (Directory('${setup.restore.path}/previous').existsSync()) return;
    final marker = File('${setup.restore.path}/$_pendingMarker');
    if (marker.existsSync()) marker.deleteSync();
    final folder = Directory('${setup.restore.path}/pending');
    if (folder.existsSync()) folder.deleteSync(recursive: true);
  }

  /// Set by tests to see, and to stop, the steps of [applyPendingRestore]. Throwing [SimulatedKill] ends the
  /// launch on the spot, as a killed app would.
  @visibleForTesting
  static void Function(String step)? applyStep;

  static void _step(String name) => applyStep?.call(name);

  /// How many launches may start applying a restore before it is given up.
  static const maxAttempts = 2;

  /// Puts a staged backup in place. Everything from moving the live files aside to the commit is one unit: any
  /// failure puts the original databases and preferences back from `previous`, and `previous` is only deleted once
  /// the marker is gone, which is the commit. Returns whether the backup is now in place.
  static Future<bool> applyPendingRestore(BackupSetup setup) async {
    final markerFile = File('${setup.restore.path}/$_pendingMarker');
    if (!markerFile.existsSync()) return false;
    PendingBackupRestore? pending;
    try {
      pending = PendingBackupRestore.decode(markerFile.readAsStringSync());
    } on Object {
      pending = null;
    }
    final staged = Directory('${setup.restore.path}/pending');
    final previous = Directory('${setup.restore.path}/previous');
    final name = pending?.name ?? '';
    try {
      // An earlier launch stopped halfway: the data goes back as it was before anything else happens.
      if (previous.existsSync()) await _rollBack(setup, previous);
      // Two launches started this restore and neither finished: the app is being killed by it.
      if (pending == null || pending.attempts >= maxAttempts) throw BackupError.databaseUnreadable;
      if (!staged.existsSync()) throw BackupError.unavailable;
      _writeMarker(setup, pending.attempted());
      previous.createSync(recursive: true);
      try {
        for (final database in BackupEntry.databases) {
          _moveAside(setup, previous, database);
          _step('moved:$database');
        }
        _step('moveAside');
        for (final entry in BackupEntry.databaseEntries) {
          final source = File('${staged.path}/$entry');
          if (source.existsSync()) source.copySync('${setup.dataFolder.path}/${entry.substring(3)}');
        }
        _step('copyIn');
        checkDatabases(setup.dataFolder);
        keepTasteDevice(previous, setup.dataFolder);
        verifyOpens(setup.dataFolder);
        _step('check');
        await _applyPreferences(staged, previous, setup);
        _step('preferences');
        // The commit: from here the restore stands. A marker that cannot be removed undoes everything.
        _commit(setup, markerFile);
      } on SimulatedKill {
        rethrow;
      } on Object {
        await _rollBack(setup, previous);
        rethrow;
      }
    } on SimulatedKill {
      rethrow;
    } on Object catch (error) {
      final message = (error is BackupError ? error : BackupError.databaseUnreadable).message;
      await _report(setup, BackupRestoreReport(date: setup.now(), backup: name, succeeded: false, message: message));
      // Only when the original data is back is there nothing left to try; otherwise the marker stays for the next launch.
      if (!previous.existsSync()) _discardPending(setup, markerFile);
      return false;
    }
    await _report(setup, BackupRestoreReport(date: setup.now(), backup: name, succeeded: true));
    _finish(setup, staged, previous);
    return true;
  }

  /// A database is moved as a unit: its journal files first, the main file last, so a main file in `previous` means
  /// the whole database is there.
  static void _moveAside(BackupSetup setup, Directory previous, String database) {
    for (final suffix in [...BackupEntry.databaseSuffixes.skip(1), '']) {
      final live = File('${setup.dataFolder.path}/$database$suffix');
      if (live.existsSync()) live.renameSync('${previous.path}/$database$suffix');
    }
  }

  /// The commit: the marker is renamed away in one step. After it, a launch finding `previous` knows it may delete it.
  static void _commit(BackupSetup setup, File marker) {
    _step('commit');
    final done = File('${setup.restore.path}/$_committedMarker');
    if (done.existsSync()) done.deleteSync();
    marker.renameSync(done.path);
  }

  static void _discardPending(BackupSetup setup, File marker) {
    try {
      if (marker.existsSync()) marker.deleteSync();
      final staged = Directory('${setup.restore.path}/pending');
      if (staged.existsSync()) staged.deleteSync(recursive: true);
    } on Object catch (error) {
      debugPrint('Backup restore marker not removed: $error');
    }
  }

  /// What a restore leaves once it stands; none of it matters if it cannot be removed now.
  static void _finish(BackupSetup setup, Directory staged, Directory previous) {
    try {
      for (final MapEntry(key: entry, value: destination) in setup.files.entries) {
        final source = File('${staged.path}/$entry');
        if (!source.existsSync() || destination.existsSync()) continue;
        try {
          destination.parent.createSync(recursive: true);
          source.copySync(destination.path);
        } on Object {
          // A small file that cannot be written is rebuilt by the app.
        }
      }
      if (previous.existsSync()) previous.deleteSync(recursive: true);
      if (staged.existsSync()) staged.deleteSync(recursive: true);
      final done = File('${setup.restore.path}/$_committedMarker');
      if (done.existsSync()) done.deleteSync();
    } on Object catch (error) {
      debugPrint('Backup restore leftovers not removed: $error');
    }
  }

  /// Without a marker, `previous` and the staged files belong to a restore that was committed: they go.
  static void _cleanCommitted(BackupSetup setup) {
    try {
      for (final entity in [
        Directory('${setup.restore.path}/previous'),
        Directory('${setup.restore.path}/pending'),
        File('${setup.restore.path}/$_committedMarker'),
      ]) {
        if (entity.existsSync()) entity.deleteSync(recursive: true);
      }
    } on Object catch (error) {
      debugPrint('Backup restore leftovers not removed: $error');
    }
  }

  static Future<void> _report(BackupSetup setup, BackupRestoreReport report) async {
    try {
      await setup.preferences.set(restoreReportKey, report.encode());
    } on Object catch (error) {
      debugPrint('Backup restore report not saved: $error');
    }
  }

  /// Puts the original databases and preferences back, then removes `previous`. Each database is a unit: only one whose
  /// main file is in `previous` has its live files (journals too) replaced; a database that was not moved is left alone.
  static Future<void> _rollBack(BackupSetup setup, Directory previous) async {
    _step('rollBack');
    for (final database in BackupEntry.databases) {
      final kept = File('${previous.path}/$database');
      if (kept.existsSync()) {
        for (final suffix in BackupEntry.databaseSuffixes) {
          final live = File('${setup.dataFolder.path}/$database$suffix');
          if (live.existsSync()) live.deleteSync();
        }
      }
      for (final suffix in BackupEntry.databaseSuffixes) {
        final file = File('${previous.path}/$database$suffix'), live = File('${setup.dataFolder.path}/$database$suffix');
        // Journal files moved before their main file do not come back over a live main file that never moved.
        if (file.existsSync() && !live.existsSync()) file.renameSync(live.path);
      }
    }
    final preferences = File('${previous.path}/$_previousPreferences');
    if (preferences.existsSync()) {
      final values = BackupPreferences.decode(preferences.readAsBytesSync());
      if (values == null) throw BackupError.damaged;
      await setup.preferences.replaceAll(values);
    }
    previous.deleteSync(recursive: true);
  }

  /// The backup's keys replace the current ones, except the kept keys. No favorites sync runs again
  /// until the person answers the first-sync choice; accounts declined before or now stay declined.
  /// Returns the keys as they were, so a failure later in the restore can put them back.
  static Future<Map<String, Object>> _applyPreferences(Directory staged, Directory previous, BackupSetup setup) async {
    final current = await setup.preferences.all();
    // Kept beside the original databases, so a rollback after a killed launch can put the preferences back too.
    File('${previous.path}/$_previousPreferences').writeAsBytesSync(BackupPreferences.encode(current), flush: true);
    final file = File('${staged.path}/${BackupEntry.preferences}');
    // A backup without preferences leaves them as they are, but its favorites still wait to be asked.
    var restored = current;
    if (file.existsSync()) restored = BackupPreferences.decode(file.readAsBytesSync()) ?? (throw BackupError.damaged);
    var next = <String, Object>{
      for (final MapEntry(:key, :value) in restored.entries)
        if (!isKept(key)) key: value,
    };
    for (final MapEntry(:key, :value) in current.entries) {
      if (isKept(key)) next[key] = value;
    }
    for (final keys in setup.favorites) {
      next = SiteFavoriteKeys.restoredPreferences(next, current: current, keys: keys);
    }
    // The next library sync sends the restored library as the newest state. Only where sync is on: with it off or
    // signed out the signal would wait for months and stamp the library with this time. A normal capture handles it.
    next.remove(libraryReplacedKey);
    if (current[driveSyncEnabledKey] == true) next[libraryReplacedKey] = setup.now().millisecondsSinceEpoch / 1000;
    try {
      await setup.preferences.replaceAll(next);
    } on Object {
      try {
        await setup.preferences.replaceAll(current);
      } on Object {
        // Nothing more can be done for a store that refuses writes.
      }
      rethrow;
    }
    return current;
  }

  /// Analysis history names the device that recorded it; a backup from another device keeps this one's name.
  static void keepTasteDevice(Directory previous, Directory folder) {
    for (final name in BackupEntry.databases) {
      final old = File('${previous.path}/$name'), restored = File('${folder.path}/$name');
      if (!old.existsSync() || !restored.existsSync()) continue;
      Uint8List? device;
      try {
        final source = SqlDatabase.openReadOnly(old.path);
        try {
          if (source.tableExists('taste_meta')) device = source.value<Uint8List>("SELECT value FROM taste_meta WHERE key = 'device'");
        } finally {
          source.close();
        }
      } on Object {
        continue;
      }
      if (device == null) continue;
      try {
        final target = SqlDatabase.open(restored.path);
        try {
          if (target.tableExists('taste_meta')) target.write((db) => db.execute("UPDATE taste_meta SET value = ? WHERE key = 'device'", [device]));
        } finally {
          target.close();
        }
      } on Object {
        // The restored history keeps the other device's name; analysis still works.
      }
    }
  }
}
