import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/gestures.dart' show VelocityTracker;
import 'package:video_player/video_player.dart';

import '../../core/booru/booru_client.dart';
import '../../core/booru/booru_models.dart';
import '../../core/booru/booru_browser.dart';
import '../../core/booru/booru_support.dart';
import '../../core/support/l10n.dart';
import '../design/tegnal_theme.dart';
import '../content/image_translation.dart';
import '../content/reader_models.dart';
import 'booru_common.dart';

/// What the media reports to the viewer, as the native document's messages do.
sealed class BooruMediaGesture {
  const BooruMediaGesture();
}

class BooruTap extends BooruMediaGesture {
  const BooruTap(this.x);
  final double x;
}

class BooruHold extends BooruMediaGesture {
  const BooruHold();
}

class BooruSwipe extends BooruMediaGesture {
  const BooruSwipe(this.delta);
  final int delta;
}

class BooruDetails extends BooruMediaGesture {
  const BooruDetails();
}

class BooruZoom extends BooruMediaGesture {
  const BooruZoom(this.zoomed);
  final bool zoomed;
}

/// Two fingers open the menu over a video without taking its own controls.
class BooruVideoMenu extends BooruMediaGesture {
  const BooruVideoMenu();
}

/// `BooruMediaView`: one post's image or video on black. Images fit the screen and zoom to
/// eight times; notes sit over the image. Taps, holds and swipes follow the native document's
/// rules: the center third toggles the menu, the sides and horizontal swipes change posts at
/// original zoom, and a swipe up from the bottom quarter opens the details.
class BooruMediaView extends StatefulWidget {
  const BooruMediaView({
    super.key,
    required this.booru,
    required this.post,
    required this.server,
    required this.url,
    required this.active,
    required this.notes,
    required this.showNotes,
    required this.onNote,
    required this.onStatus,
    required this.onGesture,
    required this.onExitDrag,
    required this.onGoldRequired,
    required this.onRemoved,
    this.translation = const [],
  });

  final BooruContext booru;
  final BooruPost post;
  final BooruServer server;
  final String url;
  final bool active;
  final List<BooruNote> notes;
  final bool showNotes;
  final ValueChanged<BooruNote> onNote;
  final ValueChanged<String> onStatus;
  final ValueChanged<BooruMediaGesture> onGesture;

  /// The downward drag at original zoom that closes the viewer: its distance, then null with
  /// whether it should close.
  /// A pull down: each move with [end] null, then `end: true` when the finger lifts (with its
  /// sideways distance and speed in points per second) or `end: false` when it is cancelled.
  final void Function(double offset, {bool? end, double velocity, double sideways}) onExitDrag;
  final VoidCallback onGoldRequired;
  final VoidCallback onRemoved;

  /// Translated balloons over the image, as the comics reader draws them.
  final List<TranslatedRegion> translation;

  @override
  State<BooruMediaView> createState() => _BooruMediaViewState();
}

class _GestureStart {
  _GestureStart(this.position, this.zoom, {required this.video});
  final Offset position;
  final double zoom;
  final bool video;
  final DateTime time = DateTime.now();
}

class _BooruMediaViewState extends State<BooruMediaView> with SingleTickerProviderStateMixin {
  final _transform = TransformationController();
  late final AnimationController _zoomAnimation = AnimationController(vsync: this, duration: const Duration(milliseconds: 280));
  Matrix4Tween? _zoomTween;
  Uint8List? _image;
  Size? _imageSize;
  VideoPlayerController? _video;
  bool _videoControls = true;
  Timer? _controlsTimer;
  int _retries = 0;
  Timer? _retryTimer;

  _GestureStart? _start;
  final _pointers = <int, Offset>{};
  int _maxPointers = 0;
  Timer? _holdTimer;
  Timer? _tapTimer;
  DateTime? _lastTap;
  bool _held = false;
  bool _exitDragging = false;
  VelocityTracker? _velocity;
  bool _lastZoomed = false;

