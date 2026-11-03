import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../../core/content/content_environment.dart';
import '../../core/content/content_errors.dart';
import '../../core/content/gallery_content.dart';
import '../../core/content/manga_urls.dart';
import '../../core/storage/app_database.dart';
import '../../core/support/l10n.dart';
import '../../domain/models.dart';
import '../design/app_sheet.dart';
import '../design/glass.dart';
import '../design/grouped_form.dart';
import '../design/symbols.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import '../works/artwork_grid.dart';
import 'gallery_preview_models.dart';
import 'page_image_store.dart';

/// What the detail screen can do besides showing the work.
class GalleryDetailActions {
  const GalleryDetailActions({required this.read, required this.save, this.search, this.openVersion, this.openRelated});

  /// Opens the reader at a page (zero-based), resuming saved progress when `resume` is true.
  final void Function(int page, {required bool resume}) read;
  final Future<void> Function(NativeGallery gallery) save;
  final ValueChanged<String>? search;
  final ValueChanged<int>? openVersion;
  final ValueChanged<int>? openRelated;
}

/// Presents a work's details as a large sheet with a grabber, its title and a close button.
Future<void> showGalleryDetail(
  BuildContext context, {
  required int galleryID,
  required ContentProviding source,
  required PageImageStore images,
  required ContentEnvironment content,
  required AppDatabase database,
  required GalleryDetailActions Function(BuildContext sheetContext) actions,
}) => showAppSheet<void>(
  context,
  grabber: true,
  builder: (sheetContext, controller) => RemoteGalleryView(
    galleryID: galleryID,
    source: source,
    images: images,
    content: content,
    database: database,
    actions: actions(sheetContext),
    scrollController: controller,
  ),
);

/// Loads one work and shows `GalleryWorkInformation` under the sheet's navigation bar.
class RemoteGalleryView extends StatefulWidget {
  const RemoteGalleryView({
    super.key,
    required this.galleryID,
    required this.source,
    required this.images,
    required this.content,
    required this.database,
    required this.actions,
    this.scrollController,
  });

  final int galleryID;
  final ContentProviding source;
  final PageImageStore images;
  final ContentEnvironment content;
  final AppDatabase database;
  final GalleryDetailActions actions;
  final ScrollController? scrollController;

  @override
  State<RemoteGalleryView> createState() => _RemoteGalleryViewState();
}

class _RemoteGalleryViewState extends State<RemoteGalleryView> {
  NativeGallery? _gallery;
  ui.Image? _cover;
  bool _coverFinished = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final gallery = await widget.source.gallery(widget.galleryID);
      if (!mounted) return;
      setState(() => _gallery = gallery);
      final page = gallery.pages.firstOrNull;
      if (page != null) {
        try {
          final cover = await widget.images.load(page, galleryID: widget.galleryID, thumbnail: true);
          if (mounted) setState(() => _cover = cover);
        } on Object {
          // A missing cover keeps the details usable.
        }
      }
      if (mounted) setState(() => _coverFinished = true);
    } on Object catch (error) {
      if (mounted) setState(() => _error = ContentError.message(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final gallery = _gallery;
    final Widget body;
    if (gallery != null) {
      body = GalleryWorkInformation(
        gallery: gallery,
        images: widget.images,
        content: widget.content,
        database: widget.database,
        cover: _cover,
        coverFinished: _coverFinished,
        actions: widget.actions,
        scrollController: widget.scrollController,
        topInset: 76,
      );
    } else if (_error != null) {
      body = Center(
        child: SingleChildScrollView(
          child: ContentFailure(message: _error!, retry: _load),
        ),
      );
    } else {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CupertinoActivityIndicator(),
            const SizedBox(height: 8),
            Text(L10n.text('Loading work details'), style: TegnalType.style(15, color: TegnalColors.secondaryLabel.resolveFrom(context))),
          ],
        ),
      );
    }
    return ScrollEdgeSheet(
      bar: SheetNavigationBar(
        title: L10n.text('Work Details'),
        trailing: GlassIconButton(icon: CupertinoIcons.xmark, label: L10n.text('Close'), onPressed: () => Navigator.of(context).pop()),
      ),
      child: body,
    );
  }
}

