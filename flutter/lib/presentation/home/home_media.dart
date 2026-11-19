import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

/// The night colours at the head and foot of the illustration, which the sky and the ground continue.
abstract final class HomePalette {
  static const sky = Color(0xFF0B0717);
  static const ground = Color(0xFF1E1430);
  static const dusk = Color(0xFF2A1E51);
}

/// How the picture sits on a screen. A phone shows all of it. A tablet or a desktop window is another
/// shape, so the picture fills it and closes in on the word TEGNAL.
abstract final class HomeFraming {
  static const pictureSize = Size(1206, 2622);

  /// The middle of the word TEGNAL, as a share of the picture's width and height.
  static const focus = Offset(0.5, 0.388);

  /// Where the whole picture lies so that it covers a screen of this size with its focus in the middle,
  /// or as near the middle as the picture's own edges allow.
  static Rect frame(Size size) {
    final scale = math.max(size.width / pictureSize.width, size.height / pictureSize.height);
    final width = pictureSize.width * scale, height = pictureSize.height * scale;
    return Rect.fromLTWH(
      math.min(0, math.max(size.width - width, size.width / 2 - width * focus.dx)),
      math.min(0, math.max(size.height - height, size.height / 2 - height * focus.dy)),
      width,
      height,
    );
  }
}

/// The film's first frame, already blurred: what the system shows while the app starts and what the
/// scene opens from. It is decoded before the first frame, so that the first frame already shows it.
///
/// `home_blur.jpg` is a capture of the scene's own live blur, so that the hand-over is invisible.
/// To capture it again after changing the blur or the film, on an emulator:
///   1. `adb -s <emulator> shell wm size 1206x2622` and `wm density 480` (402 × 874 points, the picture's own shape);
///   2. `flutter run -d <emulator> --dart-define=TEGNAL_FIXTURE=on --dart-define=TEGNAL_HOME=blur`, which holds the
///      live blur without the still and hides the system bars;
///   3. `adb exec-out screencap -p > blur.png`, scale it to 603 × 1311 (`sips -Z 1311`) and save it as JPEG;
///   4. write it to `flutter/assets/home/home_blur.jpg` and to `flutter/android/app/src/main/res/drawable-nodpi/home_blur.jpg`
///      (the Android launch cover), then `wm size reset` and `wm density reset`.
abstract final class HomeStill {
  static const asset = 'assets/home/home_blur.jpg';
  static ui.Image? image;

  static Future<void> load() async {
    if (image != null) return;
    try {
      final data = await rootBundle.load(asset);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      image = (await codec.getNextFrame()).image;
      codec.dispose();
    } on Object {
      // The scene then opens from its plain dusk colour.
    }
  }

  /// Once the scene has opened, the still is not needed again until the app starts anew.
  static void release() {
    image?.dispose();
    image = null;
  }
}

/// Nothing the scene plays takes the sound from another app or keeps playing in the background on its own.
VideoPlayerOptions get _quietOptions => VideoPlayerOptions(mixWithOthers: true, allowBackgroundPlayback: true);

/// The illustration's film: its opening once, then its loop for as long as the scene is watched.
///
/// The loop waits, paused on its first frame, under the opening; when the opening ends the loop starts
/// and the opening is let go, so the hand-over shows no seam.
class HomeFilm extends ChangeNotifier {
  VideoPlayerController? intro;
  VideoPlayerController? loop;

  /// Called once the first frame of the film can be shown.
  VoidCallback? onFirstFrame;
  bool _firstFrame = false;
  bool _wantsPlayback = false;
  bool _cleared = false;
  bool _handingOver = false;
  bool _disposed = false;

  bool get firstFrame => _firstFrame;

  Future<void> load() async {
    final loop = this.loop = VideoPlayerController.asset('assets/home/home_loop.mp4', videoPlayerOptions: _quietOptions);
    final intro = this.intro = VideoPlayerController.asset('assets/home/home_intro.mp4', videoPlayerOptions: _quietOptions);
    final loading = [
      _prepare(loop).then((ready) async {
        if (!ready) return;
        await loop.setLooping(true);
        if (this.intro == null) _ready();
      }),
      _prepare(intro).then((ready) {
        if (!ready) {
          this.intro = null;
          intro.dispose();
          if (this.loop?.value.isInitialized ?? false) _ready();
          return;
        }
        intro.addListener(_watchIntro);
        _ready();
      }),
    ];
    await Future.wait(loading);
  }

  Future<bool> _prepare(VideoPlayerController controller) async {
    try {
      await controller.initialize();
      await controller.setVolume(0);
      if (!_disposed) controller.addListener(() => _watchError(controller));
      return !_disposed;
    } on Object {
      return false;
    }
  }

