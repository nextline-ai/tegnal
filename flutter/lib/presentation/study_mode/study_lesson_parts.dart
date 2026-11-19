import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/booru/booru_models.dart';
import '../../core/support/l10n.dart';
import '../booru/booru_common.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import '../study/study_widgets.dart';
import 'study_kit.dart';
import 'study_reactions.dart';

// The pieces every lesson step is built from. Ported from the "Shared pieces" of `StudyLessonView.swift`.

/// A rounded rectangle with continuous corners, as SwiftUI's `RoundedRectangle(style: .continuous)`.
ShapeBorder studyRounded(double radius, [BorderSide side = BorderSide.none]) =>
    RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius), side: side);

/// Whether the screen is wide enough for SwiftUI's regular horizontal size class.
bool studyIsRegular(BuildContext context) => MediaQuery.sizeOf(context).width >= 600;

/// `typeSize.isAccessibilitySize`: the text is scaled to roughly 1.6 times or more.
bool studyIsAccessibilitySize(BuildContext context) => MediaQuery.textScalerOf(context).scale(17) / 17 >= 1.6;

/// The width over height of [post], kept within [low]...[high], as the Swift steps clamp a picture's shape.
double studyAspect(BooruPost post, {required double low, required double high}) {
  final width = post.width < 1 ? 1 : post.width;
  final height = post.height < 1 ? 1 : post.height;
  return (width / height).clamp(low, high).toDouble();
}

/// Opens a lesson's picture in the image viewer (Swift's `studyOpenPicture` environment value). `StudyPlayView`
/// puts one above its steps; with none, a picture does not open.
class StudyPictureOpener extends InheritedWidget {
  const StudyPictureOpener({super.key, required this.open, required super.child});

  /// Opens [post], with [among] beside it to page through.
  final void Function(BooruPost post, List<BooruPost> among) open;

  /// The nearest opener, if any.
  static StudyPictureOpener? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<StudyPictureOpener>();

  @override
  bool updateShouldNotify(StudyPictureOpener old) => old.open != open;
}

/// Makes a lesson's picture open in the image viewer (`StudyZoom`): by a tap anywhere on it, or, where a tap
/// already chooses the picture as an answer ([cornerOnly]), by the small button in its corner.
class StudyZoom extends StatelessWidget {
  const StudyZoom({super.key, required this.post, this.among = const [], this.cornerOnly = false, required this.child});

  /// The picture opened.
  final BooruPost post;

  /// The pictures beside it, to page through.
  final List<BooruPost> among;

  /// Only the corner button opens it.
  final bool cornerOnly;

