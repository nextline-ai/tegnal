import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/semantics.dart';

import '../../core/booru/booru_models.dart';
import '../../core/content/gallery_content.dart';
import '../../core/support/l10n.dart';
import '../../core/taste/recommendation_service.dart';
import '../../core/taste/taste_analyzer.dart';
import '../../core/taste/taste_feed_state.dart';
import '../../core/taste/taste_models.dart';
import '../../core/taste/taste_recap.dart';
import '../booru/booru_common.dart';
import '../booru/booru_post_view.dart';
import '../content/content_bookmark.dart';
import '../content/work_save_feedback.dart';
import '../design/context_menu.dart';
import '../design/symbols.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import '../library/folders_view.dart' show anchorOf;
import '../navigation/root_tab_view.dart';
import '../works/artwork_grid.dart';
import 'taste_context.dart';
import 'taste_dashboard.dart';
import '../booru/booru_favorites_view.dart';

/// Shared presentation values keep raw tags intact for queries and evidence.
abstract final class TastePresentation {
  static Color accent(BuildContext context) => SystemColors.indigo.resolveFrom(context);
  static String name(String tag) => tag.replaceAll('_', ' ');
  static String host(String source) => Uri.tryParse(source)?.host.isNotEmpty == true ? Uri.parse(source).host : source;
  static String category(TasteTag tag) => L10n.text(
    tag.count == 0
        ? 'Searched tags'
        : tag.discovery
        ? 'Hidden taste candidate'
        : tag.confirmed > 0
        ? 'Confirmed preference'
        : 'Often saved together',
  );
  static String explanation(TasteInsight insight, TasteTag tag, TasteSnapshot snapshot) => switch (insight.pattern) {
    TasteInsightPattern.confirmed => L10n.text('You chose and saved %@ works associated with this tag.', ['${tag.confirmed}']),
    TasteInsightPattern.discovery => L10n.text('You saved %@ works with this tag without searching for it, across %@ sessions.', [
      '${tag.hidden}',
      '${tag.sessions.length}',
    ]),
    TasteInsightPattern.frequent => L10n.text('This tag appears in %@ of your saved works.', ['${tag.count}']),
    TasteInsightPattern.rising => L10n.text('Saved works with this tag increased from %@ to %@.', [
      '${snapshot.previousTagCounts[tag.id] ?? 0}',
      '${tag.count}',
    ]),
    TasteInsightPattern.association => L10n.text('This tag often appears together with %@ in your saved works.', [
      snapshot.tags.where((other) => other.id == insight.relatedKey).firstOrNull?.name ?? '',
    ]),
  };

  /// SF Symbols of the recommendation reasons, as Cupertino icons.
  static IconData icon(String symbol) => switch (symbol) {
    'heart' => CupertinoIcons.heart,
    'flame' => CupertinoIcons.flame,
    'sparkles' => CupertinoIcons.sparkles,
    'arrow.uturn.backward' => CupertinoIcons.arrow_uturn_left,
    'link' => CupertinoIcons.link,
    'paintpalette' => CupertinoIcons.paintbrush,
    'safari' => CupertinoIcons.compass,
    'square.on.square' => CupertinoIcons.square_on_square,
    'chart.line.uptrend.xyaxis' => CupertinoIcons.graph_circle,
    _ => CupertinoIcons.sparkles,
  };
}

/// `TasteSurface`: an 18 pt padded card on the grouped background, 22 pt corners.
class TasteSurface extends StatelessWidget {
  const TasteSurface({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: ShapeDecoration(
      color: TegnalColors.secondaryBackground.resolveFrom(context),
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(22)),
    ),
    child: child,
  );
}

/// `TasteSectionHeading`: a bold title over an optional subtitle.
class TasteSectionHeading extends StatelessWidget {
  const TasteSectionHeading({super.key, required this.title, this.subtitle});
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          L10n.text(title),
          style: TegnalType.style(20, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(subtitle!, style: TegnalType.style(15, color: TegnalColors.secondaryLabel.resolveFrom(context))),
        ],
      ],
    ),
  );
}

