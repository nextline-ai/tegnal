import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/support/l10n.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/sync/library_drive_sync.dart';

/// A Drive folder shared by fake devices; nothing contacts Google.
class FakeDrive {
  final files = <String, (String name, Uint8List data, int revision)>{};
  int _revision = 0;
  int downloads = 0;
}

class FakeBackend implements DriveBackend {
  FakeBackend(this.drive, {this.configured = true, this.accountID = 'account-1'});
  final FakeDrive drive;
  final bool configured;
  String accountID;
  bool signedIn = false;
  bool revoked = false;
  bool authorized = true;

  @override
  bool get isConfigured => configured;

  @override
  Future<DriveAccount?> restore() async => signedIn ? DriveAccount(id: accountID, email: 'person@example.com') : null;

  @override
  Future<DriveAccount> connect() async {
    signedIn = true;
    return DriveAccount(id: accountID, email: 'person@example.com');
  }

  @override
  Future<void> disconnect() async {
    signedIn = false;
    revoked = true;
  }

  void _check() {
    if (!authorized) throw const DriveAuthorizationError();
  }

  @override
  Future<String> folder() async {
    _check();
    return 'folder';
  }

  @override
  Future<List<DriveFile>> documents(String folder) async {
    _check();
    return [
      for (final MapEntry(:key, value: (name, data, revision)) in drive.files.entries) DriveFile(id: key, name: name, size: data.length, modified: '$revision'),
    ];
  }

  @override
  Future<Uint8List> download(String fileID) async {
    _check();
    drive.downloads += 1;
    return drive.files[fileID]!.$2;
  }

  @override
  Future<String> upload(String folder, String name, Uint8List data, {String? fileID}) async {
    _check();
    final id = fileID ?? 'file-${drive.files.length + 1}';
    drive.files[id] = (name, data, ++drive._revision);
    return id;
  }
}

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('drive-sync-'));
  tearDown(() => root.deleteSync(recursive: true));

  ({LibraryDriveSync sync, AppDatabase database, FakeBackend backend, AppPreferences preferences}) device(
    FakeDrive drive,
    String name, {
    bool configured = true,
  }) {
    final preferences = AppPreferences.memory();
    final database = AppDatabase.inMemory(preferences: preferences);
    final backend = FakeBackend(drive, configured: configured);
    final sync = LibraryDriveSync(
      backend: backend,
      database: database,
      booru: BooruStore.inMemory(preferences: preferences),
      defaults: preferences.defaults,
      booruDefaults: preferences.booruDefaults,
      directory: Directory('${root.path}/$name'),
    );
    return (sync: sync, database: database, backend: backend, preferences: preferences);
  }

  test('sync is off by default and explains a build without a client ID', () {
    final drive = FakeDrive();
    final off = device(drive, 'off');
    expect(off.sync.enabled, isFalse);
    expect(off.sync.status, L10n.text('Sync Off'));
    final unconfigured = device(drive, 'unconfigured', configured: false);
    expect(unconfigured.sync.status, L10n.text('Sync is not set up in this build.'));
  });

  test('two devices merge their libraries through their own documents', () async {
    final drive = FakeDrive();
    final a = device(drive, 'a'), b = device(drive, 'b');
    a.database.upsertWork(galleryId: 100, title: 'First');
    b.database.upsertWork(galleryId: 200, title: 'Second');
    expect(await a.sync.connect(), isNull);
    await a.sync.synchronize();
    expect(await b.sync.connect(), isNull);
    await b.sync.synchronize();
    await a.sync.synchronize();
    expect(a.database.getWork(200)?.title, 'Second');
    expect(b.database.getWork(100)?.title, 'First');
    expect(drive.files.values.map((file) => file.$1).toSet(), hasLength(2), reason: 'Each device writes only its own document');
    expect(a.sync.status, L10n.text('Google Drive Sync On'));
    expect(a.sync.cloudDocumentCount, 2);
    expect(a.sync.lastSynced, isNotNull);

    // A deletion on one device removes the work everywhere, even after a restart.
    a.database.deleteWork(200);
    await a.sync.synchronize();
    await b.sync.synchronize();
    expect(b.database.getWork(200), isNull);
    final restarted = LibraryDriveSync(
      backend: a.backend,
      database: a.database,
      booru: BooruStore.inMemory(preferences: a.preferences),
      defaults: a.preferences.defaults,
      booruDefaults: a.preferences.booruDefaults,
      directory: Directory('${root.path}/a'),
    );
    expect(restarted.enabled, isTrue);
    await restarted.synchronize();
    expect(a.database.getWork(200), isNull);
  });

  test('an unchanged peer document is not downloaded again', () async {
    final drive = FakeDrive();
    final a = device(drive, 'a'), b = device(drive, 'b');
    await a.sync.connect();
    await a.sync.synchronize();
    await b.sync.connect();
    await b.sync.synchronize();
    final count = drive.downloads;
    await b.sync.synchronize();
    expect(drive.downloads, count);
  });

  test('an unreadable peer file does not block healthy documents', () async {
    final drive = FakeDrive();
    final a = device(drive, 'a'), b = device(drive, 'b');
    a.database.upsertWork(galleryId: 42);
    await a.sync.connect();
    await a.sync.synchronize();
    drive.files['broken'] = ('library-broken.json', Uint8List.fromList(utf8.encode('interrupted')), 99);
    await b.sync.connect();
    await b.sync.synchronize();
    expect(b.database.getWork(42), isNotNull);
    expect(b.sync.status, L10n.text('Some Google Drive files could not be read. Other changes were merged. Try syncing again.'));
  });

  test('lost Drive access asks to sign in again and keeps local data', () async {
    final drive = FakeDrive();
    final a = device(drive, 'a');
    a.database.upsertWork(galleryId: 7);
    await a.sync.connect();
    a.backend.authorized = false;
    await a.sync.synchronize();
    expect(a.sync.status, L10n.text('Sign in to Google to sync.'));
    expect(a.database.getWork(7), isNotNull);
  });

  test('disconnecting turns sync off, revokes and stops later passes', () async {
    final drive = FakeDrive();
    final a = device(drive, 'a');
    await a.sync.connect();
    await a.sync.synchronize();
    await a.sync.disconnect();
    expect(a.backend.revoked, isTrue);
    expect(a.sync.enabled, isFalse);
    expect(a.sync.account, isNull);
    final files = drive.files.length;
    a.database.upsertWork(galleryId: 1);
    await a.sync.synchronize();
    expect(drive.files.length, files);
    expect(a.sync.status, L10n.text('Sync Off'));
  });
}