/// A toolbar icon button in its own 44 pt glass circle.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({super.key, required this.icon, required this.label, required this.onPressed, this.size = 44});
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: Glass.circle(
        elevated: true,
        child: SizedBox.square(
          dimension: size,
          child: Icon(icon, size: 24, color: TegnalColors.label.resolveFrom(context)),
        ),
      ),
    ),
  );
}

/// `ContentFailureView`: the reason a load failed and a retry.
class ContentFailure extends StatelessWidget {
  const ContentFailure({super.key, required this.message, required this.retry});
  final String message;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.wifiExclamationmark, size: 44, color: secondary),
          const SizedBox(height: 12),
          Text(
            L10n.text('Unable to Load'),
            style: TegnalType.style(22, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TegnalType.style(15, color: secondary),
          ),
          const SizedBox(height: 16),
          CupertinoButton.filled(
            borderRadius: const BorderRadius.all(Radius.circular(999)),
            onPressed: retry,
            child: Text(
              L10n.text('Try Again'),
              style: TegnalType.style(15, weight: FontWeight.w600, color: const Color(0xFFFFFFFF)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Explore, saved works and the viewer use the same work information sections.
class GalleryWorkInformation extends StatefulWidget {
  const GalleryWorkInformation({
    super.key,
    required this.gallery,
    required this.images,
    required this.content,
    required this.database,
    required this.actions,
    this.cover,
    this.coverFinished = true,
    this.showsCover = true,
    this.showsRead = true,
    this.scrollController,
    this.topInset = 0,
  });

  final NativeGallery gallery;
  final PageImageStore images;
  final ContentEnvironment content;
  final AppDatabase database;
  final GalleryDetailActions actions;
  final ui.Image? cover;
  final bool coverFinished;
  final bool showsCover;
  final bool showsRead;
  final ScrollController? scrollController;
  final double topInset;

  @override
  State<GalleryWorkInformation> createState() => _GalleryWorkInformationState();
}

class _GalleryWorkInformationState extends State<GalleryWorkInformation> {
  final _metadataKey = GlobalKey();
  late final ScrollController _scroll = widget.scrollController ?? ScrollController();
  bool _previewsEnabled = false;
  Set<int> _savedIDs = {};
  List<ArtistMemo> _savedTags = [];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_checkPreviews);
    _reload();
  }

  @override
  void dispose() {
    _scroll.removeListener(_checkPreviews);
    if (widget.scrollController == null) _scroll.dispose();
    super.dispose();
  }

  void _reload() {
    _savedIDs = widget.database.savedGalleryIDs().toSet();
    _savedTags = widget.database.listArtists();
  }

  /// Page previews load only after a deliberate scroll past the metadata.
  void _checkPreviews() {
    if (_previewsEnabled) return;
    final box = _metadataKey.currentContext?.findRenderObject() as RenderBox?;
    final viewport = context.findRenderObject() as RenderBox?;
    if (box == null || viewport == null) return;
    final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy - widget.topInset;
    final frame = Rect.fromLTWH(0, top, box.size.width, box.size.height);
    if (GalleryPreviewLoading.shouldLoad(metadata: frame, viewportHeight: viewport.size.height - widget.topInset)) {
      setState(() => _previewsEnabled = true);
    }
  }

  void _toggleSaved(String name, SavedCollectionKind kind) {
    try {
      final saved = widget.database.toggleCollectionTag(name, kind);
      HapticFeedback.mediumImpact();
      setState(() {
        _savedTags = widget.database.listArtists();
        if (saved) _savedIDs = _savedIDs;
      });
    } on Object catch (error) {
      _alert(L10n.text('Unable to Save'), '$error');
    }
  }

  void _alert(String title, String message) => showCupertinoDialog<void>(
    context: context,
    builder: (context) => CupertinoAlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('Done')))],
    ),
  );

  Set<String> get _savedQueries => {
    for (final value in _savedTags)
      if (SavedCollectionKind.values.where((kind) => kind.mangaKind == value.kind).firstOrNull case final kind?) kind.query(value.name, manga: true),
  };

  @override
  Widget build(BuildContext context) {
    final gallery = widget.gallery;
    final candidate = widget.actions.openVersion == null ? null : gallery.suggestedVersion(L10n.contentLanguage);
    final suggestion = candidate != null && !widget.content.hiddenMangaGalleryIDs.contains(candidate.id) ? candidate : null;
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        controller: _scroll,
        padding: EdgeInsets.fromLTRB(20, widget.topInset + 20, 20, 20 + MediaQuery.paddingOf(context).bottom),
        children: [
          KeyedSubtree(
            key: _metadataKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.showsCover) ...[WorkDetailCover(image: widget.cover, loading: !widget.coverFinished), const SizedBox(height: 22)],
                GalleryDetailHeading(
                  title: gallery.title,
                  metadata: L10n.text('%@ · %@ · %@ pages', [gallery.language, gallery.type, '${gallery.pages.length}']),
                ),
                const SizedBox(height: 22),
                if (widget.showsRead) ...[
                  _ActionButton(prominent: true, icon: Symbols.book, label: L10n.text('Read'), onPressed: () => widget.actions.read(0, resume: true)),
                  const SizedBox(height: 11),
                ],
                _ActionButton(
                  prominent: false,
                  icon: CupertinoIcons.bookmark,
                  label: L10n.text('Save to Library'),
                  onPressed: () => widget.actions.save(gallery),
                ),
                if (suggestion != null) ...[
                  const SizedBox(height: 11),
                  _VersionSuggestion(version: suggestion, open: () => widget.actions.openVersion!(suggestion.id)),
                ],
                const SizedBox(height: 22),
                _GalleryDetailMetadata(
                  gallery: gallery,
                  content: widget.content,
                  savedIDs: _savedIDs,
                  savedQueries: _savedQueries,
                  favoriteArtists: {
                    for (final value in _savedTags)
                      if (value.kind == 0) MangaArtistFavorite.key(value.name),
                  },
                  search: widget.actions.search,
                  openVersion: widget.actions.openVersion,
                  toggleSaved: _toggleSaved,
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: _previewsEnabled ? 0 : constraints.maxHeight),
            child: Align(
              alignment: Alignment.topLeft,
              child: GalleryDetailPreviews(
                gallery: gallery,
                images: widget.images,
                content: widget.content,
                enabled: _previewsEnabled,
                select: (page) => widget.actions.read(page, resume: false),
              ),
            ),
          ),
          const SizedBox(height: 22),
          _MangaContentControls(gallery: gallery, content: widget.content),
        ],
      ),
    );
  }
}

