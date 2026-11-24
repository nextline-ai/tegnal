import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/support/l10n.dart';
import '../design/app_sheet.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';
import '../study_mode/study_kit.dart';
import 'lab_kit.dart';

// Who made this: NextLine, the studio behind TEGNAL and its courses (https://nextline.work). Ported from `CreatorView.swift`.
// Shown as a page in each built-in course's onboarding (the AI lab before its one-minute check, 2D AI 배우기 after its hello)
// and behind a "누가 만들었나요?" button in the 코스 tab and the 2D course's Me tab. The figures are the ones NextLine publishes
// on its own site; keep them in step with it.

abstract final class Creator {
  static final site = Uri.parse('https://nextline.work');
  static final mail = Uri.parse('mailto:contact@nextline.work');
  static const ink = Color(0xFFF5F2EE);
  static const muted = Color(0xFF9C978F);
  static const ground = Color(0xFF0C0B0B);
  static const raised = Color(0xFF1A1817);

  /// The mark's colours, from hot pink through red to amber, as on the site.
  static const gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFF0D5E), Color(0xFFFF240C), Color(0xFFFF732D), Color(0xFFFFB047), Color(0xFFFFD356)],
    stops: [0, 0.38, 0.62, 0.82, 1],
  );

  /// Each record: its figure, then `creator.<id>.label` and `creator.<id>.detail`.
  static const records = [('chatbot', 'creator.chatbot.value'), ('app', 'TOP 25'), ('edu', '#1'), ('usage', 'creator.usage.value')];
  static const work = ['creator.work.prompt', 'creator.work.design', 'creator.work.build', 'creator.work.teach'];
}

/// NextLine's mark: the N drawn as two strokes, a bar and a falling diagonal (`NextLineMark`).
class NextLineMark extends StatelessWidget {
  const NextLineMark({super.key, required this.width, required this.height, this.opacity = 1});
  final double width;
  final double height;
  final double opacity;

  @override
  Widget build(BuildContext context) => SizedBox(width: width, height: height, child: CustomPaint(painter: _MarkPainter(opacity)));
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.opacity);
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    // The site's own drawing, in its 652 × 514 box from (186, 255).
    const box = Rect.fromLTWH(186, 255, 652, 514);
    final scale = (size.width / box.width) < (size.height / box.height) ? size.width / box.width : size.height / box.height;
    final origin = Offset((size.width - box.width * scale) / 2, (size.height - box.height * scale) / 2);
    Offset point(double x, double y) => origin + Offset((x - box.left) * scale, (y - box.top) * scale);
    final path = Path()
      ..addPolygon([point(528.6, 460.1), point(528.6, 628.76), point(660.76, 760.92), point(829.42, 760.92)], true)
      ..addPolygon([
        point(312.53, 263.08),
        point(194.59, 263.08),
        point(194.59, 760.92),
        point(312.84, 760.92),
        point(312.84, 432.05),
        point(433.74, 552.95),
        point(433.74, 384.29),
      ], true);
    canvas.saveLayer(Offset.zero & size, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
    canvas.drawPath(path, Paint()..shader = Creator.gradient.createShader(Offset.zero & size));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.opacity != opacity;
}

/// The page itself, dark in either appearance as NextLine's own pages are (`CreatorProfile`). In an onboarding it adds a line
/// about the course. [framed] puts it on a dark card of its own, for screens of another colour; the page that stands alone is
/// the dark ground itself.
class CreatorProfile extends StatelessWidget {
  const CreatorProfile({super.key, this.onboarding = false, this.framed = true});
  final bool onboarding;
  final bool framed;

  static const _red = Color(0xFFFF240C);

