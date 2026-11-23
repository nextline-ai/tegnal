// Ported from native-ios/TEGNALTests/LabTests.swift: the AI lab's script files, its rules for opening cards, and its money.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_backup.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/lab/lab_course.dart';
import 'package:tegnal/core/lab/lab_records.dart';
import 'package:tegnal/core/lab/lab_sheet.dart';
import 'package:tegnal/core/lab/lab_store.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/sync/library_sync_adapter.dart';
import 'package:tegnal/core/sync/library_sync_record.dart';

import '../../support/addon_market_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LabCourse course;

  setUpAll(() async {
    course = await LabCourse.loadBundled();
    await LabShop.loadBundled();
    await LabDiagnosis.loadBundled();
    await LabEdition.loadBundled();
  });

  LabStore store() =>
      LabStore(course: course, shop: LabShop.bundled, diagnosis: LabDiagnosis.bundled, records: LabMemoryRecords(), edition: LabEdition.bundled);

  // MARK: Script files

  test('the bundled course has fifteen episodes in four seasons and cycles five card colours', () {
    expect([for (final season in course.seasons) season.number], [1, 2, 3, 4]);
    expect([for (final episode in course.episodes) episode.id], [for (var n = 1; n <= 15; n++) 'ep${n.toString().padLeft(2, '0')}']);
    expect([for (final episode in course.episodes) episode.number], [for (var n = 1; n <= 15; n++) n]);
    expect(course.info.cardColors, ['1F4D3A', '2B2F77', '6B1F2A', '6E4A12', '0F4C5C'], reason: "The system sheet's card colours, without 먹");
    expect([for (final episode in course.episodes.take(6)) course.color(episode)], ['1F4D3A', '2B2F77', '6B1F2A', '6E4A12', '0F4C5C', '1F4D3A']);
  });

  test('the scripts are the same files the iOS app carries', () {
    final native = Directory('../native-ios/TEGNAL/AILab');
    if (!native.existsSync()) return;
    for (final file in native.listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.json'))) {
      final relative = file.path.substring(native.path.length + 1);
      final copy = File('assets/lab/$relative');
      expect(copy.existsSync(), isTrue, reason: 'assets/lab/$relative is missing');
      expect(copy.readAsStringSync(), file.readAsStringSync(), reason: 'assets/lab/$relative differs from the iOS script; copy it again');
    }
  });

  test('every episode has one right choice, traps with their 망작 and three uses', () {
    for (final episode in course.episodes) {
      expect(episode.choices.where((choice) => choice.isRight).length, 1, reason: episode.id);
      for (final choice in episode.choices.where((choice) => !choice.isRight)) {
        expect(choice.fail, isNotNull, reason: '${episode.id}: a trap needs its 망작');
      }
      expect(episode.disaster.verdict.isEmpty, isFalse, reason: episode.id);
      expect(episode.card.line.isEmpty, isFalse, reason: episode.id);
      expect(episode.card.uses.length, 3, reason: episode.id);
      expect(episode.impact, greaterThan(0));
      expect(episode.reward, greaterThan(0));
    }
    final ids = [for (final fail in course.fails) fail.id];
    expect(ids.toSet().length, ids.length, reason: 'Every 망작 has its own id');
  });

  test('impact goes down the deck and every card takes the rate to one hundred', () {
    final impacts = [for (final episode in course.episodes) episode.impact];
    expect(impacts, [...impacts]..sort((a, b) => b.compareTo(a)));
    expect(course.top, 100);
  });

  test('every tool can be passed with what its file gives it', () {
    for (final episode in course.episodes) {
      final tool = episode.tool;
      switch (tool.kind) {
        case LabToolKind.switches:
          final controls = tool.controls ?? const [];
          expect(controls, isNotEmpty, reason: episode.id);
          final passing = (tool.results ?? const []).where((result) => result.pass == true).length;
          expect(tool.compose != null || passing >= (tool.need ?? 1), isTrue, reason: '${episode.id}: not enough passing results');
          for (final result in tool.results ?? const <LabResult>[]) {
            expect(result.when.length, controls.length, reason: episode.id);
            for (final (index, value) in result.when.indexed) {
              if (value >= 0) expect(value, lessThan(controls[index].options.length), reason: episode.id);
            }
          }
          if (tool.compose != null) {
            expect(controls.every((control) => control.options.every((option) => option.line != null)), isTrue, reason: episode.id);
          }
        case LabToolKind.chips:
          final chips = tool.chips ?? const [];
          if (tool.mode == 'toggle') {
            expect(chips.where((chip) => chip.line != null).length, greaterThanOrEqualTo(tool.need ?? 1), reason: episode.id);
          } else {
            expect(chips.any((chip) => chip.pass == true), isTrue, reason: episode.id);
            expect(chips.every((chip) => (chip.replies ?? const []).isNotEmpty), isTrue, reason: episode.id);
          }
        case LabToolKind.stamps:
          expect(tool.stamps?.length, 2, reason: episode.id);
          expect((tool.items ?? const []).every((item) => item.answer >= 0 && item.answer < 2), isTrue, reason: episode.id);
        case LabToolKind.marks:
          expect((tool.pieces ?? const []).any((piece) => piece.isTarget), isTrue, reason: episode.id);
          expect(['cut', 'flag', 'mask'], contains(tool.style ?? 'cut'));
        case LabToolKind.equip:
          final gear = {for (final value in tool.gear ?? const <LabGear>[]) value.id};
          expect(tool.missions, isNotEmpty, reason: episode.id);
          for (final mission in tool.missions ?? const <LabMission>[]) {
            expect(gear.containsAll(mission.needs), isTrue, reason: episode.id);
          }
        case LabToolKind.rot:
          expect((tool.replies ?? const []).length, greaterThanOrEqualTo(tool.minRetries ?? 2), reason: episode.id);
          expect(tool.fresh, isNotNull, reason: episode.id);
      }
    }
  });

  test('text can be one string, lines or per language', () {
    expect(LabText.parse('한 줄').resolved('en'), '한 줄', reason: 'Plain text shows in every language until translated');
    expect(LabText.parse(['첫 줄', '둘째 줄']).resolved('ko'), '첫 줄\n둘째 줄');
    final both = LabText.parse({
      'ko': '안녕',
      'en': ['Hello', 'there'],
    });
    expect(both.resolved('en'), 'Hello\nthere');
    expect(both.resolved('ja'), '안녕');
    final options = [for (final value in jsonDecode('["짧게", {"label": "길게", "line": "한 줄 더"}]') as List) LabOption.parse(value)];
    expect([for (final option in options) option.label.resolved('ko')], ['짧게', '길게']);
    expect(options[1].line?.resolved('ko'), '한 줄 더');
  });

  // MARK: Opening cards

  test('cards open one at a time, in deck order, season after season', () {
    final lab = store();
    for (final episode in course.episodes) {
      expect([for (final card in lab.openCards) card.id], [episode.id]);
      expect(lab.next?.id, episode.id);
      lab.engrave(episode, failsHung: 0);
    }
    expect(lab.openCards, isEmpty);
    expect(lab.next, isNull);
  });

  test('the rate climbs by each card’s impact and playing again changes nothing', () {
    final lab = store(), first = course.episode('ep01')!;
    expect(lab.rate, course.base);
    final engraving = lab.engrave(first, failsHung: 2);
    expect(engraving.before, course.base);
    expect(engraving.after, course.base + first.impact);
    expect(engraving.cardReward, first.reward);
    expect(engraving.failReward, 2 * course.info.rewards.fail);
    final again = lab.engrave(first, failsHung: 0);
    expect(again.first, isFalse);
    expect(again.cardReward, 0);
    expect(again.after, engraving.after);
  });

  test('cheat-sheet sections open with cards 001 and 004 and an edition pays once', () {
    final lab = store();
    final edition = lab.edition!;
    expect([for (final section in edition.sections) ?section.opens], ['ep01', 'ep04']);
    expect(lab.editionWaiting, isFalse);
    expect(lab.read(), 0);
    lab.engrave(course.episode('ep01')!, failsHung: 0);
    expect(lab.editionWaiting, isTrue);
    expect(lab.read(), edition.reward ?? course.info.rewards.edition);
    expect(lab.editionWaiting, isFalse);
    expect(lab.read(), 0, reason: 'An edition pays once');
  });

  test('a downloaded edition must be signed', () {
    final key = TestSigningKey();
    final payload = utf8.encode(File('assets/lab/cheatsheet.json').readAsStringSync());
    List<int> envelope(List<int> bytes, List<int> signature) =>
        utf8.encode(jsonEncode({'payload': base64.encode(bytes), 'signature': base64.encode(signature)}));
    final signature = key.sign(payload);
    expect(LabSheetSource.open(envelope(payload, signature), key.public)?.id, LabEdition.bundled?.id);
    final changed = [...payload];
    changed[changed.length ~/ 2] ^= 0x01;
    expect(LabSheetSource.open(envelope(changed, signature), key.public), isNull, reason: 'Changed bytes are refused');
    expect(LabSheetSource.open(envelope(payload, signature), TestSigningKey().public), isNull, reason: 'Another key is refused');
  });

  // MARK: Money

  test('a 망작 pays once and the balance is income less purchases', () {
    final lab = store();
    expect(lab.hang(course.fails.first), isTrue);
    expect(lab.hang(course.fails.first), isFalse);
    expect(lab.balance, course.info.rewards.fail);
  });

  test('prices follow the agreed rules', () {
    final shop = LabShop.bundled;
    final seasonOne = course.seasons.first.episodes.map(course.episode).nonNulls.fold(0, (total, episode) => total + episode.reward);
    final cheapest = shop.items.where((item) => !item.isRepeat && !item.isSoon).map((item) => item.price).nonNulls.reduce((a, b) => a < b ? a : b);
    expect(seasonOne, greaterThanOrEqualTo(cheapest), reason: 'Season 1 pays for a first purchase');
    final cards = course.episodes.fold(0, (total, episode) => total + episode.reward);
    final share = cards / shop.permanentTotal;
    expect(share, inInclusiveRange(0.6, 0.7));
  });

  test('buying the 2D course, and its lessons paying afterwards', () {
    final lab = store();
    final item = lab.shop.item(LabStore.tagCourse)!;
    expect(lab.canBuy(item), LabBuyResult.shortBy(item.price!));
    for (final id in ['ep01', 'ep02', 'ep03', 'ep04']) {
      lab.engrave(course.episode(id)!, failsHung: 0);
    }
    lab.count(lessons: 5, of: LabStore.tagCourse);
    expect(lab.buy(item), LabBuyResult.bought);
    expect(lab.ownsTagCourse, isTrue);
    expect(lab.canBuy(item), LabBuyResult.owned);
    final after = lab.balance;
    lab.count(lessons: 8, of: LabStore.tagCourse);
    expect(lab.balance, after + 3 * course.info.rewards.courseLesson, reason: 'Only lessons finished after buying pay');
  });

  test('a learner who studied tags before keeps the course free', () {
    final lab = store()..grandfather(lessons: 12, xp: 300);
    expect(lab.ownsTagCourse, isTrue);
    expect(lab.spent, 0);
    final fresh = store()..grandfather(lessons: 0, xp: 0);
    expect(fresh.ownsTagCourse, isFalse);
  });

  test('items not on sale cannot be bought', () {
    final lab = store();
    expect(lab.canBuy(lab.shop.items.firstWhere((item) => item.isSoon)), LabBuyResult.unavailable);
  });

  // MARK: Diagnosis

  test('the diagnosis picks the type most answers point to', () {
    final diagnosis = LabDiagnosis.bundled!;
    expect(diagnosis.result([1, 1, 2, 1])?.id, diagnosis.fallback);
    expect(diagnosis.result([0, 1, 2, 1])?.id, 'default');
    expect(diagnosis.result([0, 0, 0, 0])?.id, 'role', reason: 'A tie goes to the type listed first');
    for (final type in diagnosis.types) {
      expect(type.episodes.every((id) => course.episode(id) != null), isTrue, reason: type.id);
    }
  });

  // MARK: Saving

  test('progress is saved in the image database and read back', () {
    final booru = BooruStore.inMemory();
    final first = LabStore(course: course, shop: LabShop.bundled, diagnosis: LabDiagnosis.bundled, records: LabDatabaseRecords(booru.database));
    first.engrave(course.episode('ep01')!, failsHung: 0);
    first.hang(course.fails.first);
    first.diagnose(first.diagnosis!.types.first);
    final second = LabStore(course: course, shop: LabShop.bundled, diagnosis: LabDiagnosis.bundled, records: LabDatabaseRecords(booru.database));
    expect(second.earned(course.episode('ep01')!), isTrue);
    expect(second.hung(course.fails.first), isTrue);
    expect(second.progress.type, first.progress.type);
    expect(second.progress, first.progress);
    expect(booru.database.read((db) => db.rows('SELECT COUNT(*) AS n FROM lab_records').first['n']), 4, reason: 'A card, a 망작, the type and the greeting');
  });

  test('synced lab records merge without losing anything', () {
    final preferences = AppPreferences.memory();
    final booru = BooruStore.inMemory(preferences: preferences);
    final records = LabDatabaseRecords(booru.database)
      ..replace(const [LabRecord(key: 'card:ep01', value: 1, at: 200), LabRecord(key: 'purchase:course.tags', value: 1, text: '{"price":600}', at: 300)]);
    final adapter = LibrarySyncAdapter(
      manga: AppDatabase.inMemory(preferences: preferences),
      booru: booru,
      mangaDefaults: preferences.defaults,
      booruDefaults: preferences.booruDefaults,
    );
    expect(adapter.snapshot().values.any((row) => row.table == 'booru.lab_records' && row.values['key']?.string == 'card:ep01'), isTrue);
    LibrarySyncChange change(Map<String, SyncValue> values) => LibrarySyncChange(
      row: LibrarySyncRow(table: 'booru.lab_records', values: values),
      timestamp: 1,
      device: 'other',
      deleted: false,
    );
    adapter.apply({
      'a': change({'key': const SyncValue.text('card:ep01'), 'value': const SyncValue.integer(1), 'text': SyncValue.null_, 'at': const SyncValue.real(100)}),
      'b': change({'key': const SyncValue.text('card:ep02'), 'value': const SyncValue.integer(1), 'text': SyncValue.null_, 'at': const SyncValue.real(400)}),
      'c': change({
        'key': const SyncValue.text('purchase:course.tags'),
        'value': const SyncValue.integer(0),
        'text': SyncValue.null_,
        'at': const SyncValue.real(500),
      }),
    });
    final merged = LabProgress.fromRecords(records.all());
    expect(merged.cards['ep01'], 100, reason: 'The earlier engraving time is kept');
    expect(merged.cards['ep02'], isNotNull, reason: 'A card engraved on the other device arrives');
    expect(merged.purchases['course.tags']?.count, 1, reason: 'A purchase is not undone by an older record');
    expect(merged.purchases['course.tags']?.price, 600);
  });

  test('lab records go into backups and come back', () {
    final source = BooruStore.inMemory();
    LabDatabaseRecords(source.database).replace(const [LabRecord(key: 'card:ep03', value: 1, at: 50)]);
    final backup = BooruBackup.decode(source.exportBackup().encoded());
    expect(backup.lab?.map((record) => record.key), ['card:ep03']);
    final target = BooruStore.inMemory()..restoreBackup(backup);
    expect(LabProgress.fromRecords(LabDatabaseRecords(target.database).all()).cards['ep03'], 50);
  });
}
