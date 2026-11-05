import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../design/tegnal_theme.dart';

/// The viewers' quick menu glass: the same clear glass as the Up Next bar, always dark, with the
/// device's rounded corners.
class ViewerPanelGlass extends StatelessWidget {
  const ViewerPanelGlass({super.key, required this.child, this.cornerRadius = 44});
  final Widget child;
  final double cornerRadius;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.all(Radius.circular(cornerRadius)),
      side: const BorderSide(color: Color(0x2EFFFFFF), width: 0.5),
    );
    return ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: DecoratedBox(
          decoration: ShapeDecoration(shape: shape, color: const Color(0x8C404044)),
          child: child,
        ),
      ),
    );
  }
}

/// `ViewerQuickMenuPanel`: laid out as the Camera app lays out its controls, a glass sheet inset
/// from the screen's edges with its tools as round buttons in three columns, their names
/// underneath. Pulling it down puts it away.
class ViewerQuickMenuPanel extends StatefulWidget {
  const ViewerQuickMenuPanel({super.key, required this.close, required this.navigation, required this.actions});
  final VoidCallback close;
  final Widget navigation;
  final Widget actions;

  @override
  State<ViewerQuickMenuPanel> createState() => _ViewerQuickMenuPanelState();
}

class _ViewerQuickMenuPanelState extends State<ViewerQuickMenuPanel> {
  double _pull = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onVerticalDragUpdate: (details) => setState(() => _pull = (_pull + details.delta.dy).clamp(0, 400)),
    onVerticalDragEnd: (details) {
      final close = _pull > 70 || (details.primaryVelocity ?? 0) > 700;
      setState(() => _pull = 0);
      if (close) widget.close();
    },
    child: AnimatedContainer(
      duration: _pull == 0 ? const Duration(milliseconds: 260) : Duration.zero,
      curve: Curves.easeOutCubic,
      transform: Matrix4.translationValues(0, _pull, 0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ViewerPanelGlass(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
            child: Column(mainAxisSize: MainAxisSize.min, children: [widget.navigation, const SizedBox(height: 18), widget.actions]),
          ),
        ),
      ),
    ),
  );
}

const _white = Color(0xFFFFFFFF);
const _buttonFill = Color(0x1FFFFFFF);

/// One tool of the quick menu: a round button with its name underneath.
class ViewerQuickMenuButton extends StatefulWidget {
  const ViewerQuickMenuButton({super.key, required this.title, required this.icon, this.onTap});
  final String title;
  final Widget icon;
  final VoidCallback? onTap;

  @override
  State<ViewerQuickMenuButton> createState() => _ViewerQuickMenuButtonState();
}

class _ViewerQuickMenuButtonState extends State<ViewerQuickMenuButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return Semantics(
      button: true,
      label: widget.title,
      enabled: enabled,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: AnimatedScale(
            scale: _pressed ? 0.92 : 1,
            duration: const Duration(milliseconds: 150),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: const ShapeDecoration(color: _buttonFill, shape: CircleBorder()),
                  child: Center(child: widget.icon),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TegnalType.style(15, color: _white.withValues(alpha: 0.9)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A round glass control in the quick menu's top row.
class ViewerQuickMenuCircle extends StatelessWidget {
  const ViewerQuickMenuCircle({super.key, required this.icon, required this.label, this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    enabled: onTap != null,
    excludeSemantics: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: const ShapeDecoration(color: _buttonFill, shape: CircleBorder()),
        child: Icon(icon, size: 19, color: onTap == null ? _white.withValues(alpha: 0.3) : _white),
      ),
    ),
  );
}

/// The page position between the arrows: a capsule that opens the page jump.
class ViewerQuickMenuPosition extends StatelessWidget {
  const ViewerQuickMenuPosition({super.key, required this.text, this.onTap});
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      height: 44,
      decoration: const ShapeDecoration(color: _buttonFill, shape: StadiumBorder()),
      alignment: Alignment.center,
      child: Text(
        text,
        style: TegnalType.style(17, weight: FontWeight.w600, color: _white),
      ),
    ),
  );
}

/// The quick menu's top row: previous, the position, next and close.
class ViewerQuickMenuNavigation extends StatelessWidget {
  const ViewerQuickMenuNavigation({
    super.key,
    required this.position,
    required this.previousLabel,
    required this.nextLabel,
    required this.closeLabel,
    this.previous,
    this.next,
    this.jump,
    required this.close,
  });
  final String position;
  final String previousLabel;
  final String nextLabel;
  final String closeLabel;
  final VoidCallback? previous;
  final VoidCallback? next;
  final VoidCallback? jump;
  final VoidCallback close;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      ViewerQuickMenuCircle(icon: CupertinoIcons.chevron_left, label: previousLabel, onTap: previous),
      const SizedBox(width: 12),
      Expanded(
        child: ViewerQuickMenuPosition(text: position, onTap: jump),
      ),
      const SizedBox(width: 12),
      ViewerQuickMenuCircle(icon: CupertinoIcons.chevron_right, label: nextLabel, onTap: next),
      const SizedBox(width: 12),
      ViewerQuickMenuCircle(icon: CupertinoIcons.xmark, label: closeLabel, onTap: close),
    ],
  );
}

/// Lays the tools out in rows of three.
class ViewerQuickMenuGrid extends StatelessWidget {
  const ViewerQuickMenuGrid({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var row = 0; row * 3 < children.length; row++) ...[
        if (row > 0) const SizedBox(height: 20),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var column = 0; column < 3; column++)
              Expanded(child: row * 3 + column < children.length ? children[row * 3 + column] : const SizedBox.shrink()),
          ],
        ),
      ],
    ],
  );
}

/// The quick menu rises from the bottom by its own height, and falls back the same way.
class ViewerMenuReveal extends StatelessWidget {
  const ViewerMenuReveal({super.key, required this.visible, required this.child});
  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 340),
    reverseDuration: const Duration(milliseconds: 260),
    switchInCurve: Curves.easeOutCubic,
    switchOutCurve: Curves.easeInCubic,
    transitionBuilder: (child, animation) => SlideTransition(
      position: Tween(begin: const Offset(0, 1.1), end: Offset.zero).animate(animation),
      child: FadeTransition(opacity: animation, child: child),
    ),
    layoutBuilder: (current, previous) => Stack(alignment: Alignment.bottomCenter, children: [...previous, ?current]),
    child: visible ? child : const SizedBox.shrink(key: ValueKey('hidden')),
  );
}
