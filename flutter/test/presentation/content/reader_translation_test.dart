// Translation mode from native-ios/TEGNAL/Presentation/Content/ReaderPageTranslation.swift: the
// visible spread first, then the next, each page carrying the lines of the pages before it.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/fixture_content_source.dart';
import 'package:tegnal/core/content/gallery_content.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/presentation/content/image_translation.dart';
import 'package:tegnal/presentation/content/page_image_store.dart';
import 'package:tegnal/presentation/content/reader_models.dart';
import 'package:tegnal/presentation/content/reader_translation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const translation = MethodChannel('work.nextline.tegnal/translation');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory cache;
  late List<Map<Object?, Object?>> calls;
  late List<Map<Object?, Object?>> refines;
  late Map<int, String> failures;
  late String aiStatus;

  setUp(() {
    cache = Directory.systemTemp.createTempSync('reader-translation');
    calls = [];
    refines = [];
    failures = {};
    aiStatus = AITranslationModel.available;
    AITranslationModel.status = AITranslationModel.available;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (call) async => cache.path);
    messenger.setMockMethodCallHandler(translation, (call) async {
      final arguments = call.arguments as Map<Object?, Object?>;
      if (call.method == 'aiStatus') return aiStatus;
      if (call.method == 'refine') {
        refines.add(arguments);
        return ['AI ${refines.length}'];
      }
      calls.add(arguments);
      final page = calls.length;
      if (failures[page] case final code?) throw PlatformException(code: code);
      return {
        'regions': [
          {'text': '번역 $page', 'source': 'line $page', 'left': 0.1, 'top': 0.1, 'width': 0.3, 'height': 0.1},
        ],
      };
    });
  });

  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(translation, null);
    cache.deleteSync(recursive: true);
  });

  Future<void> settle(ReaderTranslationSession session) async {
    for (var i = 0; i < 200 && session.isWorkingAny; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('translation mode shows the quick translation, then the AI reading with earlier lines', () async {
    final source = FixtureContentSource();
    final gallery = await source.gallery(1001);
    final images = PageImageStore(source: source, allowsPrefetch: () => false);
    final session = ReaderTranslationSession(MemoryPreferences());
    session.follow(gallery, index: 0, count: 1, images: images);
    expect(calls, isEmpty, reason: 'Nothing translates until the mode is on');

    session.toggle();
    session.follow(gallery, index: 0, count: 1, images: images);
    await settle(session);
    expect(calls, hasLength(2), reason: 'The visible page, then the next');
    expect(calls.first['language'], gallery.language, reason: "The work's language picks the recognizer");
    expect(session.balloons(gallery.pages[0].hash)?.single.text, 'AI 1', reason: "The AI model's reading replaces the quick translation");
    expect(refines.first['lines'], ['line 1']);
    expect(refines[1]['context'], [
      {'source': 'line 1', 'translation': 'AI 1'},
    ], reason: 'The next page reads on from the one before');

    session.toggleOriginal();
    expect(session.balloons(gallery.pages[0].hash), isNull, reason: 'The pill shows the original again');
    session.toggleOriginal();

    session.stop();
    expect(session.balloons(gallery.pages[0].hash), isNull);
  });

  test('a page without text is quiet; a real failure is reported once', () async {
    final source = FixtureContentSource();
    final gallery = await source.gallery(1001);
    final images = PageImageStore(source: source, allowsPrefetch: () => false);
    final session = ReaderTranslationSession(MemoryPreferences())..toggle();
    failures[1] = 'noText';
    failures[2] = 'download';
    session.follow(gallery, index: 0, count: 1, images: images);
    await settle(session);
    expect(session.balloons(gallery.pages[0].hash), isEmpty);
    expect(session.message, isNotNull);
  });

  test('AI translation style keeps text readable and opacity in range', () {
    const plain = TranslationStyle();
    expect(plain.fill, const Color(0xFFFFFFFF));
    expect(plain.text, const Color(0xFF000000));
    final preferences = MemoryPreferences({TranslationStyle.backgroundKey: 'black', TranslationStyle.opacityKey: 0.1});
    final dark = TranslationStyle.stored(preferences);
    expect(dark.opacity, TranslationStyle.minimumOpacity, reason: 'Too clear to read is raised to the lowest allowed');
    expect(dark.text, const Color(0xFFFFFFFF), reason: 'Text turns white on black');
    final unknown = TranslationStyle.stored(MemoryPreferences({TranslationStyle.backgroundKey: 'unknown', TranslationStyle.opacityKey: 2}));
    expect(unknown.background, TranslationBackground.white);
    expect(unknown.opacity, 1);
  });

  test('preferred language follows the system among work languages', () {
    expect(PreferredWorkLanguage.systemLanguage('ko-KR'), 'korean');
    expect(PreferredWorkLanguage.systemLanguage('ja'), 'japanese');
    expect(PreferredWorkLanguage.systemLanguage('en-US'), 'english');
    expect(PreferredWorkLanguage.systemLanguage('fr_FR'), 'english', reason: 'Other system languages fall back to English');
  });

  test('without the AI model the quick translation stays and AI translation cannot be on', () async {
    aiStatus = AITranslationModel.unavailable;
    AITranslationModel.status = AITranslationModel.unavailable;
    final source = FixtureContentSource();
    final gallery = await source.gallery(1001);
    final images = PageImageStore(source: source, allowsPrefetch: () => false);
    final session = ReaderTranslationSession(MemoryPreferences())..toggle();
    session.follow(gallery, index: 0, count: 1, images: images);
    await settle(session);
    expect(session.balloons(gallery.pages[0].hash)?.single.text, '번역 1');
    expect(refines, isEmpty);
    expect(ReaderPreferences.continuousTranslation, isFalse, reason: 'Off without the model, whatever was chosen');
  });
}
