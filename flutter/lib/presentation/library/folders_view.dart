import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/content/recent_works.dart';
import '../../core/storage/app_database.dart';
import '../../core/support/l10n.dart';
import '../../domain/models.dart';
import '../design/context_menu.dart';
import '../design/symbols.dart';
import '../design/tegnal_theme.dart';
import '../navigation/app_header.dart';
import '../navigation/app_state.dart';
import '../navigation/root_tab_view.dart';
import '../settings/recent_works_page.dart';
import '../works/artwork_grid.dart';
import 'folder_name_prompt.dart';
import 'library_routes.dart';
import 'local_thumbnail.dart';
import '../design/alert_dialog.dart';

/// `FoldersView`: the comics library's folders as bento cards, with the saved-works search.
class FoldersView extends StatefulWidget {
  const FoldersView({super.key, required this.state, required this.routes});
  final AppState state;
  final LibraryRoutes routes;

  @override
  State<FoldersView> createState() => _FoldersViewState();
}

class _FoldersViewState extends State<FoldersView> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  List<Folder> _folders = [];
  Map<int, List<Work>> _previews = {};

  AppDatabase get _database => widget.routes.database;

  /// Commits from imports and the cover queue, gathered so a fill redraws the folders at most a
  /// few times a second.
  StreamSubscription<int>? _libraryChanges;
  Timer? _pendingReload;

  /// The app's recent works, which Saved can show as a folder.
  RecentWorks? get _recents => RecentWorks.shared;
  bool get _showsRecents => _recents?.showsInSaved ?? false;
  void _recentsChanged() => setState(() {});

  @override
  void initState() {
    super.initState();
    _reload();
    _recents?.addListener(_recentsChanged);
    widget.routes.changes.addListener(_reload);
    _libraryChanges = _database.changes.listen((_) => _pendingReload ??= Timer(const Duration(milliseconds: 300), _reload));
  }

  @override
  void dispose() {
    _libraryChanges?.cancel();
    _pendingReload?.cancel();
    _recents?.removeListener(_recentsChanged);
    widget.routes.changes.removeListener(_reload);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _reload() {
    _pendingReload?.cancel();
    _pendingReload = null;
    if (!mounted) return;
    setState(() {
      _folders = _database.listFolders();
      _previews = _database.folderPreviews();
    });
  }

  void _submitSearch(String text) {
    final query = text.trim();
    if (query.isNotEmpty) widget.routes.openSearch(context, query);
  }

  Future<void> _createFolder() async {
    final result = await showFolderNamePrompt(context, alternateTitle: L10n.text('Make a Smart Folder'));
    if (!mounted || result == null) return;
    if (result.alternate) {
      await widget.routes.composeSmartFolder(context, name: result.name);
    } else if (result.name.isNotEmpty) {
      _database.createFolder(name: result.name);
    }
    widget.routes.notifyChanged();
  }

  void _openMenu(BuildContext cardContext, Folder folder) {
    final unfiled = folder.name == '미분류';
    final id = folder.id;
    if (id == null) return;
    showContextMenu(
      cardContext,
      anchor: anchorOf(cardContext),
      child: FolderBentoCard(folder: folder, previews: _previews[id] ?? const [], style: _style(cardContext)),
      actions: [
        ContextMenuAction(
          title: L10n.text('Change Color'),
          symbol: (color) => PaletteSymbol(color: color),
          onSelected: () => widget.routes.changeColor(context, folder),
        ),
        ContextMenuAction(
          title: L10n.text('Reorder Folders'),
          icon: CupertinoIcons.arrow_up_arrow_down,
          onSelected: () => widget.routes.reorderFolders(context),
        ),
        if (!unfiled) ...[
          ContextMenuAction(title: L10n.text('Rename Folder'), icon: CupertinoIcons.pencil, onSelected: () => _rename(folder)),
          ContextMenuAction(title: L10n.text('Smart Folder'), icon: CupertinoIcons.sparkles, onSelected: () => widget.routes.editSmartFolder(context, folder)),
        ],
        ContextMenuAction(
          title: L10n.text('Delete Folder'),
          icon: CupertinoIcons.trash,
          destructive: true,
          onSelected: () => unfiled ? _delete(id) : _confirmDelete(folder),
        ),
      ],
    );
  }

  void _openRecents(BuildContext context, RecentWorks recents) => Navigator.of(context).push(
    CupertinoPageRoute<void>(
      builder: (_) => RecentWorksPage(recents: recents, open: (context, id) => widget.routes.contentRoutes.openThumbnail(context, id)),
    ),
  );

  void _openRecentsMenu(BuildContext cardContext, RecentWorks recents) => showContextMenu(
    cardContext,
    anchor: anchorOf(cardContext),
    child: RecentWorksFolderCard(recents: recents, style: _style(cardContext)),
    actions: [ContextMenuAction(title: L10n.text('Hide from Saved'), icon: CupertinoIcons.eye_slash, onSelected: () => recents.setShowsInSaved(false))],
  );

  ArtworkCellStyle _style(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    return ArtworkCellStyle(width: box?.size.width ?? 160);
  }

  Future<void> _rename(Folder folder) async {
    final result = await showFolderNamePrompt(context, title: 'Rename Folder', actionTitle: 'Save', initialName: folder.name);
    if (!mounted || result == null || result.name.isEmpty || folder.id == null) return;
    try {
      _database.renameFolder(folder.id!, result.name);
      widget.routes.notifyChanged();
    } on Object catch (error) {
      _showError('$error');
    }
  }

  Future<void> _confirmDelete(Folder folder) async {
    final delete = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text("Delete the folder '%@'?", [folder.displayName])),
        content: Text(L10n.text('Works in this folder will be moved to Unfiled.')),
        actions: [
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Delete'))),
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
        ],
      ),
    );
    if (delete == true && folder.id != null) _delete(folder.id!);
  }

  void _delete(int id) {
    try {
      _database.deleteFolder(id);
    } on Object catch (error) {
      widget.routes.showMessage(context, '$error');
    }
    widget.routes.notifyChanged();
  }

  void _showError(String message) => showCupertinoDialog<void>(
    context: context,
    builder: (context) => TegnalAlertDialog(
      title: Text(L10n.text('Error')),
      content: Text(message),
      actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('OK')))],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final top = rootContentTop(context);
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
                        prompt: L10n.text('Search saved works'),
                        onSubmitted: _submitSearch,
                      ),
                    ),
                  ),
                  if (_folders.isEmpty && !_showsRecents)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 60),
                        child: ContentUnavailable(
                          icon: CupertinoIcons.folder,
                          title: L10n.text('No Folders'),
                          description: L10n.text('Create a folder to organize your works.'),
                        ),
                      ),
                    )
                  else
                    ArtworkGridSliver(
                      itemCount: _folders.length + (_showsRecents ? 1 : 0),
                      preferences: widget.routes.folderGrid,
                      topMarginScale: 26 / 16,
                      itemBuilder: (context, index, style) {
                        final recents = _recents;
                        if (_showsRecents && recents != null) {
                          if (index == 0) {
                            return Builder(
                              builder: (cardContext) => PressableCard(
                                key: const ValueKey('manga.recentFolder'),
                                onTap: () => _openRecents(context, recents),
                                onLongPress: () => _openRecentsMenu(cardContext, recents),
                                child: RecentWorksFolderCard(recents: recents, style: style),
                              ),
                            );
                          }
                          index -= 1;
                        }
                        final folder = _folders[index];
                        return Builder(
                          builder: (cardContext) => PressableCard(
                            onTap: () => widget.routes.openFolder(context, folder),
                            onLongPress: () => _openMenu(cardContext, folder),
                            child: FolderBentoCard(folder: folder, previews: _previews[folder.id] ?? const [], style: style),
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
              state: widget.state,
              trailing: ToolbarGroup(
                children: [
                  ToolbarIconButton(label: L10n.text('Create Folder'), icon: CupertinoIcons.folder_badge_plus, size: 24, onPressed: _createFolder),
                  ToolbarIconButton(label: L10n.text('Add Work Number'), icon: CupertinoIcons.plus, size: 24, onPressed: () => widget.routes.addWork(context)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The global rectangle of `context`'s render box.
Rect anchorOf(BuildContext context) {
  final box = context.findRenderObject()! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// A card that dims slightly while touched, opens on tap and shows its menu on a hold.
class PressableCard extends StatefulWidget {
  const PressableCard({super.key, required this.child, required this.onTap, required this.onLongPress});
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<PressableCard> createState() => PressableCardState();
}

class PressableCardState extends State<PressableCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapDown: (_) => setState(() => _pressed = true),
    onTapCancel: () => setState(() => _pressed = false),
    onTapUp: (_) => setState(() => _pressed = false),
    onTap: widget.onTap,
    onLongPress: () {
      setState(() => _pressed = false);
      widget.onLongPress();
    },
    child: AnimatedScale(scale: _pressed ? 0.97 : 1, duration: const Duration(milliseconds: 120), child: widget.child),
  );
}

/// `FolderBentoCard`: the folder's color with its four newest covers and a caption.
class FolderBentoCard extends StatelessWidget {
  const FolderBentoCard({super.key, required this.folder, required this.previews, required this.style});
  final Folder folder;
  final List<Work> previews;
  final ArtworkCellStyle style;

  @override
  Widget build(BuildContext context) => FolderBentoFrame(
    color: folder.color,
    title: folder.plainName,
    isSmart: folder.isSmart,
    count: folder.workCount,
    style: style,
    cell: (index, text) {
      if (index >= previews.length) return FolderBentoFrame.emptyCell(style, text);
      final work = previews[index];
      final path = work.thumbStatus == 'ready' ? work.thumbPath : null;
      final placeholder = FolderBentoFrame.placeholder(style, text, work.galleryId);
      return FolderBentoFrame.clip(
        style,
        path == null ? placeholder : LocalThumbnail(path: path, revision: '${work.thumbPage ?? 1}', placeholder: placeholder),
      );
    },
  );
}

/// The neutral color the recent folder wears in Saved; it is not a folder the user colors.
const recentFolderColor = 0xFF636366;

/// Recently opened works as a folder card in Saved, with the latest covers.
class RecentWorksFolderCard extends StatelessWidget {
  const RecentWorksFolderCard({super.key, required this.recents, required this.style});
  final RecentWorks recents;
  final ArtworkCellStyle style;

  @override
  Widget build(BuildContext context) {
    final entries = recents.entries.take(4).toList();
    return FolderBentoFrame(
      color: recentFolderColor,
      title: L10n.text('Recent Works'),
      count: recents.entries.length,
      style: style,
      cell: (index, text) {
        if (index >= entries.length) return FolderBentoFrame.emptyCell(style, text);
        final id = entries[index].id;
        final cover = recents.cover(id);
        final placeholder = FolderBentoFrame.placeholder(style, text, id);
        return FolderBentoFrame.clip(style, cover == null ? placeholder : Image.memory(cover, fit: BoxFit.cover, gaplessPlayback: true));
      },
    );
  }
}

/// The comics folder card's frame: a 2×2 preview above the caption, on the folder's color.
class FolderBentoFrame extends StatelessWidget {
  const FolderBentoFrame({
    super.key,
    required this.color,
    required this.title,
    this.isSmart = false,
    required this.count,
    required this.style,
    required this.cell,
  });
  final int color;
  final String title;
  final bool isSmart;
  final int count;
  final ArtworkCellStyle style;

  /// The preview at `index`, drawn with the caption's text color.
  final Widget Function(int index, Color text) cell;

  /// White or black text by the background's luminance, as the native card decides.
  static Color textColor(int color) {
    final r = ((color >> 16) & 0xFF) / 255, g = ((color >> 8) & 0xFF) / 255, b = (color & 0xFF) / 255;
    return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.48 ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
  }

  /// An empty slot when there are fewer than four covers.
  static Widget emptyCell(ArtworkCellStyle style, Color text) => DecoratedBox(
    decoration: ShapeDecoration(
      color: text.withValues(alpha: 0.08),
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(style.radius(8))),
    ),
    child: const SizedBox.expand(),
  );

  /// A cover not available yet: the work's number on a tinted tile.
  static Widget placeholder(ArtworkCellStyle style, Color text, int galleryID) => DecoratedBox(
    decoration: ShapeDecoration(
      color: text.withValues(alpha: 0.14),
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(style.radius(8))),
    ),
    child: Center(
      child: Padding(
        padding: EdgeInsets.all(style.inset(2)),
        child: Text(
          '$galleryID',
          maxLines: 1,
          overflow: TextOverflow.clip,
          softWrap: false,
          style: TegnalType.style(style.fontSize(10), weight: FontWeight.w600, color: text.withValues(alpha: 0.85)),
          textScaler: TextScaler.noScaling,
        ),
      ),
    ),
  );

  static Widget clip(ArtworkCellStyle style, Widget child) => ClipRSuperellipse(
    borderRadius: BorderRadius.circular(style.radius(8)),
    child: SizedBox.expand(child: child),
  );

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(style.radius(16));
    final shape = RoundedSuperellipseBorder(
      borderRadius: radius,
      side: style.removesPadding ? BorderSide.none : const BorderSide(color: Color(0x26FFFFFF), width: 0.5),
    );
    final inset = style.inset(4);
    final text = textColor(color);
    return Semantics(
      button: true,
      label: '$title${isSmart ? ' ${L10n.text('Smart Folder')}' : ''}, $count',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: Color(color),
          shape: shape,
          shadows: [BoxShadow(color: const Color(0x1A000000), blurRadius: style.inset(8) * 2, offset: Offset(0, style.inset(3)))],
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
                              for (final index in [row, row + 1]) ...[if (index > row) SizedBox(width: inset), Expanded(child: cell(index, text))],
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              FolderCardCaption(title: title, isSmart: isSmart, count: count, color: text, style: style),
            ],
          ),
        ),
      ),
    );
  }
}

