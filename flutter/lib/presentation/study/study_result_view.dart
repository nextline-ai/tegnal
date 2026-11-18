import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';

import '../../core/study/study_models.dart';
import '../../core/study/study_session.dart';
import '../../core/study/study_store.dart';
import '../../core/support/l10n.dart';
import '../design/grouped_form.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import '../library/folders_view.dart' show ContentUnavailable;
import '../navigation/app_header.dart';
import 'study_widgets.dart';

/// `StudyGrade`: how a round went, which decides how much the results screen celebrates.
enum StudyGrade {
  perfect,
  great,
  practice;

  /// All right is perfect, seven in ten or more is great, anything else is practice.
  factory StudyGrade.of({required int right, required int total}) => total > 0 && right == total
      ? perfect
      : total > 0 && right / total >= 0.7
      ? great
      : practice;

  /// The English wording; pass it through `L10n.text`.
  String get title => switch (this) {
    perfect => 'Perfect Round!',
    great => 'Well Done!',
    practice => 'Keep Going!',
  };

  /// `trophy.fill`, `star.fill` and `figure.walk` on iOS.
  IconData get symbol => switch (this) {
    perfect => CupertinoIcons.rosette,
    great => CupertinoIcons.star_fill,
    practice => CupertinoIcons.arrow_up_right_circle_fill,
  };

  /// How many pieces of confetti fall once after the round.
  int get confetti => switch (this) {
    perfect => 120,
    great => 70,
    practice => 30,
  };

  List<Color> colors(BuildContext context) {
    Color color(CupertinoDynamicColor value) => value.resolveFrom(context);
    return switch (this) {
      perfect => [color(SystemColors.yellow), color(SystemColors.orange), color(SystemColors.pink)],
      great => [color(SystemColors.indigo), color(SystemColors.purple), color(SystemColors.teal)],
      practice => [color(SystemColors.indigo), color(SystemColors.blue)],
    };
  }
}

/// `StudyResultView`: the end of a round: the score, what the round changed, and the answers to look back at.
class StudyResultView extends StatefulWidget {
  const StudyResultView({
    super.key,
    required this.session,
    required this.before,
    required this.after,
    required this.onOpen,
    required this.onAgain,
    required this.onDone,
  });
  final StudySession session;

  /// How things stood when the round began, and how they stand now.
  final StudySummary before;
  final StudySummary after;
  final ValueChanged<StudyTag> onOpen;
  final VoidCallback onAgain;
  final VoidCallback onDone;

  @override
  State<StudyResultView> createState() => _StudyResultViewState();
}

