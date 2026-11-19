import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../../core/support/l10n.dart';
import '../../core/support/preferences.dart';
import 'study_reactions.dart';
import 'study_symbols.dart';

// Learning mode's shared look: bright, rounded and chunky, unlike the stock iOS look of the rest of the app.
// Ported from `StudyKit.swift` (and `studyLifted` from `StudyAwardViews.swift`).

/// `TEGNAL_FIXTURE=studyMode` (a name in the comma-separated list): the `--study-mode` launch argument.
const String _fixture = String.fromEnvironment('TEGNAL_FIXTURE');

/// Whether the app is showing learning mode, which takes over the whole screen, dock included.
class StudyMode extends ChangeNotifier {
  StudyMode._();

  /// A separate instance, so that a test does not share state with the app-wide one.
  StudyMode.forTesting();

  /// The app-wide instance.
  static final StudyMode shared = StudyMode._();

  /// The image-mode preference that opens learning mode when the app starts.
  static const startKey = 'study.startInMode';

  Preferences? _preferences;
  bool _active = false;
  bool _startsActive = false;
  StudyTab _tab = StudyTab.path;

  /// Reads the stored start-up choice from the image-mode preferences (`ReaderPreferences.booruDefaults`). The app
  /// calls this once at start-up. [fixture] defaults to whether `TEGNAL_FIXTURE` names `studyMode`.
  void attach(Preferences preferences, {bool? fixture}) {
    _preferences = preferences;
    StudySound.attach(preferences);
    _startsActive = preferences.boolean(startKey) ?? false;
    final launchedIn = fixture ?? _fixture.split(',').map((name) => name.trim()).contains('studyMode');
    _active = _startsActive || launchedIn;
    notifyListeners();
  }

  /// Whether learning mode is on screen.
  bool get active => _active;

  /// The tab learning mode opens on the next time it is entered.
  StudyTab get tab => _tab;
  set tab(StudyTab value) {
    if (_tab == value) return;
    _tab = value;
    notifyListeners();
  }

  /// Open straight into learning mode when the app starts.
  bool get startsActive => _startsActive;
  set startsActive(bool value) {
    if (_startsActive == value) return;
    _startsActive = value;
    _preferences?.set(startKey, value);
    notifyListeners();
  }

  /// Opens learning mode, on [tab].
  void enter([StudyTab tab = StudyTab.path]) {
    _tab = tab;
    _active = true;
    notifyListeners();
  }

  /// Opens the library again and lets the sounds go.
  void leave() {
    _active = false;
    notifyListeners();
    StudySound.rest();
  }
}

/// The five tabs of learning mode.
enum StudyTab {
  path('Map', 'map.fill'),
  practice('Practice', 'dumbbell.fill'),
  dex('Collection', 'square.grid.2x2.fill'),
  lab('Studio', 'wand.and.stars'),
  me('Me', 'person.crop.circle.fill');

  const StudyTab(this._title, this.symbol);
  final String _title;

  /// The SF Symbol the iOS tab uses.
  final String symbol;

  /// The localized tab name.
  String get title => L10n.text(_title);

  /// The tab's icon.
  IconData get icon => StudyGlyph.icon(symbol);
}

/// iOS wraps Korean between words, never inside one. Lesson text that does not pass through [L10n.text] (the path's
/// wording, tag names, answers) goes through this before it is shown, so that narrow chips and buttons break at
/// spaces too (e.g. "쉽다" stays whole). Other languages are returned as they are.
String studyWords(String text) => L10n.language == 'ko' ? L10n.keepingWords(text) : text;

/// A colour from six hexadecimal digits (`Color(studyHex:)`); unreadable text gives the primary violet.
Color studyHex(String hex) {
  final value = int.tryParse(hex, radix: 16) ?? 0x7C5CFF;
  return Color(0xFF000000 | (value & 0xFFFFFF));
}

/// A darker shade of the same colour, for the edge a raised button stands on (`Color.studyEdge()`).
Color studyEdge(Color color) {
  final hsv = HSVColor.fromColor(color);
  return hsv.withSaturation(math.min(1, hsv.saturation * 1.05)).withValue(hsv.value * 0.72).toColor();
}

/// A paler shade of the same colour, for where light falls on a badge (`Color.studyLifted()`).
Color studyLifted(Color color) {
  final hsv = HSVColor.fromColor(color);
  return hsv.withSaturation(hsv.saturation * 0.45).withValue(math.min(1, hsv.value * 1.25 + 0.1)).toColor();
}

