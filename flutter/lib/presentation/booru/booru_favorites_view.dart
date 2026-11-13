import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/booru/booru_models.dart';
import '../../core/booru/booru_store.dart';
import '../../core/content/recent_works.dart';
import '../../core/support/l10n.dart';
import '../../core/taste/taste_models.dart';
import '../content/content_bookmark.dart';
import '../content/explore_view.dart' show ScrollSearchVisibility;
import '../content/work_save_feedback.dart';
import '../design/app_sheet.dart';
import '../design/context_menu.dart';
import '../design/grouped_form.dart';
import '../design/symbols.dart';
import '../design/tegnal_theme.dart';
import '../library/folder_color_sheet.dart';
import '../library/folder_name_prompt.dart';
import '../library/folder_order_view.dart';
import '../library/folder_rule_editor.dart';
import '../library/folders_view.dart' show ContentUnavailable, FolderCardCaption, PressableCard, anchorOf, recentFolderColor;
import '../library/library_routes.dart' show showTransientMessage;
import '../navigation/app_header.dart';
import '../navigation/root_tab_view.dart';
import '../works/artwork_grid.dart';
import '../works/search_controls.dart';
import 'booru_common.dart';
import 'booru_post_view.dart';
import '../design/alert_dialog.dart';
import '../library/folder_picker_sheet.dart';

/// `BooruFavoritesView`: All Favorites above the folders as bento cards.
class BooruFavoritesView extends StatefulWidget {
  const BooruFavoritesView({super.key, required this.booru});
  final BooruContext booru;

  @override
  State<BooruFavoritesView> createState() => _BooruFavoritesViewState();
}

class _BooruFavoritesViewState extends State<BooruFavoritesView> {
  BooruContext get _booru => widget.booru;

  /// The app's recent images, which Saved can show as a folder.
  RecentImages? get _recents => RecentImages.shared;

  @override
  void initState() {
    super.initState();
    _booru.store.addListener(_changed);
    _recents?.addListener(_changed);
  }

  @override
  void dispose() {
    _booru.store.removeListener(_changed);
    _recents?.removeListener(_changed);
    super.dispose();
  }

  List<BooruPost> _recentPosts(RecentImages recents) => [
    for (final entry in recents.entries)
      if (_booru.store.isShownInSafeMode(entry.post)) entry.post,
  ];

  void _openRecents(RecentImages recents) =>
      Navigator.of(context).push(CupertinoPageRoute<void>(builder: (context) => BooruFolderContentsView(booru: _booru, recents: true)));

  void _openRecentsMenu(BuildContext cardContext, RecentImages recents) => showContextMenu(
    cardContext,
    anchor: anchorOf(cardContext),
    child: BooruFolderCard.recent(
      booru: _booru,
      posts: _recentPosts(recents),
      style: ArtworkCellStyle(width: anchorOf(cardContext).width),
    ),
    actions: [ContextMenuAction(title: L10n.text('Hide from Saved'), icon: CupertinoIcons.eye_slash, onSelected: () => recents.setShowsInSaved(false))],
  );

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _createFolder() async {
    final result = await showFolderNamePrompt(context, alternateTitle: L10n.text('Make a Smart Folder'));
    if (!mounted || result == null || result.name.isEmpty) return;
    if (result.alternate) {
      await showAppSheet<void>(
        context,
        builder: (context, controller) => FolderRuleEditor.create(library: _booru.store, booru: true, name: result.name, scrollController: controller),
      );
    } else {
      _perform(() => _booru.store.saveFolder(name: result.name));
    }
  }

  void _perform(void Function() action) {
    try {
      action();
    } on Object catch (error) {
      showTransientMessage(context, '$error', bottom: tabBarClearance(context) + 8);
    }
  }

  void _openFolder(BooruFolder? folder) => Navigator.of(context).push(
    CupertinoPageRoute<void>(
      builder: (context) => BooruFolderContentsView(booru: _booru, folderID: folder?.id),
    ),
  );

