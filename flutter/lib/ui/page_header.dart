import 'package:material_ui/material_ui.dart';

import '../core/app_controller.dart';
import '../core/content.dart';
import 'common.dart';
import 'l10n.dart';

/// Fixed vertical extent of the compact floating page header.
const double tegnalHeaderExtent = 64;

/// Keeps root navigation chrome above scrolling content while allowing the
/// optional search control to tuck away on downward scroll.
class TegnalFloatingHeader extends StatefulWidget {
  const TegnalFloatingHeader({
    super.key,
    required this.header,
    required this.child,
    this.search,
    this.searchFocusNode,
  });

  final Widget header;
  final Widget child;
  final Widget? search;
  final FocusNode? searchFocusNode;

  @override
  State<TegnalFloatingHeader> createState() => _TegnalFloatingHeaderState();
}

class _TegnalFloatingHeaderState extends State<TegnalFloatingHeader> {
  static const double _scrollHysteresis = 10;
  bool _searchVisible = true;
  double _directionDistance = 0;
  int _direction = 0;

  @override
  void initState() {
    super.initState();
    widget.searchFocusNode?.addListener(_onSearchFocusChanged);
  }

  @override
  void didUpdateWidget(covariant TegnalFloatingHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchFocusNode != widget.searchFocusNode) {
      oldWidget.searchFocusNode?.removeListener(_onSearchFocusChanged);
      widget.searchFocusNode?.addListener(_onSearchFocusChanged);
    }
    if (oldWidget.search == null && widget.search != null) {
      _setSearchVisible(true);
    } else if (widget.search == null) {
      _setSearchVisible(true);
    }
  }

  @override
  void dispose() {
    widget.searchFocusNode?.removeListener(_onSearchFocusChanged);
    super.dispose();
  }

  void _onSearchFocusChanged() {
    if (widget.searchFocusNode?.hasFocus == true) _setSearchVisible(true);
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification is! ScrollUpdateNotification ||
        notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (widget.searchFocusNode?.hasFocus == true) {
      _setSearchVisible(true);
      return false;
    }
    final offset = notification.metrics.pixels;
    if (offset <= _scrollHysteresis) {
      _direction = 0;
      _directionDistance = 0;
      _setSearchVisible(true);
      return false;
    }
    final delta = notification.scrollDelta ?? 0;
    if (delta.abs() < .1) return false;
    final direction = delta > 0 ? 1 : -1;
    if (direction != _direction) {
      _direction = direction;
      _directionDistance = 0;
    }
    _directionDistance += delta.abs();
    if (_directionDistance >= _scrollHysteresis) {
      _setSearchVisible(direction < 0);
    }
    return false;
  }

  void _setSearchVisible(bool visible) {
    if (!mounted || visible == _searchVisible) return;
    setState(() => _searchVisible = visible);
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Positioned.fill(
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: widget.child,
        ),
      ),
      if (widget.search case final search?)
        Positioned(
          top: tegnalHeaderExtent,
          left: 16,
          right: 16,
          child: ClipRect(
            child: AnimatedSlide(
              offset: _searchVisible ? Offset.zero : const Offset(0, -1.15),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: IgnorePointer(
                ignoring: !_searchVisible,
                child: ExcludeSemantics(
                  excluding: !_searchVisible,
                  child: search,
                ),
              ),
            ),
          ),
        ),
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        height: tegnalHeaderExtent,
        child: widget.header,
      ),
    ],
  );
}

