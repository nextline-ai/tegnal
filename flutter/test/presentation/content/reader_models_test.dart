// Reader logic from native-ios/TEGNALTests/ReaderUXTests.swift.
// Not ported here, because they drive real UIKit views, gestures or screens:
// - testInterruptedExitCancellationCannotResetTheNextDrag: a cancelled pull-down's spring-back must not
//   move the next drag (ReaderExitMotion on a UIView). Screen: restart the drag offset at 0 on a new drag.
// - testImageExitChoosesTheWholeNavigationContainer: the image viewer's pull moves its whole navigation
//   container, not the inner page. Screen: move the whole viewer route while dragging.
// - testExitGestureOwnsScrollingAndWorkSwipesStayWithinTheCurrentList (gesture half): the pull-down
//   waits for page scrolling to fail and never runs with it. The neighbor half is ported below.
// - testEmptyMetadataReservesAFullLineAndScalesWithTextSize: an empty metadata row keeps a 22 pt line
//   that grows with the text size.
// - testResumePromptLoadsTheWorkAndFirstPageBeforeAsking: "Continue Reading?" appears only after the
//   work and its first page have loaded, and the saved page stays until the choice.
// - testCachedReaderPersistsExplicitStartingPageWithoutTurningAndResumesThere: opening a cached work at
//   an explicit page (e.g. 5 from a preview) saves that page at once, so a normal reopen resumes there.
// - testGalleryHeadingAndActionSizingKeepTheButtonPositionStable: the title always reserves two lines and
//   the Read and Save buttons are 1.25× their natural height.
// - testSamePageResolutionUpgradePreservesZoomAndViewport, testPageImageReplacementRecomputesAspectFit…,
//   testShortZoomedPageHasVerticalSpace…, testTwoZoomedPagesKeepTheirSharedPagerLocked, the four
//   testPager… tests: zoom and paging behavior of the page views.
// - Translation, Live Text and Mac tests (Apple frameworks), and testChunkedTransportEnforcesBodyLimitAndStatus
//   (URLSession; the transport is covered in test/core/content).
import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/gallery_content.dart';
import 'package:tegnal/core/content/manga_urls.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/taste/taste_models.dart';
import 'package:tegnal/presentation/content/reader_models.dart';

