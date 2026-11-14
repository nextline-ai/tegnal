import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../../core/content/gallery_content.dart';
import '../../core/support/l10n.dart';
import '../../domain/models.dart';
import '../content/gallery_preview_models.dart';
import '../design/app_sheet.dart';
import '../design/context_menu.dart';
import '../design/grouped_form.dart';
import '../design/symbols.dart';
import '../design/tegnal_theme.dart';
import '../navigation/app_header.dart';
import '../navigation/root_tab_view.dart';
import '../works/artwork_grid.dart';
import '../works/search_controls.dart';
import '../works/works_models.dart';
import 'folder_name_prompt.dart';
import 'folders_view.dart';
import 'library_routes.dart';
import 'local_thumbnail.dart';
import '../design/alert_dialog.dart';
import '../content/reading_queue_views.dart';
import '../../core/content/reading_queue.dart';

import 'dart:io';

/// `WorksGridView`: a folder's saved works, every saved work, or a saved-works search,
/// with the category filter, selection, quick jumps and each work's menu.
class WorksGridView extends StatefulWidget {
  const WorksGridView({super.key, required this.routes, this.folder, this.search});
  final LibraryRoutes routes;
  final Folder? folder;

  /// Opened from the folders' search with this text.
  final String? search;

  @override
  State<WorksGridView> createState() => _WorksGridViewState();
}

class _WorksGridViewState extends State<WorksGridView> {
  late final _search = TextEditingController(text: widget.search ?? '');
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();
  final _visibility = ScrollSearchVisibility();
  final _keys = <int, GlobalKey>{};
  StreamSubscription<int>? _changes;
  Timer? _debounce;
  double _lastOffset = 0;
  bool _searchVisible = true;

  List<Work> _scopeWorks = [];
  List<Work> _works = [];
  List<({String key, int count})> _categories = [];
  String _category = '';
  List<Folder> _folders = [];
  bool _selecting = false;
  Set<int> _selection = {};

  bool get _opensSearch => widget.search != null;

  @override
  void initState() {
    super.initState();
    _reload();
    _changes = widget.routes.database.changes.listen((_) => _reload());
    widget.routes.changes.addListener(_reload);
    _search.addListener(_searchChanged);
    _searchFocus.addListener(() {
      if (_searchFocus.hasFocus && !_searchVisible) setState(() => _searchVisible = true);
    });
    _scroll.addListener(_scrolled);
  }

