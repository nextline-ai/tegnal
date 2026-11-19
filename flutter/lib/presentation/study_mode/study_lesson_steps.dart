import 'dart:async';
import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../../core/booru/booru_models.dart';
import '../../core/study/study_engine.dart';
import '../../core/study/study_models.dart';
import '../../core/study/study_path.dart';
import '../../core/support/l10n.dart';
import '../booru/booru_common.dart';
import 'study_kit.dart';
import 'study_lesson_parts.dart';
import 'study_reactions.dart';

// The lesson steps that are played with more than one tap: pairs, a prompt built from tags, things put in order and
// things sorted into two buckets. Ported from `StudyLessonView.swift`.

const _white = Color(0xFFFFFFFF);

ShapeBorder _rounded(double radius, [BorderSide side = BorderSide.none]) => RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius), side: side);

/// Grows in from [from] times its size and fades in the first time it is built (SwiftUI's
/// `.transition(.scale(scale:).combined(with: .opacity))` on insertion), on [spring].
class _Appear extends StatefulWidget {
  const _Appear({super.key, required this.child, this.from = 0.4, this.spring});
  final Widget child;
  final double from;
  final StudySpring? spring;

  @override
  State<_Appear> createState() => _AppearState();
}

class _AppearState extends State<_Appear> with SingleTickerProviderStateMixin {
  static final _default = StudySpring(0.3, 0.4);
  late final StudySpring _spring = widget.spring ?? _default;
  late final AnimationController _controller = AnimationController(vsync: this, duration: _spring.settle);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller.isAnimating || _controller.isCompleted) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
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
      final value = _spring.transform(_controller.value);
      return Opacity(
        opacity: _controller.value.clamp(0.0, 1.0),
        child: Transform.scale(scale: widget.from + (1 - widget.from) * value, child: child),
      );
    },
  );
}

// MARK: - Match

/// Tags on one side and what they mean on the other, paired by tapping one of each (`StudyMatchStep`).
class StudyMatchStep extends StatefulWidget {
  const StudyMatchStep({super.key, required this.tags, required this.revealed, required this.answer});

  final List<StudyTag> tags;
  final bool revealed;

  /// Called once every pair is made: true when no wrong pair was tried on the way.
  final ValueChanged<bool> answer;

  @override
  State<StudyMatchStep> createState() => _StudyMatchStepState();
}

class _StudyMatchStepState extends State<StudyMatchStep> {
  late final List<StudyTag> _left = [...widget.tags]..shuffle();
  late final List<StudyTag> _right = [...widget.tags]..shuffle();
  String? _chosen;
  final Set<String> _matched = {};
  String? _missed;
  bool _slipped = false;
  final List<Timer> _timers = [];

  String _meaning(StudyTag tag) => studyWords(L10n.language == 'en' ? tag.note.resolved() : tag.title());

