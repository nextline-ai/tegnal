import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../../core/support/l10n.dart';
import '../design/glass.dart';
import '../design/symbols.dart';
import '../design/tegnal_theme.dart';
import '../../core/content/reading_queue.dart';
import '../content/reading_queue_views.dart';
import 'app_state.dart';

/// Height of the floating tab bar, and its distance from the bottom edge on a phone.
const double tabBarHeight = 62;
const double _tabBarGap = 21;

/// Space a scrolling root screen leaves under its content for the floating tab bar, and for the
/// Up Next bar above it while works wait.
double tabBarClearance(BuildContext context) => tabBarHeight + _bottomGap(context) + 16 + ReadingQueueInset.of(context);

double _bottomGap(BuildContext context) => math.max(_tabBarGap, MediaQuery.paddingOf(context).bottom - 13);

/// The root of each library: five destinations kept alive while switching, under
/// the iOS 26 floating tab bar with Smart in its own circle.
class RootTabView extends StatelessWidget {
  const RootTabView({super.key, required this.state, required this.pages, this.queue, this.readQueued, this.showQueue});
  final AppState state;
  final Map<AppTab, Widget> pages;

  /// Comics' Up Next, which sits above the tabs where a music app keeps what plays next.
  final ReadingQueue? queue;
  final void Function(BuildContext context, int id)? readQueued;
  final void Function(BuildContext context)? showQueue;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([state, ?queue]),
      builder: (context, _) {
        final tabs = AppTab.values;
        final queue = this.queue;
        final next = queue?.items.firstOrNull;
        // The bar steps aside while a work is carried to the larger panel in its place.
        final showsBar = next != null && queue?.carried == null;
        final inset = queue == null || queue.isEmpty ? 0.0 : readingQueueBarHeight + 8;
        return Stack(
          children: [
            Positioned.fill(
              // Lists end above the bar and notices rise above it. The room follows the list, not
              // a carried work, so the screen never shifts under the finger.
              child: ReadingQueueInset(
                height: inset,
                child: IndexedStack(index: tabs.indexOf(state.tab), children: [for (final tab in tabs) pages[tab] ?? const SizedBox.shrink()]),
              ),
            ),
            if (queue != null)
              Positioned(
                left: _tabBarGap,
                right: _tabBarGap,
                bottom: _bottomGap(context) + tabBarHeight + 8,
                child: IgnorePointer(
                  ignoring: !showsBar,
                  child: AnimatedSlide(
                    offset: showsBar ? Offset.zero : const Offset(0, 0.4),
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    child: AnimatedOpacity(
                      opacity: showsBar ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: next == null
                          ? const SizedBox(height: readingQueueBarHeight)
                          : ReadingQueueBar(queue: queue, next: next, read: (id) => readQueued?.call(context, id), showList: () => showQueue?.call(context)),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: _bottomGap(context),
              child: FloatingTabBar(state: state),
            ),
            if (queue != null)
              Positioned.fill(
                child: ReadingQueueCarryOverlay(queue: queue, bottom: _bottomGap(context) + tabBarHeight + 4),
              ),
          ],
        );
      },
    );
  }
}

class _TabItem {
  const _TabItem(this.tab, this.title, this.icon);
  final AppTab tab;
  final String title;
  final IconData icon;
}

/// The floating tab bar. As on iOS 26, a finger can slide along the capsule: the selection
/// follows it, each tab it crosses ticks, and the tab under it opens when it lifts.
class FloatingTabBar extends StatefulWidget {
  const FloatingTabBar({super.key, required this.state});
  final AppState state;

  @override
  State<FloatingTabBar> createState() => _FloatingTabBarState();
}

class _FloatingTabBarState extends State<FloatingTabBar> {
  /// The finger's position along the tabs while it slides, and the tab under it.
  double? _dragX;
  int? _hovered;

  AppState get state => widget.state;