void main() {
  test('reader guide matches the modes gesture settings without changing reading progress', () {
    final defaults = MemoryPreferences();
    defaults.set('reader_page_101', 23);
    final paged = ReaderGuideConfiguration(booru: false, defaults: defaults);
    expect(paged.tapNavigation, isTrue);
    expect(paged.informationSwipe, isTrue);
    expect(paged.continuous, isFalse);
    expect(paged.vertical, isFalse);
    defaults.set('reader.mode', 'continuous');
    defaults.set('reader.rtl', true);
    defaults.set('reader.tapNavigation', false);
    final continuous = ReaderGuideConfiguration(booru: false, defaults: defaults);
    expect(continuous.continuous, isTrue);
    expect(continuous.vertical, isTrue);
    expect(continuous.rtl, isTrue);
    expect(continuous.tapNavigation, isFalse);
    expect(continuous.informationSwipe, isFalse);
    defaults.set('reader.continuousPreviewSwipe', true);
    expect(ReaderGuideConfiguration(booru: false, defaults: defaults).informationSwipe, isTrue);
    final image = ReaderGuideConfiguration(booru: true, defaults: defaults);
    expect(image.continuous, isFalse);
    expect(image.vertical, isFalse);
    expect(image.informationSwipe, isTrue);
    expect(defaults.integer('reader_page_101'), 23);
    expect(defaults.object('reader.helpHidden'), isNull, reason: 'Reading the guide configuration does not mark it completed');
  });

  test('reader coach advances from real menu and finishes without reopening', () {
    final session = ReaderGuideSession();
    expect(session.step, isNull);
    expect(session.hasStarted, isFalse);
    session.openedMenu();
    expect(session.step, isNull);
    session.start();
    expect(session.step, ReaderGuideStep.navigation);
    session.openedMenu();
    expect(session.step, ReaderGuideStep.tools);
    session.openedMenu();
    expect(session.step, ReaderGuideStep.tools);
    session.advance();
    expect(session.step, ReaderGuideStep.exit);
    session.finish();
    expect(session.step, isNull);
    expect(session.hasStarted, isTrue);
    session.openedMenu();
    expect(session.step, isNull);
    session.start();
    expect(session.step, ReaderGuideStep.navigation, reason: 'Settings can replay the overlay');
    session
      ..advance()
      ..advance()
      ..advance();
    expect(session.step, isNull);
  });

  test('manga return finds only the last viewed visible work without reloading the list', () {
    var examined = 0;
    final loaded = [for (var id = 1; id <= 200; id++) id].map((id) {
      examined += 1;
      return id;
    });
    expect(MangaViewerReturn.targetID(openedID: 10, viewedID: 10, availableIDs: loaded), isNull);
    expect(MangaViewerReturn.targetID(openedID: null, viewedID: 10, availableIDs: loaded), isNull);
    expect(examined, 0, reason: 'An unchanged work must preserve the exact scroll offset without scanning the list');
    expect(MangaViewerReturn.targetID(openedID: 10, viewedID: 175, availableIDs: loaded), 175);
    expect(examined, 175, reason: 'Stop scanning as soon as the last viewed work is found');
    expect(MangaViewerReturn.targetID(openedID: 10, viewedID: 201, availableIDs: loaded), isNull);
    expect(
      MangaViewerReturn.targetID(openedID: 10, viewedID: 175, availableIDs: loaded.where((id) => id != 175)),
      isNull,
      reason: 'A removed or hidden work must not jump to an unrelated row',
    );
  });

  test('exit reversal cancels even while still beyond the dismissal threshold', () {
    final intent = ReaderExitIntent()..update(180);
    expect(intent.shouldFinish(delta: const Offset(0, 180), velocity: Offset.zero), isTrue);
    intent.update(172);
    expect(intent.reversed, isTrue);
    expect(intent.shouldFinish(delta: const Offset(0, 172), velocity: const Offset(0, 100)), isFalse);
    intent.update(200);
    expect(intent.shouldFinish(delta: const Offset(0, 200), velocity: const Offset(0, 800)), isFalse);
    final steady = ReaderExitIntent()
      ..update(180)
      ..update(177);
    expect(
      steady.shouldFinish(delta: const Offset(0, 177), velocity: Offset.zero),
      isTrue,
      reason: 'Small touch noise should not cancel a deliberate pull',
    );
    expect(
      steady.shouldFinish(delta: const Offset(0, 177), velocity: const Offset(0, -1)),
      isFalse,
      reason: 'Releasing upward must never dismiss',
    );
  });

  test('back swipe uses the leading safe area and is off by default', () {
    const bounds = Rect.fromLTWH(0, 0, 800, 400);
    bool leading(Offset point) => ReaderHorizontalSwipe.isLeadingStart(point, bounds, safeLeft: 50, safeTop: 20, safeRight: 50, safeBottom: 20);
    expect(leading(const Offset(65, 100)), isTrue);
    expect(leading(const Offset(20, 100)), isFalse);
    expect(leading(const Offset(65, 10)), isFalse);
    expect(leading(const Offset(160, 100)), isFalse);
    expect(ReaderHorizontalSwipe.direction(delta: const Offset(120, 10), backOnly: true), -1);
    expect(ReaderHorizontalSwipe.direction(delta: const Offset(-120, 10), backOnly: true), isNull);
    expect(ReaderHorizontalSwipe.direction(delta: const Offset(120, 100), backOnly: true), isNull);
    final defaults = MemoryPreferences();
    expect(ReaderSettings(defaults).continuousBackSwipe, isFalse);
    defaults.set('reader.continuousBackSwipe', true);
    ReaderPreferenceReset.reset(booru: false, defaults: defaults);
    expect(defaults.boolean('reader.continuousBackSwipe') ?? false, isFalse);
  });

  test('work swipes stay within the current list', () {
    expect(MangaReaderSequence.neighbor(20, delta: 1, ids: [10, 20, 30]), 30);
    expect(MangaReaderSequence.neighbor(20, delta: -1, ids: [10, 20, 30]), 10);
    expect(MangaReaderSequence.neighbor(30, delta: 1, ids: [10, 20, 30]), isNull);
    expect(MangaReaderSequence.neighbor(99, delta: -1, ids: [10, 20, 30]), isNull);
  });

  test('viewer reset preserves progress connections and other mode options', () {
    final preferences = MemoryPreferences();
    preferences.set('reader.mode', 'continuous');
    preferences.set('reader.continuousWorkSwipe', true);
    preferences.set('reader_page_101', 42);
    preferences.set('manga_site_address', 'https://example.com');
    preferences.set('booru.showNotes', false);
    ReaderPreferenceReset.reset(booru: false, defaults: preferences);
    expect(preferences.object('reader.mode'), isNull);
    expect(preferences.object('reader.continuousWorkSwipe'), isNull);
    expect(preferences.integer('reader_page_101'), 42);
    expect(preferences.string('manga_site_address'), 'https://example.com');
    expect(preferences.boolean('booru.showNotes'), false);
    ReaderPreferenceReset.reset(booru: true, defaults: preferences);
    expect(preferences.object('booru.showNotes'), isNull);
  });

  test('continuous information swipe defaults off and paged modes remain enabled', () {
    final defaults = MemoryPreferences();
    bool optIn() => defaults.boolean('reader.continuousPreviewSwipe') ?? false;
    expect(ReaderInformationReveal.isEnabled(mode: ReaderMode.continuous.rawValue, continuousOptIn: optIn()), isFalse);
    for (final mode in [ReaderMode.horizontal, ReaderMode.vertical]) {
      for (final value in [false, true]) {
        expect(ReaderInformationReveal.isEnabled(mode: mode.rawValue, continuousOptIn: value), isTrue);
      }
    }
    defaults.set('reader.continuousPreviewSwipe', true);
    expect(ReaderInformationReveal.isEnabled(mode: ReaderMode.continuous.rawValue, continuousOptIn: optIn()), isTrue);
    defaults.set('reader.continuousPreviewSwipe', false);
    expect(ReaderInformationReveal.isEnabled(mode: ReaderMode.continuous.rawValue, continuousOptIn: optIn()), isFalse);
  });

  test('manga thumbnails default to reader and information opt-in retains discovery', () {
    final defaults = MemoryPreferences();
    final context = DiscoveryContext(origin: DiscoveryOrigin.recommendation, query: 'artist:sample', session: 'thumbnail-opening-test');
    final opening = MangaThumbnailOpening.stored(defaults);
    expect(opening, MangaThumbnailOpening.viewer);
    expect(opening.route(12345, context), DiscoveredReaderRoute(12345, 1, context));
    expect(opening.url(12345), MangaUrls.readerUrl(12345));
    defaults.set(MangaThumbnailOpening.preferenceKey, true);
    final information = MangaThumbnailOpening.stored(defaults);
    expect(information, MangaThumbnailOpening.information);
    expect(information.route(12345, context), DiscoveredGalleryRoute(12345, context));
    expect(information.url(12345), MangaUrls.galleryUrl(12345));
    defaults.set(MangaThumbnailOpening.preferenceKey, false);
    expect(MangaThumbnailOpening.stored(defaults).route(12345, context), DiscoveredReaderRoute(12345, 1, context));
  });

  test('reader resume choices preserve explicit pages and default to confirmation', () {
    final defaults = MemoryPreferences();
    expect(ReaderResumeBehavior.stored(defaults), ReaderResumeBehavior.ask);
    defaults.set('reader.resumeBehavior', 'unknown');
    expect(ReaderResumeBehavior.stored(defaults), ReaderResumeBehavior.ask);
    for (final behavior in ReaderResumeBehavior.values) {
      expect(behavior.opening(initial: 5, saved: 20, resumesProgress: true), const ReaderOpening.page(5));
      expect(behavior.opening(initial: 1, saved: 20, resumesProgress: false), const ReaderOpening.page(1));
      expect(behavior.opening(initial: 1, saved: 0, resumesProgress: true), const ReaderOpening.page(1));
    }
    expect(ReaderResumeBehavior.ask.opening(initial: 1, saved: 20, resumesProgress: true), const ReaderOpening.confirmation(20));
    expect(ReaderResumeBehavior.ask.opening(initial: 1, saved: 1, resumesProgress: true), const ReaderOpening.confirmation(1));
    expect(ReaderResumeBehavior.continueReading.opening(initial: 1, saved: 20, resumesProgress: true), const ReaderOpening.page(20));
    expect(ReaderResumeBehavior.fromBeginning.opening(initial: 1, saved: 20, resumesProgress: true), const ReaderOpening.page(1));
    const pending = ReaderOpening.confirmation(20);
    expect(pending.initialPage, 1);
    expect(pending.resolved(continuing: false), const ReaderOpening.page(1));
    expect(pending.resolved(continuing: true), const ReaderOpening.page(20));
  });

  test('information reveal requires an upward bottom swipe', () {
    const bounds = Rect.fromLTWH(0, 0, 390, 844);
    expect(ReaderInformationReveal.isInZone(const Offset(195, 740), bounds), isTrue);
    expect(ReaderInformationReveal.isInZone(const Offset(195, 420), bounds), isFalse);
    expect(ReaderInformationReveal.isInZone(const Offset(500, 740), bounds), isFalse);
    expect(ReaderInformationReveal.shouldReveal(delta: const Offset(5, -120), velocity: Offset.zero), isTrue);
    expect(ReaderInformationReveal.shouldReveal(delta: const Offset(5, -30), velocity: const Offset(0, -700)), isTrue);
    expect(ReaderInformationReveal.shouldReveal(delta: const Offset(5, -12), velocity: const Offset(0, -700)), isFalse);
    expect(ReaderInformationReveal.shouldReveal(delta: const Offset(5, 120), velocity: Offset.zero), isFalse);
    expect(ReaderInformationReveal.shouldReveal(delta: const Offset(120, -80), velocity: Offset.zero), isFalse);
  });

  test('exit recognizes short flick and rejects accidental drags', () {
    expect(ReaderDismissal.shouldExit(delta: const Offset(8, 110), velocity: Offset.zero), isTrue);
    expect(ReaderDismissal.shouldExit(delta: const Offset(2, 30), velocity: const Offset(0, 700)), isTrue);
    expect(ReaderDismissal.shouldExit(delta: const Offset(2, 30), velocity: const Offset(0, 100)), isFalse);
    expect(ReaderDismissal.shouldExit(delta: const Offset(120, 80), velocity: const Offset(800, 600)), isFalse);
    expect(ReaderDismissal.shouldExit(delta: const Offset(0, -120), velocity: const Offset(0, -800)), isFalse);
  });

  test('continuous scroll dismissal starts only at the top handle', () {
    const bounds = Rect.fromLTWH(0, 0, 390, 844);
    expect(ReaderDismissal.isInExitZone(const Offset(195, 60), bounds, safeTop: 47), isTrue);
    expect(ReaderDismissal.isInExitZone(const Offset(195, 400), bounds, safeTop: 47), isFalse);
    expect(ReaderDismissal.isInExitZone(const Offset(195, 30), bounds, safeTop: 47), isFalse);
    expect(ReaderDismissal.isInExitZone(const Offset(195, 112), bounds, safeTop: 47), isFalse);
  });

  test('reader initial page matches resume and spread rules', () {
    expect(ReaderLayout.initialPage(1, saved: 7, total: 10, count: 2), 6);
    expect(ReaderLayout.initialPage(4, saved: 9, total: 10, count: 2), 2);
    expect(ReaderLayout.initialPage(100, saved: 0, total: 5, count: 2), 4);
    expect(ReaderLayout.initialPage(-9223372036854775808, saved: 0, total: 5, count: 0), 0);
    expect(ReaderLayout.initialPage(5, saved: 0, total: 0, count: 2), 0);
  });

  test('reading progress is kept per work under the native key', () {
    final defaults = MemoryPreferences();
    expect(ReaderProgress.saved(7, defaults: defaults), 0);
    ReaderProgress.save(7, 12, defaults: defaults);
    expect(defaults.integer('reader_page_7'), 12);
    expect(ReaderProgress.saved(7, defaults: defaults), 12);
  });
}