class _StudyResultViewState extends State<StudyResultView> with SingleTickerProviderStateMixin {
  // The spring of `.spring(duration: 0.9, bounce: 0.25).delay(0.15)`.
  static const _delay = 0.15;
  static const _duration = 0.9;
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1050));
  bool _started = false;
  bool _reduceMotion = false;

  int get _total => widget.session.results.length;
  int get _right => widget.session.rightCount;
  StudyGrade get _grade => StudyGrade.of(right: _right, total: _total);
  int get _gained => math.max(0, widget.after.learned - widget.before.learned);

  /// 0 before the round's numbers come in, 1 once they have.
  double get _progress => _reduceMotion ? 1 : Curves.easeOutCubic.transform(((_controller.value * 1.05 - _delay) / _duration).clamp(0.0, 1.0));

  /// The ring's scale, which settles with a small overshoot.
  double get _scale => _reduceMotion ? 1 : 0.82 + 0.18 * Curves.easeOutBack.transform(((_controller.value * 1.05 - _delay) / _duration).clamp(0.0, 1.0));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_started) return;
    _started = true;
    if (_reduceMotion) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
    if (_total > 0) {
      // A light success haptic as the score comes in.
      WidgetsBinding.instance.addPostFrameCallback((_) => HapticFeedback.lightImpact());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final top = media.padding.top + rootBarHeight;
    final empty = widget.session.results.isEmpty;
    return Stack(
      children: [
        Positioned.fill(
          child: empty
              ? Padding(
                  padding: EdgeInsets.only(top: top, bottom: _barHeight + media.padding.bottom),
                  child: Center(
                    child: ContentUnavailable(
                      icon: StudySymbols.empty,
                      title: L10n.text('Nothing to Review'),
                      description: L10n.text('No tag is due right now. Learn new tags or come back later.'),
                    ),
                  ),
                )
              : AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) => ListView(
                    padding: EdgeInsets.only(top: top + 10, bottom: 24 + _barHeight + media.padding.bottom),
                    children: [
                      _hero(context),
                      if (widget.session.withoutPictures)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(32, 4, 32, 0),
                          child: Text(
                            L10n.text('Some questions asked by meaning because no picture could be read.'),
                            style: TegnalType.style(13, color: TegnalColors.secondaryLabel.resolveFrom(context)),
                          ),
                        ),
                      const SizedBox(height: 20),
                      _tiles(context),
                      studySectionGap,
                      _journey(context),
                      studySectionGap,
                      _answers(context),
                    ],
                  ),
                ),
        ),
        if (!empty && !_reduceMotion) Positioned.fill(child: StudyConfetti(pieces: _grade.confetti)),
        // The way on stays in reach however long the list of answers is.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: StudyBottomBar(
            children: [
              Expanded(
                child: StudyButton(key: const Key('study.done'), title: L10n.text('Done'), onPressed: widget.onDone),
              ),
              if (!empty) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: StudyButton(key: const Key('study.again'), title: L10n.text('Another Round'), prominent: true, onPressed: widget.onAgain),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  static const _barHeight = 74.0;

  // MARK: Score

  Widget _hero(BuildContext context) {
    final grade = _grade;
    final colors = grade.colors(context);
    final shown = _progress;
    final label = TegnalColors.label.resolveFrom(context);
    final count = (_right * shown).round();
    return Semantics(
      container: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            const SizedBox(height: 8),
            Transform.scale(
              scale: _scale,
              child: SizedBox.square(
                dimension: 176,
                child: CustomPaint(
                  painter: _ScorePainter(
                    fraction: _total > 0 ? _right / _total * shown : 0,
                    track: StudyStyle.tertiaryFill.resolveFrom(context),
                    colors: colors,
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Transform.scale(
                          scale: 1 + 0.25 * math.sin(math.pi * shown),
                          child: Icon(grade.symbol, size: 22, color: colors[0]),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$count / $_total',
                          key: const Key('study.score'),
                          style: TegnalType.style(40, weight: FontWeight.w700, color: label).digits,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              L10n.text(grade.title),
              textAlign: TextAlign.center,
              style: TegnalType.style(22, weight: FontWeight.w700, color: label),
            ),
            const SizedBox(height: 4),
            Text(
              L10n.text(grade == StudyGrade.perfect ? 'Every answer right.' : 'Tags you missed come back sooner.'),
              textAlign: TextAlign.center,
              style: TegnalType.style(15, color: TegnalColors.secondaryLabel.resolveFrom(context)),
            ),
          ],
        ),
      ),
    );
  }

  // MARK: What the round changed

  Widget _tiles(BuildContext context) {
    final after = widget.after;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: _tile(
              context,
              StudySymbols.streakFilled,
              SystemColors.orange.resolveFrom(context),
              '${after.streak}',
              L10n.text('Day streak'),
              raised: after.streak > widget.before.streak,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _tile(
              context,
              StudySymbols.learnedFilled,
              SystemColors.green.resolveFrom(context),
              _gained > 0 ? '+$_gained' : '${after.learned}',
              L10n.text(_gained > 0 ? 'Newly learned' : 'Learned'),
              raised: _gained > 0,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: _tile(context, StudySymbols.todayFilled, StudyStyle.accent(context), '${after.today}', L10n.text('Answered today'), raised: false)),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, IconData icon, Color color, String value, String title, {required bool raised}) {
    // The symbol of a tile the round raised bounces as the numbers come in.
    final bounce = raised ? 1 + 0.3 * math.sin(math.pi * _progress) : 1.0;
    return Semantics(
      container: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 96),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        decoration: ShapeDecoration(
          color: FormColors.listRow.resolveFrom(context),
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(16),
            side: raised ? BorderSide(color: color.withValues(alpha: 0.5), width: 1.5) : BorderSide.none,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Transform.scale(
              scale: bounce,
              child: Icon(icon, size: 20, color: color),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: TegnalType.style(22, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)).digits,
            ),
            const SizedBox(height: 4),
            Text(
              title,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TegnalType.style(12, color: TegnalColors.secondaryLabel.resolveFrom(context)),
            ),
          ],
        ),
      ),
    );
  }

  /// How far through the whole curriculum the round has brought the learner.
  Widget _journey(BuildContext context) {
    final before = widget.before;
    final after = widget.after;
    final total = after.total;
    final from = total == 0 ? 0.0 : before.learned / total;
    final to = total == 0 ? 0.0 : after.learned / total;
    final fraction = from + (to - from) * _progress;
    final accent = StudyStyle.accent(context);
    return FormSection(
      rowColor: FormColors.listRow.resolveFrom(context),
      children: [
        FormRow(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        L10n.text('%@ of %@ learned', ['${after.learned}', '$total']),
                        style: TegnalType.style(15, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                      ),
                    ),
                    if (after.due > 0)
                      Text(L10n.text('%@ to review', ['${after.due}']), style: TegnalType.style(12, color: TegnalColors.secondaryLabel.resolveFrom(context))),
                  ],
                ),
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (context, box) => SizedBox(
                    height: 8,
                    child: DecoratedBox(
                      decoration: ShapeDecoration(color: StudyStyle.tertiaryFill.resolveFrom(context), shape: const StadiumBorder()),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          width: math.max(fraction > 0 ? 8.0 : 0.0, box.maxWidth * fraction),
                          decoration: ShapeDecoration(
                            gradient: LinearGradient(colors: [accent, SystemColors.purple.resolveFrom(context)]),
                            shape: const StadiumBorder(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _answers(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return FormSection(
      prominentHeader: true,
      rowColor: FormColors.listRow.resolveFrom(context),
      header: Text(L10n.text('Answers')),
      children: [
        for (final result in widget.session.results)
          FormRow(
            onTap: () => widget.onOpen(result.tag),
            child: Row(
              children: [
                Icon(
                  result.right ? StudySymbols.right : StudySymbols.wrong,
                  size: 22,
                  color: (result.right ? SystemColors.green : SystemColors.red).resolveFrom(context),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        result.tag.english,
                        style: TegnalType.style(17, weight: FontWeight.w500, color: TegnalColors.label.resolveFrom(context)),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        result.tag.note.resolved(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TegnalType.style(13, color: secondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Icon(CupertinoIcons.chevron_right, size: 15, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
              ],
            ),
          ),
      ],
    );
  }
}

/// The score's ring: a track and the right answers' share of it in the grade's gradient, starting at the top.
class _ScorePainter extends CustomPainter {
  _ScorePainter({required this.fraction, required this.track, required this.colors});
  final double fraction;
  final Color track;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    const width = 14.0;
    final rect = (Offset.zero & size).deflate(width / 2);
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = track,
    );
    if (fraction <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * fraction.clamp(0.0, 1.0),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(colors: [...colors, colors[0]], transform: const GradientRotation(-math.pi / 2)).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_ScorePainter old) => old.fraction != fraction || old.track != track || !listEquals(old.colors, colors);
}

/// `StudyConfetti`: paper falling once from the top of the screen.
class StudyConfetti extends StatefulWidget {
  const StudyConfetti({super.key, required this.pieces});
  final int pieces;

  static const length = 3.6;

  @override
  State<StudyConfetti> createState() => _StudyConfettiState();
}

class _StudyConfettiState extends State<StudyConfetti> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 3600))..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = [
      SystemColors.indigo,
      SystemColors.purple,
      SystemColors.pink,
      SystemColors.orange,
      SystemColors.yellow,
      SystemColors.teal,
      SystemColors.green,
    ].map((color) => color.resolveFrom(context)).toList();
    return ExcludeSemantics(
      child: IgnorePointer(
        child: CustomPaint(
          key: const Key('study.confetti'),
          painter: ConfettiPainter(pieces: widget.pieces, colors: colors, time: _controller),
        ),
      ),
    );
  }
}

/// Draws the pieces for one moment of the fall; the same piece is drawn the same way in every frame.
class ConfettiPainter extends CustomPainter {
  ConfettiPainter({required this.pieces, required this.colors, required this.time}) : super(repaint: time);
  final int pieces;
  final List<Color> colors;
  final Animation<double> time;

  /// A steady value in 0..<1 for a piece.
  static double unit(int index, int salt) {
    var value = index * 2654435761 + salt * 40503 + 12345;
    value ^= value >>> 15;
    value *= 2246822519;
    value ^= value >>> 13;
    return ((value & 0x7fffffffffffffff) % 10000) / 10000;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final seconds = time.value * StudyConfetti.length;
    if (seconds >= StudyConfetti.length) return;
    for (var index = 0; index < pieces; index++) {
      final age = seconds - unit(index, 1) * 0.9;
      if (age <= 0) continue;
      final speed = 180 + unit(index, 2) * 260;
      final x = unit(index, 3) * size.width + math.sin(age * (2 + unit(index, 4) * 3) + unit(index, 5) * 6) * 26;
      final y = -24 + speed * age + 120 * age * age;
      if (y >= size.height + 24) continue;
      final opacity = ((StudyConfetti.length - seconds) / 0.8).clamp(0.0, 1.0);
      final width = 6 + unit(index, 7) * 6;
      canvas
        ..save()
        ..translate(x, y)
        ..rotate(age * (3 + unit(index, 6) * 6))
        ..drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(-width / 2, -width * 0.3, width, width * 0.6), const Radius.circular(1.5)),
          Paint()..color = colors[index % colors.length].withValues(alpha: opacity),
        )
        ..restore();
    }
  }

  @override
  bool shouldRepaint(ConfettiPainter old) => old.pieces != pieces || !listEquals(old.colors, colors);
}
