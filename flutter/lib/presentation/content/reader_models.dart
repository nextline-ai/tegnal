import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart' show ValueNotifier;

import '../../core/content/gallery_content.dart';
import '../../core/content/manga_urls.dart';
import '../../core/support/l10n.dart';
import '../../core/support/preferences.dart';
import '../../core/taste/taste_models.dart';

/// The reader's two preference stores: comics options live in the standard
/// defaults, image-mode options in their own store (`ReaderPreferences`).
abstract final class ReaderPreferences {
  /// Comics reader options and reading progress (`ReaderPreferences.defaults`).
  static Preferences get defaults => ContentPreferences.defaults;

  static const doubleTapZoomKey = 'reader.doubleTapZoom';

  /// Comics pages zoom on a double tap unless a person turned it off.
  static bool get doubleTapZooms => defaults.boolean(doubleTapZoomKey) ?? true;

  static const continuousTranslationKey = 'reader.continuousTranslation';

  /// Off by default: Translate shows one translated page. On, translation stays on while pages
  /// turn and the on-device model reads each page with the ones before it.
  static bool get continuousTranslation => defaults.boolean(continuousTranslationKey) ?? false;

  /// Image-mode viewer options, installed at launch from `AppPreferences.booruDefaults`.
  static Preferences booruDefaults = MemoryPreferences();

  static void install(AppPreferences preferences) => booruDefaults = preferences.booruDefaults;
}

/// Preference keys and native defaults of the viewer settings.
abstract final class ReaderSettingKeys {
  static const resumeBehavior = 'reader.resumeBehavior';
  static const reducedData = 'booru.reducedData'; // false, image mode
  static const original = 'booru.original'; // false, image mode
  static const showNotes = 'booru.showNotes'; // true, image mode
  static const pagesPerSpread = 'reader.pagesPerSpread'; // 1
  static const autoAdvance = 'reader.autoAdvance'; // false
  static const autoSeconds = 'reader.autoSeconds'; // 10.0, 2...120
  static const mode = 'reader.mode'; // horizontal
  static const rtl = 'reader.rtl'; // false
  static const bottomMenu = 'reader.bottomMenu'; // false
  static const pageNumber = 'reader.pageNumber'; // false
  static const keepAwake = 'reader.keepAwake'; // true
  static const prefetch = 'reader.prefetch'; // 3; 0, 2, 3 or 5
  static const dimming = 'reader.dimming'; // 0.0, 0...0.65
  static const tapNavigation = 'reader.tapNavigation'; // true
  static const doubleTapZoom = 'reader.doubleTapZoom'; // true
  static const continuousBackSwipe = 'reader.continuousBackSwipe'; // false
  static const continuousWorkSwipe = 'reader.continuousWorkSwipe'; // false
  static const continuousPreviewSwipe = 'reader.continuousPreviewSwipe'; // false
  static const helpHidden = 'reader.helpHidden'; // false
  static const translationLanguage = 'reader.translationLanguage';
}

/// The viewer settings with their native defaults, read from one store.
class ReaderSettings {
  ReaderSettings(this.defaults);
  final Preferences defaults;

  double _number(String key, double fallback) {
    final value = defaults.object(key);
    return value is num ? value.toDouble() : fallback;
  }