  void _openMenu(BuildContext cardContext, BooruFolder folder) {
    final unsorted = folder.id == 'unsorted';
    showContextMenu(
      cardContext,
      anchor: anchorOf(cardContext),
      child: BooruFolderCard(
        booru: _booru,
        folder: folder,
        posts: _booru.store.visibleFavorites(folderID: folder.id),
        style: ArtworkCellStyle(width: anchorOf(cardContext).width),
      ),
      actions: [
        ContextMenuAction(
          title: L10n.text('Change Color'),
          symbol: (color) => PaletteSymbol(color: color),
          onSelected: () => showAppSheet<void>(
            context,
            grabber: true,
            builder: (context, controller) =>
                FolderColorSheet(title: folder.displayName, color: folder.color, onSelected: (color) => _booru.store.setFolderColor(folder.id, color)),
          ),
        ),
        ContextMenuAction(
          title: L10n.text('Reorder Folders'),
          icon: CupertinoIcons.arrow_up_arrow_down,
          onSelected: () => showAppSheet<void>(
            context,
            builder: (context, controller) => FolderOrderView<String>(
              folders: [for (final folder in _booru.store.folders()) (id: folder.id, name: folder.displayName)],
              save: _booru.store.reorderFolders,
            ),
          ),
        ),
        if (!unsorted) ...[
          ContextMenuAction(title: L10n.text('Rename Folder'), icon: CupertinoIcons.pencil, onSelected: () => _rename(folder)),
          ContextMenuAction(
            title: L10n.text('Smart Folder'),
            icon: CupertinoIcons.sparkles,
            onSelected: () => showAppSheet<void>(
              context,
              builder: (context, controller) => FolderRuleEditor.existing(library: _booru.store, booru: true, folder: folder.id, scrollController: controller),
            ),
          ),
        ],
        ContextMenuAction(
          title: L10n.text('Delete Folder'),
          icon: CupertinoIcons.trash,
          destructive: true,
          onSelected: () => unsorted ? _perform(() => _booru.store.deleteFolder(folder.id)) : _confirmDelete(folder),
        ),
      ],
    );
  }

  Future<void> _rename(BooruFolder folder) async {
    final result = await showFolderNamePrompt(context, title: 'Rename Folder', actionTitle: 'Save', initialName: folder.plainName);
    if (!mounted || result == null || result.name.isEmpty) return;
    _perform(() => _booru.store.saveFolder(id: folder.id, name: result.name, color: folder.color));
  }

