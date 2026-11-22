import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/booru/booru_account.dart';
import '../../core/booru/booru_models.dart';
import '../../core/booru/booru_store.dart';
import '../../core/content/recent_works.dart';
import '../../core/storage/folder_rules.dart';
import '../../core/support/l10n.dart';
import '../../core/taste/taste_models.dart';
import '../content/content_bookmark.dart';
import '../content/explore_view.dart' show ScrollSearchVisibility;
import '../content/work_save_feedback.dart';
import '../design/app_sheet.dart';
import '../design/context_menu.dart';
import '../design/symbols.dart';
import '../design/tegnal_theme.dart';
import '../library/folder_color_sheet.dart';
import '../library/folder_name_prompt.dart';
import '../library/folder_order_view.dart';
import '../library/folder_rule_editor.dart';
import '../library/folders_view.dart'
    show ContentUnavailable, FolderBentoFrame, FolderCardCaption, LibrarySearchField, PressableCard, anchorOf, recentFolderColor;
import '../library/library_routes.dart' show showTransientMessage;
import '../navigation/app_header.dart';
import '../navigation/root_tab_view.dart';
import '../works/artwork_grid.dart';
import '../works/saved_date_view.dart';
import '../works/search_controls.dart';
import '../works/works_models.dart' show SavedMonth, SavedRun;
import 'booru_common.dart';
import 'booru_post_view.dart';
import '../design/alert_dialog.dart';
import '../library/folder_picker_sheet.dart';

/// `BooruFavoritesView`: Saved in image mode, laid out as comics mode's: the chosen servers' folders
/// and the global ones as bento cards, with a search of everything they hold. With several servers
/// chosen, each folder names its server.
class BooruFavoritesView extends StatefulWidget {
  const BooruFavoritesView({super.key, required this.booru});
  final BooruContext booru;

  @override
  State<BooruFavoritesView> createState() => _BooruFavoritesViewState();
}

