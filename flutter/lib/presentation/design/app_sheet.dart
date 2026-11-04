import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';

import 'tegnal_theme.dart';

/// The iOS 26 large sheet (`.appSheet` with the large detent): it rises from the bottom to
/// just below the status bar with 40 pt top corners, over a darkened screen, and a
/// downward drag or a tap above it dismisses it.
///
/// [medium] is the medium detent instead: about half the screen, floating 8 pt inside the
/// screen edges with every corner rounded.
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required Widget Function(BuildContext context, ScrollController controller) builder,
  bool grabber = false,
  bool medium = false,
}) => Navigator.of(context, rootNavigator: true).push<T>(_AppSheetRoute<T>(builder: builder, grabber: grabber, medium: medium));

const double _cornerRadius = 40;
const double _mediumCornerRadius = 38;
const double _mediumInset = 8;

/// A medium sheet's glass: what lies behind it shows through, blurred.
const mediumSheetGlass = Color(0x1F303032);

class _AppSheetRoute<T> extends PopupRoute<T> {
  _AppSheetRoute({required this.builder, this.grabber = false, this.medium = false});
  final Widget Function(BuildContext context, ScrollController controller) builder;
  final bool medium;

  /// `.presentationDragIndicator(.visible)`.
  final bool grabber;

  @override
  Color? get barrierColor => const Color(0x66000000);
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => 'Dismiss';
  @override
  Duration get transitionDuration => const Duration(milliseconds: 420);
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 300);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) => _SheetBody(route: this);

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    return SlideTransition(
      position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(curved),
      child: child,
    );
  }
}

class _SheetBody extends StatefulWidget {
  const _SheetBody({required this.route});
  final _AppSheetRoute route;

  @override
  State<_SheetBody> createState() => _SheetBodyState();
}

class _SheetBodyState extends State<_SheetBody> {
  final _controller = ScrollController();
  double _drag = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _dragUpdate(DragUpdateDetails details) => setState(() => _drag = math.max(0, _drag + details.delta.dy));

  void _dragEnd(DragEndDetails details, double height) {
    if (_drag > height * 0.25 || (details.primaryVelocity ?? 0) > 700) {
      Navigator.of(context).pop();
    } else {
      setState(() => _drag = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final medium = widget.route.medium;
    final height = medium ? media.size.height * 0.516 : media.size.height - media.padding.top;
    final radius = medium ? const BorderRadius.all(Radius.circular(_mediumCornerRadius)) : const BorderRadius.vertical(top: Radius.circular(_cornerRadius));
    return Padding(
      padding: medium ? EdgeInsets.fromLTRB(_mediumInset, 0, _mediumInset, _mediumInset + media.viewInsets.bottom) : EdgeInsets.zero,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: AnimatedContainer(
          duration: _drag == 0 ? const Duration(milliseconds: 250) : Duration.zero,
          curve: Curves.easeOut,
          transform: Matrix4.translationValues(0, _drag, 0),
          height: height,
          child: NotificationListener<ScrollNotification>(
            // Pulling down at the top of the content drags the sheet, as on iOS.
            onNotification: (notification) {
              if (notification is OverscrollNotification && notification.overscroll < 0 && notification.dragDetails != null) {
                setState(() => _drag = math.max(0, _drag - notification.overscroll));
              } else if (notification is ScrollEndNotification && _drag > 0) {
                _dragEnd(DragEndDetails(primaryVelocity: notification.dragDetails?.primaryVelocity), height);
              }
              return false;
            },
            child: GestureDetector(
              onVerticalDragUpdate: _dragUpdate,
              onVerticalDragEnd: (details) => _dragEnd(details, height),
              child: ClipRSuperellipse(
                borderRadius: radius,
                child: BackdropFilter(
                  enabled: medium,
                  filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: MediaQuery.removePadding(
                    context: context,
                    removeTop: true,
                    child: Stack(
                      children: [
                        // The keyboard shortens the sheet's content, so a focused field scrolls above it.
                        Positioned.fill(
                          bottom: medium ? 0 : media.viewInsets.bottom,
                          // Read from the inner context: the outer one still carries the status bar's inset.
                          child: Builder(
                            builder: (inner) => MediaQuery.removeViewInsets(
                              context: inner,
                              removeBottom: true,
                              child: Builder(builder: (context) => widget.route.builder(context, _controller)),
                            ),
                          ),
                        ),
                        if (widget.route.grabber)
                          Positioned(
                            top: 5,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: Container(
                                width: 36,
                                height: 5,
                                decoration: ShapeDecoration(color: TegnalColors.tertiaryLabel.resolveFrom(context), shape: const StadiumBorder()),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