  @override
  void dispose() {
    _changes?.cancel();
    _debounce?.cancel();
    widget.routes.changes.removeListener(_reload);
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String _lastQuery = '';

  /// Superseded searches are dropped before scanning a large library.
  void _searchChanged() {
    if (_search.text == _lastQuery) return;
    _lastQuery = _search.text;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), _reload);
  }

  void _reload() {
    if (!mounted) return;
    final database = widget.routes.database;
    final query = _search.text;
    setState(() {
      _scopeWorks = database.listWorks(folderId: widget.folder?.id, query: query.isEmpty ? null : query);
      _folders = database.listFolders();
      _applyCategory();
    });
  }

  void _applyCategory() {
    final counts = <String, int>{};
    for (final work in _scopeWorks) {
      final key = GalleryCategory.key(work.type ?? '');
      if (key.isNotEmpty) counts[key] = (counts[key] ?? 0) + 1;
    }
    _categories = [for (final entry in counts.entries) (key: entry.key, count: entry.value)]
      ..sort((a, b) => a.count != b.count ? b.count.compareTo(a.count) : a.key.compareTo(b.key));
    _works = _category.isEmpty ? _scopeWorks : _scopeWorks.where((work) => GalleryCategory.key(work.type ?? '') == _category).toList();
  }

  void _scrolled() {
    final offset = _scroll.offset;
    final visible = _visibility.update(oldY: _lastOffset, newY: offset, focused: _searchFocus.hasFocus);
    _lastOffset = offset;
    if (visible != null && visible != _searchVisible) setState(() => _searchVisible = visible);
  }

  void _open(Work work) {
    if (_selecting) {
      setState(() => _selection.contains(work.galleryId) ? _selection.remove(work.galleryId) : _selection.add(work.galleryId));
    } else {
      widget.routes.openWork(context, work.galleryId);
    }
  }

  void _toast(String message) => widget.routes.showMessage(context, message);

  void _move(Work work, Folder target) {
    final id = target.id;
    if (id == null) return;
    try {
      widget.routes.database.moveWorkToFolder(work.galleryId, id, currentFolderId: widget.folder?.id);
      _toast(L10n.text("Moved to folder '%@'", [target.displayName]));
    } on Object catch (error) {
      _toast('$error');
    }
  }

  Future<void> _moveToNewFolder(Work work) async {
    final result = await showFolderNamePrompt(
      context,
      title: 'Create Folder and Move',
      actionTitle: 'Create and Move',
      placeholder: L10n.text('New Folder Name'),
    );
    if (!mounted || result == null || result.name.isEmpty) return;
    try {
      _move(work, widget.routes.database.createFolder(name: result.name));
    } on Object catch (error) {
      _toast('$error');
    }
  }

  Future<void> _confirmDelete(Work work) async {
    final delete = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('Delete Work')),
        content: Text(L10n.text('Delete this work (number: %@)?', ['${work.galleryId}'])),
        actions: [
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Delete'))),
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
        ],
      ),
    );
    if (delete == true) widget.routes.database.deleteWork(work.galleryId);
  }

  Future<void> _confirmDeleteSelection() async {
    final delete = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('Delete Selected Items?')),
        actions: [
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Delete'))),
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
        ],
      ),
    );
    if (delete != true) return;
    try {
      widget.routes.database.deleteSelectedWorks(_selection);
      setState(() {
        _selection = {};
        _selecting = false;
      });
    } on Object catch (error) {
      _toast('$error');
    }
  }

  void _moveSelection(Folder target) {
    final id = target.id;
    if (id == null) return;
    try {
      widget.routes.database.moveSelectedWorks(_selection, id, from: widget.folder?.id);
      setState(() {
        _selection = {};
        _selecting = false;
      });
    } on Object catch (error) {
      _toast('$error');
    }
  }

  void _workMenu(BuildContext cardContext, Work work) {
    final id = work.galleryId;
    showContextMenu(
      cardContext,
      anchor: anchorOf(cardContext),
      child: const SizedBox.shrink(),
      preview: WorkContextPreview(work: work),
      previewSize: Size(340, WorkContextPreview.height(context, work)),
      actions: [
        if (ReadingQueueScope.read(context) case final queue?)
          queue.contains(id)
              ? ContextMenuAction(title: L10n.text('Remove from Up Next'), icon: CupertinoIcons.minus_circle, onSelected: () => queue.remove(id))
              : ContextMenuAction(
                  title: L10n.text('Add to Up Next'),
                  icon: CupertinoIcons.text_badge_plus,
                  onSelected: () {
                    final path = work.thumbStatus == 'ready' ? work.thumbPath : null;
                    final added = queue.add(
                      ReadingQueueItem.fromGallery(
                        id: id,
                        title: work.hasTitle ? work.title : null,
                        artists: work.artists,
                        language: work.language,
                        type: work.type,
                        site: work.site,
                      ),
                      cover: path == null ? null : File(path).readAsBytes().then<Uint8List?>((data) => data, onError: (_) => null),
                    );
                    if (added) HapticFeedback.heavyImpact();
                  },
                ),
        ContextMenuAction(
          title: L10n.text('Move to Another Folder'),
          icon: CupertinoIcons.folder,
          children: [
            ContextMenuAction(title: L10n.text('Create New Folder…'), icon: CupertinoIcons.folder_badge_plus, onSelected: () => _moveToNewFolder(work)),
            for (final target in _folders)
              ContextMenuAction(title: target.displayName, checked: target.id == widget.folder?.id, onSelected: () => _move(work, target)),
          ],
        ),
        ContextMenuAction(title: L10n.text('Work Details'), icon: CupertinoIcons.info_circle, onSelected: () => widget.routes.openDetails(context, id)),
        ContextMenuAction(
          title: L10n.text('Copy Work Number (%@)', ['$id']),
          icon: CupertinoIcons.doc_on_doc,
          onSelected: () {
            Clipboard.setData(ClipboardData(text: '$id'));
            _toast(L10n.text('Copied work number %@', ['$id']));
          },
        ),
        ContextMenuAction(title: L10n.text('Delete'), icon: CupertinoIcons.trash, destructive: true, onSelected: () => _confirmDelete(work)),
      ],
    );
  }

  void _jumpTo(int galleryID) {
    final target = _keys[galleryID]?.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(target, duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
      return;
    }
    // A row that was never built is reached by its estimated offset first.
    final index = _works.indexWhere((work) => work.galleryId == galleryID);
    if (index < 0 || !_scroll.hasClients) return;
    final fraction = index / _works.length;
    _scroll.jumpTo((_scroll.position.maxScrollExtent * fraction).clamp(0, _scroll.position.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _keys[galleryID]?.currentContext;
      if (context != null) Scrollable.ensureVisible(context, duration: const Duration(milliseconds: 250));
    });
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
        ContextMenuAction(title: L10n.text('Jump to Saved Month'), icon: CupertinoIcons.calendar, onSelected: _showMonths),
      ],
    );
  }

  Future<void> _showMonths() async {
    final months = WorkMonthDestination.make(_works);
    final chosen = await showAppSheet<int>(
      context,
      grabber: true,
      builder: (context, controller) => _MonthJumpView(months: months, controller: controller),
    );
    if (chosen != null && mounted) WidgetsBinding.instance.addPostFrameCallback((_) => _jumpTo(chosen));
  }

  void _selectionMenu(BuildContext buttonContext) => showActionMenu(
    buttonContext,
    anchor: anchorOf(buttonContext),
    actions: [
      ContextMenuAction(title: L10n.text('Select All'), onSelected: () => setState(() => _selection = {for (final work in _works) work.galleryId})),
      for (final target in _folders) ContextMenuAction(title: target.displayName, onSelected: () => _moveSelection(target)),
    ],
  );

  Widget _toolbar() {
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
          Builder(
            builder: (context) =>
                ToolbarIconButton(label: L10n.text('Move to Another Folder'), icon: CupertinoIcons.folder, onPressed: () => _selectionMenu(context)),
          ),
          ToolbarIconButton(label: L10n.text('Delete'), icon: CupertinoIcons.trash, onPressed: _selection.isEmpty ? null : _confirmDeleteSelection),
        ],
      );
    }
    return ToolbarGroup(
      children: [
        ToolbarIconButton(
          label: L10n.text('Select'),
          icon: CupertinoIcons.checkmark_circle,
          size: 24,
          onPressed: () => setState(() {
            _selecting = true;
            _selection = {};
          }),
        ),
        if (_opensSearch)
          ToolbarIconButton(
            label: L10n.text('Create Folder from Results'),
            icon: CupertinoIcons.folder_badge_plus,
            size: 24,
            onPressed: _works.isEmpty ? null : () => widget.routes.composeSmartFolder(context, tag: _search.text, smart: false),
          ),
        Builder(
          builder: (context) => ToolbarIconButton(
            label: L10n.text('Quick Jump'),
            icon: CupertinoIcons.arrow_up_arrow_down,
            size: 24,
            onPressed: _works.isEmpty ? null : () => _jumpMenu(context),
          ),
        ),
        ToolbarIconButton(label: L10n.text('Add Work Number'), icon: CupertinoIcons.plus, size: 24, onPressed: () => widget.routes.addWork(context)),
      ],
    );
  }

  Widget _empty() {
    if (_works.isEmpty && _category.isNotEmpty && _scopeWorks.isNotEmpty) {
      return ContentUnavailable(
        icon: CupertinoIcons.square_stack,
        title: L10n.text('No Works in This Category'),
        action: CupertinoButton(
          onPressed: () => setState(() {
            _category = '';
            _applyCategory();
          }),
          child: Text(L10n.text('Show All Categories')),
        ),
      );
    }
    return ContentUnavailable(
      icon: CupertinoIcons.square_grid_2x2,
      title: L10n.text('No Works'),
      description: _search.text.isEmpty ? L10n.text('Add a work number to get started.') : L10n.text("No results for '%@'", [_search.text]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final barBottom = media.padding.top + rootBarHeight;
    final title = widget.folder?.displayName ?? L10n.text(_opensSearch ? 'Search Results' : 'All');
    final pushed = Navigator.of(context).canPop();
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
                if (_categories.length > 1 || _category.isNotEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    sliver: SliverToBoxAdapter(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: BrowseFilterMenu<String>(
                          title: _category.isEmpty ? L10n.text('Category') : GalleryCategory.title(_category),
                          icon: Symbols.squareStack,
                          options: [
                            ('', L10n.text('All Categories')),
                            for (final item in _categories) (item.key, L10n.text('%@ (%@)', [GalleryCategory.title(item.key), '${item.count}'])),
                          ],
                          selected: _category,
                          onSelected: (value) => setState(() {
                            _category = value;
                            _applyCategory();
                          }),
                        ),
                      ),
                    ),
                  ),
                if (_works.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(padding: const EdgeInsets.only(top: 40), child: _empty()),
                  )
                else
                  ArtworkGridSliver(
                    itemCount: _works.length,
                    preferences: widget.routes.worksGrid,
                    itemBuilder: (context, index, style) {
                      final work = _works[index];
                      final key = _keys.putIfAbsent(work.galleryId, GlobalKey.new);
                      return Builder(
                        key: key,
                        builder: (cardContext) => GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _open(work),
                          onLongPress: _selecting ? null : () => _workMenu(cardContext, work),
                          child: Stack(
                            children: [
                              WorkCard(work: work, style: style),
                              if (_selecting)
                                Positioned(
                                  top: style.inset(10),
                                  right: style.inset(10),
                                  child: SelectionMark(selected: _selection.contains(work.galleryId), size: style.fontSize(22, minimum: 12)),
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
              title: title,
              state: widget.routes.state,
              onBack: pushed ? () => Navigator.of(context).pop() : null,
              backInTitle: true,
              showsModeSwitch: false,
              trailing: _toolbar(),
            ),
          ),
        ],
      ),
    );
  }
}

class SelectionMark extends StatelessWidget {
  const SelectionMark({super.key, required this.selected, required this.size});
  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    children: [
      if (selected)
        Container(
          width: size * 0.8,
          height: size * 0.8,
          decoration: const BoxDecoration(color: Color(0xFFFFFFFF), shape: BoxShape.circle),
        ),
      Icon(
        selected ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle,
        size: size,
        color: selected ? TegnalColors.tint.resolveFrom(context) : const Color(0xFFFFFFFF),
      ),
    ],
  );
}

