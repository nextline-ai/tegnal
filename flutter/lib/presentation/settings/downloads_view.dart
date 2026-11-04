import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/content/content_environment.dart';
import '../../core/content/gallery_content.dart';
import '../../core/downloads/download_store.dart';
import '../../core/storage/app_database.dart';
import '../../core/support/l10n.dart';
import '../../core/support/preferences.dart';
import '../content/page_image_store.dart';
import '../content/reader_view.dart';
import '../design/context_menu.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';
import '../library/folders_view.dart' show ContentUnavailable, anchorOf;
import '../library/local_thumbnail.dart';
import '../navigation/app_header.dart';
import '../navigation/root_tab_view.dart';
import '../works/artwork_grid.dart';
import '../works/search_controls.dart';
import '../works/works_models.dart';
import 'settings_page.dart';
import '../design/alert_dialog.dart';

/// What opening a download offline needs.
class DownloadsContext {
  const DownloadsContext({required this.store, required this.content, required this.database, required this.preferences});
  final DownloadStore store;
  final ContentEnvironment content;
  final AppDatabase database;
  final Preferences preferences;
}

/// `DownloadsView`: a mode's downloads in a searchable grid with their progress and actions.
class DownloadsView extends StatefulWidget {
  const DownloadsView({super.key, required this.downloads, this.booru = false, this.inSheet = false});
  final DownloadsContext downloads;

  /// Image mode's downloads, in its own grid density, instead of comics'.
  final bool booru;

  /// From the reader the list is a sheet with Done instead of a pushed screen.
  final bool inSheet;

  @override
  State<DownloadsView> createState() => _DownloadsViewState();
}

class _DownloadsViewState extends State<DownloadsView> {
  final _query = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _visibility = ScrollSearchVisibility();
  double _lastOffset = 0;
  bool _searchVisible = true;

  DownloadStore get _store => widget.downloads.store;

  @override
  void initState() {
    super.initState();
    _store.addListener(_changed);
    _query.addListener(_changed);
    _scroll.addListener(() {
      final visible = _visibility.update(oldY: _lastOffset, newY: _scroll.offset, focused: _focus.hasFocus);
      _lastOffset = _scroll.offset;
      if (visible != null && visible != _searchVisible) setState(() => _searchVisible = visible);
    });
  }

