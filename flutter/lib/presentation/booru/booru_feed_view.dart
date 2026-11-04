import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/booru/booru_client.dart';
import '../../core/booru/booru_models.dart';
import '../../core/booru/booru_support.dart';
import '../../core/challenge/challenge_engine.dart';
import '../../core/support/l10n.dart';
import '../../core/support/swift_json.dart' show uuidString;
import '../../core/taste/taste_models.dart';
import '../content/explore_view.dart' show ContentUnavailable, ScrollSearchVisibility;
import '../content/work_save_feedback.dart';
import '../design/app_sheet.dart';
import '../design/symbols.dart';
import '../design/tegnal_theme.dart';
import '../library/library_routes.dart' show showTransientMessage;
import '../navigation/app_header.dart';
import '../navigation/app_state.dart';
import '../navigation/root_tab_view.dart';
import '../works/search_controls.dart';
import 'booru_common.dart';
import 'booru_post_view.dart';
import 'booru_settings_views.dart';

/// `BooruFeedView`: the selected servers' posts merged into one grid, with tag search,
/// suggestions from every server, a sort menu and each server's failure on its own card.
class BooruFeedView extends StatefulWidget {
  const BooruFeedView({
    super.key,
    required this.booru,
    required this.servers,
    this.initialQuery = '',
    this.pool,
    this.isActive = true,
    this.onBack,
    this.showsServerMenu = false,
    this.source,
    this.challenge,
    this.header,
    this.bar,
  });

  final BooruContext booru;
  final List<BooruServer> servers;
  final String initialQuery;
  final BooruPool? pool;
  final bool isActive;
  final VoidCallback? onBack;
  final bool showsServerMenu;

  /// Where posts come from, when not the image servers themselves (a challenge's saved folder).
  final BooruProviding? source;

  /// The challenge a reference feed belongs to: its searches are not history or taste
  /// evidence, and the chosen image becomes the challenge's reference.
  final ChallengeSessionController? challenge;

  /// Content above the search field that scrolls with the feed; the field pins under the
  /// bar once it reaches it.
  final Widget? header;

  /// Replaces the root header, for a feed shown inside another screen.
  final Widget? bar;

  /// Pushes a feed for a tag or pool inside the current tab.
  static Future<void> push(BuildContext context, {required BooruContext booru, required BooruServer server, String query = '', BooruPool? pool}) =>
      Navigator.of(context).push(
        CupertinoPageRoute<void>(
          builder: (context) => BooruFeedView(booru: booru, servers: [server], initialQuery: query, pool: pool, onBack: () => Navigator.of(context).pop()),
        ),
      );

  @override
  State<BooruFeedView> createState() => _BooruFeedViewState();
}

class _BooruFeedViewState extends State<BooruFeedView> {
  late final BooruFeedLoader _loader = BooruFeedLoader();
  late final _search = TextEditingController(text: widget.initialQuery);
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();
  final _visibility = ScrollSearchVisibility();
  final _keys = <String, GlobalKey>{};
  double _lastOffset = 0;
  bool _searchBarVisible = true;
  late String _query = widget.initialQuery;
  BooruSort _sort = BooruSort.latest;
  BooruSort _acceptedSort = BooruSort.latest;
  int _retry = 0;
  String? _loadedRequest;
  String _session = uuidString();
  List<BooruTag> _suggestions = [];
  bool _suggesting = false;
  String? _suggestionError;
  Timer? _suggestionTimer;
  int _suggestionGeneration = 0;
  final _expandedQueries = <String>{};

  BooruContext get _booru => widget.booru;
  List<BooruServer> get _servers => widget.servers;
  BooruProviding get _source => widget.source ?? _booru.source;
  final _searchSlot = GlobalKey();
  bool _searchSlotPinned = false;