/// `TasteTagRow`: the tag's symbol tile, name, category and count.
class TasteTagRow extends StatelessWidget {
  const TasteTagRow({super.key, required this.tag});
  final TasteTag tag;

  @override
  Widget build(BuildContext context) {
    final accent = TastePresentation.accent(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final label = TegnalColors.label.resolveFrom(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: ShapeDecoration(
              color: accent.withValues(alpha: 0.09),
              shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: Icon(tag.discovery ? CupertinoIcons.sparkles : CupertinoIcons.number, size: 19, color: accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  TastePresentation.name(tag.name),
                  style: TegnalType.style(15, weight: FontWeight.w600, color: label),
                ),
                const SizedBox(height: 4),
                Text(TastePresentation.category(tag), style: TegnalType.style(12, color: secondary)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${tag.count == 0 ? tag.searches : tag.count}',
                style: TegnalType.style(17, weight: FontWeight.w600, color: label),
              ),
              const SizedBox(height: 3),
              Text(L10n.text(tag.count == 0 ? 'Searches' : 'Saved works'), style: TegnalType.style(11, color: secondary)),
            ],
          ),
          const SizedBox(width: 8),
          Icon(CupertinoIcons.chevron_right, size: 13, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
        ],
      ),
    );
  }
}

/// `TasteArtwork`: an image's thumbnail, or a comic's first page as its cover.
class TasteArtwork extends StatefulWidget {
  const TasteArtwork({super.key, required this.taste, this.post, this.gallery});
  final TasteContext taste;
  final BooruPost? post;
  final NativeGallery? gallery;

  @override
  State<TasteArtwork> createState() => _TasteArtworkState();
}

class _TasteArtworkState extends State<TasteArtwork> {
  ui.Image? _cover;
  bool _failed = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(TasteArtwork old) {
    super.didUpdateWidget(old);
    if (old.gallery?.id != widget.gallery?.id) _load();
  }

  Future<void> _load() async {
    final gallery = widget.gallery;
    final page = gallery?.pages.firstOrNull;
    final generation = ++_generation;
    _failed = false;
    if (gallery == null || page == null) return;
    final cached = widget.taste.images.cachedImage(page.hash, thumbnail: true);
    if (cached != null) {
      _cover = cached;
      return;
    }
    _cover = null;
    try {
      final image = await widget.taste.images.load(page, galleryID: gallery.id, thumbnail: true);
      if (mounted && generation == _generation) setState(() => _cover = image);
    } on Object {
      if (mounted && generation == _generation) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    final server = post == null ? null : widget.taste.booru.server(post.serverID);
    final cover = _cover;
    final Widget content;
    if (post != null && server != null) {
      content = BooruThumbnail(post: post, server: server, booru: widget.taste.booru);
    } else if (cover != null) {
      content = RawImage(image: cover, fit: BoxFit.cover, filterQuality: ui.FilterQuality.medium);
    } else if (widget.gallery != null && !_failed) {
      content = const Center(child: CupertinoActivityIndicator());
    } else {
      content = Center(child: Icon(Symbols.book, size: 30, color: TegnalColors.secondaryLabel.resolveFrom(context)));
    }
    return ExcludeSemantics(
      child: ColoredBox(
        color: TegnalColors.coverPlaceholder.resolveFrom(context),
        child: SizedBox.expand(child: content),
      ),
    );
  }
}

/// The feedback a card can offer. Absent on surfaces that only show evidence.
class RecommendationFeedback {
  const RecommendationFeedback({required this.why, required this.more, required this.dismiss});
  final ValueChanged<TasteRecommendation> why;
  final ValueChanged<TasteRecommendation> more;
  final ValueChanged<TasteRecommendation> dismiss;
}

/// `RecommendationMenu`: the ellipsis over a card, with why, more like this and not interested.
class RecommendationMenu extends StatelessWidget {
  const RecommendationMenu({super.key, required this.item, required this.feedback, this.compact = false});
  final TasteRecommendation item;
  final RecommendationFeedback feedback;
  final bool compact;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: L10n.text('Recommendation options'),
    child: Builder(
      builder: (buttonContext) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showActionMenu(
          buttonContext,
          anchor: anchorOf(buttonContext),
          actions: [
            ContextMenuAction(title: L10n.text('Why this recommendation?'), icon: CupertinoIcons.question_circle, onSelected: () => feedback.why(item)),
            ContextMenuAction(title: L10n.text('More like this'), icon: CupertinoIcons.square_on_square, onSelected: () => feedback.more(item)),
            ContextMenuAction(
              title: L10n.text('Not interested'),
              icon: CupertinoIcons.hand_thumbsdown,
              destructive: true,
              onSelected: () => feedback.dismiss(item),
            ),
          ],
        ),
        child: SizedBox.square(
          dimension: 44,
          child: Center(
            child: Text(
              '•••',
              style: TegnalType.style(
                compact ? 11 : 13,
                weight: FontWeight.w800,
                color: const Color(0xFFFFFFFF),
              ).copyWith(letterSpacing: -1, shadows: const [Shadow(color: Color(0xBF000000), blurRadius: 3)]),
            ),
          ),
        ),
      ),
    ),
  );
}

