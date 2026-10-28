import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show ScrollDirection, ScrollCacheExtent;
import 'package:url_launcher/url_launcher.dart';

import '../core/app_controller.dart';
import '../core/content.dart';
import '../data/download_manager.dart';
import '../ui/common.dart';
import '../ui/l10n.dart';
import '../ui/session_image.dart';
import 'reader_screen.dart';

class DetailScreen extends StatefulWidget {
  const DetailScreen({
    super.key,
    required this.controller,
    required this.item,
    required this.downloads,
    required this.onSearch,
  });
  final AppController controller;
  final ContentItem item;
  final DownloadManager downloads;
  final void Function(String) onSearch;
  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late ContentItem _item = widget.item;
  bool _loading = true;
  bool _downloading = false;
  bool _showPages = false;
  bool _userScrolled = false;
  final _metadataKey = GlobalKey();
  bool _loadingPages = false;
  List<ReaderPage>? _pages;
  String _note = '';
  String? _error;
  @override
  void initState() {
    super.initState();
    _note = widget.controller.saved(_item)?.note ?? '';
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (await widget.downloads.offlinePages(_item) != null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      var item = await widget.controller.detail(_item);
      if (mounted) {
        final saved = widget.controller.saved(item);
        if (saved != null &&
            saved.item.title.isNotEmpty &&
            saved.item.title != '#${item.id}') {
          item = ContentItem.fromJson({
            ...item.toJson(),
            'title': saved.item.title,
          });
        }
        setState(() => _item = item);
        if (saved != null) widget.controller.save(item);
      }
    } catch (e) {
      if (mounted) setState(() => _error = AppController.errorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _download() async {
    setState(() => _downloading = true);
    try {
      final pages = await widget.controller.pages(_item);
      await widget.downloads.enqueue(_item, pages);
      widget.controller.save(_item);
      if (mounted) {
        await showMessage(
          context,
          'Download Added',
          'Keep the app open while downloading. Interrupted downloads can be resumed.',
        );
      }
    } catch (e) {
      if (mounted) {
        await showMessage(
          context,
          'Unable to Download',
          AppController.errorMessage(e),
        );
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _folders() async {
    final folders = widget.controller.folders(_item.mode);
    final selected =
        widget.controller.saved(_item)?.folderIds.toSet() ?? <String>{};
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: DefaultTextStyle(
                    style: Theme.of(context).textTheme.titleLarge!,
                    child: Text(L10n.tr(context, 'Folders')),
                  ),
                ),

                for (final folder in folders)
                  CheckboxListTile(
                    value: selected.contains(folder.id),
                    activeColor: Color(folder.color),
                    title: Text(folder.name),
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: (_) {
                      setSheet(() {
                        if (_item.mode == AppMode.booru) {
                          final wasSelected = selected.contains(folder.id);
                          selected.clear();
                          if (!wasSelected) {
                            selected.add(folder.id);
                          }
                          return;
                        }
                        selected.contains(folder.id)
                            ? selected.remove(folder.id)
                            : selected.add(folder.id);
                      });
                      widget.controller.save(
                        _item,
                        folderIds: selected.toList(),
                      );
                    },
                  ),
                if (folders.isEmpty)
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      L10n.tr(
                        context,
                        'Create a folder in your library first.',
                      ),
                    ),
                  ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(L10n.tr(context, 'Done')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _read() => _readAt(null);

  void _readAt(int? initialPageIndex) =>
      Navigator.of(context, rootNavigator: true).push(
        readerRoute(
          builder: (_) => ReaderScreen(
            controller: widget.controller,
            item: _item,
            downloads: widget.downloads,
            initialPageIndex: initialPageIndex,
            onSearch: widget.onSearch,
          ),
        ),
      );

  Future<void> _loadPages() async {
    if (_loadingPages || _pages != null) return;
    setState(() => _loadingPages = true);
    try {
      final pages =
          await widget.downloads.offlinePages(_item) ??
          await widget.controller.pages(_item);
      if (mounted) setState(() => _pages = pages);
    } catch (error) {
      if (mounted) {
        await showMessage(
          context,
          'Unable to Load',
          AppController.errorMessage(error),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingPages = false);
    }
  }

  Future<void> _editSavedDetails() async {
    final saved = widget.controller.saved(_item);
    if (saved == null) return;
    final draft = await showDialog<({String title, String note})>(
      context: context,
      builder: (_) =>
          _EditSavedWorkDialog(title: _item.title, note: saved.note),
    );
    if (draft != null && mounted) {
      final renamed = ContentItem(
        sourceId: _item.sourceId,
        id: _item.id,
        mode: _item.mode,
        title: draft.title.trim().isEmpty ? _item.title : draft.title.trim(),
        thumbnailUrl: _item.thumbnailUrl,
        mediaUrl: _item.mediaUrl,
        pageUrl: _item.pageUrl,
        tags: _item.tags,
        artists: _item.artists,
        width: _item.width,
        height: _item.height,
        pageCount: _item.pageCount,
        score: _item.score,
        mediaType: _item.mediaType,
        metadata: _item.metadata,
      );
      widget.controller.save(
        renamed,
        folderIds: saved.folderIds,
        note: draft.note,
      );
      setState(() {
        _item = renamed;
        _note = draft.note;
      });
    }
  }

  Future<void> _removeSaved() async {
    if (widget.controller.saved(_item) == null) return;
    if (!await confirmAction(
      context,
      'Remove from Saved',
      'Remove this work from your saved collection?',
      action: 'Remove',
    )) {
      return;
    }
    if (!mounted) return;
    widget.controller.unsave(_item);
    Navigator.of(context).pop();
  }

  Future<void> _copyId() async {
    await Clipboard.setData(ClipboardData(text: '${_item.id}'));
    if (mounted) await showMessage(context, 'Copied', '${_item.id}');
  }

  Widget _tag(String tag, {bool artist = false}) => TextButton(
    onPressed: () => widget.onSearch(
      artist && _item.mode == AppMode.manga ? 'artist:$tag' : tag,
    ),
    style: TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      minimumSize: Size.zero,
      backgroundColor:
          (artist ? const Color(0xFFFF9500) : const Color(0xFF007AFF))
              .withValues(alpha: .13),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    child: Text(
      tag,
      style: TextStyle(
        fontSize: 13,
        color: (artist ? const Color(0xFFFF9500) : const Color(0xFF007AFF)),
      ),
    ),
  );

  bool _onDetailScroll(ScrollNotification notification) {
    if (_showPages ||
        _loading ||
        _item.mode != AppMode.manga ||
        notification.depth != 0) {
      return false;
    }
    if (notification is UserScrollNotification &&
        notification.direction != ScrollDirection.idle) {
      _userScrolled = true;
    }
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _userScrolled = true;
    }
    if (notification is! ScrollUpdateNotification || !_userScrolled) {
      return false;
    }
    final metadata = _metadataKey.currentContext?.findRenderObject();
    if (metadata is! RenderBox || !metadata.hasSize) return false;
    final viewport = notification.metrics.viewportDimension;
    final travel = notification.metrics.pixels;
    final minimumTravel = (viewport * .35).clamp(160.0, 320.0);
    // Match native GalleryPreviewLoading: travel alone is insufficient while
    // the person is still reading the metadata. Opening a short work never
    // starts page requests, even when the preview footer is already visible.
    if (viewport > 0 &&
        travel >= minimumTravel &&
        20 + metadata.size.height - travel <= viewport - 44) {
      setState(() => _showPages = true);
      _loadPages();
    }
    return false;
  }

  Widget _information(BuildContext context) {
    final saved = widget.controller.isSaved(_item);
    final metadata = [
      for (final namespace in ['language:', 'type:'])
        for (final tag in _item.tags)
          if (tag.startsWith(namespace)) tag.substring(namespace.length),
      if (_item.pageCount > 0) '${_item.pageCount} P',
    ];
    return Column(
      key: _metadataKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onTap: _read,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              height: 300,
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              padding: const EdgeInsets.all(8),
              child: _item.thumbnailUrl == null
                  ? Icon(
                      _item.mode == AppMode.manga
                          ? Icons.menu_book
                          : Icons.image_outlined,
                      size: 60,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    )
                  : SessionImage(
                      url: _item.thumbnailUrl!,
                      fit: BoxFit.contain,
                      referer: _item.pageUrl,
                      errorBuilder: (_, _, _) =>
                          const Icon(Icons.image_outlined, size: 60),
                    ),
            ),
          ),
        ),
        const SizedBox(height: 22),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SelectableText(
                _item.title,
                style: const TextStyle(
                  fontSize: 22,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.5,
                ),
              ),
            ),
            if (saved)
              IconButton(
                onPressed: _editSavedDetails,
                tooltip: L10n.tr(context, 'Edit Saved Work'),
                icon: const Icon(Icons.edit_outlined),
              ),
          ],
        ),
        const SizedBox(height: 22),
        Text(
          metadata.isEmpty ? '#${_item.id}' : metadata.join(' · '),
          style: TextStyle(
            fontSize: 14,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 22),
        FilledButton.icon(
          onPressed: _read,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          icon: Icon(
            _item.mode == AppMode.manga ? Icons.menu_book : Icons.play_arrow,
            size: 26,
          ),
          label: Text(
            L10n.tr(context, _item.mode == AppMode.manga ? 'Read' : 'Open'),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => saved
              ? widget.controller.unsave(_item)
              : widget.controller.save(_item),
          icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border),
          label: Text(
            L10n.tr(context, saved ? 'Remove Bookmark' : 'Save to Library'),
          ),
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(18),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!, style: const TextStyle(color: Color(0xFFFF3B30))),
          TextButton(onPressed: _load, child: Text(L10n.tr(context, 'Retry'))),
        ],
        if (_item.artists.isNotEmpty) ...[
          const SizedBox(height: 22),
          Text(
            L10n.tr(context, 'Artists'),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final artist in _item.artists) _tag(artist, artist: true),
            ],
          ),
        ],
        if (_item.tags.isNotEmpty) ...[
          const SizedBox(height: 22),
          Text(
            L10n.tr(context, 'Tags'),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [for (final tag in _item.tags) _tag(tag)],
          ),
        ],
        if (_note.isNotEmpty) ...[
          const SizedBox(height: 22),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(_note),
            ),
          ),
        ],
        const SizedBox(height: 22),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            TextButton.icon(
              onPressed: _downloading ? null : _download,
              icon: _downloading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_outlined),
              label: Text(L10n.tr(context, 'Download')),
            ),
            TextButton.icon(
              onPressed: _folders,
              icon: const Icon(Icons.folder_outlined),
              label: Text(L10n.tr(context, 'Folders')),
            ),
            if (_item.pageUrl != null)
              TextButton.icon(
                onPressed: () async {
                  if (!await launchUrl(
                        _item.pageUrl!,
                        mode: LaunchMode.externalApplication,
                      ) &&
                      context.mounted) {
                    await showMessage(
                      context,
                      'Unable to Open',
                      'No browser is available.',
                    );
                  }
                },
                icon: const Icon(Icons.language),
                label: Text(L10n.tr(context, 'Open in Browser')),
              ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final inset = ((constraints.maxWidth - 760) / 2).clamp(
              20.0,
              double.infinity,
            );
            return NotificationListener<ScrollNotification>(
              onNotification: _onDetailScroll,
              child: CustomScrollView(
                key: const ValueKey('content.detail.scroll'),
                // Keep speculative thumbnail requests close to the viewport.
                scrollCacheExtent: const ScrollCacheExtent.pixels(200),
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(inset, 20, inset, 0),
                    sliver: SliverToBoxAdapter(child: _information(context)),
                  ),
                  if (_item.mode == AppMode.manga) ...[
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(inset, 22, inset, 16),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Divider(),
                            const SizedBox(height: 16),
                            Text(
                              L10n.tr(context, 'Preview'),
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (!_showPages || _loadingPages || _pages == null)
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: constraints.maxHeight,
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: !_showPages
                                  ? Text(
                                      L10n.tr(
                                        context,
                                        'Scroll down to load page previews.',
                                      ),
                                    )
                                  : _loadingPages
                                  ? const CircularProgressIndicator()
                                  : TextButton(
                                      onPressed: _loadPages,
                                      child: Text(L10n.tr(context, 'Retry')),
                                    ),
                            ),
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(inset, 0, inset, 32),
                        sliver: SliverGrid(
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 150,
                                mainAxisSpacing: 8,
                                crossAxisSpacing: 8,
                                childAspectRatio: .72,
                              ),
                          delegate: SliverChildBuilderDelegate(
                            (context, index) => Semantics(
                              button: true,
                              label: '${L10n.tr(context, 'Page')} ${index + 1}',
                              child: GestureDetector(
                                key: ValueKey(
                                  'content.detail.preview.${index + 1}',
                                ),
                                onTap: () => _readAt(index),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: ReaderPageThumbnail(
                                    page: _pages![index],
                                    referer: _item.pageUrl,
                                  ),
                                ),
                              ),
                            ),
                            childCount: _pages!.length,
                          ),
                        ),
                      ),
                  ] else
                    const SliverToBoxAdapter(child: SizedBox(height: 32)),
                ],
              ),
            );
          },
        ),
      ),
      appBar: AppBar(
        leading: const TegnalBackButton(),
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text(
          L10n.tr(
            context,
            _item.mode == AppMode.manga ? 'Work Details' : 'Details',
          ),
        ),
        actions: [
          IconButton(
            onPressed: _copyId,
            tooltip: L10n.tr(
              context,
              'Copy Work Number (%@)',
            ).replaceAll('%@', '${_item.id}'),
            icon: const Icon(Icons.content_copy_outlined),
          ),
          if (widget.controller.saved(_item) != null)
            IconButton(
              onPressed: _removeSaved,
              tooltip: L10n.tr(context, 'Remove from Saved'),
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
    ),
  );
}

class _EditSavedWorkDialog extends StatefulWidget {
  const _EditSavedWorkDialog({required this.title, required this.note});

  final String title;
  final String note;

  @override
  State<_EditSavedWorkDialog> createState() => _EditSavedWorkDialogState();
}

class _EditSavedWorkDialogState extends State<_EditSavedWorkDialog> {
  late final TextEditingController _title = TextEditingController(
    text: widget.title,
  );
  late final TextEditingController _note = TextEditingController(
    text: widget.note,
  );

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(L10n.tr(context, 'Edit Saved Work')),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _title,
          decoration: InputDecoration(labelText: L10n.tr(context, 'Title')),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _note,
          minLines: 2,
          maxLines: 5,
          decoration: InputDecoration(labelText: L10n.tr(context, 'Note')),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(L10n.tr(context, 'Cancel')),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.pop(context, (title: _title.text, note: _note.text)),
        child: Text(L10n.tr(context, 'Save')),
      ),
    ],
  );
}