  ReaderResumeBehavior get resumeBehavior => ReaderResumeBehavior.stored(defaults);
  int get pagesPerSpread => defaults.integerOrNull(ReaderSettingKeys.pagesPerSpread) ?? 1;
  bool get autoAdvance => defaults.boolean(ReaderSettingKeys.autoAdvance) ?? false;
  double get autoSeconds => _number(ReaderSettingKeys.autoSeconds, 10);
  ReaderMode get mode => ReaderMode.fromRawValue(defaults.string(ReaderSettingKeys.mode)) ?? ReaderMode.horizontal;
  bool get rtl => defaults.boolean(ReaderSettingKeys.rtl) ?? false;
  bool get bottomMenu => defaults.boolean(ReaderSettingKeys.bottomMenu) ?? false;
  bool get pageNumber => defaults.boolean(ReaderSettingKeys.pageNumber) ?? false;
  bool get keepAwake => defaults.boolean(ReaderSettingKeys.keepAwake) ?? true;
  int get prefetch => defaults.integerOrNull(ReaderSettingKeys.prefetch) ?? 3;
  double get dimming => _number(ReaderSettingKeys.dimming, 0);
  bool get tapNavigation => defaults.boolean(ReaderSettingKeys.tapNavigation) ?? true;
  bool get continuousBackSwipe => defaults.boolean(ReaderSettingKeys.continuousBackSwipe) ?? false;
  bool get continuousWorkSwipe => defaults.boolean(ReaderSettingKeys.continuousWorkSwipe) ?? false;
  bool get continuousPreviewSwipe => defaults.boolean(ReaderSettingKeys.continuousPreviewSwipe) ?? false;
  bool get helpHidden => defaults.boolean(ReaderSettingKeys.helpHidden) ?? false;
  bool get reducedData => defaults.boolean(ReaderSettingKeys.reducedData) ?? false;
  bool get original => defaults.boolean(ReaderSettingKeys.original) ?? false;
  bool get showNotes => defaults.boolean(ReaderSettingKeys.showNotes) ?? true;
}

/// "Reset Viewer Settings": removes the viewer options only, never progress or connections.
abstract final class ReaderPreferenceReset {
  static const keys = [
    'reader.resumeBehavior', 'reader.pagesPerSpread', 'reader.autoAdvance', 'reader.autoSeconds', 'reader.mode', 'reader.rtl', //
    'reader.bottomMenu', 'reader.pageNumber', 'reader.keepAwake', 'reader.prefetch', 'reader.dimming', 'reader.tapNavigation', //
    'reader.doubleTapZoom',
    'reader.continuousTranslation',
    'reader.continuousPreviewSwipe',
    'reader.continuousWorkSwipe',
    'reader.continuousBackSwipe',
    'reader.helpHidden', //
    'reader.translationLanguage',
  ];

  static void reset({required bool booru, Preferences? defaults}) {
    final store = defaults ?? (booru ? ReaderPreferences.booruDefaults : ReaderPreferences.defaults);
    for (final key in [
      ...keys,
      if (booru) ...['booru.original', 'booru.reducedData', 'booru.showNotes'],
    ]) {
      store.remove(key);
    }
  }
}

/// The last page read in each work, one-based, under `reader_page_<id>`.
abstract final class ReaderProgress {
  static String key(int galleryID) => 'reader_page_$galleryID';
  static int saved(int galleryID, {Preferences? defaults}) => (defaults ?? ReaderPreferences.defaults).integer(key(galleryID));
  static void save(int galleryID, int page, {Preferences? defaults}) => (defaults ?? ReaderPreferences.defaults).set(key(galleryID), page);
}

enum ReaderMode {
  horizontal,
  vertical,
  continuous;

  String get rawValue => name;
  static ReaderMode? fromRawValue(String? value) => values.where((mode) => mode.name == value).firstOrNull;

  String get title => switch (this) {
    horizontal => L10n.text('Horizontal Paging'),
    vertical => L10n.text('Vertical Paging'),
    continuous => L10n.text('Continuous Scroll'),
  };
}

/// What tapping a comics thumbnail opens: the viewer, or work information first.
enum MangaThumbnailOpening {
  viewer,
  information;

  static const preferenceKey = 'manga.showInformationBeforeReading';

  static MangaThumbnailOpening stored([Preferences? defaults]) =>
      ((defaults ?? ReaderPreferences.defaults).boolean(preferenceKey) ?? false) ? information : viewer;

  ContentRoute route(int id, DiscoveryContext context) => this == information ? DiscoveredGalleryRoute(id, context) : DiscoveredReaderRoute(id, 1, context);