/// `FolderCardCaption`: the name, a smart mark, and the count at the trailing baseline.
class FolderCardCaption extends StatelessWidget {
  const FolderCardCaption({super.key, required this.title, this.isSmart = false, required this.count, required this.color, required this.style});
  final String title;
  final bool isSmart;
  final int count;
  final Color color;
  final ArtworkCellStyle style;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final titleStyle = TegnalType.style(style.fontSize(scaler.scale(15), minimum: 10), weight: FontWeight.w700, color: color);
    return Padding(
      padding: EdgeInsets.fromLTRB(style.inset(10), style.inset(10 / 3), style.inset(10), style.inset(8)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle, textScaler: TextScaler.noScaling),
                ),
                if (isSmart) ...[SizedBox(width: style.inset(3)), Text('✦', style: titleStyle, textScaler: TextScaler.noScaling)],
              ],
            ),
          ),
          SizedBox(width: style.inset(6)),
          Text(
            '$count',
            style: TegnalType.style(style.fontSize(scaler.scale(11), minimum: 9), weight: FontWeight.w600, color: color.withValues(alpha: 0.85)),
            textScaler: TextScaler.noScaling,
          ),
        ],
      ),
    );
  }
}

/// `ContentUnavailableView`: a large secondary symbol, a title and a description.
class ContentUnavailable extends StatelessWidget {
  const ContentUnavailable({super.key, required this.icon, required this.title, this.description, this.action});
  final IconData icon;
  final String title;
  final String? description;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: secondary),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TegnalType.style(22, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
          ),
          if (description != null) ...[
            const SizedBox(height: 8),
            Text(
              description!,
              textAlign: TextAlign.center,
              style: TegnalType.style(15, color: secondary),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}

/// The `.searchable` field under the toolbar: a 42 pt rounded search field.
class LibrarySearchField extends StatelessWidget {
  const LibrarySearchField({super.key, required this.controller, required this.focusNode, required this.prompt, required this.onSubmitted});
  final TextEditingController controller;
  final FocusNode focusNode;
  final String prompt;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        height: 42,
        decoration: ShapeDecoration(color: TegnalColors.searchFieldFill.resolveFrom(context), shape: const StadiumBorder()),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(CupertinoIcons.search, size: 20, color: secondary),
            const SizedBox(width: 8),
            Expanded(
              child: CupertinoTextField.borderless(
                controller: controller,
                focusNode: focusNode,
                placeholder: prompt,
                placeholderStyle: TegnalType.style(17, color: secondary),
                style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context)),
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.search,
                padding: EdgeInsets.zero,
                onSubmitted: onSubmitted,
                clearButtonMode: OverlayVisibilityMode.editing,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
