import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart' show Uint8List;

import '../../core/content/gallery_content.dart';
import '../../core/content/recent_works.dart';
import '../../core/storage/work_query.dart';
import '../../core/support/l10n.dart';
import '../../domain/models.dart';
import '../booru/booru_common.dart' show BooruContext;
import '../booru/booru_favorites_view.dart' show BooruFolderContentsView;
import '../design/alert_dialog.dart';
import '../design/context_menu.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';
import '../library/folders_view.dart' show ContentUnavailable, anchorOf;
import '../library/library_routes.dart';
import '../library/local_thumbnail.dart';
import '../library/works_grid_view.dart' show SelectionMark;
import '../navigation/app_header.dart';
import '../navigation/root_tab_view.dart';
import '../works/artwork_grid.dart';
import '../works/search_controls.dart';
import '../works/works_models.dart' show ScrollSearchVisibility;
import 'settings_rows.dart';

/// The rows Search History settings gain: the list of recently opened works or images, whether
/// Saved shows it as a folder, and a slider for how many to keep.
abstract final class RecentWorksSettingsRows {
  static List<Widget> comics(BuildContext context, {required RecentWorks recents, required LibraryRoutes routes}) => [
    ListenableBuilder(
      listenable: recents,
      builder: (context, _) => SettingsLinkRow(
        title: L10n.text('Recently Opened Works'),
        value: '${recents.entries.length}',
        onTap: () => Navigator.of(context).push(
          CupertinoPageRoute<void>(
            builder: (_) => RecentWorksPage(recents: recents, routes: routes),
          ),
        ),
      ),
    ),
    ListenableBuilder(
      listenable: recents,
      builder: (context, _) => SettingsToggleRow(title: L10n.text('Show as Folder in Saved'), value: recents.showsInSaved, onChanged: recents.setShowsInSaved),
    ),
    _LimitRow(title: L10n.text('Keep Recent Works'), unit: '%@ works', limit: () => recents.limit, setLimit: recents.setLimit),
  ];

  static List<Widget> images(BuildContext context, {required RecentImages recents, required BooruContext booru}) => [
    ListenableBuilder(
      listenable: recents,
      builder: (context, _) => SettingsLinkRow(
        title: L10n.text('Recently Opened Images'),
        value: '${recents.entries.length}',
        onTap: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => BooruFolderContentsView(booru: booru, recents: true))),
      ),
    ),
    ListenableBuilder(
      listenable: recents,
      builder: (context, _) => SettingsToggleRow(title: L10n.text('Show as Folder in Saved'), value: recents.showsInSaved, onChanged: recents.setShowsInSaved),
    ),
    _LimitRow(title: L10n.text('Keep Recent Images'), unit: '%@ items', limit: () => recents.limit, setLimit: recents.setLimit),
  ];

  static String title(int count, String unit) => count == 0 ? L10n.text("Don't Keep") : L10n.text(unit, ['$count']);
}

/// None, or up to 500 in steps of ten; the list follows once the slider is let go.
class _LimitRow extends StatefulWidget {
  const _LimitRow({required this.title, required this.unit, required this.limit, required this.setLimit});
  final String title;
  final String unit;
  final int Function() limit;
  final ValueChanged<int> setLimit;

  @override
  State<_LimitRow> createState() => _LimitRowState();
}

class _LimitRowState extends State<_LimitRow> {
  late double _value = widget.limit().toDouble();

  @override
  Widget build(BuildContext context) {
    final shown = RecentWorksSettingsRows.title(_value.round(), widget.unit);
    return FormRow(
      child: Semantics(
        label: widget.title,
        value: shown,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(widget.title)),
                Text(shown, style: TegnalType.style(17, color: TegnalColors.secondaryLabel.resolveFrom(context))),
              ],
            ),
            CupertinoSlider(
              value: _value,
              max: RecentLimit.maximum.toDouble(),
              divisions: RecentLimit.maximum ~/ RecentLimit.step,
              onChanged: (value) => setState(() => _value = value),
              onChangeEnd: (value) => widget.setLimit(value.round()),
            ),
          ],
        ),
      ),
    );
  }
}

/// `RecentWorksView`: recently opened works, newest first, laid out as a Saved folder is: the
/// search bar, the same cards, Select and Quick Jump. A tap opens the work again.
class RecentWorksPage extends StatefulWidget {
  const RecentWorksPage({super.key, required this.recents, required this.routes});
  final RecentWorks recents;
  final LibraryRoutes routes;

