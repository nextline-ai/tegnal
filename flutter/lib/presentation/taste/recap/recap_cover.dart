import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../../core/support/l10n.dart';
import '../../../core/taste/recap_shelf.dart';
import '../../../core/taste/taste_recap.dart';
import '../../design/tegnal_theme.dart';
import 'recap_cover_art.dart';
import 'recap_style.dart';

/// `RecapCoverLayout`: a printed cover, the masthead over artwork, with the issue's facts
/// set like coverlines.
class RecapCoverLayout extends StatelessWidget {
  const RecapCoverLayout({
    super.key,
    required this.recap,
    required this.palette,
    required this.background,
    this.showsTags = true,
    this.note,
    this.insets = EdgeInsets.zero,
  });

  final TasteRecap recap;
  final RecapPalette palette;
  final Widget background;
  final bool showsTags;
  final String? note;
  final EdgeInsets insets;

  static String _grouped(int value) => '$value'.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      const white = Color(0xFFFFFFFF);
      final ink = palette.inkColor;
      final persona = recap.persona;
      Widget fact(String value, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            value,
            style: RecapType.display(width * 0.05, weight: FontWeight.w700, color: white),
          ),
          SizedBox(width: width * 0.012),
          Text(
            label,
            style: TegnalType.style(width * 0.031, weight: FontWeight.w500, color: white.withValues(alpha: 0.78)),
          ),
        ],
      );
      return ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            background,
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [ink.withValues(alpha: 0.78), ink.withValues(alpha: 0), ink.withValues(alpha: 0), ink.withValues(alpha: 0.94)],
                  stops: const [0, 0.34, 0.46, 1],
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(width * 0.058).add(insets),
              child: DefaultTextStyle(
                style: TegnalType.style(width * 0.04, color: white),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'RECAP',
                        style: RecapType.display(width * 0.262, color: white, letterSpacing: -width * 0.006),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.only(top: width * 0.006),
                      child: Container(height: math.max(1, width * 0.003), color: white.withValues(alpha: 0.75)),
                    ),
                    Padding(
                      padding: EdgeInsets.only(top: width * 0.02),
                      child: DefaultTextStyle(
                        style: RecapType.folio(width * 0.03, color: white),
                        child: Row(
                          children: [
                            Text((recap.isSample ? L10n.text('Sample issue') : L10n.text('No. %@', ['${recap.issue}'])).toUpperCase()),
                            const Spacer(),
                            Flexible(child: Text(RecapFormat.title(recap).toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis)),
                            const Spacer(),
                            Text(RecapFormat.modeName(recap.mode).toUpperCase()),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    if (note != null)
                      Padding(
                        padding: EdgeInsets.only(bottom: width * 0.03),
                        child: Text.rich(RecapType.italicSpan(note!, RecapType.display(width * 0.042, weight: FontWeight.w500, italic: true, color: white))),
                      ),
                    if (persona != null)
                      Text(
                        persona.title,
                        maxLines: 2,
                        style: RecapType.display(width * 0.098, weight: FontWeight.w800, color: white),
                      ),
                    if (showsTags && recap.tags.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(top: width * 0.016),
                        child: Text(
                          recap.tags.take(3).map((tag) => RecapText.tag(tag.name)).join('  ·  '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TegnalType.style(width * 0.04, weight: FontWeight.w600, color: white.withValues(alpha: 0.9)),
                        ),
                      ),
                    Padding(
                      padding: EdgeInsets.only(top: width * 0.03),
                      child: Container(height: math.max(1, width * 0.002), color: white.withValues(alpha: 0.4)),
                    ),
                    Padding(
                      padding: EdgeInsets.only(top: width * 0.026),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Row(
                          children: [
                            fact(_grouped(recap.saves), L10n.text('Saved')),
                            SizedBox(width: width * 0.05),
                            fact(_grouped(recap.opens), L10n.text('Opened')),
                            SizedBox(width: width * 0.05),
                            fact(_grouped(recap.activeDays), L10n.text('Active days')),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// `RecapCover`: the issue's generated cover with its masthead.
class RecapCoverView extends StatelessWidget {
  const RecapCoverView({super.key, required this.recap, required this.palette});
  final TasteRecap recap;
  final RecapPalette palette;

  @override
  Widget build(BuildContext context) => Semantics(
    label: L10n.text('Recap issue %@, %@', ['${recap.issue}', RecapFormat.title(recap)]),
    excludeSemantics: true,
    child: RecapCoverLayout(
      recap: recap,
      palette: palette,
      background: RecapCoverArt(palette: palette, seed: recap.coverSeed),
    ),
  );
}
