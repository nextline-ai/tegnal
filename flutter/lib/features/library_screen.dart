import 'package:material_ui/material_ui.dart';

import '../core/app_controller.dart';
import '../core/content.dart';
import '../core/library.dart';
import '../data/library_store.dart';
import '../ui/common.dart';
import '../ui/content_tile.dart';
import '../ui/artwork_layout.dart';
import '../ui/folder_tools.dart';
import '../ui/l10n.dart';
import '../ui/page_header.dart';
import '../ui/native_symbols.dart';
import '../ui/session_image.dart';
import '../ui/source_picker.dart';
import '../ui/thumbnail_image_provider.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.controller,
    required this.onOpen,
    this.mode,
    this.onOpenSequence,
    this.onDetails,
  });
  final AppController controller;
  final void Function(ContentItem) onOpen;
  final AppMode? mode;
  final void Function(ContentItem, List<ContentItem>)? onOpenSequence;
  final ValueChanged<ContentItem>? onDetails;
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  AppMode get _mode => widget.mode ?? widget.controller.mode;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final mode = _mode;
      final allFolders = widget.controller.folders(mode);
      final unfiledIds = _unfiledFolderIds(widget.controller, mode, allFolders);
      final folders = allFolders
          .where((folder) => !unfiledIds.contains(folder.id))
          .toList();
      final overview = widget.controller.store.libraryOverview(
        mode,
        unfiledFolderIds: unfiledIds,
      );
      final unfiled = overview.unfiled;
      final layout = ArtworkLayout.snapshot(widget.controller, mode);
      final unfiledColor =
          allFolders
              .where((folder) => unfiledIds.contains(folder.id))
              .firstOrNull
              ?.color ??
          widget.controller.store.setting(
            'unfiledColor.${mode.name}',
            0xFF66BB6A,
          ) as int;
      final unfiledFolder = allFolders
          .where((folder) => unfiledIds.contains(folder.id))
          .firstOrNull;
      final unfiledPosition =
          unfiledFolder?.position ??
          (widget.controller.store.setting(
            'unfiledPosition.${mode.name}',
            -1,
          ) as num).toInt();
      final orderedFolders = <LibraryFolder>[
        if (mode == AppMode.manga &&
            (unfiledFolder != null ||
                unfiled.count > 0 ||
                widget.controller.store.setting(
                      'unfiledVisible.${mode.name}',
                      true,
                    ) ==
                    true))
          unfiledFolder ??
              LibraryFolder(
                id: 'unsorted',
                mode: mode,
                name: L10n.tr(context, 'Unfiled'),
                color: unfiledColor,
                position: unfiledPosition,
              ),
        ...folders,
      ]..sort((a, b) => a.position.compareTo(b.position));
      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: TegnalFloatingHeader(
          header: TegnalPageHeader(
            controller: widget.controller,
            mode: mode,
            title: 'Saved',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: () =>
                      _editFolder(context, widget.controller, mode: mode),
                  style: IconButton.styleFrom(padding: const EdgeInsets.all(8)),
                  icon: Icon(
                    Icons.create_new_folder_outlined,
                    size: 30,
                    semanticLabel: L10n.tr(context, 'Create Folder'),
                  ),
                ),
                if (mode == AppMode.booru)
                  IconButton(
                    onPressed: () =>
                        showBooruSourcePicker(context, widget.controller),
                    style: IconButton.styleFrom(
                      padding: const EdgeInsets.all(8),
                    ),
                    icon: TegnalServerIcon(
                      size: 30,
                      semanticLabel: L10n.tr(context, 'Servers'),
                    ),
                  ),
                if (mode == AppMode.manga)
                  IconButton(
                    onPressed: () => _addWork(context, mode),
                    style: IconButton.styleFrom(
                      padding: const EdgeInsets.all(8),
                    ),
                    icon: Icon(
                      Icons.add,
                      size: 30,
                      semanticLabel: L10n.tr(context, 'Add Work Number'),
                    ),
                  ),
              ],
            ),
          ),
          child: CustomScrollView(
            slivers: [
              const SliverToBoxAdapter(
                child: SizedBox(height: tegnalHeaderExtent),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 11, 16, 14),
                sliver: SliverToBoxAdapter(
                  child: _allFavorites(context, overview.totalCount),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.symmetric(
                  horizontal: layout.removesPadding ? 0 : 16,
                ),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) => SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: layout.columns(
                        constraints.crossAxisExtent,
                        folders: true,
                      ),
                      mainAxisSpacing: layout.removesPadding ? 0 : 14,
                      crossAxisSpacing: layout.removesPadding ? 0 : 14,
                      childAspectRatio: 1.04,
                    ),
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final folder = orderedFolders[index];
                      final builtIn =
                          folder.id == 'unsorted' ||
                          unfiledIds.contains(folder.id);
                      return _folderCard(
                        context,
                        builtIn ? 'unsorted' : folder.id,
                        builtIn ? L10n.tr(context, 'Unfiled') : folder.name,
                        builtIn
                            ? unfiled
                            : overview.folders[folder.id] ??
                                  const LibraryFolderOverview(),
                        Color(builtIn ? unfiledColor : folder.color),
                        layout: layout,
                        folder: folder,
                        unfiled: builtIn,
                      );
                    }, childCount: orderedFolders.length),
                  ),
                ),
              ),
              if (overview.totalCount == 0)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(28, 24, 28, 8),
                    child: Text(
                      L10n.tr(
                        context,
                        'Save works as you explore, then organize them into folders.',
                      ),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              SliverToBoxAdapter(child: const NavigationScrollSpacer()),
            ],
          ),
        ),
      );
    },
  );

  Widget _allFavorites(BuildContext context, int count) => Semantics(
    button: true,
    label: '${L10n.tr(context, 'All Favorites')}, $count',
    child: TextButton(
      onPressed: () => _openFolder(null, L10n.tr(context, 'All Favorites')),
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: Row(
          children: [
            Icon(
              Icons.grid_view,
              size: 26,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                L10n.tr(context, 'All Favorites'),
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 17,
                color: Theme.of(context).colorScheme.primary
                    .withValues(alpha: .7),
              ),
            ),
            const SizedBox(width: 12),
            Icon(
              Icons.chevron_right,
              size: 24,
              color: Theme.of(context).colorScheme.primary
                  .withValues(alpha: .7),
            ),
          ],
        ),
      ),
    ),
  );

  void _openFolder(String? id, String title) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _SavedCollection(
        controller: widget.controller,
        onOpen: widget.onOpen,
        folderId: id,
        title: title,
        mode: _mode,
        onOpenSequence: widget.onOpenSequence,
        onDetails: widget.onDetails,
      ),
    ),
  );

  Future<void> _addWork(BuildContext context, AppMode mode) async {
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _AddWorkSheet(controller: widget.controller, mode: mode),
    );
  }

  Widget _folderCard(
    BuildContext context,
    String? id,
    String name,
    LibraryFolderOverview overview,
    Color color, {
    required ArtworkLayout layout,
    LibraryFolder? folder,
    bool unfiled = false,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final plain = layout.removesPadding;
      final scale = (constraints.maxWidth / 160).clamp(.2, 1.0);
      final argb = color.toARGB32();
      final luminance =
          .2126 * ((argb >> 16) & 255) +
          .7152 * ((argb >> 8) & 255) +
          .0722 * (argb & 255);
      final textColor = _mode == AppMode.manga && luminance > 255 * .48
          ? Colors.black
          : Colors.white;
      return Semantics(
        button: true,
        label: '$name, ${overview.count}',
        child: GestureDetector(
          onTap: () => _openFolder(id, name),
          onLongPress: folder == null
              ? null
              : () => _folderActions(context, folder, unfiled: unfiled),
          onSecondaryTap: folder == null
              ? null
              : () => _folderActions(context, folder, unfiled: unfiled),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(layout.removesPadding ? 0 : 16),
            child: ColoredBox(
              color: color,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        plain ? 0 : 6 * scale,
                        plain ? 0 : 6 * scale,
                        plain ? 0 : 6 * scale,
                        0,
                      ),
                      child: Column(
                        children: [
                          for (var row = 0; row < 2; row++) ...[
                            if (row > 0)
                              SizedBox(height: plain ? 0 : 4 * scale),
                            Expanded(
                              child: Row(
                                children: [
                                  for (
                                    var column = 0;
                                    column < 2;
                                    column++
                                  ) ...[
                                    if (column > 0)
                                      SizedBox(width: plain ? 0 : 4 * scale),
                                    Expanded(
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(
                                          plain ? 0 : 8 * scale,
                                        ),
                                        child: SizedBox.expand(
                                          child:
                                              row * 2 + column <
                                                  overview.previews.length
                                              ? _cover(
                                                  overview.previews[row * 2 +
                                                      column],
                                                  color,
                                                )
                                              : ColoredBox(
                                                  color: Colors.white
                                                      .withValues(alpha: .13),
                                                ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      plain ? 0 : 10 * scale,
                      plain ? 0 : 3.33 * scale,
                      plain ? 0 : 10 * scale,
                      plain ? 0 : 8 * scale,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          L10n.tr(
                            context,
                            '%@ items',
                          ).replaceAll('%@', '${overview.count}'),
                          style: TextStyle(
                            fontSize: (11 * scale).clamp(9.0, 11.0),
                            fontWeight: FontWeight.w600,
                            color: textColor.withValues(alpha: .85),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _cover(ContentItem item, Color color) => item.thumbnailUrl == null
      ? ColoredBox(
          color: Colors.white.withValues(alpha: .13),
          child: const Center(
            child: Icon(Icons.image_outlined, color: Colors.white, size: 24),
          ),
        )
      : SessionImage(
          url: item.thumbnailUrl!,
          fit: BoxFit.cover,
          cacheWidth: 320,
          referer: item.pageUrl,
          errorBuilder: (_, _, _) => ColoredBox(
            color: Colors.white.withValues(alpha: .13),
            child: const Center(
              child: Icon(Icons.image_outlined, color: Colors.white, size: 24),
            ),
          ),
        );

  Future<void> _folderActions(
    BuildContext context,
    LibraryFolder folder, {
    bool unfiled = false,
  }) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                folder.name,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.palette_outlined),
              title: Text(L10n.tr(context, 'Change Color')),
              onTap: () => Navigator.pop(context, 'color'),
            ),
            ListTile(
              leading: const Icon(Icons.swap_vert),
              title: Text(L10n.tr(context, 'Reorder Folders')),
              onTap: () => Navigator.pop(context, 'order'),
            ),
            if (!unfiled)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(L10n.tr(context, 'Rename Folder')),
                onTap: () => Navigator.pop(context, 'rename'),
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(L10n.tr(context, 'Delete Folder')),
              textColor: Theme.of(context).colorScheme.error,
              onTap: () => Navigator.pop(context, 'delete'),
            ),
            const Divider(),
            ListTile(
              title: Text(L10n.tr(context, 'Cancel')),
              onTap: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'delete' && unfiled) {
      final ids = _unfiledFolderIds(widget.controller, folder.mode);
      final populated = widget.controller
          .savedItems(mode: folder.mode)
          .any(
            (entry) =>
                entry.folderIds.isEmpty || entry.folderIds.every(ids.contains),
          );
      if (populated) {
        await showMessage(
          context,
          'Error',
          'Move or remove the works in Uncategorized before deleting it.',
        );
      } else {
        if (folder.id != 'unsorted') widget.controller.deleteFolder(folder);
        widget.controller.setPreference(
          'unfiledVisible.${folder.mode.name}',
          false,
        );
      }
      return;
    }
    if (action == 'rename') {
      await _editFolder(context, widget.controller, folder: folder);
    } else if (action == 'color') {
      await showFolderColorPicker(
        context,
        title: folder.name,
        color: folder.color,
        onChanged: (color) {
          if (unfiled && folder.id == 'unsorted') {
            _guard(context, () {
              _customizeUnfiled(widget.controller, folder.mode, color: color);
              widget.controller.changed();
            });
          } else {
            _guard(
              context,
              () => widget.controller.updateFolder(
                LibraryFolder(
                  id: folder.id,
                  mode: folder.mode,
                  name: folder.name,
                  color: color,
                  position: folder.position,
                ),
              ),
            );
          }
        },
      );
    } else if (action == 'order') {
      final folders = widget.controller.folders(folder.mode);
      final nativeUnfiled = _unfiledFolderIds(widget.controller, folder.mode);
      final list = <LibraryFolder>[
        if (folder.mode == AppMode.manga && nativeUnfiled.isEmpty)
          LibraryFolder(
            id: 'unsorted',
            mode: folder.mode,
            name: L10n.tr(context, 'Unfiled'),
            color: widget.controller.store.setting(
              'unfiledColor.${folder.mode.name}',
              0xFF66BB6A,
            ) as int,
            position: (widget.controller.store.setting(
              'unfiledPosition.${folder.mode.name}',
              -1,
            ) as num).toInt(),
          ),
        ...folders,
      ]..sort((a, b) => a.position.compareTo(b.position));
      final ordered = await showFolderOrder(context, list);
      if (ordered == null || !context.mounted) return;
      _guard(context, () {
        widget.controller.store.transaction(() {
          for (final (index, item) in ordered.indexed) {
            if (item.id == 'unsorted') {
              _customizeUnfiled(
                widget.controller,
                folder.mode,
                position: index,
              );
            } else {
              widget.controller.store.saveFolder(
                LibraryFolder(
                  id: item.id,
                  mode: item.mode,
                  name: item.name,
                  color: item.color,
                  position: index,
                ),
              );
            }
          }
        });
        widget.controller.changed();
      });
    } else if (action == 'delete' &&
        await confirmAction(
          context,
          'Delete Folder',
          folder.mode == AppMode.booru
              ? 'Works in this folder will return to their site folders.'
              : 'Works in this folder will be moved to Unfiled.',
        )) {
      if (context.mounted) {
        _guard(context, () => widget.controller.deleteFolder(folder));
      }
    }
  }
}

class _SavedCollection extends StatefulWidget {
  const _SavedCollection({
    required this.controller,
    required this.onOpen,
    required this.onOpenSequence,
    required this.onDetails,
    required this.folderId,
    required this.title,
    required this.mode,
  });
  final AppController controller;
  final void Function(ContentItem) onOpen;
  final void Function(ContentItem, List<ContentItem>)? onOpenSequence;
  final ValueChanged<ContentItem>? onDetails;
  final String? folderId;
  final String title;
  final AppMode mode;
  @override
  State<_SavedCollection> createState() => _SavedCollectionState();
}

class _SavedCollectionState extends State<_SavedCollection> {
  String _query = '';
  bool _selecting = false;
  final Set<String> _selected = {};
  final ScrollController _scroll = ScrollController();

  List<SavedItem>? _snapshotItems;
  Map<String, String>? _searchFields;
  List<LibraryFolder>? _snapshotFolders;
  Set<String>? _snapshotUnfiled;
  ArtworkLayout? _snapshotLayout;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_invalidateSnapshot);
  }

  @override
  void didUpdateWidget(covariant _SavedCollection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_invalidateSnapshot);
      widget.controller.addListener(_invalidateSnapshot);
    }
    if (oldWidget.controller != widget.controller ||
        oldWidget.mode != widget.mode ||
        oldWidget.folderId != widget.folderId) {
      _invalidateSnapshot();
    }
  }

  void _invalidateSnapshot() {
    _snapshotItems = null;
    _searchFields = null;
    _snapshotFolders = null;
    _snapshotUnfiled = null;
    _snapshotLayout = null;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_invalidateSnapshot);
    _scroll.dispose();
    super.dispose();
  }

  void _toggle(ContentItem item) => setState(() {
    if (!_selected.add(item.key)) _selected.remove(item.key);
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final layout = _snapshotLayout ??= ArtworkLayout.snapshot(
        widget.controller,
        widget.mode,
      );
      final folders = _snapshotFolders ??= widget.controller.folders(
        widget.mode,
      );
      final unfiledIds = _snapshotUnfiled ??= _unfiledFolderIds(
        widget.controller,
        widget.mode,
        folders,
      );
      final allItems = _snapshotItems ??= widget.controller
          .savedItems(
            mode: widget.mode,
            folderId: widget.folderId == 'unsorted' ? null : widget.folderId,
          )
          .where(
            (entry) =>
                widget.folderId != 'unsorted' ||
                entry.folderIds.isEmpty ||
                entry.folderIds.every(unfiledIds.contains),
          )
          .toList();
      final needle = _query.trim().toLowerCase();
      final items = needle.isEmpty
          ? allItems
          : allItems.where((entry) {
              final fields = _searchFields ??= {
                for (final saved in allItems)
                  saved.item.key:
                      '${saved.item.title} ${saved.item.id} ${saved.item.tags.join(' ')} ${saved.item.artists.join(' ')} ${saved.note}'
                          .toLowerCase(),
              };
              return fields[entry.item.key]!.contains(needle);
            }).toList();
      final title =
          folders
              .where((folder) => folder.id == widget.folderId)
              .firstOrNull
              ?.name ??
          widget.title;
      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: SafeArea(
          child: CustomScrollView(
            controller: _scroll,
            scrollCacheExtent: thumbnailScrollCacheExtent,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 3, 16, 18),
                sliver: SliverToBoxAdapter(
                  child: TextField(
                    onChanged: (value) => setState(() => _query = value),
                    decoration: InputDecoration(
                      isDense: true,
                      constraints: const BoxConstraints.tightFor(height: 44),
                      hintText: L10n.tr(context, 'Search saved works'),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 14,
                      ),
                      prefixIcon: const Icon(Icons.search),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 44,
                        minHeight: 44,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(28),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                    ),
                  ),
                ),
              ),
              if (items.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    icon: Icons.bookmark_border,
                    title: _query.isEmpty ? 'No Saved Works' : 'No Results',
                    message: 'Save works from Explore to add them to your collection.',
                  ),
                )
              else
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: layout.margin),
                  sliver: SliverLayoutBuilder(
                    builder: (context, constraints) => SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: layout.columns(
                          constraints.crossAxisExtent,
                        ),
                        mainAxisSpacing: layout.spacing,
                        crossAxisSpacing: layout.spacing,
                        childAspectRatio: layout.aspectRatio,
                      ),
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final saved = items[index];
                        void manage() => _editSaved(
                          context,
                          widget.controller,
                          saved,
                          widget.mode,
                          onDetails: widget.onDetails,
                        );
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            Positioned.fill(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onLongPress: () {
                                  if (_selecting) {
                                    _toggle(saved.item);
                                  } else {
                                    manage();
                                  }
                                },
                                onSecondaryTap: () {
                                  if (_selecting) {
                                    _toggle(saved.item);
                                  } else {
                                    manage();
                                  }
                                },
                                child: ContentTile(
                                  item: saved.item,
                                  layout: layout,
                                  saved: true,
                                  showSavedBadge: false,
                                  selecting: _selecting,
                                  selected: _selected.contains(saved.item.key),
                                  onTap: () => _selecting
                                      ? _toggle(saved.item)
                                      : _openItem(saved, items),
                                ),
                              ),
                            ),
                          ],
                        );
                      }, childCount: items.length),
                    ),
                  ),
                ),
              SliverToBoxAdapter(child: const NavigationScrollSpacer()),
            ],
          ),
        ),
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(tegnalHeaderExtent),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                children: [
                  const TegnalBackButton(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ChromeSurface(
                    enabled: false,
                    borderRadius: BorderRadius.circular(26),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.mode == AppMode.booru)
                            _tool(
                              Icons.dns_rounded,
                              'Servers',
                              () => showBooruSourcePicker(
                                context,
                                widget.controller,
                              ),
                            ),

                          _selecting
                              ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _tool(
                                      Icons.check_circle_outline,
                                      'Select All',
                                      () => setState(() {
                                        final allSelected = items.every(
                                          (entry) => _selected.contains(
                                            entry.item.key,
                                          ),
                                        );
                                        if (allSelected) {
                                          _selected.removeAll(
                                            items.map(
                                              (entry) => entry.item.key,
                                            ),
                                          );
                                        } else {
                                          _selected.addAll(
                                            items.map(
                                              (entry) => entry.item.key,
                                            ),
                                          );
                                        }
                                      }),
                                    ),
                                    _tool(
                                      Icons.folder_outlined,
                                      widget.mode == AppMode.manga
                                          ? 'Add to Folder'
                                          : 'Move to Another Folder',
                                      _selected.isEmpty ? null : _moveSelected,
                                    ),
                                    _tool(
                                      Icons.delete_outline,
                                      'Remove from Saved',
                                      _selected.isEmpty
                                          ? null
                                          : _removeSelected,
                                    ),
                                    _tool(
                                      Icons.close,
                                      'Cancel',
                                      () => setState(() {
                                        _selecting = false;
                                        _selected.clear();
                                      }),
                                    ),
                                  ],
                                )
                              : TextButton(
                                  onPressed: items.isEmpty
                                      ? null
                                      : () => setState(() => _selecting = true),
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.all(8),
                                  ),
                                  child: Text(
                                    L10n.tr(context, 'Select'),
                                    style: const TextStyle(fontSize: 15),
                                  ),
                                ),
                          if (!_selecting)
                            PopupMenuButton<String>(
                              tooltip: L10n.tr(context, 'Quick Jump'),
                              icon: const Icon(Icons.arrow_upward_rounded),
                              onSelected: (value) {
                                if (value == 'top') {
                                  _scroll.animateTo(
                                    0,
                                    duration: const Duration(milliseconds: 250),
                                    curve: Curves.easeOut,
                                  );
                                } else if (value == 'bottom') {
                                  _scroll.animateTo(
                                    _scroll.position.maxScrollExtent,
                                    duration: const Duration(milliseconds: 250),
                                    curve: Curves.easeOut,
                                  );
                                } else {
                                  _jumpToMonth(items, value);
                                }
                              },
                              itemBuilder: (context) => [
                                PopupMenuItem(
                                  value: 'top',
                                  child: Text(L10n.tr(context, 'Jump to Top')),
                                ),
                                PopupMenuItem(
                                  value: 'bottom',
                                  child: Text(
                                    L10n.tr(context, 'Jump to Bottom'),
                                  ),
                                ),
                                if (items.isNotEmpty) const PopupMenuDivider(),
                                for (final month in _months(items))
                                  PopupMenuItem(
                                    value: month,
                                    child: Text(month),
                                  ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  void _openItem(SavedItem saved, List<SavedItem> items) {
    final sequence = items.map((entry) => entry.item).toList();
    final openSequence = widget.onOpenSequence;
    if (openSequence != null) {
      openSequence(saved.item, sequence);
    } else {
      widget.onOpen(saved.item);
    }
  }

  List<String> _months(List<SavedItem> items) =>
      items.map((entry) => _monthKey(entry.savedAt)).toSet().toList();

  String _monthKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}';

  void _jumpToMonth(List<SavedItem> items, String month) {
    final index = items.indexWhere(
      (entry) => _monthKey(entry.savedAt) == month,
    );
    if (index < 0 || !_scroll.hasClients) return;
    final width = MediaQuery.sizeOf(context).width - 24;
    final columns = (width / 185).floor().clamp(2, 7);
    final cellWidth = (width - (columns - 1) * 10) / columns;
    final rowHeight =
        cellWidth / (widget.mode == AppMode.booru ? .78 : .61) +
        (widget.mode == AppMode.booru ? 10 : 18);
    final offset = 86 + (index ~/ columns) * rowHeight;
    _scroll.animateTo(
      offset.clamp(0, _scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Widget _tool(IconData icon, String label, VoidCallback? onPressed) =>
      SizedBox(
        width: 34,
        height: 44,
        child: IconButton(
          onPressed: onPressed,
          style: IconButton.styleFrom(
            minimumSize: const Size(34, 44),
            maximumSize: const Size(34, 44),
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
          ),
          icon: Icon(icon, size: 26, semanticLabel: L10n.tr(context, label)),
        ),
      );

  List<SavedItem> get _selectedItems => widget.controller
      .savedItems(mode: widget.mode)
      .where((entry) => _selected.contains(entry.item.key))
      .toList();

  Future<void> _moveSelected() async {
    final unfiledIds = _unfiledFolderIds(widget.controller, widget.mode);
    final folders = widget.controller
        .folders(widget.mode)
        .where((folder) => !unfiledIds.contains(folder.id))
        .toList();
    final chosen = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: DefaultTextStyle(
                  style: Theme.of(context).textTheme.titleLarge!,
                  child: Text(
                    L10n.tr(
                      context,
                      widget.mode == AppMode.manga
                          ? 'Add to Folder'
                          : 'Move to Another Folder',
                    ),
                  ),
                ),
              ),
              ...[
                if (widget.mode == AppMode.manga)
                  ListTile(
                    title: Text(L10n.tr(context, 'Unfiled')),
                    onTap: () => Navigator.pop(context, 'unsorted'),
                  ),
                for (final folder in folders)
                  ListTile(
                    title: Row(
                      children: [
                        Icon(
                          Icons.folder,
                          color: Color(folder.color),
                          size: 28,
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: Text(folder.name)),
                      ],
                    ),
                    onTap: () => Navigator.pop(context, folder.id),
                  ),
              ],
              const Divider(),
              ListTile(
                title: Text(L10n.tr(context, 'Cancel')),
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    _guard(context, () {
      for (final entry in _selectedItems) {
        widget.controller.save(
          entry.item,
          folderIds: chosen == 'unsorted'
              ? []
              : widget.mode == AppMode.manga
              ? {
                  ...entry.folderIds.where((id) => !unfiledIds.contains(id)),
                  chosen,
                }.toList()
              : [chosen],
          note: entry.note,
        );
      }
    });
    if (mounted) {
      setState(() {
        _selecting = false;
        _selected.clear();
      });
    }
  }

  Future<void> _removeSelected() async {
    if (!await confirmAction(
      context,
      'Remove from Saved',
      'Remove selected works from your saved collection?',
      action: 'Remove',
    )) {
      return;
    }
    if (!mounted) return;
    _guard(context, () {
      for (final entry in _selectedItems) {
        widget.controller.unsave(entry.item);
      }
    });
    if (mounted) {
      setState(() {
        _selecting = false;
        _selected.clear();
      });
    }
  }
}

Future<void> _editFolder(
  BuildContext context,
  AppController controller, {
  AppMode? mode,
  LibraryFolder? folder,
}) async {
  final targetMode = folder?.mode ?? mode ?? controller.mode;
  final result = await showDialog<_FolderEditResult>(
    context: context,
    builder: (_) => _FolderEditorDialog(folder: folder),
  );
  if (result != null && context.mounted) {
    _guard(context, () {
      if (folder == null) {
        controller.createFolder(result.name, mode: targetMode);
      } else {
        controller.updateFolder(
          LibraryFolder(
            id: folder.id,
            mode: targetMode,
            name: result.name,
            color: folder.color,
            position: folder.position,
          ),
        );
      }
    });
  }
}

class _FolderEditResult {
  const _FolderEditResult(this.name);
  final String name;
}

class _FolderEditorDialog extends StatefulWidget {
  const _FolderEditorDialog({this.folder});
  final LibraryFolder? folder;

  @override
  State<_FolderEditorDialog> createState() => _FolderEditorDialogState();
}

class _FolderEditorDialogState extends State<_FolderEditorDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.folder?.name ?? '',
  );
  bool _invalid = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _invalid = true);
      return;
    }
    Navigator.pop(context, _FolderEditResult(name));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      L10n.tr(
        context,
        widget.folder == null ? 'Create Folder' : 'Rename Folder',
      ),
    ),
    content: Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 80,
            onChanged: (_) {
              if (_invalid) setState(() => _invalid = false);
            },
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              hintText: L10n.tr(context, 'Folder name'),
            ),
          ),
          if (_invalid)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                L10n.tr(context, 'Enter a folder name.'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(L10n.tr(context, 'Cancel')),
      ),
      FilledButton(onPressed: _save, child: Text(L10n.tr(context, 'Save'))),
    ],
    scrollable: true,
  );
}