/// Learning mode's own colours and type, as functions of the appearance (`StudyTheme`).
class StudyTheme {
  const StudyTheme._({required this.background, required this.surface, required this.sunken, required this.line, required this.ink, required this.muted});

  /// The theme for the current appearance of [context].
  static StudyTheme of(BuildContext context) => resolve(CupertinoTheme.brightnessOf(context));

  /// The theme for one appearance.
  static StudyTheme resolve(Brightness brightness) => brightness == Brightness.dark ? dark : light;

  /// Light appearance.
  static const light = StudyTheme._(
    background: Color(0xFFF6F4FF),
    surface: Color(0xFFFFFFFF),
    sunken: Color(0xFFECE8FB),
    line: Color(0xFFDDD7F3),
    ink: Color(0xFF241F47),
    muted: Color(0xFF7A7499),
  );

  /// Dark appearance.
  static const dark = StudyTheme._(
    background: Color(0xFF13112A),
    surface: Color(0xFF1F1C3D),
    sunken: Color(0xFF2A2750),
    line: Color(0xFF37336A),
    ink: Color(0xFFF3F1FF),
    muted: Color(0xFFA49FCB),
  );

  /// The page.
  final Color background;

  /// Cards and outlined buttons.
  final Color surface;

  /// Tracks, code boxes and disabled buttons.
  final Color sunken;

  /// Borders.
  final Color line;

  /// Text.
  final Color ink;

  /// Secondary text.
  final Color muted;

  /// The violet that marks what can be pressed (`7C5CFF`), the same in both appearances.
  Color get primary => const Color(0xFF7C5CFF);

  /// Right answers and progress (`1FBF8F`).
  Color get good => const Color(0xFF1FBF8F);

  /// Wrong answers (`FF5D6C`).
  Color get bad => const Color(0xFFFF5D6C);

  /// Stars and rewards (`FFB627`).
  Color get gold => const Color(0xFFFFB627);

  /// Streaks (`FF8A3D`).
  Color get flame => const Color(0xFFFF8A3D);

  /// `FontWeight` for Swift's `.heavy`.
  static const heavy = FontWeight.w800;

  /// `FontWeight` for Swift's `.bold`.
  static const bold = FontWeight.w700;

  /// `FontWeight` for Swift's `.semibold`.
  static const semibold = FontWeight.w600;

  /// `FontWeight` for Swift's `.medium`.
  static const medium = FontWeight.w500;

  static const _family = 'Pretendard';
  static const _fallback = ['Pretendard JP'];

  /// Headings: the app font in heavy weight (iOS: rounded system font).
  static TextStyle title([double size = 28]) =>
      TextStyle(fontFamily: _family, fontFamilyFallback: _fallback, fontSize: size, fontWeight: heavy, letterSpacing: 0);

  /// Running text.
  static TextStyle body([double size = 17, FontWeight weight = semibold]) =>
      TextStyle(fontFamily: _family, fontFamilyFallback: _fallback, fontSize: size, fontWeight: weight, letterSpacing: 0);

  /// Prompt text as it is typed: the platform monospace at 17 pt, semibold.
  static const code = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: ['Menlo', 'Roboto Mono', 'Courier'],
    fontSize: 17,
    fontWeight: semibold,
    letterSpacing: 0,
  );
}

/// A `.continuous` rounded rectangle, optionally stroked inside.
ShapeBorder _shape(double radius, [BorderSide side = BorderSide.none]) => RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius), side: side);

/// `Animation.spring(duration:bounce:)` as a curve: the spring settles to 1 and may overshoot on the way. Use
/// [settle] as the duration of the animation it drives; the curve can leave the 0...1 range, so clamp it for opacity.
class StudySpring extends Curve {
  /// A spring whose oscillation lasts [duration] seconds and whose [bounce] is 0 (none) to 1.
  StudySpring(this.duration, this.bounce)
    : _simulation = SpringSimulation(
        SpringDescription(mass: 1, stiffness: math.pow(2 * math.pi / duration, 2).toDouble(), damping: 4 * math.pi * (1 - bounce) / duration),
        0,
        1,
        0,
      ) {
    var time = duration;
    while (time < 4 && !_simulation.isDone(time)) {
      time += 1 / 120;
    }
    settle = Duration(microseconds: (time * Duration.microsecondsPerSecond).round());
  }

  /// SwiftUI's `duration`, in seconds.
  final double duration;

  /// SwiftUI's `bounce`.
  final double bounce;
  final SpringSimulation _simulation;

