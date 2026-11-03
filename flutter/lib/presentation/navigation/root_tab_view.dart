import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/support/l10n.dart';
import '../design/glass.dart';
import '../design/symbols.dart';
import '../design/tegnal_theme.dart';
import 'app_state.dart';

/// Height of the floating tab bar, and its distance from the bottom edge on a phone.
const double tabBarHeight = 62;
const double _tabBarGap = 21;

/// Space a scrolling root screen leaves under its content for the floating tab bar.
double tabBarClearance(BuildContext context) => tabBarHeight + _bottomGap(context) + 16;

double _bottomGap(BuildContext context) => math.max(_tabBarGap, MediaQuery.paddingOf(context).bottom - 13);

/// The root of each library: five destinations kept alive while switching, under
/// the iOS 26 floating tab bar with Smart in its own circle.
class RootTabView extends StatelessWidget {
  const RootTabView({super.key, required this.state, required this.pages});
  final AppState state;
  final Map<AppTab, Widget> pages;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final tabs = AppTab.values;
        return Stack(
          children: [
            Positioned.fill(
              child: IndexedStack(index: tabs.indexOf(state.tab), children: [for (final tab in tabs) pages[tab] ?? const SizedBox.shrink()]),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: _bottomGap(context),
              child: FloatingTabBar(state: state),
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

class FloatingTabBar extends StatelessWidget {
  const FloatingTabBar({super.key, required this.state});
  final AppState state;

  List<_TabItem> get _items {
    final booru = state.mode == AppMode.booru;
    return [
      _TabItem(AppTab.folders, L10n.text('Saved'), Symbols.folderFill),
      _TabItem(AppTab.works, L10n.text('Explore'), Symbols.globe),
      _TabItem(AppTab.artists, L10n.text('Tags'), Symbols.tagFill),
      _TabItem(AppTab.settings, L10n.text(booru ? 'More' : 'Settings'), booru ? Symbols.ellipsis : Symbols.gearshapeFill),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    final label = TegnalColors.label.resolveFrom(context);
    final selection = TegnalColors.glassSelection.resolveFrom(context);
    final items = _items;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _tabBarGap),
      child: Row(
        children: [
          Expanded(
            child: Glass.capsule(
              child: SizedBox(
                height: tabBarHeight,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Row(
                    children: [
                      for (final item in items)
                        Expanded(
                          child: _TabButton(
                            title: item.title,
                            selected: state.tab == item.tab,
                            selection: selection,
                            color: state.tab == item.tab ? tint : label,
                            onTap: () => state.tab = item.tab,
                            icon: Icon(item.icon, size: 27, color: state.tab == item.tab ? tint : label),
                          ),
                        ),
                    ],
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
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({required this.title, required this.selected, required this.selection, required this.color, required this.onTap, required this.icon});
  final String title;
  final bool selected;
  final Color selection;
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
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          decoration: ShapeDecoration(color: selected ? selection : selection.withAlpha(0), shape: const StadiumBorder()),
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
      ),
    );
  }
}
