import 'package:cupertino_ui/cupertino_ui.dart';

import 'glass.dart';
import 'system_colors.dart';
import 'tegnal_theme.dart';

/// The iOS 26 alert: a glass panel with a centered title and message over capsule
/// buttons. It takes the same title, content and [CupertinoDialogAction]s as
/// [CupertinoAlertDialog], which still draws the older iOS style.
class TegnalAlertDialog extends StatelessWidget {
  const TegnalAlertDialog({super.key, this.title, this.content, this.actions = const []});
  final Widget? title;
  final Widget? content;
  final List<Widget> actions;

  static const double _width = 318;
  static const double _inset = 16;
  static const double _buttonHeight = 48;
  static const double _buttonGap = 8;

  static const _buttonFill = CupertinoDynamicColor.withBrightness(color: Color(0x14000000), darkColor: Color(0x1FFFFFFF));

  /// Two buttons sit side by side with the cancel button first, as UIKit orders them.
  List<Widget> get _ordered {
    if (actions.length == 2 && _destructive(actions[0]) && !_destructive(actions[1])) return [actions[1], actions[0]];
    return actions;
  }

  static bool _destructive(Widget action) => action is CupertinoDialogAction && action.isDestructiveAction;

  @override
  Widget build(BuildContext context) {
    final label = TegnalColors.label.resolveFrom(context);
    final media = MediaQuery.of(context);
    final width = (media.size.width - 2 * 42).clamp(240.0, _width);
    final ordered = _ordered;
    final titleStyle = TegnalType.style(17, color: label);
    final buttonStyle = TegnalType.style(17, color: label);
    final inRow = ordered.length == 2 && ordered.every((action) => _fits(action, buttonStyle, (width - 2 * _inset - _buttonGap) / 2 - 24, media.textScaler));
    final buttons = [for (final action in ordered) _button(context, action, buttonStyle)];
    return Center(
      child: Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: SizedBox(
          width: width,
          child: Glass.surface(
            cornerRadius: 34,
            elevated: true,
            blur: 20,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(_inset, 20, _inset, _inset),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (title != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: DefaultTextStyle(style: titleStyle, textAlign: TextAlign.center, child: title!),
                    ),
                  if (content != null) ...[
                    SizedBox(height: title == null ? 0 : 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: DefaultTextStyle(
                        style: TegnalType.style(15, color: label.withValues(alpha: 0.85)).copyWith(height: 1.3),
                        textAlign: TextAlign.center,
                        child: content!,
                      ),
                    ),
                  ],
                  if (buttons.isNotEmpty) ...[
                    SizedBox(height: title == null && content == null ? 0 : 20),
                    if (inRow)
                      Row(
                        children: [
                          Expanded(child: buttons[0]),
                          const SizedBox(width: _buttonGap),
                          Expanded(child: buttons[1]),
                        ],
                      )
                    else
                      for (final (index, button) in buttons.indexed) ...[if (index > 0) const SizedBox(height: _buttonGap), button],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static bool _fits(Widget action, TextStyle style, double width, TextScaler scaler) {
    if (action is! CupertinoDialogAction || action.child is! Text) return true;
    final text = (action.child as Text).data ?? '';
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final fits = painter.width <= width;
    painter.dispose();
    return fits;
  }

  Widget _button(BuildContext context, Widget action, TextStyle style) {
    if (action is! CupertinoDialogAction) return action;
    final enabled = action.onPressed != null;
    // Glass lifts the destructive red toward coral in the dark appearance.
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final red = SystemColors.red.resolveFrom(context);
    final color = action.isDestructiveAction ? (dark ? Color.lerp(red, const Color(0xFFFFFFFF), 0.25) : red) : style.color;
    return Semantics(
      button: true,
      enabled: enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: action.onPressed,
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: Container(
            height: _buttonHeight,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: ShapeDecoration(color: _buttonFill.resolveFrom(context), shape: const StadiumBorder()),
            alignment: Alignment.center,
            child: DefaultTextStyle(
              style: style.copyWith(color: color),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              child: action.child,
            ),
          ),
        ),
      ),
    );
  }
}
