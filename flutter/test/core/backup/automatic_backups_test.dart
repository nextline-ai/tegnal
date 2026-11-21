// ignore_for_file: depend_on_referenced_packages
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tegnal/core/backup/automatic_backups.dart';
import 'package:tegnal/core/backup/backup_container.dart';
import 'package:tegnal/core/backup/backup_preferences.dart';
import 'package:tegnal/core/backup/backup_vault.dart';
import 'package:tegnal/core/backup/update_backup.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/support/document_files.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/sync/library_drive_sync.dart';

import 'backup_test_support.dart';

/// A Drive folder in memory that also keeps backup files; nothing contacts Google.
class _Drive implements DriveBackend, DriveBackupFiles {
  _Drive({this.configured = true, this.signedIn = true});
  final bool configured;
  bool signedIn;
  final files = <String, (String, Uint8List)>{};
  int uploads = 0;

  @override
  bool get isConfigured => configured;
  @override
  Future<DriveAccount?> restore({DriveAccount? known}) async => signedIn ? const DriveAccount(id: 'a', email: 'a@example.com') : null;
  @override
  Future<DriveAccount> connect() async => const DriveAccount(id: 'a', email: 'a@example.com');
  @override
  Future<void> disconnect() async {}
  @override
  Future<String> folder() async => 'folder';
  @override
  Future<List<DriveFile>> documents(String folder) async => [];
  @override
  Future<Uint8List> download(String fileID) async => files[fileID]!.$2;
  @override
  Future<String> upload(String folder, String name, Uint8List data, {String? fileID}) => uploadBackup(folder, name, data, fileID: fileID);
  @override
  Future<List<DriveFile>> backupFiles(String folder) async => [
    for (final MapEntry(:key, value: (name, data)) in files.entries) DriveFile(id: key, name: name, size: data.length, modified: ''),
  ];
  @override
  Future<String> uploadBackup(String folder, String name, Uint8List data, {String? fileID}) async {
    uploads += 1;
    final id = fileID ?? 'file-${files.length + 1}';
    files[id] = (name, data);
    return id;
  }

  @override
  Future<void> deleteFile(String fileID) async => files.remove(fileID);
}

/// The system pickers, answered from memory.
class _Pickers extends DocumentFiles {
  _Pickers();
  File? toOpen;
  String? savedName;
  List<int>? saved;

  @override
  Future<bool> createDocument({required String name, required File source, String mimeType = 'application/json'}) async {
    savedName = name;
    saved = source.readAsBytesSync();
    return true;
  }

  @override
  Future<File?> openDocument({List<String> mimeTypes = const []}) async => toOpen;
}

