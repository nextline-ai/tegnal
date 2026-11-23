import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../../core/lab/lab_course.dart';
import '../../core/support/l10n.dart';
import '../design/glass.dart';
import '../design/tegnal_theme.dart';

// The AI lab's own look: cards, paper, gauges and the engraving. Everything else is the app's stock look.
// Ported from `LabKit.swift`.

/// The lab's few colours. Material rule: deep solid colour is what no longer changes (an engraved card); paper is what
/// still changes (a blank card, the cheat sheet).
abstract final class LabPalette {
  static const paper = Color(0xFFECE9E2);
  static const paperInk = Color(0xFF1D1D1F);
  static const paperMuted = Color(0xFF5C5A55);
  static const paperRule = Color(0xFF8A867D);

  /// Measured values: the rate and every gauge.
  static const gauge = CupertinoDynamicColor.withBrightness(color: Color(0xFFA86400), darkColor: Color(0xFFFFB02E));

  /// A tool passed.
  static const pass = CupertinoDynamicColor.withBrightness(color: Color(0xFF1E8A50), darkColor: Color(0xFF5BE49B));

  /// A 망작.
  static const fail = CupertinoDynamicColor.withBrightness(color: Color(0xFFD0432A), darkColor: Color(0xFFFF6B4A));

  /// 먹, the system sheet's sixth card colour, kept for card No. 000.
  static const ink = '3A3A3C';

  /// The main button: near-white in dark appearance, ink in light.
  static const primary = CupertinoDynamicColor.withBrightness(color: Color(0xFF1D1D1F), darkColor: Color(0xFFF5F5F7));
  static const onPrimary = CupertinoDynamicColor.withBrightness(color: Color(0xFFFFFFFF), darkColor: Color(0xFF000000));

  /// Text on a signal colour.
  static const onSignal = CupertinoDynamicColor.withBrightness(color: Color(0xFFFFFFFF), darkColor: Color(0xFF000000));

  /// A grey surface, a little lighter for each step back in a stack.
  static Color surface(BuildContext context, [int step = 0]) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final level = dark ? 0.110 + step * 0.025 : 0.949 - step * 0.02;
    final value = (level.clamp(0, 1) * 255).round();
    return Color.fromARGB(255, value, value, value);
  }

  static Color hex(String hex) => Color(0xFF000000 | ((int.tryParse(hex, radix: 16) ?? 0x3A3A3C) & 0xFFFFFF));

  /// The light ink printed on a card of this colour: the colour mixed far towards white.
  static Color tint(String hex) {
    final value = int.tryParse(hex, radix: 16) ?? 0x3A3A3C;
    int mix(int channel) => ((channel / 255 * 0.3 + 0.7) * 255).round();
    return Color.fromARGB(255, mix((value >> 16) & 0xFF), mix((value >> 8) & 0xFF), mix(value & 0xFF));
  }
}

/// Three voices: serif for the content (titles, verdicts, the engraved line), the app's font for everything else,
/// monospaced for numbers. Every line sits 130% of its font size below the one before.
abstract final class LabFont {
  static const lines = 1.3;

  /// The content voice at its heaviest: titles and verdicts. The app's own sans-serif, like the rest of learning mode
  /// (user, 2026-11-24: the serif is kept only for viewing mode).
  static TextStyle voice(double size, {Color? color, double tracking = -0.3}) =>
      TegnalType.style(size, weight: FontWeight.w700, color: color, height: lines).copyWith(letterSpacing: tracking);

  /// The content voice, lighter: a line on a small card.
  static TextStyle line(double size, {Color? color}) =>
      TegnalType.style(size, weight: FontWeight.w600, color: color, height: lines).copyWith(letterSpacing: -0.2);

  /// The app's voice, at 130%.
  static TextStyle text(double size, {FontWeight weight = FontWeight.w400, Color? color, double? tracking}) {
    final style = TegnalType.style(size, weight: weight, color: color, height: lines);
    return tracking == null ? style : style.copyWith(letterSpacing: tracking);
  }

  /// The measuring voice.
  static TextStyle number(double size, {FontWeight weight = FontWeight.w700, Color? color, double tracking = 0}) => TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: const [TegnalType.family, ...TegnalType.fallback],
    fontSize: size,
    fontWeight: weight,
    height: lines,
    letterSpacing: tracking,
    color: color,
    fontFeatures: const [FontFeature.tabularFigures()],
  );
}

