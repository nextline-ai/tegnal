import 'dart:async';
import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/booru/booru_models.dart';
import '../../core/generation/generation_store.dart';
import '../../core/study/study_store.dart';
import '../../core/study/study_engine.dart';
import '../../core/study/study_models.dart';
import '../../core/study/study_path.dart';
import '../../core/support/l10n.dart';
import '../../core/taste/taste_models.dart';
import '../booru/booru_common.dart';
import '../booru/booru_post_view.dart';
import '../design/app_sheet.dart';
import '../generation/generator_account_view.dart';
import '../generation/generator_sheet.dart';
import '../generation/generator_view.dart';
import 'study_kit.dart';
import 'study_lesson_parts.dart';
import 'study_lesson_result.dart';
import 'study_lesson_steps.dart';
import 'study_mode_model.dart';
import 'study_reactions.dart';

/// A lesson played from its first step to its results (`StudyPlayView`). A full page: it pops itself when the
/// learner leaves or presses the last Continue.
class StudyPlayView extends StatefulWidget {
  const StudyPlayView({super.key, required this.booru, required this.session, required this.model});

  final BooruContext booru;
  final StudyLessonSession session;
  final StudyModeModel model;

  @override
  State<StudyPlayView> createState() => _StudyPlayViewState();
}

class _StudyPlayViewState extends State<StudyPlayView> {
  static final _snappy = StudySpring(0.28, 0.15);
  static final _bannerSpring = StudySpring(0.4, 0.5);
  static final _comboSpring = StudySpring(0.3, 0.4);

  /// Counts right answers, to set off the bounce of the bar.
  int _cheers = 0;
  String _praise = '';
  int? _banner;
  Timer? _bannerTimer;
  late StudyLessonPhase _phase;

  StudyLessonSession get _session => widget.session;

  bool? get _feedback => _session.phase.isFeedback ? _session.phase.right : null;

  @override
  void initState() {
    super.initState();
    _phase = _session.phase;
    _session.addListener(_changed);
    unawaited(_session.start());
  }

