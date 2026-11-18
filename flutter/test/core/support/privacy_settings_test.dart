import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/content/manga_urls.dart';
import 'package:tegnal/core/content/recent_works.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/storage/library_backup.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/support/privacy_settings.dart';
import 'package:tegnal/core/taste/taste_models.dart';
import 'package:tegnal/core/taste/taste_store.dart';
import 'package:tegnal/core/content/reading_queue.dart';
import 'package:tegnal/core/taste/taste_library.dart';

void main() {
  setUp(() => ContentPreferences.defaults = MemoryPreferences());

  test('incognito keeps browsing out of history and taste', () {
    final database = AppDatabase.inMemory();
    final images = BooruStore.inMemory();
    final covers = Directory.systemTemp.createTempSync('tegnal-recent-');
    addTearDown(() => covers.deleteSync(recursive: true));
    final recent = RecentWorks(MemoryPreferences(), covers: covers);
    final work = RecentWork(
      item: ReadingQueueItem.fromGallery(id: 7000001, title: 'Work'),
      openedAt: DateTime.now(),
    );

    PrivacySettings.setIncognito(true);
    expect(PrivacySettings.isIncognito, isTrue);
    expect(PrivacySettings.incognito.value, isTrue);
    database.recordSearch('tag:example');
    images.recordSearch('blue_sky', serverID: 'server');
    recent.opened(work);
    database.dbWriter.write((db) {
      TasteStore.record(TasteEventKind.open, database.comicItem(7000001, 'tag:example'), db);
      TasteStore.record(TasteEventKind.search, database.comicItem(7000001, 'tag:example'), db);
    });
    expect(database.searchHistory(), isEmpty);
    expect(images.history('server'), isEmpty);
    expect(recent.entries, isEmpty);
    expect(database.tasteStore.events(), isEmpty);
    // A deliberate save still teaches taste.
    database.dbWriter.write((db) => TasteStore.record(TasteEventKind.save, database.comicItem(7000001, 'tag:example'), db));
    expect([for (final event in database.tasteStore.events()) event.kind], [TasteEventKind.save]);

    PrivacySettings.setIncognito(false);
    database.recordSearch('tag:example');
    recent.opened(work);
    expect(database.searchHistory(), ['tag:example']);
    expect([for (final entry in recent.entries) entry.id], [7000001]);
  });

  group('locked backups', () {
    test('open only with their password', () {
      final plain = utf8.encode('{"format":"tegnal-library"}');
      final locked = LockedBackup.lock(plain, 'correct horse', iterations: 1000);
      expect(LockedBackup.isLocked(locked), isTrue);
      expect(LockedBackup.isLocked(plain), isFalse);
      expect(utf8.decode(locked).contains('tegnal-library'), isFalse);
      expect(LockedBackup.unlock(locked, 'correct horse'), plain);
      expect(() => LockedBackup.unlock(locked, 'wrong'), throwsA(LockedBackupError.wrongPassword));

      final file = File('${Directory.systemTemp.createTempSync('tegnal-locked-').path}/backup.json')..writeAsBytesSync(locked);
      addTearDown(() => file.parent.deleteSync(recursive: true));
      expect(() => LibraryBackupImport.read(file), throwsA(LockedBackupError.passwordRequired));
    });

    /// Made by the iPhone app's `LockedBackup.lock` with the password `tegnal-test` and 1,000 rounds.
    test('a backup locked on iPhone opens', () {
      expect(utf8.decode(LockedBackup.unlock(utf8.encode(_iosLocked), 'tegnal-test')), '{"format":"tegnal-library","from":"ios"}');
    });
  });

  group('encrypted DNS', () {
    test('questions follow RFC 8484', () {
      final question = base64Url.decode(base64Url.normalize(DnsOverHttps.query('www.example.com', 1)));
      expect(question.sublist(0, 12), [0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
      expect(question.sublist(12), [3, ...'www'.codeUnits, 7, ...'example'.codeUnits, 3, ...'com'.codeUnits, 0, 0, 1, 0, 1]);
    });

    test('answers give the first address of the asked type', () {
      final question = base64Url.decode(base64Url.normalize(DnsOverHttps.query('example.com', 1)));
      final response = Uint8List.fromList([
        0, 0, 0x81, 0x80, 0, 1, 0, 2, 0, 0, 0, 0, // header: response, no error, 1 question, 2 answers
        ...question.sublist(12),
        0xC0, 12, 0, 5, 0, 1, 0, 0, 0, 60, 0, 2, 0xC0, 12, // CNAME first, skipped
        0xC0, 12, 0, 1, 0, 1, 0, 0, 1, 44, 0, 4, 93, 184, 215, 14,
      ]);
      final answer = DnsOverHttps.parse(response, 1);
      expect(answer?.address.address, '93.184.215.14');
      expect(answer?.ttl, 300);
      expect(DnsOverHttps.parse(response, 28), isNull);
      final refused = Uint8List.fromList([...response])..[3] = 0x83;
      expect(DnsOverHttps.parse(refused, 1), isNull);
    });

    test('choices keep their stored names', () {
      ContentPreferences.defaults.set(PrivacySettings.encryptedDNSKey, 'quad9');
      expect(EncryptedDNS.current, EncryptedDNS.quad9);
      expect(EncryptedDNS.off.endpoint, isNull);
      for (final choice in EncryptedDNS.values.where((choice) => choice != EncryptedDNS.off)) {
        expect(choice.endpoint?.scheme, 'https');
      }
    });
  });

  test('system proxy skips excluded hosts', () {
    const proxy = SystemProxy(host: '10.0.0.2', port: 8080, exclusions: ['*.local', 'intranet.example']);
    expect(proxy.directive(Uri.parse('https://catalog.example/')), 'PROXY 10.0.0.2:8080');
    expect(proxy.directive(Uri.parse('https://nas.local/')), 'DIRECT');
    expect(proxy.directive(Uri.parse('https://intranet.example/')), 'DIRECT');
  });
}

const _iosLocked = r'''
{
  "cipher" : "AES-256-GCM",
  "data" : "yfIEe9a+iUupueH7xU8R8msmudmX09PP2eQgujk3JE+HM26YYeGhSvaKgGqqZLpZ0UF9ntk+pE0=",
  "format" : "tegnal-locked-backup",
  "iterations" : 1000,
  "kdf" : "PBKDF2-SHA256",
  "nonce" : "bFdOT8SCSUnChLpQ",
  "salt" : "E8BEjj3rO6lHX\/QV39pKqQ==",
  "version" : 1
}
''';