  /// How long the spring takes to come to rest.
  late final Duration settle;

  /// `.spring(duration: 0.5, bounce: 0.3)`: the bar.
  static final bar = StudySpring(0.5, 0.3);

  /// `.spring(duration: 0.5, bounce: 0.5)`: [StudyPop].
  static final pop = StudySpring(0.5, 0.5);

  /// `.spring(duration: 0.45, bounce: 0.3)`: [StudyRise].
  static final rise = StudySpring(0.45, 0.3);

  @override
  double transformInternal(double t) => _simulation.x(t * settle.inMicroseconds / Duration.microsecondsPerSecond);
}

/// A raised button that sinks onto its edge when pressed (`StudyPressStyle`). Give it a key such as
/// `Key('study.next')` where the Swift view sets an accessibility identifier.
class StudyPressButton extends StatefulWidget {
  /// A button around [child]; [onPressed] of null disables it.
  const StudyPressButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.color,
    this.ink = const Color(0xFFFFFFFF),
    this.radius = 18,
    this.depth = 5,
    this.outlined = false,
  });

  /// The label. Text and icons in it take the button's ink.
  final Widget child;

  /// Called on release; null disables the button.
  final VoidCallback? onPressed;

  /// The face colour; null is the theme's primary.
  final Color? color;

  /// The colour of the label.
  final Color ink;

  /// The corner radius of the face.
  final double radius;

  /// How far the face stands above its edge.
  final double depth;

  /// An outlined, paper-coloured button, for choices and second actions.
  final bool outlined;

  @override
  State<StudyPressButton> createState() => _StudyPressButtonState();
}

class _StudyPressButtonState extends State<StudyPressButton> {
  bool _down = false;

  bool get _enabled => widget.onPressed != null;

  void _set(bool down) {
    if (_down == down) return;
    setState(() => _down = down);
    if (down) HapticFeedback.lightImpact();
  }