class _BooruFavoritesViewState extends State<BooruFavoritesView> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
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
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _submitSearch(String text) {
    final query = text.trim();
    if (query.isEmpty) return;
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (context) => BooruFolderContentsView(booru: _booru, initialQuery: query),
      ),
    );
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

  /// One server chosen, a new folder is that server's; with several, the menu asks which, or global.
  /// With folders shared by all servers, a new folder is shared too.
  void _createMenu(BuildContext buttonContext) {
    final chosen = _booru.store.selectedServers;
    if (chosen.length < 2 || _booru.store.folderStyle == BooruFolderStyle.shared) {
      _createFolder(_booru.store.newFolderServer(chosen.firstOrNull?.id));
      return;
    }
    showActionMenu(
      buttonContext,
      anchor: anchorOf(buttonContext),
      actions: [
        for (final server in chosen)
          ContextMenuAction(
            title: server.displayName,
            symbol: (color) => ServerRackSymbol(color: color),
            onSelected: () => _createFolder(server.id),
          ),
        ContextMenuAction(title: L10n.text('Global Folder'), icon: CupertinoIcons.globe, onSelected: () => _createFolder(null)),
      ],
    );
  }

  /// A new folder of the server, or a global one without it.
  Future<void> _createFolder(String? serverID) async {
    try {
      await createFolderWithPrompt(context, library: BooruServerFolders(_booru.store, serverID), booru: true);
    } on Object catch (error) {
      if (mounted) showTransientMessage(context, '$error', bottom: tabBarClearance(context) + 8);
    }
    if (mounted) setState(() {});
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

  bool get _showsServerNames => _booru.store.selectedServerIDs.length > 1;

  void _openMenu(BuildContext cardContext, BooruFolder folder) {
    final uncategorized = folder.isUncategorized;
    showContextMenu(
      cardContext,
      anchor: anchorOf(cardContext),
      child: BooruFolderCard(
        booru: _booru,
        folder: folder,
        posts: _booru.store.visibleFavorites(folderID: folder.id),
        style: ArtworkCellStyle(width: anchorOf(cardContext).width),
        server: _showsServerNames ? _booru.store.serverNameOfFolder(folder) : null,
      ),
      actions: [
        ContextMenuAction(
          title: L10n.text('Change Color'),
          symbol: (color) => PaletteSymbol(color: color),
          onSelected: () => showAppSheet<void>(
            context,
            medium: true,
            builder: (context, controller) => FolderColorSheet(
              title: folder.displayName,
              color: folder.color,
              onSelected: (color) => _booru.store.setFolderColor(folder.id, color),
              preview: (color) => BooruFolderCard(
                booru: _booru,
                folder: folder,
                posts: _booru.store.visibleFavorites(folderID: folder.id),
                style: const ArtworkCellStyle(width: 132),
                color: color,
              ),
            ),
          ),
        ),
        ContextMenuAction(
          title: L10n.text('Reorder Folders'),
          icon: CupertinoIcons.arrow_up_arrow_down,
          onSelected: () => showAppSheet<void>(
            context,
            builder: (context, controller) => FolderOrderView<String>(
              // The folders Saved shows, each named with its server when several share a name.
              folders: [for (final folder in _booru.store.visibleFolders()) (id: folder.id, name: _booru.store.labeledName(folder))],
              save: _booru.store.reorderFolders,
            ),
          ),
        ),
        if (!uncategorized) ContextMenuAction(title: L10n.text('Rename Folder'), icon: CupertinoIcons.pencil, onSelected: () => _rename(folder)),
        // Uncategorized can be a smart folder like any other.
        ContextMenuAction(
          title: L10n.text('Smart Folder'),
          icon: CupertinoIcons.sparkles,
          onSelected: () => showAppSheet<void>(
            context,
            // An image folder sees its own server's folders and the global ones.
            builder: (context, controller) => FolderRuleEditor.existing(
              library: BooruServerFolders(_booru.store, folder.serverID),
              booru: true,
              folder: folder.id,
              scrollController: controller,
            ),
          ),
        ),
        // Each server keeps its own Uncategorized.
        if (!uncategorized) ...[
          ContextMenuAction(
            title: L10n.text('Global Folder'),
            icon: CupertinoIcons.globe,
            checked: folder.isGlobal,
            onSelected: () => _perform(
              () => _booru.store.setGlobal(
                folder.id,
                !folder.isGlobal,
                emptyServer: _booru.store.selectedServerID.isEmpty ? null : _booru.store.selectedServerID,
              ),
            ),
          ),
          ContextMenuAction(
            title: L10n.text('Delete Folder'),
            icon: CupertinoIcons.trash,
            destructive: true,
            onSelected: () {
              if (BooruAccountSync.shared?.isListFolder(folder.id) ?? false) {
                showTransientMessage(
                  context,
                  L10n.text(
                    "This folder holds a favorite group of a website you're signed in to, so it stays while you're signed in. To delete it, sign out of that website or turn off Sync Favorites with Folders in its settings.",
                  ),
                  bottom: tabBarClearance(context) + 8,
                );
              } else {
                _confirmDelete(folder);
              }
            },
          ),
        ],
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
    final folders = _booru.store.visibleFolders();
    final recents = _recents?.showsInSaved ?? false ? _recents : null;
    // Without a server chosen there are no folders but global ones, as Explore shows nothing.
    final noSelection = _booru.store.selectedServers.isEmpty && folders.isEmpty;
    return ColoredBox(
      color: TegnalColors.background.resolveFrom(context),
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => _searchFocus.unfocus(),
              child: CustomScrollView(
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.only(top: top),
                    sliver: SliverToBoxAdapter(
                      child: LibrarySearchField(
                        controller: _search,
                        focusNode: _searchFocus,
                        prompt: L10n.text('Search Favorites'),
                        onSubmitted: _submitSearch,
                      ),
                    ),
                  ),
                  if (noSelection)
                    const SliverToBoxAdapter(
                      child: Padding(padding: EdgeInsets.only(top: 60), child: BooruNoSelectionView()),
                    )
                  else
                    ArtworkGridSliver(
                      folders: true,
                      topMarginScale: 26 / 16,
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
                              server: _showsServerNames ? _booru.store.serverNameOfFolder(folder) : null,
                            ),
                          ),
                        );
                      },
                    ),
                  SliverToBoxAdapter(child: SizedBox(height: tabBarClearance(context))),
                ],
              ),
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
                  Builder(
                    builder: (buttonContext) => ToolbarIconButton(
                      label: L10n.text('Create Folder'),
                      icon: CupertinoIcons.folder_badge_plus,
                      size: 24,
                      onPressed: () => _createMenu(buttonContext),
                    ),
                  ),
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