/// `WorkDetailCover`: the cover fitted inside a 300 pt rounded box.
class WorkDetailCover extends StatelessWidget {
  const WorkDetailCover({super.key, required this.image, this.loading = false});
  final ui.Image? image;
  final bool loading;

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: L10n.text('Thumbnail'),
    value: L10n.text(image == null ? (loading ? 'Loading' : 'Thumbnail unavailable') : 'Thumbnail loaded'),
    child: ClipRSuperellipse(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        height: 300,
        color: FormColors.row.resolveFrom(context),
        padding: image == null ? EdgeInsets.zero : const EdgeInsets.all(8),
        alignment: Alignment.center,
        child: image != null
            ? RawImage(image: image, fit: BoxFit.contain, filterQuality: ui.FilterQuality.medium)
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Symbols.book, size: 34, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
                  if (loading) ...[const SizedBox(height: 12), const CupertinoActivityIndicator()],
                ],
              ),
      ),
    ),
  );
}

/// `GalleryDetailHeading`: a two-line bold title that opens in full when tapped, and its summary.
class GalleryDetailHeading extends StatelessWidget {
  const GalleryDetailHeading({super.key, required this.title, required this.metadata});
  final String title;
  final String metadata;

  @override
  Widget build(BuildContext context) {
    final titleStyle = TegnalType.style(22, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)).copyWith(height: 1.27);
    final metadataStyle = TegnalType.style(15, color: TegnalColors.secondaryLabel.resolveFrom(context));
    // Reserve two title lines so the actions sit at the same height for every work,
    // while the metadata stays right below the title itself.
    return Stack(
      children: [
        Opacity(
          opacity: 0,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('\n', maxLines: 2, style: titleStyle),
              Text(metadata, style: metadataStyle),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => showAppSheet<void>(
                context,
                builder: (context, controller) => _FullTitle(title: title, controller: controller),
              ),
              child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: titleStyle),
            ),
            Text(metadata, style: metadataStyle),
          ],
        ),
      ],
    );
  }
}