Future<void> _editSaved(
  BuildContext context,
  AppController controller,
  SavedItem saved,
  AppMode mode, {
  ValueChanged<ContentItem>? onDetails,
}) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: DefaultTextStyle(
                style: Theme.of(context).textTheme.titleLarge!,
                child: Text(saved.item.title),
              ),
            ),
            ...[
              ListTile(
                title: Text(L10n.tr(context, 'Edit Note and Folders')),
                onTap: () => Navigator.pop(context, 'edit'),
              ),
              if (onDetails != null)
                ListTile(
                  title: Text(L10n.tr(context, 'More Settings')),
                  onTap: () => Navigator.pop(context, 'details'),
                ),
              ListTile(
                title: Text(L10n.tr(context, 'Remove from Saved')),
                onTap: () => Navigator.pop(context, 'remove'),
                textColor: Theme.of(context).colorScheme.error,
              ),
            ],
            const Divider(),
            ListTile(
              title: Text(L10n.tr(context, 'Cancel')),
              onTap: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    ),
  );
  if (!context.mounted) return;
  if (action == 'details') {
    onDetails?.call(saved.item);
    return;
  }
  if (action == 'remove') {
    if (await confirmAction(
      context,
      'Remove from Saved',
      'Remove this work from your saved collection?',
      action: 'Remove',
    )) {
      if (context.mounted) _guard(context, () => controller.unsave(saved.item));
    }
    return;
  }
  if (action != 'edit') return;
  final result = await showDialog<_SavedItemEditResult>(
    context: context,
    builder: (_) =>
        _SavedItemEditDialog(saved: saved, folders: controller.folders(mode)),
  );
  if (result != null && context.mounted) {
    _guard(
      context,
      () => controller.save(
        saved.item,
        folderIds: result.folderIds,
        note: result.note,
      ),
    );
  }
}