/// iOS wraps Korean between words, never inside one; the lab's content text goes through this before it is shown.
String labWords(String text) => L10n.language == 'ko' ? L10n.keepingWords(text) : text;

Color labLabel(BuildContext context) => TegnalColors.label.resolveFrom(context);
Color labSecondary(BuildContext context) => TegnalColors.secondaryLabel.resolveFrom(context);

// MARK: - Headers

/// The top of each lab tab: a quiet line above a large title, and something on the right.
class LabHeader extends StatelessWidget {
  const LabHeader({super.key, required this.kicker, required this.title, this.trailing, this.below = true});
  final InlineSpan kicker;
  final String title;
  final Widget? trailing;

  /// The quiet line goes under the title instead of over it.
  final bool below;

  @override
  Widget build(BuildContext context) {
    final line = Text.rich(
      kicker,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: LabFont.text(13, weight: FontWeight.w600, color: labSecondary(context)),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!below) ...[line, const SizedBox(height: 2)],
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: LabFont.text(34, weight: FontWeight.w800, color: labLabel(context), tracking: -0.5),
                  ),
                ),
                if (below) ...[const SizedBox(height: 2), line],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ],
      ),
    );
  }
}

// MARK: - The card

enum LabCardState { blank, earned, locked }

/// A card of the deck in one of its three states.
class LabCardFace extends StatelessWidget {
  const LabCardFace({
    super.key,
    required this.serial,
    required this.title,
    this.line,
    this.color = LabPalette.ink,
    required this.state,
    this.label,
    this.footer,
    this.date,
    this.engraved,
    this.large = false,
    this.top = false,
  });

  final String serial;
  final String title;
  final String? line;

  /// The card's colour, six hexadecimal digits.
  final String color;
  final LabCardState state;

  /// A short label at the top right, such as the card's name.
  final String? label;
  final String? footer;
  final String? date;

  /// How many letters of the line are pressed in so far, while it is being engraved. Null shows the whole line.
  final double? engraved;
  final bool large;

  /// Content at the top, as for a card peeking out of the stack.
  final bool top;

  @override
  Widget build(BuildContext context) {
    final tint = LabPalette.tint(color);
    final ink = switch (state) {
      LabCardState.earned => const Color(0xFFFFFFFF),
      LabCardState.locked => labSecondary(context),
      LabCardState.blank => LabPalette.paperInk,
    };
    final muted = switch (state) {
      LabCardState.earned => tint,
      LabCardState.locked => labSecondary(context),
      LabCardState.blank => LabPalette.paperMuted,
    };
    final small = LabFont.text(11, weight: FontWeight.w700, color: muted, tracking: 1.6);
    final body = <Widget>[
      Row(
        children: [
          Expanded(child: Text(state == LabCardState.earned && large ? 'AI LAB' : serial, maxLines: 1, style: small)),
          if (state == LabCardState.earned && large) Text(serial, style: small) else if (label != null) Text(label!, style: small.copyWith(letterSpacing: 1.4)),
          if (state == LabCardState.locked)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Icon(CupertinoIcons.lock_fill, size: 11, color: muted),
            ),
        ],
      ),
      SizedBox(height: large ? 14 : 6),
      if (!top) const Spacer(),
      if (state == LabCardState.earned && line != null) ...[
        if (large) ...[Container(width: 28, height: 2, color: tint), const SizedBox(height: 16)],
        LabEngravedText(
          text: labWords(line!),
          revealed: engraved,
          style: large ? LabFont.voice(28, color: ink) : LabFont.line(16, color: ink),
        ),
      ] else ...[
        Text(
          labWords(title),
          maxLines: state == LabCardState.locked && top
              ? 1
              : large
              ? 4
              : 3,
          overflow: TextOverflow.ellipsis,
          style: state == LabCardState.locked && top ? LabFont.text(13, weight: FontWeight.w600, color: ink) : LabFont.voice(large ? 26 : 14, color: ink),
        ),
        if (state == LabCardState.blank) ...[const SizedBox(height: 8), const LabDashedRule(color: LabPalette.paperRule)],
      ],
      if (top) const Spacer(),
      if (footer != null) ...[
        SizedBox(height: large ? 14 : 6),
        Row(
          children: [
            Expanded(
              child: Text(
                footer!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: LabFont.text(11, weight: FontWeight.w600, color: muted, tracking: 0.6),
              ),
            ),
            if (date != null)
              Text(
                date!,
                style: LabFont.number(11, weight: FontWeight.w500, color: muted),
              ),
          ],
        ),
      ],
    ];
    return LabCardBackground(
      state: state,
      color: color,
      radius: large ? 24 : 20,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: large ? 24 : 20, vertical: large ? 22 : 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: body),
      ),
    );
  }
}

