import 'dart:async';
import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/gestures.dart';

import '../../core/support/l10n.dart';
import '../design/tegnal_theme.dart';
import 'home_stage.dart';
import 'home_stage_view.dart';

/// The app's root: the library and learning mode, with the home scene over them until one is chosen.
///
/// The library is built only for someone who goes there, and stays alive under learning mode once
/// built. A place is painted only while it can be seen: under the still scene, it is laid out but not drawn.
class HomeRoot extends StatefulWidget {
  const HomeRoot({super.key, required this.stage, required this.library, required this.study, this.freeze = ''});
  final HomeStage stage;
  final WidgetBuilder library;
  final WidgetBuilder study;

  /// `TEGNAL_HOME` for screenshots: `blur`, or a journey held at one moment such as `library:0.5`.
  final String freeze;

  @override
  State<HomeRoot> createState() => _HomeRootState();
}

class _HomeRootState extends State<HomeRoot> {
  final _scene = GlobalKey<HomeStageViewState>();
  final _libraryKey = GlobalKey(debugLabel: 'home.library');
  final _studyKey = GlobalKey(debugLabel: 'home.study');

  HomeStage get stage => widget.stage;

  bool canStart(Offset position) {
    final scene = _scene.currentState;
    if (scene == null) return false;
    return scene.canStartPull(position, MediaQuery.sizeOf(context), MediaQuery.paddingOf(context));
  }

  @override
  Widget build(BuildContext context) {
    // Built here, not in the listener below: a change of the stage alone then never rebuilds a place.
    final library = KeyedSubtree(
      key: _libraryKey,
      child: Builder(builder: widget.library),
    );
    final study = KeyedSubtree(
      key: _studyKey,
      child: Builder(builder: widget.study),
    );
    final places = ListenableBuilder(
      listenable: stage,
      builder: (context, _) {
        final libraryBuilt = stage.libraryMounted || (!stage.studying && stage.place != HomePlace.home);
        final studyBuilt = stage.studying && (stage.studyMounted || stage.place != HomePlace.home);
        final visible = stage.place != HomePlace.home || stage.moving;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (libraryBuilt)
              Offstage(
                key: const ValueKey('library'),
                offstage: stage.studying || !visible,
                child: IgnorePointer(ignoring: stage.studying, child: library),
              ),
            if (studyBuilt) Offstage(key: const ValueKey('study'), offstage: !visible, child: study),
            if (stage.enabled)
              AbsorbPointer(
                key: const ValueKey('scene'),
                absorbing: stage.coversScreen,
                child: ExcludeSemantics(
                  child: HomeStageView(key: _scene, stage: stage, freeze: widget.freeze),
                ),
              ),
          ],
        );
      },
    );
    if (!stage.enabled) return places;
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        HomePullRecognizer: GestureRecognizerFactoryWithHandlers<HomePullRecognizer>(() => HomePullRecognizer(debugOwner: this), (recognizer) {
          // Scroll views read the device's touch slop from here; the pull must know it to claim the finger first.
          recognizer.gestureSettings = MediaQuery.maybeGestureSettingsOf(context);
          recognizer.canStart = canStart;
          recognizer.accepts = (moved) => _scene.currentState?.acceptsPull(moved) ?? false;
          recognizer.onStart = () => _scene.currentState?.pullStarted();
          recognizer.onUpdate = (translation) => _scene.currentState?.pullMoved(translation);
          recognizer.onEnd = (translation, velocity, cancelled) => _scene.currentState?.pullEnded(translation, velocity, cancelled: cancelled);
        }),
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          places,
          HomeChrome(stage: stage),
        ],
      ),
    );
  }
}

