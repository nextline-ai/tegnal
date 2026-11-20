import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/backup/automatic_backups.dart';
import 'package:tegnal/core/backup/backup_container.dart';
import 'package:tegnal/core/backup/update_backup.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/support/sql_database.dart';
import 'package:tegnal/core/sync/library_sync_adapter.dart';
import 'package:tegnal/core/sync/library_sync_record.dart';

import 'backup_test_support.dart';

/// A device with its own library and preferences, and a backup of another library to restore over it.
class _Scenario {
  _Scenario(this.fixture, this.backup, this.memo, this.booru, this.preferences);
  final BackupFixture fixture;
  final File backup;
  final Uint8List memo;
  final Uint8List booru;
  final Map<String, Object> preferences;

  Directory get previous => Directory('${fixture.setup.restore.path}/previous');
  File get marker => File('${fixture.setup.restore.path}/pending.json');

  Future<void> stage() async {
    final prepared = await UpdateBackup.prepareRestore(backup, setup: fixture.setup);
    await UpdateBackup.stageRestore(prepared.folder, manifest: prepared.manifest, setup: fixture.setup);
  }

  /// The original databases and preferences are in place, byte for byte, and nothing is left half done.
  void expectOriginal({String reason = ''}) {
    expect(File(fixture.memoPath).readAsBytesSync(), memo, reason: 'memo.sqlite $reason');
    expect(File(fixture.booruPath).readAsBytesSync(), booru, reason: 'booru.sqlite $reason');
    expect(_withoutBackupKeys(fixture.store.values), preferences, reason: 'preferences $reason');
    expect(previous.existsSync(), isFalse, reason: 'previous $reason');
  }
}

Map<String, Object> _withoutBackupKeys(Map<String, Object> values) => {
  for (final MapEntry(:key, :value) in values.entries)
    if (!key.startsWith('backup.')) key: value,
};

Future<_Scenario> _scenario(void Function(void Function() body) addTearDown) async {
  final fixture = BackupFixture(addTearDown);
  final values = fixture.store.values;
  values[UpdateBackup.lastVersionKey] = '1.6.0';
  values[UpdateBackup.lastBuildKey] = '47';
  values[UpdateBackup.driveSyncEnabledKey] = true;
  values['app_theme'] = 'in the backup';
  var library = fixture.openLibrary();
  library.$1.upsertWork(galleryId: 8, title: 'In the backup');
  final backup = await fixture.manualBackup(library);
  fixture.closeLibrary(library);
  // This device's own library, different from the backup's.
  File(fixture.memoPath).deleteSync();
  File(fixture.booruPath).deleteSync();
  library = fixture.openLibrary();
  library.$1.upsertWork(galleryId: 7, title: 'Original');
  fixture.closeLibrary(library);
  values['app_theme'] = 'original';
  values['manga.defaultTags'] = 'original only';
  return _Scenario(fixture, backup, File(fixture.memoPath).readAsBytesSync(), File(fixture.booruPath).readAsBytesSync(), _withoutBackupKeys(values));
}

/// A container with entries and manifest as given, for sizes and dates no writer would produce.
File _raw(BackupFixture fixture, BackupManifest manifest, [List<int> body = const []]) {
  final json = manifest.encode();
  return fixture.save([...BackupContainer.header(json.length), ...json, ...body]);
}

BackupManifestEntry _entry(String name, {required int size, required int stored, String compression = 'deflate'}) =>
    BackupManifestEntry(name: name, policy: 'replace', size: size, storedSize: stored, compression: compression, sha256: '0' * 64);

