import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/study/study_models.dart';
import 'package:tegnal/core/study/study_path.dart';
import 'package:tegnal/presentation/study_mode/study_lesson_steps.dart';

import '../study/study_test_support.dart';

const _tags = [
  StudyTag(name: 'smile', note: {'en': 'Smiling'}),
  StudyTag(name: 'long_hair', note: {'en': 'Hair past the shoulders'}),
  StudyTag(name: 'outdoors', note: {'en': 'Outside'}),
];

const _build = StudyPathBuild(brief: {'en': 'One girl smiling'}, answer: ['1girl', 'smile'], extras: ['1boy', 'outdoors']);

const _order = StudyPathOrder(
  brief: {'en': 'Put them in order'},
  items: [
    {'en': 'First'},
    {'en': 'Second'},
    {'en': 'Third'},
  ],
  why: {'en': ''},
);

const _sort = StudyPathSort(
  brief: {'en': 'Sort them'},
  left: {'en': 'Lefty'},
  right: {'en': 'Righty'},
  items: [
    StudyPathSortItem(text: {'en': 'Apple'}, right: false),
    StudyPathSortItem(text: {'en': 'Brick'}, right: true),
    StudyPathSortItem(text: {'en': 'Cherry'}, right: false),
  ],
  why: {'en': ''},
);

Finder _key(String key) => find.byKey(Key(key));

