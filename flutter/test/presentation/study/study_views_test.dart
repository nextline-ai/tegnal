import 'dart:convert';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_fixture_source.dart';
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/lab/lab_records.dart';
import 'package:tegnal/core/lab/lab_shop.dart';
import 'package:tegnal/core/lab/lab_store.dart';
import 'package:tegnal/core/study/study_engine.dart';
import 'package:tegnal/core/support/l10n.dart';
import 'package:tegnal/core/study/study_models.dart';
import 'package:tegnal/core/study/study_session.dart';
import 'package:tegnal/core/study/study_store.dart';
import 'package:tegnal/presentation/booru/booru_settings_views.dart';
import 'package:tegnal/presentation/design/ios_controls.dart';
import 'package:tegnal/presentation/study/prompt_analyzer.dart';
import 'package:tegnal/presentation/study/study_home_view.dart';
import 'package:tegnal/presentation/study/study_quiz_view.dart';
import 'package:tegnal/presentation/study/study_tag_view.dart';
import 'package:tegnal/presentation/study/study_widgets.dart';
import 'package:tegnal/presentation/study_mode/study_kit.dart';

import '../../support/lab_shop_fixtures.dart';
import 'study_test_support.dart';

Finder key(String name) => find.byKey(Key(name));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => StudyCurriculum.useBundled(null));

  group('entry row', () {
    testWidgets('is reachable with no server chosen, beside the notice, and enters learning mode on its map', (tester) async {
      final harness = StudyHarness(select: false);
      StudyMode.shared.tab = StudyTab.me;
      addTearDown(StudyMode.shared.leave);
      await harness.pump(tester, BooruSavedServersView(booru: harness.booru, tags: (context, server, {onBack}) => const SizedBox()));
      expect(key('study.entry'), findsOneWidget);
      expect(find.text('Tag Study'), findsOneWidget);
      expect(find.text('lab.2d.tagline'), findsOneWidget);
      expect(StudyMode.shared.active, isFalse);
      await tester.tap(key('study.entry'));
      await tester.pump();
      expect(StudyMode.shared.active, isTrue);
      expect(StudyMode.shared.tab, StudyTab.path);
    });

    testWidgets('reads three states: not started, due, and learned so far', (tester) async {
      final harness = StudyHarness(select: false);
      final total = StudyCurriculum.bundled.count;
      await harness.pump(tester, BooruSavedServersView(booru: harness.booru, tags: (context, server, {onBack}) => const SizedBox()));
      expect(find.text('lab.2d.tagline'), findsOneWidget);

      harness.store.studyStore.answer('1girl', right: true, now: DateTime.now().subtract(const Duration(days: 3)));
      harness.state.appearanceChanged();
      await tester.pump();
      expect(find.text('1 to review · 0 of $total learned'), findsOneWidget);

      harness.store.studyStore.answer('1girl', right: true);
      harness.state.appearanceChanged();
      await tester.pump();
      expect(find.text('0 of $total learned'), findsOneWidget);
    });
  });

  group('home', () {
    testWidgets('shows the summary, the units and the closing footnote, and searches the curriculum', (tester) async {
      final harness = StudyHarness();
      await harness.pump(tester, StudyHomeView(booru: harness.booru));
      expect(find.text('Start Learning'), findsOneWidget);
      expect(key('study.review'), findsNothing);
      expect(find.text('To review'), findsOneWidget);
      expect(find.text('Answered today'), findsOneWidget);
      expect(find.text('Day streak'), findsOneWidget);
      final first = StudyCurriculum.bundled.units.first;
      expect(key('study.unit.${first.id}'), findsOneWidget);
      expect(find.text(first.title.resolved()), findsOneWidget);

      await tester.enterText(find.byType(CupertinoTextField), 'cowboy shot');
      await tester.pump();
      expect(find.text('cowboy shot'), findsWidgets);
      expect(find.text('Look up “cowboy_shot” on the server'), findsNothing, reason: 'A taught tag needs no lookup');

      await tester.enterText(find.byType(CupertinoTextField), 'zzqq nothing');
      await tester.pump();
      expect(key('study.lookup'), findsOneWidget);
      expect(find.text('Look up “zzqq_nothing” on the server'), findsOneWidget);
    });

    testWidgets('the start button becomes Today’s Study and Review Only appears once something is due', (tester) async {
      final harness = StudyHarness();
      harness.store.studyStore.answer('1girl', right: true, now: DateTime.now().subtract(const Duration(days: 3)));
      await harness.pump(tester, StudyHomeView(booru: harness.booru));
      expect(find.text("Today's Study"), findsOneWidget);
      expect(find.text('Review Only (1)'), findsOneWidget);
    });

    testWidgets('a unit lists its groups and tags with their counts once read', (tester) async {
      final harness = StudyHarness();
      final unit = StudyCurriculum.bundled.units.first;
      await harness.pump(tester, StudyHomeView(booru: harness.booru));
      await tester.tap(key('study.unit.${unit.id}'));
      await tester.pumpAndSettle();
      expect(key('study.unitQuiz'), findsOneWidget);
      expect(find.text(unit.groups.first.title.resolved()), findsOneWidget);
      expect(key('study.tag.${unit.groups.first.tags.first.name}'), findsOneWidget);
      // The fixture server counts a thousand posts for each letter of a tag.
      final name = unit.groups.first.tags.first.name;
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(StudyStyle.count(1000 * name.length)), findsWidgets);
    });
  });

  group('a round', () {
    testWidgets('runs from the home screen through ten answers to the results', (tester) async {
      final harness = StudyHarness();
      await harness.pump(tester, StudyHomeView(booru: harness.booru));
      await tester.tap(key('study.start'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      for (var question = 0; question < StudyEngine.roundSize; question++) {
        await pumpUntil(tester, key('study.choice.0'));
        expect(key('study.verdict'), findsNothing);
        await tester.tap(key('study.choice.0'));
        await tester.pump(const Duration(milliseconds: 200));
        expect(key('study.verdict'), findsOneWidget);
        expect(find.text('About This Tag'), findsOneWidget);
        expect(find.text(question == StudyEngine.roundSize - 1 ? 'See Results' : 'Next'), findsOneWidget);
        await tester.tap(key('study.next'));
        await tester.pump();
      }
      await pumpUntil(tester, key('study.score'));
      final score = (tester.widget(key('study.score')) as Text).data!;
      expect(RegExp(r'^\d+ / 10$').hasMatch(score), isTrue, reason: score);
      expect(key('study.done'), findsOneWidget);
      expect(key('study.again'), findsOneWidget);
      expect(harness.store.studyStore.progress().length, 10, reason: 'Every answer was recorded');
      expect(harness.store.studyStore.days().first.answered, 10);

      await tester.tap(key('study.done'));
      await tester.pumpAndSettle();
      expect(key('study.score'), findsNothing);
      expect(find.text('Today\'s Study'), findsOneWidget, reason: 'The home screen reads the new progress');
    });

    testWidgets('the results offer another round, and say when nothing is due', (tester) async {
      final harness = StudyHarness(select: false);
      await harness.pump(tester, StudyHomeView(booru: harness.booru));
      harness.store.studyStore.answer('1girl', right: true);
      await tester.tap(key('study.unit.${StudyCurriculum.bundled.units.first.id}'));
      await tester.pumpAndSettle();
      await tester.tap(key('study.unitQuiz'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      for (var question = 0; question < StudyEngine.roundSize; question++) {
        await pumpUntil(tester, key('study.choice.0'));
        await tester.tap(key('study.choice.0'));
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(key('study.next'));
        await tester.pump();
      }
      await pumpUntil(tester, key('study.again'));
      expect(find.text('Some questions asked by meaning because no picture could be read.'), findsNothing, reason: 'No server is chosen, so none was missing');
      await tester.tap(key('study.again'));
      await pumpUntil(tester, key('study.choice.0'));
      expect(key('study.score'), findsNothing);
    });

    testWidgets('a review round with nothing due shows Nothing to Review and no second round', (tester) async {
      final harness = StudyHarness();
      await harness.pump(
        tester,
        Builder(
          builder: (context) => CupertinoButton(
            key: const Key('open'),
            onPressed: () => openStudyQuiz(
              context,
              booru: harness.booru,
              session: StudySession(scope: StudyScope.review, store: harness.store, source: harness.source),
            ),
            child: const Text('Open'),
          ),
        ),
      );
      await tester.tap(key('open'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('Nothing to Review'), findsOneWidget);
      expect(find.text('No tag is due right now. Learn new tags or come back later.'), findsOneWidget);
      expect(key('study.done'), findsOneWidget);
      expect(key('study.again'), findsNothing);
      await tester.tap(key('study.done'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing to Review'), findsNothing);
    });
  });

  group('review card', () {
    testWidgets('is absent with nothing due, present when a tag is due, and enters learning mode on Practice', (tester) async {
      final harness = StudyHarness();
      await harness.pump(tester, StudyReviewCard(booru: harness.booru));
      expect(key('study.reviewCard'), findsNothing);
      expect(find.text('Tags to Review'), findsNothing);

      harness.store.studyStore.answer('1girl', right: true, now: DateTime.now().subtract(const Duration(days: 3)));
      harness.state.appearanceChanged();
      await tester.pump();
      expect(key('study.reviewCard'), findsOneWidget);
      expect(find.text('Tags to Review'), findsOneWidget);
      expect(find.text('Tags due again: 1'), findsOneWidget);

      addTearDown(StudyMode.shared.leave);
      await tester.tap(key('study.reviewCard'));
      await tester.pump();
      expect(StudyMode.shared.active, isTrue);
      expect(StudyMode.shared.tab, StudyTab.practice);
    });
  });

  group('tag page', () {
    testWidgets('shows the meaning, what it is mixed up with, what it is used with and the server page', (tester) async {
      final harness = StudyHarness();
      final curriculum = StudyCurriculum.bundled;
      final tag = curriculum.tags.firstWhere(
        (tag) => (tag.confusable ?? const []).any(curriculum.contains) && tag.name != 'upper_body' && tag.name != 'full_body',
      );
      final other = curriculum.tag(tag.confusable!.firstWhere(curriculum.contains))!;
      await harness.pump(tester, StudyTagView(booru: harness.booru, name: tag.name));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(tag.english), findsWidgets);
      expect(find.text(tag.note.resolved()), findsOneWidget);
      expect(find.text('Often Mixed Up With'), findsOneWidget);
      expect(find.text(other.english), findsOneWidget);
      expect(find.text('Often Used Together'), findsOneWidget);
      expect(find.text('upper body'), findsWidgets);
      expect(find.text('42%'), findsOneWidget);
      expect(find.text('sample artist'), findsNothing, reason: 'Only general tags are offered');
      expect(find.text("The share of this tag's posts that also carry each tag."), findsOneWidget);
      expect(find.text('Examples'), findsOneWidget);
      expect(find.text("From the Server's Tag Page"), findsOneWidget);
      expect(find.textContaining('A synthetic page about', findRichText: true), findsOneWidget);
      expect(find.text('See also'), findsOneWidget);
      expect(find.text(harness.server.displayName), findsOneWidget, reason: 'The server is named under its page');
      expect(find.text('Browse Pictures With This Tag'), findsOneWidget);
      expect(find.text('Save Tag'), findsOneWidget);
      expect(key('study.practice'), findsOneWidget);
      // The fixture's first example of a tag is numbered from the tag's name.
      final base = tag.name.runes.fold<int>(0, (hash, rune) => (hash * 31 + rune) % 9000).abs() * 10 + 20000;
      expect(key('study.example.$base'), findsOneWidget);
    });

    testWidgets('copies the words, saves the tag and opens another tag’s page from a chip', (tester) async {
      final harness = StudyHarness();
      await harness.pump(tester, StudyTagView(booru: harness.booru, name: 'cowboy_shot'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(key('study.copy'));
      await tester.pump();
      expect(find.text('Copied'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Copy for a Prompt'), findsOneWidget);

      await tester.tap(find.text('Save Tag'));
      await tester.pump();
      expect(harness.store.savedTags(harness.server.id), contains('cowboy_shot'));
      expect(find.text('Remove Saved Tag'), findsOneWidget);

      await tester.tap(find.text('upper body').first);
      await tester.pumpAndSettle();
      expect(find.text('upper body'), findsWidgets);
      expect(find.text('Back'), findsNothing);
    });

    testWidgets('the Save button follows the first selected server only', (tester) async {
      final harness = StudyHarness();
      final second = BooruFixtureEnvironment.servers[1];
      harness.store.saveServer(second);
      harness.store.setSelectedServers([harness.server.id, second.id]);
      harness.store.toggleTag('cowboy_shot', serverID: second.id);
      await harness.pump(tester, StudyTagView(booru: harness.booru, name: 'cowboy_shot'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Save Tag'), findsOneWidget, reason: 'Saved on the second server only');

      harness.store.toggleTag('cowboy_shot', serverID: harness.server.id);
      await tester.pump();
      expect(find.text('Remove Saved Tag'), findsOneWidget);

      // The first server is the one the button acts on, whatever the others hold.
      harness.store.toggleTag('cowboy_shot', serverID: harness.server.id);
      await tester.pump();
      expect(find.text('Save Tag'), findsOneWidget, reason: 'Still saved on the second server');
    });

    testWidgets('a tag the lessons do not teach says so when the server has no page, and offers no practice', (tester) async {
      final harness = StudyHarness(select: false);
      await harness.pump(tester, StudyTagView(booru: harness.booru, name: 'not_a_taught_tag'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('This tag is not part of the lessons, and the server has no page about it.'), findsOneWidget);
      expect(key('study.practice'), findsNothing);
      expect(find.text('Examples'), findsNothing, reason: 'No server is chosen');
    });
  });

  group('prompt view', () {
    BooruPost post(StudyHarness harness) => BooruPost(
      serverID: harness.server.id,
      postID: 7,
      width: 100,
      height: 100,
      tags: ['long_hair', 'solo', 'sample_artist', '1girl', 'hair_(ornament)'],
      artists: ['sample_artist'],
      rating: 'g',
      score: 1,
      fileExtension: 'png',
      tagCategories: {'sample_artist': 1},
    );

    testWidgets('writes the picture’s tags in each format and keeps the choices', (tester) async {
      final harness = StudyHarness();
      final value = post(harness);
      await harness.pump(tester, StudyPromptView(booru: harness.booru, post: value));
      String shown() => (tester.widget(key('study.prompt')) as Text).data!;
      expect(shown(), 'solo, 1girl, long hair, hair (ornament)');
      expect(find.text('Headcount first, then characters and series, then what the picture shows. File and translation tags are left out.'), findsOneWidget);

      await tester.tap(find.text('Escaped Brackets'));
      await tester.pumpAndSettle();
      expect(shown(), r'solo, 1girl, long hair, hair \(ornament\)');
      expect(find.text('For tools that read brackets as emphasis: brackets that belong to a tag are escaped.'), findsOneWidget);

      await tester.tap(find.text('Search Tags'));
      await tester.pumpAndSettle();
      expect(shown(), 'solo 1girl long_hair hair_(ornament)');
      expect(find.text('The tags as the server writes them, ready to search with.'), findsOneWidget);
      expect(harness.preferences.booruDefaults.string('study.promptStyle'), 'tags');

      await tester.tap(find.byType(TegnalSwitch));
      await tester.pumpAndSettle();
      expect(shown(), 'solo 1girl sample_artist long_hair hair_(ornament)');
      expect(harness.preferences.booruDefaults.boolean('study.promptArtists'), isTrue);

      await tester.tap(key('study.promptCopy'));
      await tester.pump();
      expect(find.text('Copied'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('Tags in This Picture'), findsOneWidget);
      expect(key('study.promptPractice'), findsOneWidget);
    });

    testWidgets('the prompt analyzer is sold for 보석 once 2D AI 배우기 is owned, then opens the picture as a prompt', (tester) async {
      final harness = StudyHarness();
      final lab = LabStore.shared..use(LabShop.decode(utf8.encode(fixtureShopJson)));
      addTearDown(lab.reset);
      lab.progress.editions['test-income'] = 1000;
      await harness.pump(tester, PromptAnalyzerRow(booru: harness.booru, post: post(harness), tint: const Color(0xFF007AFF)));
      expect(find.text(L10n.text('Prompt Analyzer')), findsOneWidget);
      await tester.tap(key('booru.prompt'));
      await tester.pumpAndSettle();
      expect(key('lab.shop.see.course.tags'), findsOneWidget, reason: 'It needs 2D AI 배우기 first, which its page leads to');
      expect(key('lab.shop.buy.feature.prompt-analyzer'), findsNothing);
      await tester.tap(key('lab.shop.see.course.tags'));
      await tester.pumpAndSettle();
      expect(key('lab.shop.page.course.tags'), findsOneWidget, reason: 'The page turns to the course it needs');
      Navigator.of(tester.element(key('lab.shop.page.course.tags'))).pop();
      await tester.pumpAndSettle();

      lab.progress.purchases[LabStore.tagCourse] = const LabPurchase(price: 0, count: 1, date: 0);
      await tester.tap(key('booru.prompt'));
      await tester.pumpAndSettle();
      await tester.tap(key('lab.shop.buy.feature.prompt-analyzer'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(lab.unlocked(LabFeature.promptAnalyzer), isTrue);
      expect(lab.balance, 800);
      expect(key('lab.shop.bought'), findsOneWidget, reason: 'Bought on its page, with no second question');

      await tester.tap(key('lab.shop.open.feature.prompt-analyzer'));
      await tester.pumpAndSettle();
      expect(key('study.prompt'), findsOneWidget, reason: 'Open turns the page into the analyzer');
    });

    testWidgets('remembers the format, and leaves out the artist switch when the picture has no artist', (tester) async {
      final harness = StudyHarness();
      harness.preferences.booruDefaults.set('study.promptStyle', 'escaped');
      final value = post(harness)..artists = [];
      await harness.pump(tester, StudyPromptView(booru: harness.booru, post: value));
      expect((tester.widget(key('study.prompt')) as Text).data, r'solo, 1girl, long hair, hair \(ornament\)');
      expect(find.text('Include Artist Names'), findsNothing);
    });
  });
}
