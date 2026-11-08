import 'dart:ui' show PointerDeviceKind;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

/// On a computer a mouse drags lists, pages and sheets the way a finger does, so every swipe
/// in the app, from turning a page to carrying a work to Up Next, works without a touch screen.
class TegnalScrollBehavior extends CupertinoScrollBehavior {
  const TegnalScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {...super.dragDevices, PointerDeviceKind.mouse};
}

/// The keyboard in the viewers: arrows, Page Up/Down and Space turn pages, Escape closes.
/// Left and right follow the page edge they name, so they turn the other way in right-to-left
/// reading; up, down, Page Up/Down and Space always go back and forward.
class ViewerKeys extends StatelessWidget {
  const ViewerKeys({super.key, required this.move, required this.close, required this.child, this.rightToLeft = false});
  final ValueChanged<int> move;
  final VoidCallback close;
  final bool rightToLeft;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final edge = rightToLeft ? -1 : 1;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => move(edge),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => move(-edge),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => move(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => move(-1),
        const SingleActivator(LogicalKeyboardKey.pageDown): () => move(1),
        const SingleActivator(LogicalKeyboardKey.pageUp): () => move(-1),
        const SingleActivator(LogicalKeyboardKey.space): () => move(1),
        const SingleActivator(LogicalKeyboardKey.space, shift: true): () => move(-1),
        const SingleActivator(LogicalKeyboardKey.escape): close,
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}
