// Ported from the guide and emphasis parts of native-ios/TEGNALTests/StudyTests.swift.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/study/study_guide.dart';
import 'package:tegnal/core/study/study_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => StudyGuide.useBundled(null));

  late StudyGuide guide;
  setUp(() => guide = StudyGuide.parse(File('assets/study/PromptGuide.json').readAsStringSync()));

  group('answer rows', () {
    test('two short neighbours share a line and a long one keeps its own', () {
      expect(StudyQuestion.rows([3, 4, 20, 5, 5, 5], limit: 13), [
        [0, 1],
        [2],
        [3, 4],
        [5],
      ]);
    });

    test('a long tag splits the pairs around it', () {
      expect(StudyQuestion.rows([5, 20, 5, 5], limit: 13), [
        [0],
        [1],
        [2, 3],
      ]);
    });

    test('the limit itself still pairs, and one more does not', () {
      expect(StudyQuestion.rows([13, 13], limit: 13), [
        [0, 1],
      ]);
      expect(StudyQuestion.rows([13, 14], limit: 13), [
        [0],
        [1],
      ]);
    });

    test('a wide layout pairs longer tags and a limit of zero pairs none', () {
      expect(StudyQuestion.rows([20, 22, 23, 4], limit: 22), [
        [0, 1],
        [2],
        [3],
      ]);
      expect(StudyQuestion.rows([1, 1, 1, 1], limit: 0), [
        [0],
        [1],
        [2],
        [3],
      ]);
    });

    test('no choices make no rows and an odd one out stands alone', () {
      expect(StudyQuestion.rows([], limit: 13), isEmpty);
      expect(StudyQuestion.rows([2, 2, 2], limit: 13), [
        [0, 1],
        [2],
      ]);
    });
  });

  group('emphasis', () {
    test('braces step by 1.05 for each pair, and brackets weaken', () {
      expect(StudyEmphasis.pairs(1.05), 1);
      expect(StudyEmphasis.pairs(1.1025), 2);
      expect(StudyEmphasis.pairs(1.2), 4);
      expect(StudyEmphasis.pairs(0.9), -2);
      expect(StudyEmphasis.pairs(1), 0);
      expect(StudyEmphasis.pairs(0), 0);
      expect(StudyEmphasis.braces.written('rain', weight: 1.05), '{rain}');
      expect(StudyEmphasis.braces.written('rain', weight: 1.1025), '{{rain}}');
      expect(StudyEmphasis.braces.written('rain', weight: 1.2), '{{{{rain}}}}');
      expect(StudyEmphasis.braces.written('rain', weight: 0.9), '[[rain]]');
      expect(StudyEmphasis.braces.written('rain', weight: 1.01), 'rain', reason: 'Less than half a step is no step');
    });

    test('a weight of one is written plainly and braces stop at twenty pairs', () {
      for (final kind in StudyEmphasis.values) {
        expect(kind.written('rain', weight: 1), 'rain');
        expect(kind.written('', weight: 1.5), '');
      }
      expect(StudyEmphasis.braces.written('rain', weight: 100), '${'{' * 20}rain${'}' * 20}');
    });

    test('the numbered form and the web UI form write the weight as a number', () {
      expect(StudyEmphasis.numbered.written('rain', weight: 1.5), '1.5::rain ::');
      expect(StudyEmphasis.weighted.written('rain', weight: 1.5), '(rain:1.5)');
      expect(StudyEmphasis.numbered.written('rain', weight: 0.8), '0.8::rain ::');
    });

    test('the web UI form escapes brackets that belong to a tag, the others leave them', () {
      expect(StudyEmphasis.weighted.written('hair (ornament)', weight: 1.2), r'(hair \(ornament\):1.2)');
      expect(StudyEmphasis.weighted.written('hair (ornament)', weight: 1), r'hair \(ornament\)');
      expect(StudyEmphasis.braces.written('hair (ornament)', weight: 1.05), '{hair (ornament)}');
      expect(StudyEmphasis.numbered.written('hair (ornament)', weight: 1.5), '1.5::hair (ornament) ::');
    });

    test('numbers lose trailing zeros and the point', () {
      expect(StudyEmphasis.number(1.2), '1.2');
      expect(StudyEmphasis.number(2), '2');
      expect(StudyEmphasis.number(0.5), '0.5');
      expect(StudyEmphasis.number(1.05), '1.05');
      expect(StudyEmphasis.number(1.1025), '1.1025');
      expect(StudyEmphasis.number(0.123456), '0.1235');
    });

    test('braces really give the nearest step and the others give what was asked', () {
      expect(StudyEmphasis.braces.effective(1.2), closeTo(1.2155, 0.0001));
      expect(StudyEmphasis.numbered.effective(1.2), 1.2);
      expect(StudyEmphasis.weighted.effective(1.2), 1.2);
    });
  });

  group('prompt guide', () {
    test('the file is the same as the iOS one and loads from the asset bundle', () async {
      final native = File('../native-ios/TEGNAL/PromptGuide.json');
      if (native.existsSync()) expect(File('assets/study/PromptGuide.json').readAsBytesSync(), native.readAsBytesSync());
      StudyGuide.useBundled(null);
      expect(StudyGuide.bundled.lessons, isEmpty, reason: 'Empty until loaded');
      final loaded = await StudyGuide.loadBundled();
      expect(loaded.lessons.length, guide.lessons.length);
      expect(StudyGuide.bundled.lessons.length, guide.lessons.length);
      expect(await StudyGuide.loadBundled(), same(loaded), reason: 'Read once');
      expect(() => StudyGuide.parse('not json'), throwsA(anything));
    });

    test('there are nine lessons with unique ids, and the month the sources were read', () {
      expect(guide.lessons.length, 9);
      expect(guide.lessons.map((lesson) => lesson.id).toSet().length, 9);
      expect(guide.checked, matches(RegExp(r'^\d{4}-\d{2}$')));
    });

    test('every title, summary, heading, body, note and question is written in English, Korean and Japanese', () {
      void complete(StudyText? text, String where) {
        if (text == null) return;
        for (final language in const ['en', 'ko', 'ja']) {
          expect((text[language] ?? '').trim(), isNotEmpty, reason: '$where in $language');
        }
      }

      for (final lesson in guide.lessons) {
        complete(lesson.title, '${lesson.id} title');
        complete(lesson.summary, '${lesson.id} summary');
        expect(lesson.symbol, isNotEmpty);
        expect(lesson.parts, isNotEmpty, reason: lesson.id);
        for (final part in lesson.parts) {
          complete(part.heading, '${lesson.id} heading');
          complete(part.body, '${lesson.id} body');
          expect(part.heading != null || part.body != null || part.examples.isNotEmpty, isTrue, reason: '${lesson.id} has an empty part');
          for (final example in part.examples) {
            expect(example.code, isNotEmpty);
            complete(example.note, '${lesson.id} note');
          }
        }
        for (final check in lesson.checks) {
          complete(check.question, '${lesson.id} question');
          complete(check.why, '${lesson.id} why');
        }
      }
    });

    test('every answer is one of its choices, and a question offers at least two', () {
      var questions = 0;
      for (final lesson in guide.lessons) {
        for (final check in lesson.checks) {
          questions += 1;
          expect(check.choices.length, greaterThanOrEqualTo(2), reason: lesson.id);
          expect(check.answer, inInclusiveRange(0, check.choices.length - 1), reason: lesson.id);
        }
      }
      expect(questions, greaterThan(0));
    });

    test('a lesson with a tool names one the app has, and sources are web addresses', () {
      for (final lesson in guide.lessons) {
        expect(lesson.tool, anyOf(isNull, 'emphasis'), reason: lesson.id);
        for (final source in lesson.sources) {
          expect(Uri.parse(source).scheme, 'https', reason: source);
        }
      }
      expect(guide.lessons.where((lesson) => lesson.tool == 'emphasis'), isNotEmpty);
    });

    test('backticks in a body come in pairs', () {
      for (final lesson in guide.lessons) {
        for (final part in lesson.parts) {
          for (final text in [...?part.body?.values, ...?part.heading?.values]) {
            expect('`'.allMatches(text).length.isEven, isTrue, reason: '${lesson.id}: $text');
          }
        }
      }
    });

    test('finished lessons are kept as sorted ids joined by commas', () {
      expect(StudyGuide.finished(''), isEmpty);
      expect(StudyGuide.finished('basics,quality'), {'basics', 'quality'});
      expect(StudyGuide.finishing('quality', stored: ''), 'quality');
      expect(StudyGuide.finishing('basics', stored: 'quality'), 'basics,quality');
      expect(StudyGuide.finishing('basics', stored: 'basics,quality'), 'basics,quality');
      expect(StudyGuide.finishedKey, 'study.guideFinished');
    });
  });
}
