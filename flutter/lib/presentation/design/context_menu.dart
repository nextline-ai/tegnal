import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import 'symbols.dart';
import 'system_colors.dart';
import 'tegnal_theme.dart';

/// One row of a [showContextMenu]. A row with [children] opens them as a submenu.
class ContextMenuAction {
  const ContextMenuAction({required this.title, this.icon, this.symbol, this.onSelected, this.destructive = false, this.checked = false, this.children});
  final String title;
  final IconData? icon;

  /// A drawn symbol for SF Symbols without a Cupertino icon.
  final Widget Function(Color color)? symbol;
  final VoidCallback? onSelected;
  final bool destructive;
  final bool checked;
  final List<ContextMenuAction>? children;
}

/// The iOS 26 `contextMenu`: the held view lifts above a dimmed screen and a glass menu
/// of 42 pt rows, at least 250 pt wide, opens 17 pt from it on the side with room.
///
/// [preview] replaces the lifted copy when the native menu shows a separate preview,
/// as works do; otherwise [child] is lifted at [lift] times its size.
Future<void> showContextMenu(
  BuildContext context, {
  required Rect anchor,
  required List<ContextMenuAction> actions,
  required Widget child,
  Widget? preview,
  Size? previewSize,
  double lift = 1.15,
}) {
  HapticFeedback.mediumImpact();
  return Navigator.of(
    context,
    rootNavigator: true,
  ).push(_ContextMenuRoute(anchor: anchor, actions: actions, child: child, preview: preview, previewSize: previewSize, lift: lift));
}

/// A toolbar `Menu` of actions: the same glass panel, growing out of its button without
/// lifting anything or dimming the screen.
Future<void> showActionMenu(BuildContext context, {required Rect anchor, required List<ContextMenuAction> actions}) =>
    Navigator.of(context, rootNavigator: true).push(_ActionMenuRoute(anchor: anchor, actions: actions));

class _ActionMenuRoute extends PopupRoute<void> {
  _ActionMenuRoute({required this.anchor, required this.actions});
  final Rect anchor;
  final List<ContextMenuAction> actions;

  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => 'Dismiss';
  @override
  Duration get transitionDuration => const Duration(milliseconds: 260);
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 180);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      _ActionMenuLayout(anchor: anchor, actions: actions, animation: animation);
}

class _ActionMenuLayout extends StatefulWidget {
  const _ActionMenuLayout({required this.anchor, required this.actions, required this.animation});
  final Rect anchor;
  final List<ContextMenuAction> actions;
  final Animation<double> animation;

  @override
  State<_ActionMenuLayout> createState() => _ActionMenuLayoutState();
}

class _ActionMenuLayoutState extends State<_ActionMenuLayout> {
  ContextMenuAction? _submenu;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final style = TegnalType.style(17, color: TegnalColors.label.resolveFrom(context));
    final rows = [if (_submenu != null) ContextMenuAction(title: _submenu!.title), ...(_submenu?.children ?? widget.actions)];
    double extent(ContextMenuAction row) {
      final painter = TextPainter(
        text: TextSpan(text: row.title, style: style),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 2,
      )..layout(maxWidth: _menuWidth - 63 - 40);
      return painter.computeLineMetrics().length > 1 ? _rowHeight + 22 : _rowHeight;
    }

    final height = math.min(screen.height - 32, rows.fold<double>(0, (sum, row) => sum + extent(row)) + _verticalPadding * 2);
    final left = (widget.anchor.center.dx > screen.width / 2 ? widget.anchor.right - _menuWidth : widget.anchor.left)
        .clamp(_margin, screen.width - _margin - _menuWidth)
        .toDouble();
    final top = math.min(widget.anchor.top, screen.height - height - 16);
    final origin = Alignment(((widget.anchor.center.dx - left) / _menuWidth) * 2 - 1, -1);
    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          width: _menuWidth,
          height: height,
          child: AnimatedBuilder(
            animation: widget.animation,
            builder: (context, child) {
              final grow = Curves.easeOutBack.transform(widget.animation.value).clamp(0.0, 1.08);
              return Opacity(
                opacity: Curves.easeOut.transform(widget.animation.value),
                child: Transform.scale(scale: 0.6 + 0.4 * grow, alignment: origin, child: child),
              );
            },
            child: _MenuPanel(
              rows: rows,
              style: style,
              hasHeader: _submenu != null,
              extent: extent,
              onSelected: (action) {
                if (action.children != null) {
                  setState(() => _submenu = action);
                  return;
                }
                Navigator.of(context).pop();
                action.onSelected?.call();
              },
              onBack: () => setState(() => _submenu = null),
            ),
          ),
        ),
      ],
    );
  }
}