/// A card's surface: flat deep colour with a hairline of light along the top edge, grey when locked, paper when blank.
class LabCardBackground extends StatelessWidget {
  const LabCardBackground({super.key, required this.state, this.color = LabPalette.ink, this.radius = 20, this.step = 0, this.shadow, required this.child});
  final LabCardState state;
  final String color;
  final double radius;
  final int step;

  /// Cast by the card's outline only, never by what is printed on it.
  final List<BoxShadow>? shadow;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(radius),
      side: switch (state) {
        LabCardState.blank => const BorderSide(color: Color(0x0D000000), width: 0.5),
        _ => BorderSide.none,
      },
    );
    final fill = switch (state) {
      LabCardState.earned => LabPalette.hex(color),
      LabCardState.locked => LabPalette.surface(context, step),
      LabCardState.blank => LabPalette.paper,
    };
    return DecoratedBox(
      decoration: ShapeDecoration(color: fill, shape: shape, shadows: shadow),
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(radius),
        child: state == LabCardState.earned ? CustomPaint(foregroundPainter: _Hairline(radius), child: child) : child,
      ),
    );
  }
}

class _Hairline extends CustomPainter {
  _Hairline(this.radius);
  final double radius;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.center, colors: [Color(0x38FFFFFF), Color(0x00FFFFFF)]).createShader(rect);
    canvas.drawRSuperellipse(RSuperellipse.fromRectAndRadius(rect.deflate(0.5), Radius.circular(radius)), paint);
  }

  @override
  bool shouldRepaint(_Hairline old) => old.radius != radius;
}

/// The engraved line, pressed in one letter at a time while [revealed] climbs: each letter fades in from nothing.
class LabEngravedText extends StatelessWidget {
  const LabEngravedText({super.key, required this.text, this.revealed, required this.style});
  final String text;
  final double? revealed;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final revealed = this.revealed;
    if (revealed == null) return Text(text, style: style);
    final color = style.color ?? labLabel(context);
    var index = 0;
    return Text.rich(
      TextSpan(
        children: [
          for (final glyph in text.characters)
            TextSpan(
              text: glyph,
              // The word joiners that keep Korean words whole take no turn of their own.
              style: TextStyle(color: color.withValues(alpha: color.a * ((revealed - (glyph == '\u2060' ? index : index++)) * 1.6).clamp(0.0, 1.0))),
            ),
        ],
      ),
      style: style,
      semanticsLabel: text,
    );
  }
}

/// Turns over in one unbroken movement: the front shows until it is edge-on, then the back, the right way round.
class LabFlip extends StatelessWidget {
  const LabFlip({super.key, required this.angle, required this.front, required this.back});

  /// Degrees, 0 to 180.
  final double angle;
  final Widget front;
  final Widget back;

  @override
  Widget build(BuildContext context) {
    final radians = angle * math.pi / 180;
    final showsBack = angle >= 90;
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0014)
        ..rotateY(radians),
      child: showsBack ? Transform(alignment: Alignment.center, transform: Matrix4.rotationY(math.pi), child: back) : front,
    );
  }
}

/// A band of light that crosses a card once, as when it catches the light. Taller than the card, so the slanted band
/// still covers it from top to bottom; it starts and ends wholly off the card.
class LabSheen extends StatelessWidget {
  const LabSheen({super.key, required this.progress});
  final double progress;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth, height = constraints.maxHeight;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: -width * 0.7 + width * 2.4 * progress - width * 0.25,
              top: -height * 0.4,
              width: width * 0.5,
              height: height * 1.8,
              child: Transform.rotate(
                angle: 18 * math.pi / 180,
                child: const DecoratedBox(
                  decoration: BoxDecoration(gradient: LinearGradient(colors: [Color(0x00FFFFFF), Color(0x47FFFFFF), Color(0x00FFFFFF)])),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// The dotted line on a blank card where its sentence will be engraved.
class LabDashedRule extends StatelessWidget {
  const LabDashedRule({super.key, required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 1,
    width: double.infinity,
    child: CustomPaint(painter: _Dashes(color)),
  );
}

class _Dashes extends CustomPainter {
  _Dashes(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, size.height / 2), Offset(math.min(x + 4, size.width), size.height / 2), paint);
    }
  }

  @override
  bool shouldRepaint(_Dashes old) => old.color != color;
}

/// A card under a finger sinks a little and comes back.
class LabPress extends StatefulWidget {
  const LabPress({super.key, required this.child, required this.onTap, this.label});
  final Widget child;
  final VoidCallback? onTap;
  final String? label;

