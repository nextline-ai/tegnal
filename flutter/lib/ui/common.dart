import 'dart:ui';

import 'package:material_ui/material_ui.dart';

import 'l10n.dart';

/// Height of the floating tab dock; scrollable screens use this to keep their
/// final row clear of the overlay without shrinking the whole viewport.
const double tegnalCompactDockHeight = 62;

/// Trailing scroll space needed beneath the floating dock on compact layouts.
/// Wide layouts use a small conventional list tail because their sidebar does
/// not overlap content. While the keyboard is open, the dock is hidden.
double navigationScrollInset(BuildContext context, {double gap = 16}) {
  final media = MediaQuery.of(context);
  if (media.size.width >= 840 || media.viewInsets.bottom > 0) return gap;
  final safeBottom = media.viewPadding.bottom.clamp(12.0, double.infinity);
  return tegnalCompactDockHeight + safeBottom + gap;
}

/// Keeps keyboard/safe-area dependencies on the small scroll tail instead of
/// rebuilding the database-backed library screen on every inset animation tick.
class NavigationScrollSpacer extends StatelessWidget {
  const NavigationScrollSpacer({super.key, this.gap = 16});
  final double gap;
  @override
  Widget build(BuildContext context) =>
      SizedBox(height: navigationScrollInset(context, gap: gap));
}

/// Material back control with localized semantics and standard route behavior.
class TegnalBackButton extends StatelessWidget {
  const TegnalBackButton({super.key});

  @override
  Widget build(BuildContext context) => ChromeSurface(
    enabled: false,
    borderRadius: BorderRadius.circular(24),
    child: SizedBox(
      width: 44,
      height: 44,
      child: BackButton(
        color: Theme.of(context).colorScheme.onSurface,
        onPressed: () => Navigator.of(context).maybePop(),
      ),
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 60, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 20),
            Text(
              L10n.tr(context, title),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            if (message != null) ...[
              const SizedBox(height: 10),
              Text(
                L10n.tr(context, message!),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 22), action!],
          ],
        ),
      ),
    ),
  );
}

Future<void> showMessage(BuildContext context, String title, String message) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(L10n.tr(context, title)),
        content: Text(L10n.tr(context, message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(L10n.tr(context, 'OK')),
          ),
        ],
      ),
    );

Future<bool> confirmAction(
  BuildContext context,
  String title,
  String message, {
  String action = 'Delete',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(L10n.tr(context, title)),
        content: Text(L10n.tr(context, message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(L10n.tr(context, 'Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(L10n.tr(context, action)),
          ),
        ],
      ),
    ) ??
    false;

/// Material surface colors with optional bounded blur for floating navigation.
class ChromeSurface extends StatelessWidget {
  const ChromeSurface({
    super.key,
    required this.enabled,
    required this.child,
    this.borderRadius = BorderRadius.zero,
    this.respectReduceMotion = true,
  });
  final bool enabled;
  final Widget child;
  final BorderRadius borderRadius;
  final bool respectReduceMotion;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = enabled && dark
        ? const Color(0xFF29292B)
        : Theme.of(context).colorScheme.surfaceContainer;
    final translucent =
        enabled &&
        (!respectReduceMotion || !MediaQuery.disableAnimationsOf(context)) &&
        !MediaQuery.highContrastOf(context);
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: translucent ? 0.76 : 1),
        borderRadius: borderRadius,
        border: Border.all(
          color: (dark ? Colors.white : Colors.black).withValues(
            alpha: translucent ? 0.14 : 0.04,
          ),
          width: 0.5,
        ),
      ),
      child: child,
    );
    return ClipRRect(
      borderRadius: borderRadius,
      child: translucent
          ? BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: surface,
            )
          : surface,
    );
  }
}