  DiscoveryContext get _discovery {
    final challenge = widget.challenge;
    if (challenge != null) return DiscoveryContext(origin: DiscoveryOrigin.external, session: 'challenge:${challenge.session.definition.id}');
    return DiscoveryContext(origin: _query.isEmpty ? DiscoveryOrigin.feed : DiscoveryOrigin.search, query: _query, session: _session);
  }

  String get _effectiveQuery => _booru.query(_query);

  String get _requestKey =>
      '$_effectiveQuery|${_sort.rawValue}|$_retry|${_servers.map((server) => server.id + server.canonicalAddress + server.engine.rawValue).join(',')}';

  List<BooruSort> get _sortOptions => BooruSort.options(_servers, local: widget.challenge?.session.sourceKind == 'folder');

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _searchFocus.addListener(() {
      if (_searchFocus.hasFocus) _searchBarVisible = true;
      _textChanged();
    });
    _search.addListener(_textChanged);
    _loader.addListener(_changed);
    _booru.store.addListener(_storeChanged);
    booruClientValidated.addListener(_validated);
    _updateBlacklists();
    if (widget.isActive) _loadIfNeeded();
  }

  @override
  void didUpdateWidget(BooruFeedView old) {
    super.didUpdateWidget(old);
    final serversChanged = old.servers.map((server) => server.id).join(',') != _servers.map((server) => server.id).join(',');
    if (serversChanged) {
      _updateBlacklists();
      if (!_sortOptions.contains(_sort)) _sort = _acceptedSort = BooruSort.latest;
    }
    if (widget.isActive && (serversChanged || !old.isActive)) _loadIfNeeded();
  }

  @override
  void dispose() {
    _booru.store.removeListener(_storeChanged);
    booruClientValidated.removeListener(_validated);
    _loader.removeListener(_changed);
    _loader.cancel();
    _loader.dispose();
    _suggestionTimer?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// A server that passed its client check is asked again.
  void _validated() {
    final id = booruClientValidated.value?.$1;
    if (id == null || !_servers.any((server) => server.id == id)) return;
    setState(() => _retry++);
    _loadIfNeeded();
  }

  void _storeChanged() {
    _updateBlacklists();
    _changed();
  }

  void _updateBlacklists() {
    _loader.setBlacklists({for (final server in _servers) server.id: _booru.store.blacklist(server.id)});
    _loader.setExcludedPostIDs(_booru.store.confirmedGoldRestrictedIDs);
  }

  Future<void> _loadIfNeeded() async {
    final key = _requestKey;
    if (_loadedRequest == key) return;
    if (_loader.didLoad && _loader.contentID == key) {
      _loadedRequest = key;
      return;
    }
    await _load(reset: true);
    if (mounted && !_loader.unsupportedSort && key == _requestKey) _loadedRequest = key;
  }

  Future<void> _load({required bool reset}) async {
    if (!widget.isActive) return;
    final requested = _sort;
    await _loader.load(
      servers: _servers,
      source: _source,
      query: _effectiveQuery,
      poolID: widget.pool?.id,
      sort: requested,
      reset: reset,
      contentID: _requestKey,
      onGoldRestricted: _booru.store.recordGoldRestrictions,
    );
    if (!mounted || _sort != requested) return;
    if (_loader.unsupportedSort) {
      setState(() {
        _sort = _acceptedSort;
        _loadedRequest = _requestKey;
      });
      showTransientMessage(context, L10n.text('This server does not support that sort. Your previous sort has been restored.'));
    } else if (_loader.errors.isEmpty) {
      _acceptedSort = requested;
    }
  }

  void _onScroll() {
    if (widget.header != null) {
      final slot = _searchSlot.currentContext?.findRenderObject() as RenderBox?;
      final barBottom = rootContentTop(context, pushed: widget.onBack != null);
      final pinned = slot != null && slot.attached && slot.localToGlobal(Offset.zero).dy <= barBottom;
      if (pinned != _searchSlotPinned) setState(() => _searchSlotPinned = pinned);
    }
    final offset = _scroll.offset;
    final visible = _visibility.update(_lastOffset, offset, focused: _searchFocus.hasFocus);
    _lastOffset = offset;
    if (visible != null && visible != _searchBarVisible) setState(() => _searchBarVisible = visible);
    // The Load More footer reaching the screen asks for the next page, as the native footer does.
    if (_scroll.position.extentAfter < 200 && _loader.hasMore && !_loader.loading && _loader.visiblePosts.isNotEmpty) _load(reset: false);
  }

  void _prefetch() {
    if (_loader.hasMore && !_loader.loading) scheduleMicrotask(() => _load(reset: false));
  }

  /// Suggests tags for the word being typed, 300 ms after typing stops.
  void _textChanged() {
    _suggestionTimer?.cancel();
    final generation = ++_suggestionGeneration;
    final completion = _searchFocus.hasFocus ? BooruCompletion.parse(_search.text) : null;
    setState(() {
      _suggestions = [];
      _suggestionError = null;
      _suggesting = completion != null;
    });
    if (completion == null) return;
    _suggestionTimer = Timer(const Duration(milliseconds: 300), () async {
      final result = await BooruTagSuggestionSearch.load(servers: _servers, source: _source, token: completion.token);
      if (!mounted || generation != _suggestionGeneration || !_searchFocus.hasFocus) return;
      setState(() {
        _suggestions = result.tags;
        _suggestionError = result.error;
        _suggesting = false;
      });
    });
  }

  void _submit([String? value]) {
    _searchFocus.unfocus();
    final text = (value ?? _search.text).trim();
    _session = uuidString();
    if (_booru.remembersHistory && widget.challenge == null) {
      for (final server in _servers) {
        _booru.store.recordSearch(text, serverID: server.id);
      }
      _booru.store.recordTasteSearch(DiscoveryContext(origin: DiscoveryOrigin.search, query: text, session: _session), _servers);
    }
    setState(() {
      _suggestions = [];
      if (_query == text) {
        _retry++;
      } else {
        _query = text;
      }
    });
    _loadIfNeeded();
  }

  Future<void> _refresh() async {
    final text = _search.text.trim();
    if (_query != text) {
      setState(() => _query = text);
      await _loadIfNeeded();
    } else {
      await _load(reset: true);
    }
  }

  List<String> get _history {
    final seen = <String>{};
    return [
      for (final server in _servers)
        for (final query in _booru.store.history(server.id))
          if (seen.add(query)) query,
    ];
  }

  List<String> get _savedSearches => [for (final server in _servers) ..._booru.store.savedTags(server.id, kind: 'search')];

  Future<void> _open(BooruPost post) async {
    final posts = _loader.visiblePosts;
    String? viewed;
    widget.challenge?.select(post);
    await BooruPostView.open(
      context,
      booru: _booru,
      post: post,
      posts: posts,
      discovery: _discovery,
      source: widget.source,
      challenge: widget.challenge,
      loadMore: () async {
        for (var attempt = 0; attempt < 3; attempt++) {
          final count = _loader.visiblePosts.length;
          await _load(reset: false);
          if (_loader.visiblePosts.length > count || !_loader.hasMore) break;
        }
        return BooruViewerBatch(posts: _loader.visiblePosts, hasMore: _loader.hasMore, failure: _loader.error);
      },
      willClose: (post) => viewed = post.id,
    );
    final viewedID = viewed;
    if (viewedID != null && mounted) restoreViewerPosition(openedID: post.id, viewedID: viewedID, keys: _keys);
  }

  void _hold(BuildContext context, BooruPost post) {
    showWorkSaveFeedback(context, _booru.toggleFavorite(post, context: _discovery), bottom: tabBarClearance(context) + 8);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final barBottom = rootContentTop(context, pushed: widget.onBack != null);
    final pool = widget.pool;
    final posts = _loader.visiblePosts;
    final title = pool?.name.replaceAll('_', ' ') ?? L10n.text('Explore');
    return ColoredBox(
      color: TegnalColors.background.resolveFrom(context),
      child: Stack(
        children: [
          CustomScrollView(
            controller: _scroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
            slivers: [
              CupertinoSliverRefreshControl(onRefresh: _refresh),
              if (widget.header case final header?) ...[
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(16, barBottom + 16, 16, 16),
                  sliver: SliverToBoxAdapter(child: header),
                ),
                // The search field scrolls with the header until it reaches the bar.
                SliverToBoxAdapter(
                  child: SizedBox(key: _searchSlot, height: 56, child: _searchSlotPinned || pool != null ? null : _searchArea(media)),
                ),
              ],
              SliverPadding(
                padding: EdgeInsets.fromLTRB(16, widget.header != null ? 8 : barBottom + (pool == null ? 8 + 56 : 16), 16, 0),
                sliver: SliverToBoxAdapter(child: pool == null ? _filters() : const SizedBox.shrink()),
              ),
              SliverToBoxAdapter(child: SizedBox(height: pool == null ? 8 : 0)),
              SliverPadding(
                padding: EdgeInsets.zero,
                sliver: BooruPostGridSliver(
                  booru: _booru,
                  posts: posts,
                  showsFavorite: true,
                  topMarginScale: pool == null ? 0.5 : 1,
                  prefetch: _prefetch,
                  itemKey: (id) => _keys.putIfAbsent(id, GlobalKey.new),
                  open: _open,
                  hold: _hold,
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + tabBarClearance(context)),
                sliver: SliverToBoxAdapter(child: _footer(context)),
              ),
            ],
          ),
          if (pool == null && (widget.header == null || _searchSlotPinned))
            Positioned(
              left: 0,
              right: 0,
              top: barBottom,
              child: AnimatedSlide(
                offset: Offset(0, _searchBarVisible ? 0 : -60 / 56),
                duration: Duration(milliseconds: _searchBarVisible ? 350 : 320),
                curve: _searchBarVisible ? Curves.easeOutBack : Curves.easeInOut,
                child: AnimatedOpacity(
                  opacity: _searchBarVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 250),
                  child: IgnorePointer(ignoring: !_searchBarVisible, child: _searchArea(media)),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child:
                widget.bar ??
                RootHeader(
                  title: title,
                  state: _booru.state,
                  onBack: widget.onBack,
                  trailing: widget.showsServerMenu ? BooruServerMenuButton(store: _booru.store) : null,
                ),
          ),
        ],
      ),
    );
  }

  Widget _searchArea(MediaQueryData media) {
    final available = media.size.height - media.padding.top - rootBarHeight - media.viewInsets.bottom;
    final focused = _searchFocus.hasFocus;
    final empty = _search.text.isEmpty;
    final history = focused && empty ? _history : const <String>[];
    final saved = focused && empty ? _savedSearches : const <String>[];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ScrollSearchBar(controller: _search, focusNode: _searchFocus, prompt: L10n.text('Search tags'), onSubmitted: _submit),
        if (focused && empty && (history.isNotEmpty || saved.isNotEmpty))
          SearchResultsPanel(
            height: SearchHistoryPanel.height(available),
            child: SearchHistoryPanel(
              history: history,
              saved: saved,
              open: (query) {
                _search.text = query;
                _submit(query);
              },
              star: (query) => setState(() {
                final store = _booru.store;
                final allSaved = _servers.every((server) => store.savedTags(server.id, kind: 'search').contains(query));
                for (final server in _servers) {
                  if (allSaved || !store.savedTags(server.id, kind: 'search').contains(query)) store.toggleTag(query, serverID: server.id, kind: 'search');
                }
              }),
              remove: (query) => setState(() {
                for (final server in _servers) {
                  _booru.store.deleteSearch(query, serverID: server.id);
                }
              }),
              clear: () => setState(() {
                for (final server in _servers) {
                  _booru.store.clearHistory(server.id);
                }
              }),
            ),
          )
        else if (focused && !empty && (_suggestions.isNotEmpty || _suggesting || _suggestionError != null))
          SearchResultsPanel(
            height: (_suggestions.length * 47.0).clamp(60, 280),
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final (index, tag) in _suggestions.indexed) ...[
                  if (index > 0) Container(height: 0.5, color: TegnalColors.separator.resolveFrom(context)),
                  _SuggestionRow(
                    tag: tag,
                    onTap: () {
                      final completion = BooruCompletion.parse(_search.text);
                      if (completion == null) return;
                      final text = completion.inserting(tag.name);
                      _search.value = TextEditingValue(
                        text: text,
                        selection: TextSelection.collapsed(offset: text.length),
                      );
                    },
                  ),
                ],
                if (_suggesting)
                  Semantics(
                    label: L10n.text('Finding tags'),
                    child: const Padding(padding: EdgeInsets.all(16), child: CupertinoActivityIndicator()),
                  ),
                if (_suggestionError != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_suggestionError!, style: TegnalType.style(12, color: TegnalColors.secondaryLabel.resolveFrom(context))),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _filters() => Row(
    children: [
      const Spacer(),
      BrowseFilterMenu<BooruSort>(
        title: _sort.title,
        icon: Symbols.arrowUpArrowDown,
        options: [for (final sort in _sortOptions) (sort, sort.title)],
        selected: _sort,
        onSelected: (sort) {
          setState(() => _sort = sort);
          _loadIfNeeded();
        },
      ),
    ],
  );

  Widget _footer(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final pool = widget.pool;
    final hasAccessible = _loader.posts.any(_booru.store.isVisible);
    return Column(
      children: [
        if (_loader.loading)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const CupertinoActivityIndicator(),
                const SizedBox(height: 8),
                Text(L10n.text('Loading'), style: TegnalType.style(15, color: secondary)),
              ],
            ),
          ),
        for (final server in _servers)
          if (_loader.errors[server.id] case final error?) ...[
            const SizedBox(height: 8),
            _ServerFailureCard(
              booru: _booru,
              server: server,
              message: error,
              query: _sort.query(_effectiveQuery, server.engine),
              expanded: _expandedQueries.contains(server.id),
              toggleQuery: () => setState(() => _expandedQueries.contains(server.id) ? _expandedQueries.remove(server.id) : _expandedQueries.add(server.id)),
              retry: () => setState(() {
                _retry++;
                _loadIfNeeded();
              }),
            ),
          ],
        if (_loader.didLoad && !_loader.loading && _loader.errors.isEmpty && _loader.visiblePosts.isEmpty && (!_loader.hasMore || hasAccessible))
          ContentUnavailable(
            icon: CupertinoIcons.photo_on_rectangle,
            title: L10n.text(!hasAccessible ? (pool == null ? 'No Posts' : 'No Available Posts') : 'Posts Hidden'),
            message: L10n.text(
              !hasAccessible
                  ? (pool == null
                        ? 'Try different tags or another server.'
                        : 'This website returned no posts for this pool. It may be empty or its posts may no longer be available.')
                  : 'These posts match your blacklist. You can load the next page.',
            ),
          ),
        if (_loader.hasMore)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _BorderedButton(title: L10n.text('Load More'), onPressed: _loader.loading ? null : () => _load(reset: false)),
          ),
      ],
    );
  }
}