  @override
  void didUpdateWidget(StudyPressButton old) {
    super.didUpdateWidget(old);
    if (!_enabled) _down = false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final color = widget.color ?? theme.primary;
    final enabled = _enabled;
    final fill = !enabled ? theme.sunken : (widget.outlined ? theme.surface : color);
    final edge = !enabled || widget.outlined ? theme.line : studyEdge(color);
    final foreground = !enabled ? theme.muted : (widget.outlined ? theme.ink : widget.ink);
    final depth = widget.depth;
    return Semantics(
      button: true,
      enabled: enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _set(true) : null,
        onTapUp: enabled ? (_) => _set(false) : null,
        onTapCancel: enabled ? () => _set(false) : null,
        onTap: widget.onPressed,
        child: Padding(
          padding: EdgeInsets.only(bottom: depth),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: depth,
                bottom: -depth,
                child: DecoratedBox(
                  decoration: ShapeDecoration(color: edge, shape: _shape(widget.radius)),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 80),
                curve: Curves.easeOut,
                transform: Matrix4.translationValues(0, _down && enabled ? depth : 0, 0),
                decoration: ShapeDecoration(color: fill, shape: _shape(widget.radius)),
                foregroundDecoration: widget.outlined && enabled ? ShapeDecoration(shape: _shape(widget.radius, BorderSide(color: edge, width: 2))) : null,
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: foreground),
                  child: IconTheme.merge(
                    data: IconThemeData(color: foreground),
                    child: widget.child,
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

/// The wide button at the foot of a screen (`StudyMainButton`).
class StudyMainButton extends StatelessWidget {
  /// A full-width button with [title] and, optionally, an SF Symbol name in [symbol].
  const StudyMainButton({super.key, required this.title, required this.onPressed, this.color, this.symbol});

  /// The label.
  final String title;

  /// Called on release; null disables the button.
  final VoidCallback? onPressed;

  /// The face colour; null is the theme's primary.
  final Color? color;

  /// An SF Symbol name shown before the title, mapped by [StudyGlyph].
  final String? symbol;

  @override
  Widget build(BuildContext context) {
    return StudyPressButton(
      onPressed: onPressed,
      color: color,
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 15),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (symbol != null) ...[StudyIcon(symbol!, size: 19), const SizedBox(width: 8)],
              Flexible(
                child: Text(title, style: StudyTheme.body(18, StudyTheme.heavy), textAlign: TextAlign.center),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A progress bar whose fill springs to each new value (`StudyBar`).
class StudyBar extends StatelessWidget {
  /// A bar filled to [value], clamped to 0...1.
  const StudyBar({super.key, required this.value, this.color, this.height = 16, this.track});

  /// How full the bar is; values outside 0...1 are clamped.
  final double value;

  /// The fill; null is the theme's good green.
  final Color? color;

  /// The bar's thickness.
  final double height;

  /// The empty part; null is the theme's sunken colour.
  final Color? track;

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final fill = color ?? theme.good;
    final clamped = value.isNaN ? 0.0 : value.clamp(0.0, 1.0);
    return SizedBox(
      height: height,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: clamped),
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : StudySpring.bar.settle,
        curve: StudySpring.bar,
        builder: (context, shown, _) => LayoutBuilder(
          builder: (context, constraints) {
            final width = math.max(height, constraints.maxWidth * shown);
            // The track takes all the width there is, as SwiftUI's bar does, even where the parent allows less
            // (a column that centres its children); otherwise the track shrinks to the filled part.
            return SizedBox(
              width: constraints.hasBoundedWidth ? constraints.maxWidth : width,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: ShapeDecoration(color: track ?? theme.sunken, shape: const StadiumBorder()),
                    ),
                  ),
                  SizedBox(
                    width: width,
                    height: height,
                    child: DecoratedBox(
                      decoration: ShapeDecoration(color: fill, shape: const StadiumBorder()),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 6, right: 6, top: 3),
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: SizedBox(
                            height: height * 0.3,
                            child: const DecoratedBox(
                              decoration: ShapeDecoration(color: Color(0x47FFFFFF), shape: StadiumBorder()),
                              child: SizedBox.expand(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A card standing on the page (`StudyCard`).
class StudyCard extends StatelessWidget {
  /// A full-width card around [child].
  const StudyCard({super.key, required this.child, this.padding = 18});

  /// The content, aligned to the leading edge.
  final Widget child;

  /// The space inside the card.
  final double padding;

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(padding),
      decoration: ShapeDecoration(color: theme.surface, shape: _shape(22)),
      foregroundDecoration: ShapeDecoration(shape: _shape(22, BorderSide(color: theme.line, width: 2))),
      child: Align(alignment: AlignmentDirectional.topStart, heightFactor: 1, child: child),
    );
  }
}

/// Text in which the words between backticks are prompt text: monospaced, bold and primary (`StudyRichText`).
class StudyRichText extends StatelessWidget {
  /// Shows [source] at [size].
  const StudyRichText(this.source, {super.key, this.size = 17});

  /// The text, with prompt words between backticks.
  final String source;

  /// The body size; prompt words are one point smaller.
  final double size;

  /// The pieces of [source]: every second piece, the ones inside backticks, is prompt text.
  static List<({String text, bool code})> pieces(String source) => [
    for (final (index, piece) in source.split('`').indexed)
      if (piece.isNotEmpty) (text: piece, code: index.isOdd),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    return Text.rich(
      TextSpan(
        children: [
          for (final piece in pieces(source))
            TextSpan(
              text: piece.code ? piece.text : studyWords(piece.text),
              style: piece.code
                  ? StudyTheme.code.copyWith(fontSize: size - 1, fontWeight: StudyTheme.bold, color: theme.primary)
                  : StudyTheme.body(size, StudyTheme.medium).copyWith(color: theme.ink),
            ),
        ],
      ),
      style: TextStyle(color: theme.ink),
      strutStyle: StrutStyle(fontSize: size, height: (size * 1.2 + 4) / size, forceStrutHeight: true),
    );
  }
}

/// Prompt text in a box, as it would be typed (`StudyCodeBox`).
class StudyCodeBox extends StatelessWidget {
  /// A box around [code].
  const StudyCodeBox(this.code, {super.key});

  /// The text shown.
  final String code;

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: ShapeDecoration(color: theme.sunken, shape: _shape(14)),
      child: Text(code, style: StudyTheme.code.copyWith(color: theme.ink)),
    );
  }
}

/// The poses of the guide who walks the path with the learner (`StudyMascot.Pose`).
enum StudyMascotPose {
  wave('wave'),
  cheer('cheer'),
  think('think'),
  sad('sad'),
  read('read'),
  closeUp('close-up'),
  fullBody('full-body');

  const StudyMascotPose(this.fileName);

  /// The part of the drawing's file name after `StudyMascot-`.
  final String fileName;

  /// The asset of the drawing.
  String get asset => 'assets/study/mascot/StudyMascot-$fileName.png';

  /// True for the drawings that show the guide from the waist up.
  bool get isBust => this != cheer && this != fullBody;
}

/// The guide who walks the path with the learner (`StudyMascot`). A pose that fails to load shows a stand-in.
/// With [lively] it sways forever, so a test that settles must pass `lively: false`.
class StudyMascot extends StatefulWidget {
  /// The guide in [pose], [size] points square.
  const StudyMascot({super.key, this.pose = StudyMascotPose.wave, this.size = 96, this.lively = true});

  /// Which drawing to show.
  final StudyMascotPose pose;

  /// The width and height.
  final double size;

  /// Sways gently while it waits, as something alive does.
  final bool lively;

  @override
  State<StudyMascot> createState() => _StudyMascotState();
}

class _StudyMascotState extends State<StudyMascot> with SingleTickerProviderStateMixin {
  late final AnimationController _sway = AnimationController(vsync: this, duration: const Duration(milliseconds: 1150));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateSway();
  }

  @override
  void didUpdateWidget(StudyMascot old) {
    super.didUpdateWidget(old);
    _updateSway();
  }

  void _updateSway() {
    final run = widget.lively && !MediaQuery.disableAnimationsOf(context);
    if (run && !_sway.isAnimating) {
      _sway.repeat(reverse: true);
    } else if (!run && _sway.isAnimating) {
      _sway.stop();
    }
  }

  @override
  void dispose() {
    _sway.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final theme = StudyTheme.of(context);
    Widget picture = SizedBox.square(
      dimension: size,
      child: Image.asset(
        widget.pose.asset,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stack) => _StandIn(size: size, color: theme.primary),
      ),
    );
    if (widget.pose.isBust) {
      picture = ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF000000), Color(0xFF000000), Color(0x00000000)],
          stops: [0, 0.8, 1],
        ).createShader(rect),
        child: picture,
      );
    }
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _sway,
        child: picture,
        builder: (context, child) {
          // Phase `false` rests low and tilted back; phase `true` stands high and tilted forward.
          final t = Curves.easeInOut.transform(widget.lively ? _sway.value : 0);
          final lift = size * 0.015 + (-size * 0.025 - size * 0.015) * t;
          final angle = (-1.6 + 3.2 * t) * math.pi / 180;
          return Transform.translate(
            offset: Offset(0, lift),
            child: Transform.rotate(angle: angle, alignment: Alignment.bottomCenter, child: child),
          );
        },
      ),
    );
  }
}

class _StandIn extends StatelessWidget {
  const _StandIn({required this.size, required this.color});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      key: const Key('study.mascot.standin'),
      painter: _StandInPainter(color: color, radius: size * 0.36),
      child: Center(
        child: Icon(StudyGlyph.icon('sparkles'), size: size * 0.3, color: color),
      ),
    );
  }
}

