import 'dart:async';
import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/support/l10n.dart';
import '../design/tegnal_theme.dart';

/// `SmartLoadingView`: what Smart shows while it picks works. A sparkle that keeps working, a
/// line that says what it is doing now, and cards that fill in as a wave passes over them, so a
/// long first load reads as progress rather than a stalled spinner.
class SmartLoadingView extends StatefulWidget {
  const SmartLoadingView({super.key});

  static const steps = ["Reading what you've saved…", 'Matching the tags you love…', 'Picking works for you…', 'Almost there…'];

  @override
  State<SmartLoadingView> createState() => _SmartLoadingViewState();
}

class _SmartLoadingViewState extends State<SmartLoadingView> with SingleTickerProviderStateMixin {
  late final AnimationController _wave = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();
  Timer? _timer;
  int _step = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 2400), (_) {
      if (mounted) setState(() => _step = (_step + 1) % SmartLoadingView.steps.length);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final fill = TegnalColors.coverPlaceholder.resolveFrom(context);
    return Semantics(
      label: L10n.text('Loading recommendations'),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          children: [
            SizedBox(
              height: 30,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedBuilder(
                    animation: _wave,
                    builder: (context, child) {
                      final phase = _wave.value * 2 * math.pi;
                      return Transform.rotate(
                        angle: math.sin(phase) * 0.18,
                        child: Transform.scale(scale: 1 + math.sin(phase * 2).abs() * 0.12, child: child),
                      );
                    },
                    child: Icon(CupertinoIcons.sparkles, size: 24, color: tint),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: ClipRect(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 420),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) {
                          final incoming = child.key == ValueKey(_step);
                          return FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: Tween(begin: Offset(0, incoming ? 0.8 : -0.8), end: Offset.zero).animate(animation),
                              child: child,
                            ),
                          );
                        },
                        child: Text(
                          L10n.text(SmartLoadingView.steps[_step]),
                          key: ValueKey(_step),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TegnalType.style(17, weight: FontWeight.w600, color: secondary),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            AnimatedBuilder(
              animation: _wave,
              builder: (context, _) => GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisSpacing: 12,
                mainAxisSpacing: 14,
                childAspectRatio: 0.58,
                children: [
                  for (var index = 0; index < 6; index++)
                    Opacity(
                      opacity: _pulse(index),
                      child: _SkeletonCard(fill: fill),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A wave that runs across the cards, row by row.
  double _pulse(int index) {
    final offset = (index % 3) * 0.12 + (index ~/ 3) * 0.08;
    final phase = ((_wave.value - offset) % 1.0) * 2 * math.pi;
    return 0.45 + 0.55 * (0.5 + 0.5 * math.cos(phase));
  }
}

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard({required this.fill});
  final Color fill;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: fill,
            shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: const SizedBox.expand(),
        ),
      ),
      const SizedBox(height: 6),
      Container(
        height: 10,
        decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(4)),
      ),
      const SizedBox(height: 6),
      Container(
        width: 46,
        height: 8,
        decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(4)),
      ),
    ],
  );
}