  @override
  State<LabPress> createState() => _LabPressState();
}

class _LabPressState extends State<LabPress> {
  bool _down = false;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: widget.label,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.975 : 1,
        duration: const Duration(milliseconds: 260),
        curve: _down ? Curves.easeOut : Curves.elasticOut,
        child: widget.child,
      ),
    ),
  );
}

// MARK: - Gauges

/// The rate as a dial: three quarters of a ring, the number in the middle.
class LabRing extends StatelessWidget {
  const LabRing({super.key, required this.value, this.size = 64});
  final int value;
  final double size;

  @override
  Widget build(BuildContext context) {
    final gauge = LabPalette.gauge.resolveFrom(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value.toDouble()),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (context, shown, _) => SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _Ring(shown.clamp(0, 100) / 100, LabPalette.surface(context, 1), gauge, size * 0.078),
          child: Center(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${shown.round()}',
                    style: LabFont.number(size * 0.25, color: gauge, tracking: -0.6),
                  ),
                  TextSpan(
                    text: '%',
                    style: LabFont.number(size * 0.155, color: gauge),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Ring extends CustomPainter {
  _Ring(this.fraction, this.track, this.fill, this.width);
  final double fraction;
  final Color track;
  final Color fill;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(width / 2);
    Paint stroke(Color color) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = width;
    const start = 135 * math.pi / 180, sweep = 270 * math.pi / 180;
    canvas.drawArc(rect, start, sweep, false, stroke(track));
    if (fraction > 0) canvas.drawArc(rect, start, sweep * fraction, false, stroke(fill));
  }

  @override
  bool shouldRepaint(_Ring old) => old.fraction != fraction || old.fill != fill || old.track != track;
}

enum LabTone { measure, pass, fail }

Color labToneColor(BuildContext context, LabTone tone) => switch (tone) {
  LabTone.measure => LabPalette.gauge.resolveFrom(context),
  LabTone.pass => LabPalette.pass.resolveFrom(context),
  LabTone.fail => LabPalette.fail.resolveFrom(context),
};

/// A gauge bar for a tool's measure, 0 to 100. Amber while it climbs, green when passed, red when it went wrong.
class LabMeter extends StatelessWidget {
  const LabMeter({super.key, required this.label, required this.value, this.tone = LabTone.measure});
  final String label;
  final int value;
  final LabTone tone;

  @override
  Widget build(BuildContext context) {
    final color = labToneColor(context, tone);
    return Semantics(
      label: label,
      value: '$value',
      child: ExcludeSemantics(
        child: Row(
          children: [
            Text(label, maxLines: 1, style: LabFont.number(11, color: labSecondary(context), tracking: 1)),
            const SizedBox(width: 12),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => Stack(
                  children: [
                    Container(
                      height: 8,
                      decoration: ShapeDecoration(color: LabPalette.surface(context, 1), shape: const StadiumBorder()),
                    ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 450),
                      curve: Curves.easeOutBack,
                      height: 8,
                      width: constraints.maxWidth * value.clamp(0, 100) / 100,
                      decoration: ShapeDecoration(color: color, shape: const StadiumBorder()),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 38,
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: value.toDouble()),
                duration: const Duration(milliseconds: 450),
                builder: (context, shown, _) => Text(
                  '${shown.round()}',
                  textAlign: TextAlign.right,
                  style: LabFont.number(15, color: color),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A quiet tag: "망작 No. 07 · 전시됨", "통과", a date.
class LabTag extends StatelessWidget {
  const LabTag({super.key, required this.text, required this.color, this.ink, this.mono = false});
  final String text;
  final Color color;
  final Color? ink;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final ink = this.ink ?? LabPalette.onSignal.resolveFrom(context);
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: ShapeDecoration(color: color, shape: const StadiumBorder()),
      child: Center(
        widthFactor: 1,
        child: Text(
          text,
          style: mono ? LabFont.number(11, color: ink) : LabFont.text(12, weight: FontWeight.w700, color: ink),
        ),
      ),
    );
  }
}

// MARK: - Chat

/// A fake chat line: the learner on the right, the AI on the left.
class LabBubble extends StatelessWidget {
  const LabBubble({super.key, required this.text, this.mine = false, this.tint});
  final String text;
  final bool mine;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final label = labLabel(context);
    final background = TegnalColors.background.resolveFrom(context);
    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
      decoration: BoxDecoration(
        color: mine ? label : (tint == null ? LabPalette.surface(context) : Color.alphaBlend(tint!, LabPalette.surface(context))),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(20),
          topRight: const Radius.circular(20),
          bottomLeft: Radius.circular(mine ? 20 : 6),
          bottomRight: Radius.circular(mine ? 6 : 20),
        ),
      ),
      child: Text(L10n.language == 'ko' ? L10n.keepingWords(text) : text, style: LabFont.text(15, color: mine ? background : label)),
    );
    return Row(
      children: [
        if (mine) const SizedBox(width: 48),
        Flexible(
          child: Align(alignment: mine ? Alignment.centerRight : Alignment.centerLeft, child: bubble),
        ),
        if (!mine) const SizedBox(width: 32),
      ],
    );
  }
}

/// The fake prompt box of an AI app: what the learner asked, with what has been attached under it.
class LabPromptBox extends StatelessWidget {
  const LabPromptBox({super.key, required this.text, this.footer = const []});
  final String text;
  final List<Widget> footer;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: ShapeDecoration(
      color: LabPalette.surface(context),
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(18)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: LabFont.text(15, color: labLabel(context))),
        for (final widget in footer) ...[const SizedBox(height: 10), widget],
      ],
    ),
  );
}

// MARK: - Buttons

enum LabButtonStyle { primary, secondary }

/// The main action (ink on paper-white in dark appearance, white on ink in light) or a secondary one on glass.
class LabButton extends StatefulWidget {
  const LabButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.style = LabButtonStyle.secondary,
    this.radius = 18,
    this.expand = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
    this.label,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final LabButtonStyle style;

  /// Null makes a capsule.
  final double? radius;
  final bool expand;
  final EdgeInsets padding;
  final String? label;

  @override
  State<LabButton> createState() => _LabButtonState();
}

class _LabButtonState extends State<LabButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final primary = widget.style == LabButtonStyle.primary;
    final foreground = primary ? LabPalette.onPrimary.resolveFrom(context) : labLabel(context);
    final ShapeBorder shape = widget.radius == null ? const StadiumBorder() : RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(widget.radius!));
    final content = Padding(
      padding: widget.padding,
      child: DefaultTextStyle(
        style: LabFont.text(17, weight: FontWeight.w600, color: foreground),
        textAlign: TextAlign.center,
        child: IconTheme(
          data: IconThemeData(color: foreground, size: 17),
          child: widget.expand ? Center(child: widget.child) : widget.child,
        ),
      ),
    );
    final surface = primary
        ? DecoratedBox(
            decoration: ShapeDecoration(color: LabPalette.primary.resolveFrom(context), shape: shape),
            child: content,
          )
        : Glass(shape: shape, child: content);
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapUp: enabled ? (_) => setState(() => _down = false) : null,
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onPressed,
        child: AnimatedOpacity(
          opacity: enabled ? 1 : 0.4,
          duration: const Duration(milliseconds: 150),
          child: AnimatedScale(scale: _down ? 0.96 : 1, duration: const Duration(milliseconds: 160), curve: Curves.easeOut, child: surface),
        ),
      ),
    );
  }
}