/// `BooruFolderCard`: the folder's color with four favorites on tinted cells and its caption.
class BooruFolderCard extends StatelessWidget {
  /// `color` draws the card in another color, as the color sheet previews it.
  /// `server` takes the count's place, naming the folder's server when several are chosen.
  BooruFolderCard({super.key, required this.booru, required BooruFolder folder, required this.posts, required this.style, int? color, this.server})
    : title = folder.plainName,
      isSmart = folder.isSmart,
      isGlobal = folder.isGlobal,
      color = color ?? folder.color;

  /// Recently opened images as a folder card in Saved.
  BooruFolderCard.recent({super.key, required this.booru, required this.posts, required this.style})
    : title = L10n.text('Recent Images'),
      isSmart = false,
      isGlobal = false,
      server = null,
      color = recentFolderColor;

  final BooruContext booru;
  final String title;
  final bool isSmart;
  final bool isGlobal;
  final String? server;
  final int color;
  final List<BooruPost> posts;
  final ArtworkCellStyle style;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(style.radius(16));
    // Light colors such as yellow take dark text, as comics folders do.
    final text = FolderBentoFrame.textColor(color);
    final inset = style.inset(4);
    return Semantics(
      button: true,
      label: '$title${isSmart ? ' ${L10n.text('Smart Folder')}' : ''}${isGlobal ? ', ${L10n.text('Global Folder')}' : ''}, ${server ?? posts.length}',
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
                              for (final index in [row, row + 1]) ...[if (index > row) SizedBox(width: inset), Expanded(child: _cell(context, index, text))],
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              FolderCardCaption(title: title, isSmart: isSmart, count: posts.length, color: text, style: style, detail: server, isGlobal: isGlobal),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cell(BuildContext context, int index, Color text) {
    final server = index < posts.length ? booru.server(posts[index].serverID) : null;
    return ClipRSuperellipse(
      borderRadius: BorderRadius.circular(style.radius(8)),
      child: ColoredBox(
        color: text.withValues(alpha: 0.12),
        child: SizedBox.expand(
          child: server == null
              ? Icon(Symbols.photo, size: style.fontSize(20), color: text.withValues(alpha: 0.3))
              : BooruThumbnail(post: posts[index], server: server, booru: booru),
        ),
      ),
    );
  }
}

/// `BooruFolderContentsView`: a folder's favorites, or all of them, with search,
/// selection to move or delete, and quick jumps.
class BooruFolderContentsView extends StatefulWidget {
  const BooruFolderContentsView({super.key, required this.booru, this.folderID, this.recents = false, this.initialQuery = ''});
  final BooruContext booru;
  final String? folderID;

  /// Saved's search: every folder shown there, searched for this.
  final String initialQuery;

  /// Recently opened images, shown the way a folder shows its favorites.
  final bool recents;

