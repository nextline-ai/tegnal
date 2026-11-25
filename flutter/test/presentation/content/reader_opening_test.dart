import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/content_environment.dart';
import 'package:tegnal/core/content/fixture_content_source.dart';
import 'package:tegnal/core/content/gallery_content.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/support/l10n.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/presentation/content/page_image_store.dart';
import 'package:tegnal/presentation/content/reader_models.dart';
import 'package:tegnal/presentation/content/reader_view.dart';

void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(WidgetTester tester, {required int page, required Preferences preferences, bool resumes = true}) async {
    final source = FixtureContentSource();
    await tester.pumpWidget(
      CupertinoApp(
        home: Builder(
          builder: (context) => CupertinoButton(
            child: const Text('open'),
            onPressed: () => openReader(
              context,
              galleryID: 1,
              initialPage: page,
              source: source,
              images: _Images(source),
              content: ContentEnvironment(browserPreferences: preferences, source: source),
              database: AppDatabase.inMemory(),
              preferences: preferences,
              resumesProgress: resumes,
              bookmark: (_) async {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester);
  }

  double offset(WidgetTester tester) => tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels;

  MemoryPreferences preferences({String mode = 'horizontal', int saved = 0}) => MemoryPreferences()
    ..set('reader.mode', mode)
    ..set('reader.pageNumber', true)
    ..set(ReaderLayout.pagesKey, 1)
    ..set('reader_page_1', saved);

  testWidgets('the resume prompt puts Cancel on the left, as the native alert does', (tester) async {
    L10n.table = {'Cancel': '취소', 'Continue Reading': '계속 읽기'};
    addTearDown(() => L10n.table = const {});
    await open(tester, page: 1, preferences: preferences(saved: 3));
    final cancel = tester.getCenter(find.text('취소'));
    final resume = tester.getCenter(find.text('계속 읽기'));
    expect(cancel.dy, resume.dy);
    expect(cancel.dx, lessThan(resume.dx));
  });

  testWidgets('Continue Reading turns to the saved page in paged mode', (tester) async {
    await open(tester, page: 1, preferences: preferences(saved: 3));
    await tester.tap(find.text('Continue Reading'));
    await settle(tester);
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 2);
    expect(find.text('3 / 3'), findsOneWidget);
  });

  testWidgets('Continue Reading scrolls to the saved page in continuous scroll', (tester) async {
    await open(tester, page: 1, preferences: preferences(mode: 'continuous', saved: 3));
    expect(offset(tester), 0);
    await tester.tap(find.text('Continue Reading'));
    await settle(tester);
    expect(offset(tester), greaterThan(0));
    expect(find.text('3 / 3'), findsOneWidget);
  });

  testWidgets('a page chosen in previews opens there in continuous scroll', (tester) async {
    await open(tester, page: 2, preferences: preferences(mode: 'continuous'), resumes: false);
    expect(offset(tester), greaterThan(0));
    expect(find.text('2 / 3'), findsOneWidget);
  });
}

/// The resume prompt waits for the first page; a test page fails at once instead.
class _Images extends PageImageStore {
  _Images(FixtureContentSource source) : super(source: source);
  @override
  Future<ui.Image> load(GalleryPage page, {required int galleryID, bool thumbnail = false}) => Future.error(StateError('no image'));
}
