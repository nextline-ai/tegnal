import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/support/l10n.dart';
import '../design/glass.dart';
import '../design/symbols.dart';
import '../design/tegnal_theme.dart';
import 'app_state.dart';

/// Height of the root navigation bar below the status bar.
const double rootBarHeight = 54;

/// The top of every root screen: a title capsule on the leading side and the
/// mode switch in the title position, floating above content without a bar background.
class RootHeader extends StatelessWidget {
  const RootHeader({super.key, required this.title, required this.state, this.trailing, this.onBack, this.backInTitle = false, this.showsModeSwitch = true});
  final String title;
  final AppState state;
  final Widget? trailing;

  /// A pushed screen shows a back button before its title and no mode switch.
  final VoidCallback? onBack;

  /// Saved works put the chevron inside the title capsule instead of its own circle.
  final bool backInTitle;
  final bool showsModeSwitch;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: SizedBox(
        height: rootBarHeight,
        child: Stack(
          children: [
            Positioned(
              left: 16,
              top: 0,
              child: Row(
                children: [
                  if (onBack != null && backInTitle)
                    BackTitleCapsule(title: title, onPressed: onBack!)
                  else ...[
                    if (onBack != null) ...[_BackButton(onPressed: onBack!), const SizedBox(width: 8)],
                    TitleCapsule(title),
                  ],
                ],
              ),
            ),
            if (onBack == null && showsModeSwitch)
              Positioned.fill(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: AppModeSwitch(state: state),
                ),
              ),
            if (trailing != null) Positioned(right: 16, top: 0, child: trailing!),
          ],
        ),
      ),
    );
  }
}

/// `LiquidGlassTitleCapsule` inside a toolbar's glass: 15 pt bold, 44 pt tall.
class TitleCapsule extends StatelessWidget {
  const TitleCapsule(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) => Glass.capsule(
    child: SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20.5),
        child: Center(
          widthFactor: 1,
          child: Text(
            title,
            style: TegnalType.style(15, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
          ),
        ),
      ),
    ),
  );
}

/// The compact comics/images switch: two 42×38 segments and a white thumb that
/// slides between them. Tapping toggles; a horizontal drag picks a side.
class AppModeSwitch extends StatefulWidget {
  const AppModeSwitch({super.key, required this.state});
  final AppState state;

  @override
  State<AppModeSwitch> createState() => _AppModeSwitchState();
}

class _AppModeSwitchState extends State<AppModeSwitch> {
  double? _dragPosition;

  static double _position(AppMode mode) => mode == AppMode.manga ? 0 : 44;

  void _change(AppMode mode) {
    setState(() => _dragPosition = null);
    widget.state.mode = mode;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final current = widget.state.mode;
        final position = _dragPosition ?? _position(current);
        return Semantics(
          button: true,
          label: L10n.text('Switch Modes'),
          value: L10n.text(current == AppMode.manga ? 'Comics Mode' : 'Image Mode'),
          hint: L10n.text('Tap or swipe to switch between comics and images.'),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _change(current == AppMode.manga ? AppMode.booru : AppMode.manga),
            onHorizontalDragUpdate: (details) => setState(() => _dragPosition = ((_dragPosition ?? _position(current)) + details.delta.dx).clamp(0, 44)),
            onHorizontalDragEnd: (details) {
              final end = (_dragPosition ?? _position(current)) + (details.primaryVelocity ?? 0) * 0.1;
              _change(end > 22 ? AppMode.booru : AppMode.manga);
            },
            onHorizontalDragCancel: () => setState(() => _dragPosition = null),
            child: Glass.capsule(
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: SizedBox(
                  width: 86,
                  height: 38,
                  child: Stack(
                    children: [
                      AnimatedPositioned(
                        duration: _dragPosition == null ? const Duration(milliseconds: 320) : Duration.zero,
                        curve: Curves.easeOutCubic,
                        left: position,
                        top: 0,
                        child: const DecoratedBox(
                          decoration: ShapeDecoration(
                            color: Color(0xFFFFFFFF),
                            shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.all(Radius.circular(19))),
                          ),
                          child: SizedBox(width: 42, height: 38),
                        ),
                      ),
                      Row(
                        children: [
                          _segment(current == AppMode.manga, Symbols.bookFill, Symbols.book),
                          const SizedBox(width: 2),
                          _segment(current == AppMode.booru, Symbols.photoFill, Symbols.photo),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _segment(bool selected, IconData filled, IconData outlined) =>
      SizedBox(width: 42, height: 38, child: Icon(selected ? filled : outlined, size: 23, color: selected ? const Color(0xFF000000) : const Color(0xFF8E8E93)));
}

/// The iOS 26 back button: a chevron in its own glass circle.
class _BackButton extends StatelessWidget {
  const _BackButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: L10n.text('Back'),
    excludeSemantics: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: Glass.circle(
        child: SizedBox.square(dimension: 44, child: Icon(CupertinoIcons.chevron_left, size: 22, color: TegnalColors.label.resolveFrom(context))),
      ),
    ),
  );
}

/// `WorksGridView`'s back button: a bold chevron and the folder's name in one glass capsule.
class BackTitleCapsule extends StatelessWidget {
  const BackTitleCapsule({super.key, required this.title, required this.onPressed});
  final String title;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = TegnalColors.label.resolveFrom(context);
    return Semantics(
      button: true,
      label: L10n.text('Back'),
      value: title,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Glass.capsule(
          child: SizedBox(
            height: 44,
            child: Padding(
              padding: const EdgeInsets.only(left: 13, right: 15),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(CupertinoIcons.chevron_left, size: 17, color: label, fontWeight: FontWeight.w700),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.45),
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TegnalType.style(15, weight: FontWeight.w700, color: label),
                    ),
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

/// `AppToolbarActions`: toolbar buttons sharing one 44 pt glass capsule, 40 pt apart.
class ToolbarGroup extends StatelessWidget {
  const ToolbarGroup({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Glass.capsule(
    child: SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (index, child) in children.indexed) ...[if (index > 0) const SizedBox(width: 4), child],
          ],
        ),
      ),
    ),
  );
}

/// One icon in a [ToolbarGroup]; a null action dims it.
class ToolbarIconButton extends StatelessWidget {
  const ToolbarIconButton({super.key, required this.label, required this.onPressed, this.icon, this.symbol, this.size = 22});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Widget Function(Color color)? symbol;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = TegnalColors.label.resolveFrom(context).withValues(alpha: onPressed == null ? 0.3 : 1);
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox(
          width: 36,
          height: 44,
          child: Center(
            child: symbol?.call(color) ?? Icon(icon, size: size, color: color),
          ),
        ),
      ),
    );
  }
}
