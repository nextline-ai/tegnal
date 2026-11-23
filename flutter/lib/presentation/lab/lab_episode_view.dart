import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/lab/lab_course.dart';
import '../../core/lab/lab_store.dart';
import '../../core/support/l10n.dart';
import '../../core/support/privacy_settings.dart';
import '../design/glass.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';
import '../study_mode/study_kit.dart';
import 'lab_kit.dart';
import 'lab_pages.dart';
import 'lab_tools.dart';

// One episode, played full screen: the disaster and the choice, the tool, then the card's engraving.
// Ported from `LabEpisodeView.swift`.

/// Opens [episode] over everything, as the iOS full-screen cover does.
Future<void> showLabEpisode(BuildContext context, LabEpisode episode) => Navigator.of(context, rootNavigator: true).push(
  PageRouteBuilder<void>(
    opaque: true,
    transitionDuration: const Duration(milliseconds: 420),
    reverseTransitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (context, _, _) => LabEpisodeView(episode: episode),
    transitionsBuilder: (context, animation, _, child) => SlideTransition(
      position: Tween(
        begin: const Offset(0, 1),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic)),
      child: child,
    ),
  ),
);

enum _Phase { choice, tool, engrave, season }

class LabEpisodeView extends StatefulWidget {
  const LabEpisodeView({super.key, required this.episode, this.store});
  final LabEpisode episode;
  final LabStore? store;

  @override
  State<LabEpisodeView> createState() => _LabEpisodeViewState();
}

class _LabEpisodeViewState extends State<LabEpisodeView> {
  _Phase phase = _Phase.choice;

  /// The choice picked, shown with its verdict until the learner goes back to the choices.
  int? picked;
  final List<String> hungNow = [];
  bool passed = false;
  int toolRun = 0;
  final Stopwatch _clock = Stopwatch()..start();
  LabEngraving? engraving;

  /// A 망작 just won, shown over the chat until the learner has looked at it.
  LabFail? won;

  /// Choices pressed in this visit. They can be pressed again, but are drawn dimmed.
  final Set<int> tried = {};

  /// Counts wrong answers; each one washes the screen red for a moment.
  int mistakes = 0;

  void _mistake() {
    LabHaptic.miss();
    setState(() => mistakes += 1);
  }

  /// A choice pressed before: in this visit, a trap whose 망작 already hangs, or the right one of a card already engraved.
  bool _seen(int index) {
    if (tried.contains(index)) return true;
    final choice = episode.choices[index];
    if (choice.isRight) return store.earned(episode);
    final fail = episode.fails.where((fail) => fail.choice == choice.text).firstOrNull;
    return fail != null && store.hung(fail);
  }

  /// After the card is put in the deck: the season's own page when this card finished it, else back to the deck.
  void _closeEngraving() {
    if (engraving?.season == null) return Navigator.of(context).pop();
    setState(() => phase = _Phase.season);
  }

  LabEpisode get episode => widget.episode;
  LabStore get store => widget.store ?? LabStore.shared;

  void _pick(int index) {
    final choice = episode.choices[index];
    tried.add(index);
    if (choice.isRight) {
      LabHaptic.pass();
    } else {
      final fail = episode.fails.where((fail) => fail.choice == choice.text).firstOrNull;
      if (fail != null) {
        // No penalty: a red wash, a quiet tag, and the 망작 goes up in the gallery.
        _mistake();
        if (store.hang(fail)) {
          hungNow.add(fail.id);
          // Won for the first time: the answer is read in the chat first, then the 망작 comes up as a card won.
          Future<void>.delayed(const Duration(milliseconds: 650), () {
            if (mounted) setState(() => won = fail);
          });
        }
      }
    }
    setState(() => picked = index);
  }

  @override
  Widget build(BuildContext context) {
    final background = TegnalColors.background.resolveFrom(context);
    final won = this.won;
    return Stack(
      children: [
        Positioned.fill(
          child: LabMistake(signal: _mistake, child: _stage(context, background)),
        ),
        Positioned.fill(child: LabMistakeWash(count: mistakes)),
        if (won != null)
          Positioned.fill(
            child: LabFailReveal(key: ValueKey(won.id), fail: won, done: () => setState(() => this.won = null)),
          ),
      ],
    );
  }

