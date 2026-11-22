import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/backup/backup_container.dart';
import 'package:tegnal/core/backup/backup_preferences.dart';
import 'package:tegnal/core/backup/update_backup.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/support/preferences.dart';

import '../../support/fixtures.dart';

/// `Preferences` over a [MemoryBackupStore]'s map, with the image mode's prefix, as `StoredPreferences` is
/// over the plugin's store. Writes are visible to the engine at once.
class StoreView extends Preferences {
  StoreView(this.store, [this.prefix = '']);
  final MemoryBackupStore store;
  final String prefix;

  @override
  Object? object(String key) => store.values[prefix + key];

  @override
  void set(String key, Object? value) => value == null ? store.values.remove(prefix + key) : store.values[prefix + key] = value;
}

/// One engine setup over temporary folders and its own store, and the preferences views of it.
class BackupFixture {
  BackupFixture(void Function(void Function() body) addTearDown, {String version = '1.6.0', String build = '47', DateTime Function()? now})
    : root = temporaryDirectory(addTearDown),
      store = MemoryBackupStore() {
    Directory('${root.path}/Data').createSync();
    setup = BackupSetup(
      dataFolder: Directory('${root.path}/Data'),
      root: Directory('${root.path}/Backups'),
      files: {
        'files/gallery-keys': File('${root.path}/Support/gallery-keys.json'),
        'files/work-missing-sites': File('${root.path}/Support/work-missing-sites.json'),
        'files/downloads.json': File('${root.path}/Support/Downloads/downloads.json'),
        'files/downloads-settings.json': File('${root.path}/Support/Downloads/settings.json'),
        'files/generated-index.json': File('${root.path}/Support/Generated/index.json'),
      },
      preferences: store,
      appVersion: version,
      appBuild: build,
      device: const BackupDevice(id: 'a1b2c3d4', name: 'Test phone'),
      now: now,
    );
    defaults = StoreView(store);
    images = StoreView(store, BackupPreferences.imagePrefix);
  }

  final Directory root;
  final MemoryBackupStore store;
  late final BackupSetup setup;
  late final Preferences defaults;
  late final Preferences images;

  String get memoPath => '${setup.dataFolder.path}/memo.sqlite';
  String get booruPath => '${setup.dataFolder.path}/booru.sqlite';

  /// A fresh preferences object for databases, which only need something to hold their own keys.
  (AppDatabase, BooruStore) openLibrary() {
    final preferences = AppPreferences.memory();
    return (AppDatabase.open(path: memoPath, preferences: preferences), BooruStore(path: booruPath, preferences: preferences));
  }

  void closeLibrary((AppDatabase, BooruStore) library) {
    library.$1.dbWriter.close();
    library.$2.database.close();
  }

  OpenDatabases openDatabases((AppDatabase, BooruStore) library) => OpenDatabases(memo: library.$1.dbWriter, booru: library.$2.database);

  void makeLibrary(List<int> works) {
    final library = openLibrary();
    for (final id in works) {
      library.$1.upsertWork(galleryId: id, title: 'Work $id');
    }
    closeLibrary(library);
  }

  Directory scratch(String name) => Directory('${setup.root.path}/$name')..createSync(recursive: true);

  void write(List<int> data, Directory folder, String name) {
    final file = File('${folder.path}/$name')..parent.createSync(recursive: true);
    file.writeAsBytesSync(data);
  }

  File save(List<int> data) {
    final file = File('${scratch('files').path}/${DateTime.now().microsecondsSinceEpoch}-${data.length}.tegnalbackup');
    file.writeAsBytesSync(data);
    return file;
  }

  /// A container written by hand, entries stored as they are, so tests can put in names the writer never would.
  File container(List<(String, List<int>)> entries, {BackupManifest? manifest, bool corruptChecksum = false}) {
    final made = manifest ?? sampleManifest();
    made.entries = [
      for (final (name, data) in entries)
        BackupManifestEntry(
          name: name,
          policy: 'replace',
          size: data.length,
          storedSize: data.length,
          compression: 'none',
          sha256: corruptChecksum ? '0' * 64 : sha256.convert(data).toString(),
        ),
    ];
    final json = made.encode();
    return save([...BackupContainer.header(json.length), ...json, for (final (_, data) in entries) ...data]);
  }

  /// A manual backup of the open databases, packed into the vault.
  Future<File> manualBackup((AppDatabase, BooruStore) library) async {
    final folder = await UpdateBackup.takeSnapshot(
      setup,
      kind: BackupKind.manual,
      dataVersion: setup.appVersion,
      dataBuild: setup.appBuild,
      databases: openDatabases(library),
    );
    return (await UpdateBackup.pack(folder, setup: setup)).file;
  }

  /// Checks, stages and applies a restore of [backup], as a restore and the next launch do.
  Future<LaunchReport> restore(File backup) async {
    final prepared = await UpdateBackup.prepareRestore(backup, setup: setup);
    await UpdateBackup.stageRestore(prepared.folder, manifest: prepared.manifest, setup: setup);
    return UpdateBackup.runAtLaunch(setup);
  }
}

/// The manifest of the iOS tests: a manual backup of 1.6.0 (47), data version unknown.
BackupManifest sampleManifest({String platform = 'android'}) => BackupManifest(
  id: 'id',
  kind: BackupKind.manual,
  platform: platform,
  createdAt: DateTime.fromMillisecondsSinceEpoch(1795144500 * 1000, isUtc: true),
  dataVersion: null,
  dataBuild: null,
  appVersion: '1.6.0',
  appBuild: '47',
  device: const BackupDevice(id: 'a1b2c3d4', name: 'iPhone'),
);
