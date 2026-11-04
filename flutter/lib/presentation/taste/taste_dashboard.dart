import 'dart:async';
import 'dart:convert';

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/content/manga_urls.dart';
import '../../core/support/l10n.dart';
import '../../core/taste/recommendation_service.dart';
import '../../core/taste/taste_feed_state.dart';
import '../../core/taste/taste_learning.dart';
import '../../core/taste/taste_models.dart';
import '../../core/taste/taste_recap.dart';
import '../booru/booru_common.dart';
import '../design/app_sheet.dart';
import '../design/grouped_form.dart';
import '../design/ios_controls.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import '../library/library_routes.dart' show showTransientMessage;
import '../navigation/app_header.dart';
import '../navigation/app_state.dart';
import '../navigation/root_tab_view.dart';
import '../works/artwork_grid.dart';
import 'recap/recap_home_view.dart';
import 'taste_context.dart';
import 'taste_presentation.dart';
import 'taste_reports_view.dart' show TasteTagListPage;
import 'taste_settings_view.dart';

/// How far the feed reaches, then today's threads with the tuner at their head.
/// Sections breathe more than the works inside them, which stay close together.
abstract final class SmartSpacing {
  static const double section = 40;
  static const double heading = 16;
}

/// `TasteDashboard`: today's picks, the recap, the reach control, shelves of today's
/// threads and the endless For You grid, for the library being browsed.
class TasteDashboard extends StatefulWidget {
  const TasteDashboard({super.key, required this.taste, required this.mode, this.isRoot = false});
  final TasteContext taste;
  final TasteMode mode;
  final bool isRoot;

  @override
  State<TasteDashboard> createState() => _TasteDashboardState();
}

class _TasteDashboardState extends State<TasteDashboard> {
  final _scroll = ScrollController();
  Set<int> _bookmarks = {};
  StreamSubscription<int>? _libraryChanges;
  TasteFeedState? _listened;

  TasteContext get _taste => widget.taste;
  TasteMode get _mode => widget.mode;
  bool get _isActiveMode => _taste.state.mode == (_mode == TasteMode.booru ? AppMode.booru : AppMode.manga);
  bool get _visible => !widget.isRoot || _taste.state.tab == AppTab.insights;

  List<String> get _sources =>
      _mode == TasteMode.comics ? [MangaUrls.source] : [for (final server in _taste.booru.store.selectedServers) server.canonicalAddress];
  String get _source => _sources.firstOrNull ?? '';
  TasteFeedState get _feed => _mode == TasteMode.booru ? _taste.controller.feed(_mode, sources: _sources) : _taste.controller.feed(_mode);

  @override
  void initState() {
    super.initState();
    _taste.controller.addListener(_changed);
    _taste.booru.store.addListener(_sourcesChanged);
    _taste.state.addListener(_stateChanged);
    _scroll.addListener(_onScroll);
    if (_mode == TasteMode.comics) {
      _reloadBookmarks();
      _libraryChanges = _taste.controller.library.changes.listen((_) {
        if (mounted) setState(_reloadBookmarks);
      });
    }
    _attachFeed();
    _ensureLoaded();
  }

