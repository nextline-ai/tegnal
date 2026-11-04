import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/support/l10n.dart';
import '../design/glass.dart';
import '../design/pull_down_menu.dart';
import '../design/symbols.dart';
import '../design/tegnal_theme.dart';
import '../design/alert_dialog.dart';

/// `ScrollSearchBar`: a 44 pt glass capsule shared by the library and Explore.
class ScrollSearchBar extends StatelessWidget {
  const ScrollSearchBar({super.key, required this.controller, required this.focusNode, required this.prompt, this.onSubmitted});
  final TextEditingController controller;
  final FocusNode focusNode;
  final String prompt;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Glass.capsule(
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.only(left: 14, right: 14),
            child: Row(
              children: [
                Icon(Symbols.magnifyingglass, size: 20, color: secondary),
                const SizedBox(width: 8),
                Expanded(
                  child: CupertinoTextField.borderless(
                    controller: controller,
                    focusNode: focusNode,
                    placeholder: prompt,
                    padding: EdgeInsets.zero,
                    style: TegnalType.style(16, color: TegnalColors.label.resolveFrom(context)),
                    placeholderStyle: TegnalType.style(16, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
                    cursorColor: TegnalColors.tint.resolveFrom(context),
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.search,
                    onSubmitted: onSubmitted,
                  ),
                ),
                ListenableBuilder(
                  listenable: Listenable.merge([controller, focusNode]),
                  builder: (context, _) {
                    final visible = focusNode.hasFocus || controller.text.isNotEmpty;
                    return Semantics(
                      button: true,
                      label: L10n.text('Clear Search'),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: visible ? () => controller.text.isEmpty ? focusNode.unfocus() : controller.clear() : null,
                        child: Opacity(
                          opacity: visible ? 1 : 0,
                          child: SizedBox(width: 32, height: 40, child: Icon(Symbols.xmarkCircleFill, size: 19, color: secondary)),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One bounded, scrollable surface under the search field (`searchResultsPanel`).
class SearchResultsPanel extends StatelessWidget {
  const SearchResultsPanel({super.key, required this.height, required this.child});
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    const shape = RoundedSuperellipseBorder(borderRadius: BorderRadius.all(Radius.circular(16)));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        height: height,
        decoration: ShapeDecoration(
          color: TegnalColors.secondaryBackground.resolveFrom(context),
          shape: shape.copyWith(side: BorderSide(color: TegnalColors.label.resolveFrom(context).withValues(alpha: 0.06))),
          shadows: const [BoxShadow(color: Color(0x1F000000), blurRadius: 16, offset: Offset(0, 4))],
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}

/// Recent and saved searches shown while the empty search field has focus.
class SearchHistoryPanel extends StatelessWidget {
  const SearchHistoryPanel({
    super.key,
    required this.history,
    required this.saved,
    required this.open,
    required this.star,
    required this.remove,
    required this.clear,
  });

  final List<String> history;
  final List<String> saved;
  final ValueChanged<String> open;
  final ValueChanged<String> star;
  final ValueChanged<String> remove;
  final VoidCallback clear;

  /// The search field occupies 56 points; leave a small gap above the keyboard.
  static double height(double availableHeight) => (availableHeight - 56 - 12).clamp(0, double.infinity);

  @override
  Widget build(BuildContext context) {
    final recent = history.take(5).toList();
    final savedQueries = saved.toSet().toList();
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final label = TegnalColors.label.resolveFrom(context);
    final divider = Container(height: 0.5, margin: const EdgeInsets.only(left: 12), color: TegnalColors.separator.resolveFrom(context));
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _Header(title: L10n.text('Search History'), clear: history.isEmpty ? null : () => _confirmClear(context)),
        if (history.isEmpty)
          _Row(
            child: Text(L10n.text('Nothing Saved Yet'), style: TegnalType.style(15, color: secondary)),
          ),
        for (final (index, query) in recent.indexed) ...[
          _Row(
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => open(query),
                    onLongPress: () => _confirmRemove(context, query),
                    child: SizedBox(
                      height: 46,
                      child: Row(
                        children: [
                          Icon(Symbols.clock, size: 17, color: secondary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              query,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TegnalType.style(15, color: label),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => star(query),
                  child: SizedBox(
                    width: 36,
                    height: 46,
                    child: Icon(saved.contains(query) ? Symbols.starFill : Symbols.star, size: 17, color: CupertinoColors.systemYellow.resolveFrom(context)),
                  ),
                ),
              ],
            ),
          ),
          if (index != recent.length - 1) divider,
        ],
        if (savedQueries.isNotEmpty) ...[
          const SizedBox(height: 20),
          _Header(title: L10n.text('Saved Searches')),
          for (final (index, query) in savedQueries.indexed) ...[
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => open(query),
              onLongPress: () => star(query),
              child: _Row(
                child: Row(
                  children: [
                    Icon(Symbols.starFill, size: 17, color: CupertinoColors.systemYellow.resolveFrom(context)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        query,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TegnalType.style(15, color: label),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (index != savedQueries.length - 1) divider,
          ],
        ],
      ],
    );
  }

  void _confirmClear(BuildContext context) => showCupertinoDialog<void>(
    context: context,
    builder: (context) => TegnalAlertDialog(
      title: Text(L10n.text('Clear History?')),
      content: Text(L10n.text('Search history will be deleted. Saved searches will be kept.')),
      actions: [
        CupertinoDialogAction(
          isDestructiveAction: true,
          onPressed: () {
            Navigator.pop(context);
            clear();
          },
          child: Text(L10n.text('Clear History')),
        ),
        CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('Cancel'))),
      ],
    ),
  );

  void _confirmRemove(BuildContext context, String query) => showCupertinoModalPopup<void>(
    context: context,
    builder: (context) => CupertinoActionSheet(
      title: Text(query),
      actions: [
        CupertinoActionSheetAction(
          isDestructiveAction: true,
          onPressed: () {
            Navigator.pop(context);
            remove(query);
          },
          child: Text(L10n.text('Remove')),
        ),
      ],
      cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context), child: Text(L10n.text('Cancel'))),
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.title, this.clear});
  final String title;
  final VoidCallback? clear;

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 12, right: 12),
      child: SizedBox(
        height: 28,
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TegnalType.style(17, weight: FontWeight.w600, color: secondary),
              ),
            ),
            Semantics(
              button: true,
              enabled: clear != null,
              label: L10n.text('Clear History'),
              child: GestureDetector(
                onTap: clear,
                child: SizedBox(
                  width: 36,
                  height: 28,
                  child: Icon(Symbols.trash, size: 19, color: clear == null ? secondary.withValues(alpha: secondary.a * 0.5) : secondary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 46),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Align(alignment: Alignment.centerLeft, child: child),
    ),
  );
}

/// `BrowseFilterMenu`: a tinted capsule that opens a picker as a pull-down menu.
class BrowseFilterMenu<T> extends StatelessWidget {
  const BrowseFilterMenu({super.key, required this.title, required this.icon, required this.options, required this.selected, required this.onSelected});
  final String title;
  final IconData icon;
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onSelected;

  Future<void> _open(BuildContext context) async {
    final value = await showPullDownMenu<T>(
      context,
      anchor: anchorRectOf(context),
      items: [for (final (value, label) in options) PullDownMenuItem(value: value, title: label, checked: value == selected)],
    );
    if (value != null) onSelected(value);
  }

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    return Semantics(
      button: true,
      label: title,
      child: Builder(
        builder: (context) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _open(context),
          child: Container(
            constraints: const BoxConstraints(minHeight: 40),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: ShapeDecoration(color: tint.withValues(alpha: 0.09), shape: const StadiumBorder()),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 19, color: tint),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: TegnalType.style(15, weight: FontWeight.w500, color: tint),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