  double get _zoom => _transform.value.getMaxScaleOnAxis();
  bool get _isVideo => widget.post.isVideo;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_transformChanged);
    _zoomAnimation.addListener(() {
      final tween = _zoomTween;
      if (tween != null) _transform.value = tween.evaluate(CurvedAnimation(parent: _zoomAnimation, curve: Curves.easeInOut));
    });
    _load();
  }

  @override
  void didUpdateWidget(BooruMediaView old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _reset();
      _load();
    } else if (old.active != widget.active) {
      final video = _video;
      if (video != null && video.value.isInitialized) widget.active ? video.play() : video.pause();
    }
  }

  @override
  void dispose() {
    _reset();
    _transform.dispose();
    _zoomAnimation.dispose();
    super.dispose();
  }

  void _reset() {
    _retryTimer?.cancel();
    _holdTimer?.cancel();
    _tapTimer?.cancel();
    _controlsTimer?.cancel();
    _video?.removeListener(_videoChanged);
    _video?.dispose();
    _video = null;
    _image = null;
    _imageSize = null;
    _retries = 0;
    _transform.value = Matrix4.identity();
  }

  void _transformChanged() {
    final zoomed = _zoom > 1.01;
    if (zoomed != _lastZoomed) {
      _lastZoomed = zoomed;
      widget.onGesture(BooruZoom(zoomed));
    }
  }

  /// Statuses go to the viewer after the current frame, since loads start while it builds.
  void _report(String status) {
    final url = widget.url;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.url == url) widget.onStatus(status);
    });
  }

  Future<void> _load() async {
    _report('loading');
    if (widget.booru.fixture) {
      // The native UI tests show a generated landscape for every format.
      _imageSize = const Size(1600, 1200);
      _report('ready');
      return;
    }
    if (_isVideo) return _loadVideo();
    final url = widget.url;
    try {
      final data = widget.booru.viewerImages.cached(url, widget.server) ?? await widget.booru.viewerImages.load(url, widget.server);
      if (!mounted || widget.url != url) return;
      final codec = await ui.instantiateImageCodec(data);
      final frame = await codec.getNextFrame();
      final size = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
      frame.image.dispose();
      codec.dispose();
      if (!mounted || widget.url != url) return;
      setState(() {
        _image = data;
        _imageSize = size;
      });
      _report('ready');
    } on Object catch (error) {
      if (!mounted || widget.url != url) return;
      if (error == BooruPostAccessError.goldRequired) return widget.onGoldRequired();
      if (error == BooruPostAccessError.removed) return widget.onRemoved();
      _retry();
    }
  }

  /// Two quiet retries, as the document's media error handler makes, before failing.
  void _retry() {
    if (_retries >= 2) {
      _report('error');
      return;
    }
    _report('loading');
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(milliseconds: (_retries + 1) * 500), () {
      _retries++;
      if (mounted) _load();
    });
  }

  Future<void> _loadVideo() async {
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(widget.url),
      httpHeaders: BooruBrowserSession.shared.requestHeaders(widget.server, url: widget.url),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _video = controller;
    controller.addListener(_videoChanged);
    try {
      await controller.initialize();
      if (!mounted || _video != controller) return;
      await controller.setVolume(BooruVideoAudioPreferences(widget.booru.booruDefaults).muted ? 0 : 1);
      await controller.setLooping(widget.post.isUgoira);
      if (widget.active) await controller.play();
      setState(() => _imageSize = controller.value.size);
      _scheduleControlsHide();
    } on Object {
      if (mounted && _video == controller) _retryVideo();
    }
  }

  void _retryVideo() {
    _video?.removeListener(_videoChanged);
    _video?.dispose();
    _video = null;
    _retry();
  }

  String? _lastVideoStatus;
  void _videoChanged() {
    final value = _video?.value;
    if (value == null || !value.isInitialized) return;
    if (value.hasError) return _retryVideo();
    final ended = !value.isLooping && value.duration > Duration.zero && value.position >= value.duration;
    final status = ended ? 'ended' : (value.isPlaying ? 'playing' : 'ready');
    if (status != _lastVideoStatus) {
      _lastVideoStatus = status;
      _report(status);
    }
    if (mounted) setState(() {});
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (_video?.value.isPlaying ?? false)) setState(() => _videoControls = false);
    });
  }

  // MARK: Gestures

  void _cancelHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
  }

  void _pointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.localPosition;
    _maxPointers = math.max(_maxPointers, _pointers.length);
    _cancelHold();
    _held = false;
    if (_pointers.length != 1) {
      _start = null;
      return;
    }
    final size = context.size ?? Size.zero;
    final video = _isVideo && _mediaRect(size).contains(event.localPosition);
    // The bottom of a video belongs to its controls.
    if (video && event.localPosition.dy > _mediaRect(size).bottom - 56) {
      _start = null;
      return;
    }
    _start = _GestureStart(event.localPosition, _zoom, video: video);
    _velocity = VelocityTracker.withKind(event.kind)..addPosition(event.timeStamp, event.localPosition);
    _holdTimer = Timer(const Duration(milliseconds: 550), () {
      if (_start == null) return;
      _tapTimer?.cancel();
      _held = true;
      widget.onGesture(const BooruHold());
    });
  }

  void _pointerMove(PointerMoveEvent event) {
    _pointers[event.pointer] = event.localPosition;
    final start = _start;
    if (start == null) return;
    if (_pointers.length != 1) {
      _start = null;
      _cancelHold();
      return;
    }
    final delta = event.localPosition - start.position;
    _velocity?.addPosition(event.timeStamp, event.localPosition);
    if (delta.distance > 10) _cancelHold();
    // A downward drag at original zoom carries the viewer with it until it closes.
    if (start.zoom <= 1.01 && _zoom <= 1.01 && (_exitDragging || (delta.dy > 12 && delta.dy > delta.dx.abs() * 1.3))) {
      _exitDragging = true;
      widget.onExitDrag(math.max(0, delta.dy));
    }
  }

  void _pointerUp(PointerUpEvent event) {
    _pointers.remove(event.pointer);
    final twoFingerTap = _maxPointers == 2 && _pointers.isEmpty;
    if (_pointers.isEmpty) _maxPointers = 0;
    _cancelHold();
    final start = _start;
    _start = null;
    if (twoFingerTap && _isVideo) {
      widget.onGesture(const BooruVideoMenu());
      return;
    }
    if (start == null || _held || _pointers.isNotEmpty) return;
    final size = context.size ?? Size.zero;
    final delta = event.localPosition - start.position;
    final elapsed = math.max(1, DateTime.now().difference(start.time).inMilliseconds);
    final atOriginal = start.zoom <= 1.01 && _zoom <= 1.01;
    if (_exitDragging) {
      _exitDragging = false;
      _velocity?.addPosition(event.timeStamp, event.localPosition);
      widget.onExitDrag(delta.dy, end: true, velocity: _velocity?.getVelocity().pixelsPerSecond.dy ?? delta.dy / elapsed * 1000, sideways: delta.dx);
      return;
    }
    if (atOriginal && delta.dx.abs() > 50 && delta.dx.abs() > delta.dy.abs() * 1.3) {
      _tapTimer?.cancel();
      widget.onGesture(BooruSwipe(delta.dx < 0 ? 1 : -1));
      return;
    }
    final up = -delta.dy;
    if (atOriginal && start.position.dy >= size.height * 0.75 && up > delta.dx.abs() * 1.25 && (up >= 96 || (up >= 24 && up / elapsed >= 0.55))) {
      _tapTimer?.cancel();
      widget.onGesture(const BooruDetails());
      return;
    }
    if (delta.distance > 10) return;
    if (start.video) {
      setState(() => _videoControls = !_videoControls);
      _scheduleControlsHide();
      return;
    }
    // Without double tap zoom a tap acts at once instead of waiting for a second one.
    if (!(ReaderPreferences.booruDefaults.boolean(ReaderPreferences.doubleTapZoomKey) ?? true)) {
      _tapTimer?.cancel();
      widget.onGesture(BooruTap(atOriginal && size.width > 0 ? event.localPosition.dx / size.width : 0.5));
      return;
    }
    final now = DateTime.now();
    if (_lastTap != null && now.difference(_lastTap!).inMilliseconds < 300) {
      _tapTimer?.cancel();
      _lastTap = null;
      _toggleZoom(event.localPosition);
    } else {
      _lastTap = now;
      final x = atOriginal && size.width > 0 ? event.localPosition.dx / size.width : 0.5;
      _tapTimer = Timer(const Duration(milliseconds: 300), () => widget.onGesture(BooruTap(x)));
    }
  }

  void _pointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.isEmpty) _maxPointers = 0;
    _start = null;
    _cancelHold();
    if (_exitDragging) {
      _exitDragging = false;
      widget.onExitDrag(0, end: false);
    }
  }

  /// Double tap zooms 2.5× around the point, or back to fit.
  void _toggleZoom(Offset point) {
    final Matrix4 target;
    if (_zoom > 1.01) {
      target = Matrix4.identity();
    } else {
      const scale = 2.5;
      target = Matrix4.identity()
        ..translateByDouble(-point.dx * (scale - 1), -point.dy * (scale - 1), 0, 1)
        ..scaleByDouble(scale, scale, 1, 1);
    }
    _zoomTween = Matrix4Tween(begin: _transform.value.clone(), end: target);
    _zoomAnimation.forward(from: 0);
  }

  /// Where the fitted media sits in a viewer of `size`.
  Rect _mediaRect(Size size) {
    final media = _imageSize ?? Size(math.max(1, widget.post.width).toDouble(), math.max(1, widget.post.height).toDouble());
    final scale = math.min(size.width / media.width, size.height / media.height);
    final fitted = Size(media.width * scale, media.height * scale);
    return Offset((size.width - fitted.width) / 2, (size.height - fitted.height) / 2) & fitted;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _pointerDown,
      onPointerMove: _pointerMove,
      onPointerUp: _pointerUp,
      onPointerCancel: _pointerCancel,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final rect = _mediaRect(size);
          final media = _media(rect.size);
          if (media == null) return const SizedBox.expand();
          return Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  transformationController: _transform,
                  minScale: 1,
                  maxScale: 8,
                  panEnabled: !_isVideo,
                  scaleEnabled: !_isVideo,
                  child: SizedBox.fromSize(
                    size: size,
                    child: Stack(
                      children: [
                        Positioned.fromRect(
                          rect: rect,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              media,
                              if (widget.translation.isNotEmpty && !_isVideo) TranslatedRegionsLayer(regions: widget.translation),
                              if (widget.showNotes && !_isVideo) ..._notes(rect.size),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_video case final video? when video.value.isInitialized && _videoControls)
                Positioned.fromRect(
                  rect: rect,
                  child: _VideoControls(
                    controller: video,
                    onMute: (muted) {
                      BooruVideoAudioPreferences(widget.booru.booruDefaults).update(muted: muted);
                      video.setVolume(muted ? 0 : 1);
                      _scheduleControlsHide();
                    },
                    onInteraction: _scheduleControlsHide,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget? _media(Size size) {
    if (widget.booru.fixture) return CustomPaint(painter: _FixtureArtPainter(widget.post.postID));
    if (_video case final video? when video.value.isInitialized) return VideoPlayer(video);
    final image = _image;
    if (image == null) return null;
    return Image.memory(image, fit: BoxFit.contain, gaplessPlayback: true, filterQuality: FilterQuality.medium);
  }

  /// Note boxes in the image's own coordinates, numbered, opening their text.
  List<Widget> _notes(Size size) {
    final width = math.max(1, widget.post.width).toDouble();
    final height = math.max(1, widget.post.height).toDouble();
    return [
      for (final (index, note) in widget.notes.indexed)
        Positioned(
          left: (note.x / width).clamp(0, 1) * size.width,
          top: (note.y / height).clamp(0, 1) * size.height,
          child: Semantics(
            button: true,
            label: 'Note ${index + 1}',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onNote(note),
              child: Container(
                constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                width: (note.width / width).clamp(0, 1) * size.width,
                height: (note.height / height).clamp(0, 1) * size.height,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: const Color(0x33000000), borderRadius: BorderRadius.circular(6)),
                child: Text('${index + 1}', style: TegnalType.style(12, color: const Color(0xFFFFFFFF))),
              ),
            ),
          ),
        ),
    ];
  }
}

/// Play, seek and mute over a video, hidden after a few seconds of playback.
class _VideoControls extends StatelessWidget {
  const _VideoControls({required this.controller, required this.onMute, required this.onInteraction});
  final VideoPlayerController controller;
  final ValueChanged<bool> onMute;
  final VoidCallback onInteraction;

  static String _time(Duration value) {
    final seconds = value.inSeconds;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final value = controller.value;
    const white = Color(0xFFFFFFFF);
    final duration = value.duration.inMilliseconds.toDouble();
    return Stack(
      children: [
        Center(
          child: GestureDetector(
            onTap: () {
              value.isPlaying ? controller.pause() : controller.play();
              onInteraction();
            },
            child: Container(
              width: 64,
              height: 64,
              decoration: const ShapeDecoration(color: Color(0x66000000), shape: CircleBorder()),
              child: Icon(value.isPlaying ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill, size: 30, color: white),
            ),
          ),
        ),
        Positioned(
          left: 8,
          right: 8,
          bottom: 8,
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: const ShapeDecoration(color: Color(0x80000000), shape: StadiumBorder()),
            child: Row(
              children: [
                Text(_time(value.position), style: TegnalType.style(12, color: white)),
                Expanded(
                  child: CupertinoSlider(
                    value: duration <= 0 ? 0 : value.position.inMilliseconds.clamp(0, duration).toDouble(),
                    max: math.max(1, duration),
                    activeColor: white,
                    onChanged: (position) {
                      controller.seekTo(Duration(milliseconds: position.round()));
                      onInteraction();
                    },
                  ),
                ),
                Text(_time(value.duration), style: TegnalType.style(12, color: white)),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => onMute(value.volume > 0),
                  child: Icon(value.volume > 0 ? CupertinoIcons.speaker_2_fill : CupertinoIcons.speaker_slash_fill, size: 20, color: white),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The landscape the native UI tests show in place of downloaded media.
class _FixtureArtPainter extends CustomPainter {
  _FixtureArtPainter(this.postID);
  final int postID;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 1600;
    canvas.scale(scale);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 1600, 1200), Paint()..color = const Color(0xFF193655));
    final ridge = Path()
      ..moveTo(0, 1000)
      ..lineTo(500, 250)
      ..lineTo(850, 750)
      ..lineTo(1150, 400)
      ..lineTo(1600, 1000)
      ..close();
    canvas.drawPath(ridge, Paint()..color = const Color(0xFF65C8CF));
    final text = TextPainter(
      text: TextSpan(
        text: 'Booru · Post $postID',
        style: const TextStyle(fontFamily: 'serif', fontSize: 64, color: Color(0xFFFFFFFF)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, Offset(140, 160 - text.computeDistanceToActualBaseline(TextBaseline.alphabetic)));
  }

  @override
  bool shouldRepaint(_FixtureArtPainter old) => old.postID != postID;
}

/// Shown while media takes longer than 150 ms to appear.
class BooruLoadingIndicator extends StatelessWidget {
  const BooruLoadingIndicator({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    label: L10n.text('Loading'),
    child: const CupertinoActivityIndicator(color: Color(0xFFFFFFFF)),
  );
}