  @override
  void dispose() {
    _taste.controller.removeListener(_changed);
    _taste.booru.store.removeListener(_sourcesChanged);
    _taste.state.removeListener(_stateChanged);
    _listened?.removeListener(_changed);
    _libraryChanges?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _reloadBookmarks() => _bookmarks = _taste.controller.library.savedGalleryIDs().toSet();

  void _changed() {
    if (mounted) setState(() {});
  }

  /// A server selection is another feed.
  void _attachFeed() {
    final feed = _feed;
    if (identical(feed, _listened)) return;
    _listened?.removeListener(_changed);
    _listened = feed..addListener(_changed);
  }

  void _sourcesChanged() {
    _attachFeed();
    _ensureLoaded();
    _changed();
  }

  void _stateChanged() {
    if (_isActiveMode && _visible) {
      _ensureLoaded();
    } else {
      _feed.cancelLoading();
    }
  }

  void _ensureLoaded() {
    if (!_isActiveMode || !_visible || _sources.isEmpty) return;
    _feed.ensureLoaded(_mode);
  }

  void _refresh() => _feed.refresh(_mode);

  void _onScroll() {
    final feed = _feed;
    final position = _scroll.position;
    if (position.extentAfter < 600 &&
        feed.results.failures.isEmpty &&
        feed.results.cursor.hasMore &&
        !feed.loading &&
        !feed.loadingMore &&
        feed.snapshot != null) {
      feed.loadMore(_mode);
    }
  }

  void _setFocus(TasteFocus? focus) => _feed.setFocus(focus, _mode);

  void _moreLikeThis(TasteRecommendation item) {
    final names = [
      for (final factor in item.factors)
        if (factor.kind == RecommendationFactorKind.tag) factor.name,
    ];
    final fallback = (item.rankingTags ?? const <String>{}).toList()..sort();
    final chosen = <String>[];
    for (final name in [...names, ...fallback]) {
      if (!chosen.contains(name)) chosen.add(name);
      if (chosen.length == 2) break;
    }
    if (chosen.isEmpty) return;
    _setFocus(
      TasteFocus(
        seed: TasteTag(source: item.item.source, name: chosen.join(' '), general: 1),
        why: WhySimilar(chosen.first),
      ),
    );
  }

  RecommendationFeedback get _feedback => RecommendationFeedback(
    why: (item) => showAppSheet<void>(
      context,
      grabber: true,
      medium: true,
      builder: (context, controller) =>
          RecommendationWhyView(taste: _taste, item: item, mode: _mode, feed: _feed, moreLikeThis: () => _moreLikeThis(item), scrollController: controller),
    ),
    more: _moreLikeThis,
    dismiss: (item) => _feed.dismiss(item, _mode),
  );

  void _toggle(TasteRecommendation item) => toggleRecommendation(context, _taste, item, session: _feed.discoverySession);

  void _open(TasteRecommendation item) => openRecommendation(context, _taste, item, feed: _feed);

  bool _saved(TasteRecommendation item) => item.post == null ? _bookmarks.contains(item.item.id) : _taste.booru.store.favoriteIDs.contains(item.post!.id);

  ArtworkGridPreferences get _grid {
    if (_mode == TasteMode.booru) return _taste.booru.gridPreferences;
    final content = _taste.comics.content;
    return ArtworkGridPreferences(
      columns: content.mangaColumns,
      removesPadding: content.mangaRemovesGridPadding,
      showsTitles: content.showsMangaTitles,
      showsArtists: content.showsMangaArtists,
      showsCategories: content.showsMangaCategories,
    );
  }

  /// Only a personal ranking can pick. A chosen sort keeps its own order.
  List<TasteRecommendation> _picks(List<TasteRecommendation> items) {
    final feed = _feed;
    final control = _taste.controller.control;
    if (items.length < 6 ||
        feed.starter ||
        feed.focus != null ||
        !_sources.every((source) => control.preferences(source).sort == RecommendationSort.recommended)) {
      return const [];
    }
    final defaults = ContentPreferences.defaults;
    final key = 'taste.todayPicks.${_mode.name}';
    final saved = defaults.string(key);
    TodayPicksStored? stored;
    try {
      stored = saved == null ? null : TodayPicksStored.fromJson(jsonDecode(saved));
    } on FormatException {
      stored = null;
    }
    final chosen = TodayPicks.choose(items, stored: stored, today: TodayPicks.day(DateTime.now()));
    // Remember the day's picks once; later builds read them back unchanged. Preferences hold text.
    if (chosen.stored != stored) defaults.set(key, jsonEncode(chosen.stored.toJson()));
    return chosen.picks;
  }

  void _openSettings() => Navigator.of(context).push(
    CupertinoPageRoute<void>(
      builder: (_) => TasteSettingsView(taste: _taste, mode: _mode),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final feed = _feed;
    final enabled = _taste.controller.control.enabled;
    final items = feed.visibleItems();
    final picks = _picks(items);
    final picked = {for (final item in picks) item.id};
    final rest = [
      for (final item in items)
        if (!picked.contains(item.id)) item,
    ];
    final media = MediaQuery.of(context);
    final top = rootContentTop(context, pushed: true);
    if (feed.sortMessage case final message?) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || feed.sortMessage != message) return;
        feed.sortMessage = null;
        showTransientMessage(context, message, bottom: tabBarClearance(context) + 8);
      });
    }
    final geometry = ArtworkGridGeometry(width: media.size.width, columns: _grid.columns, removesPadding: _grid.removesPadding);
    Widget padded(Widget child, {double bottom = SmartSpacing.section}) => Padding(padding: EdgeInsets.fromLTRB(20, 0, 20, bottom), child: child);
    final slivers = <Widget>[
      SliverToBoxAdapter(child: SizedBox(height: top + 16)),
      if (_sources.isNotEmpty && enabled && picks.isNotEmpty)
        SliverToBoxAdapter(
          // The cards line up with the grid below; the heading keeps the page's 20 pt margin.
          child: Padding(
            padding: EdgeInsets.fromLTRB(geometry.margin, 0, geometry.margin, SmartSpacing.section),
            child: SmartPicksView(taste: _taste, items: picks, open: _open, toggle: _toggle, saved: _saved, feedback: _feedback, inset: 20 - geometry.margin),
          ),
        ),
      if (enabled && feed.focus == null)
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(geometry.margin, 0, geometry.margin, SmartSpacing.section),
            child: RecapEntryCard(taste: _taste, mode: _mode),
          ),
        ),
      if (_sources.isNotEmpty && enabled) ...[
        SliverToBoxAdapter(
          child: padded(SmartSteering(taste: _taste, feed: feed, refresh: _refresh, focus: _setFocus)),
        ),
        for (final shelf in feed.visibleShelves())
          if (shelf.items.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: SmartSpacing.section),
                child: SmartShelfView(taste: _taste, shelf: shelf, open: _open, toggle: _toggle, saved: _saved, feedback: _feedback),
              ),
            ),
      ],
      if (_sources.isEmpty)
        const SliverToBoxAdapter(child: BooruNoSelectionView())
      else if (!enabled)
        SliverToBoxAdapter(
          child: padded(
            _Message(
              text: L10n.text('Taste analysis is paused on your devices.'),
              icon: CupertinoIcons.pause_circle,
              action: L10n.text('Enable Taste Analysis'),
              perform: () => _taste.controller.change((control) => control.enabled = true),
            ),
          ),
        )
      else ...[
        if (feed.error case final failure?)
          SliverToBoxAdapter(
            child: padded(
              _Message(text: failure, icon: CupertinoIcons.wifi_exclamationmark, action: L10n.text('Try Again'), perform: _refresh),
              bottom: SmartSpacing.heading,
            ),
          ),
        if (feed.snapshot case final snapshot? when snapshot.tags.isEmpty)
          SliverToBoxAdapter(child: padded(_gettingStarted(context), bottom: SmartSpacing.heading)),
        if (rest.isNotEmpty || items.isNotEmpty || _sources.length > 1)
          SliverToBoxAdapter(child: padded(_feedHeader(context), bottom: SmartSpacing.heading - 8)),
        if (feed.snapshot != null && rest.isNotEmpty)
          ArtworkGridSliver(
            itemCount: rest.length,
            topMarginScale: 0.5,
            preferences: _grid,
            itemBuilder: (context, index, style) {
              final item = rest[index];
              return TasteRecommendationCard(
                key: ValueKey(item.id),
                taste: _taste,
                item: item,
                style: style,
                open: () => _open(item),
                toggle: () => _toggle(item),
                isBookmarked: _bookmarks.contains(item.item.id),
                feedback: _feedback,
              );
            },
          ),
        SliverToBoxAdapter(child: padded(_footer(context, items), bottom: 0)),
      ],
      SliverToBoxAdapter(child: SizedBox(height: SmartSpacing.section + (widget.isRoot ? tabBarClearance(context) : media.padding.bottom))),
    ];
    return ColoredBox(
      color: FormColors.listBackground.resolveFrom(context),
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomScrollView(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
              slivers: [
                CupertinoSliverRefreshControl(
                  onRefresh: () async {
                    _refresh();
                    await feed.waitForRefresh();
                  },
                ),
                ...slivers,
              ],
            ),
          ),
          if (feed.lastDismissed case final item?)
            Positioned(
              left: 0,
              right: 0,
              bottom: widget.isRoot ? tabBarClearance(context) - 74 : 0,
              child: SmartUndoBar(key: ValueKey(item.id), undo: () => feed.undoDismiss(_mode), close: feed.clearUndo),
            ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: RootHeader(
              title: L10n.text(widget.isRoot ? 'Smart' : 'Taste Analysis'),
              showsBanner: false,
              state: _taste.state,
              onBack: widget.isRoot ? null : () => Navigator.of(context).pop(),
              trailing: ToolbarGroup(
                children: [
                  if (_mode == TasteMode.booru) BooruServerMenuButton(store: _taste.booru.store, grouped: true),
                  ToolbarIconButton(label: L10n.text('Settings'), icon: CupertinoIcons.slider_horizontal_3, onPressed: _openSettings),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String get _feedDescription {
    final feed = _feed;
    if (feed.focus case final focus?) return focus.why.sentence;
    return feed.starter ? const WhyPopular().sentence : L10n.text("Chosen from what you've been saving and viewing.");
  }

  /// One title with the feed's controls beside it. Several servers keep a row each.
  Widget _feedHeader(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      L10n.text(_feed.starter ? 'Popular now' : 'For you'),
                      maxLines: 1,
                      style: TegnalType.style(20, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
                    ),
                  ),
                  Text(_feedDescription, maxLines: 2, style: TegnalType.style(13, color: secondary)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (_sources.length == 1) RecommendationFilters(taste: _taste, mode: _mode, source: _source, onChange: _refresh, compact: true),
          ],
        ),
        if (_sources.length > 1 && _mode == TasteMode.booru)
          for (final server in _taste.booru.store.selectedServers) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(server.displayName, maxLines: 1, style: TegnalType.style(15, color: secondary)),
                ),
                const SizedBox(width: 8),
                RecommendationFilters(taste: _taste, mode: _mode, source: server.canonicalAddress, onChange: _refresh, compact: true),
              ],
            ),
          ],
      ],
    );
  }

  Widget _gettingStarted(BuildContext context) => TasteSurface(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          L10n.text('Start with something you love'),
          style: TegnalType.style(20, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
        ),
        const SizedBox(height: 14),
        Text(L10n.text('Every save teaches your feed.'), style: TegnalType.style(15, color: TegnalColors.secondaryLabel.resolveFrom(context))),
        const SizedBox(height: 14),
        TasteProminentButton(title: L10n.text('Explore works'), onPressed: _taste.explore),
      ],
    ),
  );

  Widget _footer(BuildContext context, List<TasteRecommendation> items) {
    final feed = _feed;
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final children = <Widget>[];
    if (items.isEmpty && feed.loading) {
      children.add(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 40),
          child: Center(child: CupertinoActivityIndicator()),
        ),
      );
    } else if (items.isEmpty && feed.snapshot != null && feed.results.failures.isEmpty && !feed.results.cursor.hasMore) {
      children.add(
        _Message(
          text: L10n.text("You're all caught up. Explore more works or refresh for new recommendations."),
          icon: CupertinoIcons.checkmark_circle,
          action: L10n.text('Explore works'),
          perform: _taste.explore,
        ),
      );
    } else if (feed.snapshot == null && feed.loading) {
      children.add(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 40),
          child: Center(child: CupertinoActivityIndicator()),
        ),
      );
    }
    if (feed.loading && items.isNotEmpty) children.add(const Center(child: CupertinoActivityIndicator()));
    if (feed.results.cursor.hasMore && !feed.loading && feed.snapshot != null) {
      if (feed.results.failures.isEmpty) {
        children.add(
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: feed.loadingMore ? null : () => feed.loadMore(_mode),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: feed.loadingMore
                    ? const CupertinoActivityIndicator()
                    : Text(L10n.text('Continue browsing'), style: TegnalType.style(17, color: TastePresentation.accent(context))),
              ),
            ),
          ),
        );
      }
    } else if (!feed.loading && items.isNotEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: Text(L10n.text("You've reached the end of these recommendations."), style: TegnalType.style(13, color: secondary)),
          ),
        ),
      );
    }
    if (feed.results.failures.isNotEmpty) {
      children.add(
        _Message(
          text: L10n.text('Some sources could not be loaded: %@', [feed.results.failures.join(', ')]),
          icon: CupertinoIcons.wifi_exclamationmark,
          action: L10n.text('Try Again'),
          perform: () => feed.loadMore(_mode),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

/// A notice on a taste surface with one bordered action.
class _Message extends StatelessWidget {
  const _Message({required this.text, required this.icon, required this.action, required this.perform});
  final String text;
  final IconData icon;
  final String action;
  final VoidCallback perform;

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final accent = TastePresentation.accent(context);
    return TasteSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: secondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(text, style: TegnalType.style(15, color: secondary)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          GestureDetector(
            onTap: perform,
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: ShapeDecoration(color: accent.withValues(alpha: 0.15), shape: const StadiumBorder()),
              child: Center(
                widthFactor: 1,
                child: Text(
                  action,
                  style: TegnalType.style(15, weight: FontWeight.w600, color: accent),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `.borderedProminent` in the taste accent, full width.
class TasteProminentButton extends StatelessWidget {
  const TasteProminentButton({super.key, required this.title, required this.onPressed, this.icon});
  final String title;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onPressed != null,
    child: GestureDetector(
      onTap: onPressed,
      child: Opacity(
        opacity: onPressed == null ? 0.4 : 1,
        child: Container(
          height: 46,
          decoration: ShapeDecoration(color: TastePresentation.accent(context), shape: const StadiumBorder()),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[Icon(icon, size: 18, color: const Color(0xFFFFFFFF)), const SizedBox(width: 6)],
              Text(
                title,
                style: TegnalType.style(17, weight: FontWeight.w600, color: const Color(0xFFFFFFFF)),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// `SmartArtwork`: a recommendation's picture; large cards upgrade to the sample image.
class SmartArtwork extends StatelessWidget {
  const SmartArtwork({super.key, required this.taste, required this.item});
  final TasteContext taste;
  final TasteRecommendation item;

  @override
  Widget build(BuildContext context) => item.post != null || item.gallery != null
      ? TasteArtwork(taste: taste, post: item.post, gallery: item.gallery)
      : ColoredBox(color: TegnalColors.secondaryLabel.resolveFrom(context).withValues(alpha: 0.12));
}

/// A card that shrinks a little while pressed (`RecapPressStyle`).
class TastePressable extends StatefulWidget {
  const TastePressable({super.key, required this.child, required this.onTap, this.onLongPress});
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  State<TastePressable> createState() => _TastePressableState();
}

class _TastePressableState extends State<TastePressable> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapDown: (_) => setState(() => _pressed = true),
    onTapCancel: () => setState(() => _pressed = false),
    onTapUp: (_) => setState(() => _pressed = false),
    onTap: widget.onTap,
    onLongPress: widget.onLongPress == null
        ? null
        : () {
            setState(() => _pressed = false);
            widget.onLongPress!();
          },
    child: AnimatedScale(scale: _pressed ? 0.975 : 1, duration: const Duration(milliseconds: 220), curve: Curves.easeOut, child: widget.child),
  );
}

Widget _bookmarkMark(BuildContext context) => Padding(
  padding: const EdgeInsets.all(6),
  child: Icon(CupertinoIcons.bookmark_fill, size: 13, color: SystemColors.yellow.resolveFrom(context)),
);

/// `SmartPicksView`: three equal cards, so no single choice has to carry the page.
class SmartPicksView extends StatelessWidget {
  const SmartPicksView({
    super.key,
    required this.taste,
    required this.items,
    required this.open,
    required this.toggle,
    required this.saved,
    required this.feedback,
    this.inset = 0,
  });
  final TasteContext taste;
  final List<TasteRecommendation> items;
  final ValueChanged<TasteRecommendation> open;
  final ValueChanged<TasteRecommendation> toggle;
  final bool Function(TasteRecommendation item) saved;
  final RecommendationFeedback feedback;

  /// The heading's extra margin, since the cards line up with the grid below.
  final double inset;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: EdgeInsets.symmetric(horizontal: inset.clamp(0, double.infinity)),
        child: _ShelfHeading(
          title: L10n.text("Today's picks"),
          subtitle: L10n.text('One each from your usual taste, recent interests and something new.'),
          wraps: true,
        ),
      ),
      const SizedBox(height: SmartSpacing.heading),
      Padding(
        padding: EdgeInsets.zero,
        child: Row(
          children: [
            for (final (index, item) in items.indexed) ...[
              if (index > 0) const SizedBox(width: 8),
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 190),
                  child: Stack(
                    children: [
                      TastePressable(
                        onTap: () => open(item),
                        onLongPress: () => toggle(item),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: AspectRatio(
                            aspectRatio: 0.74,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                SmartArtwork(taste: taste, item: item),
                                if (saved(item)) Align(alignment: Alignment.topLeft, child: _bookmarkMark(context)),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        right: 0,
                        top: 0,
                        child: RecommendationMenu(item: item, feedback: feedback, compact: true),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ],
  );
}

class _ShelfHeading extends StatelessWidget {
  const _ShelfHeading({required this.title, required this.subtitle, this.wraps = false});
  final String title;
  final String subtitle;
  final bool wraps;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Semantics(
        header: true,
        child: Text(
          title,
          maxLines: 1,
          style: TegnalType.style(20, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
        ),
      ),
      Text(
        subtitle,
        maxLines: wraps ? null : 2,
        style: TegnalType.style(13, color: TegnalColors.secondaryLabel.resolveFrom(context)),
      ),
    ],
  );
}

/// `SmartShelfView`: a named thread of today's feed in a horizontal row.
class SmartShelfView extends StatelessWidget {
  const SmartShelfView({
    super.key,
    required this.taste,
    required this.shelf,
    required this.open,
    required this.toggle,
    required this.saved,
    required this.feedback,
  });
  final TasteContext taste;
  final TasteShelf shelf;
  final ValueChanged<TasteRecommendation> open;
  final ValueChanged<TasteRecommendation> toggle;
  final bool Function(TasteRecommendation item) saved;
  final RecommendationFeedback feedback;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: _ShelfHeading(title: shelf.plan.title, subtitle: shelf.plan.why.sentence),
      ),
      const SizedBox(height: SmartSpacing.heading),
      SizedBox(
        height: 176,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          itemCount: shelf.items.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final item = shelf.items[index];
            return SizedBox(
              width: 132,
              child: Stack(
                children: [
                  TastePressable(
                    onTap: () => open(item),
                    onLongPress: () => toggle(item),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          SmartArtwork(taste: taste, item: item),
                          if (item.post == null && saved(item)) Align(alignment: Alignment.topLeft, child: _bookmarkMark(context)),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    top: 0,
                    child: RecommendationMenu(item: item, feedback: feedback, compact: true),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ],
  );
}

/// `SmartSteering`: how far the feed reaches, and the focus it is following.
class SmartSteering extends StatelessWidget {
  const SmartSteering({super.key, required this.taste, required this.feed, required this.refresh, required this.focus});
  final TasteContext taste;
  final TasteFeedState feed;
  final VoidCallback refresh;
  final ValueChanged<TasteFocus?> focus;

  @override
  Widget build(BuildContext context) {
    final active = feed.focus;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TegnalSegmented<int>(
          options: [(0, L10n.text('Familiar')), (1, L10n.text('Balanced')), (2, L10n.text('Adventurous'))],
          selected: taste.controller.control.discoveryLevel ?? 1,
          onSelected: (value) {
            taste.controller.change((control) => control.discoveryLevel = value);
            refresh();
          },
        ),
        if (active != null) ...[
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => focus(null),
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: ShapeDecoration(color: TastePresentation.accent(context), shape: const StadiumBorder()),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(CupertinoIcons.xmark, size: 14, color: Color(0xFFFFFFFF)),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      active.why.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TegnalType.style(15, weight: FontWeight.w600, color: const Color(0xFFFFFFFF)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// `SmartUndoBar`: Hidden, with Undo, for six seconds.
class SmartUndoBar extends StatefulWidget {
  const SmartUndoBar({super.key, required this.undo, required this.close});
  final VoidCallback undo;
  final VoidCallback close;

  @override
  State<SmartUndoBar> createState() => _SmartUndoBarState();
}

class _SmartUndoBarState extends State<SmartUndoBar> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 6), widget.close);
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 74),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: ShapeDecoration(
        color: TegnalColors.elevatedGlassFill.resolveFrom(context),
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(16)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(L10n.text('Hidden'), maxLines: 1, style: TegnalType.style(15, color: TegnalColors.label.resolveFrom(context))),
          ),
          GestureDetector(
            onTap: widget.undo,
            child: Text(
              L10n.text('Undo'),
              style: TegnalType.style(15, weight: FontWeight.w700, color: TastePresentation.accent(context)),
            ),
          ),
        ],
      ),
    ),
  );
}

/// `RecommendationWhyView`: every reason behind one recommendation, with control over each.
class RecommendationWhyView extends StatelessWidget {
  const RecommendationWhyView({
    super.key,
    required this.taste,
    required this.item,
    required this.mode,
    required this.feed,
    required this.moreLikeThis,
    this.scrollController,
  });
  final TasteContext taste;
  final TasteRecommendation item;
  final TasteMode mode;
  final TasteFeedState feed;
  final VoidCallback moreLikeThis;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final accent = TastePresentation.accent(context);
    final red = SystemColors.red.resolveFrom(context);
    final why = item.why;
    return ListenableBuilder(
      listenable: taste.controller,
      builder: (context, _) => ScrollEdgeSheet(
        background: FormColors.background.resolveFrom(context),
        bar: SheetNavigationBar(
          title: L10n.text('Why this recommendation?'),
          trailing: GlassTextButton(label: L10n.text('Done'), prominent: true, onPressed: () => Navigator.of(context).pop()),
        ),
        child: ListView(
          controller: scrollController,
          padding: EdgeInsets.only(top: 69 + 35, bottom: 32 + MediaQuery.paddingOf(context).bottom),
          children: [
            FormSection(
              children: [
                FormRow(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: SizedBox(
                            width: 84,
                            height: 112,
                            child: SmartArtwork(taste: taste, item: item),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (why != null) ...[
                                Row(
                                  children: [
                                    Icon(TastePresentation.icon(why.icon), size: 17, color: accent),
                                    const SizedBox(width: 6),
                                    Flexible(
                                      child: Text(
                                        why.label,
                                        style: TegnalType.style(17, weight: FontWeight.w600, color: accent),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                              ],
                              Text(
                                why?.sentence ?? L10n.text('Matches your saved works.'),
                                style: TegnalType.style(15, color: TegnalColors.label.resolveFrom(context)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),
            FormSection(
              children: [
                FormRow(
                  onTap: () {
                    Navigator.of(context).pop();
                    moreLikeThis();
                  },
                  child: Row(
                    children: [
                      Icon(CupertinoIcons.square_on_square, size: 20, color: accent),
                      const SizedBox(width: 12),
                      Text(L10n.text('More like this'), style: TegnalType.style(17, color: accent)),
                    ],
                  ),
                ),
                FormRow(
                  onTap: () {
                    feed.dismiss(item, mode);
                    Navigator.of(context).pop();
                  },
                  child: Row(
                    children: [
                      Icon(CupertinoIcons.hand_thumbsdown, size: 20, color: red),
                      const SizedBox(width: 12),
                      Text(L10n.text('Not interested'), style: TegnalType.style(17, color: red)),
                    ],
                  ),
                ),
              ],
            ),
            if (item.factors.isNotEmpty) ...[
              const SizedBox(height: 28),
              FormSection(
                header: Text(L10n.text('What counted')),
                children: [
                  for (final factor in item.factors)
                    FormRow(
                      child: _StrengthRow(taste: taste, name: factor.name, boostKey: factor.key, strength: factor.strength.clamp(0, 1).toDouble()),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A tag's name over a strength bar, with the more and less controls.
class _StrengthRow extends StatelessWidget {
  const _StrengthRow({required this.taste, required this.name, required this.boostKey, required this.strength, this.rising = false});
  final TasteContext taste;
  final String name;
  final String boostKey;
  final double strength;
  final bool rising;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      RecapText.tag(name),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TegnalType.style(15, weight: FontWeight.w500, color: TegnalColors.label.resolveFrom(context)),
                    ),
                  ),
                  if (rising) ...[
                    const SizedBox(width: 4),
                    Semantics(
                      label: L10n.text('Rising lately'),
                      child: Icon(CupertinoIcons.flame_fill, size: 11, color: SystemColors.orange.resolveFrom(context)),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              _StrengthBar(value: strength),
            ],
          ),
        ),
        const SizedBox(width: 12),
        SmartBoostControl(taste: taste, boostKey: boostKey, name: name),
      ],
    ),
  );
}

class _StrengthBar extends StatelessWidget {
  const _StrengthBar({required this.value});
  final double value;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Container(
      height: 4,
      decoration: ShapeDecoration(color: TegnalColors.secondaryLabel.resolveFrom(context).withValues(alpha: 0.15), shape: const StadiumBorder()),
      alignment: Alignment.centerLeft,
      child: Container(
        width: (constraints.maxWidth * value).clamp(4, constraints.maxWidth),
        decoration: ShapeDecoration(color: TastePresentation.accent(context), shape: const StadiumBorder()),
      ),
    ),
  );
}

/// `SmartBoostControl`: show less or more of one tag or artist.
class SmartBoostControl extends StatelessWidget {
  const SmartBoostControl({super.key, required this.taste, required this.boostKey, required this.name});
  final TasteContext taste;
  final String boostKey;
  final String name;

  @override
  Widget build(BuildContext context) {
    final value = taste.controller.control.boost(boostKey);
    Widget button(int target, IconData icon, String label) {
      final selected = value == target;
      return Semantics(
        button: true,
        selected: selected,
        label: label,
        child: GestureDetector(
          onTap: () => taste.controller.change((control) => control.setBoost(selected ? 0 : target, boostKey)),
          child: Container(
            width: 36,
            height: 36,
            decoration: ShapeDecoration(
              color: selected ? TastePresentation.accent(context) : TegnalColors.secondaryLabel.resolveFrom(context).withValues(alpha: 0.12),
              shape: const CircleBorder(),
            ),
            child: Icon(icon, size: 14, color: selected ? const Color(0xFFFFFFFF) : TegnalColors.label.resolveFrom(context)),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        button(-1, CupertinoIcons.minus, L10n.text('Show less of %@', [RecapText.tag(name)])),
        const SizedBox(width: 2),
        button(1, CupertinoIcons.plus, L10n.text('Show more of %@', [RecapText.tag(name)])),
      ],
    );
  }
}

/// `TasteTunerView`: everything the feed believes, and the means to correct it.
class TasteTunerView extends StatefulWidget {
  const TasteTunerView({super.key, required this.taste, required this.mode, required this.feed, required this.source});
  final TasteContext taste;
  final TasteMode mode;
  final TasteFeedState feed;
  final String source;

  @override
  State<TasteTunerView> createState() => _TasteTunerViewState();
}

class _TasteTunerViewState extends State<TasteTunerView> {
  TasteLearning? _learning;

  TasteContext get _taste => widget.taste;

  @override
  void initState() {
    super.initState();
    _learning = widget.feed.learning;
    if (_learning == null) {
      try {
        _learning = _taste.controller.learning(widget.mode);
      } on Object {
        _learning = null;
      }
    }
    _taste.controller.addListener(_changed);
  }

  @override
  void dispose() {
    _taste.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final control = _taste.controller.control;
    final strongest = [
      for (final tag in _learning?.ranked() ?? const <TasteLearnedTag>[])
        if (control.allows(tag.name, source: tag.source, mode: widget.mode)) tag,
    ].take(24).toList();
    final peak = strongest.isEmpty ? 1.0 : (strongest.first.weight <= 0.001 ? 0.001 : strongest.first.weight);
    final steered = (control.tasteBoosts?.keys.toList() ?? <String>[])..sort();
    final people = (_learning?.people ?? const <TasteLearnedPerson>[]).take(8).toList();
    final row = FormColors.listRow.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final accent = TastePresentation.accent(context);
    return TasteListPage(
      title: L10n.text('Tune your taste'),
      headerFirst: true,
      trailing: GlassTextButton(
        label: L10n.text('Apply'),
        prominent: true,
        elevated: false,
        onPressed: () {
          widget.feed.refresh(widget.mode);
          Navigator.of(context).pop();
        },
      ),
      children: [
        if (steered.isNotEmpty) ...[
          FormSection(
            rowColor: row,
            header: Text(L10n.text('Your adjustments')),
            children: [
              for (final key in steered)
                FormRow(
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          RecapText.tag(key.split('\n').last),
                          maxLines: 1,
                          style: TegnalType.style(15, weight: FontWeight.w500, color: TegnalColors.label.resolveFrom(context)),
                        ),
                      ),
                      SmartBoostControl(taste: _taste, boostKey: key, name: key.split('\n').last),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 28),
        ],
        if (people.isNotEmpty) ...[
          FormSection(
            rowColor: row,
            header: Text(L10n.text('Artists you return to')),
            children: [
              for (final person in people)
                FormRow(
                  minHeight: 66,
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              RecapText.capitalized(RecapText.tag(person.name)),
                              maxLines: 1,
                              style: TegnalType.style(15, weight: FontWeight.w500, color: TegnalColors.label.resolveFrom(context)),
                            ),
                            const SizedBox(height: 2),
                            Text(L10n.text('%@ saved works', ['${person.saves}']), style: TegnalType.style(12, color: secondary)),
                          ],
                        ),
                      ),
                      SmartBoostControl(taste: _taste, boostKey: person.key, name: person.name),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 28),
        ],
        FormSection(
          rowColor: row,
          header: Text(L10n.text('What your feed has learned')),
          children: [
            if (strongest.isEmpty)
              FormRow(
                child: Text(L10n.text('Save a few works and your taste will appear here.'), style: TegnalType.style(17, color: secondary)),
              ),
            for (final tag in strongest)
              FormRow(
                minHeight: 70,
                child: _StrengthRow(
                  taste: _taste,
                  name: tag.name,
                  boostKey: tag.id,
                  strength: (tag.weight / peak).clamp(0, 1).toDouble(),
                  rising: tag.recent >= 2,
                ),
              ),
          ],
        ),
        const SizedBox(height: 35),
        FormSection(
          rowColor: row,
          footer: Text(L10n.text('Recommendation searches send the selected tags to your connected websites. Your taste profile is not sent.')),
          children: [
            _LinkRow(
              title: L10n.text('Recommendation evidence'),
              icon: CupertinoIcons.list_bullet_below_rectangle,
              color: accent,
              onTap: () => Navigator.of(context).push(
                CupertinoPageRoute<void>(
                  builder: (_) => TasteTagListPage(
                    taste: _taste,
                    mode: widget.mode,
                    tags: widget.feed.snapshot?.tags ?? _taste.controller.snapshot(widget.mode, period: TastePeriod.recommendations, offset: 0).tags,
                  ),
                ),
              ),
            ),
            _LinkRow(
              title: L10n.text('Recommendation filters'),
              icon: CupertinoIcons.line_horizontal_3_decrease,
              color: accent,
              onTap: () => Navigator.of(context).push(
                CupertinoPageRoute<void>(
                  builder: (_) => RecommendationSettingsView(taste: _taste, mode: widget.mode, initialSource: widget.source),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.title, required this.icon, required this.color, required this.onTap});
  final String title;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => FormRow(
    onTap: onTap,
    separatorInset: 56,
    child: Row(
      children: [
        SizedBox(width: 24, child: Icon(icon, size: 22, color: color)),
        const SizedBox(width: 16),
        Expanded(child: Text(title)),
        Icon(CupertinoIcons.chevron_right, size: 15, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
      ],
    ),
  );
}