  @override
  State<BooruFolderContentsView> createState() => _BooruFolderContentsViewState();
}

class _BooruFolderContentsViewState extends State<BooruFolderContentsView> {
  late final _search = TextEditingController(text: widget.initialQuery);
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
        if (!widget.recents) ContextMenuAction(title: L10n.text('Browse by Saved Date'), icon: CupertinoIcons.calendar, onSelected: _showMonths),
      ],
    );
  }

  /// Favorites by when they were saved: runs saved together, and months.
  Future<void> _showMonths() async {
    final dates = _booru.store.favoriteSavedDates();
    DateTime? date(String id) => dates[id] == null ? null : DateTime.fromMillisecondsSinceEpoch((dates[id]! * 1000).round());
    String month(DateTime? date) => date == null ? '' : '${date.year}-${date.month.toString().padLeft(2, '0')}';
    final shown = [for (final post in _posts) (id: post.id, date: date(post.id))];
    final setUp = BooruAccountSync.shared?.setUpTimes ?? const <String, DateTime>{};
    final chosen = await SavedDateView.show<String>(
      context,
      months: SavedMonth.group([for (final item in shown) (id: item.id, month: month(item.date))]),
      runs: SavedRun.group(shown),
      broughtIn: [for (final server in {for (final post in _posts) post.serverID}) ?setUp[server]],
      identifier: 'booru',
      images: true,
    );
    if (chosen == null || !mounted) return;
    if (chosen.select) {
      setState(() {
        _selection = {...chosen.ids};
        _selecting = true;
      });
    }
    final first = _posts.where((post) => chosen.ids.contains(post.id)).firstOrNull?.id;
    if (first == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _keys[first]?.currentContext;
      if (target != null) Scrollable.ensureVisible(target, duration: const Duration(milliseconds: 300));
    });
  }

  /// Folders that may hold every image chosen: global ones, and one server's own when all are its.
  void _moveMenu(BuildContext buttonContext) {
    final chosen = _posts.where((post) => _selection.contains(post.id)).toList();
    final servers = {for (final post in chosen) post.serverID};
    showActionMenu(
      buttonContext,
      anchor: anchorOf(buttonContext),
      actions: [
        for (final folder in _booru.store.folders())
          if (servers.every(folder.holds))
            ContextMenuAction(
              title: folder.displayName,
              onSelected: () {
                _booru.store.moveFavorites(chosen, folder.id);
                setState(() {
                  _selection = {};
                  _selecting = false;
                });
              },
            ),
      ],
    );
  }

  Future<void> _confirmDelete() async {
    final chosen = _posts.where((post) => _selection.contains(post.id)).toList();
    final accounts = BooruAccountSync.shared;
    final synced = !widget.recents && (accounts?.syncsAny(chosen) ?? false);
    // The dialog answers whether to keep the images on the website; null cancels.
    final keepOnServer = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('Delete Selected Items?')),
        content: Text(
          widget.recents
              ? L10n.text('They leave Recently Opened Images. Favorites stay saved.')
              : [
                  L10n.text('%@ images will be deleted.', ['${_selection.length}']),
                  if (synced) L10n.text('Some of them are favorites on a website synced with your folders.'),
                ].join('\n'),
        ),
        actions: [
          if (synced) ...[
            CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Delete Here and on Website'))),
            CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Delete in App Only'))),
          ] else
            CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Delete'))),
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('Cancel'))),
        ],
      ),
    );
    if (keepOnServer == null) return;
    final recents = _recents;
    if (recents != null) {
      for (final id in _selection) {
        recents.remove(id);
      }
    } else if (accounts != null) {
      accounts.removeFavorites(chosen, keepOnServer: keepOnServer);
    } else {
      _booru.store.removeFavorites(chosen);
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
    // The image's own server's folders and the global ones; a folder made here is its server's.
    final current = store.folderIDFor(widget.post);
    return FolderPickerSheet(
      scrollController: widget.scrollController,
      error: _error,
      rows: [
        for (final folder in store.foldersForServer(widget.post.serverID))
          FolderPickerRow(id: folder.id, name: folder.displayName, color: folder.color, isCurrent: folder.id == current, isGlobal: folder.isGlobal),
      ],
      pick: (row) => _file(row.id, row.name),
      library: BooruServerFolders(store, widget.post.serverID),
      booru: true,
      create: (id) => _file(id, store.folders().where((folder) => folder.id == id).firstOrNull?.displayName ?? ''),
    );
  }
}