  List<_TabItem> get _items {
    final booru = state.mode == AppMode.booru;
    return [
      _TabItem(AppTab.folders, L10n.text('Saved'), Symbols.folderFill),
      _TabItem(AppTab.works, L10n.text('Explore'), Symbols.globe),
      _TabItem(AppTab.artists, L10n.text('Tags'), Symbols.tagFill),
      _TabItem(AppTab.settings, L10n.text(booru ? 'More' : 'Settings'), booru ? Symbols.ellipsis : Symbols.gearshapeFill),
    ];
  }

  void _slide(double x, double slot, int count) {
    final hovered = (x / slot).floor().clamp(0, count - 1);
    if (hovered != _hovered) HapticFeedback.selectionClick();
    setState(() {
      _dragX = x;
      _hovered = hovered;
    });
  }

  void _lift(List<_TabItem> items) {
    final hovered = _hovered;
    setState(() {
      _dragX = null;
      _hovered = null;
    });
    if (hovered != null) state.tab = items[hovered].tab;
  }

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    final label = TegnalColors.label.resolveFrom(context);
    final selection = TegnalColors.glassSelection.resolveFrom(context);
    final items = _items;
    final current = items.indexWhere((item) => item.tab == state.tab);
    final active = _hovered ?? current;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _tabBarGap),
      // The tab capsule and the Smart circle sit apart, so they share one backdrop.
      child: BackdropGroup(
        child: Row(
          children: [
            Expanded(
              child: Glass.capsule(
                child: SizedBox(
                  height: tabBarHeight,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final slot = constraints.maxWidth / items.length;
                        final dragX = _dragX;
                        // Following the finger, the selection stays whole inside the capsule.
                        final left = dragX == null ? slot * math.max(0, active) : (dragX - slot / 2).clamp(0.0, constraints.maxWidth - slot);
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragStart: (details) => _slide(details.localPosition.dx, slot, items.length),
                          onHorizontalDragUpdate: (details) => _slide(details.localPosition.dx, slot, items.length),
                          onHorizontalDragEnd: (_) => _lift(items),
                          onHorizontalDragCancel: () => setState(() {
                            _dragX = null;
                            _hovered = null;
                          }),
                          child: Stack(
                            children: [
                              if (active >= 0)
                                AnimatedPositioned(
                                  duration: dragX == null ? const Duration(milliseconds: 260) : Duration.zero,
                                  curve: Curves.easeOutCubic,
                                  left: left,
                                  top: 0,
                                  bottom: 0,
                                  width: slot,
                                  child: AnimatedScale(
                                    scale: dragX == null ? 1 : 1.06,
                                    duration: const Duration(milliseconds: 180),
                                    curve: Curves.easeOut,
                                    child: DecoratedBox(
                                      decoration: ShapeDecoration(color: selection, shape: const StadiumBorder()),
                                    ),
                                  ),
                                ),
                              Row(
                                children: [
                                  for (final (index, item) in items.indexed)
                                    Expanded(
                                      child: _TabButton(
                                        title: item.title,
                                        selected: state.tab == item.tab,
                                        color: index == active ? tint : label,
                                        onTap: () => state.tab = item.tab,
                                        icon: Icon(item.icon, size: 27, color: index == active ? tint : label),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Semantics(
              button: true,
              selected: state.tab == AppTab.insights,
              label: L10n.text('Smart'),
              child: GestureDetector(
                onTap: () => state.tab = AppTab.insights,
                child: Glass.circle(
                  child: SizedBox.square(
                    dimension: tabBarHeight,
                    child: Center(child: IntelligenceSymbol(size: 27, color: state.tab == AppTab.insights ? tint : label)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({required this.title, required this.selected, required this.color, required this.onTap, required this.icon});
  final String title;
  final bool selected;
  final Color color;
  final VoidCallback onTap;
  final Widget icon;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: title,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            icon,
            const SizedBox(height: 2),
            Text(
              title,
              maxLines: 1,
              style: TegnalType.style(10, weight: FontWeight.w600, color: color),
            ),
          ],
        ),
      ),
    );
  }
}
