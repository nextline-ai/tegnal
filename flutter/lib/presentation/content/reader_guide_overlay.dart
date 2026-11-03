import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/support/l10n.dart';
import '../design/symbols.dart';
import '../design/tegnal_theme.dart';
import 'reader_models.dart';

/// `ReaderGuideOverlay`: a coach mark over the real reader. Only the tip card takes touches.
class ReaderGuideOverlay extends StatefulWidget {
  const ReaderGuideOverlay({super.key, required this.step, required this.configuration, required this.menuKey, required this.next, required this.finish});
  final ReaderGuideStep step;
  final ReaderGuideConfiguration configuration;

  /// The quick menu, highlighted in the tools step.
  final GlobalKey menuKey;
  final VoidCallback next;
  final VoidCallback finish;

  @override
  State<ReaderGuideOverlay> createState() => _ReaderGuideOverlayState();
}

class _ReaderGuideOverlayState extends State<ReaderGuideOverlay> {
  Rect? _menu;

  /// The menu appears in the same frame as the tools step, so its bounds are read after layout.
  void _measureMenu() {
    if (!mounted) return;
    final menu = widget.menuKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay = context.findRenderObject() as RenderBox?;
    Rect? rect;
    if (menu != null && overlay != null && menu.hasSize && menu.attached) {
      rect = menu.localToGlobal(Offset.zero, ancestor: overlay) & menu.size;
    }
    if (rect != _menu) setState(() => _menu = rect);
  }

  Rect _highlight(Size size, double safeTop) => switch (widget.step) {
    ReaderGuideStep.tools when _menu != null => _menu!.inflate(4),
    ReaderGuideStep.exit => Rect.fromLTWH(12, safeTop, size.width - 24, 64),
    _ => Rect.fromLTWH(size.width * 0.3, size.height * 0.29, size.width * 0.4, size.height * 0.27),
  };

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureMenu());
    final media = MediaQuery.of(context);
    // The native safe area keeps the home indicator's 34 pt; immersive Android has none.
    final bottom = media.padding.bottom < 34 ? 34.0 : media.padding.bottom;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final rect = _highlight(size, media.padding.top);
        final tip = ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: _ReaderGuideTip(step: widget.step, message: widget.configuration.instruction(widget.step), next: widget.next, finish: widget.finish),
        );
        return Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(child: CustomPaint(painter: _SpotlightPainter(rect))),
            ),
            if (widget.step != ReaderGuideStep.tools)
              Positioned.fromRect(
                rect: rect,
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child: Center(
                      child: widget.step == ReaderGuideStep.navigation
                          ? const HandTapSymbol(size: 40, color: Color(0xFFFFFFFF))
                          : const Icon(CupertinoIcons.arrow_down, size: 30, color: Color(0xFFFFFFFF), fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: media.padding.left + 20,
              right: media.padding.right + 20,
              top: widget.step == ReaderGuideStep.tools ? media.padding.top + 24 : null,
              bottom: widget.step == ReaderGuideStep.tools ? null : bottom + 24,
              child: Center(child: tip),
            ),
          ],
        );
      },
    );
  }
}

class _SpotlightPainter extends CustomPainter {
  _SpotlightPainter(this.rect);
  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    final hole = RRect.fromRectAndRadius(rect, const Radius.circular(20));
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRRect(hole),
      Paint()..color = const Color(0xA6000000),
    );
    // `strokeBorder` keeps the 2 pt line inside the highlighted area.
    canvas.drawRRect(
      hole.deflate(1),
      Paint()
        ..color = const Color(0xF2FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) => old.rect != rect;
}

class _ReaderGuideTip extends StatelessWidget {
  const _ReaderGuideTip({required this.step, required this.message, required this.next, required this.finish});
  final ReaderGuideStep step;
  final String message;
  final VoidCallback next;
  final VoidCallback finish;

  @override
  Widget build(BuildContext context) {
    const white = Color(0xFFFFFFFF);
    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: const ShapeDecoration(
          color: Color(0xFF1F1F1F),
          shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(L10n.text('Step %@ of %@', ['${step.rawValue + 1}', '3']), style: TegnalType.style(15, color: white.withValues(alpha: 0.7))),
                ),
                Semantics(
                  button: true,
                  label: L10n.text('Skip Guide'),
                  excludeSemantics: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: finish,
                    child: const SizedBox.square(dimension: 32, child: Icon(CupertinoIcons.xmark, size: 20, color: white)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              step.title,
              style: TegnalType.style(22, weight: FontWeight.w700, color: white),
            ),
            const SizedBox(height: 12),
            Text(message, style: TegnalType.style(17, color: white).copyWith(height: 1.29)),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: Semantics(
                button: true,
                child: GestureDetector(
                  onTap: next,
                  child: Container(
                    height: 50,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    decoration: ShapeDecoration(color: TegnalColors.tint.resolveFrom(context), shape: const StadiumBorder()),
                    child: Center(
                      widthFactor: 1,
                      child: Text(L10n.text(step == ReaderGuideStep.exit ? 'Start Reading' : 'Next Tip'), style: TegnalType.style(17, color: white)),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