  @override
  void dispose() {
    _store.removeListener(_changed);
    _query.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  List<ContextMenuAction> _actions(WorkDownload item) => [
    if (item.status.canPause) ContextMenuAction(title: L10n.text('Pause'), icon: CupertinoIcons.pause, onSelected: () => _store.pause(item.id)),
    if (item.status.canResume)
      ContextMenuAction(title: L10n.text(item.status.resumeTitle), icon: CupertinoIcons.arrow_clockwise, onSelected: () => _store.resume(item.id)),
    ContextMenuAction(title: L10n.text('Delete Download'), icon: CupertinoIcons.trash, destructive: true, onSelected: () => _confirmDelete(item)),
  ];

  Future<void> _confirmDelete(WorkDownload item) async {
    final delete = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(L10n.text('Delete Download?')),
        message: Text(L10n.text('This removes the downloaded files from this device.')),
        actions: [CupertinoActionSheetAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Delete')))],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (delete == true) _store.remove(item.id);
  }

  void _showInfo() => showCupertinoDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (context) => TegnalAlertDialog(
      title: Text(L10n.text('Downloads')),
      content: Text(L10n.text('Downloads are stored on this device. Keep the app open while downloading. Interrupted downloads can be resumed here.')),
      actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('Done')))],
    ),
  );

  void _open(WorkDownload item) => Navigator.of(context).push(
    CupertinoPageRoute<void>(
      builder: (_) => DownloadFilesPage(item: item, downloads: widget.downloads),
    ),
  );

  Widget _card(WorkDownload item, ArtworkCellStyle style) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final cover = _store.urls(item).firstOrNull;
    final gallery = item.gallery;
    final placeholder = ColoredBox(
      color: TegnalColors.coverPlaceholder.resolveFrom(context),
      child: Center(child: Icon(CupertinoIcons.photo, size: 22, color: secondary)),
    );
    final caption = TegnalType.style(style.fontSize(12, minimum: 9), color: secondary);
    final progress = item.status == WorkDownloadStatus.downloading && item.total == 1
        ? _store.transferProgress[item.id]
        : item.files.length / (item.total < 1 ? 1 : item.total);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: item.status == WorkDownloadStatus.completed ? () => _open(item) : null,
          child: GalleryCardLayout(
            style: style,
            title: item.title,
            artists: item.artists.join(', '),
            language: gallery?.language ?? '',
            category: gallery == null || gallery.type.isEmpty ? '' : GalleryCategory.title(gallery.type),
            categoryColor: galleryCategoryColor(gallery?.type ?? ''),
            cover: LocalThumbnail(path: cover?.path, placeholder: placeholder),
          ),
        ),
        if (item.tags.isNotEmpty) ...[
          SizedBox(height: style.inset(4)),
          Text(item.tags.take(4).join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: caption),
        ],
        if (item.status != WorkDownloadStatus.completed) ...[SizedBox(height: style.inset(4)), _ProgressBar(value: progress)],
        Row(
          children: [
            Expanded(
              child: Text(
                item.status == WorkDownloadStatus.completed
                    ? L10n.text(item.status.title)
                    : '${L10n.text(item.status.title)} ${item.files.length}/${item.total}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: caption,
              ),
            ),
            Builder(
              builder: (buttonContext) => Semantics(
                button: true,
                label: L10n.text('Download Actions'),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => showActionMenu(buttonContext, anchor: anchorOf(buttonContext), actions: _actions(item)),
                  child: SizedBox.square(
                    dimension: 36 * style.scale < 24 ? 24 : 36 * style.scale,
                    child: Icon(CupertinoIcons.ellipsis, size: 17, color: secondary),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (item.error != null)
          Text(
            item.error!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: caption.copyWith(color: CupertinoColors.systemRed.resolveFrom(context)),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final barBottom = media.padding.top + rootBarHeight;
    final items = _store.items.where((item) => item.mode == (widget.booru ? WorkDownloadMode.booru : WorkDownloadMode.manga)).toList();
    final results = items.where((item) => item.matches(_query.text)).toList();
    final bytes = items.fold<int>(0, (sum, item) => sum + item.bytes);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final preferences = widget.downloads.preferences;
    final grid = widget.booru
        ? ArtworkGridPreferences(
            columns: preferences.integer('booru.grid_columns').clamp(0, 5),
            removesPadding: preferences.boolean('booru.grid.noPadding') ?? false,
            showsTitles: false,
            showsArtists: false,
          )
        : ArtworkGridPreferences(
            columns: widget.downloads.content.mangaColumns,
            removesPadding: widget.downloads.content.mangaRemovesGridPadding,
            showsTitles: widget.downloads.content.showsMangaTitles,
            showsArtists: widget.downloads.content.showsMangaArtists,
            showsCategories: widget.downloads.content.showsMangaCategories,
          );
    return ColoredBox(
      color: TegnalColors.background.resolveFrom(context),
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomScrollView(
              controller: _scroll,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(18, barBottom + 56 + 12, 18, 0),
                  sliver: SliverToBoxAdapter(
                    child: Row(
                      children: [
                        Text(L10n.text('%@ items', ['${results.length}']), style: TegnalType.style(12, color: secondary)),
                        const Spacer(),
                        Text(
                          FileByteCount.format(bytes, language: L10n.language),
                          style: TegnalType.style(12, color: secondary),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_store.storageError != null)
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverToBoxAdapter(
                      child: Text(_store.storageError!, style: TegnalType.style(15, color: CupertinoColors.systemRed.resolveFrom(context))),
                    ),
                  ),
                if (results.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 40),
                      child: ContentUnavailable(
                        icon: items.isEmpty ? CupertinoIcons.arrow_down_circle : CupertinoIcons.search,
                        title: L10n.text(items.isEmpty ? 'No Downloads' : 'No Works'),
                        description: items.isEmpty ? L10n.text('Download a work from the viewer quick menu.') : L10n.text("No results for '%@'", [_query.text]),
                      ),
                    ),
                  )
                else
                  ArtworkGridSliver(itemCount: results.length, preferences: grid, itemBuilder: (context, index, style) => _card(results[index], style)),
                SliverToBoxAdapter(child: SizedBox(height: widget.inSheet ? 32 : tabBarClearance(context))),
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
                  child: ScrollSearchBar(controller: _query, focusNode: _focus, prompt: L10n.text('Search Downloads')),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: InlineTitleHeader(
              title: L10n.text('Downloads'),
              back: !widget.inSheet,
              trailing: widget.inSheet
                  ? GlassTextButton(label: L10n.text('Done'), prominent: true, elevated: false, onPressed: () => Navigator.of(context).pop())
                  : ToolbarGroup(
                      children: [ToolbarIconButton(label: L10n.text('Storage Used'), icon: CupertinoIcons.info_circle, size: 22, onPressed: _showInfo)],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.value});
  final double? value;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 4,
    child: value == null
        ? const CupertinoActivityIndicator(radius: 6)
        : ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: Stack(
              children: [
                Container(color: TegnalColors.tertiaryLabel.resolveFrom(context)),
                FractionallySizedBox(
                  widthFactor: value!.clamp(0, 1),
                  child: Container(color: TegnalColors.tint.resolveFrom(context)),
                ),
              ],
            ),
          ),
  );
}

/// `DownloadFilesView`: a completed download's information, offline reading and its files.
class DownloadFilesPage extends StatefulWidget {
  const DownloadFilesPage({super.key, required this.item, required this.downloads});
  final WorkDownload item;
  final DownloadsContext downloads;

  @override
  State<DownloadFilesPage> createState() => _DownloadFilesPageState();
}

class _DownloadFilesPageState extends State<DownloadFilesPage> {
  bool _showsTags = false;

  @override
  void initState() {
    super.initState();
    // A comic opens straight in the reader, as the native screen does on appear.
    if (widget.item.gallery != null) WidgetsBinding.instance.addPostFrameCallback((_) => _read());
  }

  void _read() {
    final gallery = widget.item.gallery;
    if (gallery == null || !mounted) return;
    final downloads = widget.downloads;
    final source = DownloadedContentSource(item: widget.item, folder: downloads.store.folder(widget.item));
    openReader(
      context,
      galleryID: gallery.id,
      initialPage: 1,
      source: source,
      images: PageImageStore(source: source, diskCapacity: 0),
      content: downloads.content,
      database: downloads.database,
      preferences: downloads.preferences,
      bookmark: (_) async {},
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    final row = FormColors.listRow.resolveFrom(context);
    return SettingsPage(
      title: item.title,
      children: [
        FormSection(
          rowColor: row,
          children: [
            FormRow(
              child: Text(
                item.title,
                style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
              ),
            ),
            if (item.artists.isNotEmpty)
              FormRow(
                child: Text(item.artists.join(', '), style: TegnalType.style(17, color: secondary)),
              ),
            if (item.tags.isNotEmpty)
              FormRow(
                onTap: () => setState(() => _showsTags = !_showsTags),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(L10n.text('Tags'))),
                        Icon(_showsTags ? CupertinoIcons.chevron_down : CupertinoIcons.chevron_right, size: 15, color: tint),
                      ],
                    ),
                    if (_showsTags) ...[
                      const SizedBox(height: 8),
                      Text(item.tags.join(' · '), style: TegnalType.style(15, color: TegnalColors.label.resolveFrom(context))),
                    ],
                  ],
                ),
              ),
          ],
        ),
        settingsSectionGap,
        FormSection(
          rowColor: row,
          children: [
            if (item.gallery != null)
              FormRow(
                onTap: _read,
                child: Row(
                  children: [
                    Icon(CupertinoIcons.book_fill, size: 20, color: tint),
                    const SizedBox(width: 12),
                    Text(L10n.text('Read Offline'), style: TegnalType.style(17, color: tint)),
                  ],
                ),
              ),
            for (final File file in widget.downloads.store.urls(item))
              FormRow(
                child: Text(file.uri.pathSegments.last, style: TegnalType.style(17, color: tint)),
              ),
          ],
        ),
      ],
    );
  }
}