const double _rowHeight = 42;
const double _verticalPadding = 9.5;
const double _menuWidth = 250;
const double _radius = 32;
const double _gap = 17;
const double _margin = 16;

class _ContextMenuRoute extends PopupRoute<void> {
  _ContextMenuRoute({required this.anchor, required this.actions, required this.child, this.preview, this.previewSize, required this.lift});
  final Rect anchor;
  final List<ContextMenuAction> actions;
  final Widget child;
  final Widget? preview;
  final Size? previewSize;
  final double lift;

  @override
  Color? get barrierColor => const Color(0x73000000);
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => 'Dismiss';
  @override
  Duration get transitionDuration => const Duration(milliseconds: 320);
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 200);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      _ContextMenuLayout(anchor: anchor, actions: actions, preview: preview, previewSize: previewSize, lift: lift, animation: animation, child: child);
}

class _ContextMenuLayout extends StatefulWidget {
  const _ContextMenuLayout({
    required this.anchor,
    required this.actions,
    required this.child,
    required this.preview,
    required this.previewSize,
    required this.lift,
    required this.animation,
  });
  final Rect anchor;
  final List<ContextMenuAction> actions;
  final Widget child;
  final Widget? preview;
  final Size? previewSize;
  final double lift;
  final Animation<double> animation;

  @override
  State<_ContextMenuLayout> createState() => _ContextMenuLayoutState();
}

class _ContextMenuLayoutState extends State<_ContextMenuLayout> {
  ContextMenuAction? _submenu;

  List<ContextMenuAction> get _rows => _submenu?.children ?? widget.actions;