  @override
  Widget build(BuildContext context) {
    final body = Padding(
      padding: framed ? const EdgeInsets.symmetric(horizontal: 24, vertical: 32) : const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _hero(),
          _section(
            'creator.records',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (index, (id, value)) in Creator.records.indexed) ...[
                  if (index > 0) _rule(),
                  _record(id, value, first: index == 0),
                ],
                _rule(),
                const SizedBox(height: 20),
                Text(L10n.text('creator.records.note'), style: LabFont.text(14, color: Creator.muted).copyWith(height: 1.5)),
              ],
            ),
          ),
          _section(
            'creator.work',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (index, item) in Creator.work.indexed) ...[
                  if (index > 0) const SizedBox(height: 16),
                  MergeSemantics(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          (index + 1).toString().padLeft(2, '0'),
                          style: LabFont.text(13, weight: FontWeight.w500, color: Creator.muted).copyWith(fontFamily: 'monospace', fontFamilyFallback: const []),
                        ),
                        const SizedBox(width: 16),
                        Expanded(child: Text(L10n.text(item), style: LabFont.text(17, weight: FontWeight.w500, color: Creator.ink))),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 56),
          _link(const Key('creator.site'), 'creator.site', CupertinoIcons.arrow_up_right, prominent: true, onTap: () => launchUrl(Creator.site, mode: LaunchMode.externalApplication)),
          const SizedBox(height: 12),
          _link(const Key('creator.mail'), 'creator.mail', CupertinoIcons.envelope, prominent: false, onTap: () => launchUrl(Creator.mail)),
        ],
      ),
    );
    if (!framed) return body;
    // In a card the mark runs to the card's edge; on its own page, to the screen's.
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: ShapeDecoration(color: Creator.ground, shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(28))),
      child: body,
    );
  }

  /// The key visual: the mark large and glowing, running off the right edge as on the site's opening screen, the name small at
  /// its side; then the motto, and what NextLine is.
  Widget _hero() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: double.infinity,
        height: 236,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // A soft light behind the mark: a blurred disc, so it has no edge anywhere.
            Positioned(
              right: -110,
              top: -70,
              child: ExcludeSemantics(
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: 60, sigmaY: 60, tileMode: TileMode.decal),
                  child: Container(
                    width: 240,
                    height: 240,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: _red.withValues(alpha: 0.32)),
                  ),
                ),
              ),
            ),
            const Positioned(right: -44, top: 18, child: ExcludeSemantics(child: NextLineMark(width: 236, height: 186))),
            Semantics(
              key: const Key('creator.profile'),
              label: 'NextLine',
              excludeSemantics: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('NextLine', style: LabFont.text(20, weight: FontWeight.w700, color: Creator.ink)),
                  const SizedBox(height: 6),
                  Text(
                    '051 / BUSAN',
                    style: LabFont.text(11, weight: FontWeight.w500, color: Creator.muted, tracking: 1.5).copyWith(fontFamily: 'monospace', fontFamilyFallback: const []),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Text(L10n.text('creator.studio'), style: LabFont.text(13, weight: FontWeight.w500, color: Creator.muted)),
      const SizedBox(height: 10),
      Semantics(
        header: true,
        child: Text(L10n.text('creator.motto'), style: LabFont.text(34, weight: FontWeight.w800, color: Creator.ink).copyWith(height: 1.25)),
      ),
      const SizedBox(height: 20),
      Text(L10n.text('creator.about'), style: LabFont.text(16, color: Creator.ink.withValues(alpha: 0.72)).copyWith(height: 1.6)),
      if (onboarding) ...[
        const SizedBox(height: 24),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 3, decoration: const ShapeDecoration(gradient: Creator.gradient, shape: StadiumBorder())),
              const SizedBox(width: 14),
              Expanded(
                child: Text(L10n.text('creator.course'), style: LabFont.text(16, weight: FontWeight.w600, color: Creator.ink).copyWith(height: 1.5)),
              ),
            ],
          ),
        ),
      ],
    ],
  );

  Widget _rule() => Container(height: 1, color: Creator.ink.withValues(alpha: 0.1));

  Widget _section(String title, Widget content) => Padding(
    padding: const EdgeInsets.only(top: 56),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(header: true, child: Text(L10n.text(title).toUpperCase(), style: LabFont.text(12, weight: FontWeight.w600, color: Creator.muted, tracking: 1.6))),
        const SizedBox(height: 20),
        content,
      ],
    ),
  );

  /// One record: the figure large, what it counts beneath, a quiet note; every row starts on the same edge.
  Widget _record(String id, String value, {bool first = false}) => MergeSemantics(
    child: Padding(
      padding: EdgeInsets.only(top: first ? 6 : 22, bottom: 22),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: ShaderMask(
                shaderCallback: Creator.gradient.createShader,
                child: Text(L10n.text(value), maxLines: 1, style: LabFont.text(34, weight: FontWeight.w800, color: const Color(0xFFFFFFFF))),
              ),
            ),
            const SizedBox(height: 8),
            Text(L10n.text('creator.$id.label'), style: LabFont.text(16, weight: FontWeight.w600, color: Creator.ink)),
            const SizedBox(height: 4),
            Text(L10n.text('creator.$id.detail'), style: LabFont.text(14, color: Creator.muted)),
          ],
        ),
      ),
    ),
  );

  Widget _link(Key key, String title, IconData icon, {required bool prominent, required VoidCallback onTap}) => LabPress(
    key: key,
    onTap: onTap,
    child: Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: ShapeDecoration(
        gradient: prominent ? Creator.gradient : null,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(16),
          side: prominent ? BorderSide.none : BorderSide(color: Creator.ink.withValues(alpha: 0.2)),
        ),
      ),
      child: Row(
        children: [
          Expanded(child: Text(L10n.text(title), style: LabFont.text(16, weight: FontWeight.w600, color: prominent ? const Color(0xFFFFFFFF) : Creator.ink))),
          Icon(icon, size: 16, color: prominent ? const Color(0xFFFFFFFF) : Creator.ink),
        ],
      ),
    ),
  );
}