  @override
  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    super.dispose();
  }

  void _pair(StudyTag tag) {
    final chosen = _chosen;
    if (chosen == null) return;
    if (chosen == tag.name) {
      setState(() {
        _matched.add(tag.name);
        _chosen = null;
      });
      HapticFeedback.mediumImpact();
      StudySound.match.play();
      if (_matched.length == widget.tags.length) {
        _timers.add(Timer(const Duration(milliseconds: 350), () => widget.answer(!_slipped)));
      }
    } else {
      setState(() {
        _slipped = true;
        _missed = tag.name;
      });
      HapticFeedback.heavyImpact();
      StudySound.wrong.play();
      _timers.add(
        Timer(const Duration(milliseconds: 450), () {
          if (mounted) setState(() => _missed = null);
        }),
      );
    }
  }

  Widget _cell(String text, StudyChoiceState state, String id, VoidCallback action) {
    return KeyedSubtree(
      key: Key(id),
      child: IgnorePointer(
        ignoring: state == StudyChoiceState.right || widget.revealed,
        child: StudyChoiceButton(
          state: state,
          onPressed: action,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 60),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(child: StudyShrinkingText(text, maxLines: 3, minScale: 0.7, style: StudyTheme.body(16, StudyTheme.heavy))),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    return StudyStepFrame(
      button: 'Check',
      hidden: true,
      onPressed: () {},
      children: [
        Text(L10n.text('Pair each tag with what it means'), style: StudyTheme.title(22).copyWith(color: theme.ink)),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                spacing: 12,
                children: [
                  for (final tag in _left)
                    _cell(
                      tag.english,
                      _matched.contains(tag.name) ? StudyChoiceState.right : (_chosen == tag.name ? StudyChoiceState.picked : StudyChoiceState.idle),
                      'study.match.tag.${tag.name}',
                      () {
                        setState(() => _chosen = _chosen == tag.name ? null : tag.name);
                        StudySound.pick.play();
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                spacing: 12,
                children: [
                  for (final tag in _right)
                    _cell(
                      _meaning(tag),
                      _matched.contains(tag.name) ? StudyChoiceState.right : (_missed == tag.name ? StudyChoiceState.wrong : StudyChoiceState.idle),
                      'study.match.meaning.${tag.name}',
                      () => _pair(tag),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// MARK: - Build

/// A picture described in words, written as a prompt by tapping tags from a bank (`StudyBuildStep`).
class StudyBuildStep extends StatefulWidget {
  const StudyBuildStep({
    super.key,
    required this.booru,
    required this.build,
    required this.picture,
    required this.server,
    required this.revealed,
    required this.answer,
  });

  final BooruContext booru;
  final StudyPathBuild build;

  /// A picture carrying every tag of the answer, shown once the prompt is checked.
  final BooruPost? picture;
  final BooruServer server;
  final bool revealed;
  final ValueChanged<bool> answer;

  @override
  State<StudyBuildStep> createState() => _StudyBuildStepState();
}

class _StudyBuildStepState extends State<StudyBuildStep> {
  late final List<String> _bank = [...widget.build.answer, ...widget.build.extras]..shuffle();
  final List<String> _chosen = [];

  Widget _chip(String tag, String id, VoidCallback action) {
    return KeyedSubtree(
      key: Key(id),
      child: IgnorePointer(
        ignoring: widget.revealed,
        child: StudyPressButton(
          outlined: true,
          radius: 14,
          depth: 4,
          onPressed: action,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Text(StudyPrompt.words(tag), style: StudyTheme.body(17, StudyTheme.heavy)),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final picture = widget.picture;
    return StudyStepFrame(
      button: 'Check',
      enabled: _chosen.isNotEmpty,
      hidden: widget.revealed,
      onPressed: () => widget.answer(StudyLessonSession.judge(_chosen, widget.build)),
      children: [
        Text(L10n.text('Write the prompt for this picture'), style: StudyTheme.title(22).copyWith(color: theme.ink)),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const StudyMascot(pose: StudyMascotPose.wave, size: 76),
            const SizedBox(width: 12),
            Expanded(
              child: StudyCard(
                padding: 14,
                child: Text(
                  studyWords(widget.build.brief.resolved()),
                  style: StudyTheme.body(18, StudyTheme.bold).copyWith(color: theme.ink, height: (18 * 1.2 + 3) / 18),
                ),
              ),
            ),
          ],
        ),
        // The prompt as it stands.
        Container(
          key: const Key('study.build.tray'),
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 112),
          padding: const EdgeInsets.all(12),
          decoration: ShapeDecoration(color: theme.sunken, shape: _rounded(18)),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tag in _chosen)
                _Appear(
                  key: ValueKey('chosen.$tag'),
                  child: _chip(tag, 'study.build.chosen.$tag', () {
                    StudySound.tap.play();
                    setState(() => _chosen.remove(tag));
                  }),
                ),
              if (_chosen.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(L10n.text('Tap the tags below'), style: StudyTheme.body(15, StudyTheme.medium).copyWith(color: theme.muted)),
                ),
            ],
          ),
        ),
        if (widget.revealed && picture != null)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              Text(L10n.text('A picture this prompt describes'), style: StudyTheme.body(13, StudyTheme.bold).copyWith(color: theme.muted)),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: AspectRatio(
                  aspectRatio: math.max(picture.width, 1) / math.max(picture.height, 1),
                  child: StudyZoom(
                    post: picture,
                    child: ClipRSuperellipse(
                      borderRadius: BorderRadius.circular(16),
                      child: StudyLessonPicture(booru: widget.booru, post: picture, server: widget.server),
                    ),
                  ),
                ),
              ),
            ],
          )
        else
          SizedBox(
            width: double.infinity,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tag in _bank)
                  Opacity(
                    opacity: _chosen.contains(tag) ? 0.25 : 1,
                    child: IgnorePointer(
                      ignoring: _chosen.contains(tag),
                      child: _chip(tag, 'study.build.bank.$tag', () {
                        StudySound.pick.play();
                        setState(() => _chosen.add(tag));
                      }),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

// MARK: - Order

/// A pan that takes the pointer after 8 points of travel (SwiftUI's `DragGesture(minimumDistance: 8)` as a
/// `highPriorityGesture`), before a scroll view's vertical drag does at 18, so that a row can be dragged inside the
/// step's scrolling body.
class _OrderDragRecognizer extends PanGestureRecognizer {
  _OrderDragRecognizer({super.debugOwner});

  static const _settings = DeviceGestureSettings(touchSlop: 4);

  @override
  DeviceGestureSettings? get gestureSettings => _settings;

  @override
  set gestureSettings(DeviceGestureSettings? value) {}
}

/// The line drawn round an empty place: 2 points wide, 6 on and 5 off, inside a 16-point rounded rectangle.
class _DashedPlace extends CustomPainter {
  const _DashedPlace({required this.color, this.fill});
  final Color color;
  final Color? fill;

  @override
  void paint(Canvas canvas, Size size) {
    final shape = _rounded(16);
    if (fill != null) canvas.drawPath(shape.getOuterPath(Offset.zero & size), Paint()..color = fill!);
    final outline = shape.getOuterPath(Rect.fromLTWH(1, 1, size.width - 2, size.height - 2));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final metric in outline.computeMetrics()) {
      for (var at = 0.0; at < metric.length; at += 11) {
        canvas.drawPath(metric.extractPath(at, math.min(at + 6, metric.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedPlace old) => old.color != color || old.fill != fill;
}

/// Things that happen one after another, put in order by tapping them or dragging them into numbered places
/// (`StudyOrderStep`, with `StudyPlaceFrames` as keys on the places).
class StudyOrderStep extends StatefulWidget {
  const StudyOrderStep({super.key, required this.order, required this.revealed, required this.answer});

  /// The things in their right order.
  final StudyPathOrder order;
  final bool revealed;
  final ValueChanged<bool> answer;

  @override
  State<StudyOrderStep> createState() => _StudyOrderStepState();
}

class _StudyOrderStepState extends State<StudyOrderStep> with SingleTickerProviderStateMixin {
  static final _move = StudySpring(0.3, 0.4);
  static final _targetSpring = StudySpring(0.25, 0.4);

  /// Positions in the right order, as they were mixed for the bank and as they have been placed.
  late final List<int> _bank = _mix();
  final List<int> _chosen = [];

  /// Where each numbered place lies on screen (`StudyPlaceFrames`).
  late final List<GlobalKey> _places = [for (var i = 0; i < widget.order.items.length; i++) GlobalKey()];

  /// Each thing's row, wherever it is.
  late final Map<int, GlobalKey> _rows = {for (var i = 0; i < widget.order.items.length; i++) i: GlobalKey()};

  /// The thing being dragged, where its row was when it was picked up, how far it has been carried and the place it
  /// is over.
  int? _dragging;
  Rect _origin = Rect.zero;
  Offset _start = Offset.zero;
  Offset _carried = Offset.zero;
  int? _target;

  /// After a drop: the thing still flying from where it was let go to its new row.
  int? _settling;
  Rect _settleFrom = Rect.zero;
  Rect _settleTo = Rect.zero;
  late final AnimationController _settle = AnimationController(vsync: this, duration: _move.settle)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() => _settling = null);
        _portal.hide();
      }
    });
  final OverlayPortalController _portal = OverlayPortalController();

  List<int> _mix() {
    final mixed = [for (var i = 0; i < widget.order.items.length; i++) i]..shuffle();
    // Never offered already in order: that would give the answer away.
    final inOrder = [for (var i = 0; i < mixed.length; i++) mixed[i] == i].every((same) => same);
    if (inOrder && mixed.length > 1) {
      final first = mixed[0];
      mixed[0] = mixed[1];
      mixed[1] = first;
    }
    return mixed;
  }

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  Rect? _rect(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// The numbered place under a point, taking the nearest one while the point is among the places at all.
  int? _place(Offset point) {
    final frames = <int, Rect>{for (var place = 0; place < _places.length; place++) place: ?_rect(_places[place])};
    if (frames.isEmpty) return null;
    final top = frames.values.map((rect) => rect.top).reduce(math.min);
    final bottom = frames.values.map((rect) => rect.bottom).reduce(math.max);
    if (point.dy < top - 16 || point.dy > bottom + 16) return null;
    return frames.entries.reduce((a, b) => (a.value.center.dy - point.dy).abs() <= (b.value.center.dy - point.dy).abs() ? a : b).key;
  }

  void _tapBank(int item) {
    StudySound.pick.play();
    setState(() => _chosen.add(item));
  }

  void _tapPlaced(int item) {
    StudySound.tap.play();
    setState(() => _chosen.remove(item));
  }

  void _down(int item, DragDownDetails details) => _start = details.globalPosition;

  void _begin(int item) {
    if (_settling != null) {
      _settle.stop();
      _settling = null;
    }
    final rect = _rect(_rows[item]!);
    if (rect == null) return;
    setState(() {
      _dragging = item;
      _origin = rect;
    });
    _portal.show();
    StudySound.pick.play();
  }

  void _update(int item, DragUpdateDetails details) {
    if (_dragging != item) return;
    final target = _place(details.globalPosition);
    if (target != _target) HapticFeedback.selectionClick();
    setState(() {
      _carried = details.globalPosition - _start;
      _target = target;
    });
  }

  void _end(int item, Offset point) {
    if (_dragging != item) return;
    final place = _place(point);
    final from = _origin.shift(_carried);
    setState(() {
      // Dropped on a place, it goes there and the others make room; dropped anywhere else, it goes back to the bank.
      _chosen.remove(item);
      if (place != null) _chosen.insert(math.min(place, _chosen.length), item);
      _dragging = null;
      _carried = Offset.zero;
      _target = null;
      _settling = item;
      _settleFrom = from;
      _settleTo = from;
    });
    StudySound.tap.play();
    // Once the row stands in its new place, the lifted copy flies there.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _settling != item) return;
      final to = _rect(_rows[item]!);
      if (to == null || MediaQuery.disableAnimationsOf(context)) {
        setState(() => _settling = null);
        _portal.hide();
        return;
      }
      _settleTo = to;
      _settle.forward(from: 0);
    });
  }

  Widget _label(int item) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(studyWords(widget.order.items[item].resolved()), style: StudyTheme.body(16, StudyTheme.bold)),
        ),
      ),
    );
  }

  /// One thing's button as it looks in the bank or in a place.
  Widget _face(int item, {required VoidCallback? onPressed}) {
    final place = _chosen.indexOf(item);
    if (place < 0) {
      return StudyPressButton(outlined: true, radius: 16, depth: 4, onPressed: onPressed, child: _label(item));
    }
    final right = mapEquals(widget.order.items[item], widget.order.items[place]);
    return StudyChoiceButton(
      state: widget.revealed ? (right ? StudyChoiceState.right : StudyChoiceState.wrong) : StudyChoiceState.picked,
      onPressed: onPressed,
      child: _label(item),
    );
  }

  /// One thing to order: a tap sends it to the next free place or back, and a drag carries it to the place it is
  /// dropped on.
  Widget _row(int item, String id, VoidCallback tap) {
    final lifted = _dragging == item || _settling == item;
    return KeyedSubtree(
      key: _rows[item],
      child: IgnorePointer(
        ignoring: widget.revealed,
        child: RawGestureDetector(
          key: Key(id),
          gestures: {
            _OrderDragRecognizer: GestureRecognizerFactoryWithHandlers<_OrderDragRecognizer>(
              () => _OrderDragRecognizer(debugOwner: this),
              (recognizer) => recognizer
                ..onDown = ((details) => _down(item, details))
                ..onStart = ((_) => _begin(item))
                ..onUpdate = ((details) => _update(item, details))
                ..onEnd = ((_) => _end(item, _start + _carried))
                ..onCancel = (() => _end(item, _start + _carried)),
            ),
          },
          child: Opacity(
            opacity: lifted ? 0 : 1,
            child: _face(item, onPressed: tap),
          ),
        ),
      ),
    );
  }

  /// The row carried above everything else, following the finger, or flying to where it was dropped.
  Widget _lifted(BuildContext context) {
    final item = _dragging ?? _settling;
    if (item == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _settle,
      builder: (context, _) {
        final settling = _dragging == null;
        final t = settling ? _move.transform(_settle.value) : 0.0;
        final rect = settling ? Rect.lerp(_settleFrom, _settleTo, t)! : _origin.shift(_carried);
        final lift = settling ? 1 - _settle.value.clamp(0.0, 1.0) : 1.0;
        final overlay = Overlay.of(context).context.findRenderObject();
        final origin = overlay is RenderBox ? overlay.localToGlobal(Offset.zero) : Offset.zero;
        return Positioned(
          left: rect.left - origin.dx,
          top: rect.top - origin.dy,
          width: rect.width,
          child: IgnorePointer(
            child: Transform.scale(
              scale: 1 + 0.04 * lift,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  shape: _rounded(16),
                  shadows: [BoxShadow(color: Color.fromRGBO(0, 0, 0, 0.3 * lift), blurRadius: 10, offset: const Offset(0, 6))],
                ),
                child: _face(item, onPressed: () {}),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final order = widget.order;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final spring = reduce ? Duration.zero : _targetSpring.settle;
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _lifted,
      child: StudyStepFrame(
        button: 'Check',
        enabled: _chosen.length == order.items.length,
        hidden: widget.revealed,
        onPressed: () => widget.answer(StudyLessonSession.judgeOrder([for (final item in _chosen) order.items[item]], order)),
        children: [
          Text(studyWords(order.brief.resolved()), style: StudyTheme.title(22).copyWith(color: theme.ink)),
          if (!widget.revealed)
            Row(
              children: [
                StudyIcon('hand.draw.fill', size: 16, color: theme.muted),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    L10n.text('Tap them in order, or drag them into place.'),
                    style: StudyTheme.body(13, StudyTheme.bold).copyWith(color: theme.muted),
                  ),
                ),
              ],
            ),
          Column(
            spacing: 10,
            children: [
              for (var place = 0; place < order.items.length; place++)
                Row(
                  key: _places[place],
                  children: [
                    AnimatedScale(
                      scale: _target == place ? 1.2 : 1,
                      duration: spring,
                      curve: _targetSpring,
                      child: AnimatedContainer(
                        duration: spring,
                        width: 30,
                        height: 30,
                        alignment: Alignment.center,
                        decoration: ShapeDecoration(
                          shape: const CircleBorder(),
                          color: _target == place ? theme.gold : (place < _chosen.length ? theme.primary : theme.line),
                        ),
                        child: Text('${place + 1}', style: StudyTheme.body(16, StudyTheme.heavy).copyWith(color: _white)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: Opacity(
                              opacity: place >= _chosen.length || _dragging == _chosen[place] ? 1 : 0,
                              child: CustomPaint(
                                key: Key('study.order.slot.$place'),
                                painter: _DashedPlace(
                                  color: _target == place ? theme.gold : theme.line,
                                  fill: _target == place ? theme.gold.withValues(alpha: 0.14) : null,
                                ),
                              ),
                            ),
                          ),
                          ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 52),
                            child: place < _chosen.length
                                ? _Appear(
                                    key: ValueKey('place.${_chosen[place]}'),
                                    from: 0.6,
                                    spring: _move,
                                    child: _row(_chosen[place], 'study.order.place.$place', () => _tapPlaced(_chosen[place])),
                                  )
                                : const SizedBox(width: double.infinity),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ),
          if (!widget.revealed)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                spacing: 10,
                children: [
                  for (final item in _bank)
                    if (!_chosen.contains(item))
                      _Appear(key: ValueKey('bank.$item'), from: 0.6, spring: _move, child: _row(item, 'study.order.item.$item', () => _tapBank(item))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// MARK: - Sort

/// Things dropped one at a time into one of two buckets (`StudySortStep`).
class StudySortStep extends StatefulWidget {
  const StudySortStep({super.key, required this.sort, required this.revealed, required this.answer});

  final StudyPathSort sort;
  final bool revealed;

  /// Called once everything is sorted: true when nothing went into the wrong bucket first.
  final ValueChanged<bool> answer;

  @override
  State<StudySortStep> createState() => _StudySortStepState();
}

class _StudySortStepState extends State<StudySortStep> with SingleTickerProviderStateMixin {
  static final _bump = StudySpring(0.25, 0.6);

  late final List<int> _queue = [for (var i = 0; i < widget.sort.items.length; i++) i]..shuffle();
  final List<int> _placed = [];

  /// The things first dropped into the wrong bucket.
  final Set<int> _missed = {};
  int _shakes = 0;

  /// The bucket the card is flying into, while it flies.
  bool? _flying;
  bool? _bumped;
  late final AnimationController _fly = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));

  int? get _current => _queue.where((item) => !_placed.contains(item)).firstOrNull;

  @override
  void dispose() {
    _fly.dispose();
    super.dispose();
  }

  Future<void> _wait(int milliseconds) => Future<void>.delayed(Duration(milliseconds: milliseconds));

  Future<void> _drop(bool right) async {
    final item = _current;
    if (item == null || _flying != null) return;
    final belongs = widget.sort.items[item].right;
    if (belongs == right) {
      StudySound.match.play();
    } else {
      // A wrong bucket shakes the card; it then goes where it belongs, so the right place is seen.
      StudySound.wrong.play();
      HapticFeedback.heavyImpact();
      setState(() {
        _missed.add(item);
        _shakes += 1;
      });
    }
    if (belongs != right) await _wait(480);
    if (!mounted) return;
    setState(() => _flying = belongs);
    if (MediaQuery.disableAnimationsOf(context)) {
      _fly.value = 1;
    } else {
      unawaited(_fly.forward(from: 0));
    }
    await _wait(240);
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _bumped = belongs;
      _placed.add(item);
      _flying = null;
    });
    _fly.value = 0;
    await _wait(200);
    if (!mounted) return;
    setState(() => _bumped = null);
    if (_placed.length == widget.sort.items.length) {
      await _wait(350);
      if (mounted) widget.answer(_missed.isEmpty);
    }
  }

  Widget _card(StudyTheme theme, int current) {
    final card = Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: 6,
          bottom: -6,
          child: DecoratedBox(
            decoration: ShapeDecoration(color: studyEdge(theme.primary), shape: _rounded(24)),
          ),
        ),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 130),
          padding: const EdgeInsets.all(22),
          alignment: Alignment.center,
          decoration: ShapeDecoration(color: theme.surface, shape: _rounded(24)),
          foregroundDecoration: ShapeDecoration(shape: _rounded(24, BorderSide(color: theme.primary, width: 3))),
          child: Text(
            studyWords(widget.sort.items[current].text.resolved()),
            textAlign: TextAlign.center,
            style: StudyTheme.title(21).copyWith(color: theme.ink),
          ),
        ),
      ],
    );
    return _Appear(
      key: ValueKey('sort.$current'),
      from: 0.5,
      child: AnimatedBuilder(
        animation: _fly,
        child: StudyShake(travel: _shakes.toDouble(), child: card),
        builder: (context, child) {
          final flying = _flying;
          final t = Curves.easeIn.transform(_fly.value);
          final side = flying == true ? 1.0 : -1.0;
          final away = flying == null ? 0.0 : t;
          return Transform.rotate(
            angle: side * 14 * away * math.pi / 180,
            child: Opacity(
              opacity: 1 - away,
              child: Transform.scale(
                scale: 1 - 0.75 * away,
                child: Transform.translate(offset: Offset(side * 150 * away, 150 * away), child: child),
              ),
            ),
          );
        },
      ),
    );
  }

  /// A bucket, and under it what has been dropped in so far.
  Widget _bucket(StudyTheme theme, bool right) {
    final color = right ? theme.flame : theme.primary;
    final inside = _placed.where((item) => widget.sort.items[item].right == right);
    final enabled = _current != null && _flying == null && !widget.revealed;
    final reduce = MediaQuery.disableAnimationsOf(context);
    return Column(
      spacing: 8,
      children: [
        AnimatedScale(
          scale: _bumped == right ? 1.08 : 1,
          duration: reduce ? Duration.zero : _bump.settle,
          curve: _bump,
          child: StudyPressButton(
            key: Key(right ? 'study.sort.right' : 'study.sort.left'),
            color: color,
            radius: 18,
            depth: 5,
            onPressed: enabled ? () => _drop(right) : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 68),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Center(
                  heightFactor: 1,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 4,
                    children: [
                      const StudyIcon('tray.and.arrow.down.fill', size: 18),
                      StudyShrinkingText(
                        studyWords((right ? widget.sort.right : widget.sort.left).resolved()),
                        maxLines: 2,
                        minScale: 0.7,
                        style: StudyTheme.body(17, StudyTheme.heavy),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        for (final item in inside)
          _Appear(
            key: ValueKey('sorted.$item'),
            from: 0.3,
            child: Builder(
              builder: (context) {
                final wrong = _missed.contains(item);
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: ShapeDecoration(color: (wrong ? theme.bad : color).withValues(alpha: 0.16), shape: _rounded(12)),
                  foregroundDecoration: wrong ? ShapeDecoration(shape: _rounded(12, BorderSide(color: theme.bad, width: 2))) : null,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    spacing: 4,
                    children: [
                      if (wrong) StudyIcon('xmark.circle.fill', size: 13, color: theme.bad),
                      Flexible(
                        child: Text(
                          studyWords(widget.sort.items[item].text.resolved()),
                          textAlign: TextAlign.center,
                          style: StudyTheme.body(13, StudyTheme.bold).copyWith(color: theme.ink),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final current = _current;
    return StudyStepFrame(
      button: 'Check',
      hidden: true,
      onPressed: () {},
      children: [
        Text(studyWords(widget.sort.brief.resolved()), style: StudyTheme.title(22).copyWith(color: theme.ink)),
        Row(
          spacing: 6,
          children: [
            for (final item in _queue)
              Expanded(
                child: Container(
                  height: 6,
                  decoration: ShapeDecoration(
                    shape: const StadiumBorder(),
                    color: _placed.contains(item) ? theme.good : (item == current ? theme.primary : theme.sunken),
                  ),
                ),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: current != null
              ? KeyedSubtree(key: const Key('study.sort.item'), child: _card(theme, current))
              : _Appear(
                  key: const ValueKey('sort.done'),
                  from: 0.5,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 130, minWidth: double.infinity),
                    child: Center(child: StudyMascot(pose: _missed.isEmpty ? StudyMascotPose.cheer : StudyMascotPose.think, size: 120)),
                  ),
                ),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _bucket(theme, false)),
            const SizedBox(width: 12),
            Expanded(child: _bucket(theme, true)),
          ],
        ),
      ],
    );
  }
}
