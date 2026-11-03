import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';

import 'symbols.dart';
import 'tegnal_theme.dart';

/// One choice in a [showPullDownMenu].
class PullDownMenuItem<T> {
  const PullDownMenuItem({required this.value, required this.title, this.checked = false});
  final T value;
  final String title;
  final bool checked;
}

/// The iOS 26 pull-down menu a `Menu` with a `Picker` opens: a large glass panel that grows
/// out of its button, covering it, at least 250 pt wide with 42 pt rows and no dividers.
Future<T?> showPullDownMenu<T>(BuildContext context, {required Rect anchor, required List<PullDownMenuItem<T>> items}) {
  return Navigator.of(context).push<T>(_PullDownMenuRoute<T>(anchor: anchor, items: items));
}

/// The global rectangle of the widget that owns `context`.
Rect anchorRectOf(BuildContext context) {
  final box = context.findRenderObject()! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

const double _rowHeight = 42;
const double _verticalPadding = 9.5;
const double _minimumWidth = 250;
const double _radius = 32;

class _PullDownMenuRoute<T> extends PopupRoute<T> {
  _PullDownMenuRoute({required this.anchor, required this.items});
  final Rect anchor;
  final List<PullDownMenuItem<T>> items;

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
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final screen = MediaQuery.sizeOf(context);
    final style = TegnalType.style(17, color: TegnalColors.label.resolveFrom(context));
    final textWidth = items
        .map((item) {
          final painter = TextPainter(
            text: TextSpan(text: item.title, style: style),
            textDirection: TextDirection.ltr,
            textScaler: MediaQuery.textScalerOf(context),
          )..layout();
          return painter.width;
        })
        .fold<double>(0, math.max);
    final width = math.min(screen.width - 32, math.max(_minimumWidth, textWidth + 43 + 40));
    final height = items.length * _rowHeight + _verticalPadding * 2;
    final left = anchor.left.clamp(16.0, math.max(16.0, screen.width - 16 - width)).toDouble();
    final top = math.min(anchor.top, screen.height - height - 16);
    final origin = Alignment(((anchor.center.dx - left) / width) * 2 - 1, -1);
    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          width: width,
          height: height,
          child: AnimatedBuilder(
            animation: animation,
            builder: (context, child) {
              final grow = Curves.easeOutBack.transform(animation.value).clamp(0.0, 1.08);
              return Opacity(
                opacity: Curves.easeOut.transform(animation.value),
                child: Transform.scale(scale: 0.6 + 0.4 * grow, alignment: origin, child: child),
              );
            },
            child: _MenuPanel<T>(items: items, style: style, onSelected: (value) => Navigator.of(context).pop(value)),
          ),
        ),
      ],
    );
  }
}

class _MenuPanel<T> extends StatelessWidget {
  const _MenuPanel({required this.items, required this.style, required this.onSelected});
  final List<PullDownMenuItem<T>> items;
  final TextStyle style;
  final ValueChanged<T> onSelected;

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
              color: dark ? const Color(0xB0303030) : const Color(0xD9F7F7F7),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: _verticalPadding),
              child: Column(
                children: [for (final item in items) _MenuRow<T>(item: item, style: style, onSelected: onSelected)],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuRow<T> extends StatefulWidget {
  const _MenuRow({required this.item, required this.style, required this.onSelected});
  final PullDownMenuItem<T> item;
  final TextStyle style;
  final ValueChanged<T> onSelected;

  @override
  State<_MenuRow<T>> createState() => _MenuRowState<T>();
}

class _MenuRowState<T> extends State<_MenuRow<T>> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final label = TegnalColors.label.resolveFrom(context);
    return Semantics(
      button: true,
      selected: widget.item.checked,
      label: widget.item.title,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: () => widget.onSelected(widget.item.value),
        child: Container(
          height: _rowHeight,
          margin: const EdgeInsets.symmetric(horizontal: 8),
          decoration: ShapeDecoration(color: _pressed ? label.withValues(alpha: 0.12) : null, shape: const StadiumBorder()),
          child: Row(
            children: [
              SizedBox(
                width: 35,
                child: widget.item.checked
                    ? Padding(
                        padding: const EdgeInsets.only(left: 10),
                        child: Icon(Symbols.checkmark, size: 19, color: label),
                      )
                    : null,
              ),
              Expanded(
                child: Text(widget.item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: widget.style),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