  double _rowExtent(BuildContext context, ContextMenuAction action, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: action.title, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 2,
    )..layout(maxWidth: _menuWidth - 63 - 40);
    return painter.computeLineMetrics().length > 1 ? _rowHeight + 22 : _rowHeight;
  }

  void _select(ContextMenuAction action) {
    if (action.children != null) {
      HapticFeedback.selectionClick();
      setState(() => _submenu = action);
      return;
    }
    Navigator.of(context).pop();
    action.onSelected?.call();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    final style = TegnalType.style(17, color: TegnalColors.label.resolveFrom(context));
    final rows = [if (_submenu != null) ContextMenuAction(title: _submenu!.title), ..._rows];
    final menuHeight = rows.fold<double>(0, (sum, row) => sum + _rowExtent(context, row, style)) + _verticalPadding * 2;

    // The lifted view grows around its center but stays inside the screen margins.
    final size = widget.previewSize ?? widget.anchor.size * widget.lift;
    var previewLeft = widget.anchor.center.dx - size.width / 2;
    previewLeft = previewLeft.clamp(_margin, math.max(_margin, screen.width - _margin - size.width)).toDouble();
    // The preview centers on the held view, as iOS places a lifted or custom preview.
    var previewTop = widget.anchor.center.dy - size.height / 2;
    final top = media.padding.top + 8;
    final bottom = screen.height - math.max(media.padding.bottom, 34) - 8;
    final menuBelow = previewTop + size.height + _gap + menuHeight <= bottom || previewTop - _gap - menuHeight < top;
    if (menuBelow) {
      previewTop = math.min(previewTop, bottom - menuHeight - _gap - size.height);
    }
    previewTop = math.max(top, previewTop);
    final menuTop = menuBelow ? previewTop + size.height + _gap : previewTop - _gap - menuHeight;
    // The menu lines up with the side of the preview nearer the screen's edge.
    final leading = previewLeft + size.width / 2 <= screen.width / 2;
    final menuLeft = (leading ? previewLeft : previewLeft + size.width - _menuWidth).clamp(_margin, screen.width - _margin - _menuWidth).toDouble();

    return AnimatedBuilder(
      animation: widget.animation,
      builder: (context, _) {
        final t = Curves.easeOutCubic.transform(widget.animation.value);
        final grow = Curves.easeOutBack.transform(widget.animation.value);
        final from = widget.anchor;
        final rect = Rect.lerp(from, Rect.fromLTWH(previewLeft, previewTop, size.width, size.height), widget.preview == null ? grow : t)!;
        return Stack(
          children: [
            // A separate preview takes the held view off the screen while the menu is open.
            if (widget.preview != null)
              Positioned.fromRect(
                rect: widget.anchor,
                child: IgnorePointer(
                  child: ColoredBox(color: Color.alphaBlend(const Color(0x73000000), TegnalColors.background.resolveFrom(context)).withValues(alpha: t)),
                ),
              ),
            Positioned.fromRect(
              rect: rect,
              child: IgnorePointer(
                child: widget.preview == null
                    ? FittedBox(
                        fit: BoxFit.fill,
                        child: SizedBox(width: from.width, height: from.height, child: widget.child),
                      )
                    : Opacity(opacity: t, child: widget.preview),
              ),
            ),
            Positioned(
              left: menuLeft,
              top: menuTop,
              width: _menuWidth,
              height: menuHeight,
              child: Opacity(
                opacity: t,
                child: Transform.scale(
                  scale: 0.7 + 0.3 * grow.clamp(0.0, 1.05),
                  alignment: Alignment(leading ? -1 : 1, menuBelow ? -1 : 1),
                  child: _MenuPanel(
                    rows: rows,
                    style: style,
                    hasHeader: _submenu != null,
                    extent: (row) => _rowExtent(context, row, style),
                    onSelected: _select,
                    onBack: () => setState(() => _submenu = null),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MenuPanel extends StatelessWidget {
  const _MenuPanel({required this.rows, required this.style, required this.hasHeader, required this.extent, required this.onSelected, required this.onBack});
  final List<ContextMenuAction> rows;
  final TextStyle style;
  final bool hasHeader;
  final double Function(ContextMenuAction row) extent;
  final ValueChanged<ContextMenuAction> onSelected;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    const shape = RoundedSuperellipseBorder(borderRadius: BorderRadius.all(Radius.circular(_radius)));
    return DecoratedBox(
      decoration: const ShapeDecoration(
        shape: shape,
        shadows: [BoxShadow(color: Color(0x33000000), blurRadius: 40, offset: Offset(0, 12))],
      ),
      child: ClipPath(
        clipper: const ShapeBorderClipper(shape: shape),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: DecoratedBox(
            decoration: ShapeDecoration(
              shape: shape.copyWith(side: BorderSide(color: dark ? const Color(0x1FFFFFFF) : const Color(0x14000000), width: 0.5)),
              color: dark ? const Color(0xE0232325) : const Color(0xE6F7F7F7),
            ),
            // A long folder list scrolls inside the panel instead of running off the screen.
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: _verticalPadding),
              child: Column(
                children: [
                  for (final (index, row) in rows.indexed)
                    _MenuRow(
                      key: ValueKey('${hasHeader && index == 0}:$index:${row.title}'),
                      action: row,
                      style: style,
                      height: extent(row),
                      isHeader: hasHeader && index == 0,
                      onTap: hasHeader && index == 0 ? onBack : () => onSelected(row),
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

class _MenuRow extends StatefulWidget {
  const _MenuRow({super.key, required this.action, required this.style, required this.height, required this.isHeader, required this.onTap});
  final ContextMenuAction action;
  final TextStyle style;
  final double height;
  final bool isHeader;
  final VoidCallback onTap;

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final action = widget.action;
    final label = TegnalColors.label.resolveFrom(context);
    final color = action.destructive ? SystemColors.red.resolveFrom(context) : label;
    final enabled = widget.isHeader || action.onSelected != null || action.children != null;
    final icon = widget.isHeader ? CupertinoIcons.chevron_left : (action.checked ? Symbols.checkmark : action.icon);
    return Semantics(
      button: true,
      enabled: enabled,
      selected: action.checked,
      label: action.title,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapCancel: () => setState(() => _pressed = false),
        onTap: enabled ? widget.onTap : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: Container(
            height: widget.height,
            margin: const EdgeInsets.symmetric(horizontal: 8),
            decoration: ShapeDecoration(
              color: _pressed ? label.withValues(alpha: 0.12) : null,
              shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(widget.height / 2)),
            ),
            child: Row(
              children: [
                // Icons center 39 pt into the menu and titles start at 63 pt, as measured.
                const SizedBox(width: 20),
                SizedBox(
                  width: 22,
                  child: action.symbol != null && !widget.isHeader && !action.checked
                      ? Center(child: action.symbol!(color))
                      : icon == null
                      ? null
                      : Center(child: Icon(icon, size: 21, color: color)),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Text(
                    action.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: widget.isHeader ? widget.style.copyWith(fontWeight: FontWeight.w600) : widget.style.copyWith(color: color),
                  ),
                ),
                if (action.children != null && !widget.isHeader) Icon(CupertinoIcons.chevron_right, size: 15, color: label),
                const SizedBox(width: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
