import 'dart:async';
import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'home_media.dart';
import 'home_stage.dart';
import 'home_travel.dart';
import 'home_world.dart';

enum _Phase { home, pullingOut, travelling, away, pullingBack, returning }

/// The home scene and the two journeys out of it.
///
/// Nothing here is rebuilt while the camera moves: one [HomePose] holds the journey's moment, the
/// world is drawn by painters that listen to it, and the picture is moved by a render object that
/// listens to it too. Places are built under the scene before a journey starts, never during one.
class HomeStageView extends StatefulWidget {
  const HomeStageView({super.key, required this.stage, this.freeze = ''});
  final HomeStage stage;

  /// For screenshots: `blur` keeps the opening blur, and `library:0.5` holds the journey to the library at its middle.
  final String freeze;

  @override
  State<HomeStageView> createState() => HomeStageViewState();
}

class HomeStageViewState extends State<HomeStageView> with TickerProviderStateMixin, WidgetsBindingObserver {
  HomeStage get stage => widget.stage;

  final _pose = HomePose();
  final _drift = HomeDrift();
  final _film = HomeFilm();
  final _music = HomeMusic();
  late final _journeyClock = AnimationController(vsync: this);
  late final _content = AnimationController(vsync: this, value: 1, duration: const Duration(milliseconds: 450));
  late final _still = AnimationController(vsync: this, value: 1, duration: const Duration(milliseconds: 300));
  late final _clearing = AnimationController(vsync: this);
  late final _engagement = AnimationController(vsync: this);
  late final _pull = AnimationController(vsync: this);
  late final Ticker _driftClock = createTicker(_tickDrift);
  late final AppLifecycleListener _lifecycle;
  Duration _lastDrift = Duration.zero;
  double Function(double u)? _curve;

  _Phase _phase = _Phase.home;
  HomeRealm? _shown;
  double _moment = 0;
  bool _armed = false;
  bool _active = false;
  bool _started = false;
  bool _opened = false;
  bool _hidden = false;
  int _journey = 0;
  Size _size = Size.zero;

  /// The place to go on to once the scene has been reached, when one place was asked for from the other.
  HomeRealm? _onward;