class _StandInPainter extends CustomPainter {
  const _StandInPainter({required this.color, required this.radius});
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final shape = RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius));
    canvas.drawPath(shape.getOuterPath(Offset.zero & size), Paint()..color = color.withValues(alpha: 0.16));
    // A dashed outline, 2 wide, 6 on and 5 off, drawn inside the edge.
    final outline = shape.getInnerPath(Rect.fromLTWH(1, 1, size.width - 2, size.height - 2));
    final paint = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final metric in outline.computeMetrics()) {
      for (var at = 0.0; at < metric.length; at += 11) {
        canvas.drawPath(metric.extractPath(at, math.min(at + 6, metric.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_StandInPainter old) => old.color != color || old.radius != radius;
}

/// A small counter with an icon, as the bar at the top of the path shows (`StudyStat`). The icon bounces and the
/// number rolls when [value] changes.
class StudyStat extends StatefulWidget {
  /// A counter showing [value] next to the SF Symbol [symbol] in [color].
  const StudyStat({super.key, required this.symbol, required this.color, required this.value});

  /// An SF Symbol name, mapped by [StudyGlyph].
  final String symbol;

  /// The icon's colour.
  final Color color;

  /// The number shown.
  final String value;

  @override
  State<StudyStat> createState() => _StudyStatState();
}

class _StudyStatState extends State<StudyStat> with SingleTickerProviderStateMixin {
  late final AnimationController _bounce = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));

  @override
  void didUpdateWidget(StudyStat old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && !MediaQuery.disableAnimationsOf(context)) _bounce.forward(from: 0);
  }

  @override
  void dispose() {
    _bounce.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final reduce = MediaQuery.disableAnimationsOf(context);
    return DefaultTextStyle.merge(
      style: StudyTheme.body(17, StudyTheme.heavy).copyWith(color: theme.ink),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _bounce,
            // Up quickly, then back down with a small rebound.
            builder: (context, child) {
              final t = _bounce.value;
              final lift = t < 0.3 ? Curves.easeOut.transform(t / 0.3) : 1 - Curves.bounceOut.transform((t - 0.3) / 0.7);
              return Transform.translate(offset: Offset(0, -6 * lift), child: child);
            },
            child: StudyIcon(widget.symbol, size: 19, color: widget.color),
          ),
          const SizedBox(width: 5),
          AnimatedSwitcher(
            duration: reduce ? Duration.zero : const Duration(milliseconds: 400),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, 0.4), end: Offset.zero).animate(animation),
                child: child,
              ),
            ),
            child: Text(
              widget.value,
              key: ValueKey(widget.value),
              style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
        ],
      ),
    );
  }
}