/// A server that failed to load, with what it searched and how to recover.
class _ServerFailureCard extends StatelessWidget {
  const _ServerFailureCard({
    required this.booru,
    required this.server,
    required this.message,
    required this.query,
    required this.expanded,
    required this.toggleQuery,
    required this.retry,
  });
  final BooruContext booru;
  final BooruServer server;
  final String message;
  final String query;
  final bool expanded;
  final VoidCallback toggleQuery;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) {
    final label = TegnalColors.label.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: ShapeDecoration(
        color: const CupertinoDynamicColor.withBrightness(color: Color(0x2E787880), darkColor: Color(0x2E787880)).resolveFrom(context),
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ServerRackSymbol(size: 20, color: tint),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  server.displayName,
                  style: TegnalType.style(17, weight: FontWeight.w600, color: label),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(message, style: TegnalType.style(15, color: secondary)),
          const SizedBox(height: 12),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: toggleQuery,
            child: Row(
              children: [
                Expanded(
                  child: Text(L10n.text('Search Tags'), style: TegnalType.style(17, color: label)),
                ),
                AnimatedRotation(
                  turns: expanded ? 0.25 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(CupertinoIcons.chevron_right, size: 15, color: tint),
                ),
              ],
            ),
          ),
          if (expanded) ...[const SizedBox(height: 8), Text(query, style: TegnalType.style(12, color: label))],
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              _BorderedButton(
                title: L10n.text('Validate Client'),
                icon: CupertinoIcons.checkmark_shield,
                prominent: true,
                onPressed: () => showAppSheet<void>(
                  context,
                  builder: (context, controller) => BooruValidationView(booru: booru, server: server, initialURL: server.browsingURL(query, poolID: null)),
                ),
              ),
              _BorderedButton(title: L10n.text('Try Again'), onPressed: retry),
            ],
          ),
        ],
      ),
    );
  }
}