  String url(int id) => this == information ? MangaUrls.galleryUrl(id) : MangaUrls.readerUrl(id);
}

/// What a thumbnail does for each gesture, chosen in Settings for each mode. A comic opens on a
/// tap, joins Up Next on a double tap and is bookmarked on a hold; an image opens on a tap, does
/// nothing on a double tap and is added to favorites on a hold, unless changed.
enum ThumbnailAction {
  open,
  details,
  bookmark,
  upNext,
  favorite,
  folder,
  none;

  String get title => switch (this) {
    open => L10n.text('Open'),
    details => L10n.text('Work Details'),
    bookmark => L10n.text('Bookmark'),
    upNext => L10n.text('Add to Up Next'),
    favorite => L10n.text('Favorite'),
    folder => L10n.text('Save to Folder'),
    none => L10n.text('No Action'),
  };
}

enum ThumbnailGesture {
  tap,
  doubleTap,
  hold;

  String get title => switch (this) {
    tap => L10n.text('Tap'),
    doubleTap => L10n.text('Double Tap'),
    hold => L10n.text('Touch and Hold'),
  };

  /// Comics keep theirs with the reader's options; image mode keeps its own.
  String key({bool booru = false}) => '${booru ? 'booru' : 'manga'}.gesture.$name';
  static Preferences store({bool booru = false}) => booru ? ReaderPreferences.booruDefaults : ReaderPreferences.defaults;

  /// Ticks when a gesture's action changes, so thumbnails on screen pick it up.
  static final changes = ValueNotifier<int>(0);

  ThumbnailAction standard({bool booru = false}) => switch (this) {
    tap => ThumbnailAction.open,
    doubleTap => booru ? ThumbnailAction.none : ThumbnailAction.upNext,
    hold => booru ? ThumbnailAction.favorite : ThumbnailAction.bookmark,
  };

  /// A tap must always do something, or a work could not be opened at all.
  List<ThumbnailAction> choices({bool booru = false}) {
    final all = booru
        ? const [ThumbnailAction.open, ThumbnailAction.favorite, ThumbnailAction.folder, ThumbnailAction.none]
        : const [ThumbnailAction.open, ThumbnailAction.details, ThumbnailAction.bookmark, ThumbnailAction.upNext, ThumbnailAction.none];
    return this == tap ? all.where((action) => action != ThumbnailAction.none).toList() : all;
  }

  ThumbnailAction action({bool booru = false, Preferences? defaults}) {
    final stored = (defaults ?? store(booru: booru)).string(key(booru: booru));
    return choices(booru: booru).where((action) => action.name == stored).firstOrNull ?? standard(booru: booru);
  }

  void choose(ThumbnailAction action, {bool booru = false, Preferences? defaults}) {
    (defaults ?? store(booru: booru)).set(key(booru: booru), action.name);
    changes.value++;
  }
}

enum ReaderResumeBehavior {
  ask,
  continueReading,
  fromBeginning;

  String get rawValue => name;

  String get title => switch (this) {
    ask => L10n.text('Ask Before Continuing'),
    continueReading => L10n.text('Continue Reading'),
    fromBeginning => L10n.text('Start from Beginning'),
  };

  static ReaderResumeBehavior stored(Preferences defaults) =>
      values.where((behavior) => behavior.name == defaults.string(ReaderSettingKeys.resumeBehavior)).firstOrNull ?? ask;

  ReaderOpening opening({required int initial, required int saved, required bool resumesProgress}) {
    if (!resumesProgress || initial > 1 || saved <= 0) return ReaderOpening.page(math.max(1, initial));
    return switch (this) {
      ask => ReaderOpening.confirmation(saved),
      continueReading => ReaderOpening.page(saved),
      fromBeginning => const ReaderOpening.page(1),
    };
  }
}

