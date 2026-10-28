import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/content.dart';
import 'common.dart';
import 'l10n.dart';

IconData _tabIcon(int index, AppMode mode, bool selected) => switch (index) {
  0 => selected ? Icons.folder_rounded : Icons.folder_outlined,
  1 => Icons.public_rounded,
  2 => mode == AppMode.booru ? Icons.sell_rounded : Icons.people_alt_rounded,
  _ =>
    mode == AppMode.booru ? Icons.more_horiz_rounded : Icons.settings_rounded,
};

/// Material destinations retain the collection's floating split-tab layout.
class TegnalTabBar extends StatelessWidget {
  const TegnalTabBar({
    super.key,
    required this.labels,
    required this.mode,
    required this.selected,
    required this.onSelect,
  });
  final List<String> labels;
  final AppMode mode;
  final int selected;
  final ValueChanged<int> onSelect;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: ChromeSurface(
          enabled: true,
          borderRadius: BorderRadius.circular(40),
          respectReduceMotion: false,
          child: Material(
            color: Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Row(
                children: [
                  for (var i = 0; i < 4; i++)
                    Expanded(
                      child: Semantics(
                        selected: selected == i,
                        child: TextButton(
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 54),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 2,
                              vertical: 4,
                            ),
                            foregroundColor: selected == i
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.onSurface,
                            backgroundColor: selected == i
                                ? Theme.of(context).colorScheme.surface
                                : Colors.transparent,
                          ),
                          onPressed: () => onSelect(i),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(_tabIcon(i, mode, selected == i), size: 28),
                              const SizedBox(height: 4),
                              Text(
                                L10n.tr(context, labels[i]),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
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
      const SizedBox(width: 8),
      ChromeSurface(
        enabled: true,
        borderRadius: BorderRadius.circular(40),
        respectReduceMotion: false,
        child: SizedBox(
          width: tegnalCompactDockHeight,
          height: tegnalCompactDockHeight,
          child: IconButton(
            tooltip: L10n.tr(context, labels[4]),
            isSelected: selected == 4,
            style: IconButton.styleFrom(
              backgroundColor: selected == 4
                  ? Theme.of(context).colorScheme.surfaceContainerHighest
                  : Colors.transparent,
            ),
            onPressed: () => onSelect(4),
            icon: SmartMark(
              color: selected == 4
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurface,
              size: 32,
            ),
          ),
        ),
      ),
    ],
  );
}

class TegnalSidebar extends StatelessWidget {
  const TegnalSidebar({
    super.key,
    required this.labels,
    required this.mode,
    required this.selected,
    required this.onSelect,
  });
  final List<String> labels;
  final AppMode mode;
  final int selected;
  final ValueChanged<int> onSelect;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 224,
    child: NavigationDrawer(
      selectedIndex: selected,
      onDestinationSelected: onSelect,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 28, 24, 30),
          child: Text(
            'TEGNAL',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -.7,
            ),
          ),
        ),
        for (var i = 0; i < labels.length; i++)
          NavigationDrawerDestination(
            icon: i == 4
                ? SmartMark(
                    color: Theme.of(context).colorScheme.primary,
                    size: 30,
                  )
                : Icon(_tabIcon(i, mode, selected == i), size: 28),
            label: Text(L10n.tr(context, labels[i])),
          ),
      ],
    ),
  );
}

/// Three interlocking orbits echo the collection-analysis symbol.
class SmartMark extends StatelessWidget {
  const SmartMark({super.key, required this.color, this.size = 28});
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _SmartPainter(color));
}

class _SmartPainter extends CustomPainter {
  const _SmartPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * .075;
    final rect = Rect.fromCenter(
      center: Offset.zero,
      width: size.width * .91,
      height: size.height * .48,
    );
    for (var i = 0; i < 3; i++) {
      canvas.drawOval(rect, paint);
      canvas.rotate(math.pi / 3);
    }
  }

  @override
  bool shouldRepaint(_SmartPainter oldDelegate) => oldDelegate.color != color;
}