  /// The picture.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    void open() => StudyPictureOpener.maybeOf(context)?.open(post, among);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (cornerOnly) child else GestureDetector(behavior: HitTestBehavior.opaque, onTap: open, child: child),
        Positioned(
          top: 0,
          right: 0,
          child: Semantics(
            button: true,
            label: L10n.text('Open in the Viewer'),
            child: GestureDetector(
              key: const Key('study.zoom'),
              behavior: HitTestBehavior.opaque,
              onTap: open,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Container(
                  padding: const EdgeInsets.all(7),
                  decoration: const ShapeDecoration(color: Color(0x80000000), shape: CircleBorder()),
                  child: const ExcludeSemantics(child: StudyIcon('arrow.up.left.and.arrow.down.right', size: 11, color: Color(0xFFFFFFFF))),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A step's scrolling body with its button pinned below (`StudyStepFrame`). [button] is the English L10n key.
class StudyStepFrame extends StatelessWidget {
  const StudyStepFrame({super.key, required this.button, this.enabled = true, this.hidden = false, required this.onPressed, required this.children});

  /// The button's title, as an English L10n key.
  final String button;

  /// Whether the button can be pressed.
  final bool enabled;

  /// Hides the button, once an answer is in.
  final bool hidden;

  /// Called when the button is pressed.
  final VoidCallback onPressed;

  /// The step's content, 18 points apart.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Column(
      children: [
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeBottom: !hidden,
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.only(bottom: hidden ? bottom : 0),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 18, right: 18, top: 8, bottom: 20),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 18, children: children),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (!hidden)
          ColoredBox(
            color: theme.background,
            child: Padding(
              padding: EdgeInsets.only(left: 18, right: 18, top: 10, bottom: 10 + bottom),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: StudyMainButton(key: const Key('study.check'), title: L10n.text(button), onPressed: enabled ? onPressed : null),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// How an answer looks: not chosen, chosen, and after the check right, wrong or passed over (`StudyChoiceState`).
enum StudyChoiceState { idle, picked, right, wrong, faded }

/// The look of choice [index] (`choiceState`).
StudyChoiceState studyChoiceState(int index, {required int? picked, required int answer, required bool revealed}) {
  if (revealed) return index == answer ? StudyChoiceState.right : (index == picked ? StudyChoiceState.wrong : StudyChoiceState.faded);
  return index == picked ? StudyChoiceState.picked : StudyChoiceState.idle;
}

/// An answer that can be picked, and that shows afterwards whether it was right (`StudyChoiceStyle`). A picked
/// answer leans forward, the right one jumps and a wrong one shakes its head. [onPressed] of null ignores taps
/// without greying the answer out, as `allowsHitTesting(false)` does.
class StudyChoiceButton extends StatefulWidget {
  const StudyChoiceButton({super.key, required this.state, required this.onPressed, required this.child});

  final StudyChoiceState state;
  final VoidCallback? onPressed;
  final Widget child;

  @override
  State<StudyChoiceButton> createState() => _StudyChoiceButtonState();
}

class _StudyChoiceButtonState extends State<StudyChoiceButton> {
  static final _spring = StudySpring(0.35, 0.6);
  bool _down = false;

  void _set(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  void didUpdateWidget(StudyChoiceButton old) {
    super.didUpdateWidget(old);
    if (widget.onPressed == null) _down = false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final state = widget.state;
    final plain = state == StudyChoiceState.idle || state == StudyChoiceState.faded;
    final color = switch (state) {
      StudyChoiceState.picked => theme.primary,
      StudyChoiceState.right => theme.good,
      StudyChoiceState.wrong => theme.bad,
      _ => theme.line,
    };
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final ink = plain ? theme.ink : (dark ? color : studyEdge(color));
    final reduce = MediaQuery.disableAnimationsOf(context);
    final down = _down && widget.onPressed != null;
    final scale = switch (state) {
      StudyChoiceState.picked => 1.03,
      StudyChoiceState.right => 1.05,
      _ => 1.0,
    };
    final enabled = widget.onPressed != null;
    return Semantics(
      button: true,
      selected: state == StudyChoiceState.picked,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _set(true) : null,
        onTapUp: enabled ? (_) => _set(false) : null,
        onTapCancel: enabled ? () => _set(false) : null,
        onTap: widget.onPressed,
        child: StudyShake(
          travel: state == StudyChoiceState.wrong ? 1 : 0,
          duration: _spring.settle,
          child: AnimatedScale(
            scale: scale,
            duration: reduce ? Duration.zero : _spring.settle,
            curve: _spring,
            child: AnimatedOpacity(
              opacity: state == StudyChoiceState.faded ? 0.5 : 1,
              duration: reduce ? Duration.zero : const Duration(milliseconds: 350),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // The edge the face sinks onto.
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 4,
                      bottom: -4,
                      child: DecoratedBox(
                        decoration: ShapeDecoration(color: color, shape: studyRounded(16)),
                      ),
                    ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 80),
                      curve: Curves.easeOut,
                      transform: Matrix4.translationValues(0, down ? 4 : 0, 0),
                      decoration: ShapeDecoration(color: theme.surface, shape: studyRounded(16)),
                      foregroundDecoration: ShapeDecoration(shape: studyRounded(16, BorderSide(color: color, width: 2))),
                      child: DecoratedBox(
                        decoration: ShapeDecoration(color: plain ? const Color(0x00000000) : color.withValues(alpha: 0.14), shape: studyRounded(16)),
                        child: DefaultTextStyle.merge(
                          style: TextStyle(color: ink),
                          child: IconTheme.merge(
                            data: IconThemeData(color: ink),
                            child: widget.child,
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
}

/// A lesson's picture (`StudyPicture` as learning mode draws it). It is drawn over a box of the size it is given,
/// so that a wide or tall picture never pushes the layout out. Where the box must be filled ([fills]), the whole
/// picture is still shown, over a blurred copy of itself that fills the rest.
class StudyLessonPicture extends StatefulWidget {
  const StudyLessonPicture({super.key, required this.booru, required this.post, required this.server, this.fills = false});

  final BooruContext booru;
  final BooruPost post;
  final BooruServer server;
  final bool fills;

  @override
  State<StudyLessonPicture> createState() => _StudyLessonPictureState();
}

class _StudyLessonPictureState extends State<StudyLessonPicture> {
  Uint8List? _image;
  bool _failed = false;
  int _generation = 0;

  String? get _url => widget.post.reducedDataURL ?? widget.post.sampleURL ?? widget.post.previewURL;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(StudyLessonPicture old) {
    super.didUpdateWidget(old);
    if (old.post.id != widget.post.id) {
      _image = null;
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _failed = false;
    if (widget.booru.fixture) return;
    final url = _url;
    if (url == null) {
      _failed = true;
      return;
    }
    final cached = widget.booru.thumbnails.cached(url, widget.server);
    if (cached != null) {
      _image = cached;
      return;
    }
    try {
      final data = await widget.booru.thumbnails.load(url, widget.server);
      if (mounted && generation == _generation) setState(() => _image = data);
    } on Object {
      if (mounted && generation == _generation) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final List<Widget> layers;
    if (image != null) {
      Widget picture(BoxFit fit) => Image.memory(image, fit: fit, gaplessPlayback: true, errorBuilder: (context, _, _) => _failure(context));
      layers = [
        if (widget.fills)
          Positioned.fill(
            child: Opacity(
              opacity: 0.75,
              child: ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18), child: picture(BoxFit.cover)),
            ),
          ),
        Positioned.fill(child: picture(BoxFit.contain)),
      ];
    } else if (widget.booru.fixture) {
      layers = [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [SystemColors.indigo.resolveFrom(context), SystemColors.cyan.resolveFrom(context).withValues(alpha: 0.6)],
              ),
            ),
          ),
        ),
        Center(child: Icon(StudySymbols.picture, size: 44, color: const Color(0xFFFFFFFF).withValues(alpha: 0.8))),
      ];
    } else if (_failed) {
      layers = [Center(child: _failure(context))];
    } else {
      layers = [const Center(child: CupertinoActivityIndicator())];
    }
    return ClipRect(
      child: ColoredBox(
        color: StudyStyle.tertiaryFill.resolveFrom(context),
        child: SizedBox.expand(
          child: Stack(fit: StackFit.expand, children: layers),
        ),
      ),
    );
  }

  Widget _failure(BuildContext context) =>
      Center(child: Icon(CupertinoIcons.exclamationmark_triangle, color: TegnalColors.secondaryLabel.resolveFrom(context)));
}

/// A picture of the shape [aspect] as large as fits [maxHeight] and the width offered, centred on its line, as
/// SwiftUI's `.aspectRatio(aspect, contentMode: .fit).frame(maxWidth: .infinity).frame(maxHeight:)` places it.
class StudyFittedBox extends StatelessWidget {
  const StudyFittedBox({super.key, required this.aspect, required this.maxHeight, required this.child});

  final double aspect;
  final double maxHeight;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth.isFinite ? constraints.maxWidth : maxHeight * aspect;
      final fitted = width < maxHeight * aspect ? width : maxHeight * aspect;
      return Center(
        child: SizedBox(width: fitted, height: fitted / aspect, child: child),
      );
    },
  );
}

/// Text that shrinks down to [minScale] before it is cut off, as SwiftUI's `minimumScaleFactor` does.
class StudyShrinkingText extends StatelessWidget {
  const StudyShrinkingText(this.text, {super.key, required this.style, this.maxLines = 2, this.minScale = 0.75, this.textAlign = TextAlign.center});

  final String text;
  final TextStyle style;
  final int maxLines;
  final double minScale;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scaler = MediaQuery.textScalerOf(context);
      final direction = Directionality.of(context);
      var scale = 1.0;
      if (constraints.maxWidth.isFinite) {
        while (scale > minScale) {
          final painter = TextPainter(
            text: TextSpan(
              text: text,
              style: style.copyWith(fontSize: (style.fontSize ?? 17) * scale),
            ),
            maxLines: maxLines,
            textDirection: direction,
            textScaler: scaler,
          )..layout(maxWidth: constraints.maxWidth);
          final fits = !painter.didExceedMaxLines;
          painter.dispose();
          if (fits) break;
          scale = (scale - 0.05).clamp(minScale, 1.0);
        }
      }
      return Text(
        text,
        style: style.copyWith(fontSize: (style.fontSize ?? 17) * scale),
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        textAlign: textAlign,
      );
    },
  );
}