void main() {
  tearDown(() => UpdateBackup.applyStep = null);

  Future<BackupError?> failure(Future<void> Function() body) async {
    try {
      await body();
    } on BackupError catch (error) {
      return error;
    }
    return null;
  }

  // MARK: The restore is one unit

  for (final step in ['moved:memo.sqlite', 'moved:booru.sqlite', 'moveAside', 'copyIn', 'check', 'preferences', 'commit']) {
    test('a failure at "$step" leaves the original databases and preferences in place', () async {
      final scenario = await _scenario(addTearDown);
      await scenario.stage();
      UpdateBackup.applyStep = (name) {
        if (name == step) throw StateError('injected at $name');
      };
      expect((await UpdateBackup.runAtLaunch(scenario.fixture.setup)).restored, isFalse);
      scenario.expectOriginal(reason: 'after the failed launch');
      expect(scenario.marker.existsSync(), isFalse, reason: 'A restore that rolled back is not tried again');
      expect((await UpdateBackup.lastRestore(scenario.fixture.setup))?.succeeded, isFalse);
      expect(scenario.fixture.store.values.containsKey(UpdateBackup.libraryReplacedKey), isFalse);

      UpdateBackup.applyStep = null;
      await UpdateBackup.runAtLaunch(scenario.fixture.setup);
      scenario.expectOriginal(reason: 'after the next launch');
    });
  }

  test('a rollback that itself fails leaves the originals in previous, and the next launch puts them back', () async {
    final scenario = await _scenario(addTearDown);
    await scenario.stage();
    var rollbackFailures = 1;
    UpdateBackup.applyStep = (name) {
      if (name == 'copyIn') throw StateError('copy failed');
      if (name == 'rollBack' && rollbackFailures-- > 0) throw StateError('rollback failed');
    };
    expect((await UpdateBackup.runAtLaunch(scenario.fixture.setup)).restored, isFalse);
    expect(scenario.previous.existsSync(), isTrue, reason: 'previous is the only copy of the originals now');
    expect(File('${scenario.previous.path}/memo.sqlite').readAsBytesSync(), scenario.memo);
    expect(File('${scenario.previous.path}/booru.sqlite').readAsBytesSync(), scenario.booru);
    expect(scenario.marker.existsSync(), isTrue, reason: 'The restore is unresolved, so the marker stays');

    // Staging another restore or cancelling must not touch what previous holds.
    scenario.fixture.scratch('Restore/incoming-again');
    await expectLater(
      UpdateBackup.stageRestore(Directory('${scenario.fixture.setup.restore.path}/incoming-again'), manifest: sampleManifest(), setup: scenario.fixture.setup),
      throwsA(BackupError.unavailable),
    );
    UpdateBackup.cancelPendingRestore(scenario.fixture.setup);
    expect(scenario.previous.existsSync(), isTrue);
    expect(scenario.marker.existsSync(), isTrue);

    expect((await UpdateBackup.runAtLaunch(scenario.fixture.setup)).restored, isFalse);
    scenario.expectOriginal(reason: 'the next launch rolled back from previous instead of deleting it');
    expect(scenario.marker.existsSync(), isFalse);
  });

  test('a kill between moving the two databases loses neither, and the attempts give up after the second', () async {
    final scenario = await _scenario(addTearDown);
    await scenario.stage();
    UpdateBackup.applyStep = (name) {
      if (name == 'moved:memo.sqlite') throw const SimulatedKill();
    };
    await expectLater(UpdateBackup.runAtLaunch(scenario.fixture.setup), throwsA(isA<SimulatedKill>()));
    // memo.sqlite is in previous, booru.sqlite is still live: both exist.
    expect(File('${scenario.previous.path}/memo.sqlite').readAsBytesSync(), scenario.memo);
    expect(File(scenario.fixture.booruPath).readAsBytesSync(), scenario.booru);
    expect(File(scenario.fixture.memoPath).existsSync(), isFalse);
    expect(UpdateBackup.pendingRestore(scenario.fixture.setup)?.attempts, 1);

    // The second launch is killed at the same place.
    await expectLater(UpdateBackup.runAtLaunch(scenario.fixture.setup), throwsA(isA<SimulatedKill>()));
    expect(File('${scenario.previous.path}/memo.sqlite').readAsBytesSync(), scenario.memo);
    expect(File(scenario.fixture.booruPath).readAsBytesSync(), scenario.booru);
    expect(UpdateBackup.pendingRestore(scenario.fixture.setup)?.attempts, 2);

    // The third does not start over: it rolls back and reports a failure.
    final report = await UpdateBackup.runAtLaunch(scenario.fixture.setup);
    expect(report.restored, isFalse);
    scenario.expectOriginal(reason: 'after giving up');
    expect(scenario.marker.existsSync(), isFalse);
    final restored = await UpdateBackup.lastRestore(scenario.fixture.setup);
    expect(restored?.succeeded, isFalse);
    expect(restored?.message, isNotEmpty);
  });

  test('a kill after the first attempt is retried once and the restore then goes through', () async {
    final scenario = await _scenario(addTearDown);
    await scenario.stage();
    UpdateBackup.applyStep = (name) {
      if (name == 'moved:memo.sqlite') throw const SimulatedKill();
    };
    await expectLater(UpdateBackup.runAtLaunch(scenario.fixture.setup), throwsA(isA<SimulatedKill>()));
    UpdateBackup.applyStep = null;
    expect((await UpdateBackup.runAtLaunch(scenario.fixture.setup)).restored, isTrue);
    final library = scenario.fixture.openLibrary();
    expect(library.$1.getWork(8), isNotNull);
    expect(library.$1.getWork(7), isNull);
    scenario.fixture.closeLibrary(library);
    expect(scenario.previous.existsSync(), isFalse);
    expect(scenario.marker.existsSync(), isFalse);
  });

  test('a marker that cannot be read gives up and puts the originals back instead of deleting them', () async {
    final scenario = await _scenario(addTearDown);
    // As if a launch had moved the databases aside and then the marker had been damaged.
    scenario.previous.createSync(recursive: true);
    File(scenario.fixture.memoPath).renameSync('${scenario.previous.path}/memo.sqlite');
    File(scenario.fixture.booruPath).renameSync('${scenario.previous.path}/booru.sqlite');
    scenario.marker.writeAsStringSync('not json');
    expect((await UpdateBackup.runAtLaunch(scenario.fixture.setup)).restored, isFalse);
    scenario.expectOriginal();
    expect(scenario.marker.existsSync(), isFalse);
  });

  test('previous with no marker is deleted only because the restore was committed', () async {
    final scenario = await _scenario(addTearDown);
    scenario.previous.createSync(recursive: true);
    File('${scenario.previous.path}/memo.sqlite').writeAsBytesSync(const [1, 2, 3]);
    await UpdateBackup.runAtLaunch(scenario.fixture.setup);
    expect(scenario.previous.existsSync(), isFalse);
    expect(File(scenario.fixture.memoPath).readAsBytesSync(), scenario.memo, reason: 'The live data is not touched');
  });

  test('the preferences go back with a rollback after a kill', () async {
    final scenario = await _scenario(addTearDown);
    await scenario.stage();
    // Killed once the preferences were replaced, before the commit.
    UpdateBackup.applyStep = (name) {
      if (name == 'preferences') throw const SimulatedKill();
    };
    await expectLater(UpdateBackup.runAtLaunch(scenario.fixture.setup), throwsA(isA<SimulatedKill>()));
    expect(scenario.fixture.store.values['app_theme'], 'in the backup', reason: 'The kill left the restored preferences in place');
    UpdateBackup.applyStep = (name) {
      if (name == 'copyIn') throw const SimulatedKill();
    };
    await expectLater(UpdateBackup.runAtLaunch(scenario.fixture.setup), throwsA(isA<SimulatedKill>()));
    UpdateBackup.applyStep = null;
    // Third launch gives up: databases and preferences are the originals.
    await UpdateBackup.runAtLaunch(scenario.fixture.setup);
    scenario.expectOriginal(reason: 'after giving up');
  });

  // MARK: What may be restored

  test('a database that passes quick_check but fails its migrations is refused and rolled back', () async {
    final scenario = await _scenario(addTearDown);
    final bad = scenario.fixture.scratch('bad');
    final old = SqlDatabase.open('${bad.path}/memo.sqlite');
    AppDatabase.migrator.migrate(old, upTo: 'v15_work_page_count');
    old.execute('DROP TABLE folders');
    old.close();
    BooruStore(path: '${bad.path}/booru.sqlite', preferences: AppPreferences.memory()).database.close();
    expect(
      () => AppDatabase.open(path: '${bad.path}/memo.sqlite', preferences: AppPreferences.memory()),
      throwsA(anything),
      reason: 'The premise: the app would not start',
    );
    UpdateBackup.checkDatabases(bad);

    // Refused when the backup is checked.
    final memo = File('${bad.path}/memo.sqlite').readAsBytesSync(), booru = File('${bad.path}/booru.sqlite').readAsBytesSync();
    final file = scenario.fixture.container([('db/memo.sqlite', memo), ('db/booru.sqlite', booru)]);
    expect(await failure(() => UpdateBackup.prepareRestore(file, setup: scenario.fixture.setup)), BackupError.databaseUnreadable);

    // And, were one staged anyway, rolled back before it is kept.
    final folder = scenario.fixture.scratch('Restore/incoming-bad');
    scenario.fixture.write(memo, folder, 'db/memo.sqlite');
    scenario.fixture.write(booru, folder, 'db/booru.sqlite');
    await UpdateBackup.stageRestore(folder, manifest: sampleManifest(), setup: scenario.fixture.setup);
    expect((await UpdateBackup.runAtLaunch(scenario.fixture.setup)).restored, isFalse);
    scenario.expectOriginal();
    final library = scenario.fixture.openLibrary();
    expect(library.$1.getWork(7), isNotNull, reason: 'The app opens as before');
    scenario.fixture.closeLibrary(library);
  });

  test('a backup without both databases is refused on restore and on import', () async {
    final scenario = await _scenario(addTearDown);
    final library = scenario.fixture.openLibrary();
    final model = AutomaticBackups(setup: scenario.fixture.setup, databases: () => scenario.fixture.openDatabases(library));
    final memo = File(scenario.fixture.memoPath).readAsBytesSync();
    for (final entries in <List<(String, List<int>)>>[
      [],
      [('prefs/store.json', utf8.encode('{}'))],
      [('db/memo.sqlite', memo)],
      [('db/booru.sqlite', memo)],
      [('files/gallery-keys', utf8.encode('keys'))],
    ]) {
      final file = scenario.fixture.container(entries);
      expect(await failure(() => UpdateBackup.prepareRestore(file, setup: scenario.fixture.setup)), BackupError.damaged, reason: '${entries.map((e) => e.$1)}');
      await expectLater(model.importFile(file), throwsA(BackupError.damaged));
    }
    expect(model.items, isEmpty);
    expect(scenario.marker.existsSync(), isFalse);
    scenario.fixture.closeLibrary(library);
  });

  test('sizes that lie upward, oversized entries and future dates are refused without a crash', () async {
    final fixture = BackupFixture(addTearDown);
    BackupManifest manifest(List<BackupManifestEntry> entries, {DateTime? createdAt}) {
      final made = sampleManifest()..entries = entries;
      if (createdAt != null) made.createdAt = createdAt;
      return made;
    }

    final inflates = _raw(fixture, manifest([_entry('db/memo.sqlite', size: 1 << 40, stored: 10)]));
    expect(() => BackupArchive.open(inflates), throwsA(BackupError.tooLarge));
    final stores = _raw(fixture, manifest([_entry('db/memo.sqlite', size: 10, stored: 1 << 62)]));
    expect(() => BackupArchive.open(stores), throwsA(BackupError.tooLarge));
    final storesMore = _raw(fixture, manifest([_entry('db/memo.sqlite', size: 10, stored: BackupContainer.fileLimit + 1)]));
    expect(() => BackupArchive.open(storesMore), throwsA(BackupError.tooLarge));
    final noOverflow = _raw(fixture, manifest([_entry('db/memo.sqlite', size: 10, stored: 1 << 62), _entry('db/booru.sqlite', size: 10, stored: 1 << 62)]));
    expect(() => BackupArchive.open(noOverflow), throwsA(BackupError.tooLarge));
    const each = 1500 * 1024 * 1024;
    final together = _raw(fixture, manifest([_entry('db/memo.sqlite', size: each, stored: 10), _entry('db/booru.sqlite', size: each, stored: 10)]));
    expect(() => BackupArchive.open(together), throwsA(BackupError.tooLarge), reason: 'Each below 2 GB, together above');
    final negative = _raw(fixture, manifest([_entry('db/memo.sqlite', size: -1, stored: 0, compression: 'none')]));
    expect(() => BackupArchive.open(negative), throwsA(BackupError.damaged));

    // A modest lie still fails: the stream does not inflate to what it declares.
    final data = Uint8List(1000);
    final deflated = BackupContainer.deflate.encode(data);
    final lies = BackupManifest(
      id: 'id',
      kind: BackupKind.manual,
      createdAt: sampleManifest().createdAt,
      dataVersion: null,
      dataBuild: null,
      appVersion: '1.6.0',
      appBuild: '47',
      device: sampleManifest().device,
      entries: [
        BackupManifestEntry(
          name: 'db/memo.sqlite',
          policy: 'replace',
          size: 5000,
          storedSize: deflated.length,
          compression: 'deflate',
          sha256: sha256.convert(data).toString(),
        ),
      ],
    );
    expect(await failure(() => BackupArchive.open(_raw(fixture, lies, deflated)).extract(null)), BackupError.damaged);

    final future = _raw(fixture, manifest([], createdAt: DateTime.now().toUtc().add(const Duration(days: 2))));
    expect(() => BackupArchive.open(future), throwsA(BackupError.damaged));
    BackupArchive.open(_raw(fixture, manifest([], createdAt: DateTime.now().toUtc().add(const Duration(hours: 1)))));
    BackupArchive.open(_raw(fixture, manifest([], createdAt: DateTime.now().toUtc().subtract(const Duration(days: 400)))));
  });

  test('an import larger than the file limit is refused before anything is copied', () async {
    final scenario = await _scenario(addTearDown);
    final library = scenario.fixture.openLibrary();
    final model = AutomaticBackups(setup: scenario.fixture.setup, databases: () => scenario.fixture.openDatabases(library));
    final huge = File('${scenario.fixture.scratch('picked').path}/huge.tegnalbackup');
    final handle = huge.openSync(mode: FileMode.write)..truncateSync(BackupContainer.fileLimit + 1);
    handle.closeSync();
    await expectLater(model.importFile(huge), throwsA(BackupError.tooLarge));
    expect(scenario.fixture.setup.work.existsSync() && scenario.fixture.setup.work.listSync().isNotEmpty, isFalse, reason: 'Nothing was copied');
    scenario.fixture.closeLibrary(library);
  });

  test('bytes after an entry\'s deflate stream are refused, and the scanner measures streams of every kind', () async {
    final fixture = BackupFixture(addTearDown);
    final data = Uint8List.fromList([for (var i = 0; i < 20000; i++) i % 13]);
    final stream = BackupContainer.deflate.encode(data);
    BackupManifest withEntry(int stored) => sampleManifest()
      ..entries = [
        BackupManifestEntry(
          name: 'db/memo.sqlite',
          policy: 'replace',
          size: data.length,
          storedSize: stored,
          compression: 'deflate',
          sha256: sha256.convert(data).toString(),
        ),
      ];
    final clean = _raw(fixture, withEntry(stream.length), stream);
    await BackupArchive.open(clean).extract(null);
    for (final extra in [
      [0],
      [1, 2, 3],
      List.filled(500, 7),
    ]) {
      final padded = _raw(fixture, withEntry(stream.length + extra.length), [...stream, ...extra]);
      expect(await failure(() => BackupArchive.open(padded).extract(null)), BackupError.damaged, reason: '${extra.length} extra bytes');
    }

    // The measure matches what zlib wrote, for stored, fixed and dynamic blocks and for empty input.
    final random = Random(3);
    final samples = <String, List<int>>{
      'empty': const [],
      'one byte': const [42],
      'text': utf8.encode('the quick brown fox jumps over the lazy dog ' * 50),
      'zeros': Uint8List(100000),
      'noise': [for (var i = 0; i < 70000; i++) random.nextInt(256)],
      'mixed': [for (var i = 0; i < 90000; i++) i % 5 == 0 ? random.nextInt(256) : i % 7],
    };
    for (final MapEntry(:key, value: sample) in samples.entries) {
      for (final level in [0, 1, 6, 9]) {
        final encoded = ZLibCodec(raw: true, level: level).encode(sample);
        final file = File('${fixture.scratch('scan').path}/$key-$level')..writeAsBytesSync([9, 9, ...encoded, 8, 8, 8]);
        expect(DeflateScanner.length(file, 2, 2 + encoded.length + 3), encoded.length, reason: '$key at level $level');
        expect(() => DeflateScanner.length(file, 2, 2 + encoded.length - 1), throwsA(isA<FormatException>()), reason: '$key at level $level, cut short');
      }
    }
  });

  // MARK: Sync after a restore

  test('captureReplacement with an empty ledger stamps every row at the restore and deletes nothing', () {
    final preferences = AppPreferences.memory();
    final database = AppDatabase.inMemory(preferences: preferences);
    database.upsertWork(galleryId: 1, title: 'One');
    database.upsertWork(galleryId: 2, title: 'Two');
    final adapter = LibrarySyncAdapter(
      manga: database,
      booru: BooruStore.inMemory(preferences: preferences),
      mangaDefaults: preferences.defaults,
      booruDefaults: preferences.booruDefaults,
    );
    final snapshot = adapter.snapshot();
    final ledger = LibrarySyncLedger()..captureReplacement(snapshot, device: 'd', at: 5000);
    expect(ledger.changes.length, snapshot.length);
    expect(ledger.changes.values.every((change) => !change.deleted && change.timestamp == 5000 && change.device == 'd'), isTrue);
    expect(rowsEquality.equals(ledger.baseline, snapshot), isTrue);
    // A ledger that knows more rows deletes the ones the restored library lacks.
    final known = LibrarySyncLedger()..capture(snapshot, device: 'd', now: 1000);
    database.deleteWork(2);
    known.captureReplacement(adapter.snapshot(), device: 'd', at: 5000);
    expect(known.changes.values.where((change) => change.deleted).length, greaterThan(0));
  });

  test('with sync off the restore leaves no signal behind, and with it on the signal is set', () async {
    final off = await _scenario(addTearDown);
    off.fixture.store.values[UpdateBackup.driveSyncEnabledKey] = false;
    await off.stage();
    expect((await UpdateBackup.runAtLaunch(off.fixture.setup)).restored, isTrue);
    expect(off.fixture.store.values.containsKey(UpdateBackup.libraryReplacedKey), isFalse, reason: 'A later normal capture handles the restored library');
    expect(off.fixture.store.values[UpdateBackup.driveSyncEnabledKey], false);

    final missing = await _scenario(addTearDown);
    missing.fixture.store.values.remove(UpdateBackup.driveSyncEnabledKey);
    await missing.stage();
    await UpdateBackup.runAtLaunch(missing.fixture.setup);
    expect(missing.fixture.store.values.containsKey(UpdateBackup.libraryReplacedKey), isFalse);

    final on = await _scenario(addTearDown);
    await on.stage();
    await UpdateBackup.runAtLaunch(on.fixture.setup);
    expect(on.fixture.store.values[UpdateBackup.libraryReplacedKey], isA<double>());
  });

  // MARK: The model

  test('a failed restore is one notice, which can be dismissed', () async {
    final scenario = await _scenario(addTearDown);
    final library = scenario.fixture.openLibrary();
    final model = AutomaticBackups(setup: scenario.fixture.setup, databases: () => scenario.fixture.openDatabases(library));
    scenario.fixture.closeLibrary(library);
    await scenario.stage();
    UpdateBackup.applyStep = (name) {
      if (name == 'copyIn') throw StateError('injected');
    };
    expect((await UpdateBackup.runAtLaunch(scenario.fixture.setup)).restored, isFalse);
    await model.refresh();
    expect(model.lastRestore?.succeeded, isFalse);
    expect(model.lastFailure, isNull, reason: 'Not both a failure note and a restore note');
    expect(model.pendingRestore, isNull);
    await model.dismissRestoreReport();
    expect(model.lastRestore, isNull);
    expect(scenario.fixture.store.values.containsKey(UpdateBackup.restoreReportKey), isFalse);
    await model.refresh();
    expect(model.lastRestore, isNull);
  });
}