class _FullTitle extends StatelessWidget {
  const _FullTitle({required this.title, required this.controller});
  final String title;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: FormColors.background.resolveFrom(context),
    child: Column(
      children: [
        SheetNavigationBar(
          title: L10n.text('Title'),
          trailing: GlassTextButton(label: L10n.text('Done'), prominent: true, onPressed: () => Navigator.of(context).pop()),
        ),
        Expanded(
          child: SingleChildScrollView(
            controller: controller,
            padding: const EdgeInsets.all(20),
            child: Text(
              title,
              style: TegnalType.style(22, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
            ),
          ),
        ),
      ],
    ),
  );
}

/// The Read and Save to Library buttons: 19.5 pt bold labels in tall capsules.
class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.prominent, required this.icon, required this.label, required this.onPressed});
  final bool prominent;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    final foreground = prominent ? const Color(0xFFFFFFFF) : tint;
    final background = prominent ? tint : _borderedFill.resolveFrom(context);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        child: Container(
          height: 66,
          decoration: ShapeDecoration(color: background, shape: const StadiumBorder()),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: foreground),
              const SizedBox(width: 8),
              Text(
                label,
                style: TegnalType.style(19.5, weight: FontWeight.w700, color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// `.bordered`: a gray fill that reads the same in both appearances.
  static const _borderedFill = CupertinoDynamicColor.withBrightness(color: Color(0x1F787880), darkColor: Color(0xFF39393D));
}

class _VersionSuggestion extends StatelessWidget {
  const _VersionSuggestion({required this.version, required this.open});
  final GalleryVersion version;
  final VoidCallback open;

  @override
  Widget build(BuildContext context) {
    final color = artworkTagColor(ArtworkTagCategory.language, context);
    return GestureDetector(
      onTap: open,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: ShapeDecoration(
          color: color.withValues(alpha: 0.12),
          shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: Row(
          children: [
            Icon(Symbols.globe, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                L10n.text('View in %@', [version.displayName]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TegnalType.style(15, weight: FontWeight.w600, color: color),
              ),
            ),
            Icon(CupertinoIcons.chevron_right, size: 13, color: color.withValues(alpha: 0.6)),
          ],
        ),
      ),
    );
  }
}

/// `ArtworkTagCategory.color`.
Color artworkTagColor(ArtworkTagCategory category, BuildContext context) => switch (category) {
  ArtworkTagCategory.artist => SystemColors.orange,
  ArtworkTagCategory.series => SystemColors.purple,
  ArtworkTagCategory.character => SystemColors.green,
  ArtworkTagCategory.female => SystemColors.pink,
  ArtworkTagCategory.male => SystemColors.blue,
  ArtworkTagCategory.group => SystemColors.teal,
  ArtworkTagCategory.language => SystemColors.indigo,
  ArtworkTagCategory.type => SystemColors.brown,
  ArtworkTagCategory.metadata => SystemColors.mint,
  ArtworkTagCategory.general => TegnalColors.label,
}.resolveFrom(context);

/// `ArtworkTagPill`: body text in a capsule tinted 12% with the tag's color.
class ArtworkTagPill extends StatelessWidget {
  const ArtworkTagPill({super.key, required this.color, required this.child, this.onTap, this.onLongPress, this.starred = false});
  final Color color;
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool starred;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    onLongPress: onLongPress,
    child: AnimatedScale(
      scale: 1,
      duration: const Duration(milliseconds: 320),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: ShapeDecoration(color: color.withValues(alpha: 0.12), shape: const StadiumBorder()),
        child: DefaultTextStyle(
          style: TegnalType.style(17, color: color),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (starred) ...[Icon(Symbols.starFill, size: 15, color: CupertinoColors.systemYellow.resolveFrom(context)), const SizedBox(width: 4)],
              child,
            ],
          ),
        ),
      ),
    ),
  );
}

class _GalleryDetailMetadata extends StatelessWidget {
  const _GalleryDetailMetadata({
    required this.gallery,
    required this.content,
    required this.savedIDs,
    required this.savedQueries,
    required this.favoriteArtists,
    required this.search,
    required this.openVersion,
    required this.toggleSaved,
  });