/// The mode switch stays centered regardless of the root's trailing actions.
class TegnalPageHeader extends StatelessWidget {
  const TegnalPageHeader({
    super.key,
    required this.controller,
    required this.title,
    this.trailing,
    this.mode,
  });
  final AppController controller;
  final String title;
  final AppMode? mode;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey('tegnal-page-header'),
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
    child: LayoutBuilder(
      builder: (context, constraints) {
        const switchWidth = 96.0;
        final sideWidth = (constraints.maxWidth - switchWidth) / 2;
        return ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Row(
            children: [
              SizedBox(
                width: sideWidth,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ChromeSurface(
                    enabled: false,
                    borderRadius: BorderRadius.circular(28),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Semantics(
                        header: true,
                        child: Text(
                          L10n.tr(context, title),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              _ModeSwitch(controller: controller),
              SizedBox(
                width: sideWidth,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: trailing == null
                      ? const SizedBox(height: 48)
                      : ChromeSurface(
                          enabled: false,
                          borderRadius: BorderRadius.circular(28),
                          child: IconTheme(
                            data: IconThemeData(
                              size: 30,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                            child: trailing!,
                          ),
                        ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

class _ModeSwitch extends StatefulWidget {
  const _ModeSwitch({required this.controller});
  final AppController controller;

  @override
  State<_ModeSwitch> createState() => _ModeSwitchState();
}

class _ModeSwitchState extends State<_ModeSwitch> {
  static const double _horizontalSlop = 18;
  static const double _minimumFlingVelocity = 500;
  int? _activePointer;
  Offset? _pointerStart;
  Offset? _pointerLast;
  Duration? _pointerStartTime;
  bool _suppressTap = false;

  void _setMode(AppMode mode) {
    if (widget.controller.mode != mode) widget.controller.setMode(mode);
  }

  void _toggleMode() => _setMode(
    widget.controller.mode == AppMode.manga ? AppMode.booru : AppMode.manga,
  );

  void _pointerDown(PointerDownEvent event) {
    if (_activePointer != null) {
      // Multi-touch is never a mode gesture or a tap.
      _activePointer = null;
      _pointerStart = null;
      _pointerLast = null;
      _pointerStartTime = null;
      _suppressTap = true;
      return;
    }
    _activePointer = event.pointer;
    _pointerStart = event.position;
    _pointerLast = event.position;
    _pointerStartTime = event.timeStamp;
    _suppressTap = false;
  }

  void _pointerMove(PointerMoveEvent event) {
    if (event.pointer != _activePointer) return;
    _pointerLast = event.position;
    final start = _pointerStart;
    if (start == null) return;
    final delta = event.position - start;
    if (delta.dx.abs() > _horizontalSlop && delta.dx.abs() > delta.dy.abs()) {
      // The tap recognizer will usually lose the arena after slop, but the
      // raw listener also handles fast gestures which can end before that.
      _suppressTap = true;
    }
  }

  void _pointerUp(PointerUpEvent event) {
    if (event.pointer != _activePointer) return;
    final start = _pointerStart;
    final last = _pointerLast;
    final startTime = _pointerStartTime;
    _clearPointer();
    if (start == null || last == null || startTime == null) return;

    final delta = last - start;
    if (delta.dx.abs() <= delta.dy.abs()) return;
    final elapsed = (event.timeStamp - startTime).inMicroseconds;
    final velocity = elapsed > 0 ? delta.dx * 1000000 / elapsed : 0.0;
    if (delta.dx.abs() >= _horizontalSlop ||
        velocity.abs() >= _minimumFlingVelocity) {
      _suppressTap = true;
      _setMode(delta.dx > 0 ? AppMode.booru : AppMode.manga);
    }
  }

  void _pointerCancel(PointerCancelEvent event) {
    if (event.pointer == _activePointer) _clearPointer();
  }

  void _clearPointer() {
    _activePointer = null;
    _pointerStart = null;
    _pointerLast = null;
    _pointerStartTime = null;
  }

  void _onTap() {
    if (_suppressTap) {
      _suppressTap = false;
      return;
    }
    _toggleMode();
  }

  @override
  Widget build(BuildContext context) {
    final activeMode = widget.controller.mode;
    final comics = L10n.tr(context, 'Comics');
    final images = L10n.tr(context, 'Images');
    return SizedBox(
      key: const ValueKey('mode-switch'),
      width: 96,
      height: 48,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _pointerDown,
        onPointerMove: _pointerMove,
        onPointerUp: _pointerUp,
        onPointerCancel: _pointerCancel,
        child: Semantics(
          button: true,
          label: L10n.tr(context, 'Mode'),
          value: activeMode == AppMode.manga ? comics : images,
          hint: '$comics / $images',
          onTap: _toggleMode,
          child: ExcludeSemantics(
            child: Material(
              color: Theme.of(context).colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(24),
              child: InkWell(
                key: const ValueKey('mode-switch-tap'),
                borderRadius: BorderRadius.circular(24),
                onTap: _onTap,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Row(
                    children: [
                      _modeIcon(
                        context,
                        mode: AppMode.manga,
                        activeMode: activeMode,
                        label: comics,
                        icon: Icons.menu_book_rounded,
                      ),
                      _modeIcon(
                        context,
                        mode: AppMode.booru,
                        activeMode: activeMode,
                        label: images,
                        icon: Icons.photo_library_rounded,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _modeIcon(
    BuildContext context, {
    required AppMode mode,
    required AppMode activeMode,
    required String label,
    required IconData icon,
  }) {
    final selected = mode == activeMode;
    final colors = Theme.of(context).colorScheme;
    return Expanded(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 40,
        decoration: BoxDecoration(
          color: selected ? colors.onSurface : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        alignment: Alignment.center,
        child: Tooltip(
          message: label,
          child: Icon(
            icon,
            size: 28,
            color: selected ? colors.surface : colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