class _SavedItemEditResult {
  const _SavedItemEditResult({required this.note, required this.folderIds});
  final String note;
  final List<String> folderIds;
}

class _SavedItemEditDialog extends StatefulWidget {
  const _SavedItemEditDialog({required this.saved, required this.folders});
  final SavedItem saved;
  final List<LibraryFolder> folders;

  @override
  State<_SavedItemEditDialog> createState() => _SavedItemEditDialogState();
}

class _SavedItemEditDialogState extends State<_SavedItemEditDialog> {
  late final TextEditingController _note = TextEditingController(
    text: widget.saved.note,
  );
  late final Set<String> _selected = widget.saved.folderIds.toSet();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _toggleFolder(LibraryFolder folder) {
    setState(() {
      if (widget.saved.item.mode == AppMode.booru) {
        final wasSelected = _selected.contains(folder.id);
        _selected.clear();
        if (!wasSelected) _selected.add(folder.id);
        return;
      }
      if (!_selected.add(folder.id)) _selected.remove(folder.id);
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(L10n.tr(context, 'Edit Saved Work')),
    content: Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _note,
            minLines: 2,
            maxLines: 4,
            maxLength: 10000,
            decoration: InputDecoration(hintText: L10n.tr(context, 'Note')),
          ),
          const SizedBox(height: 12),
          if (widget.folders.isEmpty)
            Text(
              L10n.tr(
                context,
                'Create a folder in Saved to organize this work.',
              ),
            ),
          for (final folder in widget.folders)
            CheckboxListTile(
              title: Text(folder.name),
              value: _selected.contains(folder.id),
              onChanged: (_) => _toggleFolder(folder),
              activeColor: Color(folder.color),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(L10n.tr(context, 'Cancel')),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(
          context,
          _SavedItemEditResult(note: _note.text, folderIds: _selected.toList()),
        ),
        child: Text(L10n.tr(context, 'Save')),
      ),
    ],
    scrollable: true,
  );
}