  /// A decoder that fails leaves the picture to the poster under it rather than to a frozen or black frame.
  void _watchError(VideoPlayerController controller) {
    if (!controller.value.hasError || _disposed) return;
    if (identical(controller, intro)) {
      intro = null;
      // The loop takes over at once.
      if (_cleared && _wantsPlayback) loop?.play();
    } else if (identical(controller, loop)) {
      loop = null;
    } else {
      return;
    }
    notifyListeners();
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
  }

  void _ready() {
    if (_disposed) return;
    notifyListeners();
    if (_firstFrame) return;
    _firstFrame = true;
    onFirstFrame?.call();
  }

  /// The opening has played to its end: the loop takes over, and the opening goes once the loop is moving.
  void _watchIntro() {
    final intro = this.intro, loop = this.loop;
    if (intro == null || _handingOver) return;
    final value = intro.value;
    if (!value.isInitialized || value.duration == Duration.zero) return;
    if (value.position < value.duration - const Duration(milliseconds: 30) && !value.isCompleted) return;
    _handingOver = true;
    if (loop == null || !loop.value.isInitialized) {
      intro.seekTo(Duration.zero);
      if (_wantsPlayback) intro.play();
      _handingOver = false;
      return;
    }
    intro.removeListener(_watchIntro);
    (_wantsPlayback ? loop.play() : Future<void>.value()).whenComplete(() {
      if (_disposed) return;
      this.intro = null;
      notifyListeners();
      // Let go of it after the frame that no longer shows it.
      WidgetsBinding.instance.addPostFrameCallback((_) => intro.dispose());
    });
  }

  /// The film plays while the scene is watched. Before the blur has cleared it waits on its first frame.
  void play() {
    _wantsPlayback = true;
    if (_cleared) _current?.play();
  }

  void pause() {
    _wantsPlayback = false;
    intro?.pause();
    loop?.pause();
  }

  /// The blur has cleared: the film may move.
  void cleared() {
    _cleared = true;
    if (_wantsPlayback) _current?.play();
  }

  VideoPlayerController? get _current => _handingOver ? loop : intro ?? loop;

  @override
  void dispose() {
    _disposed = true;
    intro?.dispose();
    loop?.dispose();
    super.dispose();
  }
}

/// The illustration itself: the film framed on the screen, the shades that run it into the night above
/// and below, and the opening blur with the still that stands in for it while the app starts.
class HomeSceneView extends StatelessWidget {
  const HomeSceneView({super.key, required this.film, required this.clearing, required this.still, required this.holdsBlur});
  final HomeFilm film;

  /// From 0, the blurred opening, to 1, the clear picture.
  final Animation<double> clearing;

  /// The still's opacity; it goes once the live picture is ready under it.
  final Animation<double> still;

  /// For capturing the still: the live blur stays, without the still over it.
  final bool holdsBlur;

  /// How soft the opening is, as a share of the drawn picture's width, so that every screen shows the same blur.
  static const blurShare = 0.058;

  /// The dark, slightly grey haze laid over the blur, as a dark ultra-thin material.
  static const haze = Color(0x4D38343F);

  /// How much colour the blurred picture keeps; the material greys it a little.
  static const saturation = 0.72;