/// The one pull of the home scene: up or down from anywhere at the scene, down from the library's top
/// bar, up from learning mode's bottom.
///
/// It must win over whatever lies under the finger, a hint, a list under a bar or the tab bar's own
/// slide, so it claims a mostly vertical movement after at most 10 logical pixels, well before a scroll
/// view's touch slop. A tap, or a movement mostly across, is left to what lies under it.
class HomePullRecognizer extends OneSequenceGestureRecognizer {
  HomePullRecognizer({super.debugOwner});

  /// About 10 logical pixels, and always well inside the device's own touch slop, which scroll views wait for
  /// (Android's is often 8).
  double get _slop => math.max(4, math.min(10, (gestureSettings?.touchSlop ?? kTouchSlop) * 0.6));

  bool Function(Offset position)? canStart;
  bool Function(Offset moved)? accepts;
  VoidCallback? onStart;
  ValueChanged<Offset>? onUpdate;
  void Function(Offset translation, Offset velocity, bool cancelled)? onEnd;

  int? _pointer;
  Offset _origin = Offset.zero;
  Offset _translation = Offset.zero;
  VelocityTracker? _tracker;
  bool _decided = false;
  bool _pulling = false;

  @override
  bool isPointerAllowed(PointerDownEvent event) => _pointer == null && (canStart?.call(event.position) ?? false) && super.isPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _pointer = event.pointer;
    _origin = event.position;
    _translation = Offset.zero;
    _tracker = VelocityTracker.withKind(event.kind)..addPosition(event.timeStamp, event.position);
    _decided = false;
    _pulling = false;
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerMoveEvent) {
      _tracker?.addPosition(event.timeStamp, event.position);
      _translation = event.position - _origin;
      if (!_decided && _translation.distance >= _slop) {
        _decided = true;
        if (accepts?.call(_translation) ?? false) {
          resolve(GestureDisposition.accepted);
          _pulling = true;
          onStart?.call();
        } else {
          resolve(GestureDisposition.rejected);
          stopTrackingPointer(event.pointer);
          return;
        }
      }
      if (_pulling) onUpdate?.call(_translation);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (_pulling) {
        _pulling = false;
        final velocity = _tracker?.getVelocity().pixelsPerSecond ?? Offset.zero;
        onEnd?.call(_translation, velocity, event is PointerCancelEvent);
      } else {
        resolve(GestureDisposition.rejected);
      }
      stopTrackingPointer(event.pointer);
    }
  }

  /// Winning by default, when nothing else wants the pointer, is not yet a pull; the movement decides.
  @override
  void acceptGesture(int pointer) {}

  @override
  void rejectGesture(int pointer) {
    if (_pulling) {
      _pulling = false;
      onEnd?.call(_translation, Offset.zero, true);
    }
    stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _pointer = null;
    _tracker = null;
    _decided = false;
  }

  @override
  String get debugDescription => 'home pull';
}

/// The few words laid over the scene: where each pull leads, the music switch, and the way back.
class HomeChrome extends StatefulWidget {
  const HomeChrome({super.key, required this.stage});
  final HomeStage stage;

  @override
  State<HomeChrome> createState() => _HomeChromeState();
}

class _HomeChromeState extends State<HomeChrome> {
  HomeStage get stage => widget.stage;
  bool _covered = true;
  bool _showsWayBack = false;
  Timer? _wayBack;

  @override
  void initState() {
    super.initState();
    _covered = stage.coversScreen;
    stage.addListener(_changed);
  }

  @override
  void dispose() {
    stage.removeListener(_changed);
    _wayBack?.cancel();
    super.dispose();
  }