/// The page on its own, as the "누가 만들었나요?" button opens it (`CreatorView`).
Future<void> showCreator(BuildContext context) => showAppSheet<void>(
  context,
  builder: (context, controller) {
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(platformBrightness: Brightness.dark),
      child: CupertinoTheme(
        data: CupertinoTheme.of(context).copyWith(brightness: Brightness.dark),
        child: ColoredBox(
          color: Creator.ground,
          child: Stack(
            children: [
              ListView(
                controller: controller,
                padding: EdgeInsets.fromLTRB(24, 76 + 16, 24, 48 + media.padding.bottom),
                children: [
                  Center(
                    child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: const CreatorProfile(framed: false)),
                  ),
                ],
              ),
              SheetNavigationBar(
                title: L10n.text('creator.kicker'),
                leading: GlassTextButton(label: L10n.text('Close'), onPressed: () => Navigator.of(context).pop()),
              ),
            ],
          ),
        ),
      ),
    );
  },
);

/// Where the button sits: the lab's stock pages or the 2D course's rounded ones.
enum CreatorButtonStyle { lab, study }

/// "누가 만들었나요?": a quiet row that opens the page (`CreatorButton`).
class CreatorButton extends StatelessWidget {
  const CreatorButton({super.key, this.style = CreatorButtonStyle.lab});
  final CreatorButtonStyle style;

  @override
  Widget build(BuildContext context) {
    final study = style == CreatorButtonStyle.study;
    final theme = study ? StudyTheme.of(context) : null;
    final label = theme?.ink ?? TegnalColors.label.resolveFrom(context);
    final secondary = theme?.muted ?? TegnalColors.secondaryLabel.resolveFrom(context);
    return Semantics(
      button: true,
      child: GestureDetector(
        key: const Key('creator.button'),
        behavior: HitTestBehavior.opaque,
        onTap: () => showCreator(context),
        child: Container(
          padding: study ? const EdgeInsets.symmetric(horizontal: 12, vertical: 10) : const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: study
              ? null
              : ShapeDecoration(
                  color: FormColors.listRow.resolveFrom(context),
                  shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(18)),
                ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: ShapeDecoration(color: Creator.ground, shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(11))),
                child: const NextLineMark(width: 26, height: 21),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      L10n.text('creator.button'),
                      style: study ? StudyTheme.body(16, StudyTheme.bold).copyWith(color: label) : LabFont.text(16, weight: FontWeight.w600, color: label),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      L10n.text('creator.button.detail'),
                      style: study ? StudyTheme.body(13, StudyTheme.medium).copyWith(color: secondary) : LabFont.text(13, color: secondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(CupertinoIcons.chevron_right, size: 14, color: secondary),
            ],
          ),
        ),
      ),
    );
  }
}