  Future<void> _confirmDelete(BooruFolder folder) async {
    final delete = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(L10n.text('Delete Folder?')),
        message: Text(L10n.text('Favorites in this folder will move to Uncategorized.')),
        actions: [CupertinoActionSheetAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Delete')))],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (delete == true) _perform(() => _booru.store.deleteFolder(folder.id));
  }

  @override
  Widget build(BuildContext context) {
    final top = rootContentTop(context);
    final folders = _booru.store.folders();
    final count = _booru.store.visibleFavorites().length;
    final recents = _recents?.showsInSaved ?? false ? _recents : null;
    return ColoredBox(
      color: TegnalColors.background.resolveFrom(context),
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(16, top + 16, 16, 0),
                  sliver: SliverToBoxAdapter(
                    child: _AllFavoritesRow(count: count, onTap: () => _openFolder(null)),
                  ),
                ),
                ArtworkGridSliver(
                  itemCount: folders.length + (recents != null ? 1 : 0),
                  preferences: ArtworkGridPreferences(columns: _booru.folderColumns, removesPadding: _booru.gridPreferences.removesPadding),
                  itemBuilder: (context, index, style) {
                    if (recents != null) {
                      if (index == 0) {
                        return Builder(
                          builder: (cardContext) => PressableCard(
                            key: const ValueKey('booru.recentFolder'),
                            onTap: () => _openRecents(recents),
                            onLongPress: () => _openRecentsMenu(cardContext, recents),
                            child: BooruFolderCard.recent(booru: _booru, posts: _recentPosts(recents), style: style),
                          ),
                        );
                      }
                      index -= 1;
                    }
                    final folder = folders[index];
                    return Builder(
                      builder: (cardContext) => PressableCard(
                        onTap: () => _openFolder(folder),
                        onLongPress: () => _openMenu(cardContext, folder),
                        child: BooruFolderCard(
                          booru: _booru,
                          folder: folder,
                          posts: _booru.store.visibleFavorites(folderID: folder.id),
                          style: style,
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
            top: 0,
            child: RootHeader(
              title: L10n.text('Saved'),
              state: _booru.state,
              trailing: ToolbarGroup(
                children: [
                  ToolbarIconButton(label: L10n.text('Create Folder'), icon: CupertinoIcons.folder_badge_plus, size: 24, onPressed: _createFolder),
                  BooruServerMenuButton(store: _booru.store, grouped: true),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The All Favorites row: a grid symbol, the title and the count, on a rounded card.
class _AllFavoritesRow extends StatelessWidget {
  const _AllFavoritesRow({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // A navigation link in a scroll view takes the accent color, secondary styles included.
    final tint = TegnalColors.tint.resolveFrom(context);
    final secondary = tint.withValues(alpha: 0.6);
    return Semantics(
      button: true,
      label: '${L10n.text('All Favorites')}, $count',
      excludeSemantics: true,
      child: PressableCard(
        onTap: onTap,
        onLongPress: () {},
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: ShapeDecoration(
            color: TegnalColors.secondaryBackground.resolveFrom(context),
            shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(18)),
          ),
          child: Row(
            children: [
              Icon(CupertinoIcons.square_grid_2x2_fill, size: 24, color: tint),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  L10n.text('All Favorites'),
                  style: TegnalType.style(17, weight: FontWeight.w600, color: tint),
                ),
              ),
              Text('$count', style: TegnalType.style(17, color: secondary)),
              const SizedBox(width: 14),
              Icon(CupertinoIcons.chevron_right, size: 13, color: secondary),
            ],
          ),
        ),
      ),
    );
  }
}

/// `BooruFolderCard`: the folder's color with four favorites on white cells and its caption.
class BooruFolderCard extends StatelessWidget {
  BooruFolderCard({super.key, required this.booru, required BooruFolder folder, required this.posts, required this.style})
    : title = folder.plainName,
      isSmart = folder.isSmart,
      color = folder.color;

  /// Recently opened images as a folder card in Saved.
  BooruFolderCard.recent({super.key, required this.booru, required this.posts, required this.style})
    : title = L10n.text('Recent Images'),
      isSmart = false,
      color = recentFolderColor;

  final BooruContext booru;
  final String title;
  final bool isSmart;
  final int color;
  final List<BooruPost> posts;
  final ArtworkCellStyle style;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(style.radius(16));
    const white = Color(0xFFFFFFFF);
    final inset = style.inset(4);
    return Semantics(
      button: true,
      label: '$title${isSmart ? ' ${L10n.text('Smart Folder')}' : ''}, ${posts.length}',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: Color(color),
          shape: RoundedSuperellipseBorder(
            borderRadius: radius,
            side: style.removesPadding ? BorderSide.none : const BorderSide(color: Color(0x26FFFFFF), width: 0.5),
          ),
        ),
        child: ClipRSuperellipse(
          borderRadius: radius,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AspectRatio(
                aspectRatio: 1.25,
                child: Padding(
                  padding: EdgeInsets.all(style.inset(6)),
                  child: Column(
                    children: [
                      for (final row in [0, 2]) ...[
                        if (row > 0) SizedBox(height: inset),
                        Expanded(
                          child: Row(
                            children: [
                              for (final index in [row, row + 1]) ...[if (index > row) SizedBox(width: inset), Expanded(child: _cell(context, index))],
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              FolderCardCaption(title: title, isSmart: isSmart, count: posts.length, color: white, style: style),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cell(BuildContext context, int index) {
    final server = index < posts.length ? booru.server(posts[index].serverID) : null;
    return ClipRSuperellipse(
      borderRadius: BorderRadius.circular(style.radius(8)),
      child: ColoredBox(
        color: const Color(0x1FFFFFFF),
        child: SizedBox.expand(
          child: server == null
              ? Icon(Symbols.photo, size: style.fontSize(20), color: const Color(0x4DFFFFFF))
              : BooruThumbnail(post: posts[index], server: server, booru: booru),
        ),
      ),
    );
  }
}

/// `BooruFolderContentsView`: a folder's favorites, or all of them, with search,
/// selection to move or delete, and quick jumps.
class BooruFolderContentsView extends StatefulWidget {
  const BooruFolderContentsView({super.key, required this.booru, this.folderID, this.recents = false});
  final BooruContext booru;
  final String? folderID;

  /// Recently opened images, shown the way a folder shows its favorites.
  final bool recents;

  @override
  State<BooruFolderContentsView> createState() => _BooruFolderContentsViewState();
}

class _BooruFolderContentsViewState extends State<BooruFolderContentsView> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();
  final _visibility = ScrollSearchVisibility();
  final _keys = <String, GlobalKey>{};
  double _lastOffset = 0;
  bool _searchVisible = true;
  bool _selecting = false;
  Set<String> _selection = {};

  BooruContext get _booru => widget.booru;
  RecentImages? get _recents => widget.recents ? RecentImages.shared : null;
  List<BooruPost> get _posts {
    final recents = _recents;
    if (!widget.recents) return _booru.store.visibleFavorites(folderID: widget.folderID, query: _search.text);
    final servers = {for (final server in _booru.store.servers) server.id};
    return [
      for (final entry in recents?.entries ?? const <RecentImage>[])
        if (servers.contains(entry.post.serverID) && BooruStore.matches(entry.post, _search.text) && _booru.store.isShownInSafeMode(entry.post)) entry.post,
    ];
  }

  @override
  void initState() {
    super.initState();
    _booru.store.addListener(_changed);
    _recents?.addListener(_changed);
    _search.addListener(_changed);
    _searchFocus.addListener(() {
      if (_searchFocus.hasFocus) setState(() => _searchVisible = true);
    });
    _scroll.addListener(() {
      final visible = _visibility.update(_lastOffset, _scroll.offset, focused: _searchFocus.hasFocus);
      _lastOffset = _scroll.offset;
      if (visible != null && visible != _searchVisible) setState(() => _searchVisible = visible);
    });
  }

  @override
  void dispose() {
    _booru.store.removeListener(_changed);
    _recents?.removeListener(_changed);
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _open(BooruPost post) async {
    String? viewed;
    await BooruPostView.open(
      context,
      booru: _booru,
      post: post,
      posts: _posts,
      discovery: DiscoveryContext(origin: DiscoveryOrigin.library),
      willClose: (post) => viewed = post.id,
    );
    if (viewed != null && mounted) restoreViewerPosition(openedID: post.id, viewedID: viewed!, keys: _keys);
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
        if (!widget.recents) ContextMenuAction(title: L10n.text('Jump to Saved Month'), icon: CupertinoIcons.calendar, onSelected: _showMonths),
      ],
    );
  }

  /// Each save month, newest first by the order favorites appear.
  List<(String, String)> get _months {
    String format(double? seconds) {
      if (seconds == null) return L10n.text('No Date');
      final date = DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
      return '${date.year}-${date.month.toString().padLeft(2, '0')}';
    }

    final dates = _booru.store.favoriteSavedDates();
    final seen = <String>{};
    return [
      for (final post in _posts)
        if (format(dates[post.id]) case final month when seen.add(month)) (month, post.id),
    ];
  }

  Future<void> _showMonths() async {
    final months = _months;
    final chosen = await showAppSheet<String>(
      context,
      grabber: true,
      builder: (context, controller) => ScrollEdgeSheet(
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
                for (final (month, id) in months)
                  FormRow(
                    onTap: () => Navigator.of(context).pop(id),
                    child: Text(month, style: TegnalType.style(17, color: TegnalColors.tint.resolveFrom(context))),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _keys[chosen]?.currentContext;
      if (target != null) Scrollable.ensureVisible(target, duration: const Duration(milliseconds: 300));
    });
  }

  void _moveMenu(BuildContext buttonContext) => showActionMenu(
    buttonContext,
    anchor: anchorOf(buttonContext),
    actions: [
      for (final folder in _booru.store.folders())
        ContextMenuAction(
          title: folder.displayName,
          onSelected: () {
            _booru.store.moveFavorites(_posts.where((post) => _selection.contains(post.id)).toList(), folder.id);
            setState(() {
              _selection = {};
              _selecting = false;
            });
          },
        ),
    ],
  );

  Future<void> _confirmDelete() async {
    final delete = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('Delete Selected Items?')),
        content: widget.recents ? Text(L10n.text('They leave Recently Opened Images. Favorites stay saved.')) : null,
        actions: [
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Delete'))),
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
        ],
      ),
    );
    if (delete != true) return;
    final recents = _recents;
    if (recents != null) {
      for (final id in _selection) {
        recents.remove(id);
      }
    } else {
      _booru.store.removeFavorites(_posts.where((post) => _selection.contains(post.id)).toList());
    }
    setState(() {
      _selection = {};
      _selecting = false;
    });
  }

  Widget _toolbar(List<BooruPost> posts) => ToolbarGroup(
    children: [
      BooruServerMenuButton(store: _booru.store, grouped: true),
      if (_selecting) ...[
        ToolbarIconButton(
          label: L10n.text('Select All'),
          icon: CupertinoIcons.checkmark_circle_fill,
          onPressed: () => setState(() => _selection = {for (final post in posts) post.id}),
        ),
        if (!widget.recents)
          Builder(
            builder: (context) => ToolbarIconButton(
              label: L10n.text('Move to Another Folder'),
              icon: CupertinoIcons.folder,
              onPressed: _selection.isEmpty ? null : () => _moveMenu(context),
            ),
          ),
        ToolbarIconButton(label: L10n.text('Delete'), icon: CupertinoIcons.trash, onPressed: _selection.isEmpty ? null : _confirmDelete),
      ] else
        Builder(
          builder: (context) => ToolbarIconButton(
            label: L10n.text('Quick Jump'),
            icon: CupertinoIcons.arrow_up_arrow_down,
            onPressed: posts.isEmpty ? null : () => _jumpMenu(context),
          ),
        ),
      ToolbarIconButton(
        label: L10n.text(_selecting ? 'Done' : 'Select'),
        icon: _selecting ? CupertinoIcons.xmark : CupertinoIcons.checkmark_circle,
        onPressed: () => setState(() {
          _selecting = !_selecting;
          _selection = {};
        }),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final barBottom = MediaQuery.paddingOf(context).top + rootBarHeight;
    final posts = _posts;
    final folder = _booru.store.folders().where((folder) => folder.id == widget.folderID).firstOrNull;
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
                if (posts.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 48),
                      child: widget.recents
                          ? ContentUnavailable(
                              icon: (_recents?.entries.isEmpty ?? true) ? CupertinoIcons.clock : CupertinoIcons.search,
                              title: L10n.text((_recents?.entries.isEmpty ?? true) ? 'No Recent Images' : 'No Results'),
                              description: (_recents?.entries.isEmpty ?? true)
                                  ? L10n.text('Images you open in the viewer appear here.')
                                  : L10n.text("No results for '%@'", [_search.text]),
                            )
                          : ContentUnavailable(
                              icon: CupertinoIcons.heart,
                              title: L10n.text('No Favorites'),
                              description: L10n.text('Hold an image to save it, or choose Save to Folder from its menu.'),
                            ),
                    ),
                  )
                else
                  BooruPostGridSliver(
                    booru: _booru,
                    posts: posts,
                    selection: _selecting ? _selection : null,
                    toggleSelection: (post) => setState(() => _selection.contains(post.id) ? _selection.remove(post.id) : _selection.add(post.id)),
                    itemKey: (id) => _keys.putIfAbsent(id, GlobalKey.new),
                    open: _open,
                    hold: (context, post) => showBooruPostMenu(context, booru: _booru, post: post),
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
                  child: ScrollSearchBar(controller: _search, focusNode: _searchFocus, prompt: L10n.text(widget.recents ? 'Search tags' : 'Search Favorites')),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: RootHeader(
              title: widget.recents ? L10n.text('Recently Opened Images') : folder?.displayName ?? L10n.text('All Favorites'),
              state: _booru.state,
              onBack: () => Navigator.of(context).pop(),
              trailing: _toolbar(posts),
            ),
          ),
        ],
      ),
    );
  }
}

/// The context menu of a saved image: similar art, favorite, folder and share.
void showBooruPostMenu(BuildContext cardContext, {required BooruContext booru, required BooruPost post, DiscoveryContext? discovery}) {
  final saved = booru.store.isFavorite(post);
  final box = cardContext.findRenderObject()! as RenderBox;
  showContextMenu(
    cardContext,
    anchor: anchorOf(cardContext),
    child: SizedBox.fromSize(
      size: box.size,
      child: BooruThumbnailCard(
        post: post,
        style: ArtworkCellStyle(width: box.size.width),
        cover: booru.server(post.serverID) == null ? const SizedBox.shrink() : BooruThumbnail(post: post, server: booru.server(post.serverID)!, booru: booru),
      ),
    ),
    actions: [
      ContextMenuAction(
        title: WorkSaveResult.actionTitle(saved: saved, mode: TasteMode.booru),
        icon: CupertinoIcons.heart,
        onSelected: () => showWorkSaveFeedback(cardContext, booru.toggleFavorite(post, context: discovery), bottom: tabBarClearance(cardContext) + 8),
      ),
      ContextMenuAction(
        title: L10n.text('Save to Folder'),
        icon: CupertinoIcons.folder,
        onSelected: () => showBooruFolderPicker(cardContext, booru: booru, post: post, discovery: discovery),
      ),
    ],
  );
}

Future<void> showBooruFolderPicker(BuildContext context, {required BooruContext booru, required BooruPost post, DiscoveryContext? discovery}) =>
    pickBooruFolder(context, booru: booru, post: post, discovery: discovery);

/// Opens the folders and names the one the image went to, so the notice that offered the change
/// can say where it went.
Future<String?> pickBooruFolder(BuildContext context, {required BooruContext booru, required BooruPost post, DiscoveryContext? discovery}) async {
  String? filed;
  await showAppSheet<void>(
    context,
    grabber: true,
    medium: true,
    builder: (context, controller) =>
        BooruFolderPicker(booru: booru, post: post, discovery: discovery, scrollController: controller, filed: (name) => filed = name),
  );
  return filed;
}

/// `BooruFolderPicker`: saves the image into the chosen folder, in the folder list both modes share.
class BooruFolderPicker extends StatefulWidget {
  const BooruFolderPicker({super.key, required this.booru, required this.post, this.discovery, this.scrollController, this.filed});
  final BooruContext booru;
  final BooruPost post;
  final DiscoveryContext? discovery;
  final ScrollController? scrollController;
  final ValueChanged<String>? filed;

  @override
  State<BooruFolderPicker> createState() => _BooruFolderPickerState();
}

class _BooruFolderPickerState extends State<BooruFolderPicker> {
  String? _error;

  void _file(String id, String name) {
    try {
      widget.booru.store.saveFavorite(widget.post, folderID: id, context: widget.discovery);
      widget.filed?.call(name);
      Navigator.of(context).pop();
    } on Object catch (error) {
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.booru.store;
    final current = store.folderIDFor(widget.post);
    return FolderPickerSheet(
      scrollController: widget.scrollController,
      error: _error,
      rows: [
        for (final folder in store.folders()) FolderPickerRow(id: folder.id, name: folder.displayName, color: folder.color, isCurrent: folder.id == current),
      ],
      pick: (row) => _file(row.id, row.name),
      create: (name) {
        try {
          final id = store.saveFolder(name: name);
          _file(id, name.trim());
        } on Object catch (error) {
          setState(() => _error = '$error');
        }
      },
    );
  }
}