  void _changed() {
    final covered = stage.coversScreen;
    if (covered == _covered) return;
    _covered = covered;
    // The way back is told the first few times a place is reached.
    if (covered || stage.place == HomePlace.home || !stage.takeReturnHint()) return;
    setState(() => _showsWayBack = true);
    _wayBack?.cancel();
    _wayBack = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showsWayBack = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return ListenableBuilder(
      listenable: stage,
      builder: (context, _) {
        final atHome = stage.place == HomePlace.home;
        final rising = stage.place == HomePlace.study;
        return Stack(
          fit: StackFit.expand,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              // Leaving the scene, the hints have already faded under the finger; they must not come back on arrival.
              reverseDuration: Duration.zero,
              child: atHome ? _Hints(key: const ValueKey('hints'), stage: stage, padding: padding) : const SizedBox.shrink(),
            ),
            IgnorePointer(
              child: ValueListenableBuilder<double>(
                valueListenable: stage.pull,
                builder: (context, pull, _) {
                  // Each place is pulled back from its own side: the library from its top bar, learning mode from its bottom.
                  final pulling = pull > 0 && !atHome;
                  final wayBack = _showsWayBack && !stage.coversScreen && pull == 0;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      if (pulling)
                        Positioned(
                          left: 0,
                          right: 0,
                          top: rising ? null : padding.top + 6,
                          bottom: rising ? padding.bottom + 104 : null,
                          child: Center(
                            child: _Pulling(stage: stage, pull: pull, rising: rising),
                          ),
                        ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: padding.bottom + (rising ? 104 : 92),
                        child: Center(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 350),
                            transitionBuilder: (child, animation) => FadeTransition(
                              opacity: animation,
                              child: SlideTransition(
                                position: Tween(begin: const Offset(0, 0.6), end: Offset.zero).animate(animation),
                                child: child,
                              ),
                            ),
                            child: wayBack
                                ? _Notice(
                                    key: ValueKey(rising),
                                    text: rising ? 'Swipe up from the bottom bar to return to the start' : 'Pull down from the top to return to the start',
                                    icon: rising ? CupertinoIcons.arrow_up : CupertinoIcons.arrow_down,
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The two ways out and the music switch, while the scene is on screen.
class _Hints extends StatefulWidget {
  const _Hints({super.key, required this.stage, required this.padding});
  final HomeStage stage;
  final EdgeInsets padding;

  @override
  State<_Hints> createState() => _HintsState();
}

class _HintsState extends State<_Hints> with SingleTickerProviderStateMixin {
  late final _breathing = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat(reverse: true);

  HomeStage get stage => widget.stage;

  @override
  void dispose() {
    _breathing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final padding = widget.padding;
    return ValueListenableBuilder<double>(
      valueListenable: stage.engagement,
      builder: (context, engagement, child) => Opacity(opacity: (1 - engagement).clamp(0.0, 1.0), child: child),
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedOpacity(
            opacity: stage.hintsReady ? 1 : 0,
            duration: const Duration(milliseconds: 1200),
            curve: Curves.easeInOut,
            child: IgnorePointer(
              ignoring: !stage.hintsReady,
              child: Padding(
                padding: EdgeInsets.only(top: padding.top + 14, bottom: padding.bottom + 10),
                child: Column(children: [_way(HomeRealm.study), const Spacer(), _way(HomeRealm.library)]),
              ),
            ),
          ),
          Positioned(
            top: padding.top + 4,
            right: padding.right + 10,
            child: AnimatedOpacity(
              opacity: stage.introFinished ? 1 : 0,
              duration: const Duration(milliseconds: 300),
              child: IgnorePointer(ignoring: !stage.introFinished, child: _music()),
            ),
          ),
        ],
      ),
    );
  }

  /// One of the two ways out. It can be pulled toward from anywhere on the scene, or simply tapped.
  Widget _way(HomeRealm realm) {
    final study = realm == HomeRealm.study;
    final label = Text(
      L10n.text(study ? 'Learning Mode' : 'Viewing Mode'),
      style: TegnalType.style(13, weight: FontWeight.w600, color: const Color(0xEBFFFFFF)).copyWith(
        letterSpacing: 2.5,
        shadows: const [Shadow(color: Color(0x73000000), blurRadius: 8, offset: Offset(0, 1))],
      ),
    );
    final arrow = ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _breathing,
        builder: (context, child) {
          final value = Curves.easeInOut.transform(_breathing.value);
          return Transform.translate(
            offset: Offset(0, (study ? 5 : -5) * value),
            child: Opacity(opacity: 0.55 + 0.45 * value, child: child),
          );
        },
        child: CustomPaint(
          size: const Size(34, 12),
          painter: _CompactChevron(up: !study),
        ),
      ),
    );
    return Semantics(
      button: true,
      label: L10n.text(study ? 'Learning Mode' : 'Viewing Mode'),
      hint: L10n.text(study ? 'Swipe down anywhere to open.' : 'Swipe up anywhere to open.'),
      excludeSemantics: true,
      child: GestureDetector(
        key: ValueKey(study ? 'home.study' : 'home.library'),
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (!stage.moving) stage.travel?.call(realm);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: study ? [label, const SizedBox(height: 5), arrow] : [arrow, const SizedBox(height: 5), label],
          ),
        ),
      ),
    );
  }

  Widget _music() {
    final muted = stage.muted;
    // A pull that happens to start on the button is a pull, not a press.
    return Semantics(
      button: true,
      label: L10n.text(muted ? 'Turn Music On' : 'Turn Music Off'),
      excludeSemantics: true,
      child: GestureDetector(
        key: const ValueKey('home.music'),
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (!stage.moving) stage.muted = !stage.muted;
        },
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Container(
            width: 38,
            height: 38,
            decoration: const ShapeDecoration(
              color: Color(0x21FFFFFF),
              shape: CircleBorder(side: BorderSide(color: Color(0x38FFFFFF), width: 0.6)),
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(scale: Tween(begin: 0.7, end: 1.0).animate(animation), child: child),
              ),
              child: Icon(
                muted ? CupertinoIcons.speaker_slash_fill : CupertinoIcons.speaker_2_fill,
                key: ValueKey(muted),
                size: 16,
                color: const Color(0xE6FFFFFF),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `chevron.compact.up` / `.down`: a wide, shallow chevron in a light stroke.
class _CompactChevron extends CustomPainter {
  const _CompactChevron({required this.up});
  final bool up;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xEBFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final shadow = Paint()
      ..color = const Color(0x40000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    final top = 2.0, bottom = size.height - 2;
    final path = Path()
      ..moveTo(2, up ? bottom : top)
      ..lineTo(size.width / 2, up ? top : bottom)
      ..lineTo(size.width - 2, up ? bottom : top);
    canvas.drawPath(path.shift(const Offset(0, 1)), shadow);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_CompactChevron old) => old.up != up;
}

/// The notice while a place is being pulled back.
class _Pulling extends StatelessWidget {
  const _Pulling({required this.stage, required this.pull, required this.rising});
  final HomeStage stage;
  final double pull;
  final bool rising;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: (pull / 36).clamp(0.0, 1.0),
    child: ValueListenableBuilder<bool>(
      valueListenable: stage.pullArmed,
      builder: (context, armed, _) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: _Notice(
          key: ValueKey(armed),
          text: armed ? 'Release to Return' : 'Keep Pulling to Return',
          icon: armed
              ? CupertinoIcons.house_fill
              : rising
              ? CupertinoIcons.arrow_up
              : CupertinoIcons.arrow_down,
        ),
      ),
    ),
  );
}

/// A small capsule of words over the screen.
class _Notice extends StatelessWidget {
  const _Notice({super.key, required this.text, required this.icon});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: DecoratedBox(
      decoration: const ShapeDecoration(
        color: Color(0x8C000000),
        shape: StadiumBorder(side: BorderSide(color: Color(0x2EFFFFFF), width: 0.6)),
        shadows: [BoxShadow(color: Color(0x40000000), blurRadius: 12, offset: Offset(0, 4))],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: const Color(0xFFFFFFFF)),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                L10n.text(text),
                style: TegnalType.style(14, weight: FontWeight.w600, color: const Color(0xFFFFFFFF)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
