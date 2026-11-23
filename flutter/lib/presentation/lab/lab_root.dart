import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../../core/booru/booru_store.dart';
import '../../core/lab/lab_course.dart';
import '../../core/lab/lab_course_file.dart';
import '../../core/lab/lab_sheet.dart';
import '../../core/lab/lab_store.dart';
import '../../core/lab/learning_courses.dart';
import '../../core/study/study_models.dart';
import '../../core/study/study_path.dart';
import '../../core/study/study_store.dart';
import '../../core/support/document_files.dart';
import '../../core/support/l10n.dart';
import '../design/alert_dialog.dart';
import '../design/app_sheet.dart';
import '../design/glass.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';
import '../home/home_stage.dart';
import '../navigation/app_header.dart';
import '../navigation/tab_navigator.dart';
import '../settings/settings_page.dart';
import '../study_mode/study_kit.dart';
import 'lab_episode_view.dart';
import 'lab_kit.dart';
import 'lab_pages.dart';

// AI 실험실: what learning mode opens on. Ported from `LabRoot.swift`.

/// The lab's tabs. `courses` lists the courses, the 2D AI course among them; `sheet` stands apart at the right end of the dock.
enum LabTab { deck, fails, courses, shop, sheet }

/// The icon of the 코스 tab, in the lab and in the 2D AI course alike.
const IconData labCoursesIcon = CupertinoIcons.square_stack_3d_up_fill;

/// The lab: a deck, the 망작 gallery, the 2D course, the shop, and the cheat sheet apart at the right end of the dock.
/// The way back to the home scene is the swipe up from the bottom, as everywhere in learning mode.
class LabRoot extends StatefulWidget {
  const LabRoot({super.key, required this.booru, this.mode});
  final BooruStore booru;

  /// The mode to follow; null is [StudyMode.shared].
  final StudyMode? mode;

  @override
  State<LabRoot> createState() => _LabRootState();
}

class _LabRootState extends State<LabRoot> {
  StudyMode get mode => widget.mode ?? StudyMode.shared;
  LabStore get store => LabStore.shared;
  final Set<LabTab> _opened = {};

  /// True while an episode is open over the deck. A card engraved there slides into the stack once the deck is seen again.
  final ValueNotifier<bool> _covered = ValueNotifier(false);

  /// Whether the cheat sheet's tab is on screen.
  final ValueNotifier<bool> _sheetShown = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    store.reload();
    _countCourses();
    widget.booru.addListener(_countCourses);
    HomeStage.shared.addListener(_greet);
    WidgetsBinding.instance.addPostFrameCallback((_) => _greet());
    unawaited(
      LabSheetSource.fetch().then((edition) {
        if (edition != null) store.show(edition);
      }),
    );
  }

  @override
  void dispose() {
    widget.booru.removeListener(_countCourses);
    HomeStage.shared.removeListener(_greet);
    _covered.dispose();
    _sheetShown.dispose();
    super.dispose();
  }

  /// Pays what 2D AI 배우기's progress has not paid yet. A learner who studied it before it was sold is told once what it paid
  /// and that it now opens from the shop.
  void _countCourses() {
    store.settleTagCourse(widget.booru.studyStore);
    // Told once the home scene has gone, before the welcome check.
    if (!store.owesLegacyNotice || HomeStage.shared.coversScreen || _telling) return;
    _telling = true;
    final paid = store.tagCoursePaid;
    store.noticeLegacy();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tellLegacy(paid));
  }

  /// True while the notice for earlier 2D progress is on screen; the welcome check waits for it.
  bool _telling = false;

  Future<void> _tellLegacy(({int gems, int lessons}) paid) async {
    if (!mounted) return;
    final open = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('lab.legacy.title')),
        content: Text(L10n.text('lab.legacy.message', ['${paid.lessons}', '${paid.gems}'])),
        actions: [
          CupertinoDialogAction(key: const Key('lab.legacy.open'), onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('lab.legacy.open'))),
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('OK'))),
        ],
      ),
    );
    _telling = false;
    if (!mounted) return;
    if (open == true) mode.labTab = LabTab.courses;
    _greet();
  }

  /// A first visit begins with the one-minute check, once the home scene has gone.
  void _greet() {
    if (!mounted || store.progress.greeted || !store.offersDiagnosis || HomeStage.shared.coversScreen || !mode.active) return;
    if (_telling || store.owesLegacyNotice) return _countCourses();
    store.greeted();
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      if (mounted) unawaited(showLabDiagnosis(context));
    });
  }

  void _select(LabTab tab) => mode.labTab = tab;

  Future<void> _play(LabEpisode episode) async {
    _covered.value = true;
    await showLabEpisode(context, episode);
    if (mounted) _covered.value = false;
  }

  // Each tab's page is built once, by its own navigator; what changes later reaches it through notifiers.
  Widget _page(LabTab tab) => switch (tab) {
    LabTab.deck => LabDeckView(play: _play, covered: _covered),
    LabTab.fails => LabFailsView(play: _play),
    LabTab.courses => LabCoursesView(mode: mode, lessons: () => widget.booru.studyStore.lessons().keys.toSet()),
    LabTab.shop => LabShopView(open: mode.open, mode: mode),
    LabTab.sheet => LabSheetView(shown: _sheetShown),
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([mode, store]),
    builder: (context, _) {
      final current = mode.labTab;
      _opened.add(current);
      _sheetShown.value = current == LabTab.sheet;
      return ColoredBox(
        color: TegnalColors.background.resolveFrom(context),
        child: Stack(
          children: [
            for (final tab in LabTab.values)
              if (_opened.contains(tab))
                // Keyed, so a tab opened later never takes over the navigator of one opened before it.
                Positioned.fill(
                  key: ValueKey(tab),
                  child: Offstage(
                    offstage: tab != current,
                    child: TickerMode(
                      enabled: tab == current,
                      child: TabNavigator(active: tab == current, builder: (context) => _page(tab)),
                    ),
                  ),
                ),
            Positioned(
              left: 0,
              right: 0,
              bottom: math.max(21, MediaQuery.paddingOf(context).bottom - 13),
              child: LabDock(current: current, select: _select),
            ),
          ],
        ),
      );
    },
  );
}