/// `.bordered` / `.borderedProminent` capsules.
class _BorderedButton extends StatelessWidget {
  const _BorderedButton({required this.title, required this.onPressed, this.icon, this.prominent = false});
  final String title;
  final IconData? icon;
  final bool prominent;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    final foreground = prominent ? const Color(0xFFFFFFFF) : tint;
    return Semantics(
      button: true,
      enabled: onPressed != null,
      child: GestureDetector(
        onTap: onPressed,
        child: Opacity(
          opacity: onPressed == null ? 0.4 : 1,
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: ShapeDecoration(color: prominent ? tint : tint.withValues(alpha: 0.15), shape: const StadiumBorder()),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[Icon(icon, size: 17, color: foreground), const SizedBox(width: 6)],
                Text(
                  title,
                  style: TegnalType.style(15, weight: FontWeight.w500, color: foreground),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One tag suggestion: its kind, name and how many posts use it.
class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({required this.tag, required this.onTap});
  final BooruTag tag;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 46),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(tag.isArtist ? CupertinoIcons.person : CupertinoIcons.number, size: 17, color: secondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                tag.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TegnalType.style(15, color: TegnalColors.label.resolveFrom(context)),
              ),
            ),
            if (tag.count > 0) ...[
              const SizedBox(width: 4),
              Text(tag.count.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ','), style: TegnalType.style(12, color: secondary)),
            ],
          ],
        ),
      ),
    );
  }
}

/// The selected servers' feed, or why there is none.
class BooruExploreRoot extends StatelessWidget {
  const BooruExploreRoot({super.key, required this.booru, required this.isActive});
  final BooruContext booru;
  final bool isActive;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: booru.store,
    builder: (context, _) {
      final servers = booru.store.selectedServers;
      if (servers.isEmpty) {
        final top = rootContentTop(context);
        return ColoredBox(
          color: TegnalColors.background.resolveFrom(context),
          child: Stack(
            children: [
              Positioned.fill(
                top: top,
                child: const Center(child: BooruNoSelectionView()),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: RootHeader(
                  title: L10n.text('Explore'),
                  state: booru.state,
                  trailing: BooruServerMenuButton(store: booru.store),
                ),
              ),
            ],
          ),
        );
      }
      return BooruFeedView(booru: booru, servers: servers, isActive: isActive && booru.state.mode == AppMode.booru, showsServerMenu: true);
    },
  );
}