  @override
  void didUpdateWidget(StudyPlayView old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      old.session.removeListener(_changed);
      widget.session.addListener(_changed);
      _phase = widget.session.phase;
    }
  }

  @override
  void dispose() {
    _session.removeListener(_changed);
    _bannerTimer?.cancel();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final phase = _session.phase;
    if (phase != _phase) {
      _phase = phase;
      _react(phase);
    }
    setState(() {});
  }

  /// Answers what just happened with a sound, a word and a movement.
  void _react(StudyLessonPhase phase) {
    if (!phase.isFeedback) return;
    final right = phase.right ?? false;
    right ? HapticFeedback.mediumImpact() : HapticFeedback.heavyImpact();
    _praise = StudyPraise.line(right: right, combo: _session.combo, seed: _session.index * 7 + _session.asked);
    if (right) {
      _cheers += 1;
      if (StudyPraise.runs.contains(_session.combo)) {
        StudySound.combo.play();
        final combo = _session.combo;
        _banner = combo;
        _bannerTimer?.cancel();
        _bannerTimer = Timer(const Duration(milliseconds: 1500), () {
          if (mounted && _banner == combo) setState(() => _banner = null);
        });
      } else {
        StudySound.right.play();
      }
    } else {
      StudySound.wrong.play();
    }
  }

  /// Opens a picture in the library's own image viewer, where it can be zoomed, translated, saved and filed.
  void _open(BooruPost post, List<BooruPost> among) {
    // What is saved in the viewer is filed under the picture's server. A server only learning mode knew
    // (Safebooru, for a learner with no server of their own) joins the library, so that the save is found there.
    final store = widget.booru.store;
    final server = _session.server;
    if (!store.servers.any((other) => other.id == server.id)) {
      try {
        store.saveServer(server);
        widget.booru.booruDefaults.set(StudyServer.key, server.id);
      } on Object {
        // The picture still opens.
      }
    }
    final posts = among.any((other) => other.id == post.id) ? among : [post];
    BooruPostView.open(context, booru: widget.booru, post: post, posts: posts, discovery: DiscoveryContext.unknown, source: _session.source);
  }

  void _leave() => Navigator.of(context).pop();

  Future<void> _close() async {
    if (_session.index == 0) return _leave();
    final leave = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(L10n.text('Leave this lesson?')),
        message: Text(L10n.text('What you did in this lesson will not be kept.')),
        actions: [CupertinoActionSheetAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Leave')))],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (leave == true && mounted) _leave();
  }

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final phase = _session.phase;
    final finished = phase == StudyLessonPhase.finished;
    final step = _session.step;
    final Widget body;
    if (phase == StudyLessonPhase.loading) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 16,
          children: [
            const StudyMascot(pose: StudyMascotPose.think, size: 130),
            Text(L10n.text('Getting the pictures ready…'), style: StudyTheme.body(17, StudyTheme.bold).copyWith(color: theme.muted)),
            const CupertinoActivityIndicator(),
          ],
        ),
      );
    } else if (finished) {
      body = StudyLessonResult(booru: widget.booru, session: _session, model: widget.model, done: _leave);
    } else if (step != null) {
      body = AnimatedSwitcher(
        duration: _snappy.settle,
        switchInCurve: _snappy,
        switchOutCurve: _snappy,
        layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
        transitionBuilder: (child, animation) {
          // A new step slides in from the trailing edge; the old one slides out to the leading edge.
          final incoming = child.key == ValueKey(step.id);
          return SlideTransition(
            position: animation.drive(Tween(begin: Offset(incoming ? 1 : -1, 0), end: Offset.zero)),
            child: FadeTransition(opacity: animation.drive(_Clamped()), child: child),
          );
        },
        child: KeyedSubtree(key: ValueKey(step.id), child: _content(step)),
      );
    } else {
      body = const SizedBox.expand();
    }
    final top = MediaQuery.paddingOf(context).top;
    return StudyPictureOpener(
      open: _open,
      child: ColoredBox(
        color: theme.background,
        child: Stack(
          children: [
            Column(
              children: [
                if (!finished)
                  Padding(
                    padding: EdgeInsets.only(top: top),
                    child: _bar(theme),
                  ),
                Expanded(
                  child: finished ? body : MediaQuery.removePadding(context: context, removeTop: true, child: body),
                ),
              ],
            ),
            // A run of right answers is called out over the lesson.
            Positioned(
              top: top + 58,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: AnimatedSwitcher(
                    duration: _bannerSpring.settle,
                    switchInCurve: _bannerSpring,
                    switchOutCurve: _bannerSpring,
                    transitionBuilder: (child, animation) => ScaleTransition(
                      scale: animation.drive(Tween(begin: 0.3, end: 1.0)),
                      child: FadeTransition(opacity: animation.drive(_Clamped()), child: child),
                    ),
                    child: _banner == null
                        ? const SizedBox.shrink()
                        : KeyedSubtree(
                            key: ValueKey('combo.$_banner'),
                            child: StudyComboBanner(combo: _banner!),
                          ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bar(StudyTheme theme) {
    final combo = _session.combo;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Semantics(
            button: true,
            label: L10n.text('Close'),
            child: GestureDetector(
              key: const Key('study.close'),
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              child: SizedBox.square(
                dimension: 36,
                child: Center(
                  child: ExcludeSemantics(child: StudyIcon('xmark', size: 17, color: theme.muted)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: _Bounce(
              trigger: _cheers,
              child: StudyBar(key: const Key('study.progress'), value: _session.progress),
            ),
          ),
          AnimatedSize(
            duration: _comboSpring.settle,
            curve: _comboSpring,
            child: AnimatedSwitcher(
              duration: _comboSpring.settle,
              switchInCurve: _comboSpring,
              switchOutCurve: _comboSpring,
              transitionBuilder: (child, animation) => ScaleTransition(
                scale: animation,
                child: FadeTransition(opacity: animation.drive(_Clamped()), child: child),
              ),
              child: combo >= 2
                  ? Padding(
                      key: const ValueKey('flame'),
                      padding: const EdgeInsets.only(left: 14),
                      child: Semantics(
                        label: L10n.text('Right in a row: %@', ['$combo']),
                        child: ExcludeSemantics(
                          child: StudyStat(symbol: 'flame.fill', color: theme.flame, value: '$combo'),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(key: ValueKey('none')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(StudyStep step) {
    final feedback = _feedback;
    final revealed = feedback != null;
    final session = _session;
    final server = session.server;
    final Widget content = switch (step.kind) {
      StudyStepCard(:final card) => _StudyCardStep(booru: widget.booru, card: card, proceed: session.proceed),
      StudyStepTeach(:final tag, :final posts) => _StudyTeachStep(booru: widget.booru, tag: tag, posts: posts, server: server, proceed: session.proceed),
      StudyStepQuiz(:final question) => _StudyQuizStep(
        booru: widget.booru,
        question: question,
        server: server,
        revealed: revealed,
        answer: (right) => session.answer(right, tag: question.tag.name),
      ),
      StudyStepAsk(:final ask) => _StudyAskStep(ask: ask, revealed: revealed, answer: session.answer),
      StudyStepMatch(:final tags) => StudyMatchStep(tags: tags, revealed: revealed, answer: session.answer),
      StudyStepBuild(:final build) => StudyBuildStep(
        booru: widget.booru,
        build: build,
        picture: session.builtPictures[build],
        server: server,
        revealed: revealed,
        answer: session.answer,
      ),
      StudyStepOrder(:final order) => StudyOrderStep(order: order, revealed: revealed, answer: session.answer),
      StudyStepSort(:final sort) => StudySortStep(sort: sort, revealed: revealed, answer: session.answer),
      StudyStepOdd(:final post, :final choices, :final answer) => _StudyOddStep(
        booru: widget.booru,
        post: post,
        choices: choices,
        answer: answer,
        server: server,
        revealed: revealed,
        done: (right) => session.answer(right, tag: choices[answer].name),
      ),
      StudyStepSpell(:final tag, :final post) => _StudySpellStep(
        booru: widget.booru,
        tag: tag,
        post: post,
        server: server,
        revealed: revealed,
        done: (right) => session.answer(right, tag: tag.name),
      ),
    };
    return Column(
      children: [
        Expanded(
          child: MediaQuery.removePadding(context: context, removeBottom: revealed, child: content),
        ),
        if (feedback != null) _VerdictRise(child: _verdict(feedback, step)),
      ],
    );
  }

  /// What was right, said once an answer is in, and the way on. The guide is glad or sorry with the learner.
  Widget _verdict(bool right, StudyStep step) {
    final theme = StudyTheme.of(context);
    final color = right ? theme.good : theme.bad;
    final String? detail = switch (step.kind) {
      StudyStepQuiz(:final question) => '`${question.tag.english}` · ${question.tag.note.resolved()}',
      StudyStepAsk(:final ask) => ask.why.resolved(),
      StudyStepBuild(:final build) => '`${StudyPrompt.text(build.answer, style: StudyPromptStyle.natural)}`',
      StudyStepOrder(:final order) => order.why.resolved(),
      StudyStepSort(:final sort) => sort.why.resolved(),
      StudyStepOdd(:final choices, :final answer) => L10n.text('This picture does not carry `%@`.', [choices[answer].english]),
      StudyStepSpell(:final tag) => '`${tag.english}` · ${tag.note.resolved()}',
      _ => null,
    };
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(color: Color.alphaBlend(color.withValues(alpha: 0.16), theme.surface)),
            child: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                height: 2,
                width: double.infinity,
                child: ColoredBox(color: color.withValues(alpha: 0.5)),
              ),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(left: 18, right: 18, top: 14, bottom: 8 + bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                spacing: 10,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 8,
                      children: [
                        _VerdictLine(right: right, text: _praise.isEmpty ? L10n.text(right ? "That's right!" : 'Not quite') : _praise, color: color),
                        if (detail != null) StudyRichText(detail, size: 15),
                      ],
                    ),
                  ),
                  _StudyVerdictGuide(right: right),
                ],
              ),
              StudyMainButton(
                key: const Key('study.next'),
                title: L10n.text('Continue'),
                color: color,
                onPressed: () {
                  StudySound.tap.play();
                  _session.next();
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The praise line of a verdict, which shakes its head on a miss.
class _VerdictLine extends StatefulWidget {
  const _VerdictLine({required this.right, required this.text, required this.color});
  final bool right;
  final String text;
  final Color color;

  @override
  State<_VerdictLine> createState() => _VerdictLineState();
}

class _VerdictLineState extends State<_VerdictLine> {
  double _travel = 0;

  @override
  void initState() {
    super.initState();
    // The miss is counted just after the verdict appears, so the line shakes once it is on screen.
    if (!widget.right) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _travel = 1);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = StudyTheme.title(22).copyWith(color: widget.color);
    return Semantics(
      key: const Key('study.verdict'),
      container: true,
      value: widget.right ? 'right' : 'wrong',
      child: StudyShake(
        travel: _travel,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          spacing: 8,
          children: [
            StudyIcon(widget.right ? 'checkmark.circle.fill' : 'xmark.circle.fill', size: 22, color: widget.color),
            Flexible(child: Text(widget.text, style: style)),
          ],
        ),
      ),
    );
  }
}

/// The guide beside a verdict: it jumps in cheering for a right answer and droops for a wrong one
/// (`StudyVerdictGuide`). It stands 40 points above the row it sits in.
class _StudyVerdictGuide extends StatefulWidget {
  const _StudyVerdictGuide({required this.right});
  final bool right;

  @override
  State<_StudyVerdictGuide> createState() => _StudyVerdictGuideState();
}

class _StudyVerdictGuideState extends State<_StudyVerdictGuide> {
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final right = widget.right;
    return SizedBox(
      width: 112,
      height: 72,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 112,
            child: _Sprung(
              shown: _shown,
              delay: 0.08,
              spring: StudySpring.pop,
              child: StudyMascot(pose: right ? StudyMascotPose.cheer : StudyMascotPose.sad, size: 112),
              builder: (context, value, child) => Opacity(
                opacity: value.clamp(0.0, 1.0),
                child: Transform.scale(
                  scale: 0.2 + 0.8 * value,
                  child: Transform.rotate(angle: (1 - value) * (right ? -25 : 12) * math.pi / 180, alignment: Alignment.bottomCenter, child: child),
                ),
              ),
            ),
          ),
          if (right) Positioned.fill(child: StudyBurst(trigger: _shown ? 1 : 0, count: 18, reach: 70)),
        ],
      ),
    );
  }
}

/// Lets the verdict panel rise from the bottom on a 0.38 s spring, taking its room as it comes.
class _VerdictRise extends StatefulWidget {
  const _VerdictRise({required this.child});
  final Widget child;

  @override
  State<_VerdictRise> createState() => _VerdictRiseState();
}

class _VerdictRiseState extends State<_VerdictRise> with SingleTickerProviderStateMixin {
  static final _spring = StudySpring(0.38, 0.3);
  late final AnimationController _controller = AnimationController(vsync: this, duration: _spring.settle);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller.status == AnimationStatus.dismissed) {
      MediaQuery.disableAnimationsOf(context) ? _controller.value = 1 : _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: widget.child,
    builder: (context, child) {
      final value = _controller.isCompleted ? 1.0 : _spring.transform(_controller.value);
      // Only the risen part takes room; the rest hangs below the screen's edge.
      return Align(alignment: Alignment.topCenter, heightFactor: math.max(0, value), child: child);
    },
  );
}

/// Bounces its child up and down (scale 1 → 1.45 → 1 on 0.22 s springs) each time [trigger] changes.
class _Bounce extends StatefulWidget {
  const _Bounce({required this.trigger, required this.child});
  final int trigger;
  final Widget child;

  @override
  State<_Bounce> createState() => _BounceState();
}

class _BounceState extends State<_Bounce> with SingleTickerProviderStateMixin {
  static final _spring = StudySpring(0.22, 0.5);
  late final AnimationController _controller = AnimationController(vsync: this, duration: _spring.settle * 2);

  @override
  void didUpdateWidget(_Bounce old) {
    super.didUpdateWidget(old);
    if (old.trigger != widget.trigger && !MediaQuery.disableAnimationsOf(context)) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: widget.child,
    builder: (context, child) {
      final t = _controller.value;
      final scale = !_controller.isAnimating
          ? 1.0
          : t < 0.5
          ? 1 + 0.45 * _spring.transform(t * 2)
          : 1.45 - 0.45 * _spring.transform(t * 2 - 1);
      return Transform(alignment: Alignment.center, transform: Matrix4.diagonal3Values(1, scale, 1), child: child);
    },
  );
}

/// An opacity that never leaves 0...1 when a spring overshoots.
class _Clamped extends Animatable<double> {
  @override
  double transform(double t) => t.clamp(0.0, 1.0);
}

/// Drives a value from 0 to 1 along [spring] after [delay] seconds once [shown] turns true, as the Swift steps
/// animate several effects of one view with `studyPop`/`studyRise`. Reduced motion jumps.
class _Sprung extends StatefulWidget {
  const _Sprung({super.key, required this.shown, required this.spring, required this.builder, required this.child, this.delay = 0});
  final bool shown;
  final double delay;
  final StudySpring spring;
  final Widget child;
  final Widget Function(BuildContext context, double value, Widget child) builder;

  @override
  State<_Sprung> createState() => _SprungState();
}

class _SprungState extends State<_Sprung> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);
  late double _target = widget.shown ? 1 : 0;

  double get _value {
    if (!_controller.isAnimating) return _target;
    final total = _controller.duration!.inMicroseconds / Duration.microsecondsPerSecond;
    final elapsed = _controller.value * total;
    if (elapsed <= widget.delay) return 1 - _target;
    final t = ((elapsed - widget.delay) / (total - widget.delay)).clamp(0.0, 1.0);
    final moved = widget.spring.transform(t);
    return _target == 1 ? moved : 1 - moved;
  }

  @override
  void didUpdateWidget(_Sprung old) {
    super.didUpdateWidget(old);
    if (old.shown == widget.shown) return;
    _target = widget.shown ? 1 : 0;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
      return;
    }
    _controller.duration = Duration(microseconds: (widget.delay * Duration.microsecondsPerSecond).round()) + widget.spring.settle;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: _controller, builder: (context, _) => widget.builder(context, _value, widget.child));
}

/// Sets `shown` once the step is on screen, as the Swift steps do in `onAppear`.
mixin _Appearing<T extends StatefulWidget> on State<T> {
  bool shown = false;

  /// Called once the step is first on screen.
  void appeared() {}

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => shown = true);
      appeared();
    });
  }
}

/// The tail of a speech bubble: a triangle open along its foot (`StudyTail`).
class _StudyTailPainter extends CustomPainter {
  const _StudyTailPainter({required this.fill, required this.stroke});
  final Color fill;
  final Color stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, size.height)
      ..lineTo(size.width / 2, 0)
      ..lineTo(size.width, size.height);
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..color = stroke
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_StudyTailPainter old) => old.fill != fill || old.stroke != stroke;
}

// MARK: - Steps

/// A card the guide tells (`StudyCardStep`).
class _StudyCardStep extends StatefulWidget {
  const _StudyCardStep({required this.booru, required this.card, required this.proceed});
  final BooruContext booru;
  final StudyPathCard card;
  final VoidCallback proceed;

  @override
  State<_StudyCardStep> createState() => _StudyCardStepState();
}

class _StudyCardStepState extends State<_StudyCardStep> with _Appearing {
  StudyPathCard get _card => widget.card;

  StudyMascotPose get _pose => StudyMascotPose.values.where((pose) => pose.fileName == _card.pose).firstOrNull ?? StudyMascotPose.read;

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final pose = _pose;
    final symbol = _card.symbol;
    // The bust poses lean out from behind the bubble; the others stand just above it.
    final tuck = pose.isBust ? 30.0 : 4.0;
    final action = _card.action;
    return StudyStepFrame(
      button: 'Continue',
      onPressed: () {
        StudySound.tap.play();
        widget.proceed();
      },
      children: [
        // The guide tells it: its picture, then what it says in a bubble.
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            spacing: 12,
            children: [
              SizedBox(
                width: 124,
                height: 124 - tuck,
                child: OverflowBox(
                  alignment: Alignment.topCenter,
                  minHeight: 124,
                  maxHeight: 124,
                  child: StudyPop(
                    shown: shown,
                    from: 0.3,
                    child: StudyMascot(pose: pose, size: 124),
                  ),
                ),
              ),
              if (symbol != null)
                Expanded(
                  child: StudyPop(
                    shown: shown,
                    delay: 0.12,
                    from: 0.6,
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 108),
                      alignment: Alignment.center,
                      decoration: ShapeDecoration(color: theme.primary.withValues(alpha: 0.14), shape: studyRounded(24)),
                      child: StudyIcon(symbol, size: 42, color: theme.primary),
                    ),
                  ),
                ),
            ],
          ),
        ),
        StudyRise(
          shown: shown,
          delay: 0.1,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // The bubble's tail points up at the guide. It lies under the bubble, which covers its foot.
              if (!pose.isBust)
                Positioned(
                  left: 50,
                  top: -13,
                  width: 24,
                  height: 16,
                  child: CustomPaint(
                    painter: _StudyTailPainter(fill: theme.surface, stroke: theme.line),
                  ),
                ),
              StudyCard(
                padding: 20,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 12,
                  children: [
                    Text(
                      studyWords(_card.title.resolved()),
                      key: const Key('study.cardTitle'),
                      style: StudyTheme.title(25).copyWith(color: theme.ink),
                    ),
                    StudyRichText(_card.body.resolved(), size: 18),
                    if (_card.code case final code?) StudyCodeBox(code),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (action != null) StudyRise(shown: shown, delay: 0.25, child: _button(action)),
      ],
    );
  }

  /// Something to do from the card itself, so that what was just read can be done at once.
  Widget _button(String action) {
    // The generator's store can be missing (a fixture run without its stand-in); the button then shows no key and
    // opens only what needs no store.
    GenerationStore? generation;
    try {
      generation = GenerationStore.shared(widget.booru.booruDefaults);
      unawaited(generation.load());
    } on Object {
      generation = null;
    }
    return ListenableBuilder(
      listenable: generation ?? const AlwaysStoppedAnimation<double>(0),
      builder: (context, _) {
        final theme = StudyTheme.of(context);
        final connected = generation?.hasKey ?? false;
        final symbol = action == 'civitai' ? 'safari.fill' : (action == 'key' ? (connected ? 'checkmark.seal.fill' : 'key.fill') : 'wand.and.stars');
        final title = action == 'civitai'
            ? 'Open Civitai Account Settings'
            : (action == 'key' ? (connected ? 'API Key Connected' : 'Enter the API Key') : 'Open the Generator');
        return StudyPressButton(
          key: const Key('study.cardAction'),
          color: action == 'key' && connected ? theme.good : theme.gold,
          onPressed: () {
            StudySound.tap.play();
            switch (action) {
              case 'civitai':
                unawaited(launchUrl(Uri.parse('https://civitai.com/user/account'), mode: LaunchMode.externalApplication));
              case 'key':
                if (generation case final store?) unawaited(showGeneratorSheet<void>(context, (context) => GeneratorAccountView(store: store)));
              default:
                // `.appSheet { NavigationStack { GeneratorView(…).toolbar { Close } } }`.
                if (generation case final store?) {
                  unawaited(
                    showAppSheet<void>(
                      context,
                      builder: (sheetContext, controller) => Navigator(
                        onGenerateRoute: (_) => CupertinoPageRoute<void>(
                          builder: (context) => GeneratorView(
                            store: store,
                            safeMode: () => widget.booru.safeMode,
                            prompt: _card.code ?? '',
                            study: widget.booru.store.studyStore,
                            onClose: () => Navigator.of(sheetContext).pop(),
                          ),
                        ),
                      ),
                    ),
                  );
                }
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 13),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: 8,
              children: [
                StudyIcon(symbol, size: 18),
                Flexible(
                  child: Text(L10n.text(title), style: StudyTheme.body(17, StudyTheme.heavy), textAlign: TextAlign.center),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A new tag shown with pictures before it is asked (`StudyTeachStep`).
class _StudyTeachStep extends StatefulWidget {
  const _StudyTeachStep({required this.booru, required this.tag, required this.posts, required this.server, required this.proceed});
  final BooruContext booru;
  final StudyTag tag;
  final List<BooruPost> posts;
  final BooruServer server;
  final VoidCallback proceed;

  @override
  State<_StudyTeachStep> createState() => _StudyTeachStepState();
}

class _StudyTeachStepState extends State<_StudyTeachStep> with _Appearing {
  @override
  void appeared() => StudySound.match.play();

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final tag = widget.tag;
    final posts = widget.posts;
    const white = Color(0xFFFFFFFF);
    return StudyStepFrame(
      button: 'Got It',
      onPressed: () {
        StudySound.tap.play();
        widget.proceed();
      },
      children: [
        StudyPop(
          shown: shown,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: ShapeDecoration(color: theme.primary, shape: const StadiumBorder()),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 6,
              children: [
                const StudyIcon('sparkles', size: 13, color: white),
                Text(L10n.text('New Tag'), style: StudyTheme.body(13, StudyTheme.heavy).copyWith(color: white)),
              ],
            ),
          ),
        ),
        Stack(
          clipBehavior: Clip.none,
          children: [
            StudyPop(
              shown: shown,
              delay: 0.1,
              from: 0.5,
              child: Text(
                tag.english,
                key: const Key('study.newTag'),
                style: StudyTheme.title(36).copyWith(color: theme.ink),
              ),
            ),
            Positioned(left: -40, top: 0, bottom: 0, width: 0, child: StudyBurst(trigger: shown ? 1 : 0, count: 14, reach: 80)),
          ],
        ),
        StudyRise(
          shown: shown,
          delay: 0.18,
          child: StudyCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 6,
              children: [
                if (L10n.language != 'en') Text(studyWords(tag.title()), style: StudyTheme.body(18, StudyTheme.heavy).copyWith(color: theme.primary)),
                Text(
                  studyWords(tag.note.resolved()),
                  style: StudyTheme.body(17, StudyTheme.medium).copyWith(color: theme.ink, height: (17 * 1.2 + 3) / 17),
                ),
              ],
            ),
          ),
        ),
        if (posts.isNotEmpty) ...[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            child: Row(
              spacing: 10,
              children: [
                for (final (index, post) in posts.indexed)
                  _Sprung(
                    key: ValueKey(post.id),
                    shown: shown,
                    delay: 0.28 + index * 0.09,
                    spring: StudySpring.rise,
                    builder: (context, value, child) => Opacity(
                      opacity: value.clamp(0.0, 1.0),
                      child: Transform.translate(
                        offset: Offset(0, 40 * (1 - value)),
                        child: Transform.rotate(angle: (1 - value) * (index.isEven ? -6 : 6) * math.pi / 180, child: child),
                      ),
                    ),
                    child: StudyZoom(
                      post: post,
                      among: posts,
                      child: ClipRSuperellipse(
                        borderRadius: BorderRadius.circular(16),
                        child: SizedBox(
                          width: 190 * studyAspect(post, low: 0.5, high: 2.2),
                          height: 190,
                          child: StudyLessonPicture(booru: widget.booru, post: post, server: widget.server),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Text(L10n.text('Pictures that carry this tag'), style: StudyTheme.body(13, StudyTheme.bold).copyWith(color: theme.muted)),
        ],
      ],
    );
  }
}

/// The prompt of an asked step.
Widget _prompt(BuildContext context, String text) => Text(L10n.text(text), style: StudyTheme.title(22).copyWith(color: StudyTheme.of(context).ink));

/// The step's one picture, as large as fits, keeping its shape between 0.7 and 1.6.
Widget _picture(BuildContext context, BooruContext booru, BooruPost post, BooruServer server, {required double maxHeight, required double radius, Key? key}) =>
    StudyFittedBox(
      aspect: studyAspect(post, low: 0.7, high: 1.6),
      maxHeight: maxHeight,
      child: StudyZoom(
        key: key,
        post: post,
        child: ClipRSuperellipse(
          borderRadius: BorderRadius.circular(radius),
          child: StudyLessonPicture(booru: booru, post: post, server: server),
        ),
      ),
    );

/// Two equal columns of [children], [spacing] apart across and [runSpacing] down.
Widget _grid(List<Widget> children, {required double spacing, required double runSpacing}) => Column(
  spacing: runSpacing,
  children: [
    for (var index = 0; index < children.length; index += 2)
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: spacing,
        children: [
          Expanded(child: children[index]),
          Expanded(child: index + 1 < children.length ? children[index + 1] : const SizedBox.shrink()),
        ],
      ),
  ],
);

/// A tag question of one of three kinds (`StudyQuizStep`).
class _StudyQuizStep extends StatefulWidget {
  const _StudyQuizStep({required this.booru, required this.question, required this.server, required this.revealed, required this.answer});
  final BooruContext booru;
  final StudyQuestion question;
  final BooruServer server;
  final bool revealed;
  final ValueChanged<bool> answer;

  @override
  State<_StudyQuizStep> createState() => _StudyQuizStepState();
}

class _StudyQuizStepState extends State<_StudyQuizStep> {
  int? _picked;

  void _pick(int index) {
    setState(() => _picked = index);
    StudySound.pick.play();
  }

  StudyChoiceState _state(int index) => studyChoiceState(index, picked: _picked, answer: widget.question.answer, revealed: widget.revealed);

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final question = widget.question;
    final regular = studyIsRegular(context);
    final children = <Widget>[];
    switch (question.kind) {
      case StudyQuestionKind.pictureToTag:
        children.add(_prompt(context, 'Which tag does this picture carry?'));
        if (question.posts.firstOrNull case final post?) {
          children.add(_picture(context, widget.booru, post, widget.server, maxHeight: regular ? 480 : 300, radius: 20, key: const Key('study.picture')));
        }
        children.add(_words(context));
      case StudyQuestionKind.meaningToTag:
        children.add(_prompt(context, 'Which tag means this?'));
        children.add(
          StudyCard(
            child: Text(
              studyWords(question.tag.note.resolved()),
              style: StudyTheme.body(19, StudyTheme.semibold).copyWith(color: theme.ink, height: (19 * 1.2 + 3) / 19),
            ),
          ),
        );
        children.add(_words(context));
      case StudyQuestionKind.tagToPicture:
        children.add(_prompt(context, 'Which picture carries this tag?'));
        children.add(
          SizedBox(
            width: double.infinity,
            child: Text(
              question.tag.english,
              textAlign: TextAlign.center,
              style: StudyTheme.title(32).copyWith(color: theme.primary),
            ),
          ),
        );
        children.add(
          _grid(spacing: 12, runSpacing: 14, [
            for (final (index, post) in question.posts.indexed)
              StudyZoom(
                post: post,
                among: question.posts,
                cornerOnly: true,
                child: Semantics(
                  label: L10n.text('Picture %@', ['${index + 1}']),
                  child: StudyChoiceButton(
                    key: Key('study.choice.$index'),
                    state: _state(index),
                    onPressed: widget.revealed ? null : () => _pick(index),
                    child: Padding(
                      padding: const EdgeInsets.all(5),
                      child: ClipRSuperellipse(
                        borderRadius: BorderRadius.circular(12),
                        child: AspectRatio(
                          aspectRatio: 0.82,
                          child: StudyLessonPicture(booru: widget.booru, post: post, server: widget.server, fills: true),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ]),
        );
    }
    return StudyStepFrame(
      button: 'Check',
      enabled: _picked != null,
      hidden: widget.revealed,
      onPressed: () {
        final picked = _picked;
        if (picked != null) widget.answer(picked == question.answer);
      },
      children: children,
    );
  }

  /// Tags are offered in the words a prompt is written in, never translated. Short ones share a line.
  Widget _words(BuildContext context) {
    final question = widget.question;
    final limit = studyIsAccessibilitySize(context) ? 0 : (studyIsRegular(context) ? 22 : 13);
    final rows = StudyQuestion.rows([for (final tag in question.choices) tag.english.characters.length], limit: limit);
    return Column(
      spacing: 12,
      children: [
        for (final row in rows)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              for (final index in row)
                Expanded(
                  child: StudyChoiceButton(
                    key: Key('study.choice.$index'),
                    state: _state(index),
                    onPressed: widget.revealed ? null : () => _pick(index),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 56, minWidth: double.infinity),
                        child: Center(child: StudyShrinkingText(question.choices[index].english, style: StudyTheme.body(19, StudyTheme.heavy))),
                      ),
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// A question about an idea, with its choices written out (`StudyAskStep`).
class _StudyAskStep extends StatefulWidget {
  const _StudyAskStep({required this.ask, required this.revealed, required this.answer});
  final StudyPathAsk ask;
  final bool revealed;
  final ValueChanged<bool> answer;

  @override
  State<_StudyAskStep> createState() => _StudyAskStepState();
}

class _StudyAskStepState extends State<_StudyAskStep> {
  int? _picked;

  @override
  Widget build(BuildContext context) {
    final ask = widget.ask;
    return StudyStepFrame(
      button: 'Check',
      enabled: _picked != null,
      hidden: widget.revealed,
      onPressed: () {
        final picked = _picked;
        if (picked != null) widget.answer(picked == ask.answer);
      },
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              const StudyMascot(pose: StudyMascotPose.think, size: 76),
              Expanded(child: StudyCard(padding: 14, child: StudyRichText(ask.question.resolved(), size: 19))),
            ],
          ),
        ),
        Column(
          spacing: 12,
          children: [
            for (final (index, choice) in ask.choices.indexed)
              StudyChoiceButton(
                key: Key('study.choice.$index'),
                state: studyChoiceState(index, picked: _picked, answer: ask.answer, revealed: widget.revealed),
                onPressed: widget.revealed
                    ? null
                    : () {
                        setState(() => _picked = index);
                        StudySound.pick.play();
                      },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 50, minWidth: double.infinity),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(studyWords(choice.resolved()), style: ask.code == true ? StudyTheme.code : StudyTheme.body(18, StudyTheme.bold)),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// A picture and four tags. Three are on the picture; the one that is not is the answer (`StudyOddStep`).
class _StudyOddStep extends StatefulWidget {
  const _StudyOddStep({
    required this.booru,
    required this.post,
    required this.choices,
    required this.answer,
    required this.server,
    required this.revealed,
    required this.done,
  });
  final BooruContext booru;
  final BooruPost post;
  final List<StudyTag> choices;
  final int answer;
  final BooruServer server;
  final bool revealed;
  final ValueChanged<bool> done;

  @override
  State<_StudyOddStep> createState() => _StudyOddStepState();
}

class _StudyOddStepState extends State<_StudyOddStep> {
  int? _picked;

  @override
  Widget build(BuildContext context) {
    return StudyStepFrame(
      button: 'Check',
      enabled: _picked != null,
      hidden: widget.revealed,
      onPressed: () {
        final picked = _picked;
        if (picked != null) widget.done(picked == widget.answer);
      },
      children: [
        _prompt(context, 'Which tag is NOT in this picture?'),
        _picture(
          context,
          widget.booru,
          widget.post,
          widget.server,
          maxHeight: studyIsRegular(context) ? 480 : 300,
          radius: 20,
          key: const Key('study.picture'),
        ),
        _grid(spacing: 12, runSpacing: 12, [
          for (final (index, tag) in widget.choices.indexed)
            StudyChoiceButton(
              key: Key('study.odd.$index'),
              state: studyChoiceState(index, picked: _picked, answer: widget.answer, revealed: widget.revealed),
              onPressed: widget.revealed
                  ? null
                  : () {
                      setState(() => _picked = index);
                      StudySound.pick.play();
                    },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 56, minWidth: double.infinity),
                  child: Center(child: StudyShrinkingText(tag.english, style: StudyTheme.body(18, StudyTheme.heavy), minScale: 0.7)),
                ),
              ),
            ),
        ]),
      ],
    );
  }
}

/// A tag typed from memory, the way a prompt is typed. Letters can be asked for one at a time as a hint
/// (`StudySpellStep`).
class _StudySpellStep extends StatefulWidget {
  const _StudySpellStep({required this.booru, required this.tag, required this.post, required this.server, required this.revealed, required this.done});
  final BooruContext booru;
  final StudyTag tag;
  final BooruPost? post;
  final BooruServer server;
  final bool revealed;
  final ValueChanged<bool> done;

  @override
  State<_StudySpellStep> createState() => _StudySpellStepState();
}

class _StudySpellStepState extends State<_StudySpellStep> {
  final _typed = TextEditingController();
  final _focus = FocusNode();
  int _hints = 0;

  @override
  void initState() {
    super.initState();
    _typed.addListener(_changed);
    _focus.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _typed.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final tag = widget.tag;
    final post = widget.post;
    final revealed = widget.revealed;
    final english = tag.english;
    final typed = _typed.text;
    final border = revealed ? (StudyLessonSession.spelled(typed, tag) ? theme.good : theme.bad) : (_focus.hasFocus ? theme.primary : theme.line);
    return StudyStepFrame(
      button: 'Check',
      enabled: typed.trim().isNotEmpty,
      hidden: revealed,
      onPressed: () {
        _focus.unfocus();
        widget.done(StudyLessonSession.spelled(_typed.text, tag));
      },
      children: [
        _prompt(context, 'Type the tag yourself'),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            const StudyMascot(pose: StudyMascotPose.read, size: 76),
            Expanded(
              child: StudyCard(
                padding: 14,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    if (L10n.language != 'en') Text(studyWords(tag.title()), style: StudyTheme.body(18, StudyTheme.heavy).copyWith(color: theme.primary)),
                    Text(
                      studyWords(tag.note.resolved()),
                      style: StudyTheme.body(16, StudyTheme.medium).copyWith(color: theme.ink, height: (16 * 1.2 + 3) / 16),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (post != null) _picture(context, widget.booru, post, widget.server, maxHeight: studyIsRegular(context) ? 360 : 200, radius: 18),
        Container(
          decoration: ShapeDecoration(
            color: theme.surface,
            shape: studyRounded(16, BorderSide(color: border, width: 2)),
          ),
          child: CupertinoTextField.borderless(
            key: const Key('study.spell.field'),
            controller: _typed,
            focusNode: _focus,
            autofocus: true,
            enabled: !revealed,
            padding: const EdgeInsets.all(16),
            placeholder: L10n.text('Write it in English'),
            placeholderStyle: StudyTheme.code.copyWith(color: theme.muted),
            style: StudyTheme.code.copyWith(color: theme.ink),
            cursorColor: theme.primary,
            // An ASCII keyboard with nothing corrected, as a prompt is typed.
            keyboardType: TextInputType.visiblePassword,
            textCapitalization: TextCapitalization.none,
            autocorrect: false,
            enableSuggestions: false,
            smartDashesType: SmartDashesType.disabled,
            smartQuotesType: SmartQuotesType.disabled,
            textInputAction: TextInputAction.done,
          ),
        ),
        if (!revealed)
          Row(
            spacing: 10,
            children: [
              if (_hints > 0)
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      english.substring(0, math.min(_hints, english.length)) + '·' * math.max(0, english.length - _hints),
                      key: const Key('study.spell.hint'),
                      maxLines: 1,
                      style: StudyTheme.code.copyWith(color: theme.muted),
                    ),
                  ),
                ),
              const Spacer(),
              StudyPressButton(
                key: const Key('study.spell.hintButton'),
                color: theme.gold,
                radius: 12,
                depth: 3,
                outlined: true,
                onPressed: _hints >= english.length
                    ? null
                    : () {
                        StudySound.tap.play();
                        setState(() => _hints = math.min(english.length, _hints + 1));
                      },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 6,
                    children: [
                      const StudyIcon('lightbulb.fill', size: 14),
                      Text(L10n.text('Hint'), style: StudyTheme.body(14, StudyTheme.heavy)),
                    ],
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