/// Where a reader opens, possibly after asking whether to continue.
class ReaderOpening {
  const ReaderOpening.page(this.page) : needsConfirmation = false;
  const ReaderOpening.confirmation(this.page) : needsConfirmation = true;

  final int page;
  final bool needsConfirmation;

  int get initialPage => needsConfirmation ? 1 : page;
  ReaderOpening resolved({required bool continuing}) => ReaderOpening.page(continuing ? page : 1);

  @override
  bool operator ==(Object other) => other is ReaderOpening && other.page == page && other.needsConfirmation == needsConfirmation;
  @override
  int get hashCode => Object.hash(page, needsConfirmation);
  @override
  String toString() => needsConfirmation ? 'confirmation($page)' : 'page($page)';
}

/// Spread arithmetic: zero-based page indices grouped by 1–4 pages per view.
abstract final class ReaderLayout {
  static int count(int value) => math.min(4, math.max(1, value));
  static int start(int page, {required int count}) => math.max(0, page) ~/ ReaderLayout.count(count) * ReaderLayout.count(count);

  static int next(int page, {required int delta, required int count, required int total}) =>
      math.min(math.max(0, start(page, count: count) + delta * ReaderLayout.count(count)), start(math.max(0, total - 1), count: count));

  static int initialPage(int initial, {required int saved, required int total, required int count}) {
    final preferred = initial > 1 ? initial : math.max(initial, saved);
    final page = math.min(math.max(1, preferred) - 1, math.max(0, total - 1));
    return start(page, count: count);
  }
}

enum ReaderGuideStep {
  navigation,
  tools,
  exit;

  int get rawValue => index;
  static ReaderGuideStep? fromRawValue(int value) => value >= 0 && value < values.length ? values[value] : null;

  String get title => switch (this) {
    navigation => L10n.text('Tap the Center'),
    tools => L10n.text('Your Quick Menu'),
    exit => L10n.text('Pull Down to Close'),
  };
}

/// The three-step coach mark over the real reader.
class ReaderGuideSession {
  ReaderGuideStep? _step;
  bool _hasStarted = false;

  ReaderGuideStep? get step => _step;
  bool get hasStarted => _hasStarted;

  void start() {
    _hasStarted = true;
    _step = ReaderGuideStep.navigation;
  }

  void openedMenu() {
    if (_step == ReaderGuideStep.navigation) _step = ReaderGuideStep.tools;
  }

  void advance() {
    final current = _step;
    if (current == null) return;
    _step = ReaderGuideStep.fromRawValue(current.rawValue + 1);
  }

  void finish() => _step = null;
}

/// The guide's wording follows the reader's mode and gesture settings.
class ReaderGuideConfiguration {
  factory ReaderGuideConfiguration({required bool booru, required Preferences defaults}) {
    final mode = ReaderMode.fromRawValue(defaults.string(ReaderSettingKeys.mode)) ?? ReaderMode.horizontal;
    return ReaderGuideConfiguration._(
      booru: booru,
      continuous: !booru && mode == ReaderMode.continuous,
      vertical: !booru && mode != ReaderMode.horizontal,
      rtl: defaults.boolean(ReaderSettingKeys.rtl) ?? false,
      tapNavigation: defaults.boolean(ReaderSettingKeys.tapNavigation) ?? true,
      informationSwipe:
          booru || ReaderInformationReveal.isEnabled(mode: mode.rawValue, continuousOptIn: defaults.boolean(ReaderSettingKeys.continuousPreviewSwipe) ?? false),
    );
  }

  const ReaderGuideConfiguration._({
    required this.booru,
    required this.continuous,
    required this.vertical,
    required this.rtl,
    required this.tapNavigation,
    required this.informationSwipe,
  });

  final bool booru;
  final bool continuous;
  final bool vertical;
  final bool rtl;
  final bool tapNavigation;
  final bool informationSwipe;