  final NativeGallery gallery;
  final ContentEnvironment content;
  final Set<int> savedIDs;
  final Set<String> savedQueries;
  final Set<String> favoriteArtists;
  final ValueChanged<String>? search;
  final ValueChanged<int>? openVersion;
  final void Function(String name, SavedCollectionKind kind) toggleSaved;

  List<String> get _artists {
    final seen = <String>{};
    final tagged =
        ArtworkTagGroup.make(tags: gallery.tags)
            .where((group) => group.category == ArtworkTagCategory.artist)
            .firstOrNull
            ?.tags
            .map((tag) => tag.query.substring('artist:'.length)) ??
        const <String>[];
    return [...gallery.artists, ...tagged].where((name) => MangaArtistFavorite.key(name).isNotEmpty && seen.add(MangaArtistFavorite.key(name))).toList();
  }

  List<ArtworkTagGroup> get _groups {
    final tags = ArtworkTagGroup.make(tags: gallery.tags)
        .where((group) => group.category != ArtworkTagCategory.artist && group.category != ArtworkTagCategory.language);
    // Keep Other Tags last, including an empty placeholder.
    return [
      ...tags.where((group) => group.category != ArtworkTagCategory.general),
      tags.where((group) => group.category == ArtworkTagCategory.general).firstOrNull ?? const ArtworkTagGroup(category: ArtworkTagCategory.general, tags: []),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final label = TegnalColors.label.resolveFrom(context);
    final headline = TegnalType.style(17, weight: FontWeight.w600, color: label);
    final versions = gallery.otherVersions(L10n.contentLanguage).where((version) => !content.hiddenMangaGalleryIDs.contains(version.id)).toList();
    final languageColor = artworkTagColor(ArtworkTagCategory.language, context);
    final artistColor = artworkTagColor(ArtworkTagCategory.artist, context);
    Widget section(Widget heading, Widget body) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [heading, const SizedBox(height: 4), body]),
    );
    final artists = _artists;
    final languageSaved = savedQueries.contains(SavedCollectionKind.language.query(gallery.language, manga: true));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        section(
          Text(L10n.text('Artists'), style: headline),
          artists.isEmpty
              ? const _MetadataPlaceholder()
              : FlowLayout(
                  spacing: 6,
                  children: [
                    for (final name in artists)
                      ArtworkTagPill(
                        color: artistColor,
                        starred: favoriteArtists.contains(MangaArtistFavorite.key(name)),
                        onTap: search == null ? null : () => search!('artist:${name.replaceAll(' ', '_')}'),
                        onLongPress: () => toggleSaved(name, SavedCollectionKind.artist),
                        child: Text(name.replaceAll('_', ' ')),
                      ),
                  ],
                ),
        ),
        section(
          Text(L10n.text('Language'), style: headline),
          gallery.language.trim().isEmpty
              ? const _MetadataPlaceholder()
              : FlowLayout(
                  children: [
                    ArtworkTagPill(
                      color: languageColor,
                      starred: languageSaved,
                      onTap: search == null ? null : () => search!('language:${gallery.language.replaceAll(' ', '_')}'),
                      onLongPress: () => toggleSaved(gallery.language, SavedCollectionKind.language),
                      child: Text(gallery.language),
                    ),
                  ],
                ),
        ),
        if (openVersion != null && versions.isNotEmpty)
          section(
            Text(L10n.text('Other Languages'), style: headline),
            FlowLayout(
              spacing: 6,
              children: [
                for (final version in versions)
                  ArtworkTagPill(
                    color: languageColor,
                    onTap: () => openVersion!(version.id),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (savedIDs.contains(version.id)) ...[
                          Icon(Symbols.bookmarkFill, size: 13, color: CupertinoColors.systemYellow.resolveFrom(context)),
                          const SizedBox(width: 4),
                        ],
                        Text(version.displayName),
                        const SizedBox(width: 4),
                        Icon(CupertinoIcons.chevron_right, size: 11, color: languageColor.withValues(alpha: 0.6)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        section(
          Row(
            children: [
              Text(L10n.text('Tags'), style: headline),
              const SizedBox(width: 4),
              // `SettingsInfoButton`: a secondary info glyph in a 32 pt target.
              Semantics(
                button: true,
                label: L10n.text('About %@', [L10n.text('Tags')]),
                excludeSemantics: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => showCupertinoDialog<void>(
                    context: context,
                    barrierDismissible: true,
                    builder: (context) => CupertinoAlertDialog(
                      title: Text(L10n.text('Tags')),
                      content: Text(L10n.text('Hold an artist or tag to add it to your favorites. Hold it again to remove it.')),
                      actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('Done')))],
                    ),
                  ),
                  child: SizedBox.square(
                    dimension: 32,
                    child: Icon(CupertinoIcons.info_circle, size: 20, color: TegnalColors.tint.resolveFrom(context).withValues(alpha: 0.6)),
                  ),
                ),
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_groups.every((group) => group.tags.isEmpty)) const _MetadataPlaceholder(),
              for (final (index, group) in _groups.indexed) ...[if (index > 0) const SizedBox(height: 12), _tagGroup(context, group, headline)],
            ],
          ),
        ),
        GalleryWorkNumber(number: gallery.id),
      ],
    );
  }

  Widget _tagGroup(BuildContext context, ArtworkTagGroup group, TextStyle headline) {
    final color = artworkTagColor(group.category, context);
    final hidesHeading = group.category == ArtworkTagCategory.female || group.category == ArtworkTagCategory.male;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!hidesHeading) ...[Text(L10n.text(group.category.title), style: headline.copyWith(color: color)), const SizedBox(height: 4)],
        if (group.tags.isEmpty) const _MetadataPlaceholder(),
        FlowLayout(
          spacing: 6,
          children: [
            for (final tag in group.tags)
              ArtworkTagPill(
                color: color,
                starred: savedQueries.contains(tag.query.replaceAll(' ', '_')),
                onTap: search == null ? null : () => search!(tag.query.replaceAll(' ', '_')),
                onLongPress: () => toggleSaved(tag.query, tag.category.savedKind),
                child: Text(tag.name),
              ),
          ],
        ),
      ],
    );
  }
}