/// `WorkCardView`: a saved work's local cover, or its number over a placeholder.
class WorkCard extends StatelessWidget {
  const WorkCard({super.key, required this.work, required this.style});
  final Work work;
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
            Icon(work.thumbStatus == 'gone' ? CupertinoIcons.slash_circle : CupertinoIcons.photo, size: style.fontSize(22), color: secondary),
            if (style.showsTitle) ...[
              SizedBox(height: style.inset(6)),
              Text(
                '${work.galleryId}',
                style: TegnalType.style(style.fontSize(11), color: secondary),
                textScaler: TextScaler.noScaling,
              ),
            ],
          ],
        ),
      ),
    );
    final type = work.type ?? '';
    return GalleryCardLayout(
      style: style,
      title: work.hasTitle ? work.title ?? '' : '${work.galleryId}',
      artists: work.artists ?? '',
      language: work.language ?? '',
      category: type.isEmpty ? '' : GalleryCategory.title(type),
      categoryColor: galleryCategoryColor(type),
      cover: LocalThumbnail(path: work.thumbStatus == 'ready' ? work.thumbPath : null, revision: '${work.thumbPage ?? 1}', placeholder: placeholder),
    );
  }
}

/// `WorkContextPreview`: shown while a card is held, so reading a work's details takes no second tap.
class WorkContextPreview extends StatelessWidget {
  const WorkContextPreview({super.key, required this.work});
  final Work work;

