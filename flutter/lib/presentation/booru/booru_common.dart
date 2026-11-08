import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/booru/booru_client.dart';
import '../../core/booru/booru_models.dart';
import '../../core/booru/booru_store.dart';
import '../../core/booru/booru_image_cache.dart';
import '../../core/storage/app_database.dart';
import '../../core/taste/taste_models.dart';
import '../../core/support/l10n.dart';
import '../../core/support/preferences.dart';
import '../content/content_bookmark.dart';
import '../content/explore_view.dart' show ContentUnavailable;
import '../content/reader_models.dart' show ThumbnailAction, ThumbnailGesture;
import '../design/glass.dart';
import '../design/pull_down_menu.dart';
import '../design/symbols.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import '../navigation/app_header.dart';
import '../navigation/app_state.dart';
import '../settings/downloads_view.dart';
import '../works/artwork_grid.dart';
import '../content/reading_queue_views.dart';
import '../../core/support/app_platform.dart';

/// What every image-mode screen shares, created once with the root.
class BooruContext {
  BooruContext({
    required this.state,
    required this.store,
    required this.source,
    required this.thumbnails,
    required this.viewerImages,
    required this.database,
    required this.preferences,
    required this.booruDefaults,
    required this.downloads,
    this.fixture = false,
  });

  final AppState state;
  final BooruStore store;
  final BooruProviding source;
  final BooruImageCache thumbnails;
  final BooruImageCache viewerImages;

  /// The comics database, for the shared search retention and taste settings.
  final AppDatabase database;

  /// `browserPreferences`, which hold both libraries' grid settings.
  final Preferences preferences;

  /// `ReaderPreferences.booruDefaults`: the image viewer's own settings.
  final Preferences booruDefaults;
  final DownloadsContext downloads;

  /// Offline fixture runs draw generated thumbnails, as the native UI tests do.
  final bool fixture;

  ArtworkGridPreferences get gridPreferences => ArtworkGridPreferences(
    columns: preferences.integer('booru.grid_columns').clamp(0, 5),
    removesPadding: preferences.boolean('booru.grid.noPadding') ?? false,
  );

  int get folderColumns => preferences.integer('booru.folder_columns').clamp(0, 5);

  bool get fitsThumbnails => booruDefaults.boolean('booru.fitThumbnails') ?? false;

  bool get remembersHistory => booruDefaults.boolean('booru.rememberHistory') ?? true;

  /// `booru.useEmbeddedBrowser`: Explore shows the website instead of the image grid.
  static const embeddedBrowserKey = 'booru.useEmbeddedBrowser';
  bool get useEmbeddedBrowser => AppPlatform.hasWebView && (booruDefaults.boolean(embeddedBrowserKey) ?? false);
  set useEmbeddedBrowser(bool value) {
    booruDefaults.set(embeddedBrowserKey, value);
    embeddedBrowserChanges.value++;
  }

  /// Counts changes to [useEmbeddedBrowser], so open feeds switch between the grid and the website.
  final embeddedBrowserChanges = ValueNotifier<int>(0);

  bool get safeMode => preferences.boolean('booru.safeMode') ?? false;
  BooruSafeRating get safeRating => BooruSafeRating.fromRawValue(preferences.string('booru.safeRating')) ?? BooruSafeRating.general;

  /// `booruQuery`: Safe Mode adds its rating tag unless the search names one, and only when a
  /// server other than Safebooru is chosen; Safebooru has no rating tags and is all ages.
  String query(String query) => safeMode && store.needsSafeRating ? safeRating.applyingDefault(query) : query;

  BooruServer? server(String id) {
    for (final server in store.servers) {
      if (server.id == id) return server;
    }
    return null;
  }

  /// `BooruFavoriteAction.toggle` as a save notice.
  WorkSaveFeedback toggleFavorite(BooruPost post, {DiscoveryContext? context}) => WorkSaveFeedback.perform(() {
    final saved = store.isFavorite(post);
    store.toggleFavorite(post, context: context);
    return saved ? const WorkSaveResult.removed(TasteMode.booru) : const WorkSaveResult.added(TasteMode.booru);
  });
}