void main() {
  AutomaticBackups modelFor(BackupFixture fixture, (AppDatabase, BooruStore) library, {BackupVault? drive, List<int>? flushed}) {
    return AutomaticBackups(setup: fixture.setup, databases: () => fixture.openDatabases(library), drive: drive, flushPreferences: () async => flushed?.add(1));
  }

  test('the model backs up, exports, imports, stages and cancels a restore', () async {
    final fixture = BackupFixture(addTearDown);
    final library = fixture.openLibrary();
    library.$1.upsertWork(galleryId: 1, title: 'One');
    final flushed = <int>[];
    final model = modelFor(fixture, library, flushed: flushed);
    var notified = 0;
    model.addListener(() => notified += 1);
    expect(model.keepInDrive, isTrue, reason: 'Keep in Drive starts on');
    expect(model.driveAvailable, isFalse);
    expect(model.pendingRestore, isNull);

    await model.backUpNow();
    expect(flushed, [1], reason: 'Preferences are flushed before a manual snapshot');
    final item = model.items.single;
    expect(item.kind, BackupKind.manual);
    expect(item.dataVersion, '1.6.0');
    expect(item.appVersion, '1.6.0');
    expect(item.deviceName, 'Test phone');
    expect(item.isThisDevice, isTrue);
    expect(item.places, {BackupPlace.local});
    expect(item.download, BackupDownload.onDevice);
    expect(item.size, greaterThan(0));
    expect(model.totalSize, item.size);
    expect(item.isProtected, isTrue, reason: 'The newest manual backup is always kept');
    expect(notified, greaterThan(0));
    expect(model.isWorking, isFalse);

    final exported = await model.export(item);
    expect(BackupArchive.open(exported).manifest.fileName, item.id);
    await model.delete(item);
    expect(model.items, isEmpty);
    final imported = await model.importFile(exported);
    expect(imported?.id, item.id, reason: 'An imported file is listed under its own name again');
    expect(exported.existsSync(), isTrue, reason: 'The picked file is left as it is');

    await model.restore(imported!);
    expect(flushed.length, 2);
    expect(model.pendingRestore?.name, item.id);
    expect(model.items.any((entry) => entry.kind == BackupKind.safety), isTrue, reason: 'The current data is backed up before a restore is staged');
    model.cancelPendingRestore();
    expect(model.pendingRestore, isNull);
    expect(UpdateBackup.pendingRestore(fixture.setup), isNull);
    fixture.closeLibrary(library);
  });

  test('export and import go through the document pickers, and a backup of another platform is refused', () async {
    final fixture = BackupFixture(addTearDown);
    final library = fixture.openLibrary();
    final model = modelFor(fixture, library);
    await model.backUpNow();
    final item = model.items.single;
    final pickers = _Pickers();
    expect(await model.exportToFile(item, files: pickers), isTrue);
    expect(pickers.savedName, item.id);
    expect(BackupArchive.open(File(fixture.setup.vault.listSync().whereType<File>().single.path)).manifest.id, isNotEmpty);

    await model.delete(item);
    final picked = File('${fixture.scratch('picked').path}/${item.id}')..writeAsBytesSync(pickers.saved!);
    pickers.toOpen = picked;
    expect((await model.importFromFile(files: pickers))?.id, item.id);
    expect(picked.existsSync(), isFalse, reason: 'The picker copy is removed');
    pickers.toOpen = null;
    expect(await model.importFromFile(files: pickers), isNull, reason: 'Cancelling imports nothing');

    final foreign = fixture.container([
      ('db/memo.sqlite', Uint8List.fromList([1, 2, 3])),
    ], manifest: sampleManifest(platform: 'ios'));
    await expectLater(model.importFile(foreign), throwsA(BackupError.otherPlatform));
    final damaged = fixture.save(foreign.readAsBytesSync().sublist(0, 20));
    await expectLater(model.importFile(damaged), throwsA(isA<BackupError>()));
    fixture.closeLibrary(library);
  });

  test('after launch packs a staged snapshot, keeps it and applies retention', () async {
    final fixture = BackupFixture(addTearDown);
    fixture.makeLibrary([1]);
    fixture.store.values[UpdateBackup.lastVersionKey] = '1.5.1';
    fixture.store.values[UpdateBackup.lastBuildKey] = '44';
    expect((await UpdateBackup.runAtLaunch(fixture.setup)).staged, BackupKind.minor);
    final library = fixture.openLibrary();
    final model = modelFor(fixture, library);
    await model.afterLaunch();
    final item = model.items.single;
    expect(item.kind, BackupKind.minor);
    expect(item.dataVersion, '1.5.1');
    expect(item.isProtected, isTrue, reason: 'The newest minor backup is always kept');
    expect(UpdateBackup.stagedSnapshots(fixture.setup), isEmpty);
    await model.afterLaunch();
    expect(model.items, hasLength(1), reason: 'A second pass finds nothing new');

    await UpdateBackup.recordFailure(fixture.setup, 'it failed');
    await model.refresh();
    expect(model.lastFailure?.message, 'it failed');
    await model.dismissFailure();
    expect(model.lastFailure, isNull);
    expect(fixture.store.values.containsKey(UpdateBackup.failureKey), isFalse);
    fixture.closeLibrary(library);
  });

  test('the model reports a restore that was applied at launch', () async {
    final fixture = BackupFixture(addTearDown);
    final library = fixture.openLibrary();
    library.$1.upsertWork(galleryId: 1, title: 'One');
    final backup = await fixture.manualBackup(library);
    fixture.closeLibrary(library);
    expect((await fixture.restore(backup)).restored, isTrue);
    final reopened = fixture.openLibrary();
    final model = modelFor(fixture, reopened);
    await model.refresh();
    expect(model.lastRestore?.succeeded, isTrue);
    expect(model.lastRestore?.backup, backup.uri.pathSegments.last);
    expect(model.pendingRestore, isNull);
    fixture.closeLibrary(reopened);
  });

  test('Google Drive keeps a copy when it is signed in, and only then', () async {
    final fixture = BackupFixture(addTearDown);
    final library = fixture.openLibrary();
    final drive = _Drive(signedIn: false);
    final vault = DriveBackupVault(backend: drive, isSignedIn: () => drive.signedIn);
    final model = modelFor(fixture, library, drive: vault);
    await model.backUpNow();
    expect(model.driveAvailable, isFalse);
    expect(drive.files, isEmpty, reason: 'Signed out, nothing is uploaded');
    expect(model.items.single.places, {BackupPlace.local});

    drive.signedIn = true;
    await model.refresh();
    expect(model.driveAvailable, isTrue);
    await model.setKeepInDrive(true);
    expect(drive.files, hasLength(1), reason: 'Turning the switch on copies what is already there');
    final item = model.items.single;
    expect(item.places, {BackupPlace.local, BackupPlace.drive});
    expect(drive.files.values.single.$1, item.id);
    await model.refresh();
    expect(drive.uploads, 1, reason: 'A backup already in Drive is not uploaded again');

    await model.setKeepInDrive(false);
    expect(fixture.store.values[UpdateBackup.keepInDriveKey], false);
    await model.backUpNow();
    expect(drive.files, hasLength(1), reason: 'Switched off, new backups stay local');
    await model.setKeepInDrive(true);
    expect(drive.files, hasLength(2));

    // A backup only in Drive restores after a download.
    final local = Directory(fixture.setup.vault.path);
    final driveOnly = model.items.last;
    File('${local.path}/${driveOnly.id}').deleteSync();
    await model.refresh();
    final remote = model.items.firstWhere((entry) => entry.id == driveOnly.id);
    expect(remote.places, {BackupPlace.drive});
    expect(remote.download, BackupDownload.inCloud);
    await model.restore(remote);
    expect(model.pendingRestore?.name, remote.id);

    // Deleting removes it from both places.
    final both = model.items.firstWhere((entry) => entry.places.length == 2);
    await model.delete(both);
    expect(drive.files.values.any((file) => file.$1 == both.id), isFalse);
    expect(local.listSync().whereType<File>().any((file) => file.uri.pathSegments.last == both.id), isFalse);

    // Without a configured client or without the backup interface the vault is not available.
    expect(await DriveBackupVault(backend: _Drive(configured: false), isSignedIn: () => true).available(), isFalse);
    fixture.closeLibrary(library);
  });

  test('Google Drive refuses a backup above the size it can carry in one piece', () async {
    final fixture = BackupFixture(addTearDown);
    final drive = _Drive();
    final vault = DriveBackupVault(backend: drive, isSignedIn: () => true);
    final big = File('${fixture.scratch('big').path}/tegnal_manual_1_1_20261120T031500Z_a1b2c3d4.tegnalbackup');
    final handle = big.openSync(mode: FileMode.write)..truncateSync(DriveBackupVault.sizeLimit + 1);
    handle.closeSync();
    await expectLater(vault.add(big, big.uri.pathSegments.last), throwsA(BackupError.tooLarge));
    expect(drive.uploads, 0);
    drive.files['x'] = ('tegnal_manual_1_1_20261120T031500Z_a1b2c3d4.tegnalbackup', Uint8List(DriveBackupVault.sizeLimit + 1));
    await expectLater(vault.fetch('tegnal_manual_1_1_20261120T031500Z_a1b2c3d4.tegnalbackup', fixture.scratch('fetched')), throwsA(BackupError.tooLarge));
  });

  test('the plugin store replaces keys without clearing, and AppPreferences sees the same keys', () async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.withData({
      'app_theme': 'dark',
      'gone': 'x',
      'booru.suite.reader.page': 3,
      'list': <String>['a'],
      'ratio': 1.5,
      'flag': true,
    });
    final store = SharedPreferencesBackupStore();
    final before = await store.all();
    expect(before.keys.toSet(), {'app_theme', 'gone', 'booru.suite.reader.page', 'list', 'ratio', 'flag'});

    await store.set('backup.lastRun.version', '1.6.0');
    await store.replaceAll(
      {...before}
        ..remove('gone')
        ..['app_theme'] = 'light',
    );
    final after = await store.all();
    expect(after.containsKey('gone'), isFalse);
    expect(after['app_theme'], 'light');
    expect(after['list'], ['a']);
    expect(after['ratio'], 1.5);
    expect(after.containsKey('backup.lastRun.version'), isFalse, reason: 'replaceAll makes the store hold exactly the keys given');

    await store.set('backup.lastRun.version', '1.6.0');
    final preferences = await AppPreferences.load();
    expect(preferences.defaults.object('app_theme'), 'light');
    expect(preferences.defaults.object('backup.lastRun.version'), '1.6.0', reason: 'The launch step writes before AppPreferences reads');
    expect(preferences.booruDefaults.object('reader.page'), 3, reason: 'Image mode is the same store under a prefix');
    expect(await store.get('missing'), isNull);
  });
}