void _guard(BuildContext context, VoidCallback operation) {
  try {
    operation();
  } catch (error) {
    showMessage(context, 'Unable to save', AppController.errorMessage(error));
  }
}

List<int> _parseGalleryIds(String input) {
  final seen = <int>{};
  final ids = <int>[];
  void add(String digits) {
    final id = int.tryParse(digits);
    if (id == null || id < 1000 || id > 9999999999 || !seen.add(id)) return;
    ids.add(id);
  }

  final idPattern = RegExp(
    r'(?:(?:https?://)?(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}/)?(?:galleries|reader|r)/(\d{4,10})(?:\.html)?|(?:(?:https?://)?(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}/)?[^/\s]+/[^/\s]*-(\d{4,10})\.html',
    caseSensitive: false,
  );
  final nestedPattern = RegExp(r'[?&]u=([^&\s]+)', caseSensitive: false);
  void scan(String value, int depth) {
    if (depth > 3) return;
    for (final match in idPattern.allMatches(value)) {
      add(match.group(1) ?? match.group(2)!);
    }
    for (final match in nestedPattern.allMatches(value)) {
      final encoded = match.group(1)!;
      try {
        scan(Uri.decodeComponent(encoded), depth + 1);
      } on FormatException {
        continue;
      }
    }
  }

  scan(input.trim(), 0);
  if (ids.isNotEmpty) return ids;
  for (final token in input.split(RegExp(r'[\s,;]+'))) {
    if (RegExp(r'^\d{4,10}$').hasMatch(token)) add(token);
  }
  return ids;
}

