import 'dart:async';
import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/booru/booru_store.dart';
import '../../core/lab/lab_course.dart';
import '../../core/lab/lab_sheet.dart';
import '../../core/lab/lab_store.dart';
import '../../core/study/study_models.dart';
import '../../core/study/study_path.dart';
import '../../core/study/study_store.dart';
import '../../core/support/l10n.dart';
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

/// The lab's tabs. `twoD` leads into the 2D AI course; `sheet` stands apart at the right end of the dock.
enum LabTab { deck, fails, twoD, shop, sheet }

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

  /// Lessons of the 2D course finished so far, which pay once the course is bought. A learner who studied tags before the
  /// lab keeps it.
  void _countCourses() {
    final study = widget.booru.studyStore;
    int lessons;
    int xp;
    try {
      lessons = study.lessons().length;
      xp = study.days().fold(0, (total, day) => total + day.xp);
    } on Object {
      return;
    }
    store
      ..grandfather(lessons: lessons, xp: xp)
      ..count(lessons: lessons, of: LabStore.tagCourse);
  }

  /// A first visit begins with the one-minute check, once the home scene has gone.
  void _greet() {
    if (!mounted || store.progress.greeted || store.diagnosis == null || HomeStage.shared.coversScreen || !mode.active) return;
    store.greeted();
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      if (mounted) unawaited(showLabDiagnosis(context));
    });
  }

  void _select(LabTab tab) {
    // The 2D tab of someone who owns the course opens the course itself; the lab tab they were on stays chosen.
    if (tab == LabTab.twoD && store.ownsTagCourse) {
      mode.openTags();
      return;
    }
    mode.labTab = tab;
  }

  Future<void> _play(LabEpisode episode) async {
    _covered.value = true;
    await showLabEpisode(context, episode);
    if (mounted) _covered.value = false;
  }

  // Each tab's page is built once, by its own navigator; what changes later reaches it through notifiers.
  Widget _page(LabTab tab) => switch (tab) {
    LabTab.deck => LabDeckView(play: _play, covered: _covered),
    LabTab.fails => const LabFailsView(),
    LabTab.twoD => LabTwoDView(openTags: mode.openTags),
    LabTab.shop => LabShopView(openTags: mode.openTags),
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

  static const _height = 62.0;

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    final label = labLabel(context);
    final selection = TegnalColors.glassSelection.resolveFrom(context);
    final items = [
      (LabTab.deck, L10n.text('lab.tab.deck'), CupertinoIcons.rectangle_stack_fill),
      (LabTab.fails, L10n.text('lab.tab.fails'), CupertinoIcons.photo_fill),
      (LabTab.twoD, L10n.text('lab.tab.2d'), CupertinoIcons.paintbrush_fill),
      (LabTab.shop, L10n.text('lab.tab.shop'), CupertinoIcons.bag_fill),
    ];
    final active = items.indexWhere((item) => item.$1 == current);
    final waiting = LabStore.shared.editionWaiting;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 21),
      child: BackdropGroup(
        child: Row(
          children: [
            Expanded(
              child: Glass.capsule(
                child: SizedBox(
                  height: _height,
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
                                      button: true,
                                      selected: index == active,
                                      label: item.$2,
                                      excludeSemantics: true,
                                      child: GestureDetector(
                                        key: Key('lab.tab.${item.$1.name}'),
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
            const SizedBox(width: 8),
            // Like Smart in viewing mode: the cheat sheet stands apart at the right end of the dock.
            Semantics(
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
                        dimension: _height,
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
          ],
        ),
      ),
    );
  }
}

// MARK: - The deck

/// The deck: home and collection at once, as a wallet of cards. The nearest engraved cards show their number, name and
/// line, each a little smaller and showing less further back; older ones fold into a pile of coloured edges that a tap
/// fans out. The next blank card lies in front; locked ones wait below with only their titles.
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

  static const earnedHeight = 200.0;
  static const lockedPeek = 44.0;
  static const lockedHeight = 120.0;
  static const openCount = 3;
  static const edges = 5;
  static const edge = 10.0;

  /// From the card's top edge to the foot of its line: padding, the number row, the gap, one line of the serif at 130%.
  static const stripContent = 14.0 + 14 + 6 + 21;

  /// Shrinks quickly near the front and ever more slowly further back, towards 80%, so even a full deck keeps leaning away.
  static double scale(int depth) => 0.8 + 0.2 * math.pow(0.86, depth);

  /// The strip left showing shrinks with the card, but always holds its number, name and line whole.
  static double peek(int depth) => (stripContent * scale(depth)).roundToDouble() + 8;

  bool folded(int depth) => !fanned && depth > openCount;
  bool hidden(int depth) => !fanned && depth > openCount + edges;
  double shownHeight(int depth) => hidden(depth) ? 0 : (folded(depth) ? edge : peek(depth));

  /// Folded cards darken the further back they sit, as if the light did not reach them.
  double dim(int depth) => folded(depth) ? math.min(0.6, 0.22 + 0.08 * (depth - openCount - 1)) : 0;

  @override
  void initState() {
    super.initState();
    shown = store.progress.cards.keys.toSet();
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
    final next = store.progress.cards.keys.toSet();
    if (next.length != shown.length || !next.containsAll(shown)) setState(() => shown = next);
  }

  /// The cover has gone: the new card slides into the stack, the ring climbs and the next blank card is laid down.
  void _uncovered() {
    if (widget.covered.value) return;
    Future<void>.delayed(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      final next = store.progress.cards.keys.toSet();
      final added = next.difference(shown);
      setState(() => shown = next);
      if (added.isNotEmpty) LabHaptic.snap();
    });
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
      final hasType = store.type != null || store.diagnosis != null;
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
                  TextSpan(text: '${course.title} · ${L10n.text('lab.season', ['$season'])} · '),
                  TextSpan(text: '${shown.length}/${course.episodes.length}', style: LabFont.number(13)),
                ],
              ),
              title: L10n.text('lab.deck.title'),
              trailing: Semantics(
                key: const Key('lab.rate'),
                label: course.info.gauge.text,
                value: '$rate%',
                child: ExcludeSemantics(child: LabRing(value: rate)),
              ),
            ),
            const SizedBox(height: 22),
            if (stacked > openCount)
              Align(
                alignment: Alignment.centerRight,
                child: GestureDetector(
                  key: const Key('lab.deck.fan'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _fan(!fanned),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10, top: 4, left: 12),
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
                          fanned ? L10n.text('lab.deck.fold') : L10n.text('lab.deck.unfold', ['${stacked - openCount}']),
                          style: LabFont.text(13, weight: FontWeight.w600, color: labSecondary(context)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (hasType) _typeCard(context, earned.length + 1),
            for (final (index, episode) in earned.indexed)
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
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              transitionBuilder: (child, animation) => ScaleTransition(
                scale: Tween(begin: 0.96, end: 1.0).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutBack)),
                child: FadeTransition(opacity: animation, child: child),
              ),
              child: next == null ? _finished(context) : KeyedSubtree(key: ValueKey(next.id), child: _nextCard(context, next)),
            ),
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
          ],
        ),
      );
    },
  );

  /// A card further up the stack: smaller the further back it sits, and only its top showing above the card in front.
  /// A folded edge fans the pile out rather than opening its card.
  Widget _band({Key? key, required int depth, required VoidCallback onTap, required String semantics, required Widget card}) {
    final folded = this.folded(depth);
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
              onTap: folded ? () => _fan(true) : onTap,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(20)),
                  shadows: const [BoxShadow(color: Color(0x52000000), blurRadius: 20, offset: Offset(0, -6))],
                ),
                child: Stack(
                  children: [
                    SizedBox(height: earnedHeight, width: double.infinity, child: card),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: AnimatedOpacity(
                          opacity: dim(depth),
                          duration: const Duration(milliseconds: 300),
                          child: ClipRSuperellipse(
                            borderRadius: BorderRadius.circular(20),
                            child: const ColoredBox(color: Color(0xFF000000)),
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
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
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
              const SizedBox(height: 18),
              Text(
                labWords(episode.title.text),
                key: const Key('lab.deck.next.title'),
                style: LabFont.voice(28, color: paperInk, tracking: -0.6),
              ),
              if (episode.teaser case final teaser?) ...[const SizedBox(height: 10), Text(labWords(teaser.text), style: LabFont.text(14, color: paperMuted))],
              const SizedBox(height: 10),
              const LabDashedRule(color: LabPalette.paperRule),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(text: '${L10n.text('lab.card.impact')} '),
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
                    date: store.progress.cards[episode.id] == null ? null : labStamp(store.progress.cards[episode.id]!),
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

// MARK: - 2D AI 배우기

/// The 2D tab: the 2D AI course. Someone who owns it goes straight in (see [LabRoot]); anyone else sees what it is and
/// what it costs.
class LabTwoDView extends StatelessWidget {
  const LabTwoDView({super.key, required this.openTags});
  final VoidCallback openTags;

  @override
  Widget build(BuildContext context) {
    final store = LabStore.shared;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final item = store.shop.item(LabStore.tagCourse);
        final price = item?.price;
        final state = item == null ? LabBuyResult.unavailable : store.canBuy(item);
        const white = Color(0xFFFFFFFF);
        final primary = StudyTheme.of(context).primary;
        Widget feature(String symbol, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
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
        );
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, MediaQuery.paddingOf(context).top, 20, labDockClearance),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LabHeader(
                kicker: TextSpan(text: L10n.text('lab.2d.tagline')),
                title: L10n.text('Tag Study'),
              ),
              const SizedBox(height: 20),
              DecoratedBox(
                decoration: ShapeDecoration(
                  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [primary, studyEdge(primary)]),
                  shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(24)),
                  shadows: [BoxShadow(color: primary.withValues(alpha: 0.35), blurRadius: 40, offset: const Offset(0, 10))],
                ),
                child: ClipRSuperellipse(
                  borderRadius: BorderRadius.circular(24),
                  child: Stack(
                    children: [
                      // The course's guide leans in from the corner, behind nothing.
                      Positioned(
                        right: -8,
                        bottom: -6,
                        child: ExcludeSemantics(child: StudyMascot(pose: StudyMascotPose.wave, size: 132)),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(22, 22, 118, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              L10n.text('lab.2d.kicker'),
                              style: LabFont.text(11, weight: FontWeight.w700, color: white.withValues(alpha: 0.75), tracking: 1.6),
                            ),
                            const SizedBox(height: 6),
                            Text(L10n.text('Tag Study'), style: LabFont.voice(30, color: white)),
                            const SizedBox(height: 18),
                            feature('map.fill', L10n.text('lab.2d.lessons', ['${StudyPath.bundled.lessons.length}'])),
                            feature('tag.fill', L10n.text('lab.2d.tags', ['${StudyCurriculum.bundled.tags.length}'])),
                            feature('wand.and.stars', L10n.text('lab.2d.studio')),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (item != null && price != null) ...[
                const SizedBox(height: 20),
                LabButton(
                  key: const Key('lab.2d.buy'),
                  style: LabButtonStyle.primary,
                  expand: true,
                  onPressed: state.isBought
                      ? () async {
                          if (await confirmLabPurchase(context, item)) openTags();
                        }
                      : null,
                  child: Text(L10n.text('lab.shop.buy', ['$price'])),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    state.isBought
                        ? L10n.text('lab.2d.balance', ['${store.balance}'])
                        : L10n.text('lab.2d.short', ['${store.balance}', '${price - store.balance}']),
                    style: LabFont.text(13, color: labSecondary(context)),
                  ),
                ),
                const SizedBox(height: 20),
                Text(L10n.text('lab.2d.how'), style: LabFont.text(13, color: labSecondary(context))),
              ],
            ],
          ),
        );
      },
    );
  }
}