/// The text shown inside [parent] (its first `Text`).
String _textIn(Finder parent) {
  final text = find.descendant(of: parent, matching: find.byType(Text)).evaluate().first.widget as Text;
  return text.data ?? text.textSpan!.toPlainText();
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.tap(_key(key));
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _settle(WidgetTester tester, [int milliseconds = 1200]) async {
  for (var waited = 0; waited < milliseconds; waited += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StudyMatchStep', () {
    testWidgets('right pairs turn green and answer true', (tester) async {
      final harness = StudyHarness();
      bool? answered;
      await harness.pump(tester, StudyMatchStep(tags: _tags, revealed: false, answer: (right) => answered = right));
      expect(find.text('Pair each tag with what it means'), findsOneWidget);
      for (final tag in _tags) {
        expect(_key('study.match.tag.${tag.name}'), findsOneWidget);
        expect(_key('study.match.meaning.${tag.name}'), findsOneWidget);
      }
      for (final tag in _tags) {
        await _tap(tester, 'study.match.tag.${tag.name}');
        await _tap(tester, 'study.match.meaning.${tag.name}');
      }
      expect(answered, isNull, reason: 'The answer waits 350 ms');
      await _settle(tester, 500);
      expect(answered, isTrue);
    });

    testWidgets('a wrong pair makes the step a miss', (tester) async {
      final harness = StudyHarness();
      bool? answered;
      await harness.pump(tester, StudyMatchStep(tags: _tags, revealed: false, answer: (right) => answered = right));
      await _tap(tester, 'study.match.tag.smile');
      await _tap(tester, 'study.match.meaning.outdoors');
      await _settle(tester, 500);
      // The tag stays chosen after a wrong pair.
      await _tap(tester, 'study.match.meaning.smile');
      for (final tag in _tags.skip(1)) {
        await _tap(tester, 'study.match.tag.${tag.name}');
        await _tap(tester, 'study.match.meaning.${tag.name}');
      }
      await _settle(tester, 500);
      expect(answered, isFalse);
    });
  });

  group('StudyBuildStep', () {
    Future<bool?> build(WidgetTester tester, List<String> taps, {List<String> remove = const []}) async {
      final harness = StudyHarness();
      bool? answered;
      await harness.pump(
        tester,
        StudyBuildStep(booru: harness.booru, build: _build, picture: null, server: harness.server, revealed: false, answer: (right) => answered = right),
      );
      expect(find.descendant(of: _key('study.build.tray'), matching: find.text('Tap the tags below')), findsOneWidget);
      for (final tag in taps) {
        await _tap(tester, 'study.build.bank.$tag');
      }
      for (final tag in remove) {
        await _tap(tester, 'study.build.chosen.$tag');
        expect(_key('study.build.chosen.$tag'), findsNothing);
      }
      await _settle(tester, 500);
      await tester.tap(_key('study.check'));
      await tester.pump();
      return answered;
    }

    testWidgets('the right prompt is right', (tester) async {
      expect(await build(tester, ['1girl', 'smile']), isTrue);
      expect(_key('study.build.chosen.1girl'), findsOneWidget);
      expect(find.text('1girl'), findsNWidgets(2), reason: 'The bank keeps a dimmed copy of a used tag');
    });

    testWidgets('a wrong tag makes it wrong', (tester) async {
      expect(await build(tester, ['1girl', 'outdoors']), isFalse);
    });

    testWidgets('the headcount tag must come first', (tester) async {
      expect(await build(tester, ['smile', '1girl']), isFalse);
    });

    testWidgets('a chosen tag is taken back by a tap', (tester) async {
      expect(await build(tester, ['1boy', '1girl', 'smile'], remove: ['1boy']), isTrue);
    });

    testWidgets('Check waits for a tag', (tester) async {
      final harness = StudyHarness();
      bool? answered;
      await harness.pump(
        tester,
        StudyBuildStep(booru: harness.booru, build: _build, picture: null, server: harness.server, revealed: false, answer: (right) => answered = right),
      );
      await tester.tap(_key('study.check'));
      await tester.pump();
      expect(answered, isNull);
    });
  });

  group('StudyOrderStep', () {
    Future<List<bool>> pump(WidgetTester tester) async {
      final harness = StudyHarness();
      final answers = <bool>[];
      await harness.pump(tester, StudyOrderStep(order: _order, revealed: false, answer: answers.add));
      return answers;
    }

    Future<void> check(WidgetTester tester) async {
      await tester.tap(_key('study.check'));
      await tester.pump();
    }

    Future<void> drag(WidgetTester tester, String from, Offset to) async {
      await tester.timedDrag(_key(from), to - tester.getCenter(_key(from)), const Duration(milliseconds: 300));
      await _settle(tester);
    }

    testWidgets('the bank is never in the right order and has a hint', (tester) async {
      for (var run = 0; run < 8; run++) {
        await pump(tester);
        final tops = [for (var item = 0; item < 3; item++) tester.getTopLeft(_key('study.order.item.$item')).dy];
        expect(tops[0] < tops[1] && tops[1] < tops[2], isFalse);
      }
      expect(find.text('Tap them in order, or drag them into place.'), findsOneWidget);
      expect(_key('study.order.slot.0'), findsOneWidget);
    });

    testWidgets('tapping in order is right, and Check waits until every place is filled', (tester) async {
      final answers = await pump(tester);
      await _tap(tester, 'study.order.item.0');
      await _tap(tester, 'study.order.item.1');
      await check(tester);
      expect(answers, isEmpty);
      await _tap(tester, 'study.order.item.2');
      await _settle(tester, 500);
      expect(_textIn(_key('study.order.place.0')), 'First');
      expect(_textIn(_key('study.order.place.2')), 'Third');
      await check(tester);
      expect(answers, [true]);
    });

    testWidgets('a tap takes a placed thing back to the bank', (tester) async {
      await pump(tester);
      await _tap(tester, 'study.order.item.1');
      await _settle(tester, 500);
      expect(_key('study.order.item.1'), findsNothing);
      await _tap(tester, 'study.order.place.0');
      await _settle(tester, 500);
      expect(_key('study.order.place.0'), findsNothing);
      expect(_key('study.order.item.1'), findsOneWidget);
    });

    testWidgets('a wrong order is wrong', (tester) async {
      final answers = await pump(tester);
      for (final item in [1, 0, 2]) {
        await _tap(tester, 'study.order.item.$item');
      }
      await _settle(tester, 500);
      await check(tester);
      expect(answers, [false]);
    });

    testWidgets('a bank row dragged onto a place goes there', (tester) async {
      await pump(tester);
      await drag(tester, 'study.order.item.2', tester.getCenter(_key('study.order.slot.1')));
      expect(_key('study.order.item.2'), findsNothing);
      expect(_key('study.order.place.0'), findsOneWidget, reason: 'With one place filled the thing takes the first');
      expect(_textIn(_key('study.order.place.0')), 'Third');
      await drag(tester, 'study.order.item.0', tester.getCenter(_key('study.order.slot.0')));
      expect(_textIn(_key('study.order.place.0')), 'First');
      expect(_textIn(_key('study.order.place.1')), 'Third', reason: 'The others make room');
    });

    testWidgets('a placed row dragged onto another place moves there', (tester) async {
      final answers = await pump(tester);
      for (final item in [1, 0, 2]) {
        await _tap(tester, 'study.order.item.$item');
      }
      await _settle(tester, 500);
      await drag(tester, 'study.order.place.0', tester.getCenter(_key('study.order.slot.1')));
      expect(_textIn(_key('study.order.place.0')), 'First');
      expect(_textIn(_key('study.order.place.1')), 'Second');
      expect(_textIn(_key('study.order.place.2')), 'Third');
      await check(tester);
      expect(answers, [true]);
    });

    testWidgets('a drag inside a body that scrolls moves the row, not the page', (tester) async {
      const order = StudyPathOrder(
        brief: {'en': 'Five things'},
        items: [
          {'en': 'One'},
          {'en': 'Two'},
          {'en': 'Three'},
          {'en': 'Four'},
          {'en': 'Five'},
        ],
        why: {'en': ''},
      );
      final harness = StudyHarness();
      await harness.pump(tester, StudyOrderStep(order: order, revealed: false, answer: (_) {}));
      tester.view.physicalSize = const Size(1206, 1800);
      await tester.pump();
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).first);
      expect(scrollable.position.maxScrollExtent, greaterThan(0), reason: 'The body must scroll for this test');
      final first = [
        0,
        1,
        2,
        3,
        4,
      ].reduce((a, b) => tester.getTopLeft(_key('study.order.item.$a')).dy < tester.getTopLeft(_key('study.order.item.$b')).dy ? a : b);
      await drag(tester, 'study.order.item.$first', tester.getCenter(_key('study.order.slot.0')));
      expect(scrollable.position.pixels, 0);
      expect(_textIn(_key('study.order.place.0')), order.items[first]['en']);
    });

    testWidgets('a row dropped outside the places goes back to the bank', (tester) async {
      await pump(tester);
      await _tap(tester, 'study.order.item.1');
      await _settle(tester, 500);
      await drag(tester, 'study.order.place.0', tester.getCenter(_key('study.order.place.0')) + const Offset(0, 1500));
      expect(_key('study.order.place.0'), findsNothing);
      expect(_key('study.order.item.1'), findsOneWidget);
    });

    testWidgets('after the answer each row shows right or wrong and Check is gone', (tester) async {
      final harness = StudyHarness();
      await harness.pump(tester, StudyOrderStep(order: _order, revealed: true, answer: (_) {}));
      expect(_key('study.check'), findsNothing);
      expect(find.text('Tap them in order, or drag them into place.'), findsNothing);
    });
  });

  group('StudySortStep', () {
    Future<void> sortAll(WidgetTester tester, {int wrongFirst = -1}) async {
      for (var turn = 0; _key('study.sort.item').evaluate().isNotEmpty; turn++) {
        final text = _textIn(_key('study.sort.item'));
        final right = _sort.items.firstWhere((item) => item.text['en'] == text).right;
        final bucket = turn == wrongFirst ? !right : right;
        await tester.tap(_key(bucket ? 'study.sort.right' : 'study.sort.left'));
        await _settle(tester, 1200);
      }
    }

    testWidgets('everything in its bucket is right', (tester) async {
      final harness = StudyHarness();
      bool? answered;
      await harness.pump(tester, StudySortStep(sort: _sort, revealed: false, answer: (right) => answered = right));
      expect(find.text('Lefty'), findsOneWidget);
      await sortAll(tester);
      await _settle(tester, 500);
      expect(answered, isTrue);
      for (final item in _sort.items) {
        final bucket = tester.getCenter(_key(item.right ? 'study.sort.right' : 'study.sort.left')).dx;
        expect(tester.getCenter(find.text(item.text['en']!)).dx, closeTo(bucket, 1));
      }
    });

    testWidgets('a wrong drop still ends in its own bucket, marked, and the answer is wrong', (tester) async {
      final harness = StudyHarness();
      bool? answered;
      await harness.pump(tester, StudySortStep(sort: _sort, revealed: false, answer: (right) => answered = right));
      final first = _textIn(_key('study.sort.item'));
      final right = _sort.items.firstWhere((item) => item.text['en'] == first).right;
      await tester.tap(_key(right ? 'study.sort.left' : 'study.sort.right'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(first), findsOneWidget, reason: 'The card shakes first and stays');
      await _settle(tester, 1200);
      final bucket = tester.getCenter(_key(right ? 'study.sort.right' : 'study.sort.left')).dx;
      expect(tester.getCenter(find.text(first)).dx, closeTo(bucket, 20), reason: 'Beside the x');
      expect(find.byIcon(CupertinoIcons.xmark_circle_fill), findsOneWidget);
      await sortAll(tester);
      await _settle(tester, 500);
      expect(answered, isFalse);
    });
  });
}