  static List<double> _saturating(double amount) {
    const r = 0.2126, g = 0.7152, b = 0.0722;
    final rest = 1 - amount;
    return [
      r * rest + amount, g * rest, b * rest, 0, 0, //
      r * rest, g * rest + amount, b * rest, 0, 0,
      r * rest, g * rest, b * rest + amount, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  static const _curve = Cubic(0.3, 0, 0.2, 1);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      final frame = HomeFraming.frame(size);
      final picture = RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fromRect(
              rect: frame,
              child: const Image(image: AssetImage('assets/home/home_poster.jpg'), fit: BoxFit.fill, gaplessPlayback: true),
            ),
            Positioned.fromRect(
              rect: frame,
              child: _Film(film: film),
            ),
            // The picture ends in the same dark as the sky above it and the soil under it, whatever part of it the screen shows.
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: size.height * 0.16,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [HomePalette.sky, Color(0x000B0717)]),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: size.height * 0.9,
              height: size.height * 0.1,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x001E1430), HomePalette.ground]),
                ),
              ),
            ),
          ],
        ),
      );
      final sigma = frame.width * blurShare;
      return ColoredBox(
        color: HomePalette.dusk,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRect(
              child: AnimatedBuilder(
                animation: clearing,
                child: picture,
                builder: (context, child) {
                  final open = holdsBlur ? 0.0 : _curve.transform(clearing.value);
                  Widget result = Transform.scale(scale: 1.08 - 0.08 * open, child: child);
                  if (open >= 1) return result;
                  final blur = sigma * (1 - open);
                  result = ImageFiltered(
                    imageFilter: ui.ImageFilter.compose(
                      outer: ui.ColorFilter.matrix(_saturating(saturation + (1 - saturation) * open)),
                      inner: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur, tileMode: TileMode.clamp),
                    ),
                    child: result,
                  );
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      result,
                      ColoredBox(color: haze.withValues(alpha: haze.a * (1 - open))),
                    ],
                  );
                },
              ),
            ),
            if (!holdsBlur)
              AnimatedBuilder(
                animation: still,
                builder: (context, _) {
                  final image = HomeStill.image;
                  if (still.value <= 0) return const SizedBox.shrink();
                  return IgnorePointer(
                    child: Opacity(
                      opacity: still.value,
                      child: ClipRect(
                        child: CustomSingleChildLayout(
                          delegate: _FrameLayout(frame),
                          child: image == null
                              ? const Image(image: AssetImage(HomeStill.asset), fit: BoxFit.fill)
                              : RawImage(image: image, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      );
    },
  );
}

/// Lays the still exactly where the film lies.
class _FrameLayout extends SingleChildLayoutDelegate {
  const _FrameLayout(this.frame);
  final Rect frame;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => BoxConstraints.tight(frame.size);

  @override
  Offset getPositionForChild(Size size, Size childSize) => frame.topLeft;

  @override
  bool shouldRelayout(_FrameLayout old) => old.frame != frame;
}

/// The loop, with the opening over it while it plays.
class _Film extends StatelessWidget {
  const _Film({required this.film});
  final HomeFilm film;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: film,
    builder: (context, _) {
      final loop = film.loop, intro = film.intro;
      return Stack(
        fit: StackFit.expand,
        children: [if (loop != null && loop.value.isInitialized) VideoPlayer(loop), if (intro != null && intro.value.isInitialized) VideoPlayer(intro)],
      );
    },
  );
}

/// The scene's music. Everything it plays is media: the volume buttons set it and the silent setting
/// leaves it alone, and it never takes the sound from another app. Someone already listening to
/// something else keeps it and hears no music here.
class HomeMusic {
  static const level = 0.85;
  static const _screen = MethodChannel('work.nextline.tegnal/screen');

  VideoPlayerController? _player;
  bool _loading = false;
  bool _wanted = false;
  bool _disposed = false;
  double _volume = 0;
  Timer? _fade;
  Timer? _quiet;

  void play(Duration fade) {
    _wanted = true;
    _quiet?.cancel();
    _quiet = null;
    final player = _player;
    if (player == null) {
      _load(fade);
    } else {
      _start(player, fade);
    }
  }

  Future<void> _load(Duration fade) async {
    if (_loading) return;
    _loading = true;
    final player = VideoPlayerController.asset('assets/home/home_theme.mp3', videoPlayerOptions: _quietOptions);
    try {
      await player.initialize();
      await player.setLooping(true);
      await player.setVolume(0);
    } on Object {
      _loading = false;
      await player.dispose();
      return;
    }
    _loading = false;
    if (_disposed) {
      await player.dispose();
      return;
    }
    _player = player;
    if (_wanted) _start(player, fade);
  }

  /// Whether another app is playing sound; any doubt counts as no.
  static Future<bool> _otherAudioPlaying() async {
    try {
      return await _screen.invokeMethod<bool>('musicActive') ?? false;
    } on Object {
      return false;
    }
  }

  Future<void> _start(VideoPlayerController player, Duration fade) async {
    if (!player.value.isPlaying) {
      if (await _otherAudioPlaying()) return;
      if (!_wanted || _disposed) return;
      _volume = 0;
      await player.setVolume(0);
      await player.play();
    }
    _fadeTo(level, fade);
  }

  void stop(Duration fade) {
    _wanted = false;
    final player = _player;
    if (player == null || !player.value.isPlaying) return;
    _fadeTo(0, fade);
    _quiet?.cancel();
    _quiet = Timer(fade + const Duration(milliseconds: 50), () {
      if (!_wanted) _player?.pause();
    });
  }

  void _fadeTo(double target, Duration duration) {
    _fade?.cancel();
    final player = _player;
    if (player == null) return;
    final from = _volume, steps = math.max(1, duration.inMilliseconds ~/ 40);
    var step = 0;
    _fade = Timer.periodic(const Duration(milliseconds: 40), (timer) {
      step += 1;
      final share = step / steps;
      _volume = from + (target - from) * math.min(1, share);
      player.setVolume(_volume);
      if (share >= 1) timer.cancel();
    });
  }

  void dispose() {
    _disposed = true;
    _fade?.cancel();
    _quiet?.cancel();
    _player?.dispose();
  }
}