/// `BooruThumbnail`: the preview image filling its cell, cached across screens.
class BooruThumbnail extends StatefulWidget {
  const BooruThumbnail({super.key, required this.post, required this.server, required this.booru});
  final BooruPost post;
  final BooruServer server;
  final BooruContext booru;

  @override
  State<BooruThumbnail> createState() => _BooruThumbnailState();
}

/// The decode width for a thumbnail of this size, as the native cache decodes it: the shorter
/// side keeps about 720 pixels, so a tall or wide image cropped to fill a cell stays sharp,
/// the longer side stops at 2048, and the file is never enlarged.
int booruThumbnailDecodeWidth(int width, int height) {
  const shortSide = 720, longSide = 2048;
  final long = width > height ? width : height;
  final short = (width < height ? width : height).clamp(1, 1 << 30);
  final scale = [1.0, shortSide / short, longSide / long].reduce((a, b) => a < b ? a : b);
  return (width * scale).round().clamp(1, width);
}

class _BooruThumbnailState extends State<BooruThumbnail> {
  Uint8List? _image;
  int? _decodeWidth;
  bool _failed = false;
  int _generation = 0;

  /// Decode widths of recent thumbnails, so cached ones draw at once.
  static final _decodeWidths = <String, int>{};

  String? get _url => widget.post.previewURL ?? widget.post.sampleURL;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(BooruThumbnail old) {
    super.didUpdateWidget(old);
    if (old.post.id != widget.post.id || (old.post.previewURL ?? old.post.sampleURL) != _url) {
      _image = null;
      _decodeWidth = null;
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _failed = false;
    final url = _url;
    if (widget.booru.fixture) return;
    if (url == null) {
      setState(() => _failed = true);
      return;
    }
    final cached = widget.booru.thumbnails.cached(url, widget.server);
    final known = _decodeWidths[url];
    if (cached != null && known != null) {
      _image = cached;
      _decodeWidth = known;
      return;
    }
    try {
      final data = cached ?? await widget.booru.thumbnails.load(url, widget.server);
      final width = await _measure(data);
      if (width != null) {
        if (_decodeWidths.length >= 512) _decodeWidths.remove(_decodeWidths.keys.first);
        _decodeWidths[url] = width;
      }
      if (mounted && generation == _generation) {
        setState(() {
          _image = data;
          _decodeWidth = width;
        });
      }
    } on Object {
      if (mounted && generation == _generation) setState(() => _failed = true);
    }
  }

  /// Reads only the image header for its size.
  static Future<int?> _measure(Uint8List data) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(data);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = booruThumbnailDecodeWidth(descriptor.width, descriptor.height);
      descriptor.dispose();
      buffer.dispose();
      return width;
    } on Object {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final Widget content;
    if (widget.booru.fixture) {
      // A wide two-color image through the same fill as real thumbnails.
      content = FittedBox(
        fit: widget.booru.fitsThumbnails ? BoxFit.contain : BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: 1600,
          height: 300,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: ColoredBox(color: SystemColors.indigo.resolveFrom(context))),
              Expanded(child: ColoredBox(color: SystemColors.cyan.resolveFrom(context))),
            ],
          ),
        ),
      );
    } else if (image != null) {
      content = LayoutBuilder(
        builder: (context, constraints) => Image.memory(
          image,
          fit: widget.booru.fitsThumbnails ? BoxFit.contain : BoxFit.cover,
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          cacheWidth: _decodeWidth,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (context, _, _) => _failure(context),
        ),
      );
    } else if (_failed) {
      content = _failure(context);
    } else {
      content = const Center(child: CupertinoActivityIndicator());
    }
    return IgnorePointer(
      child: ColoredBox(color: TegnalColors.coverPlaceholder.resolveFrom(context), child: content),
    );
  }

  Widget _failure(BuildContext context) =>
      Center(child: Icon(CupertinoIcons.exclamationmark_triangle, color: TegnalColors.secondaryLabel.resolveFrom(context)));
}