/// `TasteRecommendationCard`: the image or comic card with the one reason that found it.
class TasteRecommendationCard extends StatelessWidget {
  const TasteRecommendationCard({
    super.key,
    required this.taste,
    required this.item,
    required this.style,
    required this.open,
    required this.toggle,
    this.isBookmarked = false,
    this.feedback,
  });
  final TasteContext taste;
  final TasteRecommendation item;
  final ArtworkCellStyle style;
  final VoidCallback open;
  final VoidCallback toggle;
  final bool isBookmarked;
  final RecommendationFeedback? feedback;

  TasteMode get _mode => item.post == null ? TasteMode.comics : TasteMode.booru;

  bool get _saved => item.post == null ? isBookmarked : taste.booru.store.favoriteIDs.contains(item.post!.id);

  /// The one reason a card has room for. An exclusion removes it at once.
  String? get _reason {
    final why = item.why;
    if (feedback == null || why == null || !taste.controller.control.allows(item.reason.name, source: item.reason.source, mode: _mode)) return null;
    // The tag that found this work varies more than the artist behind many saves.
    return item.reason.name.isEmpty ? why.label : RecapText.tag(item.reason.name);
  }

  Widget _imageTags({String? language}) {
    final reason = _reason;
    return IgnorePointer(
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Row(
          children: [
            if (reason != null) Flexible(child: _chip(reason)),
            const Spacer(),
            if (language != null && language.isNotEmpty) _chip(language),
          ],
        ),
      ),
    );
  }

  Widget _chip(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: const ShapeDecoration(color: Color(0x94000000), shape: StadiumBorder()),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TegnalType.style(style.fontSize(12, minimum: 9), weight: FontWeight.w600, color: const Color(0xFFFFFFFF)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final post = item.post;
    final gallery = item.gallery;
    final server = post == null ? null : taste.booru.server(post.serverID);
    final Widget card;
    if (post != null && server != null) {
      card = Stack(
        children: [
          BooruThumbnailCard(
            post: post,
            style: style,
            showsFavorite: true,
            isFavorite: _saved,
            cover: BooruThumbnail(post: post, server: server, booru: taste.booru),
          ),
          Positioned(left: 0, right: 0, bottom: 0, child: _imageTags()),
        ],
      );
    } else if (post != null) {
      card = ClipRRect(
        borderRadius: BorderRadius.circular(style.radius(16)),
        child: AspectRatio(
          aspectRatio: 0.78,
          child: ColoredBox(
            color: TegnalColors.coverPlaceholder.resolveFrom(context),
            child: Icon(Symbols.photo, color: TegnalColors.secondaryLabel.resolveFrom(context)),
          ),
        ),
      );
    } else if (gallery != null) {
      card = Stack(
        children: [
          GalleryCardLayout(
            style: style,
            title: gallery.title,
            artists: gallery.artists.join(', '),
            language: gallery.language,
            showsLanguage: false,
            cover: Stack(
              fit: StackFit.expand,
              children: [
                TasteArtwork(taste: taste, gallery: gallery),
                Positioned(left: 0, right: 0, bottom: 0, child: _imageTags(language: gallery.language)),
              ],
            ),
          ),
          if (isBookmarked)
            Positioned(
              left: style.inset(7),
              top: style.inset(7),
              child: Container(
                padding: EdgeInsets.all(style.inset(8)),
                decoration: const ShapeDecoration(color: Color(0xB8000000), shape: CircleBorder()),
                child: Icon(Symbols.bookmarkFill, size: style.fontSize(14), color: SystemColors.yellow.resolveFrom(context)),
              ),
            ),
        ],
      );
    } else {
      card = const SizedBox.shrink();
    }
    return Semantics(
      button: true,
      value: WorkSaveResult.accessibilityValue(saved: _saved, mode: _mode),
      customSemanticsActions: {
        CustomSemanticsAction(
          label: WorkSaveResult.actionTitle(saved: _saved, mode: _mode),
        ): toggle,
      },
      child: SmartHold(
        taste: taste,
        item: item,
        onTap: open,
        toggle: toggle,
        child: Stack(
          children: [
            card,
            if (feedback != null)
              Positioned(
                right: 0,
                top: 0,
                child: RecommendationMenu(item: item, feedback: feedback!, compact: true),
              ),
          ],
        ),
      ),
    );
  }
}