class _AddWorkSheet extends StatefulWidget {
  const _AddWorkSheet({required this.controller, required this.mode});

  final AppController controller;
  final AppMode mode;

  @override
  State<_AddWorkSheet> createState() => _AddWorkSheetState();
}

class _AddWorkSheetState extends State<_AddWorkSheet> {
  final TextEditingController _input = TextEditingController();
  late List<LibraryFolder> _folders = widget.controller.folders(widget.mode);
  String? _selectedFolderId;
  List<int> _ids = const [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selectedFolderId = _folders.firstOrNull?.id;
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _createFolder() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _CreateFolderDialog(),
    );
    if (name == null || !mounted) return;
    final created = widget.controller.createFolder(name, mode: widget.mode);
    setState(() {
      _folders = widget.controller.folders(widget.mode);
      _selectedFolderId = created.id;
    });
  }

  void _save() {
    if (_ids.isEmpty || _saving) return;
    setState(() => _saving = true);
    for (final id in _ids) {
      final placeholder = ContentItem(
        sourceId: '',
        id: id,
        mode: widget.mode,
        title: '#$id',
      );
      final existing = widget.controller.saved(placeholder);
      final folders = <String>{...?existing?.folderIds};
      if (_selectedFolderId != null) folders.add(_selectedFolderId!);
      widget.controller.save(
        existing?.item ?? placeholder,
        folderIds: folders.toList(),
        note: existing?.note,
      );
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              L10n.tr(context, 'Add Work Number'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _input,
              minLines: 3,
              maxLines: 6,
              autofocus: true,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                labelText: L10n.tr(context, 'Work Number or Link'),
                hintText: 'https://example.com/galleries/123456',
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) =>
                  setState(() => _ids = _parseGalleryIds(value)),
            ),
            const SizedBox(height: 10),
            if (_ids.isNotEmpty)
              Text(
                L10n.tr(context, 'Found %@: %@')
                    .replaceFirst('%@', '${_ids.length}')
                    .replaceFirst('%@', _ids.join('  ')),
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              )
            else if (_input.text.trim().isNotEmpty)
              Text(
                L10n.tr(context, 'No work numbers found'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 18),
            Text(
              L10n.tr(context, 'Save to Folder'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.folder_outlined),
              title: Text(L10n.tr(context, 'Unfiled')),
              trailing: _selectedFolderId == null
                  ? const Icon(Icons.check, color: Colors.blue)
                  : null,
              onTap: () => setState(() => _selectedFolderId = null),
            ),
            for (final folder in _folders)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.folder, color: Color(folder.color)),
                title: Text(folder.name),
                trailing: _selectedFolderId == folder.id
                    ? const Icon(Icons.check, color: Colors.blue)
                    : null,
                onTap: () => setState(() => _selectedFolderId = folder.id),
              ),
            TextButton.icon(
              onPressed: _createFolder,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: Text(L10n.tr(context, 'Create New Folder…')),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(L10n.tr(context, 'Cancel')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _ids.isEmpty || _saving ? null : _save,
                    child: Text(L10n.tr(context, 'Save')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _CreateFolderDialog extends StatefulWidget {
  const _CreateFolderDialog();

  @override
  State<_CreateFolderDialog> createState() => _CreateFolderDialogState();
}

class _CreateFolderDialogState extends State<_CreateFolderDialog> {
  final TextEditingController _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(L10n.tr(context, 'Create Folder')),
    content: TextField(
      controller: _name,
      autofocus: true,
      decoration: InputDecoration(hintText: L10n.tr(context, 'Folder name')),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => Navigator.pop(context, _name.text.trim()),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(L10n.tr(context, 'Cancel')),
      ),
      FilledButton(
        onPressed: _name.text.trim().isEmpty
            ? null
            : () => Navigator.pop(context, _name.text.trim()),
        child: Text(L10n.tr(context, 'Create')),
      ),
    ],
  );
}

/// Imported native backups retain their built-in Unfiled folder as a real row.
/// Present that row together with works that have no folder membership.
Set<String> _unfiledFolderIds(
  AppController controller,
  AppMode mode, [
  Iterable<LibraryFolder>? folders,
]) {
  final key = mode == AppMode.booru ? 'backup.images' : 'backup.comics';
  final metadata =
      controller.store.portable(key)?['folderMetadata'] as Map? ?? {};
  return {
    for (final folder in folders ?? controller.folders(mode))
      if ((metadata[folder.id] is Map &&
              (metadata[folder.id] as Map)['nativeID'] == 'unsorted') ||
          (mode == AppMode.manga &&
              metadata[folder.id] is Map &&
              (metadata[folder.id] as Map)['name'] == '미분류'))
        folder.id,
  };
}

void _customizeUnfiled(
  AppController controller,
  AppMode mode, {
  int? color,
  int? position,
}) {
  final ids = _unfiledFolderIds(controller, mode);
  final existing = controller
      .folders(mode)
      .where((folder) => ids.contains(folder.id))
      .firstOrNull;
  final id = existing?.id ?? 'builtin-unfiled-${mode.name}';
  final key = mode == AppMode.booru ? 'backup.images' : 'backup.comics';
  final portable = controller.store.portable(key) ?? <String, dynamic>{};
  final metadata = Map<String, dynamic>.from(
    portable['folderMetadata'] as Map? ?? {},
  );
  metadata[id] = <String, dynamic>{
    ...?metadata[id] as Map?,
    if (mode == AppMode.booru) 'nativeID': 'unsorted',
    'name': mode == AppMode.manga ? '미분류' : '',
  };
  controller.store.transaction(() {
    controller.store.saveFolder(
      LibraryFolder(
        id: id,
        mode: mode,
        name: mode == AppMode.manga ? '미분류' : 'Uncategorized',
        color:
            color ??
            existing?.color ??
            controller.store.setting('unfiledColor.${mode.name}', 0xFF66BB6A)
                as int,
        position:
            position ??
            existing?.position ??
            (controller.store.setting(
              'unfiledPosition.${mode.name}',
              -1,
            ) as num).toInt(),
      ),
    );
    controller.store.setPortable(key, {
      ...portable,
      'folderMetadata': metadata,
    });
  });
}