/// `BooruThumbnailCardLayout`: a 0.78 card with its video or animation badge and,
/// in feeds, a heart on favorites.
class BooruThumbnailCard extends StatelessWidget {
  const BooruThumbnailCard({super.key, required this.post, required this.style, required this.cover, this.showsFavorite = false, this.isFavorite = false});
  final BooruPost post;
  final ArtworkCellStyle style;
  final Widget cover;
  final bool showsFavorite;
  final bool isFavorite;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(style.radius(16));
    return ClipRRect(
      borderRadius: radius,
      child: ColoredBox(
        color: TegnalColors.secondaryBackground.resolveFrom(context),
        child: AspectRatio(
          aspectRatio: 0.78,
          child: Stack(
            fit: StackFit.expand,
            children: [
              cover,
              if (post.isVideo || post.isAnimated)
                Positioned(
                  right: style.inset(8),
                  top: style.inset(8),
                  child: _Badge(
                    style: style,
                    child: Icon(
                      post.isVideo ? CupertinoIcons.play_fill : CupertinoIcons.sparkles,
                      size: style.fontSize(10) + 2,
                      color: TegnalColors.label.resolveFrom(context),
                    ),
                  ),
                ),
              if (showsFavorite && isFavorite)
                Positioned(
                  left: style.inset(8),
                  top: style.inset(8),
                  child: _Badge(
                    style: style,
                    circle: true,
                    child: Icon(CupertinoIcons.heart_fill, size: style.fontSize(13), color: SystemColors.pink.resolveFrom(context)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `.ultraThinMaterial` under a small symbol.
class _Badge extends StatelessWidget {
  const _Badge({required this.style, required this.child, this.circle = false});
  final ArtworkCellStyle style;
  final Widget child;
  final bool circle;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(style.inset(circle ? 8 : 6)),
    decoration: ShapeDecoration(
      color: TegnalColors.background.resolveFrom(context).withValues(alpha: 0.55),
      shape: circle ? const CircleBorder() : const StadiumBorder(),
    ),
    child: child,
  );
}

/// `BooruPostGrid`: posts in the shared artwork grid. Feeds hold a card to favorite it;
/// a selection marks cards instead of opening them.
class BooruPostGridSliver extends StatelessWidget {
  const BooruPostGridSliver({
    super.key,
    required this.booru,
    required this.posts,
    required this.open,
    this.showsFavorite = false,
    this.selection,
    this.toggleSelection,
    this.hold,
    this.holdSaves = false,
    this.fileIntoFolder,
    this.prefetch,
    this.topMarginScale = 1,
    this.itemKey,
  });

  final BooruContext booru;
  final List<BooruPost> posts;
  final ValueChanged<BooruPost> open;
  final bool showsFavorite;
  final Set<String>? selection;
  final ValueChanged<BooruPost>? toggleSelection;
  final void Function(BuildContext context, BooruPost post)? hold;

  /// Whether [hold] saves the image, which then presses like a held comic. Such a grid also
  /// follows the image-mode thumbnail gestures chosen in Settings.
  final bool holdSaves;

  /// Files the image into a folder, for a gesture set to do that.
  final void Function(BuildContext context, BooruPost post)? fileIntoFolder;

  /// Asks for the next page as the last rows appear.
  final VoidCallback? prefetch;
  final double topMarginScale;

  /// Lets a feed scroll back to the post a viewer ended on.
  final GlobalKey Function(String id)? itemKey;

  @override
  Widget build(BuildContext context) {
    final favorites = booru.store.favoriteIDs;
    final threshold = posts.length - 8;
    return ArtworkGridSliver(
      itemCount: posts.length,
      topMarginScale: topMarginScale,
      preferences: booru.gridPreferences,
      itemBuilder: (context, index, style) {
        final post = posts[index];
        final server = booru.server(post.serverID);
        if (server == null) return const SizedBox.shrink();
        if (index >= threshold) prefetch?.call();
        final selection = this.selection;
        final card = BooruThumbnailCard(
          post: post,
          style: style,
          showsFavorite: showsFavorite,
          isFavorite: favorites.contains(post.id),
          cover: BooruThumbnail(post: post, server: server, booru: booru),
        );
        return Semantics(
          key: itemKey?.call(post.id),
          button: true,
          label: '${server.displayName} · ${post.postID}',
          value: selection != null
              ? (selection.contains(post.id) ? L10n.text('Selected') : '')
              : showsFavorite
              ? WorkSaveResult.accessibilityValue(saved: favorites.contains(post.id), mode: TasteMode.booru)
              : '',
          child: Builder(
            // A hold that saves presses the image as comics do; one that opens a menu does not.
            builder: (cardContext) => selection == null && hold != null && holdSaves
                ? ValueListenableBuilder<int>(
                    valueListenable: ThumbnailGesture.changes,
                    builder: (_, _, _) {
                      void perform(ThumbnailGesture gesture) => switch (gesture.action(booru: true)) {
                        ThumbnailAction.open => open(post),
                        ThumbnailAction.favorite => hold!(cardContext, post),
                        ThumbnailAction.folder => fileIntoFolder?.call(cardContext, post),
                        _ => null,
                      };
                      return WorkHold(
                        onTap: () => perform(ThumbnailGesture.tap),
                        onDoubleTap: ThumbnailGesture.doubleTap.action(booru: true) == ThumbnailAction.none ? null : () => perform(ThumbnailGesture.doubleTap),
                        bookmark: () => perform(ThumbnailGesture.hold),
                        child: card,
                      );
                    },
                  )
                : GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => selection != null ? toggleSelection?.call(post) : open(post),
                    onLongPress: selection != null || hold == null ? null : () => hold!(cardContext, post),
                    child: selection == null
                        ? card
                        : Stack(
                            children: [
                              card,
                              Positioned(right: 10, top: 10, child: _SelectionMark(selected: selection.contains(post.id))),
                            ],
                          ),
                  ),
          ),
        );
      },
    );
  }
}

class _SelectionMark extends StatelessWidget {
  const _SelectionMark({required this.selected});
  final bool selected;

  @override
  Widget build(BuildContext context) => selected
      ? Container(
          decoration: const ShapeDecoration(color: Color(0xFFFFFFFF), shape: CircleBorder()),
          child: Icon(CupertinoIcons.checkmark_circle_fill, size: 26, color: SystemColors.blue.resolveFrom(context)),
        )
      : const Icon(CupertinoIcons.circle, size: 26, color: Color(0xFFFFFFFF));
}

/// `BooruServerMenu`: the server button and its menu of servers to search together.
class BooruServerMenuButton extends StatelessWidget {
  const BooruServerMenuButton({super.key, required this.store, this.grouped = false});
  final BooruStore store;

  /// Inside a [ToolbarGroup] beside other buttons, rather than its own glass circle.
  final bool grouped;

  Future<void> _open(BuildContext context) async {
    final selected = store.selectedServerIDs.toSet();
    final id = await showPullDownMenu<String>(
      context,
      anchor: anchorRectOf(context),
      items: [for (final server in store.servers) PullDownMenuItem(value: server.id, title: server.displayName, checked: selected.contains(server.id))],
    );
    if (id == null) return;
    final server = store.servers.where((server) => server.id == id).firstOrNull;
    if (server != null) store.toggleServer(server);
  }

  @override
  Widget build(BuildContext context) {
    final names = store.selectedServers.map((server) => server.displayName).join(', ');
    final button = Builder(
      builder: (context) => ToolbarIconButton(
        label: '${L10n.text('Servers')}: ${names.isEmpty ? L10n.text('None') : names}',
        symbol: (color) => ServerRackSymbol(size: 22, color: color),
        onPressed: () => _open(context),
      ),
    );
    if (grouped) return button;
    // A lone toolbar button sits in a glass pill barely wider than it is tall.
    return Glass.capsule(
      child: SizedBox(width: 48, height: 44, child: Center(child: button)),
    );
  }
}

/// `BooruNoSelectionView`.
class BooruNoSelectionView extends StatelessWidget {
  const BooruNoSelectionView({super.key});

  @override
  Widget build(BuildContext context) => ContentUnavailable(
    icon: CupertinoIcons.square_stack_3d_up,
    title: L10n.text('No servers selected'),
    message: L10n.text('Choose servers using the server button above. Your saved works are kept.'),
  );
}

/// Scrolls a grid back to the post a viewer ended on, when it differs from the opened one
/// (`BooruViewerReturn`).
void restoreViewerPosition({required String? openedID, required String viewedID, required Map<String, GlobalKey> keys}) {
  if (openedID == null || openedID == viewedID) return;
  final target = keys[viewedID]?.currentContext;
  if (target == null) return;
  unawaited(Scrollable.ensureVisible(target, alignment: 0.5));
}