  String instruction(ReaderGuideStep step) => switch (step) {
    ReaderGuideStep.navigation => L10n.text(
      continuous
          ? 'Scroll to read. Tap the center to open your menu.'
          : tapNavigation
          ? 'Tap the sides to turn pages. Tap the center to open your menu.'
          : 'Swipe to turn pages. Tap the center to open your menu.',
    ),
    ReaderGuideStep.tools => L10n.text('Open work information, save or translate here. Change how you read in Viewer Detail Settings.'),
    ReaderGuideStep.exit => L10n.text(
      continuous
          ? 'Pull down from the top reading area to return to the list. Move back up to cancel.'
          : 'Pull the work down to return to the list. Move back up to cancel. Zoom out first.',
    ),
  };

  /// The highlighted area of a step in a full-screen overlay (`ReaderGuideOverlay.highlight`).
  /// The tools step highlights the quick menu's own bounds, expanded by 4 points.
  Rect highlight(ReaderGuideStep step, {required double width, required double height, required double safeTop, Rect? menuBounds}) {
    if (step == ReaderGuideStep.tools && menuBounds != null) return menuBounds.inflate(4);
    if (step == ReaderGuideStep.exit) return Rect.fromLTWH(12, safeTop, width - 24, 64);
    return Rect.fromLTWH(width * 0.3, height * 0.29, width * 0.4, height * 0.27);
  }

  @override
  bool operator ==(Object other) =>
      other is ReaderGuideConfiguration &&
      other.booru == booru &&
      other.continuous == continuous &&
      other.vertical == vertical &&
      other.rtl == rtl &&
      other.tapNavigation == tapNavigation &&
      other.informationSwipe == informationSwipe;
  @override
  int get hashCode => Object.hash(booru, continuous, vertical, rtl, tapNavigation, informationSwipe);
}

/// The sheets a comics reader presents (`ReaderSheet`).
enum ReaderSheet { settings, information, downloads }

/// Works the reader can page through: the list it was opened from.
class MangaReaderSequence {
  MangaReaderSequence([List<int>? ids]) : ids = ids ?? [];
  List<int> ids;

  /// Called on close with the work opened first and the one last viewed, so the
  /// list can scroll to the latter.
  void Function(int opened, int viewed)? prepareReturn;

  static int? neighbor(int id, {required int delta, required List<int> ids}) {
    final index = ids.indexOf(id);
    if (index < 0 || index + delta < 0 || index + delta >= ids.length) return null;
    return ids[index + delta];
  }
}

/// After closing the reader, the list scrolls to the last work viewed, if it changed and is still shown.
abstract final class MangaViewerReturn {
  static int? targetID({required int? openedID, required int viewedID, required Iterable<int> availableIDs}) {
    if (openedID == null || openedID == viewedID || !availableIDs.contains(viewedID)) return null;
    return viewedID;
  }
}

/// Swiping up from the bottom quarter opens work information.
abstract final class ReaderInformationReveal {
  static bool isEnabled({required String mode, required bool continuousOptIn}) => mode != ReaderMode.continuous.rawValue || continuousOptIn;

  static bool isInZone(Offset point, Rect bounds) => bounds.contains(point) && point.dy >= bounds.top + bounds.height * 0.75;

  static bool shouldReveal({required Offset delta, required Offset velocity}) =>
      ReaderDismissal.shouldExit(delta: Offset(delta.dx, -delta.dy), velocity: Offset(velocity.dx, -velocity.dy));
}

/// A pull that turns back by 8 points or more is cancelled, whatever its distance.
class ReaderExitIntent {
  double peak = 0;
  bool reversed = false;

  void update(double distance) {
    peak = math.max(peak, distance);
    if (peak - distance >= 8) reversed = true;
  }

  bool shouldFinish({required Offset delta, required Offset velocity}) =>
      !reversed && velocity.dy >= 0 && ReaderDismissal.shouldExit(delta: delta, velocity: velocity);
}

