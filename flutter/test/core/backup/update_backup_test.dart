import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/backup/backup_container.dart';
import 'package:tegnal/core/backup/backup_preferences.dart';
import 'package:tegnal/core/backup/backup_retention.dart';
import 'package:tegnal/core/backup/update_backup.dart';
import 'package:tegnal/core/content/cover_queue.dart';
import 'package:tegnal/core/content/site_favorites_sync.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/support/sql_database.dart';
import 'package:tegnal/core/sync/library_sync_adapter.dart';
import 'package:tegnal/core/sync/library_sync_record.dart';

import 'backup_test_support.dart';

/// Ported case for case from `UpdateBackupTests` (iOS).
void main() {
  final random = Random(7);
  Uint8List noise(int count) => Uint8List.fromList([for (var i = 0; i < count; i++) random.nextInt(256)]);

  Future<BackupError?> failure(Future<void> Function() body) async {
    try {
      await body();
    } on BackupError catch (error) {
      return error;
    }
    return null;
  }

  // MARK: Container

  test('container round trip keeps every byte and stores incompressible data as it is', () async {
    final fixture = BackupFixture(addTearDown);
    final folder = fixture.scratch('source');
    final compressible = Uint8List.fromList([for (var i = 0; i < 3000000; i++) i % 7]);
    final incompressible = noise(1500000);
    fixture.write(compressible, folder, 'db/memo.sqlite');
    fixture.write(incompressible, folder, 'db/booru.sqlite');
    fixture.write(const [], folder, 'db/memo.sqlite-journal');
    fixture.write(utf8.encode('keys'), folder, 'files/gallery-keys');
    fixture.write(utf8.encode('ignored'), folder, 'notes.txt');
    final file = File('${fixture.setup.vault.path}/round.tegnalbackup');
    final written = await BackupContainer.write(folder: folder, manifest: sampleManifest(), destination: file, work: fixture.setup.work);

    final archive = BackupArchive.open(file);
    expect(archive.manifest.encode(), written.encode());
    expect(archive.manifest.entries.map((entry) => entry.name), ['db/memo.sqlite', 'db/memo.sqlite-journal', 'db/booru.sqlite', 'files/gallery-keys']);
    BackupManifestEntry entry(String name) => archive.manifest.entries.firstWhere((entry) => entry.name == name);
    expect(entry('db/memo.sqlite').compression, 'deflate');
    expect(entry('db/booru.sqlite').compression, 'none', reason: 'Data that does not shrink is stored as it is');
    expect(entry('files/gallery-keys').policy, 'ifMissing');
    final out = fixture.scratch('out');
    await archive.extract(out);
    expect(File('${out.path}/db/memo.sqlite').readAsBytesSync(), compressible);
    expect(File('${out.path}/db/booru.sqlite').readAsBytesSync(), incompressible);
    expect(File('${out.path}/db/memo.sqlite-journal').readAsBytesSync(), isEmpty);
    expect(File('${out.path}/files/gallery-keys').readAsBytesSync(), utf8.encode('keys'));
    expect(File('${out.path}/notes.txt').existsSync(), isFalse);

    // The stored deflate stream is plain RFC 1951, as the iOS app reads it.
    final raw = file.readAsBytesSync();
    final start = archive.bodyOffset;
    final inflated = ZLibCodec(raw: true).decode(raw.sublist(start, start + entry('db/memo.sqlite').storedSize));
    expect(inflated, compressible);
    final json = utf8.decode(raw.sublist(13, start));
    expect(json, contains('"dataVersion":null'), reason: 'An unknown data version is written as null');
    expect(json, contains('"createdAt":"2026-11-20T03:15:00Z"'));
  });

  test('a backup written here has the header and manifest layout the design specifies', () async {
    final fixture = BackupFixture(addTearDown);
    final folder = fixture.scratch('source');
    fixture.write(utf8.encode('library'), folder, 'db/memo.sqlite');
    final file = File('${fixture.setup.vault.path}/layout.tegnalbackup');
    final manifest = sampleManifest();
    await BackupContainer.write(folder: folder, manifest: manifest, destination: file, work: fixture.setup.work);

    final raw = file.readAsBytesSync();
    expect(raw.sublist(0, 8), ascii.encode('TEGNALBK'), reason: 'bytes 0-7: the magic');
    expect(raw[8], 1, reason: 'byte 8: the container version');
    final length = (raw[9] << 24) | (raw[10] << 16) | (raw[11] << 8) | raw[12];
    expect(length, raw.length - 13 - 7, reason: 'bytes 9-12: the manifest length, big-endian; the body is the 7 stored bytes');
    // Sorted keys, no spaces and a date in whole seconds with Z: the bytes the iOS encoder writes.
    final text = utf8.decode(raw.sublist(13, 13 + length));
    expect(
      text.replaceAll(RegExp(r'"sha256":"[0-9a-f]{64}"'), '"sha256":"-"'),
      '{"appBuild":"47","appVersion":"1.6.0","createdAt":"2026-11-20T03:15:00Z","dataBuild":null,"dataVersion":null,'
      '"device":{"id":"a1b2c3d4","name":"iPhone"},"entries":[{"compression":"none","name":"db/memo.sqlite","policy":"replace","sha256":"-","size":7,"storedSize":7}],'
      '"format":"tegnal-backup","id":"id","kind":"manual","platform":"android","version":1}',
    );
    expect(raw.sublist(13 + length), utf8.encode('library'), reason: 'the body follows, in manifest order');
    expect(jsonDecode(text), isA<Map<String, Object?>>());
  });

  test('damaged or foreign files are refused', () async {
    final fixture = BackupFixture(addTearDown);
    final folder = fixture.scratch('source');
    fixture.write(noise(4096), folder, 'db/memo.sqlite');
    final file = File('${fixture.setup.vault.path}/good.tegnalbackup');
    await BackupContainer.write(folder: folder, manifest: sampleManifest(), destination: file, work: fixture.setup.work);
    final good = file.readAsBytesSync();

    expect(() => BackupArchive.open(fixture.save([...good]..[0] = 0x58)), throwsA(BackupError.notBackup));
    expect(() => BackupArchive.open(fixture.save([...good]..[8] = 2)), throwsA(BackupError.notBackup));

    final flipped = BackupArchive.open(fixture.save([...good]..[good.length - 1] ^= 0xFF));
    expect(await failure(() => flipped.extract(fixture.scratch('flipped'))), BackupError.damaged);
    expect(File('${fixture.setup.root.path}/flipped/db/memo.sqlite').existsSync(), isFalse, reason: 'A file that fails its checksum is not left behind');

    expect(() => BackupArchive.open(fixture.save(good.sublist(0, good.length - 1))), throwsA(BackupError.damaged));
    expect(() => BackupArchive.open(fixture.save([...good, 0])), throwsA(BackupError.damaged));

    final oversized = [...BackupContainer.header(BackupContainer.manifestLimit + 1), ...Uint8List(BackupContainer.manifestLimit + 1)];
    expect(() => BackupArchive.open(fixture.save(oversized)), throwsA(BackupError.notBackup));

    final foreign = fixture.container([('db/memo.sqlite', utf8.encode('x'))], manifest: sampleManifest(platform: 'ios'));
    expect(() => BackupArchive.open(foreign).checkRestorable(appVersion: '1.6.0', appBuild: '47'), throwsA(BackupError.otherPlatform));
    expect(await failure(() => UpdateBackup.prepareRestore(foreign, setup: fixture.setup)), BackupError.otherPlatform);

    final newer = sampleManifest()..platform = 'android';
    final future = fixture.container(
      [('db/memo.sqlite', utf8.encode('x'))],
      manifest: BackupManifest(
        id: 'id',
        kind: BackupKind.manual,
        createdAt: newer.createdAt,
        dataVersion: null,
        dataBuild: null,
        appVersion: '1.10.0',
        appBuild: '47',
        device: newer.device,
      ),
    );
    expect(await failure(() => UpdateBackup.prepareRestore(future, setup: fixture.setup)), BackupError.newerApp);
    BackupManifest made(String version, String build) => BackupManifest(
      id: 'id',
      kind: BackupKind.manual,
      createdAt: newer.createdAt,
      dataVersion: null,
      dataBuild: null,
      appVersion: version,
      appBuild: build,
      device: newer.device,
    );
    expect(
      () => BackupArchive.open(fixture.container([], manifest: made('1.6.0', '48'))).checkRestorable(appVersion: '1.6.0', appBuild: '47'),
      throwsA(BackupError.newerApp),
    );
    BackupArchive.open(fixture.container([], manifest: made('1.5.1', '44'))).checkRestorable(appVersion: '1.6.0', appBuild: '47');

    // A manifest that is not JSON, and one whose format is not ours, are not backups.
    final garbage = utf8.encode('not json');
    expect(() => BackupArchive.open(fixture.save([...BackupContainer.header(garbage.length), ...garbage])), throwsA(BackupError.notBackup));
    final other = utf8.encode('{"format":"other","version":1}');
    expect(() => BackupArchive.open(fixture.save([...BackupContainer.header(other.length), ...other])), throwsA(BackupError.notBackup));
  });

  test('a stream that inflates past its declared size is refused', () async {
    final fixture = BackupFixture(addTearDown);
    final data = Uint8List(100000);
    final stored = ZLibCodec(raw: true).encode(data);
    final manifest = sampleManifest()
      ..entries = [
        BackupManifestEntry(name: 'db/memo.sqlite', policy: 'replace', size: 10, storedSize: stored.length, compression: 'deflate', sha256: '0' * 64),
      ];
    final json = manifest.encode();
    final file = fixture.save([...BackupContainer.header(json.length), ...json, ...stored]);
    expect(await failure(() => BackupArchive.open(file).extract(null)), BackupError.damaged);
  });

  test('unknown entry names are checked but never written', () async {
    final fixture = BackupFixture(addTearDown);
    final file = fixture.container([('../escape', utf8.encode('evil')), ('db/memo.sqlite', utf8.encode('library')), ('files/unknown', utf8.encode('?'))]);
    final out = fixture.scratch('deep/out');
    await BackupArchive.open(file).extract(out);
    expect(File('${out.path}/db/memo.sqlite').readAsStringSync(), 'library');
    expect(File('${out.parent.path}/escape').existsSync(), isFalse);
    expect(File('${out.path}/files/unknown').existsSync(), isFalse);

    // An unknown entry is still checked: a wrong checksum anywhere refuses the file.
    final bad = fixture.container([('files/unknown', utf8.encode('?'))], corruptChecksum: true);
    expect(await failure(() => BackupArchive.open(bad).extract(null)), BackupError.damaged);
  });

  test('file names encode and decode', () {
    final date = DateTime.fromMillisecondsSinceEpoch(1795000000750, isUtc: true);
    final name = BackupName(kind: BackupKind.minor, dataVersion: '1.5.1', dataBuild: '44', createdAt: date, deviceID: 'a1b2c3d4');
    expect(name.fileName, 'tegnal_minor_1.5.1_44_20261118T110640Z_a1b2c3d4.tegnalbackup');
    expect(BackupName.tryParse(name.fileName), name);
    expect(BackupName.tryParse(name.fileName)!.createdAt, DateTime.fromMillisecondsSinceEpoch(1795000000000, isUtc: true));

    final unknown = BackupName(kind: BackupKind.minor, dataVersion: null, dataBuild: null, createdAt: date, deviceID: 'a1b2c3d4');
    expect(unknown.fileName, 'tegnal_minor_0_0_20261118T110640Z_a1b2c3d4.tegnalbackup');
    final decoded = BackupName.tryParse(unknown.fileName)!;
    expect(decoded.dataVersion, isNull);
    expect(decoded.dataBuild, isNull);

    final odd = BackupName(kind: BackupKind.manual, dataVersion: '1.6_beta 2', dataBuild: '4/7', createdAt: date, deviceID: 'dev_ice');
    expect(odd.fileName, 'tegnal_manual_1.6-beta-2_4-7_20261118T110640Z_dev-ice.tegnalbackup');
    expect(BackupName.tryParse(odd.fileName), odd);

    for (final invalid in [
      'tegnal_minor_1.5.1_44_20261118T110640Z_a1b2c3d4.zip',
      'tegnal_other_1_1_20261118T110640Z_a.tegnalbackup',
      'tegnal_minor_1_1_2026-11-19_a.tegnalbackup',
      'tegnal_minor_1_1_20261118T110640Z_.tegnalbackup',
      'other_minor_1_1_20261118T110640Z_a.tegnalbackup',
      'tegnal_minor_1_1_20261118T110640Z_a_b.tegnalbackup',
      'tegnal_minor_1_1_20261318T110640Z_a.tegnalbackup',
    ]) {
      expect(BackupName.tryParse(invalid), isNull, reason: invalid);
    }
  });

  // MARK: Retention

  BackupRetentionItem item(String name, BackupKind kind, {required int day, required int mb, String device = 'd'}) => BackupRetentionItem(
    name: name,
    size: mb * 1024 * 1024,
    device: device,
    kind: kind,
    date: DateTime.fromMillisecondsSinceEpoch(day * 86400 * 1000, isUtc: true),
  );

  test('retention deletes nothing under the limit', () {
    final items = [for (var i = 0; i < 10; i++) item('m$i', BackupKind.manual, day: i, mb: 9)];
    expect(BackupRetention.expired(items), isEmpty);
  });

  test('retention deletes unprotected backups until the rest fit, the oldest of all last', () {
    final items = [
      item('s0', BackupKind.safety, day: 0, mb: 30),
      item('p1', BackupKind.patch, day: 1, mb: 30),
      item('m2', BackupKind.manual, day: 2, mb: 30),
      item('s3', BackupKind.safety, day: 3, mb: 30),
      item('m4', BackupKind.manual, day: 4, mb: 30),
      item('p5', BackupKind.patch, day: 5, mb: 30),
      item('min6', BackupKind.minor, day: 6, mb: 30),
    ];
    // 210 MB: p1 is one of the two newest patches, s3 and m4 the newest safety and manual backups; the older ones go.
    expect(BackupRetention.expired(items), ['m2', 's0']);
    final more = [...items, item('p7', BackupKind.patch, day: 7, mb: 1)];
    expect(BackupRetention.expired(more), [
      'p1',
      'm2',
      's0',
    ], reason: 'A third patch is no longer protected, and deleting stops when nothing unprotected is left');
  });

  test('retention keeps protected backups even when they alone exceed the limit', () {
    final items = [
      item('p1', BackupKind.patch, day: 1, mb: 60),
      item('p2', BackupKind.patch, day: 2, mb: 60),
      item('min0', BackupKind.minor, day: 0, mb: 60),
      item('min3', BackupKind.minor, day: 3, mb: 60),
      item('m-old', BackupKind.manual, day: 0, mb: 1),
      item('m4', BackupKind.manual, day: 4, mb: 1),
      item('other-p', BackupKind.patch, day: 1, mb: 60, device: 'other'),
      item('other-min', BackupKind.minor, day: 1, mb: 60, device: 'other'),
    ];
    expect(BackupRetention.expired(items), [
      'min0',
      'm-old',
    ], reason: 'Only the older minor and the older manual one may go; each device keeps its own protected backups');
    expect(BackupRetention.protected(items), {'p1', 'p2', 'min3', 'm4', 'other-p', 'other-min'});
  });

  test('the newest safety and manual backups of a device survive every later pass', () {
    final items = [
      item('old', BackupKind.manual, day: 1, mb: 90),
      item('safety', BackupKind.safety, day: 2, mb: 60),
      item('manual', BackupKind.manual, day: 3, mb: 60),
      item('other-safety', BackupKind.safety, day: 1, mb: 60, device: 'other'),
      item('other-manual', BackupKind.manual, day: 1, mb: 60, device: 'other'),
    ];
    for (final keeping in [
      <String>{},
      {'something-else'},
    ]) {
      final expired = BackupRetention.expired(items, keeping: keeping);
      expect(expired, ['old'], reason: 'passes with keeping $keeping');
      expect(expired, isNot(contains('safety')));
      expect(expired, isNot(contains('manual')));
    }
    expect(BackupRetention.protected(items), {'safety', 'manual', 'other-safety', 'other-manual'});
    // Newer ones replace them as the protected ones, and the former newest becomes ordinary.
    final newer = [...items, item('safety-2', BackupKind.safety, day: 4, mb: 1)];
    expect(BackupRetention.protected(newer), contains('safety-2'));
    expect(BackupRetention.protected(newer), isNot(contains('safety')));
  });

  test('retention counts a backup in two vaults once', () {
    final items = [item('a', BackupKind.manual, day: 1, mb: 60), item('a', BackupKind.manual, day: 1, mb: 60), item('b', BackupKind.manual, day: 2, mb: 30)];
    expect(BackupRetention.expired(items), isEmpty, reason: '90 MB, not 150 MB');
    expect(BackupRetention.expired([...items, item('c', BackupKind.manual, day: 3, mb: 20)]), ['b'], reason: 'The oldest of all goes last');
  });

  test('over the limit the spacing widens instead of the oldest going', () {
    final now = DateTime.fromMillisecondsSinceEpoch(400 * 86400 * 1000, isUtc: true);
    // Every three days for a year, 1 MB each.
    final items = [for (var day = 40; day <= 400; day += 3) item('a$day', BackupKind.periodic, day: day, mb: 1)];
    final expired = BackupRetention.expired(items, limit: 60 * 1024 * 1024, now: now).toSet();
    final kept = [
      for (final value in items)
        if (!expired.contains(value.name)) value.date.millisecondsSinceEpoch ~/ (86400 * 1000),
    ];
    expect(kept.length, 60);
    expect(kept.first, 40, reason: 'The oldest backup stays');
    expect(kept.last, 400, reason: 'The newest automatic backup is always kept');
    final gaps = [for (var i = 1; i < kept.length; i++) kept[i] - kept[i - 1]];
    expect(gaps.skip(gaps.length - 5).reduce((a, b) => a > b ? a : b), lessThan(gaps.take(5).reduce((a, b) => a < b ? a : b)),
        reason: 'Recent backups stay closer together than old ones');
  });

  test('automatic backups thin as they age', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1000 * 86400 * 1000, isUtc: true);
    // Every three days for two years.
    final items = [for (var day = 270; day <= 1000; day += 3) item('a$day', BackupKind.periodic, day: day, mb: 1)];
    final thinned = BackupRetention.thinned(items, now: now).toSet();
    final remaining = items.where((value) => !thinned.contains(value.name)).toList();
    final kept = [for (final value in remaining) 1000 - value.date.millisecondsSinceEpoch ~/ (86400 * 1000)];
    expect(kept.where((age) => age < 14).length, 5, reason: 'Two weeks of backups are all kept');
    expect(kept.where((age) => age >= 14 && age < 84).length, inInclusiveRange(5, 6), reason: 'Then about one in two weeks');
    expect(kept.where((age) => age >= 84 && age < 364).length, inInclusiveRange(5, 7), reason: 'Then about one in eight weeks');
    expect(kept.where((age) => age >= 364).length, lessThanOrEqualTo(3), reason: 'Then about one in 24 weeks');
    expect(kept.reduce((a, b) => a > b ? a : b), 730, reason: 'The oldest backup stays');
    // A day later only backups crossing into an older tier may go: windows are fixed in time.
    expect(BackupRetention.thinned(remaining, now: now.add(const Duration(days: 1))).length, lessThanOrEqualTo(3));
    final other = [item('u', BackupKind.patch, day: 300, mb: 1), item('v', BackupKind.patch, day: 301, mb: 1), item('m', BackupKind.manual, day: 302, mb: 1)];
    expect(BackupRetention.thinned([...items, ...other], now: now).every((name) => name.startsWith('a')), isTrue, reason: 'Only automatic backups are thinned');
  });

  test('retention never deletes the backup just made', () {
    final items = [item('old', BackupKind.manual, day: 1, mb: 150), item('new', BackupKind.manual, day: 0, mb: 50)];
    expect(BackupRetention.expired(items, keeping: {'old'}), ['new']);
    expect(BackupRetention.expired([item('only', BackupKind.manual, day: 1, mb: 150)], keeping: {'only'}), isEmpty);
  });

  // MARK: Preferences

  test('every preference type survives the entry, and the kept keys are kept in both forms', () {
    final values = <String, Object>{
      'flag': true,
      'count': 9007199254740993,
      'ratio': 0.1,
      'whole': 2.0,
      'text': 'hello "there"',
      'list': ['a', 'b', ''],
      'booru.suite.reader.page': 4,
    };
    final decoded = BackupPreferences.decode(BackupPreferences.encode(values))!;
    expect(decoded.keys.toSet(), values.keys.toSet());
    for (final MapEntry(:key, :value) in values.entries) {
      expect(BackupPreferences.same(decoded[key], value), isTrue, reason: key);
    }
    expect(decoded['whole'], isA<double>(), reason: 'A whole double does not come back as an int');
    expect(BackupPreferences.decode(utf8.encode('{}')), isNull);

    for (final key in [
      'backup.lastRun.version',
      'privacy.incognito',
      'icloud.installation',
      'icloud.librarySyncEnabled',
      'icloud.offReminderShown',
      'drive.librarySyncEnabled',
    ]) {
      expect(UpdateBackup.isKept(key), isTrue, reason: key);
      expect(UpdateBackup.isKept('booru.suite.$key'), isTrue, reason: 'image mode form of $key');
    }
    for (final key in ['app_theme', 'booru.safeMode', 'booru.suite.app_theme', 'manga.favoriteSync', 'reader_page_1']) {
      expect(UpdateBackup.isKept(key), isFalse, reason: key);
    }
  });

  // MARK: Launch step

  test('a fresh install writes the marker and makes no backup', () async {
    final fixture = BackupFixture(addTearDown);
    final report = await UpdateBackup.runAtLaunch(fixture.setup);
    expect(report.staged, isNull);
    expect(report.failed, isNull);
    expect(fixture.store.values[UpdateBackup.lastVersionKey], '1.6.0');
    expect(fixture.store.values[UpdateBackup.lastBuildKey], '47');
    expect(UpdateBackup.stagedSnapshots(fixture.setup), isEmpty);
  });

  test('data without a marker makes a minor backup of unknown version', () async {
    final fixture = BackupFixture(addTearDown);
    fixture.makeLibrary([1]);
    fixture.store.values['app_theme'] = 'dark';
    fixture.write(utf8.encode('keys'), fixture.setup.files['files/gallery-keys']!.parent, 'gallery-keys.json');
    expect((await UpdateBackup.runAtLaunch(fixture.setup)).staged, BackupKind.minor);
    final staged = UpdateBackup.stagedSnapshots(fixture.setup).first;
    final packed = await UpdateBackup.pack(staged, setup: fixture.setup);
    expect(packed.manifest.dataVersion, isNull);
    expect(packed.manifest.dataBuild, isNull);
    expect(packed.manifest.kind, BackupKind.minor);
    expect(packed.manifest.appVersion, '1.6.0');
    expect(packed.manifest.platform, 'android');
    expect(packed.file.uri.pathSegments.last.substring(0, 21), 'tegnal_minor_0_0_2026');
    final names = packed.manifest.entries.map((entry) => entry.name).toSet();
    expect(names, containsAll(['db/memo.sqlite', 'db/booru.sqlite', 'prefs/store.json', 'files/gallery-keys']));
    expect(UpdateBackup.stagedSnapshots(fixture.setup), isEmpty, reason: 'Packing empties the staging folder');
    expect((await UpdateBackup.runAtLaunch(fixture.setup)).staged, isNull, reason: 'The same version makes no backup');
  });

  test('version changes pick the backup kind', () async {
    final cases = <(String, String, String, String, BackupKind?)>[
      ('1.6.0', '47', '1.6.0', '47', null),
      ('1.6.0', '47', '1.6.1', '48', BackupKind.patch),
      ('1.6.3', '50', '1.7.0', '51', BackupKind.minor),
      ('1.6.0', '47', '1.6.0', '48', BackupKind.patch),
      ('1.9.2', '60', '2.0', '61', BackupKind.minor),
    ];
    for (final (fromVersion, fromBuild, version, build, kind) in cases) {
      final fixture = BackupFixture(addTearDown, version: version, build: build);
      fixture.makeLibrary([1]);
      fixture.store.values[UpdateBackup.lastVersionKey] = fromVersion;
      fixture.store.values[UpdateBackup.lastBuildKey] = fromBuild;
      expect((await UpdateBackup.runAtLaunch(fixture.setup)).staged, kind, reason: '$fromVersion ($fromBuild) -> $version ($build)');
      if (kind != null) {
        final packed = await UpdateBackup.pack(UpdateBackup.stagedSnapshots(fixture.setup).first, setup: fixture.setup);
        expect(packed.manifest.kind, kind);
        expect(packed.manifest.dataVersion, fromVersion);
        expect(packed.manifest.dataBuild, fromBuild);
      }
    }
  });

  test('a failed snapshot still writes the marker and records the failure', () async {
    final fixture = BackupFixture(addTearDown);
    fixture.makeLibrary([1]);
    fixture.store.values[UpdateBackup.lastVersionKey] = '1.5.1';
    fixture.setup.root.createSync(recursive: true);
    File(fixture.setup.staging.path).writeAsBytesSync(const []); // a file where the staging folder belongs
    final report = await UpdateBackup.runAtLaunch(fixture.setup);
    expect(report.failed, BackupKind.minor);
    expect(report.staged, isNull);
    expect(fixture.store.values[UpdateBackup.lastVersionKey], '1.6.0');
    expect((await UpdateBackup.lastFailure(fixture.setup))?.appVersion, '1.6.0');
    expect((await UpdateBackup.runAtLaunch(fixture.setup)).failed, isNull, reason: "The next launch does not label migrated data as the old version's");
  });

  test('the launch step does nothing under flutter test unless asked, and never throws', () async {
    final fixture = BackupFixture(addTearDown);
    fixture.makeLibrary([1]);
    final support = fixture.setup.dataFolder;
    expect(await UpdateBackup.launch(support: support, version: '1.6.0', build: '47', deviceName: 'x', preferences: fixture.store), isNull);
    expect(fixture.store.values, isEmpty, reason: 'No marker was written');
    final forced = await UpdateBackup.launch(support: support, version: '1.6.0', build: '47', deviceName: 'x', preferences: fixture.store, force: true);
    expect(forced?.report.staged, BackupKind.minor);
    expect(forced?.setup.root.path, '${support.path}/Backups');
    expect(forced?.setup.files['files/gallery-keys']?.path, '${support.path}/gallery-keys.json');
    expect(fixture.store.values[UpdateBackup.deviceIDKey], isA<String>());
    // Without a version it does nothing at all; a store that throws is not a crash.
    expect(await UpdateBackup.launch(support: support, version: '', build: '', deviceName: 'x', preferences: MemoryBackupStore(), force: true), isNull);
    expect(await UpdateBackup.launch(support: support, version: '1.7.0', build: '1', deviceName: 'x', preferences: _BrokenStore(), force: true), isNull);
  });

  test('the snapshot is taken before migration', () async {
    final fixture = BackupFixture(addTearDown);
    final path = fixture.memoPath;
    final old = SqlDatabase.open(path);
    AppDatabase.migrator.migrate(old, upTo: 'v15_work_page_count');
    old.close();
    // The old library's image database; a backup holds both.
    BooruStore(path: fixture.booruPath, preferences: AppPreferences.memory()).database.close();
    fixture.store.values[UpdateBackup.lastVersionKey] = '1.5.1';
    fixture.store.values[UpdateBackup.lastBuildKey] = '44';
    expect((await UpdateBackup.runAtLaunch(fixture.setup)).staged, BackupKind.minor);
    // The new version then opens and migrates the data.
    final opened = AppDatabase.open(path: path, preferences: AppPreferences.memory());
    expect(_migrations(opened.dbWriter), contains('v16_vivid_folder_colors'));
    opened.dbWriter.close();

    final packed = await UpdateBackup.pack(UpdateBackup.stagedSnapshots(fixture.setup).first, setup: fixture.setup);
    expect(packed.manifest.dataVersion, '1.5.1');
    // The backup itself holds the file as the old version left it.
    final unpacked = fixture.scratch('unpacked');
    await BackupArchive.open(packed.file).extract(unpacked);
    final inBackup = SqlDatabase.open('${unpacked.path}/db/memo.sqlite');
    final backedUp = _migrations(inBackup);
    inBackup.close();
    expect(backedUp, contains('v15_work_page_count'));
    expect(backedUp, isNot(contains('v16_vivid_folder_colors')), reason: 'The snapshot was taken before the new version migrated');
    final prepared = await UpdateBackup.prepareRestore(packed.file, setup: fixture.setup);
    await UpdateBackup.stageRestore(prepared.folder, manifest: prepared.manifest, setup: fixture.setup);
    expect((await UpdateBackup.runAtLaunch(fixture.setup)).restored, isTrue);
    final restored = SqlDatabase.open(path);
    final applied = _migrations(restored);
    restored.close();
    expect(applied, contains('v15_work_page_count'));
    // The restored library is checked by opening it the way the app does, so the current migrations have run on it.
    expect(applied, contains('v16_vivid_folder_colors'));
  });

  // MARK: Restore

  test('restore replaces data, keeps the kept keys and writes only missing files', () async {
    final fixture = BackupFixture(addTearDown);
    final store = fixture.store.values;
    store['app_theme'] = 'light';
    store['booru.suite.booru.layout'] = 'grid';
    store['privacy.incognito'] = 1;
    store['booru.suite.privacy.secret'] = 'before-prefixed';
    store['icloud.installation'] = 'before';
    store['drive.librarySyncEnabled'] = true;
    store['icloud.offReminderShown'] = 'before';
    fixture.write(utf8.encode('keys at backup'), fixture.setup.files['files/gallery-keys']!.parent, 'gallery-keys.json');
    fixture.write(utf8.encode('downloads at backup'), fixture.setup.files['files/downloads.json']!.parent, 'downloads.json');
    final File backup;
    {
      final library = fixture.openLibrary();
      final folder = library.$1.createFolder(name: 'Kept');
      library.$1.upsertWork(galleryId: 1, folderId: folder.id, title: 'One');
      backup = await fixture.manualBackup(library);
      // Changes made after the backup.
      library.$1.upsertWork(galleryId: 2, title: 'Two');
      library.$1.renameFolder(folder.id!, 'Renamed');
      fixture.closeLibrary(library);
    }
    store['app_theme'] = 'dark';
    store['booru.suite.booru.layout'] = 'list';
    store['manga.defaultTags'] = 'added later';
    store['privacy.incognito'] = 2;
    store['booru.suite.privacy.secret'] = 'after-prefixed';
    store['icloud.installation'] = 'after';
    store['icloud.offReminderShown'] = 'after';
    fixture.write(utf8.encode('keys now'), fixture.setup.files['files/gallery-keys']!.parent, 'gallery-keys.json');
    fixture.setup.files['files/downloads.json']!.deleteSync();

    final prepared = await UpdateBackup.prepareRestore(backup, setup: fixture.setup);
    await UpdateBackup.stageRestore(prepared.folder, manifest: prepared.manifest, setup: fixture.setup);
    expect(UpdateBackup.pendingRestore(fixture.setup), isNotNull);
    expect((await UpdateBackup.runAtLaunch(fixture.setup)).restored, isTrue);
    expect(UpdateBackup.pendingRestore(fixture.setup), isNull);
    expect((await UpdateBackup.lastRestore(fixture.setup))?.succeeded, isTrue);

    final library = fixture.openLibrary();
    expect(library.$1.getWork(1), isNotNull);
    expect(library.$1.getWork(2), isNull, reason: 'A work added after the backup is gone');
    expect(library.$1.listFolders().any((folder) => folder.name == 'Kept'), isTrue);
    expect(library.$1.listFolders().any((folder) => folder.name == 'Renamed'), isFalse, reason: 'The folder change is undone');
    fixture.closeLibrary(library);
    expect(store['app_theme'], 'light');
    expect(store['booru.suite.booru.layout'], 'grid', reason: "Image mode's own keys are restored too");
    expect(store.containsKey('manga.defaultTags'), isFalse, reason: 'A key added after the backup goes');
    expect(store['privacy.incognito'], 2, reason: 'Kept keys are not rolled back');
    expect(store['booru.suite.privacy.secret'], 'after-prefixed', reason: 'Kept keys keep in the image mode form too');
    expect(store['icloud.installation'], 'after');
    expect(store['drive.librarySyncEnabled'], true);
    expect(store['icloud.offReminderShown'], 'after');
    expect(store[UpdateBackup.lastVersionKey], '1.6.0');
    expect(store[UpdateBackup.libraryReplacedKey], isA<double>());
    expect(fixture.setup.files['files/gallery-keys']!.readAsStringSync(), 'keys now', reason: 'An existing file stays');
    expect(fixture.setup.files['files/downloads.json']!.readAsStringSync(), 'downloads at backup', reason: 'A missing file is written');
  });

  test('a corrupt database in a backup rolls back and leaves the data unchanged', () async {
    final fixture = BackupFixture(addTearDown);
    fixture.makeLibrary([7]);
    fixture.store.values[UpdateBackup.lastVersionKey] = '1.6.0';
    fixture.store.values[UpdateBackup.lastBuildKey] = '47';
    fixture.store.values['app_theme'] = 'current';
    final before = File(fixture.memoPath).readAsBytesSync();
    // A backup whose checksums are right but whose database is not a database.
    final folder = fixture.scratch('Restore/incoming-test');
    fixture.write(Uint8List.fromList(List.filled(8192, 0x42)), folder, 'db/memo.sqlite');
    fixture.write(BackupPreferences.encode({'app_theme': 'restored'}), folder, BackupEntry.preferences);
    await UpdateBackup.stageRestore(folder, manifest: sampleManifest(), setup: fixture.setup);

    expect((await UpdateBackup.runAtLaunch(fixture.setup)).restored, isFalse);
    expect(File(fixture.memoPath).readAsBytesSync(), before);
    expect(File(fixture.booruPath).existsSync(), isTrue);
    expect(fixture.store.values['app_theme'], 'current');
    expect(UpdateBackup.pendingRestore(fixture.setup), isNull, reason: 'A failed restore is not tried again on every launch');
    expect((await UpdateBackup.lastRestore(fixture.setup))?.succeeded, isFalse);
    expect(await UpdateBackup.lastFailure(fixture.setup), isNull, reason: 'A failed restore is one notice: the restore report');
    expect((await UpdateBackup.lastRestore(fixture.setup))?.message, isNotEmpty);
    expect(fixture.store.values.containsKey(UpdateBackup.libraryReplacedKey), isFalse);
    final library = fixture.openLibrary();
    expect(library.$1.getWork(7), isNotNull);
    fixture.closeLibrary(library);
  });

  test('a restore whose preferences cannot be written puts the databases back too', () async {
    final fixture = BackupFixture(addTearDown);
    fixture.makeLibrary([7]);
    fixture.store.values[UpdateBackup.lastVersionKey] = '1.6.0';
    fixture.store.values[UpdateBackup.lastBuildKey] = '47';
    final library = fixture.openLibrary();
    final backup = await fixture.manualBackup(library);
    library.$1.upsertWork(galleryId: 8, title: 'After the backup');
    fixture.closeLibrary(library);
    final before = File(fixture.memoPath).readAsBytesSync();
    final prepared = await UpdateBackup.prepareRestore(backup, setup: fixture.setup);
    await UpdateBackup.stageRestore(prepared.folder, manifest: prepared.manifest, setup: fixture.setup);
    final failing = BackupSetup(
      dataFolder: fixture.setup.dataFolder,
      root: fixture.setup.root,
      files: fixture.setup.files,
      preferences: _FailingReplace(fixture.store),
      appVersion: '1.6.0',
      appBuild: '47',
      device: fixture.setup.device,
    );
    expect((await UpdateBackup.runAtLaunch(failing)).restored, isFalse);
    expect(File(fixture.memoPath).readAsBytesSync(), before, reason: 'The restore is all or nothing');
  });

  test('a restore keeps this device\'s taste device id in the restored databases', () async {
    final fixture = BackupFixture(addTearDown);
    final library = fixture.openLibrary();
    final backup = await fixture.manualBackup(library);
    Uint8List device(SqlDatabase db) => db.value<Uint8List>("SELECT value FROM taste_meta WHERE key = 'device'")!;
    final backedUp = device(library.$1.dbWriter);
    // This device's id differs from the one in the backup, as when the backup came from another device.
    library.$1.dbWriter.write((db) => db.execute("UPDATE taste_meta SET value = ? WHERE key = 'device'", [utf8.encode('this-device')]));
    library.$2.database.write((db) => db.execute("UPDATE taste_meta SET value = ? WHERE key = 'device'", [utf8.encode('this-device')]));
    fixture.closeLibrary(library);
    expect(backedUp, isNot(utf8.encode('this-device')));

    expect((await fixture.restore(backup)).restored, isTrue);
    for (final path in [fixture.memoPath, fixture.booruPath]) {
      final restored = SqlDatabase.open(path);
      expect(utf8.decode(device(restored)), 'this-device', reason: path);
      restored.close();
    }
  });

  test('a restore makes every favorites sync ask again and keeps declined accounts declined', () async {
    final fixture = BackupFixture(addTearDown);
    final sites = SiteFavoriteFolders(fixture.defaults);
    final servers = SiteFavoriteFolders(fixture.images, statesKey: SiteFavoriteKeys.booruStates, declinedKey: SiteFavoriteKeys.booruDeclined);
    sites.setState(SiteFavoriteState(), 'synced.example');
    sites.remove('declined-then.example', declined: true);
    servers.setState(SiteFavoriteState(), 'server-a');
    servers.remove('server-declined-then', declined: true);
    final File backup;
    {
      final library = fixture.openLibrary();
      backup = await fixture.manualBackup(library);
      fixture.closeLibrary(library);
    }
    sites.remove('declined-now.example', declined: true);
    sites.setState(SiteFavoriteState(), 'declined-then.example');
    expect(sites.isDeclined('declined-then.example'), isFalse);
    expect(sites.asksAgain('synced.example'), isFalse);

    expect((await fixture.restore(backup)).restored, isTrue);

    expect(sites.syncedSites, isEmpty, reason: 'No website syncs until the first-sync choice is answered again');
    expect(sites.state('synced.example'), isNull);
    expect(sites.isDeclined('declined-then.example'), isTrue);
    expect(sites.isDeclined('declined-now.example'), isTrue);
    expect(sites.isDeclined('synced.example'), isFalse);
    expect(sites.asksAgain('synced.example'), isTrue, reason: 'Even a website without favorites is asked');
    expect(sites.asksAgain('declined-then.example'), isFalse, reason: 'A declined account is not asked');
    expect(sites.asksAgain('new.example'), isFalse, reason: 'An account that did not exist at the restore is set up as usual');
    expect(servers.syncedSites, isEmpty);
    expect(servers.isDeclined('server-declined-then'), isTrue);
    expect(servers.isDeclined('server-a'), isFalse);
    expect(servers.asksAgain('server-a'), isTrue);

    // The flag lasts for each account until its state is set or it is declined.
    sites.setState(SiteFavoriteState(), 'synced.example');
    expect(sites.asksAgain('synced.example'), isFalse);
    expect(fixture.store.values.containsKey(SiteFavoriteKeys.manga.asksAgain), isFalse, reason: 'No account left to ask: the flag is gone');
    expect(servers.asksAgain('server-a'), isTrue, reason: "Another mode's accounts are not affected");
    servers.remove('server-a', declined: true);
    expect(servers.asksAgain('server-a'), isFalse);
    expect(fixture.store.values.containsKey('booru.suite.${SiteFavoriteKeys.booru.asksAgain}'), isFalse);
  });

  test('a backup without preferences still makes the favorites ask again', () async {
    final fixture = BackupFixture(addTearDown);
    final sites = SiteFavoriteFolders(fixture.defaults);
    sites.setState(SiteFavoriteState(), 'synced.example');
    fixture.makeLibrary([1]);
    final folder = fixture.scratch('Restore/incoming-test');
    File(fixture.memoPath).copySync('${fixture.scratch('Restore/incoming-test/db').path}/memo.sqlite');
    await UpdateBackup.stageRestore(folder, manifest: sampleManifest(), setup: fixture.setup);
    fixture.store.values[UpdateBackup.lastVersionKey] = '1.6.0';
    fixture.store.values[UpdateBackup.lastBuildKey] = '47';
    expect((await UpdateBackup.runAtLaunch(fixture.setup)).restored, isTrue);
    expect(sites.syncedSites, isEmpty);
    expect(sites.asksAgain('synced.example'), isTrue);
  });

  test('library sync sends the restored library as the newest state', () async {
    final fixture = BackupFixture(addTearDown);
    var local = LibrarySyncLedger();
    final peerPreferences = AppPreferences.memory();
    final peer = LibrarySyncAdapter(
      manga: AppDatabase.inMemory(preferences: peerPreferences),
      booru: BooruStore.inMemory(preferences: peerPreferences),
      mangaDefaults: peerPreferences.defaults,
      booruDefaults: peerPreferences.booruDefaults,
    );
    final peerLedger = LibrarySyncLedger();
    final File backup;
    {
      final library = fixture.openLibrary();
      final adapter = LibrarySyncAdapter(manga: library.$1, booru: library.$2, mangaDefaults: fixture.defaults, booruDefaults: fixture.images);
      library.$1.upsertWork(galleryId: 1, title: 'One');
      library.$1.upsertWork(galleryId: 2, title: 'Two');
      backup = await fixture.manualBackup(library);
      library.$1.upsertWork(galleryId: 3, title: 'Three');
      local.capture(adapter.snapshot(), device: 'local');
      peerLedger.merge(local.changes);
      peer.apply(peerLedger.changes);
      peerLedger.baseline = peer.snapshot();
      fixture.closeLibrary(library);
    }
    // The other device edits a work the restore brings back as it was, before the restore happens.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    peer.manga.upsertWork(galleryId: 2, title: 'Edited elsewhere', overwriteMetadata: true);
    peerLedger.capture(peer.snapshot(), device: 'peer');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    fixture.store.values[UpdateBackup.driveSyncEnabledKey] = true;
    expect((await fixture.restore(backup)).restored, isTrue);
    final replacedAt = (fixture.store.values[UpdateBackup.libraryReplacedKey] as num).toDouble();

    final library = fixture.openLibrary();
    final adapter = LibrarySyncAdapter(manga: library.$1, booru: library.$2, mangaDefaults: fixture.defaults, booruDefaults: fixture.images);
    local = local.copy()..captureReplacement(adapter.snapshot(), device: 'local', at: replacedAt);
    local.merge(peerLedger.changes);
    LibrarySyncChange work(int id) =>
        local.changes.values.firstWhere((change) => change.row.table == 'manga.works' && change.row.values['gallery_id'] == SyncValue.integer(id));
    expect(work(3).deleted, isTrue, reason: 'A work missing from the restored library is sent as a deletion');
    expect(work(2).row.values['title'], SyncValue.text('Two'), reason: 'The restored library wins over the cloud copy');
    adapter.apply(local.changes);
    expect(library.$1.getWork(3), isNull, reason: 'Nothing is downloaded back');
    expect(library.$1.getWork(2)?.title, 'Two');
    fixture.closeLibrary(library);

    peerLedger.merge(local.changes);
    peer.apply(peerLedger.changes);
    expect(peer.manga.getWork(3), isNull, reason: 'The other device follows the restore');
    expect(peer.manga.getWork(2)?.title, 'Two');
  });

  test('a restored work without its cover waits for the bulk fill guard', () async {
    final fixture = BackupFixture(addTearDown);
    final thumbs = fixture.scratch('thumbs');
    final library = fixture.openLibrary();
    final database = library.$1;
    for (var id = 1; id <= CoverFillGuard.quietLimit + 5; id++) {
      database.upsertWork(galleryId: id, title: 'Work', tags: 'tag:one');
      database.setThumb(id, 'ready', path: '/old/files/thumbs/native_$id.jpg');
    }
    expect(database.countPendingFill(), 0, reason: 'Restored rows still claim their covers');
    database.repairThumbnailReferences(thumbs);
    expect(database.countPendingFill(), CoverFillGuard.quietLimit + 5, reason: 'Each cover not on the device goes back to the queue');
    final outcome = CoverFillGuard.outcome(
      sites: ['keyed.example'],
      blocks: (_) => true,
      pending: database.countPendingFill,
      manual: false,
      defaults: MemoryPreferences(),
    );
    expect(outcome, CoverFillAsk(CoverFillGuard.quietLimit + 5, ['keyed.example']), reason: 'They are not read in bulk without asking');
    fixture.closeLibrary(library);
  });
}

Set<String> _migrations(SqlDatabase database) => database.column<String>('SELECT identifier FROM grdb_migrations').toSet();

class _BrokenStore implements BackupPreferenceStore {
  @override
  Future<Map<String, Object>> all() => throw StateError('store gone');
  @override
  Future<Object?> get(String key) => throw StateError('store gone');
  @override
  Future<void> set(String key, Object? value) => throw StateError('store gone');
  @override
  Future<void> replaceAll(Map<String, Object> values) => throw StateError('store gone');
}

/// A store that reads and sets keys but refuses to replace them as a whole.
class _FailingReplace extends MemoryBackupStore {
  _FailingReplace(MemoryBackupStore inner) : super(inner.values);
  bool failed = false;
  @override
  Future<void> replaceAll(Map<String, Object> next) {
    if (failed) return super.replaceAll(next);
    failed = true;
    throw StateError('store refuses');
  }
}