/// Copies a text to the clipboard and says so for a moment.
class LabCopyButton extends StatefulWidget {
  const LabCopyButton({super.key, required this.text, this.color});
  final String text;
  final Color? color;

  @override
  State<LabCopyButton> createState() => _LabCopyButtonState();
}

class _LabCopyButtonState extends State<LabCopyButton> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? TegnalColors.tint.resolveFrom(context);
    return Semantics(
      button: true,
      child: GestureDetector(
        key: const Key('lab.copy'),
        behavior: HitTestBehavior.opaque,
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: widget.text));
          LabHaptic.pass();
          if (!mounted) return;
          setState(() => _copied = true);
          await Future<void>.delayed(const Duration(milliseconds: 1500));
          if (mounted) setState(() => _copied = false);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Icon(_copied ? CupertinoIcons.checkmark_alt : CupertinoIcons.doc_on_doc, key: ValueKey(_copied), size: 17, color: color),
              ),
              const SizedBox(width: 6),
              Text(
                L10n.text(_copied ? 'lab.copied' : 'lab.copy'),
                style: LabFont.text(15, weight: FontWeight.w600, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A short tap felt under the finger, for each change a tool makes.
abstract final class LabHaptic {
  static void tick() => HapticFeedback.selectionClick();

  /// One letter pressed into a card.
  static void press() => HapticFeedback.lightImpact();
  static void snap() => HapticFeedback.mediumImpact();
  static void pass() => HapticFeedback.mediumImpact();
  static void miss() => HapticFeedback.heavyImpact();
}

extension LabEpisodeLook on LabCourse {
  /// The season line of a card's footer: "뇌 스위치 · 시즌 1".
  String footer(LabEpisode episode) {
    final season = seasonOf(episode);
    return [
      episode.label,
      if (season != null) L10n.text('lab.season', ['${season.number}']),
    ].join(' · ');
  }
}

/// `2026.11.23`, from seconds since 1970.
String labStamp(double seconds) {
  final date = DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
  String two(int value) => value.toString().padLeft(2, '0');
  return '${date.year}.${two(date.month)}.${two(date.day)}';
}

/// "세 번째", "3rd", "3番目" for the engraving's title.
String labOrdinal(int number, {String? language}) {
  switch (language ?? L10n.language) {
    case 'ko':
      const words = ['첫', '두', '세', '네', '다섯', '여섯', '일곱', '여덟', '아홉', '열', '열한', '열두', '열세', '열네', '열다섯', '열여섯', '열일곱', '열여덟', '열아홉', '스무'];
      return '${number >= 1 && number <= words.length ? words[number - 1] : '$number'} 번째';
    case 'ja':
      return '$number番目';
    default:
      final suffix = (number % 100 >= 11 && number % 100 <= 13) ? 'th' : const {1: 'st', 2: 'nd', 3: 'rd'}[number % 10] ?? 'th';
      return '$number$suffix';
  }
}

// MARK: - A wrong answer

/// Gives the tools inside an episode a way to wash the whole screen red for a moment after a wrong answer
/// (`EnvironmentValues.labMistake`).
class LabMistake extends InheritedWidget {
  const LabMistake({super.key, required this.signal, required super.child});
  final VoidCallback signal;

  /// Washes the episode red, where there is one above [context].
  static void of(BuildContext context) => context.getInheritedWidgetOfExactType<LabMistake>()?.signal();

  @override
  bool updateShouldNotify(LabMistake oldWidget) => false;
}

/// The red wash over the whole screen after a wrong answer: in fast, out slowly. Lets touches through.
class LabMistakeWash extends StatefulWidget {
  const LabMistakeWash({super.key, required this.count});

  /// Bumped once per wrong answer.
  final int count;

  @override
  State<LabMistakeWash> createState() => _LabMistakeWashState();
}

class _LabMistakeWashState extends State<LabMistakeWash> with SingleTickerProviderStateMixin {
  late final AnimationController _wash = AnimationController(vsync: this, duration: const Duration(milliseconds: 750));
  static final _curve = TweenSequence<double>([
    TweenSequenceItem(tween: Tween<double>(begin: 0, end: 1).chain(CurveTween(curve: Curves.easeOut)), weight: 12),
    TweenSequenceItem(tween: ConstantTween<double>(1), weight: 12),
    TweenSequenceItem(tween: Tween<double>(begin: 1, end: 0).chain(CurveTween(curve: Curves.easeIn)), weight: 76),
  ]);

  @override
  void didUpdateWidget(LabMistakeWash oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.count != oldWidget.count) _wash.forward(from: 0);
  }

  @override
  void dispose() {
    _wash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final red = LabPalette.fail.resolveFrom(context);
    return IgnorePointer(
      child: ExcludeSemantics(
        child: AnimatedBuilder(
          animation: _wash,
          builder: (context, _) => ColoredBox(color: red.withValues(alpha: 0.22 * _curve.evaluate(_wash))),
        ),
      ),
    );
  }
}