class _MetadataPlaceholder extends StatelessWidget {
  const _MetadataPlaceholder();
  @override
  Widget build(BuildContext context) => const SizedBox.square(dimension: 22);
}

/// `GalleryWorkNumber`: the number in a pill; tap or hold copies it.
class GalleryWorkNumber extends StatefulWidget {
  const GalleryWorkNumber({super.key, required this.number});
  final int number;

  @override
  State<GalleryWorkNumber> createState() => _GalleryWorkNumberState();
}

class _GalleryWorkNumberState extends State<GalleryWorkNumber> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: '${widget.number}'));
    HapticFeedback.mediumImpact();
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final color = artworkTagColor(ArtworkTagCategory.general, context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          L10n.text('Number'),
          style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            ArtworkTagPill(color: color, onTap: _copy, onLongPress: _copy, child: Text('${widget.number}')),
            if (_copied) ...[
              const SizedBox(width: 8),
              Icon(Symbols.checkmark, size: 12, color: TegnalColors.secondaryLabel.resolveFrom(context)),
              const SizedBox(width: 4),
              Text(L10n.text('Copied'), style: TegnalType.style(12, color: TegnalColors.secondaryLabel.resolveFrom(context))),
            ],
          ],
        ),
      ],
    );
  }
}

/// Page previews in pages of rows, with a page picker beside the heading.
class GalleryDetailPreviews extends StatefulWidget {
  const GalleryDetailPreviews({super.key, required this.gallery, required this.images, required this.content, required this.enabled, required this.select});
  final NativeGallery gallery;
  final PageImageStore images;
  final ContentEnvironment content;
  final bool enabled;
  final ValueChanged<int> select;

  @override
  State<GalleryDetailPreviews> createState() => _GalleryDetailPreviewsState();
}

