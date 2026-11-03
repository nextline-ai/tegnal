import 'package:cupertino_ui/cupertino_ui.dart';

import 'glass.dart';
import 'tegnal_theme.dart';

/// iOS 26 grouped form colors: the sheet background and its rows.
abstract final class FormColors {
  static const background = CupertinoDynamicColor.withBrightness(color: Color(0xFFF2F2F7), darkColor: Color(0xFF1C1C1E));
  static const row = CupertinoDynamicColor.withBrightness(color: Color(0xFFFFFFFF), darkColor: Color(0xFF2C2C2E));
}

/// A `Form` section: an optional header, then rows on one rounded card with 26 pt corners.
class FormSection extends StatelessWidget {
  const FormSection({super.key, this.header, required this.children, this.footer});
  final Widget? header;
  final List<Widget> children;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final separator = TegnalColors.separator.resolveFrom(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.only(left: 18, right: 18, bottom: 16),
              child: DefaultTextStyle(
                style: TegnalType.style(17, color: TegnalColors.secondaryLabel.resolveFrom(context)),
                child: header!,
              ),
            ),
          ClipRSuperellipse(
            borderRadius: BorderRadius.circular(26),
            child: ColoredBox(
              color: FormColors.row.resolveFrom(context),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (index, child) in children.indexed) ...[
                    if (index > 0) Container(height: 0.5, margin: const EdgeInsets.only(left: 18, right: 18), color: separator),
                    child,
                  ],
                ],
              ),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.only(left: 18, right: 18, top: 8),
              child: DefaultTextStyle(
                style: TegnalType.style(13, color: TegnalColors.secondaryLabel.resolveFrom(context)),
                child: footer!,
              ),
            ),
        ],
      ),
    );
  }
}

/// One 52 pt form row with 18 pt insets.
class FormRow extends StatelessWidget {
  const FormRow({super.key, required this.child, this.onTap});
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: DefaultTextStyle(
            style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context)),
            child: child,
          ),
        ),
      ),
    ),
  );
}

/// A sheet's navigation bar: glass capsule buttons on both sides and a bold title.
class SheetNavigationBar extends StatelessWidget {
  const SheetNavigationBar({super.key, required this.title, this.leading, this.trailing});
  final String title;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 76,
    width: double.infinity,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Text(
          title,
          style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
        ),
        if (leading != null) Positioned(left: 16, child: leading!),
        if (trailing != null) Positioned(right: 16, child: trailing!),
      ],
    ),
  );
}

/// A toolbar text button in its own glass capsule, 44 pt tall.
class GlassTextButton extends StatelessWidget {
  const GlassTextButton({super.key, required this.label, this.onPressed, this.prominent = false});
  final String label;
  final VoidCallback? onPressed;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final color = enabled ? TegnalColors.label.resolveFrom(context) : TegnalColors.tertiaryLabel.resolveFrom(context);
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Glass.capsule(
          child: SizedBox(
            height: 44,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Center(
                widthFactor: 1,
                child: Text(
                  label,
                  style: TegnalType.style(17, weight: prominent ? FontWeight.w600 : FontWeight.w400, color: color),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