/// The lab's dock, as the library's floating tab bar: four tabs in a glass capsule and the cheat sheet in its own circle,
/// with a dot while a new edition waits.
class LabDock extends StatelessWidget {
  const LabDock({super.key, required this.current, required this.select});
  final LabTab current;
  final ValueChanged<LabTab> select;

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    final label = labLabel(context);
    final waiting = LabStore.shared.editionWaiting;
    return LabGlassDock<LabTab>(
      current: current,
      select: select,
      keyPrefix: 'lab.tab',
      tint: tint,
      items: [
        (LabTab.deck, L10n.text('lab.tab.deck'), CupertinoIcons.rectangle_stack_fill),
        (LabTab.fails, L10n.text('lab.tab.fails'), CupertinoIcons.photo_fill),
        (LabTab.courses, L10n.text('lab.tab.courses'), labCoursesIcon),
        (LabTab.shop, L10n.text('lab.tab.shop'), CupertinoIcons.bag_fill),
      ],
      // Like Smart in viewing mode: the cheat sheet stands apart at the right end of the dock. It is the AI lab's own.
      trailing: LabStore.shared.course.imported
          ? null
          : Semantics(
              button: true,
              selected: current == LabTab.sheet,
              label: L10n.text('lab.tab.sheet'),
              child: GestureDetector(
                key: const Key('lab.tab.sheet'),
                onTap: () {
                  HapticFeedback.selectionClick();
                  select(LabTab.sheet);
                },
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Glass.circle(
                      child: SizedBox.square(
                        dimension: LabGlassDock.height,
                        child: Icon(CupertinoIcons.doc_text_fill, size: 25, color: current == LabTab.sheet ? tint : label),
                      ),
                    ),
                    if (waiting)
                      Positioned(
                        right: -4,
                        top: -4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: const ShapeDecoration(color: Color(0xFFFF3B30), shape: StadiumBorder()),
                          child: Text(
                            L10n.text('lab.new'),
                            style: TegnalType.style(12, weight: FontWeight.w600, color: const Color(0xFFFFFFFF)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// The floating glass tab bar of learning mode, as the library's: the tabs in a glass capsule with the chosen one lifted
/// in its tint, and optionally something standing apart in its own circle at the right end. iOS draws the stock tab bar.
class LabGlassDock<T extends Enum> extends StatelessWidget {
  const LabGlassDock({super.key, required this.items, required this.current, required this.select, required this.keyPrefix, required this.tint, this.trailing});

  /// Each tab: its value, its name and its icon.
  final List<(T, String, IconData)> items;
  final T current;
  final ValueChanged<T> select;

  /// Each tab is keyed `<keyPrefix>.<name>`.
  final String keyPrefix;
  final Color tint;
  final Widget? trailing;

  static const height = 62.0;

  @override
  Widget build(BuildContext context) {
    final label = labLabel(context);
    final selection = TegnalColors.glassSelection.resolveFrom(context);
    final active = items.indexWhere((item) => item.$1 == current);
    final trailing = this.trailing;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 21),
      child: BackdropGroup(
        child: Row(
          children: [
            Expanded(
              child: Glass.capsule(
                child: SizedBox(
                  height: height,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final slot = constraints.maxWidth / items.length;
                        return Stack(
                          children: [
                            if (active >= 0)
                              AnimatedPositioned(
                                duration: const Duration(milliseconds: 260),
                                curve: Curves.easeOutCubic,
                                left: slot * active,
                                top: 0,
                                bottom: 0,
                                width: slot,
                                child: DecoratedBox(
                                  decoration: ShapeDecoration(color: selection, shape: const StadiumBorder()),
                                ),
                              ),
                            Row(
                              children: [
                                for (final (index, item) in items.indexed)
                                  Expanded(
                                    child: Semantics(
                                      key: Key('$keyPrefix.${item.$1.name}'),
                                      button: true,
                                      selected: index == active,
                                      label: item.$2,
                                      excludeSemantics: true,
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: () {
                                          HapticFeedback.selectionClick();
                                          select(item.$1);
                                        },
                                        child: Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Icon(item.$3, size: 25, color: index == active ? tint : label),
                                            const SizedBox(height: 2),
                                            Text(
                                              item.$2,
                                              maxLines: 1,
                                              style: TegnalType.style(10, weight: FontWeight.w600, color: index == active ? tint : label),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing],
          ],
        ),
      ),
    );
  }
}

// MARK: - The deck

/// The deck: home and collection at once, as a wallet of cards. Engraved cards lean away behind the next one, each a
/// little smaller, closer and fainter further back; a tap on the thin strips at the back fans them all out. The next blank card lies in front; locked ones wait below with only their titles.
class LabDeckView extends StatefulWidget {
  const LabDeckView({super.key, required this.play, required this.covered});
  final Future<void> Function(LabEpisode) play;

  /// True while an episode is open over the deck.
  final ValueListenable<bool> covered;

  @override
  State<LabDeckView> createState() => _LabDeckViewState();
}

class _LabDeckViewState extends State<LabDeckView> {
  LabStore get store => LabStore.shared;

  /// The engraved cards the deck shows. It catches up with the store after an episode closes, so the new card can be
  /// seen arriving.
  Set<String> shown = {};

  /// The folded pile at the back of the stack, fanned out by a tap.
  bool fanned = false;

  /// The card just engraved, shown in its colours where the blank card lay, before it goes into the stack.
  String? arriving;

  /// The front card's height when it began to shrink, measured through [_frontKey].
  double? _frontHeight;
  final GlobalKey _frontKey = GlobalKey();

  /// Whether a card laid in front now rises from below, as the next blank card does after one goes into the stack.
  bool _rising = false;

  static const earnedHeight = 200.0;
  static const lockedPeek = 44.0;
  static const lockedHeight = 120.0;

  /// From the card's top edge to the foot of its line: padding, the number row, the gap, one line of the serif at 130%.
  static const stripContent = 14.0 + 14 + 6 + 21;

  /// How far back a card sits: 1 just behind the blank card, more further up. One rule runs from the front of the stack to
  /// the back, with no step anywhere: each card is a little smaller, shows a little less of itself and is a little fainter
  /// than the one in front, as things further off are. Lines further back may be cut through; the deck reads as leaning
  /// away into the distance and never grows past about four strips' height, however many cards it holds.
  /// Shrinks quickly near the front and ever more slowly further back, towards 74%.
  static double scale(int depth) => 0.74 + 0.26 * math.pow(0.8, depth);

  /// The card just behind the blank one shows its whole strip; each card behind shows 74% of what the one in front shows.
  static const front = 64.0;
  static const recede = 0.74;

  /// Fanned out, every card shows its whole strip.
  double peek(int depth) => fanned ? (stripContent * scale(depth)).roundToDouble() + 8 : front * math.pow(recede, depth - 1);

  /// So far back that it would show less than a hairline: left out until the deck is fanned.
  bool hidden(int depth) => peek(depth) < 1.5;

  /// Too little of it shows to read or aim at: a tap fans the deck out rather than opening the card.
  bool compact(int depth) => !fanned && peek(depth) < 40;
  double shownHeight(int depth) => hidden(depth) ? 0 : peek(depth);

  /// How far a card has faded into the page: none just behind the blank card, a little more for each step back.
  /// Fanned out, the cards stay readable, so they fade less.
  double fade(int depth) => math.min(fanned ? 0.4 : 0.8, 1 - math.pow(0.84, depth - 1).toDouble());

  /// And it softens a little for each step back, past the first two.
  double blur(int depth) => fanned ? 0 : math.min(2.5, math.max(0, 0.45 * (depth - 2)));

  @override
  void initState() {
    super.initState();
    shown = store.earnedIDs;
    store.addListener(_follow);
    widget.covered.addListener(_uncovered);
  }

  @override
  void dispose() {
    store.removeListener(_follow);
    widget.covered.removeListener(_uncovered);
    super.dispose();
  }

  void _follow() {
    if (widget.covered.value || !mounted) return;
    final next = store.earnedIDs;
    if (next.length != shown.length || !next.containsAll(shown)) setState(() => shown = next);
  }

  /// The cover has gone. The blank card in front comes up in its engraved colours, settling to a card's size; then the
  /// next blank card rises over it from below, tucking it into the stack as the cards behind lean one step further back,
  /// and the ring climbs.
  void _uncovered() {
    if (widget.covered.value) return;
    Future<void>.delayed(const Duration(milliseconds: 350), () async {
      if (!mounted) return;
      final all = store.earnedIDs;
      final added = all.difference(shown);
      final first = store.course.episodes.where((episode) => !shown.contains(episode.id)).firstOrNull;
      if (added.length != 1 || first?.id != added.first) {
        setState(() => shown = all);
        if (added.isNotEmpty) LabHaptic.snap();
        return;
      }
      LabHaptic.tick();
      setState(() {
        _frontHeight = _frontKey.currentContext?.size?.height ?? 290;
        arriving = added.first;
      });
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!mounted) return;
      setState(() {
        shown = all;
        arriving = null;
        _rising = true;
      });
      LabHaptic.snap();
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (mounted) setState(() => _rising = false);
    });
  }

  /// The card in front: the next blank card or, just after it was engraved, the same card in its colours.
  Widget _front(BuildContext context, LabEpisode? next) {
    if (next == null) return _Rising(key: const ValueKey('lab.deck.finished'), rise: _rising, child: _finished(context));
    return _Rising(
      key: ValueKey(next.id),
      rise: _rising,
      child: arriving == next.id ? _arriving(context, next) : KeyedSubtree(key: _frontKey, child: _nextCard(context, next)),
    );
  }

  /// The card just engraved, where the blank card lay: its colours fade in over the paper while it shrinks to the size of
  /// the cards in the stack it is about to join.
  Widget _arriving(BuildContext context, LabEpisode episode) {
    final from = _frontHeight ?? 290;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 550),
      curve: Curves.easeOutCubic,
      builder: (context, t, _) => SizedBox(
        height: from + (earnedHeight - from) * t,
        // While it shrinks, the paper below the new edge is cut off; above and beside, its shadow still falls.
        child: ClipRect(
          clipper: const _OpenAbove(),
          child: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: Opacity(opacity: 1 - t, child: _nextCard(context, episode)),
              ),
              Positioned.fill(
                child: Opacity(
                  opacity: t,
                  child: LabCardFace(
                    serial: episode.serial,
                    title: episode.title.text,
                    line: episode.card.line.text,
                    color: store.course.color(episode),
                    state: LabCardState.earned,
                    label: episode.label,
                    top: true,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _fan(bool open) {
    LabHaptic.tick();
    setState(() => fanned = open);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final course = store.course;
      final earned = course.episodes.where((episode) => shown.contains(episode.id)).toList();
      final next = course.episodes.where((episode) => !shown.contains(episode.id) && store.state(episode) != LabCardStatus.locked).firstOrNull;
      final waiting = course.episodes.where((episode) => !shown.contains(episode.id) && episode.id != next?.id).take(3).toList();
      final rate = course.base + earned.fold<int>(0, (total, episode) => total + episode.impact);
      final hasType = store.offersDiagnosis;
      final stacked = earned.length + (hasType ? 1 : 0);
      final season = (next ?? earned.lastOrNull) == null ? 1 : course.seasonOf((next ?? earned.last))?.number ?? 1;
      return SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, MediaQuery.paddingOf(context).top, 20, labDockClearance),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LabHeader(
              kicker: TextSpan(
                children: [
                  TextSpan(text: '${L10n.text('lab.season', ['$season'])} · '),
                  TextSpan(text: '${shown.length}/${course.episodes.length}', style: LabFont.number(13)),
                ],
              ),
              title: L10n.text('lab.deck.title'),
              below: true,
              trailing: Semantics(
                key: const Key('lab.rate'),
                label: course.info.gauge.text,
                value: '$rate%',
                child: ExcludeSemantics(child: LabRing(value: rate)),
              ),
            ),
            const SizedBox(height: 14),
            LabSeasonTrack(course: course, shown: shown, current: (next ?? earned.lastOrNull) == null ? null : course.seasonOf(next ?? earned.last)),
            const SizedBox(height: 22),
            if (stacked > 2)
              Align(
                child: GestureDetector(
                  key: const Key('lab.deck.fan'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _fan(!fanned),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10, top: 4, left: 12, right: 12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedRotation(
                          turns: fanned ? 0.5 : 0,
                          duration: const Duration(milliseconds: 300),
                          child: Icon(CupertinoIcons.chevron_down, size: 14, color: labSecondary(context)),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          fanned ? L10n.text('lab.deck.fold') : L10n.text('lab.deck.unfold', ['$stacked']),
                          style: LabFont.text(13, weight: FontWeight.w600, color: labSecondary(context)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (hasType) _typeCard(context, earned.length + 1),
            for (final (index, episode) in earned.indexed) ...[
              // Fanned out, each season's cards sit under its own heading.
              if (fanned && course.seasonOf(episode) != null && (index == 0 || course.seasonOf(earned[index - 1]) != course.seasonOf(episode)))
                _seasonHeading(context, course.seasonOf(episode)!),
              _band(
                key: ValueKey(episode.id),
                depth: earned.length - index,
                onTap: () => Navigator.of(context).push(
                  CupertinoPageRoute<void>(
                    builder: (_) => LabCardDetailView(episode: episode, play: widget.play),
                  ),
                ),
                semantics: 'lab.deck.earned.${episode.id}',
                card: LabCardFace(
                  serial: episode.serial,
                  title: episode.title.text,
                  line: episode.card.line.text,
                  color: course.color(episode),
                  state: LabCardState.earned,
                  label: episode.label,
                  top: true,
                ),
              ),
            ],
            // Laid out from the bottom up, so the card in front is painted over the locked cards: the next blank card
            // rises over them.
            Column(
              verticalDirection: VerticalDirection.up,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (waiting.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
                    child: Column(
                      children: [
                        for (final (offset, episode) in waiting.indexed)
                          SizedBox(
                            height: offset == waiting.length - 1 ? lockedHeight : lockedPeek,
                            child: OverflowBox(
                              alignment: Alignment.topCenter,
                              minHeight: lockedHeight,
                              maxHeight: lockedHeight,
                              child: LabCardBackground(
                                key: Key('lab.deck.locked.${episode.id}'),
                                state: LabCardState.locked,
                                radius: 18,
                                step: offset,
                                shadow: offset == 0 ? null : const [BoxShadow(color: Color(0x66000000), blurRadius: 16, offset: Offset(0, -6))],
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(18, 13, 18, 0),
                                  child: Align(
                                    alignment: Alignment.topLeft,
                                    child: Row(
                                      children: [
                                        // A locked card that opens a new season carries its season's name.
                                        if (course.seasonOf(episode) case final season?
                                            when (offset == 0 ? next : waiting[offset - 1]).let((before) => before == null ? null : course.seasonOf(before)) !=
                                                season) ...[
                                          ConstrainedBox(
                                            constraints: const BoxConstraints(maxWidth: 96),
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                              decoration: ShapeDecoration(
                                                shape: StadiumBorder(side: BorderSide(color: labSecondary(context).withValues(alpha: 0.5))),
                                              ),
                                              child: Text(
                                                L10n.text('lab.season', ['${season.number}']),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: LabFont.text(11, weight: FontWeight.w700, color: labSecondary(context)),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                        ],
                                        Expanded(
                                          child: Text(
                                            '${episode.digits} · ${episode.title.text}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: LabFont.text(13, weight: FontWeight.w600, color: labSecondary(context)),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          L10n.text('lab.card.locked'),
                                          style: LabFont.text(13, weight: FontWeight.w600, color: labSecondary(context)),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                _front(context, next),
              ],
            ),
          ],
        ),
      );
    },
  );

  /// A card further up the stack: smaller the further back it sits, and only its top showing above the card in front.
  /// A strip too thin to read fans the deck out rather than opening its card.
  /// A season's name over its cards, when the deck is fanned out.
  Widget _seasonHeading(BuildContext context, LabSeason season) => ColoredBox(
    // The page's own background, so the heading cuts cleanly across the foot of the card above it.
    color: TegnalColors.background.resolveFrom(context),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(6, 14, 6, 10),
      child: Semantics(
        header: true,
        child: Row(
          children: [
            Text(
              L10n.text('lab.season', ['${season.number}']),
              style: LabFont.text(12, weight: FontWeight.w700, color: labSecondary(context)),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                season.title.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: LabFont.text(12, weight: FontWeight.w600, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: Container(height: 1, color: labSecondary(context).withValues(alpha: 0.25))),
          ],
        ),
      ),
    ),
  );

  Widget _band({Key? key, required int depth, required VoidCallback onTap, required String semantics, required Widget card}) {
    final compact = this.compact(depth);
    return AnimatedContainer(
      key: key,
      duration: const Duration(milliseconds: 550),
      curve: Curves.easeOutBack,
      height: shownHeight(depth),
      child: OverflowBox(
        alignment: Alignment.topCenter,
        minHeight: earnedHeight,
        maxHeight: earnedHeight,
        child: AnimatedOpacity(
          opacity: hidden(depth) ? 0 : 1,
          duration: const Duration(milliseconds: 300),
          child: AnimatedScale(
            scale: scale(depth),
            alignment: Alignment.topCenter,
            duration: const Duration(milliseconds: 550),
            curve: Curves.easeOutBack,
            child: LabPress(
              key: Key(semantics),
              onTap: compact ? () => _fan(true) : onTap,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(20)),
                  shadows: [BoxShadow(color: Color.fromRGBO(0, 0, 0, 0.32 * (1 - fade(depth) * 0.6)), blurRadius: 20, offset: const Offset(0, -6))],
                ),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: blur(depth)),
                  duration: const Duration(milliseconds: 300),
                  builder: (context, sigma, child) => sigma < 0.05
                      ? child!
                      : ImageFiltered(
                          imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                          child: child,
                        ),
                  child: Stack(
                    children: [
                      SizedBox(height: earnedHeight, width: double.infinity, child: card),
                      // The page's own background laid over the card: it fades into the distance in light and dark alike.
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedOpacity(
                            opacity: fade(depth),
                            duration: const Duration(milliseconds: 300),
                            child: ClipRSuperellipse(
                              borderRadius: BorderRadius.circular(20),
                              child: ColoredBox(color: TegnalColors.background.resolveFrom(context)),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Card No. 000: the learner's type, or the paper card that invites the check. It sits at the back of the stack.
  Widget _typeCard(BuildContext context, int depth) {
    final type = store.type;
    if (type != null) {
      return _band(
        depth: depth,
        semantics: 'lab.deck.type',
        onTap: () => showAppSheet<void>(
          context,
          builder: (sheet, controller) => LabTypeSheet(controller: controller, diagnose: () => showLabDiagnosis(context)),
        ),
        card: LabCardFace(
          serial: 'No. 000',
          title: type.name.text,
          line: type.name.text,
          state: LabCardState.earned,
          label: L10n.text('lab.type.label'),
          top: true,
        ),
      );
    }
    return _band(
      depth: depth,
      semantics: 'lab.deck.diagnose',
      onTap: () => showLabDiagnosis(context),
      card: LabCardFace(serial: 'No. 000 · ${L10n.text('lab.card.blank')}', title: L10n.text('lab.deck.diagnose'), state: LabCardState.blank, top: true),
    );
  }

  Widget _nextCard(BuildContext context, LabEpisode episode) {
    const paperInk = LabPalette.paperInk, paperMuted = LabPalette.paperMuted;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 290),
      child: LabCardBackground(
        state: LabCardState.blank,
        shadow: const [BoxShadow(color: Color(0x73000000), blurRadius: 24, offset: Offset(0, -10))],
        // At least 290 tall, as on iOS, with any room left over shared above and below the title (its two `Spacer`s), never
        // gathered under the footer.
        child: IntrinsicHeight(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${episode.serial} · ${L10n.text('lab.card.blank')}',
                        style: LabFont.text(11, weight: FontWeight.w700, color: paperMuted, tracking: 1.5),
                      ),
                    ),
                    Text(
                      L10n.text('lab.card.minutes', ['3']),
                      style: LabFont.text(11, weight: FontWeight.w700, color: paperMuted, tracking: 1.5),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        labWords(episode.title.text),
                        key: const Key('lab.deck.next.title'),
                        style: LabFont.voice(28, color: paperInk, tracking: -0.6),
                      ),
                      if (episode.teaser case final teaser?) ...[
                        const SizedBox(height: 10),
                        Text(labWords(teaser.text), style: LabFont.text(14, color: paperMuted)),
                      ],
                      const SizedBox(height: 10),
                      const LabDashedRule(color: LabPalette.paperRule),
                    ],
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text:
                                      '${store.course.imported ? L10n.text('lab.card.impactOf', [store.course.info.gauge.text]) : L10n.text('lab.card.impact')} ',
                                ),
                                TextSpan(
                                  text: '+${episode.impact}%',
                                  style: LabFont.number(11, color: paperInk),
                                ),
                              ],
                            ),
                            style: LabFont.text(11, weight: FontWeight.w600, color: paperMuted),
                          ),
                          const SizedBox(height: 5),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: _ImpactPips(impact: episode.impact),
                          ),
                        ],
                      ),
                    ),
                    GestureDetector(
                      key: const Key('lab.deck.start'),
                      onTap: () => widget.play(episode),
                      child: Container(
                        height: 46,
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        decoration: const ShapeDecoration(color: paperInk, shape: StadiumBorder()),
                        child: Center(
                          widthFactor: 1,
                          child: Text(
                            L10n.text('lab.card.start'),
                            style: LabFont.text(15, weight: FontWeight.w700, color: const Color(0xFFFFFFFF)),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _finished(BuildContext context) => LabCardBackground(
    key: const ValueKey('finished'),
    state: LabCardState.blank,
    shadow: const [BoxShadow(color: Color(0x73000000), blurRadius: 24, offset: Offset(0, -10))],
    child: Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 200),
      padding: const EdgeInsets.all(20),
      alignment: Alignment.bottomLeft,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(L10n.text('lab.deck.complete'), style: LabFont.voice(24, color: LabPalette.paperInk)),
          const SizedBox(height: 10),
          Text(L10n.text('lab.deck.completeNote'), style: LabFont.text(14, color: LabPalette.paperMuted)),
        ],
      ),
    ),
  );
}

/// How much a card adds, as five short bars.
class _ImpactPips extends StatelessWidget {
  const _ImpactPips({required this.impact});
  final int impact;
  @override
  Widget build(BuildContext context) {
    final filled = impact >= 12
        ? 5
        : impact >= 9
        ? 4
        : impact >= 6
        ? 3
        : impact >= 3
        ? 2
        : 1;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < 5; index++) ...[
          if (index > 0) const SizedBox(width: 3),
          Container(
            width: 14,
            height: 5,
            decoration: ShapeDecoration(
              color: index < filled ? LabPalette.paperInk : LabPalette.paperRule.withValues(alpha: 0.4),
              shape: const StadiumBorder(),
            ),
          ),
        ],
      ],
    );
  }
}

// MARK: - The back of a card

/// An engraved card turned over: how to use it, the text to copy, the sheet it opened, its 망작, and playing it again.
class LabCardDetailView extends StatelessWidget {
  LabCardDetailView({super.key, required this.episode, required this.play});
  final LabEpisode episode;
  final Future<void> Function(LabEpisode) play;
  final _card = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final store = LabStore.shared;
    final mode = StudyMode.shared;
    final fails = episode.fails;
    final sections = store.edition?.sections.where((section) => section.opens == episode.id).toList() ?? const [];
    final rowColor = FormColors.listRow.resolveFrom(context);
    final color = store.course.color(episode);
    return SettingsPage(
      title: '${episode.number} / ${store.course.episodes.length}',
      trailing: ToolbarGroup(
        children: [ToolbarIconButton(label: L10n.text('lab.share'), icon: CupertinoIcons.share, onPressed: () => labShare(_card, episode.card.line.text))],
      ),
      children: [
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: DecoratedBox(
              decoration: ShapeDecoration(
                shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(24)),
                shadows: [BoxShadow(color: LabPalette.hex(color).withValues(alpha: 0.45), blurRadius: 48, offset: const Offset(0, 14))],
              ),
              child: RepaintBoundary(
                key: _card,
                child: SizedBox(
                  width: 280,
                  height: 352,
                  child: LabCardFace(
                    serial: episode.serial,
                    title: episode.title.text,
                    line: episode.card.line.text,
                    color: color,
                    state: LabCardState.earned,
                    footer: store.course.footer(episode),
                    date: store.engraved(episode) == null ? null : labStamp(store.engraved(episode)!),
                    large: true,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        FormSection(
          header: Text(L10n.text('lab.card.uses')),
          rowColor: rowColor,
          children: [
            for (final (index, use) in episode.card.uses.indexed)
              FormRow(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text('${index + 1}', style: LabFont.number(13, color: LabPalette.gauge.resolveFrom(context))),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(studyWords(use.text), style: LabFont.text(17, color: labLabel(context))),
                    ),
                  ],
                ),
              ),
          ],
        ),
        if (episode.card.copy case final copy?) ...[
          const SizedBox(height: 28),
          FormSection(
            header: Text(L10n.text('lab.card.copy')),
            footer: Text(L10n.text('lab.card.copyNote')),
            rowColor: rowColor,
            children: [
              FormRow(
                child: Text(labWords(copy.text), style: LabFont.text(15, color: labLabel(context))),
              ),
              FormRow(child: LabCopyButton(text: copy.text)),
            ],
          ),
        ],
        const SizedBox(height: 28),
        FormSection(
          rowColor: rowColor,
          children: [
            for (final section in sections)
              FormRow(
                onTap: () {
                  Navigator.of(context).pop();
                  mode.labTab = LabTab.sheet;
                },
                child: _row(
                  context,
                  L10n.text('lab.card.opened'),
                  section.title.text,
                  store.edition == null ? null : L10n.text('lab.sheet.stamp', [store.edition!.stamp]),
                ),
              ),
            FormRow(
              key: const Key('lab.card.fails'),
              onTap: () {
                Navigator.of(context).pop();
                mode.labTab = LabTab.fails;
              },
              child: _row(context, L10n.text('lab.tab.fails'), null, '${fails.where(store.hung).length}/${fails.length}'),
            ),
          ],
        ),
        const SizedBox(height: 28),
        FormSection(
          rowColor: rowColor,
          children: [
            FormRow(
              key: const Key('lab.card.again'),
              onTap: () => play(episode),
              child: Row(
                children: [
                  Icon(CupertinoIcons.arrow_counterclockwise, size: 19, color: TegnalColors.tint.resolveFrom(context)),
                  const SizedBox(width: 8),
                  Text(L10n.text('lab.card.again'), style: LabFont.text(17, color: TegnalColors.tint.resolveFrom(context))),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _row(BuildContext context, String title, String? detail, String? value) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: LabFont.text(17, color: labLabel(context))),
            if (detail != null) Text(detail, style: LabFont.text(13, color: labSecondary(context))),
          ],
        ),
      ),
      if (value != null) Text(value, style: LabFont.number(13, color: labSecondary(context))),
      const SizedBox(width: 6),
      Icon(CupertinoIcons.chevron_right, size: 13, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
    ],
  );
}

// MARK: - Courses

/// The 코스 tab, in every course alike: each course of `LearningCourses` as a card, the way the 2D course was shown before
/// it was bought. The course on screen is marked on its card; another one owned opens with a tap; one not bought yet shows
/// its price and the balance. At the foot, a course file can be imported; an imported course is removed with a long press.
class LabCoursesView extends StatefulWidget {
  const LabCoursesView({super.key, this.mode, this.courses, this.bottom = labDockClearance, this.pick, this.lessons});

  /// The mode to switch; null is [StudyMode.shared].
  final StudyMode? mode;

  /// The catalog to list; null is [LearningCourses.shared].
  final LearningCourses? courses;

  /// Room left under the page for the dock.
  final double bottom;

  /// Picks a course file; null opens the system's document picker. For tests.
  final Future<File?> Function()? pick;

  /// The lessons finished on the tags engine, by id, for an imported course's count.
  final Set<String> Function()? lessons;

  @override
  State<LabCoursesView> createState() => _LabCoursesViewState();
}

class _LabCoursesViewState extends State<LabCoursesView> {
  StudyMode get _mode => widget.mode ?? StudyMode.shared;
  LearningCourses get _courses => widget.courses ?? LearningCourses.shared;
  bool _reading = false;

  String _title(LearningCourse course) => course.title;

  Future<void> _import() async {
    setState(() => _reading = true);
    File? file;
    try {
      file = await (widget.pick ?? () => const DocumentFiles().openDocument())();
      if (file == null) return;
      final course = await _courses.addFile(file);
      LabHaptic.pass();
      _mode.open(course.id);
    } on Object catch (error) {
      if (!mounted) return;
      final update = error == const LabCourseFileError.newer();
      await showCupertinoDialog<void>(
        context: context,
        builder: (context) => TegnalAlertDialog(
          title: Text(L10n.text(update ? 'lab.import.updateTitle' : 'lab.import.failed')),
          content: Text(error is LabCourseFileError ? error.errorDescription : L10n.text('lab.import.notCourse')),
          actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('OK')))],
        ),
      );
    } finally {
      if (widget.pick == null) {
        try {
          await file?.delete();
        } on Object {
          // The copy is only a temporary one.
        }
      }
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _remove(LearningCourse course, {String? title}) async {
    final yes = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('lab.courses.removeConfirm', [title ?? _title(course)])),
        content: Text(L10n.text('lab.courses.removeNote')),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
          CupertinoDialogAction(
            key: const Key('lab.courses.remove'),
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: Text(L10n.text('lab.courses.remove')),
          ),
        ],
      ),
    );
    if (yes != true) return;
    if (_mode.courseID == course.id) _mode.open(LearningCourse.labID);
    _courses.remove(course.id);
  }

  @override
  Widget build(BuildContext context) {
    final store = LabStore.shared;
    return ListenableBuilder(
      listenable: Listenable.merge([store, _courses, _mode]),
      builder: (context, _) {
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, MediaQuery.paddingOf(context).top, 20, math.max(widget.bottom, MediaQuery.paddingOf(context).bottom + 24)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LabHeader(
                kicker: TextSpan(text: L10n.text('lab.courses.subtitle')),
                title: L10n.text('lab.tab.courses'),
              ),
              for (final course in _courses.all) ...[const SizedBox(height: 20), _courseCard(context, course, store)],
              for (final waiting in _courses.waiting) ...[const SizedBox(height: 20), _waitingCard(context, waiting)],
              const SizedBox(height: 24),
              LabButton(
                key: const Key('lab.courses.import'),
                expand: true,
                onPressed: _reading ? null : _import,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(CupertinoIcons.square_arrow_down, size: 18, color: TegnalColors.tint.resolveFrom(context)),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        L10n.text('lab.courses.import'),
                        style: LabFont.text(17, weight: FontWeight.w600, color: TegnalColors.tint.resolveFrom(context)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                L10n.text('lab.courses.importNote'),
                textAlign: TextAlign.center,
                style: LabFont.text(13, color: labSecondary(context)),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _courseCard(BuildContext context, LearningCourse course, LabStore store) {
    final here = _mode.courseID == course.id;
    // A course owned and not on screen opens with a tap on its card.
    final open = here || !_courses.owned(course, store) ? null : (Key('lab.courses.open.${course.id}'), () => _mode.open(course.id));
    final deck = course.deck;
    if (course.lessons case final lessons?) {
      // An imported course on the 2D engine: its own colour, with its symbol in the corner.
      final color = studyHex(lessons.color);
      final done = _lessonsDone();
      return GestureDetector(
        key: Key('lab.courses.menu.${course.id}'),
        onLongPress: () => _remove(course),
        child: _card(
          context,
          key: Key('lab.courses.card.${course.id}'),
          open: open,
          kicker: L10n.text('lab.courses.imported.kicker'),
          title: _title(course),
          current: here,
          colors: [Color.lerp(color, const Color(0xFFFFFFFF), 0.12)!, color],
          glow: color.withValues(alpha: 0.35),
          features: [
            ('map.fill', L10n.text('lab.2d.lessons', ['${lessons.path.lessons.length}'])),
            ('tag.fill', L10n.text('lab.2d.tags', ['${lessons.unit?.tags.length ?? 0}'])),
            (
              'checkmark.circle.fill',
              L10n.text('lab.courses.lessonsDone', [
                '${lessons.path.lessons.where((lesson) => done.contains(lesson.id)).length}',
                '${lessons.path.lessons.length}',
              ]),
            ),
          ],
          art: Positioned(
            right: 18,
            bottom: 14,
            child: ExcludeSemantics(child: StudyIcon(lessons.symbol, size: 86, color: const Color(0x38FFFFFF))),
          ),
        ),
      );
    }
    if (course.engine == LearningEngine.tags || deck == null) {
      final primary = StudyTheme.of(context).primary;
      return _card(
        context,
        key: Key('lab.courses.card.${course.id}'),
        open: open,
        kicker: L10n.text('lab.courses.tags.kicker'),
        title: _title(course),
        current: here,
        colors: [primary, studyEdge(primary)],
        glow: primary.withValues(alpha: 0.35),
        footer: _purchase(context, course, store, primary),
        features: [
          ('map.fill', L10n.text('lab.2d.lessons', ['${StudyPath.bundled.lessons.length}'])),
          ('tag.fill', L10n.text('lab.2d.tags', ['${StudyCurriculum.bundled.tags.length}'])),
          ('wand.and.stars', L10n.text('lab.2d.studio')),
        ],
        // The course's guide leans in from the corner, behind nothing.
        art: Positioned(
          right: -8,
          bottom: -6,
          child: ExcludeSemantics(child: StudyMascot(pose: StudyMascotPose.wave, size: 132)),
        ),
      );
    }
    // A deck course: the AI lab in ink, an imported one in its first card colour, each with a fan of its card colours.
    final colors = deck.info.cardColors ?? const [LabPalette.ink];
    final rate =
        deck.base +
        deck.episodes
            .where((episode) => store.progress.cards.containsKey(LabStore.keyIn(episode.id, deck)))
            .fold<int>(0, (total, episode) => total + episode.impact);
    final first = LabPalette.hex(colors.first);
    final card = _card(
      context,
      key: Key('lab.courses.card.${course.id}'),
      open: open,
      kicker: L10n.text(deck.imported ? 'lab.courses.imported.kicker' : 'lab.courses.lab.kicker'),
      title: deck.title,
      current: here,
      colors: deck.imported ? [Color.lerp(first, const Color(0xFFFFFFFF), 0.12)!, first] : const [Color(0xFF3A3A3C), Color(0xFF1C1C1E)],
      glow: const Color(0x4D000000),
      features: [
        ('rectangle.stack.fill', L10n.text('lab.courses.lab.cards', ['${deck.episodes.length}', '${deck.seasons.length}'])),
        if (!deck.imported) ('doc.text.fill', L10n.text('lab.courses.lab.sheet')),
        ('gauge.with.dots.needle.67percent', L10n.text('lab.courses.lab.rate', [deck.info.gauge.text, '$rate%'])),
      ],
      art: _fan(colors),
    );
    if (!deck.imported) return card;
    return GestureDetector(key: Key('lab.courses.menu.${course.id}'), onLongPress: () => _remove(course), child: card);
  }

  /// Lessons finished in any course on the tags engine, for an imported course's count.
  Set<String> _lessonsDone() {
    try {
      return widget.lessons?.call() ?? const {};
    } on Object {
      return const {};
    }
  }

  /// A course kept although this app is too old for it: named, greyed, and asking for an update.
  Widget _waitingCard(BuildContext context, WaitingCourse waiting) {
    final secondary = labSecondary(context);
    return GestureDetector(
      key: Key('lab.courses.waiting.${waiting.id}'),
      onLongPress: () => _remove(
        LearningCourse(id: waiting.id, engine: LearningEngine.deck, imported: true),
        title: waiting.title,
      ),
      child: CustomPaint(
        foregroundPainter: _DashedRect(secondary.withValues(alpha: 0.35)),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: ShapeDecoration(
            color: FormColors.listRow.resolveFrom(context),
            shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(24)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                L10n.text('lab.courses.waiting.kicker'),
                style: LabFont.text(11, weight: FontWeight.w700, color: secondary, tracking: 1.6),
              ),
              const SizedBox(height: 10),
              Text(waiting.title, style: LabFont.voice(24, color: labLabel(context))),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(CupertinoIcons.arrow_down_square_fill, size: 16, color: secondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      L10n.text('lab.courses.waiting.note'),
                      style: LabFont.text(14, weight: FontWeight.w600, color: secondary),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A small fan of a deck course's card colours in the corner.
  Widget _fan(List<String> colors) => Positioned(
    right: 30,
    bottom: -16,
    child: ExcludeSemantics(
      child: SizedBox(
        width: 120,
        height: 96,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.bottomCenter,
          children: [
            for (final (index, hex) in colors.take(3).indexed)
              Transform.translate(
                offset: Offset((index - 1) * 14.0, 0),
                child: Transform.rotate(
                  angle: (index - 1) * 11 * math.pi / 180,
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    width: 58,
                    height: 78,
                    decoration: ShapeDecoration(
                      color: LabPalette.hex(hex),
                      shape: RoundedSuperellipseBorder(
                        borderRadius: BorderRadius.circular(9),
                        side: const BorderSide(color: Color(0x2EFFFFFF), width: 0.75),
                      ),
                      shadows: const [BoxShadow(color: Color(0x59000000), blurRadius: 12, offset: Offset(0, 3))],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );

  /// The foot of a course not bought yet: what the learner has, what is missing and how it is earned, and the buy button, in a
  /// band across the bottom of the course's own card. Null for a course owned or free.
  Widget? _purchase(BuildContext context, LearningCourse course, LabStore store, Color ink) {
    if (_courses.owned(course, store)) return null;
    final item = course.item == null ? null : store.shop.item(course.item!);
    final price = item?.price;
    if (item == null || price == null) return null;
    final state = store.canBuy(item);
    const white = Color(0xFFFFFFFF);
    final key = Key(course.id == LearningCourse.tagsID ? 'lab.2d.buy' : 'lab.courses.buy.${course.id}');
    final label = Text(
      L10n.text('lab.shop.buy', ['$price']),
      style: LabFont.text(15, weight: FontWeight.w700, color: state.isBought ? ink : white.withValues(alpha: 0.75)),
    );
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                state.isBought
                    ? L10n.text('lab.2d.balance', ['${store.balance}'])
                    : L10n.text('lab.2d.short', ['${store.balance}', '${price - store.balance}']),
                style: LabFont.text(13, weight: FontWeight.w600, color: white.withValues(alpha: 0.9)),
              ),
              // A learner who studied the course before it was sold: the lessons stay, waiting for it to be bought.
              if (course.id == LearningCourse.tagsID && store.tagCoursePaid.lessons > 0) ...[
                const SizedBox(height: 3),
                Text(
                  L10n.text('lab.2d.kept', ['${store.tagCoursePaid.lessons}']),
                  style: LabFont.text(12, weight: FontWeight.w600, color: white.withValues(alpha: 0.85)),
                ),
              ],
              if (!state.isBought) ...[const SizedBox(height: 3), Text(L10n.text('lab.2d.how'), style: LabFont.text(12, color: white.withValues(alpha: 0.7)))],
            ],
          ),
        ),
        const SizedBox(width: 12),
        if (state.isBought)
          GestureDetector(
            key: key,
            onTap: () async {
              if (await confirmLabPurchase(context, item)) _mode.open(course.id);
            },
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              alignment: Alignment.center,
              decoration: const ShapeDecoration(color: white, shape: StadiumBorder()),
              child: label,
            ),
          )
        else
          // Not enough yet: the price, readable on the card, with nothing to press.
          Container(
            key: key,
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            alignment: Alignment.center,
            decoration: ShapeDecoration(
              shape: StadiumBorder(side: BorderSide(color: white.withValues(alpha: 0.45), width: 1.2)),
            ),
            child: label,
          ),
      ],
    );
  }

  Widget _card(
    BuildContext context, {
    required Key key,
    required String kicker,
    required String title,
    required bool current,
    required List<Color> colors,
    required Color glow,
    required List<(String, String)> features,
    required Widget art,
    (Key, VoidCallback)? open,
    Widget? footer,
  }) {
    const white = Color(0xFFFFFFFF);
    final card = DecoratedBox(
      key: key,
      decoration: ShapeDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: colors),
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(24)),
        shadows: [BoxShadow(color: glow, blurRadius: 40, offset: const Offset(0, 10))],
      ),
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Stack(
              children: [
                art,
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 22, 22, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              kicker,
                              style: LabFont.text(11, weight: FontWeight.w700, color: white.withValues(alpha: 0.75), tracking: 1.6),
                            ),
                          ),
                          if (current)
                            Container(
                              key: const Key('lab.courses.here'),
                              height: 26,
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              decoration: const ShapeDecoration(color: Color(0x33FFFFFF), shape: StadiumBorder()),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(CupertinoIcons.checkmark_alt, size: 13, color: white),
                                  const SizedBox(width: 4),
                                  Text(
                                    L10n.text('lab.courses.here'),
                                    style: LabFont.text(12, weight: FontWeight.w700, color: white),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(title, style: LabFont.voice(30, color: white)),
                      const SizedBox(height: 18),
                      for (final (symbol, text) in features)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10, right: 96),
                          child: Row(
                            children: [
                              StudyIcon(symbol, size: 17, color: white),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  text,
                                  style: LabFont.text(15, weight: FontWeight.w600, color: white),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            // A course not bought yet: its price and the buy button across the foot of the same card.
            if (footer != null)
              ColoredBox(
                color: const Color(0x3D000000),
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14), child: footer),
              ),
          ],
        ),
      ),
    );
    if (open == null) return card;
    return LabPress(
      key: open.$1,
      onTap: () {
        LabHaptic.tick();
        open.$2();
      },
      child: card,
    );
  }
}

/// Cuts off only what lies below the box, so a shadow above and beside it still shows.
class _OpenAbove extends CustomClipper<Rect> {
  const _OpenAbove();
  @override
  Rect getClip(Size size) => Rect.fromLTRB(-60, -60, size.width + 60, size.height);
  @override
  bool shouldReclip(_OpenAbove oldClipper) => false;
}

/// A card laid in front of the deck: rising from below when [rise] is set as it first appears, otherwise simply there.
class _Rising extends StatefulWidget {
  const _Rising({super.key, required this.rise, required this.child});
  final bool rise;
  final Widget child;

  @override
  State<_Rising> createState() => _RisingState();
}

class _RisingState extends State<_Rising> with SingleTickerProviderStateMixin {
  late final AnimationController _lift = AnimationController.unbounded(vsync: this, value: widget.rise ? 0 : 1);

  @override
  void initState() {
    super.initState();
    if (widget.rise) {
      // `.spring(duration: 0.65, bounce: 0.08)` on iOS.
      unawaited(_lift.animateWith(SpringSimulation(SpringDescription.withDampingRatio(mass: 1, stiffness: 93, ratio: 0.92), 0, 1, 0)));
    }
  }

  @override
  void dispose() {
    _lift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _lift,
    builder: (context, child) => Transform.translate(offset: Offset(0, 300 * (1 - _lift.value)), child: child),
    child: widget.child,
  );
}

extension _Let<T> on T {
  R let<R>(R Function(T value) transform) => transform(this);
}

/// The seasons side by side under the deck's title: one bar per season, filled as far as its cards are engraved. The season
/// in play is the long bar; finished seasons and those still ahead are short ones beside it; with no season in play (all
/// done) the bars share the width evenly. Its name is below (`LabSeasonTrack`).
class LabSeasonTrack extends StatelessWidget {
  const LabSeasonTrack({super.key, required this.course, required this.shown, required this.current});
  final LabCourse course;
  final Set<String> shown;
  final LabSeason? current;

  @override
  Widget build(BuildContext context) {
    // The season in play weighs four short bars.
    double weight(LabSeason season) => current == null ? 1 : (season.number == current!.number ? 4 : 1);
    final total = course.seasons.fold(0.0, (sum, season) => sum + weight(season));
    final label = labLabel(context), secondary = labSecondary(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 6,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final room = constraints.maxWidth - 5 * (course.seasons.length - 1).clamp(0, 99);
              return Row(
                children: [
                  for (final (index, season) in course.seasons.indexed) ...[
                    if (index > 0) const SizedBox(width: 5),
                    Builder(
                      builder: (context) {
                        final done = season.episodes.where(shown.contains).length;
                        final here = season.number == current?.number;
                        final width = room * weight(season) / (total == 0 ? 1 : total);
                        final count = season.episodes.isEmpty ? 1 : season.episodes.length;
                        return Semantics(
                          label: '${L10n.text('lab.season', ['${season.number}'])} · ${season.title.text}',
                          value: '$done/${season.episodes.length}',
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 600),
                            curve: Curves.easeOutCubic,
                            width: width,
                            height: here ? 6 : 4,
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: DecoratedBox(
                                    decoration: ShapeDecoration(
                                      color: secondary.withValues(alpha: here ? 0.3 : 0.16),
                                      shape: const StadiumBorder(),
                                    ),
                                  ),
                                ),
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 600),
                                  curve: Curves.easeOutCubic,
                                  width: width * done / count,
                                  decoration: ShapeDecoration(
                                    color: done == season.episodes.length ? LabPalette.pass.resolveFrom(context) : label,
                                    shape: const StadiumBorder(),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ],
              );
            },
          ),
        ),
        if (current case final current?) ...[
          const SizedBox(height: 8),
          Text(
            current.title.text,
            key: const Key('lab.season.current'),
            maxLines: 2,
            style: LabFont.text(14, weight: FontWeight.w600, color: secondary),
          ),
        ],
      ],
    );
  }
}

/// A dashed outline around a course waiting for an update.
class _DashedRect extends CustomPainter {
  _DashedRect(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(24)));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final metric in path.computeMetrics()) {
      for (var distance = 0.0; distance < metric.length; distance += 11) {
        canvas.drawPath(metric.extractPath(distance, distance + 6), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRect old) => old.color != color;
}