  @override
  State<RecentWorksPage> createState() => _RecentWorksPageState();
}

class _RecentWorksPageState extends State<RecentWorksPage> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();
  final _visibility = ScrollSearchVisibility();
  double _lastOffset = 0;
  bool _searchVisible = true;
  bool _selecting = false;
  Set<int> _selection = {};

  /// Saved works show their library cover, as they do in their folder.
  Map<int, Work> _saved = {};
  List<int> _savedFor = const [];

  RecentWorks get _recents => widget.recents;

  @override
  void initState() {
    super.initState();
    _recents.addListener(_changed);
    _search.addListener(_changed);
    _searchFocus.addListener(() {
      if (_searchFocus.hasFocus && !_searchVisible) setState(() => _searchVisible = true);
    });
    _scroll.addListener(() {
      final visible = _visibility.update(oldY: _lastOffset, newY: _scroll.offset, focused: _searchFocus.hasFocus);
      _lastOffset = _scroll.offset;
      if (visible != null && visible != _searchVisible) setState(() => _searchVisible = visible);
    });
  }

  @override
  void dispose() {
    _recents.removeListener(_changed);
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  List<RecentWork> get _shown {
    final query = WorkQuery(_search.text);
    return query.isEmpty ? _recents.entries : _recents.entries.where((entry) => entry.matches(query)).toList();
  }

  void _loadSaved() {
    final ids = [for (final entry in _recents.entries) entry.id];
    if (_listEquals(ids, _savedFor)) return;
    _savedFor = ids;
    _saved = {for (final id in ids) id: ?widget.routes.database.getWork(id)};
  }

  static bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  void _jumpMenu(BuildContext buttonContext) {
    _searchFocus.unfocus();
    showActionMenu(
      buttonContext,
      anchor: anchorOf(buttonContext),
      actions: [
        ContextMenuAction(
          title: L10n.text('Jump to Top'),
          icon: CupertinoIcons.arrow_up_to_line,
          onSelected: () => _scroll.animateTo(0, duration: const Duration(milliseconds: 350), curve: Curves.easeInOut),
        ),
        ContextMenuAction(
          title: L10n.text('Jump to Bottom'),
          icon: CupertinoIcons.arrow_down_to_line,
          onSelected: () => _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 350), curve: Curves.easeInOut),
        ),
      ],
    );
  }

  Future<void> _confirmDelete() async {
    final delete = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('Delete Selected Items?')),
        content: Text(L10n.text('They leave Recently Opened Works. Saved works stay saved.')),
        actions: [
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Delete'))),
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
        ],
      ),
    );
    if (delete != true) return;
    for (final id in _selection) {
      _recents.remove(id);
    }
    setState(() {
      _selection = {};
      _selecting = false;
    });
  }

  void _workMenu(BuildContext cardContext, RecentWork entry) => showActionMenu(
    cardContext,
    anchor: anchorOf(cardContext),
    actions: [ContextMenuAction(title: L10n.text('Remove'), icon: CupertinoIcons.trash, destructive: true, onSelected: () => _recents.remove(entry.id))],
  );

  Widget _toolbar(List<RecentWork> shown) {
    if (_selecting) {
      return ToolbarGroup(
        children: [
          ToolbarIconButton(
            label: L10n.text('Done'),
            icon: CupertinoIcons.xmark,
            onPressed: () => setState(() {
              _selecting = false;
              _selection = {};
            }),
          ),
          ToolbarIconButton(
            label: L10n.text('Select All'),
            icon: CupertinoIcons.checkmark_circle_fill,
            onPressed: () => setState(() => _selection = {for (final entry in shown) entry.id}),
          ),
          ToolbarIconButton(label: L10n.text('Delete'), icon: CupertinoIcons.trash, onPressed: _selection.isEmpty ? null : _confirmDelete),
        ],
      );
    }
    return ToolbarGroup(
      children: [
        ToolbarIconButton(
          label: L10n.text('Select'),
          icon: CupertinoIcons.checkmark_circle,
          size: 24,
          onPressed: _recents.entries.isEmpty
              ? null
              : () => setState(() {
                  _selecting = true;
                  _selection = {};
                }),
        ),
        Builder(
          builder: (context) => ToolbarIconButton(
            label: L10n.text('Quick Jump'),
            icon: CupertinoIcons.arrow_up_arrow_down,
            size: 24,
            onPressed: shown.isEmpty ? null : () => _jumpMenu(context),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    _loadSaved();
    final shown = _shown;
    final barBottom = MediaQuery.paddingOf(context).top + rootBarHeight;
    return ColoredBox(
      color: TegnalColors.background.resolveFrom(context),
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomScrollView(
              controller: _scroll,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                SliverToBoxAdapter(child: SizedBox(height: barBottom + 56)),
                if (_recents.entries.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 40),
                      child: ContentUnavailable(
                        icon: CupertinoIcons.clock,
                        title: L10n.text('No Recent Works'),
                        description: L10n.text('Works you open in the viewer appear here.'),
                      ),
                    ),
                  )
                else if (shown.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 40),
                      child: ContentUnavailable(
                        icon: CupertinoIcons.search,
                        title: L10n.text('No Results'),
                        description: L10n.text("No results for '%@'", [_search.text]),
                      ),
                    ),
                  )
                else
                  ArtworkGridSliver(
                    itemCount: shown.length,
                    preferences: widget.routes.worksGrid,
                    itemBuilder: (context, index, style) {
                      final entry = shown[index];
                      return Builder(
                        key: ValueKey('recentWorks.${entry.id}'),
                        builder: (cardContext) => GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            if (_selecting) {
                              setState(() => _selection.contains(entry.id) ? _selection.remove(entry.id) : _selection.add(entry.id));
                            } else {
                              widget.routes.contentRoutes.openThumbnail(context, entry.id);
                            }
                          },
                          onLongPress: _selecting ? null : () => _workMenu(cardContext, entry),
                          child: Stack(
                            children: [
                              RecentWorkCard(entry: entry, saved: _saved[entry.id], cover: _recents.cover(entry.id), style: style),
                              if (_selecting)
                                Positioned(
                                  top: style.inset(10),
                                  right: style.inset(10),
                                  child: SelectionMark(selected: _selection.contains(entry.id), size: style.fontSize(22, minimum: 12)),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                SliverToBoxAdapter(child: SizedBox(height: tabBarClearance(context))),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: barBottom,
            child: AnimatedSlide(
              offset: Offset(0, _searchVisible ? 0 : -60 / 56),
              duration: Duration(milliseconds: _searchVisible ? 350 : 320),
              curve: _searchVisible ? Curves.easeOutBack : Curves.easeInOut,
              child: AnimatedOpacity(
                opacity: _searchVisible ? 1 : 0,
                duration: const Duration(milliseconds: 250),
                child: IgnorePointer(
                  ignoring: !_searchVisible,
                  child: ScrollSearchBar(controller: _search, focusNode: _searchFocus, prompt: L10n.text('Search works')),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: RootHeader(
              title: L10n.text('Recently Opened Works'),
              state: widget.routes.state,
              onBack: () => Navigator.of(context).pop(),
              backInTitle: true,
              showsModeSwitch: false,
              trailing: _toolbar(shown),
            ),
          ),
        ],
      ),
    );
  }
}

/// A recently opened work drawn as a folder's work card.
class RecentWorkCard extends StatelessWidget {
  const RecentWorkCard({super.key, required this.entry, required this.saved, required this.cover, required this.style});
  final RecentWork entry;
  final Work? saved;
  final Uint8List? cover;
  final ArtworkCellStyle style;

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final placeholder = ColoredBox(
      color: TegnalColors.coverPlaceholder.resolveFrom(context),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CupertinoIcons.photo, size: style.fontSize(22), color: secondary),
            if (style.showsTitle) ...[
              SizedBox(height: style.inset(6)),
              Text(
                '${entry.id}',
                style: TegnalType.style(style.fontSize(11), color: secondary),
                textScaler: TextScaler.noScaling,
              ),
            ],
          ],
        ),
      ),
    );
    final work = saved, image = cover;
    final Widget art;
    if (work != null && work.thumbStatus == 'ready') {
      art = LocalThumbnail(path: work.thumbPath, revision: '${work.thumbPage ?? 1}', placeholder: placeholder);
    } else if (image != null) {
      art = Image.memory(image, fit: BoxFit.cover, gaplessPlayback: true);
    } else {
      art = placeholder;
    }
    final type = entry.type ?? '';
    return GalleryCardLayout(
      style: style,
      title: entry.item.title.isEmpty ? '${entry.id}' : entry.item.title,
      artists: entry.item.artists,
      language: entry.language ?? '',
      category: type.isEmpty ? '' : GalleryCategory.title(type),
      categoryColor: galleryCategoryColor(type),
      cover: art,
    );
  }
}