class _GalleryDetailPreviewsState extends State<GalleryDetailPreviews> {
  final _pages = PageController();
  int _selected = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.content;
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final fullWidth = constraints.maxWidth + 40;
        final columns = GalleryPreviewLayout.columns(
          width: fullWidth,
          artworkColumns: content.mangaColumns,
          previewColumns: content.mangaPreviewColumns,
          removesArtworkPadding: content.mangaRemovesGridPadding,
        );
        final rows = content.mangaPreviewRows;
        final total = widget.gallery.pages.length;
        final pageCount = GalleryPreviewLayout.pageCount(total: total, columns: columns, rows: rows);
        final geometry = ArtworkGridGeometry(
          width: fullWidth,
          columns: columns,
          removesPadding: content.mangaRemovesGridPadding,
          maximumColumns: columns < 10 ? 10 : columns,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(height: 0.5, color: TegnalColors.separator.resolveFrom(context)),
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  L10n.text('Preview'),
                  style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                ),
                const SizedBox(width: 12),
                if (widget.enabled)
                  Expanded(
                    child: SizedBox(
                      height: 40,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        reverse: true,
                        child: Row(
                          children: [
                            for (var page = 0; page < pageCount; page++)
                              Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: GestureDetector(
                                  onTap: () {
                                    setState(() => _selected = page);
                                    _pages.animateToPage(page, duration: const Duration(milliseconds: 200), curve: Curves.easeInOut);
                                  },
                                  child: Container(
                                    constraints: const BoxConstraints(minWidth: 32, minHeight: 36),
                                    alignment: Alignment.center,
                                    padding: const EdgeInsets.symmetric(horizontal: 8),
                                    decoration: ShapeDecoration(
                                      color: _selected == page ? TegnalColors.tint.resolveFrom(context).withValues(alpha: 0.14) : null,
                                      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                    child: Text(
                                      '${page + 1}',
                                      style: TegnalType.style(
                                        15,
                                        weight: _selected == page ? FontWeight.w700 : FontWeight.w400,
                                        color: TegnalColors.label.resolveFrom(context),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (widget.enabled)
              // The pages reach the sheet's edges, past the 20 pt content padding.
              SizedBox(
                height: GalleryPreviewLayout.height(
                  rows: GalleryPreviewLayout.filledRows(total: total, columns: columns, rows: rows),
                  geometry: geometry,
                ),
                child: OverflowBox(
                  minWidth: fullWidth,
                  maxWidth: fullWidth,
                  child: PageView.builder(
                    controller: _pages,
                    itemCount: pageCount,
                    onPageChanged: (page) => setState(() => _selected = page),
                    itemBuilder: (context, page) => GalleryPagePreviewGrid(
                      gallery: widget.gallery,
                      images: widget.images,
                      geometry: geometry,
                      columns: columns,
                      removesPadding: content.mangaRemovesGridPadding,
                      range: GalleryPreviewLayout.pageRange(page, total: total, columns: columns, rows: rows),
                      select: widget.select,
                    ),
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(CupertinoIcons.chevron_down, size: 14, color: secondary),
                      const SizedBox(width: 6),
                      Text(L10n.text('Scroll down to load page previews.'), style: TegnalType.style(15, color: secondary)),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// A page of thumbnails; the current page, when given, gets a tint border.
class GalleryPagePreviewGrid extends StatelessWidget {
  const GalleryPagePreviewGrid({
    super.key,
    required this.gallery,
    required this.images,
    required this.geometry,
    required this.columns,
    required this.removesPadding,
    required this.range,
    required this.select,
    this.current,
  });

  final NativeGallery gallery;
  final PageImageStore images;
  final ArtworkGridGeometry geometry;
  final int columns;
  final bool removesPadding;
  final (int, int) range;
  final ValueChanged<int> select;
  final int? current;

  @override
  Widget build(BuildContext context) {
    final style = ArtworkCellStyle(width: geometry.cellWidth, removesPadding: removesPadding);
    final indices = [for (var index = range.$1; index < range.$2; index++) index];
    final rows = (indices.length / columns).ceil();
    return Padding(
      padding: EdgeInsets.all(geometry.margin),
      child: Column(
        children: [
          for (var row = 0; row < rows; row++) ...[
            if (row > 0) SizedBox(height: geometry.spacing),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var column = 0; column < columns; column++) ...[
                  if (column > 0) SizedBox(width: geometry.spacing),
                  Expanded(
                    child: row * columns + column < indices.length ? _thumbnail(context, indices[row * columns + column], style) : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _thumbnail(BuildContext context, int index, ArtworkCellStyle style) => Semantics(
    button: true,
    label: L10n.text('Pages: %@', ['${index + 1}']),
    child: GestureDetector(
      onTap: () => select(index),
      child: AspectRatio(
        aspectRatio: 0.72,
        child: Container(
          foregroundDecoration: current == index
              ? ShapeDecoration(
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(style.radius(12)),
                    side: BorderSide(color: TegnalColors.tint.resolveFrom(context), width: 3),
                  ),
                )
              : null,
          child: ClipRSuperellipse(
            borderRadius: BorderRadius.circular(style.radius(12)),
            child: ReaderThumbnail(page: gallery.pages[index], galleryID: gallery.id, images: images),
          ),
        ),
      ),
    ),
  );
}

/// One page thumbnail, loaded when it appears.
class ReaderThumbnail extends StatefulWidget {
  const ReaderThumbnail({super.key, required this.page, required this.galleryID, required this.images});
  final GalleryPage page;
  final int galleryID;
  final PageImageStore images;

  @override
  State<ReaderThumbnail> createState() => _ReaderThumbnailState();
}

class _ReaderThumbnailState extends State<ReaderThumbnail> {
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _image = widget.images.cachedImage(widget.page.hash, thumbnail: true);
    if (_image == null) _load();
  }

  Future<void> _load() async {
    try {
      final image = await widget.images.load(widget.page, galleryID: widget.galleryID, thumbnail: true);
      if (mounted) setState(() => _image = image);
    } on Object {
      // The placeholder stays.
    }
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: TegnalColors.coverPlaceholder.resolveFrom(context),
    child: _image != null
        ? RawImage(image: _image, fit: BoxFit.cover, filterQuality: ui.FilterQuality.medium)
        : Center(child: Icon(Symbols.photo, color: TegnalColors.secondaryLabel.resolveFrom(context))),
  );
}

/// Report, hide and block, for when a work should not be shown.
class _MangaContentControls extends StatelessWidget {
  const _MangaContentControls({required this.gallery, required this.content});
  final NativeGallery gallery;
  final ContentEnvironment content;

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    final hidden = content.hiddenMangaGalleryIDs.contains(gallery.id);
    Widget row(IconData icon, String title, VoidCallback onTap, {bool chevron = false}) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, size: 20, color: tint),
            const SizedBox(width: 12),
            Expanded(
              child: Text(title, style: TegnalType.style(17, color: tint)),
            ),
            if (chevron) Icon(CupertinoIcons.chevron_right, size: 13, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
          ],
        ),
      ),
    );
    final divider = Container(height: 0.5, margin: const EdgeInsets.only(left: 16), color: TegnalColors.separator.resolveFrom(context));
    final page = MangaUrls.galleryUrl(gallery.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(L10n.text('Content Controls'), style: TegnalType.style(15, color: TegnalColors.secondaryLabel.resolveFrom(context))),
        ),
        const SizedBox(height: 12),
        ClipRSuperellipse(
          borderRadius: BorderRadius.circular(12),
          child: ColoredBox(
            color: FormColors.row.resolveFrom(context),
            child: Column(
              children: [
                if (page.isNotEmpty) ...[row(CupertinoIcons.flag, L10n.text('Report Content'), () {}, chevron: true), divider],
                row(CupertinoIcons.eye_slash, L10n.text(hidden ? 'Show This Work' : 'Hide This Work'), () {
                  content.setMangaGalleryHidden(gallery.id, hidden: !hidden);
                  Navigator.of(context).pop();
                }),
                if (gallery.artists.isNotEmpty) ...[
                  divider,
                  row(CupertinoIcons.person_crop_circle_badge_xmark, L10n.text('Block Artist'), () async {
                    final artist = await showCupertinoModalPopup<String>(
                      context: context,
                      builder: (context) => CupertinoActionSheet(
                        actions: [
                          for (final artist in gallery.artists)
                            CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, artist), child: Text(artist)),
                        ],
                        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context), child: Text(L10n.text('Cancel'))),
                      ),
                    );
                    if (artist == null || !context.mounted) return;
                    content.blockMangaArtist(artist);
                    Navigator.of(context).pop();
                  }),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