  Widget _stage(BuildContext context, Color background) {
    return ColoredBox(
      color: background,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (phase == _Phase.choice || phase == _Phase.tool) _bar(context),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 450),
                switchInCurve: Curves.easeOutCubic,
                transitionBuilder: (child, animation) => phase == _Phase.tool && child.key == const ValueKey(_Phase.tool)
                    ? SlideTransition(
                        position: Tween(begin: const Offset(0.25, 0), end: Offset.zero).animate(animation),
                        child: FadeTransition(opacity: animation, child: child),
                      )
                    : FadeTransition(opacity: animation, child: child),
                child: switch (phase) {
                  _Phase.choice => KeyedSubtree(key: const ValueKey(_Phase.choice), child: _choiceStage(context)),
                  _Phase.tool => KeyedSubtree(key: const ValueKey(_Phase.tool), child: _toolStage(context)),
                  _Phase.engrave => LabEngraveView(
                    key: const ValueKey(_Phase.engrave),
                    episode: episode,
                    engraving: engraving,
                    seconds: _clock.elapsed.inSeconds,
                    store: store,
                    done: _closeEngraving,
                  ),
                  _Phase.season => LabSeasonCompleteView(
                    key: const ValueKey(_Phase.season),
                    season: store.course.seasons.firstWhere((season) => season.number == engraving!.season),
                    store: store,
                    done: () => Navigator.of(context).pop(),
                  ),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The close button, four short bars for disaster, choice, tool and engraving, and the tool's reset.
  Widget _bar(BuildContext context) {
    final reached = phase == _Phase.choice ? (picked == null ? 1 : 2) : (phase == _Phase.tool ? 3 : 4);
    final label = labLabel(context);
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            _circle(context, CupertinoIcons.xmark, L10n.text('Close'), const Key('lab.episode.close'), () => Navigator.of(context).pop()),
            Expanded(
              child: Center(
                child: Semantics(
                  label: L10n.text('lab.episode.step', ['$reached', '4']),
                  child: SizedBox(
                    width: 150,
                    child: Row(
                      children: [
                        for (var index = 0; index < 4; index++) ...[
                          if (index > 0) const SizedBox(width: 4),
                          Expanded(
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 300),
                              height: 4,
                              decoration: ShapeDecoration(
                                color: index < reached ? label : labSecondary(context).withValues(alpha: 0.3),
                                shape: const StadiumBorder(),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (phase == _Phase.tool)
              _circle(context, CupertinoIcons.arrow_counterclockwise, L10n.text('lab.tool.again'), const Key('lab.tool.again'), () {
                setState(() {
                  toolRun += 1;
                  passed = false;
                });
              })
            else
              const SizedBox(width: 44),
          ],
        ),
      ),
    );
  }

  Widget _circle(BuildContext context, IconData icon, String label, Key key, VoidCallback onTap) => Semantics(
    button: true,
    label: label,
    child: GestureDetector(
      key: key,
      onTap: onTap,
      child: Glass.circle(
        child: SizedBox.square(dimension: 44, child: Icon(icon, size: 19, color: labLabel(context))),
      ),
    ),
  );

  // MARK: The disaster and the choice

  Widget _choiceStage(BuildContext context) {
    final choice = picked == null ? null : episode.choices[picked!];
    final ask = choice?.fail != null ? '${episode.disaster.ask.text}\n+ ${choice!.text.text}' : episode.disaster.ask.text;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        // On a short screen the choices stay in view; the chat above scrolls.
        reverse: true,
        padding: EdgeInsets.fromLTRB(20, 12, 20, 12 + MediaQuery.paddingOf(context).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight - 24 - MediaQuery.paddingOf(context).bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                children: [
                  LabBubble(text: ask, mine: true),
                  const SizedBox(height: 10),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: LabBubble(key: ValueKey(picked), text: choice?.fail?.reply.text ?? episode.disaster.reply.text),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 28),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: picked == null || choice == null
                      ? KeyedSubtree(key: const ValueKey('opening'), child: _opening(context))
                      : KeyedSubtree(key: ValueKey('verdict$picked'), child: _verdict(context, choice)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _opening(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Semantics(
        header: true,
        child: Text(
          labWords(episode.disaster.verdict.text),
          key: const Key('lab.disaster'),
          style: LabFont.voice(29, color: labLabel(context)),
        ),
      ),
      const SizedBox(height: 8),
      Text(labWords(episode.disaster.question.text), style: LabFont.text(15, color: labSecondary(context))),
      const SizedBox(height: 16),
      for (final (index, choice) in episode.choices.indexed) ...[
        // Already pressed: it can be pressed again, but reads as done.
        Semantics(
          value: _seen(index) ? L10n.text('lab.choice.seen') : null,
          child: Opacity(
            opacity: _seen(index) ? 0.42 : 1,
            child: LabButton(
              key: Key('lab.choice.$index'),
              onPressed: () => _pick(index),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      studyWords(choice.text.text),
                      textAlign: TextAlign.left,
                      style: LabFont.text(16, weight: FontWeight.w600, color: labLabel(context)),
                    ),
                  ),
                  if (_seen(index)) ...[
                    const SizedBox(width: 10),
                    Icon(CupertinoIcons.checkmark_alt, key: Key('lab.choice.seen.$index'), size: 16, color: labLabel(context)),
                  ],
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    ],
  );

  Widget _verdict(BuildContext context, LabChoice choice) {
    final fail = choice.isRight ? null : episode.fails.where((fail) => fail.choice == choice.text).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (choice.isRight)
          LabTag(text: L10n.text('lab.pass'), color: LabPalette.pass.resolveFrom(context))
        else if (fail != null)
          LabTag(
            key: const Key('lab.fail.tag'),
            text: L10n.text('lab.fail.hung', [store.number(fail).toString().padLeft(2, '0')]),
            color: LabPalette.fail.resolveFrom(context),
          ),
        const SizedBox(height: 8),
        Text(
          labWords(choice.verdict.text),
          key: const Key('lab.verdict'),
          style: LabFont.voice(25, color: labLabel(context)),
        ),
        if (choice.why case final why?) ...[const SizedBox(height: 8), Text(labWords(why.text), style: LabFont.text(15, color: labSecondary(context)))],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: LabButton(
                key: const Key('lab.choice.back'),
                onPressed: () => setState(() => picked = null),
                expand: true,
                child: Text(L10n.text(choice.isRight ? 'lab.choice.seeFails' : 'lab.choice.tryOthers')),
              ),
            ),
            if (choice.isRight) ...[
              const SizedBox(width: 8),
              Expanded(
                child: LabButton(
                  key: const Key('lab.choice.next'),
                  style: LabButtonStyle.primary,
                  onPressed: () => setState(() => phase = _Phase.tool),
                  expand: true,
                  child: Text(L10n.text('lab.choice.tryIt')),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  // MARK: The tool

  Widget _toolStage(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    labWords(episode.tool.title.text),
                    style: LabFont.text(22, weight: FontWeight.w700, color: labLabel(context)),
                  ),
                ),
                if (episode.tool.hint case final hint?) ...[
                  const SizedBox(height: 4),
                  Text(labWords(hint.text), style: LabFont.text(15, color: labSecondary(context))),
                ],
                const SizedBox(height: 18),
                LabToolView(key: ValueKey(toolRun), tool: episode.tool, passed: passed, onPass: () => setState(() => passed = true)),
              ],
            ),
          ),
        ),
        ColoredBox(
          color: TegnalColors.background.resolveFrom(context),
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, 10, 20, 10 + bottom),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              transitionBuilder: (child, animation) => SlideTransition(
                position: Tween(begin: const Offset(0, 0.4), end: Offset.zero).animate(animation),
                child: FadeTransition(opacity: animation, child: child),
              ),
              child: passed
                  ? LabButton(
                      key: const Key('lab.tool.engrave'),
                      style: LabButtonStyle.primary,
                      expand: true,
                      onPressed: () => setState(() {
                        engraving = store.engrave(episode, failsHung: hungNow.length);
                        phase = _Phase.engrave;
                      }),
                      child: Text(L10n.text(store.earned(episode) && engraving == null ? 'lab.tool.finish' : 'lab.tool.engrave')),
                    )
                  : SizedBox(
                      height: 52,
                      width: double.infinity,
                      child: CustomPaint(
                        painter: _DashedBox(labSecondary(context).withValues(alpha: 0.4)),
                        child: Center(
                          child: Text(
                            L10n.text('lab.tool.pending'),
                            style: LabFont.text(14, weight: FontWeight.w600, color: labSecondary(context)),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DashedBox extends CustomPainter {
  _DashedBox(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addRSuperellipse(RSuperellipse.fromRectAndRadius((Offset.zero & size).deflate(0.5), const Radius.circular(18)));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final metric in path.computeMetrics()) {
      for (var distance = 0.0; distance < metric.length; distance += 9) {
        canvas.drawPath(metric.extractPath(distance, distance + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBox old) => old.color != color;
}

// MARK: - The engraving

/// The reward: the blank card turns over in one movement and comes up in its colour, its line is pressed in one letter
/// at a time, light crosses it once, and only then the numbers settle in below. The longest moment in the lab.
class LabEngraveView extends StatefulWidget {
  const LabEngraveView({super.key, required this.episode, required this.engraving, required this.seconds, required this.store, required this.done});
  final LabEpisode episode;
  final LabEngraving? engraving;
  final int seconds;
  final LabStore store;
  final VoidCallback done;

  @override
  State<LabEngraveView> createState() => _LabEngraveViewState();
}

class _LabEngraveViewState extends State<LabEngraveView> with TickerProviderStateMixin {
  late final AnimationController _flip = AnimationController(vsync: this, duration: const Duration(milliseconds: 1050));
  late final AnimationController _reveal = AnimationController(vsync: this);
  late final AnimationController _sheen = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  final _card = GlobalKey();
  bool settled = false;
  int? shownRate;

  /// The balance as shown: from before the engraving, climbing to now once the numbers settle in.
  int? shownBalance;
  bool _gone = false;

  LabEpisode get episode => widget.episode;

  @override
  void initState() {
    super.initState();
    unawaited(_play());
  }

  @override
  void dispose() {
    _gone = true;
    _flip.dispose();
    _reveal.dispose();
    _sheen.dispose();
    super.dispose();
  }

  Future<void> _wait(int milliseconds) => Future<void>.delayed(Duration(milliseconds: milliseconds));

  Future<void> _play() async {
    final line = episode.card.line.text;
    final count = line.characters.length;
    if (MediaQueryData.fromView(ui.PlatformDispatcher.instance.views.first).disableAnimations) {
      _flip.value = 1;
      _reveal.value = 1;
      setState(() {
        settled = true;
        shownRate = widget.engraving?.after;
        shownBalance = widget.store.balance;
      });
      return;
    }
    await _wait(450);
    if (_gone) return;
    LabHaptic.snap();
    // One unbroken turn: the paper goes edge-on and comes round as the coloured card, settling with a small give.
    unawaited(_flip.animateWith(SpringSimulation(const SpringDescription(mass: 1, stiffness: 36, damping: 9.5), 0, 1, 0)));
    await _wait(950);
    if (_gone) return;
    // The line is pressed in one letter at a time, felt as a run of soft taps.
    const step = 75;
    _reveal.duration = Duration(milliseconds: count * step + 200);
    unawaited(_reveal.forward());
    for (final glyph in line.characters) {
      if (_gone) return;
      if (glyph != ' ') LabHaptic.press();
      await _wait(step);
    }
    unawaited(_sheen.animateTo(1, curve: Curves.easeInOut));
    await _wait(350);
    if (_gone) return;
    setState(() => settled = true);
    await _wait(250);
    if (_gone) return;
    setState(() => shownRate = widget.engraving?.after);
    if (widget.engraving?.first == true) LabHaptic.pass();
    // Then the 보석, once the rate has moved.
    await _wait(600);
    if (_gone) return;
    if ((widget.engraving?.total ?? 0) > 0) LabHaptic.tick();
    setState(() => shownBalance = widget.store.balance);
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final line = episode.card.line.text;
    final count = line.characters.length;
    final engraving = widget.engraving;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final color = store.course.color(episode);
    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: FormColors.listBackground.resolveFrom(context))),
        LayoutBuilder(
          builder: (context, constraints) {
            final height = (constraints.maxHeight * 0.5).clamp(250.0, 352.0);
            return SingleChildScrollView(
              clipBehavior: Clip.none,
              padding: EdgeInsets.fromLTRB(20, 16, 20, 100 + bottom),
              child: Column(
                children: [
                  Text(
                    '${widget.seconds ~/ 60}:${(widget.seconds % 60).toString().padLeft(2, '0')} · ${L10n.text('lab.engrave.done')}',
                    style: LabFont.number(12, color: labSecondary(context), tracking: 1.2),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    engraving?.first == false
                        ? L10n.text('lab.engrave.again')
                        : L10n.text('lab.engrave.title', [labOrdinal(store.earnedCards.isEmpty ? 1 : store.earnedCards.length)]),
                    key: const Key('lab.engrave.title'),
                    textAlign: TextAlign.center,
                    style: LabFont.text(24, weight: FontWeight.w700, color: labLabel(context)),
                  ),
                  const SizedBox(height: 22),
                  Semantics(
                    label: line,
                    child: AnimatedBuilder(
                      animation: Listenable.merge([_flip, _reveal, _sheen]),
                      builder: (context, _) {
                        final angle = _flip.value * 180;
                        return SizedBox(
                          key: const Key('lab.engrave.card'),
                          width: height * 280 / 352,
                          height: height,
                          child: DecoratedBox(
                            // The shadow follows the card's outline, never its printing.
                            decoration: ShapeDecoration(
                              shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(24)),
                              shadows: [
                                BoxShadow(
                                  color: angle > 90 ? LabPalette.hex(color).withValues(alpha: 0.5) : const Color(0x40000000),
                                  blurRadius: 56,
                                  offset: const Offset(0, 16),
                                ),
                              ],
                            ),
                            child: LabFlip(
                              angle: angle,
                              front: LabCardFace(
                                serial: '${episode.serial} · ${L10n.text('lab.card.blank')}',
                                title: episode.title.text,
                                state: LabCardState.blank,
                                large: true,
                              ),
                              back: RepaintBoundary(
                                key: _card,
                                child: Stack(
                                  children: [
                                    Positioned.fill(
                                      child: LabCardFace(
                                        serial: episode.serial,
                                        title: episode.title.text,
                                        line: line,
                                        color: color,
                                        state: LabCardState.earned,
                                        footer: store.course.footer(episode),
                                        date: labStamp(store.engraved(episode) ?? LabStore.now),
                                        engraved: _reveal.value * (count + 1),
                                        large: true,
                                      ),
                                    ),
                                    Positioned.fill(
                                      child: ClipRSuperellipse(
                                        borderRadius: BorderRadius.circular(24),
                                        child: LabSheen(progress: _sheen.value),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 22),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 500),
                    transitionBuilder: (child, animation) => SlideTransition(
                      position: Tween(begin: const Offset(0, 0.3), end: Offset.zero).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutBack)),
                      child: FadeTransition(opacity: animation, child: child),
                    ),
                    child: engraving != null && settled ? _rows(context, engraving) : const SizedBox(width: double.infinity),
                  ),
                ],
              ),
            );
          },
        ),
        Positioned(
          left: 20,
          right: 20,
          bottom: 10 + bottom,
          child: IgnorePointer(
            ignoring: !settled,
            child: AnimatedSlide(
              offset: settled ? Offset.zero : const Offset(0, 0.4),
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeOutBack,
              child: AnimatedOpacity(
                opacity: settled ? 1 : 0,
                duration: const Duration(milliseconds: 300),
                child: Row(
                  children: [
                    LabButton(
                      key: const Key('lab.share'),
                      label: L10n.text('lab.share'),
                      onPressed: () => labShare(_card, episode.card.line.text),
                      child: const Icon(CupertinoIcons.share),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: LabButton(
                        key: const Key('lab.engrave.put'),
                        style: LabButtonStyle.primary,
                        expand: true,
                        onPressed: widget.done,
                        child: Text(L10n.text('lab.engrave.put')),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// The rate, the 보석 and the 망작, grouped as a stock inset list draws them.
  Widget _rows(BuildContext context, LabEngraving engraving) {
    final secondary = labSecondary(context), label = labLabel(context);
    Widget row(Key? key, String title, List<Widget> trailing) => Padding(
      key: key,
      padding: const EdgeInsets.only(right: 16),
      child: SizedBox(
        height: 50,
        child: Row(
          children: [
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: LabFont.text(17, color: label),
              ),
            ),
            const SizedBox(width: 8),
            // The numbers keep their line, shrinking a little on a narrow screen.
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(mainAxisSize: MainAxisSize.min, children: trailing),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    final divider = Container(height: 0.5, color: TegnalColors.separator.resolveFrom(context));
    return Container(
      key: const ValueKey('rows'),
      padding: const EdgeInsets.only(left: 16),
      decoration: ShapeDecoration(
        color: FormColors.listRow.resolveFrom(context),
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(22)),
      ),
      child: Column(
        children: [
          row(const Key('lab.engrave.rate'), widget.store.course.info.gauge.text, [
            Text('${engraving.before}% → ', style: LabFont.number(17, color: secondary)),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: engraving.before.toDouble(), end: (shownRate ?? engraving.before).toDouble()),
              duration: const Duration(milliseconds: 1200),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => Text('${value.round()}%', style: LabFont.number(17, color: LabPalette.gauge.resolveFrom(context))),
            ),
          ]),
          // An imported course pays no 보석, so it has no row for it.
          if (!widget.store.course.imported) ...[
            divider,
            // The balance climbs from before the card to now, as the rate does above; what paid sits under it.
            Builder(
              builder: (context) {
                final before = widget.store.balance - engraving.total;
                final gauge = LabPalette.gauge.resolveFrom(context);
                return Padding(
                  key: const Key('lab.engrave.income'),
                  padding: const EdgeInsets.only(right: 16, top: 9, bottom: 9),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 3,
                    children: [
                      Row(
                        children: [
                          Icon(CupertinoIcons.rhombus_fill, size: 17, color: gauge),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(widget.store.shop.currency.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: LabFont.text(17, color: label)),
                          ),
                          Text('$before → ', style: LabFont.number(17, color: secondary)),
                          TweenAnimationBuilder<double>(
                            tween: Tween(begin: before.toDouble(), end: (shownBalance ?? before).toDouble()),
                            duration: const Duration(milliseconds: 1200),
                            curve: Curves.easeOutCubic,
                            builder: (context, value, _) => Text('${value.round()}', style: LabFont.number(17, color: gauge)),
                          ),
                        ],
                      ),
                      Text(
                        engraving.seasonReward > 0
                            ? L10n.text('lab.engrave.gemsSeason', ['${engraving.total}', '${engraving.cardReward}', '${engraving.failReward}', '${engraving.seasonReward}'])
                            : L10n.text('lab.engrave.gemsDetail', ['${engraving.total}', '${engraving.cardReward}', '${engraving.failReward}']),
                        style: LabFont.text(13, color: secondary),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
          divider,
          row(null, L10n.text('lab.engrave.fails'), [
            Text(L10n.text('lab.count.pieces', ['${engraving.failsHung}']), style: LabFont.number(15, color: LabPalette.fail.resolveFrom(context))),
            const SizedBox(width: 4),
            Text(
              engraving.failsLeft == 0 ? L10n.text('lab.engrave.allFails') : L10n.text('lab.engrave.failsLeft', ['${engraving.failsLeft}']),
              style: LabFont.text(13, color: secondary),
            ),
          ]),
        ],
      ),
    );
  }
}

const _screen = MethodChannel('work.nextline.tegnal/screen');

/// Shares a picture of the card under [key] through the system share sheet, as the iOS ShareLink does.
Future<void> labShare(GlobalKey key, String title) async {
  final boundary = key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
  if (boundary == null) return;
  try {
    final image = await boundary.toImage(pixelRatio: 3);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) return;
    // Only this folder is offered to other apps through the app's file provider.
    final folder = Directory('${(await getApplicationCacheDirectory()).path}/shared');
    await folder.create(recursive: true);
    final file = File('${folder.path}/TEGNAL AI Lab.png');
    await file.writeAsBytes(data.buffer.asUint8List());
    await AppAway.run(() => _screen.invokeMethod<void>('shareImage', {'path': file.path, 'title': title}));
  } on Object catch (error) {
    debugPrint('Lab share: $error');
  }
}

// MARK: - A season finished

/// Shown once, right after the card that finishes a season is put in the deck: the season's cards fan out in their colours,
/// with what the season added up to and the season that opens next (`LabSeasonCompleteView`).
class LabSeasonCompleteView extends StatefulWidget {
  const LabSeasonCompleteView({super.key, required this.season, required this.store, required this.done});
  final LabSeason season;
  final LabStore store;
  final VoidCallback done;

  @override
  State<LabSeasonCompleteView> createState() => _LabSeasonCompleteViewState();
}

class _LabSeasonCompleteViewState extends State<LabSeasonCompleteView> with TickerProviderStateMixin {
  late final AnimationController _fan = AnimationController(vsync: this, duration: const Duration(milliseconds: 800));
  late final AnimationController _settle = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));

  @override
  void initState() {
    super.initState();
    LabHaptic.pass();
    _fan.forward();
    Future<void>.delayed(const Duration(milliseconds: 450), () {
      if (mounted) _settle.forward();
    });
  }

  @override
  void dispose() {
    _fan.dispose();
    _settle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store, season = widget.season, course = store.course;
    final cards = [for (final id in season.episodes) ?course.episode(id)];
    final fails = [for (final card in cards) ...card.fails];
    final next =
        course.seasons.where((value) => value.opensAfter == season.number).firstOrNull ??
        course.seasons.where((value) => value.number > season.number).firstOrNull;
    final secondary = labSecondary(context);
    final middle = (cards.length - 1) / 2;
    Widget stat(String title, String value) => Expanded(
      child: Column(
        children: [
          Text(value, style: LabFont.number(19, color: labLabel(context))),
          const SizedBox(height: 4),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: LabFont.text(12, color: secondary),
          ),
        ],
      ),
    );
    return ColoredBox(
      color: TegnalColors.background.resolveFrom(context),
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 24, 20, MediaQuery.paddingOf(context).bottom + 10),
        child: Column(
          children: [
            const Spacer(),
            SizedBox(
              height: 190,
              child: AnimatedBuilder(
                animation: _fan,
                builder: (context, _) {
                  final t = Curves.easeOutBack.transform(_fan.value);
                  return Opacity(
                    opacity: _fan.value.clamp(0, 1),
                    child: Transform.scale(
                      scale: 0.7 + 0.3 * t,
                      child: Stack(
                        alignment: Alignment.bottomCenter,
                        children: [
                          for (final (index, card) in cards.indexed)
                            Transform.translate(
                              offset: Offset((index - middle) * 34 * t, (index - middle).abs() * 6 * t),
                              child: Transform.rotate(
                                angle: (index - middle) * 9 * t * 3.1415926 / 180,
                                alignment: Alignment.bottomCenter,
                                child: Container(
                                  width: 96,
                                  height: 136,
                                  padding: const EdgeInsets.all(10),
                                  alignment: Alignment.topLeft,
                                  decoration: ShapeDecoration(
                                    color: LabPalette.hex(course.color(card)),
                                    shape: RoundedSuperellipseBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      side: const BorderSide(color: Color(0x2EFFFFFF), width: 0.75),
                                    ),
                                    shadows: const [BoxShadow(color: Color(0x4D000000), blurRadius: 20, offset: Offset(0, 6))],
                                  ),
                                  child: Text(card.digits, style: LabFont.number(12, color: const Color(0xD9FFFFFF))),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            FadeTransition(
              opacity: _settle,
              child: Column(
                children: [
                  const SizedBox(height: 28),
                  Text(
                    L10n.text('lab.season.done', ['${season.number}']),
                    key: const Key('lab.season.done'),
                    style: LabFont.text(13, weight: FontWeight.w700, color: LabPalette.pass.resolveFrom(context), tracking: 1.4),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    season.title.text,
                    textAlign: TextAlign.center,
                    style: LabFont.voice(28, color: labLabel(context)),
                  ),
                  if (season.summary case final summary?) ...[
                    const SizedBox(height: 10),
                    Text(
                      summary.text,
                      textAlign: TextAlign.center,
                      style: LabFont.text(15, color: secondary),
                    ),
                  ],
                  const SizedBox(height: 26),
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: ShapeDecoration(
                      color: FormColors.listRow.resolveFrom(context),
                      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(20)),
                    ),
                    child: Row(
                      children: [
                        stat(L10n.text('lab.season.cards'), '${cards.length}'),
                        stat(course.info.gauge.text, '${store.rate}%'),
                        stat(L10n.text('lab.season.fails'), '${fails.where(store.hung).length}/${fails.length}'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(),
            FadeTransition(
              opacity: _settle,
              child: Column(
                children: [
                  Text(
                    next == null ? L10n.text('lab.season.all') : L10n.text('lab.season.next', ['${next.number}', next.title.text]),
                    textAlign: TextAlign.center,
                    style: LabFont.text(14, weight: FontWeight.w600, color: secondary),
                  ),
                  const SizedBox(height: 10),
                  LabButton(
                    key: const Key('lab.season.continue'),
                    style: LabButtonStyle.primary,
                    expand: true,
                    onPressed: widget.done,
                    child: Text(L10n.text('lab.season.continue')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