/// `TasteRecommendationAction.toggle`: a save from recommendations, with its reason as evidence.
void toggleRecommendation(BuildContext context, TasteContext taste, TasteRecommendation item, {required String session}) {
  final discovery = DiscoveryContext.recommended(item.reason.name, session: session);
  final post = item.post;
  final WorkSaveFeedback feedback;
  if (post != null) {
    feedback = taste.booru.toggleFavorite(post, context: discovery);
  } else {
    feedback = WorkSaveFeedback.perform(
      () => ContentBookmarkAction.toggle(item.item.id, gallery: item.gallery, session: taste.comics.bookmarks, images: taste.images, context: discovery),
      galleryID: item.item.id,
    );
  }
  showWorkSaveFeedback(
    context,
    feedback,
    session: post == null ? taste.comics.bookmarks : null,
    bottom: tabBarClearance(context) + 8,
    pickFolder: post == null ? null : (context) => pickBooruFolder(context, booru: taste.booru, post: post, discovery: discovery),
  );
}

/// `TasteWorkPresentation`: an image opens the viewer over the feed's images; a comic
/// opens as its thumbnail setting says.
Future<void> openRecommendation(
  BuildContext context,
  TasteContext taste,
  TasteRecommendation item, {
  TasteFeedState? feed,
  DiscoveryContext? discovery,
  ValueChanged<BooruPost>? willClose,
}) async {
  final post = item.post;
  final session = feed?.discoverySession ?? item.item.key;
  if (post != null) {
    final booru = taste.booru;
    final posts = feed == null ? [post].where(booru.store.isVisible).toList() : _feedPosts(feed, booru);
    await BooruPostView.open(
      context,
      booru: booru,
      post: post,
      posts: posts.isEmpty ? [post] : posts,
      discovery: discovery ?? DiscoveryContext.recommended(item.reason.name, session: session),
      loadMore: feed == null
          ? null
          : () async {
              await feed.loadMore(TasteMode.booru);
              return BooruViewerBatch(
                posts: _feedPosts(feed, booru),
                hasMore: feed.results.cursor.hasMore && feed.results.failures.isEmpty,
                failure: feed.results.failures.isEmpty ? null : L10n.text('Unable to Load'),
              );
            },
      willClose: willClose,
    );
    return;
  }
  taste.comics.openThumbnail(context, item.item.id);
}

List<BooruPost> _feedPosts(TasteFeedState feed, BooruContext booru) => [
  for (final item in feed.visibleItems())
    if (item.post case final post? when booru.store.isVisible(post)) post,
];