  static double height(BuildContext context, Work work) => 148 + 28;

  @override
  Widget build(BuildContext context) {
    final label = TegnalColors.label.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final details = [work.language, work.type].whereType<String>().where((value) => value.isNotEmpty).join(' · ');
    final tags = ArtworkTagGroup.make(tags: (work.tags ?? '').split(', '))
        .expand((group) => group.tags)
        .where((tag) => tag.category != ArtworkTagCategory.language && tag.category != ArtworkTagCategory.artist)
        .take(6)
        .map((tag) => tag.name)
        .join(' · ');
    final artists = work.artists ?? '';
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: TegnalColors.secondaryBackground.resolveFrom(context),
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(26)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 104,
                height: 148,
                child: LocalThumbnail(
                  path: work.thumbStatus == 'ready' ? work.thumbPath : null,
                  revision: '${work.thumbPage ?? 1}',
                  placeholder: ColoredBox(color: TegnalColors.coverPlaceholder.resolveFrom(context)),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    work.hasTitle ? work.title ?? '' : '${work.galleryId}',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TegnalType.style(17, weight: FontWeight.w600, color: label),
                  ),
                  if (artists.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      artists,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TegnalType.style(15, color: secondary),
                    ),
                  ],
                  if (details.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      details,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TegnalType.style(13, color: secondary),
                    ),
                  ],
                  if (tags.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      tags,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TegnalType.style(12, color: secondary),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `WorkMonthJumpView`: each save month with its count; choosing one returns its first work.
class _MonthJumpView extends StatelessWidget {
  const _MonthJumpView({required this.months, required this.controller});
  final List<WorkMonthDestination> months;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return ScrollEdgeSheet(
      bar: SheetNavigationBar(
        title: L10n.text('Jump to Saved Month'),
        leading: GlassTextButton(label: L10n.text('Close'), onPressed: () => Navigator.of(context).pop()),
      ),
      child: ListView(
        controller: controller,
        padding: EdgeInsets.only(top: 76 + 4, bottom: 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          FormSection(
            children: [
              for (final month in months)
                FormRow(
                  onTap: () => Navigator.of(context).pop(month.firstGalleryID),
                  child: Row(
                    children: [
                      Expanded(child: Text(month.title)),
                      Text(L10n.text('%@ items', ['${month.count}']), style: TegnalType.style(17, color: secondary)),
                      const SizedBox(width: 8),
                      Icon(CupertinoIcons.chevron_right, size: 13, color: secondary),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
