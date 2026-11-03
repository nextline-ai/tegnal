import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/support/l10n.dart';
import 'glass.dart';
import 'tegnal_theme.dart';

/// iOS 26 grouped form colors: the sheet background and its rows.
abstract final class FormColors {
  static const background = CupertinoDynamicColor.withBrightness(color: Color(0xFFF2F2F7), darkColor: Color(0xFF1C1C1E));
  static const row = CupertinoDynamicColor.withBrightness(color: Color(0xFFFFFFFF), darkColor: Color(0xFF2C2C2E));

  /// An inset-grouped list on the screen itself, not in a sheet: rows over the system background.
  static const listRow = CupertinoDynamicColor.withBrightness(color: Color(0xFFFFFFFF), darkColor: Color(0xFF1C1C1E));
  static const listBackground = CupertinoDynamicColor.withBrightness(color: Color(0xFFF2F2F7), darkColor: Color(0xFF000000));
}

/// A `Form` section: an optional header, then rows on one rounded card with 26 pt corners.
class FormSection extends StatelessWidget {
  const FormSection({super.key, this.header, required this.children, this.footer, this.prominentHeader = false, this.rowColor});
  final Widget? header;

  /// Rows on the screen use [FormColors.listRow]; rows in sheets keep [FormColors.row].
  final Color? rowColor;

  /// A plain `Form` inside a navigation stack titles its sections in semibold, closer to the rows.
  final bool prominentHeader;
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
              padding: const EdgeInsets.only(left: 16, right: 16, bottom: 10),
              child: DefaultTextStyle(
                style: TegnalType.style(
                  17,
                  weight: prominentHeader ? FontWeight.w600 : FontWeight.w400,
                  color: TegnalColors.secondaryLabel.resolveFrom(context),
                ),
                child: header!,
              ),
            ),
          ClipRSuperellipse(
            borderRadius: BorderRadius.circular(26),
            child: ColoredBox(
              color: rowColor ?? FormColors.row.resolveFrom(context),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (index, child) in children.indexed) ...[
                    // The line under a row starts where that row's text does.
                    if (index > 0)
                      Container(
                        height: 0.5,
                        margin: EdgeInsets.only(left: children[index - 1] is FormRow ? (children[index - 1] as FormRow).separatorInset : 16, right: 16),
                        color: separator,
                      ),
                    child,
                  ],
                ],
              ),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, top: 8),
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

/// One 52 pt form row with 16 pt insets, as measured on the native forms.
class FormRow extends StatelessWidget {
  const FormRow({super.key, required this.child, this.onTap, this.separatorInset = 16, this.minHeight = 52});
  final Widget child;
  final VoidCallback? onTap;

  /// In a `List` a row whose title carries a 32 pt info button grows to about 61 pt.
  final double minHeight;

  /// Rows that lead with an icon start their separator under the title instead.
  final double separatorInset;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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

/// `SettingsInfoButton`: a secondary info glyph in a 32 pt target that explains a setting.
class FormHelpButton extends StatelessWidget {
  const FormHelpButton({super.key, required this.title, required this.message});
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: L10n.text('About %@', [title]),
    excludeSemantics: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showCupertinoDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (context) => CupertinoAlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('Done')))],
        ),
      ),
      child: SizedBox.square(
        dimension: 32,
        child: Icon(CupertinoIcons.info_circle, size: 20, color: TegnalColors.tint.resolveFrom(context).withValues(alpha: 0.6)),
      ),
    ),
  );
}

/// A sheet with its navigation bar over the content. Once the content scrolls beneath it,
/// the bar gets the iOS 26 hard scroll edge: a blurred band with a sharp lower edge.
class ScrollEdgeSheet extends StatefulWidget {
  const ScrollEdgeSheet({super.key, required this.bar, required this.child, this.background});
  final Widget bar;
  final Widget child;
  final Color? background;

  /// The band covers the bar and a little below its buttons, as the native band does.
  static const double edgeHeight = 69;

  @override
  State<ScrollEdgeSheet> createState() => _ScrollEdgeSheetState();
}

class _ScrollEdgeSheetState extends State<ScrollEdgeSheet> {
  bool _scrolled = false;

  bool _update(ScrollNotification notification) {
    if (notification.depth == 0 && notification.metrics.axis == Axis.vertical) {
      final scrolled = notification.metrics.pixels > 0.5;
      if (scrolled != _scrolled) setState(() => _scrolled = scrolled);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return ColoredBox(
      color: widget.background ?? FormColors.background.resolveFrom(context),
      child: Stack(
        children: [
          Positioned.fill(
            child: NotificationListener<ScrollNotification>(onNotification: _update, child: widget.child),
          ),
          if (_scrolled)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: ScrollEdgeSheet.edgeHeight,
              child: ClipRect(
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: ColoredBox(color: dark ? const Color(0xF0242426) : const Color(0xF0F7F7F7)),
                ),
              ),
            ),
          Positioned(left: 0, right: 0, top: 0, child: widget.bar),
        ],
      ),
    );
  }
}

/// A toolbar text button in its own glass capsule, 44 pt tall.
class GlassTextButton extends StatelessWidget {
  const GlassTextButton({super.key, required this.label, this.onPressed, this.prominent = false, this.elevated = true});
  final String label;
  final VoidCallback? onPressed;
  final bool prominent;

  /// In a sheet the glass is lighter; on a screen's toolbar it is the plain glass.
  final bool elevated;

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
          elevated: elevated,
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
