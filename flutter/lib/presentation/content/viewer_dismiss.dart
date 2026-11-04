import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'reader_models.dart';

/// The route a viewer opens in, as `fullScreenCover`: it slides up and covers the screen.
/// While it is pulled down the screen under it shows through, and once it has followed the
/// finger off the screen it closes without a second animation (`ReaderInteractiveExit`).
class ViewerRoute<T> extends PageRoute<T> {
  ViewerRoute({required this.builder});
  final WidgetBuilder builder;

  bool _seeThrough = false;
  bool _closesInstantly = false;

  @override
  bool get opaque => !_seeThrough;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 380);

  @override
  Duration get reverseTransitionDuration => _closesInstantly ? Duration.zero : const Duration(milliseconds: 300);

  /// Lets the screen under the viewer paint while the viewer is dragged.
  void setSeeThrough(bool value) {
    if (_seeThrough == value) return;
    _seeThrough = value;
    if (overlayEntries.isNotEmpty) overlayEntries.first.opaque = !value;
  }

  /// The next close skips the slide down: the viewer has already left the screen.
  void closeInstantly() => _closesInstantly = true;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) => builder(context);

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) => SlideTransition(
    position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
    child: child,
  );
}

/// `ReaderExitMotion`: the viewer follows a downward pull one to one with rounding corners,
/// ticks as the pull starts and again where letting go would close it, then either leaves the
/// screen or springs back.
class ViewerDismiss extends ChangeNotifier {
  ViewerDismiss({required TickerProvider vsync}) : _animation = AnimationController(vsync: vsync) {
    _animation.addListener(() {
      final from = _from, to = _to;
      if (from == null || to == null) return;
      _distance = from + (to - from) * Curves.easeOut.transform(_animation.value);
      notifyListeners();
    });
  }

  final AnimationController _animation;
  double _distance = 0;
  double? _from, _to;
  ReaderExitIntent _intent = ReaderExitIntent();
  bool _crossed = false;
  bool _active = false;
  ViewerRoute<dynamic>? _route;

  /// How far the viewer has been pulled down.
  double get distance => _distance;
  bool get isActive => _active;

  void begin(BuildContext context) {
    _animation.stop();
    _active = true;
    _intent = ReaderExitIntent();
    _crossed = false;
    final route = ModalRoute.of(context);
    _route = route is ViewerRoute ? route : null;
    _route?.setSeeThrough(true);
    HapticFeedback.lightImpact();
  }

  void update(double dy) {
    if (!_active) return;
    _distance = math.max(0, dy);
    _intent.update(_distance);
    if (_distance >= ReaderDismissal.threshold && !_crossed) {
      _crossed = true;
      HapticFeedback.mediumImpact();
    }
    notifyListeners();
  }

  /// Closes when the pull went far or fast enough without turning back; otherwise returns.
  void end({required Offset delta, required Offset velocity, required double screenHeight, required VoidCallback exit}) {
    if (!_active) return;
    update(delta.dy);
    _active = false;
    if (_intent.shouldFinish(delta: delta, velocity: velocity)) {
      _run(screenHeight, const Duration(milliseconds: 180), () {
        _route?.closeInstantly();
        exit();
      });
    } else {
      cancel();
    }
  }

  void cancel() {
    _active = false;
    _run(0, const Duration(milliseconds: 220), () => _route?.setSeeThrough(false));
  }

  void _run(double target, Duration duration, VoidCallback done) {
    _from = _distance;
    _to = target;
    _animation.duration = duration;
    _animation.forward(from: 0).whenCompleteOrCancel(() {
      if (_animation.isCompleted) done();
    });
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }
}

/// Moves the viewer with the pull and rounds its corners as it leaves, up to 24 points.
class ViewerDismissSurface extends StatelessWidget {
  const ViewerDismissSurface({super.key, required this.dismiss, required this.child});
  final ViewerDismiss dismiss;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: dismiss,
    child: child,
    // One tree whatever the distance, so the viewer under it keeps its state and its gestures.
    builder: (context, child) {
      final distance = dismiss.distance;
      return Transform.translate(
        offset: Offset(0, distance),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(math.min(24, distance / 4)),
          clipBehavior: distance > 0 ? Clip.antiAlias : Clip.none,
          child: child,
        ),
      );
    },
  );
}

/// A one-finger vertical swipe that wins over the pager and page zoom as soon as it is clearly
/// heading [down] (or up), so it starts the instant the finger moves. [accepts] decides from the
/// first touch whether this swipe may start there at all.
class ViewerSwipeRecognizer extends OneSequenceGestureRecognizer {
  ViewerSwipeRecognizer({required this.down, required this.accepts, super.debugOwner});

  final bool down;
  bool Function(Offset globalPosition) accepts;
  void Function()? onStart;
  void Function(Offset delta)? onUpdate;
  void Function(Offset delta, Offset velocity)? onEnd;
  void Function()? onCancel;

  int? _pointer;
  Offset _start = Offset.zero;
  Offset _delta = Offset.zero;
  bool _accepted = false;
  VelocityTracker? _tracker;

  @override
  bool isPointerAllowed(PointerDownEvent event) => event.kind != PointerDeviceKind.mouse || event.buttons == kPrimaryButton;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    // A second finger is a pinch, never a swipe.
    if (_pointer != null) {
      resolve(GestureDisposition.rejected);
      return;
    }
    if (!accepts(event.position)) return;
    super.addAllowedPointer(event);
    _pointer = event.pointer;
    _start = event.position;
    _delta = Offset.zero;
    _accepted = false;
    _tracker = VelocityTracker.withKind(event.kind)..addPosition(event.timeStamp, event.position);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _tracker?.addPosition(event.timeStamp, event.position);
    if (event is PointerMoveEvent) {
      _delta = event.position - _start;
      if (!_accepted) {
        final along = down ? _delta.dy : -_delta.dy;
        if (along > 8 && along > _delta.dx.abs() * 1.25) {
          _accepted = true;
          resolve(GestureDisposition.accepted);
          onStart?.call();
        } else if (along < -8 || _delta.dx.abs() > 12) {
          resolve(GestureDisposition.rejected);
          stopTrackingPointer(event.pointer);
        }
      }
      if (_accepted) onUpdate?.call(_delta);
    } else if (event is PointerUpEvent) {
      if (_accepted) onEnd?.call(_delta, _tracker?.getVelocity().pixelsPerSecond ?? Offset.zero);
      stopTrackingPointer(event.pointer);
    } else if (event is PointerCancelEvent) {
      if (_accepted) onCancel?.call();
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void rejectGesture(int pointer) {
    if (_accepted && pointer == _pointer) onCancel?.call();
    super.rejectGesture(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _pointer = null;
    _accepted = false;
    _tracker = null;
  }

  @override
  String get debugDescription => down ? 'viewer pull down' : 'viewer swipe up';
}

/// The pull down that closes a viewer.
class ViewerPullDownRecognizer extends ViewerSwipeRecognizer {
  ViewerPullDownRecognizer({required super.accepts}) : super(down: true);
}

/// The swipe up from the bottom that opens work information.
class ViewerSwipeUpRecognizer extends ViewerSwipeRecognizer {
  ViewerSwipeUpRecognizer({required super.accepts}) : super(down: false);
}
