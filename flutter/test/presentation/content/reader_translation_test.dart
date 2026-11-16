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

  test('zoomed reading places, merges and skips areas already read', () {
    TranslatedRegion region(double left, double top, {String text = 'x'}) => TranslatedRegion(text: text, left: left, top: top, width: 0.2, height: 0.1);
    const area = Rect.fromLTWH(0.5, 0.25, 0.5, 0.5);
    final placed = ZoomedText.place([region(0.2, 0.2), region(0.0, 0.4), region(0.8, 0.5)], area);
    expect(placed, hasLength(2), reason: 'Text cut by the left edge of a zoomed area is read from elsewhere');
    expect(placed.first.left, closeTo(0.6, 0.0001));
    expect(placed.first.top, closeTo(0.35, 0.0001));
    expect(placed.first.width, closeTo(0.1, 0.0001));
    expect(placed.last.left + placed.last.width, closeTo(1.0, 0.0001), reason: 'The image edge itself is not a cut');
    final merged = ZoomedText.merge([region(0.1, 0.1, text: 'A'), region(0.6, 0.6, text: 'B')], [region(0.65, 0.62, text: 'small')]);
    expect([for (final item in merged) item.text], ['A', 'small']);
    const zoomed = Rect.fromLTWH(0.2, 0.2, 0.4, 0.4);
    expect(ZoomedText.needsReading(zoomed, const []), isTrue);
    expect(ZoomedText.needsReading(const Rect.fromLTWH(0.25, 0.25, 0.35, 0.35), [zoomed]), isFalse, reason: 'Covered at a similar zoom');
    expect(ZoomedText.needsReading(const Rect.fromLTWH(0.3, 0.3, 0.1, 0.1), [zoomed]), isTrue, reason: 'Zooming further reads again');
    expect(ZoomedText.needsReading(const Rect.fromLTWH(0.5, 0.5, 0.4, 0.4), [zoomed]), isTrue, reason: 'Moving elsewhere reads again');
    const size = Size(400, 800);
    const image = Rect.fromLTWH(0, 100, 400, 600);
    expect(ZoomedText.visibleArea(Matrix4.identity(), size, image), isNull, reason: 'Not zoomed in');
    final twice = Matrix4.identity()..scaleByDouble(2, 2, 1, 1);
    final visible = ZoomedText.visibleArea(twice, size, image)!;
    expect(visible.left, closeTo(0, 0.0001));
    expect(visible.top, closeTo(0, 0.0001));
    expect(visible.width, closeTo(0.5, 0.0001));
    expect(visible.height, closeTo(300 / 600, 0.0001));
  });

  test('a zoom before the page is translated is read once it is, and keeps its balloons', () async {
    final source = FixtureContentSource();
    final gallery = await source.gallery(1001);
    final images = PageImageStore(source: source, allowsPrefetch: () => false);
    final session = ReaderTranslationSession(MemoryPreferences())..toggle();
    final page = gallery.pages[0];
    Future<Uint8List> load() => images.data(page, galleryID: gallery.id);
    const area = Rect.fromLTWH(0.5, 0.5, 0.4, 0.4);
    session.readZoomed(key: page.hash, index: 0, area: area, load: load);
    expect(calls, isEmpty, reason: 'The page-wide reading goes first');
    session.follow(gallery, index: 0, count: 1, images: images);
    await settle(session);
    for (var i = 0; i < 300 && session.isWorking(page.hash); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final balloons = session.balloons(page.hash)!;
    expect(balloons, hasLength(2), reason: 'The page-wide balloon and the one the zoom found');
    expect(balloons.last.left, closeTo(0.54, 0.0001));
    expect(balloons.last.top, closeTo(0.54, 0.0001));
    final read = calls.length;
    session.readZoomed(key: page.hash, index: 0, area: area, load: load);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(calls.length, read, reason: 'An area already read is not read again');
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