/// Pull-down-to-close thresholds.
abstract final class ReaderDismissal {
  /// Continuous scroll closes only from the 64 points below the safe area's top.
  static bool isInExitZone(Offset point, Rect bounds, {required double safeTop}) =>
      bounds.contains(point) && point.dy >= bounds.top + safeTop && point.dy <= bounds.top + safeTop + 64;

  static bool shouldExit({required Offset delta, required Offset velocity}) =>
      delta.dy > delta.dx.abs() * 1.25 && (delta.dy >= 96 || (delta.dy >= 24 && velocity.dy >= 550));

  /// The drag haptic threshold.
  static const threshold = 96.0;
}

/// While dragging to close, the page follows the finger and rounds its corners.
abstract final class ReaderExitMotion {
  static double offset(double distance) => math.max(0, distance);
  static double cornerRadius(double distance) => math.min(24, math.max(0, distance) / 4);
  static const cancelDuration = Duration(milliseconds: 220);
  static const finishDuration = Duration(milliseconds: 180);

  /// A drag starts only when it moves down more than sideways.
  static bool shouldBegin(Offset velocity) => velocity.dy > 0 && velocity.dy > velocity.dx.abs() * 1.25;

  /// The information swipe starts only when it moves up more than sideways.
  static bool shouldBeginReveal(Offset velocity) => -velocity.dy > velocity.dx.abs() * 1.25;
}

/// Horizontal swipes between works, and the back swipe from the leading edge.
abstract final class ReaderHorizontalSwipe {
  /// Within 44 points of the leading edge of the safe area.
  static bool isLeadingStart(Offset point, Rect bounds, {required double safeLeft, double safeTop = 0, double safeRight = 0, double safeBottom = 0}) {
    final safe = Rect.fromLTRB(bounds.left + safeLeft, bounds.top + safeTop, bounds.right - safeRight, bounds.bottom - safeBottom);
    return safe.contains(point) && point.dx <= safe.left + 44;
  }

  /// +1 for the next work (swipe left), -1 for the previous; null when not a clear horizontal swipe.
  static int? direction({required Offset delta, required bool backOnly}) {
    if ((backOnly && delta.dx <= 0) || delta.dx.abs() <= 80 || delta.dx.abs() <= delta.dy.abs() * 1.5) return null;
    return delta.dx < 0 ? 1 : -1;
  }

  /// A work swipe starts only when it moves sideways at least 1.5 times as much as vertically.
  static bool shouldBegin(Offset velocity, {required bool backOnly}) => (!backOnly || velocity.dx > 0) && velocity.dx.abs() > velocity.dy.abs() * 1.5;
}

/// Where a tap on a page leads: the center third toggles the menu, the sides turn pages.
abstract final class ReaderTap {
  /// `x` is the tap position as a fraction of the page width. Returns the page delta, 0 for the menu, null for nothing.
  static int? action(double x, {required bool tapNavigation, required bool rtl}) {
    if (x >= 0.3 && x <= 0.7) return 0;
    if (!tapNavigation) return null;
    return (x < 0.3 ? -1 : 1) * (rtl ? -1 : 1);
  }
}

/// Hardware keyboard commands shared by the readers.
enum ReaderShortcut {
  exit('Escape'),
  previous('ArrowLeft'),
  next('ArrowRight'),
  menu('m'),
  favorite('f'),
  details('i');

  const ReaderShortcut(this.rawValue);
  final String rawValue;

  static ReaderShortcut? fromRawValue(String value) => values.where((shortcut) => shortcut.rawValue == value).firstOrNull;

  String get title => switch (this) {
    exit => 'Exit',
    previous => 'Previous',
    next => 'Next',
    menu => 'Quick Menu',
    favorite => 'Toggle Saved',
    details => 'Work Details',
  };

  String get displayKey => switch (this) {
    exit => 'Esc',
    previous => '←',
    next => '→',
    _ => rawValue.toUpperCase(),
  };
}
