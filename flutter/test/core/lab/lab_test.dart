// Ported from native-ios/TEGNALTests/LabTests.swift: the AI lab's script files, its rules for opening cards, and its money.

import 'dart:convert';
import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/app/app_notice.dart';
import 'package:tegnal/core/addons/addon_market.dart';
import 'package:tegnal/core/lab/lab_goods.dart';
import 'package:tegnal/core/lab/lab_shop.dart';
import 'package:tegnal/core/booru/booru_backup.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/lab/lab_course.dart';
import 'package:tegnal/core/lab/lab_course_file.dart';
import 'package:tegnal/core/lab/lab_records.dart';
import 'package:tegnal/core/lab/lab_sheet.dart';
import 'package:tegnal/core/lab/lab_store.dart';
import 'package:tegnal/core/lab/learning_courses.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/study/study_models.dart';
import 'package:tegnal/core/study/study_path.dart';
import 'package:tegnal/core/study/study_store.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/sync/library_sync_adapter.dart';
import 'package:tegnal/core/sync/library_sync_record.dart';
import 'package:tegnal/presentation/lab/lab_pages.dart';

import '../../support/addon_market_fixtures.dart';
import '../../support/lab_shop_fixtures.dart';
import 'lab_course_file_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LabCourse course;

  setUpAll(() async {
    course = await LabCourse.loadBundled();
    // A tags lesson may teach the app's own tags, so course files are checked against the curriculum.
    StudyCurriculum.useBundled(StudyCurriculum.parse(File('assets/study/TagStudy.json').readAsStringSync()));
    await LabDiagnosis.loadBundled();
    await LabEdition.loadBundled();
  });

  LabStore store() =>
      LabStore(course: course, shop: testShop(), diagnosis: LabDiagnosis.bundled, records: LabMemoryRecords(), edition: LabEdition.bundled);

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

  test('the bundled course keeps the course rules', () {
    expect(course.problems(), isEmpty);
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

  StudyPath path() => StudyPath.parse(File('assets/study/StudyPath.json').readAsStringSync());

  // What every bundled course pays when finished; cheat-sheet editions are left out, as they keep coming.
  int labPayout() =>
      course.episodes.fold(0, (total, episode) => total + episode.reward) +
      course.fails.length * course.info.rewards.fail +
      course.seasons.length * course.info.rewards.season;
  int tagPayout() {
    final rates = course.info.rewards, lessons = path().sections.fold(0, (total, section) => total + section.lessons.length);
    return lessons * (rates.courseLesson + rates.courseStars) + path().sections.length * rates.courseSection;
  }

  test('prices follow the agreed rules', () {
    // The rules are checked on the list as published (`docs/live/shop.json`, local only).
    final shop = liveShop();
    if (shop == null) return markTestSkipped('docs/live/shop.json is local only');
    // Season 1's cards and its season pay for the first course, without a single 망작.
    final seasonOne =
        course.seasons.first.episodes.map(course.episode).nonNulls.fold(0, (total, episode) => total + episode.reward) + course.info.rewards.season;
    final course2D = shop.item(LabStore.tagCourse)!.price!;
    expect(seasonOne, greaterThanOrEqualTo(course2D), reason: 'Season 1 pays for 2D AI 배우기');
    // A bought course pays back several times its price.
    expect(tagPayout(), greaterThanOrEqualTo(4 * course2D));
    // Everything that lasts costs 50–70% of what all courses pay; the rest is left for tickets.
    expect(shop.permanentTotal / (labPayout() + tagPayout()), inInclusiveRange(0.5, 0.7));
    expect(labPayout(), lessThan(shop.permanentTotal), reason: 'The free course alone does not buy everything');
    // What the app sells offline costs what the published list asks.
    for (final item in LabShop.builtIn.items) {
      expect(item.price, shop.item(item.id)?.price, reason: "${item.id}: the app's offline price matches docs/live/shop.json");
      expect(item.supported, isTrue, reason: item.id);
    }
  });

  test("the app's own goods can be bought offline", () async {
    final lab = LabStore(course: course, diagnosis: LabDiagnosis.bundled, records: LabMemoryRecords());
    await lab.refreshShop(
      market: AddonMarket(base: AddonMarket.liveBase, publicKey: TestSigningKey().public, fetch: (url, limit) async => throw const AddonMarketError.offline()),
    );
    expect(lab.shopState, LabShopState.failed);
    for (final episode in course.episodes.take(4)) {
      lab.engrave(episode, failsHung: 0);
    }
    expect(lab.buy(lab.shop.item(LabStore.tagCourse)!), LabBuyResult.bought);
    for (final episode in course.episodes.skip(4).take(2)) {
      lab.engrave(episode, failsHung: 0);
    }
    expect(lab.buy(lab.shop.item(LabFeature.promptAnalyzer.item)!), LabBuyResult.bought);
    expect(lab.unlocked(LabFeature.promptAnalyzer), isTrue);
    expect(lab.progress.purchases[LabFeature.promptAnalyzer.item]?.price, 200);
  });

  test('amounts paid are kept when the files change later', () async {
    final records = LabMemoryRecords();
    final first = LabStore(course: course, shop: testShop(), diagnosis: LabDiagnosis.bundled, records: records);
    LabEngraving? last;
    for (final id in ['ep01', 'ep02', 'ep03', 'ep04']) {
      last = first.engrave(course.episode(id)!, failsHung: 0);
    }
    expect(last?.seasonReward, course.info.rewards.season, reason: 'The card that finishes a season pays for it');
    first.hang(course.fails.first);
    final balance = first.balance;
    expect(records.all().firstWhere((record) => record.key == 'card:ep01').value, course.episode('ep01')!.reward);

    // The same course with every amount changed.
    final cheaper = await LabCourse.load((path) async {
      final json = jsonDecode(File('assets/lab/$path').readAsStringSync()) as Map<String, Object?>;
      if (path == 'course.json') json['rewards'] = {'fail': 2, 'edition': 2, 'season': 2, 'courseLesson': 2};
      if (path.startsWith('episodes/')) json['reward'] = 3;
      return jsonEncode(json);
    });
    final later = LabStore(course: cheaper, shop: testShop(), diagnosis: LabDiagnosis.bundled, records: records);
    expect(later.balance, balance, reason: 'Nothing already earned moves');
    later.engrave(cheaper.episode('ep05')!, failsHung: 0);
    expect(later.balance, balance + 3, reason: 'What is earned from now on pays the new amount');
  });

  test('older records count at the present amount', () {
    final progress = LabProgress.fromRecords(const [LabRecord(key: 'card:ep01', value: 1, at: 10)]);
    expect(progress.cardGems['ep01'], isNull);
    final records = LabMemoryRecords()..replace(progress.records);
    final lab = LabStore(course: course, shop: testShop(), diagnosis: LabDiagnosis.bundled, records: records);
    expect(lab.balance, course.episode('ep01')!.reward);
  });

  test('season 1 buys the 2D course, and its tickets wait for it', () {
    final lab = store();
    final item = lab.shop.item(LabStore.tagCourse)!;
    expect(lab.canBuy(item), LabBuyResult.shortBy(item.price!));
    for (final id in ['ep01', 'ep02', 'ep03', 'ep04']) {
      lab.engrave(course.episode(id)!, failsHung: 0);
    }
    final listed = lab.shop.items.firstWhere((item) => item.kind == 'ticket');
    expect(listed.requires, LabStore.tagCourse);
    final tickets = listed.copyWith(soon: false);
    expect(lab.canBuy(tickets), const LabBuyResult.needs(LabStore.tagCourse), reason: 'Tickets are for the generator 2D AI 배우기 opens');
    expect(lab.buy(item), LabBuyResult.bought);
    expect(lab.ownsTagCourse, isTrue);
    expect(lab.canBuy(item), LabBuyResult.owned);
    expect(lab.canBuy(tickets), isNot(const LabBuyResult.needs(LabStore.tagCourse)));
  });

  test('2D lessons, three stars and sections pay once', () {
    final booru = BooruStore.inMemory();
    final lab = store();
    final rates = course.info.rewards, section = path().sections.first;
    final ids = [for (final lesson in section.lessons) lesson.id];
    booru.studyStore.earn(10, lesson: ids.first, stars: 2);
    expect(lab.settleTagCourse(booru.studyStore, path: path()).total, rates.courseLesson);
    booru.studyStore.earn(10, lesson: ids.first, stars: 2);
    expect(lab.settleTagCourse(booru.studyStore, path: path()).total, 0, reason: 'Playing a lesson again pays nothing');
    booru.studyStore.earn(10, lesson: ids.first, stars: 3);
    expect(lab.settleTagCourse(booru.studyStore, path: path()).total, rates.courseStars, reason: 'Three stars pay once');
    for (final id in ids.skip(1)) {
      booru.studyStore.earn(10, lesson: id, stars: 1);
    }
    expect(lab.settleTagCourse(booru.studyStore, path: path()), LabTagPayout(lesson: (ids.length - 1) * rates.courseLesson, section: rates.courseSection));
    booru.studyStore.earn(10, lesson: 'course:other:one', stars: 3);
    expect(lab.settleTagCourse(booru.studyStore, path: path()).total, 0, reason: "An imported course's lesson pays nothing");
    final balance = lab.balance;
    booru.studyStore.reset();
    expect(lab.settleTagCourse(booru.studyStore, path: path()).total, 0);
    expect(lab.balance, balance, reason: 'Resetting the course takes nothing back');
  });

  test('a finished 2D course starts over and pays a quarter', () {
    final booru = BooruStore.inMemory();
    final records = LabMemoryRecords();
    final lab = LabStore(course: course, shop: testShop(), diagnosis: LabDiagnosis.bundled, records: records);
    final rates = course.info.rewards, lessons = path().lessons;
    booru.studyStore.earn(10, lesson: lessons.first.id, stars: 3);
    lab.startTagCourseOver(booru.studyStore, path: path());
    expect(lab.tagRound, 0, reason: 'Only a finished course starts over');
    for (final lesson in lessons) {
      booru.studyStore.earn(10, lesson: lesson.id, stars: 3);
    }
    lab.settleTagCourse(booru.studyStore, path: path());
    expect(LabStore.tagCourseFinished(booru.studyStore.lessons(), path: path()), isTrue);
    final balance = lab.balance;
    lab.startTagCourseOver(booru.studyStore, path: path());
    expect(lab.tagRound, 1);
    expect(booru.studyStore.lessons(round: 1), isEmpty, reason: 'The path starts again');
    expect(booru.studyStore.lessons().length, lessons.length, reason: 'The first round stays in the records');
    expect(lab.balance, balance, reason: 'What was earned stays');

    booru.studyStore.earn(10, lesson: lessons.first.id, stars: 3, round: lab.tagRound);
    booru.studyStore.earn(10, lesson: 'course:other:one', stars: 3, round: lab.tagRound);
    expect(booru.studyStore.lessons(round: 1)['course:other:one'], isNotNull, reason: "An imported course's lessons have no rounds");
    expect(
      lab.settleTagCourse(booru.studyStore, path: path()),
      LabTagPayout(lesson: LabStore.share(rates.courseLesson, 1), stars: LabStore.share(rates.courseStars, 1)),
    );
    expect(lab.settleTagCourse(booru.studyStore, path: path()).total, 0, reason: 'Each round pays once');
    expect(lab.tagCoursePaid.lessons, lessons.length, reason: "The kept-lessons count is the first round's");

    final synced = LabStore(course: course, shop: testShop(), diagnosis: LabDiagnosis.bundled, records: records);
    expect(synced.tagRound, 1);
    expect(synced.balance, lab.balance);
  });

  test('progress from before the course was sold pays but does not open it', () {
    final booru = BooruStore.inMemory();
    final lab = store();
    expect(lab.owesLegacyNotice, isFalse, reason: 'Nothing to tell someone who never studied it');
    for (final lesson in path().sections.expand((section) => section.lessons).take(6)) {
      booru.studyStore.earn(10, lesson: lesson.id, stars: 3);
    }
    expect(lab.settleTagCourse(booru.studyStore, path: path()).total, greaterThan(0));
    expect(lab.ownsTagCourse, isFalse);
    expect(lab.tagCoursePaid.lessons, 6);
    expect(lab.owesLegacyNotice, isTrue);
    lab.noticeLegacy();
    expect(lab.owesLegacyNotice, isFalse);
    expect(lab.spent, 0);
  });

  test('items not on sale cannot be bought', () {
    final lab = store();
    expect(lab.canBuy(lab.shop.items.firstWhere((item) => item.isSoon)), LabBuyResult.unavailable);
  });

  // MARK: The shop from the server

  test('the shop list is read only when TEGNAL signed it', () {
    final key = TestSigningKey(), other = TestSigningKey();
    final (shop, payload) = LabShopSource.open(signedShop(fixtureShopJson, key), key.public);
    expect([for (final item in shop.items) item.id], ['course.tags', 'feature.prompt-analyzer', 'tickets.10']);
    expect(payload, utf8.encode(fixtureShopJson), reason: "What is kept is the list's own bytes");
    expect(() => LabShopSource.open(signedShop(fixtureShopJson, other), key.public), throwsA(LabShopError.unsigned));
    final newer = fixtureShopJson.replaceFirst('"schemaVersion": 1', '"schemaVersion": 2');
    expect(() => LabShopSource.open(signedShop(newer, key), key.public), throwsA(LabShopError.newer), reason: 'A list for a later app asks for an update');
    expect(() => LabShop.decode(utf8.encode('{"format": "tegnal-addon-catalog", "schemaVersion": 1}')), throwsA(LabShopError.invalid));
  });

  test('the store shows the list it read and keeps it when the server fails', () async {
    final key = TestSigningKey();
    final lab = LabStore(course: course, diagnosis: LabDiagnosis.bundled, records: LabMemoryRecords());
    expect(lab.shopState, LabShopState.loading);
    expect([for (final item in lab.shop.items) item.id], ['course.tags', 'feature.prompt-analyzer'], reason: 'Before the list is read, only the goods the app carries');
    var file = signedShop(fixtureShopJson, key);
    Object? failure;
    final market = AddonMarket(
      base: AddonMarket.liveBase,
      publicKey: key.public,
      fetch: (url, limit) async {
        if (failure case final failure?) throw failure;
        return file;
      },
    );
    await lab.refreshShop(market: market);
    expect(lab.shopState, LabShopState.ready);
    expect(lab.shop.item('feature.prompt-analyzer'), isNotNull);
    failure = const AddonMarketError.offline();
    await lab.refreshShop(market: market);
    expect(lab.shopState, LabShopState.ready, reason: 'A list already read stays when the server cannot be reached');
    expect(lab.shop.item('course.tags'), isNotNull);
    failure = null;
    file = signedShop(fixtureShopJson.replaceFirst('"schemaVersion": 1', '"schemaVersion": 2'), key);
    await lab.refreshShop(market: market);
    expect(lab.shopState, LabShopState.newer);
    expect(
      [for (final item in lab.shop.items) item.id],
      [for (final item in LabShop.builtIn.items) item.id],
      reason: "An old list is not sold from once a newer one is out; the app's own goods are",
    );
  });

  test('goods this app does not know ask for an update', () {
    const json = '''
      {"format": "tegnal-lab-shop", "schemaVersion": 1, "currency": "보석", "sections": [{"title": "새 상품", "items": [
        {"id": "sticker.cat", "kind": "sticker", "name": "고양이 스티커", "price": 10, "sticker": {"shape": "round"}},
        {"id": "feature.prompt-analyzer", "kind": "feature", "version": 2, "feature": "prompt-analyzer", "name": "새 분석기", "price": 10},
        {"id": "feature.voice", "kind": "feature", "feature": "voice", "name": "음성", "price": 10},
        {"id": "feature.other", "kind": "feature", "feature": "prompt-analyzer", "name": "다른 ID", "price": 10},
        {"id": "home.broken", "kind": "home", "name": "파일 없는 홈", "price": 10},
        {"id": "BAD ID", "kind": "feature", "name": "모양이 틀림"},
        {"id": "tickets.5", "kind": "ticket", "count": 5, "name": "생성권", "price": 10, "repeat": true}
      ]}]}''';
    final shop = LabShop.decode(utf8.encode(json));
    expect(
      [for (final item in shop.items) item.id],
      ['sticker.cat', 'feature.prompt-analyzer', 'feature.voice', 'feature.other', 'home.broken', 'tickets.5'],
      reason: 'An item not shaped like one is left out; the others stay',
    );
    final lab = LabStore(course: course, shop: shop, diagnosis: LabDiagnosis.bundled, records: LabMemoryRecords());
    for (final id in ['sticker.cat', 'feature.prompt-analyzer', 'feature.voice', 'feature.other', 'home.broken']) {
      expect(shop.item(id)!.supported, isFalse, reason: id);
      expect(lab.canBuy(shop.item(id)!), LabBuyResult.update, reason: id);
    }
    expect(shop.item('tickets.5')!.supported, isTrue);
  });

  test('what docs/live/publish_live.py signs opens with the key the app carries', () {
    final shop = File('../docs/live/dist/v1/lab/shop.json');
    if (!shop.existsSync()) return markTestSkipped('docs/live/dist is local only');
    final (list, _) = LabShopSource.open(shop.readAsBytesSync(), AddonMarket.live.publicKey);
    expect(list.item(LabStore.tagCourse), isNotNull);
    expect(list.items.every((item) => item.supported), isTrue, reason: 'Everything published is something this app knows');
    final notice = File('../docs/live/dist/v1/app/notice.json');
    if (notice.existsSync()) AppNotice.decode(LabSigned.payload(notice.readAsBytesSync(), AddonMarket.live.publicKey, AppNotice.maximumBytes));
  });

  test("an item's picture is read only when it is a proper file", () {
    final hash = 'a' * 64;
    LabShopItem item(Object image) => LabShopItem.parse({'id': 'home.dusk', 'kind': 'home', 'name': '노을', 'soon': true, 'image': image})!;
    expect(item({'path': 'goods/home.dusk/0123abcd-card.jpg', 'size': 1000, 'sha256': hash}).image?.path, 'goods/home.dusk/0123abcd-card.jpg');
    expect(item({'path': '../x.jpg', 'size': 1000, 'sha256': hash}).image, isNull);
    expect(item({'path': 'goods/a.jpg', 'size': 3000000, 'sha256': hash}).image, isNull, reason: 'Larger than 2 MB');
    expect(item('goods/a.jpg').image, isNull, reason: 'A local path is only for the source list');
    expect(item('goods/a.jpg').supported, isTrue, reason: 'A picture never stops an item from being sold');
  });

  test('the prompt analyzer needs the 2D course and stays open without the list', () {
    final records = LabMemoryRecords();
    final lab = LabStore(course: course, shop: testShop(), diagnosis: LabDiagnosis.bundled, records: records);
    final analyzer = lab.shop.item(LabFeature.promptAnalyzer.item)!;
    expect(analyzer.requires, LabStore.tagCourse);
    expect(lab.unlocked(LabFeature.promptAnalyzer), isFalse);
    expect(lab.canBuy(analyzer), const LabBuyResult.needs(LabStore.tagCourse));
    for (final episode in course.episodes) {
      lab.engrave(episode, failsHung: 0);
    }
    expect(lab.buy(lab.shop.item(LabStore.tagCourse)!), LabBuyResult.bought);
    expect(lab.buy(analyzer), LabBuyResult.bought);
    expect(lab.unlocked(LabFeature.promptAnalyzer), isTrue);
    expect(lab.canBuy(analyzer), LabBuyResult.owned);
    final later = LabStore(course: course, diagnosis: LabDiagnosis.bundled, records: records);
    expect(later.unlocked(LabFeature.promptAnalyzer), isTrue, reason: 'What was bought opens without the shop list');
  });

  test('tickets count what each purchase brought', () {
    final lab = store();
    final tickets = lab.shop.items.firstWhere((item) => item.kind == 'ticket').copyWith(soon: false, count: 10);
    for (final episode in course.episodes) {
      lab.engrave(episode, failsHung: 0);
    }
    lab.buy(lab.shop.item(LabStore.tagCourse)!);
    expect(lab.buy(tickets), LabBuyResult.bought);
    expect(lab.buy(tickets), LabBuyResult.bought);
    expect(lab.tickets, 20);
    expect(LabProgress.fromRecords(lab.progress.records).purchases[tickets.id]?.each, 10, reason: 'Kept in the records');
  });

  test('a finished course starts over and pays a quarter, keeping what it paid', () {
    final records = LabMemoryRecords();
    final lab = LabStore(course: course, shop: testShop(), diagnosis: LabDiagnosis.bundled, records: records);
    lab.startOver();
    expect(lab.round, 0, reason: 'Only a finished course starts over');
    for (final episode in course.episodes) {
      lab.engrave(episode, failsHung: 0);
    }
    lab.hang(course.fails.first);
    expect(lab.finished, isTrue);
    final balance = lab.balance, sheet = LabEdition.bundled!.sections.where(lab.sectionOpened).length;
    lab.startOver();
    expect(lab.round, 1);
    expect(lab.finished, isFalse);
    expect(lab.rate, course.base, reason: 'The rate starts again');
    expect(lab.next?.id, course.episodes.first.id);
    expect(lab.hung(course.fails.first), isFalse, reason: 'The gallery starts empty');
    expect(lab.balance, balance, reason: 'What was earned stays');
    expect(LabEdition.bundled!.sections.where(lab.sectionOpened).length, sheet, reason: 'The cheat sheet stays open');
    final first = lab.engrave(course.episodes.first, failsHung: 1);
    expect(first.cardReward, (course.episodes.first.reward / 4).round());
    expect(lab.failReward, (course.info.rewards.fail / 4).round());
    expect(lab.hang(course.fails.first), isTrue);
    expect(lab.balance, balance + first.cardReward + lab.failReward);
    final synced = LabStore(course: course, shop: testShop(), diagnosis: LabDiagnosis.bundled, records: records);
    expect(synced.round, 1);
    expect(synced.earnedIDs, {course.episodes.first.id});
    expect(synced.balance, lab.balance);
  });

  test('a course from the shop pays', () {
    final lab = store();
    final official = LabCourseFile.decode(labCourseFile(edit: (top) => top['rewards'] = {'fail': 20, 'season': 100})).deck!.asOfficial();
    lab.showCourse(official);
    expect(lab.pays, isTrue);
    final first = lab.engrave(official.episodes[0], failsHung: 0);
    expect(first.cardReward, 999);
    expect(lab.hang(official.fails.first), isTrue);
    final second = lab.engrave(official.episodes[1], failsHung: 0);
    expect(second.seasonReward, 100, reason: 'Its season pays too');
    expect(lab.balance, 999 * 2 + 20 + 100);
    final reread = LabStore(course: course, shop: testShop(), diagnosis: LabDiagnosis.bundled, records: LabMemoryRecords()..replace(lab.progress.records));
    expect(reread.balance, lab.balance, reason: 'Read back from the records');
    expect(lab.progress.seasonGems['1'], isNull, reason: "The AI lab's season 1 is untouched");
  });

  test('the catalog keeps courses from the shop apart from imported ones', () {
    final folder = Directory.systemTemp.createTempSync('shop-courses');
    addTearDown(() => folder.deleteSync(recursive: true));
    final catalog = LearningCourses(folder: folder);
    catalog.add(labCourseFile());
    final official = catalog.addOfficial(labCourseFile(), 'course.prompt-basics');
    expect(official.official, isTrue);
    expect(official.item, 'course.prompt-basics');
    expect(official.deck?.official, isTrue);
    expect(
      [for (final course in catalog.all) course.id],
      [LearningCourse.labID, LearningCourse.tagsID, 'maker.prompt-basics'],
      reason: 'The official copy replaces the imported one',
    );
    expect(catalog.has('course.prompt-basics'), isTrue);
    expect(() => catalog.add(labCourseFile()), throwsA(const LabCourseFileError.reserved()), reason: "A file cannot take an official course's id");
    final reread = LearningCourses(folder: folder);
    expect([for (final course in reread.official) course.item], ['course.prompt-basics']);
    expect(reread.imported, isEmpty);
  });

  test('goods are checked against the list', () async {
    final data = utf8.encode('film');
    final file = LabShopFile(path: 'goods/home.test/loop.mp4', size: data.length, sha256: LabCourseFile.digest(data));
    List<int> served = data;
    final goods = LabGoods(
      market: AddonMarket(
        base: AddonMarket.liveBase,
        publicKey: TestSigningKey().public,
        fetch: (url, limit) async {
          expect(url.toString(), 'https://addons.nextline.work/v1/goods/home.test/loop.mp4');
          return served;
        },
      ),
    );
    expect(await goods.download(file), data);
    served = utf8.encode('fake');
    await expectLater(goods.download(file), throwsA(const AddonMarketError.damaged()), reason: 'A different file is refused');
    for (final path in ['../etc/passwd', '/goods/a', 'goods//a', 'goods/한글', '']) {
      expect(LabShopFile(path: path, size: 1, sha256: file.sha256).valid, isFalse, reason: path);
    }
  });

  test('home scenes are kept and chosen', () {
    final root = Directory.systemTemp.createTempSync('home-scenes');
    addTearDown(() {
      HomeScenes.root = null;
      HomeScenes.chosenScene.value = null;
      root.deleteSync(recursive: true);
    });
    HomeScenes.use(root);
    LabShopFile file(String name, List<int> data) => LabShopFile(path: 'goods/home.test/$name', size: data.length, sha256: LabCourseFile.digest(data));
    final films = {'intro': utf8.encode('intro'), 'loop': utf8.encode('loop'), 'still': utf8.encode('still')};
    final home = LabShopHome(
      intro: file('intro.mp4', films['intro']!),
      loop: file('loop.mp4', films['loop']!),
      still: file('still.jpg', films['still']!),
      palette: const {'sky': '102030'},
    );
    expect(home.valid, isTrue);
    expect(HomeScenes.has('home.test', home), isFalse);
    HomeScenes.keep('home.test', home, films);
    expect(HomeScenes.has('home.test', home), isTrue);
    expect(HomeScenes.file('loop'), isNull, reason: 'Kept is not chosen');
    HomeScenes.choose('home.test');
    expect(HomeScenes.file('loop')!.readAsBytesSync(), films['loop']);
    expect(HomeScenes.file('theme'), isNull, reason: "No music of its own: the app's plays");
    expect(HomeScenes.color('sky'), 0x102030);
    expect(HomeScenes.color('ground'), isNull);
    HomeScenes.use(root);
    expect(HomeScenes.chosen, 'home.test', reason: 'The choice is kept for the next launch');
    final newer = LabShopHome(intro: home.intro, loop: file('loop.mp4', utf8.encode('loop 2')), still: home.still);
    expect(HomeScenes.has('home.test', newer), isFalse, reason: 'A new version of a file is downloaded again');
    HomeScenes.choose(null);
    expect(HomeScenes.file('loop'), isNull);
  });

  // MARK: Update notice

  test('an update notice shows only on older builds, and a recommended one can be put off', () {
    const json = '''
      {"format": "tegnal-app-notice", "schemaVersion": 1, "id": "n1", "level": "recommended", "title": "업데이트", "message": "새 버전",
       "android": {"below": 22, "url": "https://play.google.com/store/apps/details?id=work.nextline.tegnal"}}''';
    final notice = AppNotice.decode(utf8.encode(json));
    expect(notice.appliesTo(21), isTrue);
    expect(notice.appliesTo(22), isFalse);
    expect(() => AppNotice.decode(utf8.encode(json.replaceFirst('"schemaVersion": 1', '"schemaVersion": 2'))), throwsA(LabShopError.invalid));
    expect(() => AppNotice.decode(utf8.encode(json.replaceFirst('recommended', 'someday'))), throwsA(LabShopError.invalid));
    String? putOff;
    final old = AppNotices(build: 21, fetch: () async => const [], putOffStore: (read: () => putOff, write: (id) => putOff = id));
    old.show(notice);
    expect(old.current, notice);
    old.putOff();
    expect(old.current, isNull);
    old.show(notice);
    expect(old.current, isNull, reason: 'Put off once, not shown again');
    final urgent = notice.copyWith(id: 'n2', level: AppNoticeLevel.required);
    old.show(urgent);
    old.putOff();
    expect(old.current, urgent, reason: 'A required notice cannot be put off');
    final current = AppNotices(build: 22, fetch: () async => const []);
    current.show(urgent);
    expect(current.current, isNull, reason: 'Builds that are new enough see nothing');
    old.show(urgent.copyWith(noAndroid: true));
    expect(old.current, isNull, reason: 'A notice for the other platform only');
  });

  testWidgets('a required update notice stays over the app', (tester) async {
    final notices = AppNotices(build: 1, fetch: () async => const []);
    await tester.pumpWidget(
      CupertinoApp(
        home: AppNoticeGate(notices: notices, child: const CupertinoPageScaffold(child: Center(child: Text('app')))),
      ),
    );
    notices.show(
      const AppNotice(
        id: 'n',
        level: AppNoticeLevel.required,
        title: LabText({'en': 'Update Required'}),
        message: LabText({'en': 'Please update.'}),
        android: AppNoticePlatform(below: 2),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('notice.title')), findsOneWidget);
    expect(find.byKey(const Key('notice.update')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byKey(const Key('notice.title')), findsOneWidget, reason: 'Back does not leave it');
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
    final first = LabStore(course: course, shop: testShop(), diagnosis: LabDiagnosis.bundled, records: LabDatabaseRecords(booru.database));
    first.engrave(course.episode('ep01')!, failsHung: 0);
    first.hang(course.fails.first);
    first.diagnose(first.diagnosis!.types.first);
    final second = LabStore(course: course, shop: testShop(), diagnosis: LabDiagnosis.bundled, records: LabDatabaseRecords(booru.database));
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

  // MARK: Course files and the 코스 tab

  test('a course file decodes as an imported deck course', () {
    final imported = LabCourseFile.decode(labCourseFile()).deck!;
    expect(imported.imported, isTrue);
    expect(imported.id, 'maker.prompt-basics');
    expect([for (final episode in imported.episodes) episode.id], ['a1', 'a2']);
    expect(imported.top, 40);
    expect(imported.info.rewards.fail, 0, reason: 'Rewards may be left out');
  });

  test('course files are refused rather than cleaned', () {
    void refused(List<int> data, [LabCourseFileError? error]) =>
        expect(() => LabCourseFile.decode(data), throwsA(error == null ? isA<LabCourseFileError>() : equals(error)));
    refused(utf8.encode('[]'), const LabCourseFileError.notCourse());
    refused(labCourseFile(edit: (top) => top['format'] = 'tegnal-addon'), const LabCourseFileError.notCourse());
    refused(labCourseFile(edit: (top) => top['version'] = 2), const LabCourseFileError.newer());
    refused(labCourseFile(edit: (top) => top['engine'] = 'flashcards'), const LabCourseFileError.newer());
    refused(
      labCourseFile(edit: (top) => ((top['episodes']! as List)[0] as Map)['tool'] = {'kind': 'hologram', 'title': '새 도구'}),
      const LabCourseFileError.newer(),
    );
    refused(List.filled(LabCourseFile.maximumBytes + 1, 32), const LabCourseFileError.tooLarge());
    refused(labCourseFile(id: LearningCourse.labID), const LabCourseFileError.invalid('id'));
    refused(labCourseFile(id: 'Bad ID'), const LabCourseFileError.invalid('id'));
    refused(labCourseFile(edit: (top) => top['title'] = '숨은\u202E글자'));
    refused(
      labCourseFile(
        edit: (top) => top['seasons'] = [
          {'number': 1, 'title': '시즌', 'order': 'fixed', 'episodes': ['a1']},
        ],
      ),
      const LabCourseFileError.invalid('episodes'),
    );
    refused(
      labCourseFile(
        edit: (top) {
          final episodes = top['episodes']! as List;
          (episodes[0] as Map)['choices'] = [
            {'text': '함정뿐', 'verdict': '판정'},
            {'text': '또 함정', 'verdict': '판정'},
          ];
        },
      ),
    );
    refused(
      labCourseFile(
        edit: (top) {
          final episodes = top['episodes']! as List;
          (episodes[1] as Map)['tool'] = {
            'kind': 'stamps',
            'title': '도장',
            'stamps': ['하나'],
            'items': [
              {'text': '문장', 'answer': 3},
            ],
          };
        },
      ),
      const LabCourseFileError.invalid('episodes.a2.tool.stamps'),
    );
  });

  /// An imported course keeps its records under its own id and pays nothing; the AI lab's money is untouched by it.
  test('an imported course keeps its own records and pays nothing', () {
    final lab = store();
    final imported = LabCourseFile.decode(labCourseFile()).deck!;
    lab.showCourse(imported);
    expect(lab.next?.id, 'a1');
    expect(lab.rate, 20);
    final engraving = lab.engrave(imported.episodes.first, failsHung: 1);
    expect(lab.hang(imported.fails.first), isTrue);
    expect(engraving.cardReward, 0);
    expect(engraving.failReward, 0);
    expect(lab.failReward, 0);
    expect(lab.rate, 30);
    expect(lab.balance, 0, reason: 'Nothing in an imported course pays');
    expect(lab.progress.cards.containsKey('maker.prompt-basics/a1'), isTrue);
    expect(lab.progress.fails.containsKey('maker.prompt-basics/a1-trap'), isTrue);
    expect(lab.offersDiagnosis, isFalse, reason: 'Card No. 000 is the AI lab\'s');

    lab.showCourse(course);
    expect(lab.next?.id, 'ep01', reason: 'The AI lab\'s deck is as it was');
    expect(lab.rate, course.base);
    expect(lab.offersDiagnosis, isTrue);
  });

  test('the catalog keeps imported courses and removes them', () {
    final folder = Directory.systemTemp.createTempSync('courses-');
    addTearDown(() => folder.deleteSync(recursive: true));
    final catalog = LearningCourses(folder: folder);
    expect([for (final course in catalog.all) course.id], [LearningCourse.labID, LearningCourse.tagsID]);
    final data = labCourseFile();
    catalog
      ..add(data)
      ..add(data);
    expect([for (final course in catalog.all) course.id], [LearningCourse.labID, LearningCourse.tagsID, 'maker.prompt-basics'], reason: 'The same course again replaces it');
    expect(catalog.course('maker.prompt-basics')?.engine, LearningEngine.deck);
    expect([for (final course in LearningCourses(folder: folder).imported) course.id], ['maker.prompt-basics'], reason: 'Kept for the next launch');
    catalog.remove('maker.prompt-basics');
    expect(LearningCourses(folder: folder).imported, isEmpty);
    expect(() => catalog.add(labCourseFile(id: LearningCourse.labID)), throwsA(isA<LabCourseFileError>()), reason: "A bundled course's id is never taken");
  });

  test('the sample courses in the docs folder pass', () {
    final folder = Directory('../docs/edu/courses');
    final files = folder.existsSync() ? folder.listSync().whereType<File>().where((file) => file.path.endsWith('.${LabCourseFile.fileExtension}')).toList() : <File>[];
    if (files.isEmpty) return markTestSkipped('The samples are local only');
    for (final file in files) {
      expect(() => LabCourseFile.decode(file.readAsBytesSync()), returnsNormally, reason: file.path);
    }
  });

  test('a course on the tags engine brings a path and tags of its own', () {
    final course = LabCourseFile.decode(tagsCourseFile());
    expect(course.engine, LearningEngine.tags);
    final lessons = course.lessons!;
    expect([for (final lesson in lessons.path.lessons) lesson.id], ['course:maker.backgrounds:intro', 'course:maker.backgrounds:tags']);
    expect(lessons.title['en'], '배경과 장소', reason: 'Korean-only text is shown in English too');
    expect(lessons.unit?.tags.single.name, 'lighthouse');
    expect(
      () => LabCourseFile.decode(
        tagsCourseFile(
          edit: (top) => (((top['sections']! as List)[0] as Map)['lessons'] as List)[0] = {
            'id': 'intro',
            'kind': 'concept',
            'symbol': 'book',
            'title': {'ko': '소개'},
            'steps': [
              {'card': {'title': {'ko': '가자'}, 'body': {'ko': '생성기'}, 'action': 'generator'}},
            ],
          },
        ),
      ),
      throwsA(isA<LabCourseFileError>()),
      reason: 'Cards in course files only tell: they open nothing',
    );
    expect(
      () => LabCourseFile.decode(
        tagsCourseFile(
          edit: (top) => ((((top['sections']! as List)[0] as Map)['lessons'] as List)[0] as Map)['steps'] = [
            {'match': {'pairs': []}},
          ],
        ),
      ),
      throwsA(const LabCourseFileError.newer()),
      reason: 'A step this app does not know asks for an update',
    );
  });

  test('a course for a newer app waits in the catalog', () {
    final folder = Directory.systemTemp.createTempSync('courses-');
    addTearDown(() => folder.deleteSync(recursive: true));
    final catalog = LearningCourses(folder: folder);
    expect(
      () => catalog.add(labCourseFile(edit: (top) => top..['engine'] = 'flashcards'..['title'] = '미래 코스')),
      throwsA(const LabCourseFileError.newer()),
    );
    expect(catalog.waiting, [const WaitingCourse(id: 'maker.prompt-basics', title: '미래 코스')]);
    expect(catalog.course('maker.prompt-basics'), isNull);
    expect([for (final course in LearningCourses(folder: folder).waiting) course.id], ['maker.prompt-basics'], reason: 'Kept for after the update');
    catalog.add(labCourseFile());
    expect(catalog.waiting, isEmpty);
    expect(catalog.course('maker.prompt-basics'), isNotNull);
  });

  test('the card that finishes a season says so', () {
    final lab = store();
    final season = course.seasons.first;
    for (final id in season.episodes.take(season.episodes.length - 1)) {
      expect(lab.engrave(course.episode(id)!, failsHung: 0).season, isNull);
    }
    final last = course.episode(season.episodes.last)!;
    expect(lab.engrave(last, failsHung: 0).season, season.number);
    expect(lab.engrave(last, failsHung: 0).season, isNull, reason: 'Playing it again finishes nothing new');
  });

  test('markdown details read as headings, lists, quotes and fenced code', () {
    final blocks = LabMarkdown.blocks('첫 줄\n이어서\n\n### 제목\n1. 하나\n- 점\n> 인용\n---\n```\n코드 한 줄\n```');
    expect(blocks.map((block) => block.runtimeType.toString()), [
      'LabMarkdownParagraph',
      'LabMarkdownHeading',
      'LabMarkdownNumbered',
      'LabMarkdownBullet',
      'LabMarkdownQuote',
      'LabMarkdownRule',
      'LabMarkdownCode',
    ]);
    expect((blocks.first as LabMarkdownParagraph).text, '첫 줄 이어서');
    expect((blocks.last as LabMarkdownCode).code, '코드 한 줄');
    final spans = LabMarkdown.inline('**굵게** 그리고 `코드` [링크](https://example.com)', const TextStyle()).children!;
    expect(spans.map((span) => (span as TextSpan).text), ['굵게', ' 그리고 ', '코드', ' ', '링크'], reason: 'Links keep only their words');
  });

  test('every bundled cheat-sheet row names an icon both apps draw', () {
    for (final section in LabEdition.bundled!.sections) {
      for (final row in section.rows) {
        if (row.symbol case final symbol?) expect(labSheetSymbol(symbol), isNot(labSheetSymbol(null)), reason: symbol);
      }
    }
  });
}