  bool get _reduced => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _journeyClock.addListener(() {
      final curve = _curve, realm = _shown;
      if (curve != null) _apply(curve(_journeyClock.value), realm);
    });
    _film.onFirstFrame = _open;
    unawaited(_film.load());
    stage.travel = (realm) => _travel(realm, pace: 0);
    stage.travelQuickly = (realm) => _travel(realm, pace: 0, within: HomeTravel.quickDuration);
    stage.goHome = returnHome;
    stage.transfer = _transfer;
    stage.onMutedChange = (_) => _updateMusic(const Duration(milliseconds: 600));
    _lifecycle = AppLifecycleListener(onStateChange: (state) => _setActive(state == AppLifecycleState.resumed));
    final state = WidgetsBinding.instance.lifecycleState;
    WidgetsBinding.instance.addPostFrameCallback((_) => _setActive(state == null || state == AppLifecycleState.resumed));
    if (widget.freeze == 'blur') SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // The still is in this frame; once the frame after it has been drawn too, the system's launch cover may go.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) => stage.sceneShown());
      WidgetsBinding.instance.scheduleFrame();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lifecycle.dispose();
    for (final controller in [_journeyClock, _content, _still, _clearing, _engagement, _pull]) {
      controller.dispose();
    }
    _driftClock.dispose();
    _film.dispose();
    _music.dispose();
    _pose.dispose();
    _drift.dispose();
    if (stage.goHome == returnHome) {
      stage.travel = stage.travelQuickly = stage.transfer = null;
      stage.goHome = null;
      stage.onMutedChange = null;
    }
    super.dispose();
  }

  /// Away from the scene, its pictures are only needed again on the way back; under pressure they are let go.
  @override
  void didHaveMemoryPressure() {
    if (_phase == _Phase.away) HomeArt.shed();
  }

  // MARK: Opening

  /// The scene is told whether the app is in front; film and music stop when it is not.
  void _setActive(bool active) {
    if (!mounted || _active == active) return;
    _active = active;
    if (_phase == _Phase.home || _phase == _Phase.pullingOut) {
      if (active) {
        _film.play();
      } else {
        _film.pause();
      }
      _updateMusic(Duration(milliseconds: active ? 2400 : 300));
    }
    if (active && !_started) {
      _started = true;
      // A film that never shows its first frame must not leave the app behind a blur.
      Timer(const Duration(milliseconds: 1200), _open);
    }
  }

  /// Clears the opening blur. With a place to open in, the scene is only passed through, so it clears faster.
  void _open() {
    if (_opened || !mounted) return;
    _opened = true;
    final freeze = widget.freeze;
    if (freeze == 'blur') return;
    final parts = freeze.split(':');
    if (parts.length == 2) {
      final realm = HomeRealm.values.where((realm) => realm.name == parts[0]).firstOrNull;
      final moment = double.tryParse(parts[1]);
      if (realm != null && moment != null) {
        _clearScene(const Duration(milliseconds: 100));
        unawaited(_hold(realm, moment));
        return;
      }
    }
    stage.introStarted();
    unawaited(HomeArt.load());
    final seconds = stage.preferred == null ? 1.7 : 0.9;
    _clearScene(Duration(milliseconds: (seconds * 1000).round()));
    Timer(Duration(milliseconds: (seconds * 750).round()), stage.finishIntro);
  }

  /// Holds a journey at one moment, for screenshots.
  Future<void> _hold(HomeRealm realm, double moment) async {
    await HomeArt.load();
    if (!mounted) return;
    stage.mount(realm);
    _build();
    _show(realm);
    _startDrift(realm, returning: false);
    _apply(moment, realm);
    _phase = _Phase.travelling;
    stage.beginDrag();
    stage.engagement.value = 1;
  }

  /// Lets go of the still, clears the blur, and only then starts the film.
  void _clearScene(Duration duration) {
    _still.animateTo(0, curve: Curves.easeOut);
    _clearing.duration = _reduced ? const Duration(milliseconds: 500) : duration;
    Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      _clearing.forward().whenComplete(() {
        if (!mounted) return;
        _film.cleared();
        HomeStill.release();
      });
    });
  }

  void _updateMusic(Duration fade) {
    final wanted = _active && !stage.muted && (_phase == _Phase.home || _phase == _Phase.pullingOut || _phase == _Phase.returning);
    if (wanted) {
      _music.play(fade);
    } else {
      _music.stop(fade < const Duration(milliseconds: 1200) ? fade : const Duration(milliseconds: 1200));
    }
  }

  // MARK: Building the world

  /// Lays out both journeys for this screen, and makes sure the drawings are on their way.
  void _build() {
    unawaited(HomeArt.load());
    final size = _size;
    if (size.isEmpty) return;
    for (final realm in HomeRealm.values) {
      if (_pose.layouts[realm]?.size != size) _pose.layouts[realm] = HomeRealmLayout(realm, size);
    }
  }

  void _resized(Size size) {
    if (size == _size) return;
    _size = size;
    // A turned or resized screen is a different world; it is laid out again when next needed.
    if (_phase == _Phase.home || _phase == _Phase.away) {
      _pose.layouts.clear();
      if (_phase == _Phase.home) _apply(0, null);
    }
  }

  void _show(HomeRealm? realm) {
    if (_shown == realm) return;
    if (_shown != null) _stopDrift(clear: true);
    _shown = realm;
    _pose.set(_moment, realm);
  }

  /// Places everything where it stands at one moment of the journey.
  void _apply(double t, HomeRealm? realm) {
    _moment = t;
    _pose.set(t, realm);
  }

  void _startDrift(HomeRealm realm, {required bool returning}) {
    if (_size.isEmpty) return;
    // On the way back the dust and the stars pass the other way.
    _drift.start(realm, _size, reversed: returning);
    if (!_driftClock.isActive) {
      _lastDrift = Duration.zero;
      _driftClock.start();
    }
  }

  void _stopDrift({bool clear = false}) {
    _drift.stop(clear: clear);
    if (clear && _driftClock.isActive) _driftClock.stop();
  }

  void _tickDrift(Duration elapsed) {
    final dt = (elapsed - _lastDrift).inMicroseconds / 1e6;
    _lastDrift = elapsed;
    if (dt <= 0) return;
    _drift.advance(math.min(dt, 0.05));
    if (!_drift.running) _driftClock.stop();
  }

  /// Plays the journey from one moment to another. Only numbers change each frame; nothing is rebuilt.
  Future<void> _run({
    required double from,
    required double to,
    required double seconds,
    double leaving = 0,
    double landing = 1,
    required VoidCallback completion,
  }) async {
    final current = ++_journey;
    _curve = (u) => HomeTravel.moment(u, start: from, end: to, seconds: seconds, leaving: leaving, landing: landing);
    _journeyClock.duration = Duration(microseconds: (seconds * 1e6).round());
    try {
      await _journeyClock.forward(from: 0).orCancel;
    } on TickerCanceled {
      return;
    }
    if (!mounted || current != _journey) return;
    _curve = null;
    completion();
  }

  /// Tweens one of the stage's per-frame numbers.
  void _tween(AnimationController controller, ValueNotifier<double> value, double to, Duration duration) {
    final from = value.value;
    controller.stop();
    if ((from - to).abs() < 0.001) {
      value.value = to;
      return;
    }
    void step() => value.value = from + (to - from) * Curves.easeOut.transform(controller.value);
    controller
      ..duration = duration
      ..value = 0;
    controller.addListener(step);
    controller.forward().whenCompleteOrCancel(() => controller.removeListener(step));
  }

  // MARK: Pulls

  /// The place on screen once the scene has been left.
  HomeRealm get _placeRealm => stage.place == HomePlace.study ? HomeRealm.study : HomeRealm.library;

  /// Whether a pull may start at this point of the screen: anywhere at the scene, from the library's top bar, or from learning mode's bottom.
  bool canStartPull(Offset position, Size size, EdgeInsets padding) {
    if (!stage.enabled || widget.freeze.isNotEmpty) return false;
    if (_phase == _Phase.home) return stage.atHome;
    if (_phase != _Phase.away || stage.moving) return false;
    // The library came down from the scene: it is pulled down from its top bar to go back up.
    if (_placeRealm == HomeRealm.library) return position.dy <= padding.top + 64;
    // Learning mode rose from it: it is swept up from its bottom bar to come back down.
    return position.dy >= size.height - padding.bottom - 96;
  }

  /// Whether a finger that has moved this far is pulling the way this pull goes.
  bool acceptsPull(Offset moved) {
    if (_phase == _Phase.home) return moved.dy.abs() > moved.dx.abs();
    if (_placeRealm == HomeRealm.library) return moved.dy > 0 && moved.dy > moved.dx.abs() * 1.2;
    return moved.dy < 0 && -moved.dy > moved.dx.abs() * 1.2;
  }

  void pullStarted() {
    if (_phase == _Phase.home) {
      _phase = _Phase.pullingOut;
      _armed = false;
      _build();
      stage.beginDrag();
      HapticFeedback.selectionClick();
    } else if (_phase == _Phase.away) {
      _beginReturn();
      _phase = _Phase.pullingBack;
    }
  }

  void pullMoved(Offset translation) {
    final height = _size.height;
    if (_phase == _Phase.pullingOut) {
      final offset = translation.dy;
      if (offset.abs() <= 0.5) return;
      final realm = offset < 0 ? HomeRealm.library : HomeRealm.study;
      if (_shown != realm) {
        _show(realm);
        _startDrift(realm, returning: false);
        stage.leanToward(realm);
        // The place is built while the finger is still deciding, so that the journey never waits on it.
        stage.mount(realm);
      }
      _apply(HomeTravel.progressForDrag(offset.abs(), height), realm);
      stage.engagement.value = math.min(1, offset.abs() / 70);
      final reached = offset.abs() > height * HomeTravel.commit;
      if (reached != _armed) {
        _armed = reached;
        reached ? HapticFeedback.lightImpact() : HapticFeedback.selectionClick();
      }
    } else if (_phase == _Phase.pullingBack) {
      final realm = _shown;
      if (realm == null) return;
      // The world's edge comes back in under the finger: the cave's roof from above, the clouds from below.
      final offset = math.max(0.0, translation.dy * (_placeRealm == HomeRealm.library ? 1 : -1));
      if (_reduced) {
        _content.value = math.min(0.6, offset / height * 2);
      } else {
        _apply(HomeTravel.progressForPull(offset, height), realm);
      }
      stage.pull.value = offset;
      final reached = offset > height * HomeTravel.returnCommit;
      if (reached != _armed) {
        _armed = reached;
        stage.pullArmed.value = reached;
        reached ? HapticFeedback.lightImpact() : HapticFeedback.selectionClick();
      }
    }
  }

  void pullEnded(Offset translation, Offset velocity, {required bool cancelled}) {
    final height = _size.height;
    if (_phase == _Phase.pullingOut) {
      final offset = translation.dy, speed = velocity.dy;
      final onward = offset * speed >= 0 || speed.abs() < 120;
      final flicked = speed.abs() > HomeTravel.flick && offset * speed > 0 && offset.abs() > 24;
      final realm = _shown;
      if (!cancelled && realm != null && ((offset.abs() > height * HomeTravel.commit && onward) || flicked)) {
        // The finger's speed carries on into the journey.
        final pace = (speed.abs() / height) / math.max(0.2, HomeTravel.cameraSpeed(_moment));
        _travel(realm, pace: onward ? pace : 0);
      } else {
        _settleHome();
      }
    } else if (_phase == _Phase.pullingBack) {
      final realm = _shown;
      if (realm == null) return;
      final sign = _placeRealm == HomeRealm.library ? 1 : -1;
      final offset = math.max(0.0, translation.dy * sign), speed = velocity.dy * sign;
      final committed = !cancelled && ((offset > height * HomeTravel.returnCommit && speed > -120) || (speed > HomeTravel.flick && offset > 24));
      committed ? returnHome() : _settleAway(realm);
    }
  }

  // MARK: Leaving home

  void _settleHome() {
    final realm = _shown;
    if (realm == null || _moment <= 0.0005) return _finishHome();
    _phase = _Phase.returning;
    _tween(_engagement, stage.engagement, 0, const Duration(milliseconds: 300));
    _run(from: _moment, to: 0, seconds: 0.5, landing: 0, completion: _finishHome);
  }

  void _finishHome() {
    _show(null);
    _apply(0, null);
    _content.value = 1;
    if (_hidden) setState(() => _hidden = false);
    _phase = _Phase.home;
    stage.cancelDrag();
    if (stage.place != HomePlace.home) stage.arriveHome();
    final next = _onward;
    if (next != null) {
      // Only passing through: the scene's words stay away, and the second journey leaves at once.
      _onward = null;
      stage.engagement.value = 1;
      _travel(next, pace: 0);
      return;
    }
    _updateMusic(const Duration(milliseconds: 1200));
  }

  /// Goes from the place on screen to the other one, all the way back through the scene and out again.
  void _transfer(HomeRealm realm) {
    if (_phase != _Phase.away || _placeRealm == realm) return;
    _onward = realm;
    returnHome();
  }

  /// Travels to a place from wherever the scene now stands.
  Future<void> _travel(HomeRealm realm, {required double pace, double within = HomeTravel.duration}) async {
    if (_phase != _Phase.home && _phase != _Phase.pullingOut) return;
    _build();
    if (_shown != realm) {
      _show(realm);
      _startDrift(realm, returning: false);
      _apply(_moment, realm);
    }
    _phase = _Phase.travelling;
    final fresh = stage.mount(realm);
    stage.depart(realm);
    _tween(_engagement, stage.engagement, 1, const Duration(milliseconds: 250));
    _music.stop(const Duration(milliseconds: 1400));
    final ticket = ++_journey;
    if (fresh) {
      // A place built just now is drawn first; the journey starts on the frame after, so no frame of it waits on building.
      await SchedulerBinding.instance.endOfFrame;
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame;
      if (!mounted || ticket != _journey) return;
    }
    if (_reduced) {
      _fade(0, () => _finishAway(realm));
      return;
    }
    final seconds = math.max(1.1, within * (1 - _moment));
    unawaited(_run(from: _moment, to: 1, seconds: seconds, leaving: pace, completion: () => _finishAway(realm)));
    // The world's edge is felt as it goes by.
    Timer(Duration(milliseconds: (seconds * 620).round()), () {
      if (mounted && _phase == _Phase.travelling) HapticFeedback.mediumImpact();
    });
  }

  void _finishAway(HomeRealm realm) {
    _film.pause();
    _stopDrift(clear: true);
    _content.value = 1;
    setState(() => _hidden = true);
    _phase = _Phase.away;
    stage.arrive(realm);
  }

  /// With motion reduced, a place and the scene simply fade into each other.
  void _fade(double opacity, VoidCallback completion) {
    final current = ++_journey;
    _content.animateTo(opacity, duration: const Duration(milliseconds: 450)).whenComplete(() {
      if (mounted && current == _journey) completion();
    });
  }

  // MARK: Coming back

  /// Brings the scene back over the place, with the world's edge waiting just out of sight.
  void _beginReturn() {
    final realm = _placeRealm;
    _build();
    _armed = false;
    if (_hidden) setState(() => _hidden = false);
    _show(realm);
    _startDrift(realm, returning: true);
    if (_reduced) {
      _apply(0, null);
      _content.value = 0;
    } else {
      _apply(HomeTravel.progressForPull(0, _size.height), realm);
    }
    stage.beginReturn();
  }

  void _settleAway(HomeRealm realm) {
    _phase = _Phase.travelling;
    _tween(_pull, stage.pull, 0, const Duration(milliseconds: 250));
    stage.pullArmed.value = false;
    void done() {
      _content.value = 1;
      setState(() => _hidden = true);
      _stopDrift(clear: true);
      _phase = _Phase.away;
      stage.cancelReturn();
    }

    if (_reduced) return _fade(0, done);
    _run(from: _moment, to: 1, seconds: 0.4, landing: 0, completion: done);
  }

  /// Travels back to the home scene from the place on screen.
  void returnHome() {
    if (_phase == _Phase.away) _beginReturn();
    if (_phase != _Phase.away && _phase != _Phase.pullingBack) return;
    _phase = _Phase.returning;
    _tween(_pull, stage.pull, 0, const Duration(milliseconds: 250));
    stage.pullArmed.value = false;
    if (_active) _film.play();
    if (_onward == null) _updateMusic(const Duration(milliseconds: 2200));
    if (_reduced) return _fade(1, _finishHome);
    final seconds = math.max(1.2, HomeTravel.returnDuration * _moment);
    _run(from: _moment, to: 0, seconds: seconds, landing: 0, completion: _finishHome);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _resized(constraints.biggest);
        return Offstage(
          offstage: _hidden,
          child: TickerMode(
            enabled: !_hidden,
            child: FadeTransition(
              opacity: _content,
              // The night picture always has light status and navigation bar icons over it.
              child: AnnotatedRegion<SystemUiOverlayStyle>(
                value: _lightBars,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    RepaintBoundary(child: CustomPaint(painter: HomeUnderPainter(_pose))),
                    _Slide(
                      pose: _pose,
                      child: RepaintBoundary(
                        child: HomeSceneView(film: _film, clearing: _clearing, still: _still, holdsBlur: widget.freeze == 'blur'),
                      ),
                    ),
                    IgnorePointer(
                      child: RepaintBoundary(child: CustomPaint(painter: HomeOverPainter(_pose, _drift))),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

const _lightBars = SystemUiOverlayStyle(
  statusBarColor: Color(0x00000000),
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
  systemNavigationBarColor: Color(0x00000000),
  systemNavigationBarIconBrightness: Brightness.light,
  systemNavigationBarContrastEnforced: false,
);

/// Moves its child with the camera, without rebuilding or repainting it.
class _Slide extends SingleChildRenderObjectWidget {
  const _Slide({required this.pose, super.child});
  final HomePose pose;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSlide(pose);

  @override
  void updateRenderObject(BuildContext context, _RenderSlide renderObject) => renderObject.pose = pose;
}

class _RenderSlide extends RenderProxyBox {
  _RenderSlide(this._pose);
  HomePose _pose;
  double _offset = 0;

  set pose(HomePose value) {
    if (value == _pose) return;
    if (attached) _pose.removeListener(_moved);
    _pose = value;
    if (attached) _pose.addListener(_moved);
    _moved();
  }

  void _moved() {
    final offset = _pose.slide;
    if (offset == _offset) return;
    _offset = offset;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _pose.addListener(_moved);
    _offset = _pose.slide;
  }

  @override
  void detach() {
    _pose.removeListener(_moved);
    super.detach();
  }

  /// Moving changes only where its layer is laid, never what the picture holds.
  @override
  bool get isRepaintBoundary => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    // Wholly off screen, the picture is not drawn at all.
    if (_offset.abs() >= size.height) return;
    context.paintChild(child, offset + Offset(0, _offset));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) => result.addWithPaintOffset(
    offset: Offset(0, _offset),
    position: position,
    hitTest: (result, position) => super.hitTestChildren(result, position: position),
  );

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) => transform.translateByDouble(0, _offset, 0, 1);
}