/// An SF Symbol by its name, as learning mode's screens and lesson data name them. Screens use this widget rather
/// than `Icon(StudyGlyph.icon(...))`, so that a symbol with no close glyph can be given a drawing of its own here
/// without any screen changing.
class StudyIcon extends StatelessWidget {
  const StudyIcon(this.symbol, {super.key, this.size = 20, this.color});

  /// The SF Symbol name, such as `wand.and.stars`.
  final String symbol;
  final double size;

  /// Null takes the colour of the text around it.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (!studySymbolDrawn(symbol)) return Icon(StudyGlyph.icon(symbol), size: size, color: color);
    // The colour as `Icon` works it out: the given one, else the icon theme's, faded by the theme's opacity.
    final theme = IconTheme.of(context);
    var resolved = color ?? theme.color ?? const Color(0xFF000000);
    final opacity = theme.opacity ?? 1;
    if (opacity != 1) resolved = resolved.withValues(alpha: resolved.a * opacity);
    return ExcludeSemantics(
      child: studySymbol(symbol, size: size, color: resolved),
    );
  }
}

/// `Image(systemName:)` for Flutter: the SF Symbol names that the iOS code and the lesson data use, as the closest
/// `CupertinoIcons` glyph. Some have no close glyph and get a stand-in.
abstract final class StudyGlyph {
  /// The icon for an SF Symbol name; an unknown name gives a circle.
  static IconData icon(String symbol) => switch (symbol) {
    'arrow.left.arrow.right' => CupertinoIcons.arrow_left_right,
    'scope' => CupertinoIcons.scope,
    'arrow.right.circle' => CupertinoIcons.arrow_right_circle,
    'arrow.triangle.2.circlepath' => CupertinoIcons.arrow_2_circlepath,
    'arrow.triangle.branch' => CupertinoIcons.arrow_branch,
    'arrow.up.left.and.arrow.down.right' => CupertinoIcons.fullscreen,
    'arrow.up.left.and.down.right.and.arrow.up.right.and.down.left' => CupertinoIcons.move,
    'arrow.up.right.square' => CupertinoIcons.arrow_up_right_square,
    'bandage' => CupertinoIcons.bandage,
    'bolt.circle' => CupertinoIcons.bolt_circle,
    'bolt.fill' => CupertinoIcons.bolt_fill,
    'bolt.horizontal.fill' => CupertinoIcons.bolt_horizontal_fill,
    'book' => CupertinoIcons.book,
    'book.fill' => CupertinoIcons.book_fill,
    'books.vertical.fill' => CupertinoIcons.rectangle_stack_fill,
    'brain.head.profile' => CupertinoIcons.lightbulb,
    'bubble.left.and.text.bubble.right' => CupertinoIcons.bubble_left_bubble_right,
    'building.columns' => CupertinoIcons.building_2_fill,
    'calendar' => CupertinoIcons.calendar,
    'calendar.badge.clock' => CupertinoIcons.calendar_badge_plus,
    'camera.aperture' => CupertinoIcons.camera_viewfinder,
    'camera.fill' => CupertinoIcons.camera_fill,
    'camera.filters' => CupertinoIcons.color_filter,
    'character.book.closed' => CupertinoIcons.book,
    'chart.bar' => CupertinoIcons.chart_bar,
    'checkmark' => CupertinoIcons.checkmark,
    'checkmark.circle.fill' => CupertinoIcons.checkmark_circle_fill,
    'checkmark.seal' => CupertinoIcons.checkmark_seal,
    'checkmark.seal.fill' => CupertinoIcons.checkmark_seal_fill,
    'chevron.right' => CupertinoIcons.chevron_right,
    'circle' => CupertinoIcons.circle,
    'circle.fill' => CupertinoIcons.circle_fill,
    'circle.lefthalf.filled' => CupertinoIcons.circle_lefthalf_fill,
    'cloud' => CupertinoIcons.cloud,
    'cloud.sun.fill' => CupertinoIcons.cloud_sun_fill,
    'cpu' => CupertinoIcons.gear_alt,
    'creditcard' => CupertinoIcons.creditcard,
    'crop' => CupertinoIcons.crop,
    'crown.fill' => CupertinoIcons.star_circle_fill,
    'desktopcomputer' => CupertinoIcons.desktopcomputer,
    'dial.low' => CupertinoIcons.dial,
    'diamond' => CupertinoIcons.rhombus,
    'dice' => CupertinoIcons.cube,
    'doc.on.doc' => CupertinoIcons.doc_on_doc,
    'doc.text' => CupertinoIcons.doc_text,
    'doc.text.magnifyingglass' => CupertinoIcons.doc_text_search,
    'doc.viewfinder' => CupertinoIcons.doc_text_viewfinder,
    'door.left.hand.open' => CupertinoIcons.square_arrow_right,
    'dumbbell.fill' => CupertinoIcons.gamecontroller_fill,
    'eye' => CupertinoIcons.eye,
    'eye.fill' => CupertinoIcons.eye_fill,
    'eye.slash' => CupertinoIcons.eye_slash,
    'eyeglasses' => CupertinoIcons.eyeglasses,
    'face.dashed' => CupertinoIcons.smiley,
    'face.smiling' => CupertinoIcons.smiley,
    'figure.run' => CupertinoIcons.hare,
    'figure.stand' => CupertinoIcons.person_alt,
    'figure.walk' => CupertinoIcons.person_alt,
    'flag.fill' => CupertinoIcons.flag_fill,
    'flame.fill' => CupertinoIcons.flame_fill,
    'function' => CupertinoIcons.function,
    'gauge.with.dots.needle.33percent' => CupertinoIcons.gauge,
    'gearshape' => CupertinoIcons.gear,
    'globe' => CupertinoIcons.globe,
    'globe.asia.australia' => CupertinoIcons.globe,
    'graduationcap.fill' => CupertinoIcons.book_fill,
    'hand.draw.fill' => CupertinoIcons.hand_draw_fill,
    'hand.raised' => CupertinoIcons.hand_raised,
    'hand.raised.fill' => CupertinoIcons.hand_raised_fill,
    'hands.clap' => CupertinoIcons.hand_thumbsup,
    'hare.fill' => CupertinoIcons.hare_fill,
    'heart' => CupertinoIcons.heart,
    'house.fill' => CupertinoIcons.house_fill,
    'iphone.and.arrow.forward' => CupertinoIcons.device_phone_portrait,
    'iphone.gen3' => CupertinoIcons.device_phone_portrait,
    'key' => CupertinoIcons.lock_open,
    'key.fill' => CupertinoIcons.lock_open_fill,
    'laptopcomputer' => CupertinoIcons.device_laptop,
    'leaf' => CupertinoIcons.tree,
    'leaf.fill' => CupertinoIcons.tree,
    'lightbulb.fill' => CupertinoIcons.lightbulb_fill,
    'list.bullet' => CupertinoIcons.list_bullet,
    'lock.fill' => CupertinoIcons.lock_fill,
    'lock.shield' => CupertinoIcons.lock_shield,
    'magnifyingglass' => CupertinoIcons.search,
    'map' => CupertinoIcons.map,
    'map.fill' => CupertinoIcons.map_fill,
    'mappin.and.ellipse' => CupertinoIcons.map_pin_ellipse,
    'mappin.circle' => CupertinoIcons.map_pin,
    'megaphone' => CupertinoIcons.speaker_3_fill,
    'memorychip' => CupertinoIcons.rectangle_split_3x3,
    'minus.circle' => CupertinoIcons.minus_circle,
    'paintbrush' => CupertinoIcons.paintbrush,
    'paintbrush.pointed' => CupertinoIcons.paintbrush,
    'paintbrush.pointed.fill' => CupertinoIcons.paintbrush_fill,
    'paintpalette' => CupertinoIcons.color_filter,
    'paintpalette.fill' => CupertinoIcons.color_filter_fill,
    'party.popper' => CupertinoIcons.gift_fill,
    'pawprint.fill' => CupertinoIcons.paw,
    'pencil.and.outline' => CupertinoIcons.pencil_outline,
    'pencil.tip' => CupertinoIcons.pencil,
    'person.2.fill' => CupertinoIcons.person_2_fill,
    'person.3' => CupertinoIcons.person_3,
    'person.badge.key' => CupertinoIcons.person_badge_plus,
    'person.crop.circle.badge.plus' => CupertinoIcons.person_crop_circle_badge_plus,
    'person.crop.circle.fill' => CupertinoIcons.person_crop_circle_fill,
    'person.crop.rectangle.badge.plus' => CupertinoIcons.person_crop_rectangle,
    'photo.badge.magnifyingglass' => CupertinoIcons.photo,
    'photo.on.rectangle.angled' => CupertinoIcons.photo_on_rectangle,
    'photo.stack' => CupertinoIcons.collections,
    'photo.stack.fill' => CupertinoIcons.collections_solid,
    'play.fill' => CupertinoIcons.play_fill,
    'plus.forwardslash.minus' => CupertinoIcons.plus_slash_minus,
    'point.3.connected.trianglepath.dotted' => CupertinoIcons.flowchart,
    'point.3.filled.connected.trianglepath.dotted' => CupertinoIcons.flowchart_fill,
    'puzzlepiece.extension' => CupertinoIcons.rectangle_3_offgrid,
    'questionmark.circle' => CupertinoIcons.question_circle,
    'rectangle.and.hand.point.up.left' => CupertinoIcons.hand_point_left,
    'rosette' => CupertinoIcons.rosette,
    'ruler.fill' => CupertinoIcons.resize_h,
    'safari.fill' => CupertinoIcons.compass_fill,
    'scalemass' => CupertinoIcons.minus_slash_plus,
    'scissors' => CupertinoIcons.scissors,
    'scribble' => CupertinoIcons.scribble,
    'shield.fill' => CupertinoIcons.shield_fill,
    'shippingbox' => CupertinoIcons.cube_box,
    'shoe.fill' => CupertinoIcons.hare_fill,
    'signpost.right' => CupertinoIcons.location_north_fill,
    'slider.horizontal.3' => CupertinoIcons.slider_horizontal_3,
    'space' => CupertinoIcons.minus_rectangle,
    'sparkle.magnifyingglass' => CupertinoIcons.sparkles,
    'sparkles' => CupertinoIcons.sparkles,
    'sparkles.tv' => CupertinoIcons.tv,
    'speaker.wave.2.fill' => CupertinoIcons.speaker_2_fill,
    'square.grid.2x2.fill' => CupertinoIcons.square_grid_2x2_fill,
    'square.grid.3x3.square' => CupertinoIcons.square_grid_3x2,
    'square.stack.3d.down.right' => CupertinoIcons.square_stack_3d_down_right,
    'square.stack.3d.up' => CupertinoIcons.square_stack_3d_up,
    'stairs' => CupertinoIcons.chart_bar_alt_fill,
    'star.fill' => CupertinoIcons.star_fill,
    'sun.max.fill' => CupertinoIcons.sun_max_fill,
    'tag' => CupertinoIcons.tag,
    'tag.fill' => CupertinoIcons.tag_fill,
    'target' => CupertinoIcons.scope,
    'terminal' => CupertinoIcons.chevron_left_slash_chevron_right,
    'text.badge.plus' => CupertinoIcons.text_badge_plus,
    'text.book.closed.fill' => CupertinoIcons.book_fill,
    'text.bubble' => CupertinoIcons.text_bubble,
    'text.magnifyingglass' => CupertinoIcons.doc_text_search,
    'thermometer.medium' => CupertinoIcons.thermometer,
    'ticket' => CupertinoIcons.ticket,
    'timer' => CupertinoIcons.timer,
    'tortoise' => CupertinoIcons.tortoise,
    'tray.and.arrow.down.fill' => CupertinoIcons.tray_arrow_down_fill,
    'tray.and.arrow.up' => CupertinoIcons.tray_arrow_up,
    'tray.full' => CupertinoIcons.tray_full,
    'trophy.fill' => CupertinoIcons.star_circle_fill,
    'tshirt.fill' => CupertinoIcons.bag_fill,
    'wand.and.stars' => CupertinoIcons.wand_stars,
    'waveform' => CupertinoIcons.waveform,
    'wrench.and.screwdriver' => CupertinoIcons.wrench,
    'xmark' => CupertinoIcons.xmark,
    'xmark.circle.fill' => CupertinoIcons.xmark_circle_fill,
    _ => CupertinoIcons.circle,
  };
}
