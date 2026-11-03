import 'dart:async';
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/content/gallery_content.dart';
import '../../core/storage/app_database.dart';
import '../../core/support/l10n.dart';
import '../../core/content/content_environment.dart';
import '../design/symbols.dart';
import '../design/tegnal_theme.dart';
import '../navigation/app_header.dart';
import '../navigation/app_state.dart';
import '../navigation/root_tab_view.dart';
import '../works/artwork_grid.dart';
import '../works/search_controls.dart';
import 'gallery_feed_loader.dart';
import 'page_image_store.dart';

/// Accumulates scroll travel so slow drags behave like fast swipes (`ScrollSearchVisibility`).
class ScrollSearchVisibility {
  double _travel = 0;

  bool? update(double oldY, double newY, {required bool focused}) {
    if (focused || newY <= 15) {
      _travel = 0;
      return true;
    }
    final delta = newY - oldY;
    if (delta.abs() <= 0.1) return null;
    if (_travel * delta < 0) {
      _travel = delta;
    } else {
      _travel += delta;
    }
    if (_travel >= 32) {
      _travel = 0;
      return false;
    }
    if (_travel <= -24) {
      _travel = 0;
      return true;
    }
    return null;
  }
}

/// Explore: the connected site's latest works with language, category and sort
/// filters, and a search field that hides while scrolling down (`GalleryFeedView`).
class ExploreView extends StatefulWidget {
  const ExploreView({
    super.key,
    required this.state,
    required this.source,
    required this.images,
    required this.database,
    required this.content,
    required this.openGallery,
    this.bookmark,
    this.isActive = true,
    this.initialQuery = '',
    this.onBack,
  });

  final AppState state;
  final ContentProviding source;
  final PageImageStore images;
  final AppDatabase database;
  final ContentEnvironment content;
  final void Function(int id) openGallery;

  /// Holding a card toggles its bookmark.
  final void Function(int id, NativeGallery? gallery)? bookmark;
  final bool isActive;

  /// A feed opened from a tag or search starts with that query and offers a way back.
  final String initialQuery;
  final VoidCallback? onBack;

  @override
  State<ExploreView> createState() => _ExploreViewState();
}

class _ExploreViewState extends State<ExploreView> {
  late final GalleryFeedLoader _loader = GalleryFeedLoader(source: widget.source, images: widget.images);
  late GalleryQuery _query = GalleryQuery(
    language: ArtistBrowsing.matches(widget.initialQuery) ? ArtistBrowsing.language : (widget.initialQuery.isEmpty ? L10n.contentLanguage : 'all'),
    text: widget.initialQuery,
  );
  late String _openedCategory = '';
  late final _search = TextEditingController(text: widget.initialQuery);
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();
  final _visibility = ScrollSearchVisibility();
  double _lastOffset = 0;
  bool _searchBarVisible = true;
  List<String> _history = [];
  List<String> _saved = [];
  Set<int> _bookmarked = {};
  List<TagSuggestion> _suggestions = [];
  bool _suggesting = false;
  Timer? _suggestionTimer;
  int _suggestionGeneration = 0;

  /// Suggests a tag for the word being typed, 300 ms after typing stops.
  void _textChanged() {
    _suggestionTimer?.cancel();
    final generation = ++_suggestionGeneration;
    final context = _searchFocus.hasFocus ? TagCompletionContext.parse(_search.text) : null;
    setState(() {
      _suggestions = [];
      _suggesting = false;
    });
    if (context == null) return;
    _suggestionTimer = Timer(const Duration(milliseconds: 300), () async {
      if (!mounted || generation != _suggestionGeneration) return;
      setState(() => _suggesting = true);
      try {
        final result = await widget.source.suggestions(context.token);
        if (!mounted || generation != _suggestionGeneration) return;
        setState(() {
          _suggestions = result.take(8).toList();
          _suggesting = false;
        });
      } on Object {
        if (mounted && generation == _suggestionGeneration) setState(() => _suggesting = false);
      }
    });
  }

  /// The main feed remembers its category; a feed opened from a tag or artist starts with all.
  bool get _isMainFeed => widget.onBack == null;
  String get _category => _isMainFeed ? widget.content.mangaBrowseCategory : _openedCategory;
  set _category(String value) => setState(() => _isMainFeed ? widget.content.mangaBrowseCategory = value : _openedCategory = value);

  GalleryQuery _effective(String category) {
    final content = widget.content;
    return _query
        .filteredTo(category)
        .applyingDefaults(tags: content.defaultTags, excluded: content.defaultExcludedTags)
        .copyWith(allowsLanguageExceptions: content.allowsMangaLanguageExceptions);
  }

  GalleryQuery get _effectiveQuery => _effective(_category);

  Set<int> get _hidden => widget.content.hiddenMangaGalleryIDs;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _searchFocus.addListener(() {
      if (_searchFocus.hasFocus) {
        _reloadSearches();
        setState(() => _searchBarVisible = true);
      } else {
        setState(() {});
      }
    });
    _search.addListener(_textChanged);
    _loader.addListener(() => setState(() {}));
    _reloadBookmarks();
    // Saved marks follow the works table, as the native view observes it.
    _libraryChanges = widget.database.changes.listen((_) {
      if (mounted) setState(_reloadBookmarks);
    });
    if (widget.isActive) _loader.load(_effectiveQuery, reset: true);
  }

  StreamSubscription<int>? _libraryChanges;

  @override
  void didUpdateWidget(ExploreView old) {
    super.didUpdateWidget(old);
    if (widget.isActive && !old.isActive) {
      _loader.resume();
      _reloadBookmarks();
      if (!_loader.didLoad || _loader.currentQuery != _effectiveQuery) _loader.load(_effectiveQuery, reset: true);
    } else if (!widget.isActive && old.isActive) {
      _loader.suspend();
    }
  }

  @override
  void dispose() {
    _libraryChanges?.cancel();
    _loader.dispose();
    _suggestionTimer?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    final offset = _scroll.offset;
    final visible = _visibility.update(_lastOffset, offset, focused: _searchFocus.hasFocus);
    _lastOffset = offset;
    if (visible != null && visible != _searchBarVisible) setState(() => _searchBarVisible = visible);
    final position = _scroll.position;
    if (position.extentAfter < 600 && _loader.hasMore && !_loader.loading && _loader.error == null) {
      _loader.load(_effectiveQuery, reset: false);
    }
  }

  void _reloadSearches() {
    _history = widget.database.searchHistory();
    _saved = widget.database.savedSearches();
  }

  void _reloadBookmarks() => _bookmarked = widget.database.savedGalleryIDs().toSet();

  void _changeQuery(GalleryQuery query) {
    setState(() => _query = query);
    _loader.load(_effectiveQuery, reset: true);
  }

  void _submitSearch([String? value]) {
    _searchFocus.unfocus();
    final text = (value ?? _search.text).trim();
    if (widget.content.browserPreferences.boolean('search.rememberHistory') ?? true) widget.database.recordSearch(text);
    _reloadSearches();
    final route = ContentRoute.initial(text);
    if (route case GalleryRoute(:final id) || ReaderRoute(:final id)) return widget.openGallery(id);
    final number = RegExp(r'^[0-9]+$').hasMatch(text) ? int.tryParse(text) : null;
    if (number != null && number > 0) return widget.openGallery(number);
    if (_query.text == text) {
      _loader.load(_effectiveQuery, reset: true);
    } else {
      _changeQuery(_query.copyWith(text: text));
    }
  }

  Future<void> _refresh() async {
    final text = _search.text.trim();
    if (_query.text != text) {
      _changeQuery(_query.copyWith(text: text));
    } else {
      await _loader.load(_effectiveQuery, reset: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final barBottom = media.padding.top + rootBarHeight;
    final hidden = _hidden;
    final entries = [
      for (final id in _loader.ids)
        if (!hidden.contains(id)) id,
    ];
    final title = _query.text.isEmpty ? L10n.text('Explore') : L10n.text('Search Results');
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
              SliverPadding(
                padding: EdgeInsets.fromLTRB(16, barBottom + 8 + 56, 16, 0),
                sliver: SliverToBoxAdapter(child: _filters()),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 8)),
              ArtworkGridSliver(
                itemCount: entries.length,
                topMarginScale: 0.5,
                preferences: ArtworkGridPreferences(
                  columns: widget.content.mangaColumns,
                  removesPadding: widget.content.mangaRemovesGridPadding,
                  showsTitles: widget.content.showsMangaTitles,
                  showsArtists: widget.content.showsMangaArtists,
                  showsCategories: widget.content.showsMangaCategories,
                ),
                itemBuilder: (context, index, style) {
                  _loader.retainCovers(index);
                  final id = entries[index];
                  final preview = _loader.previews[id];
                  return _GalleryGridCard(
                    key: ValueKey(id),
                    id: id,
                    preview: preview,
                    style: style,
                    bookmarked: _bookmarked.contains(id),
                    open: () => widget.openGallery(id),
                    hold: widget.bookmark == null ? null : () => widget.bookmark!(id, preview?.gallery),
                  );
                },
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + tabBarClearance(context)),
                sliver: SliverToBoxAdapter(child: _footer(context)),
              ),
            ],
          ),
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
            child: RootHeader(title: title, state: widget.state, onBack: widget.onBack),
          ),
        ],
      ),
    );
  }

  Widget _searchArea(MediaQueryData media) {
    final available = media.size.height - media.padding.top - rootBarHeight - media.viewInsets.bottom;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ScrollSearchBar(controller: _search, focusNode: _searchFocus, prompt: L10n.text('Search, number, or link'), onSubmitted: _submitSearch),
        if (_searchFocus.hasFocus && _search.text.isEmpty)
          SearchResultsPanel(
            height: SearchHistoryPanel.height(available),
            child: SearchHistoryPanel(
              history: _history,
              saved: _saved,
              open: (query) {
                _search.text = query;
                _submitSearch(query);
              },
              star: (query) => setState(() {
                widget.database.toggleSavedSearch(query);
                _reloadSearches();
              }),
              remove: (query) => setState(() {
                widget.database.deleteSearch(query);
                _reloadSearches();
              }),
              clear: () => setState(() {
                widget.database.clearSearchHistory();
                _reloadSearches();
              }),
            ),
          )
        else if (_searchFocus.hasFocus && _suggestions.isNotEmpty)
          SearchResultsPanel(
            height: (_suggestions.length * 47.0).clamp(0, 280),
            child: ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: _suggestions.length,
              separatorBuilder: (context, _) => Container(height: 0.5, color: TegnalColors.separator.resolveFrom(context)),
              itemBuilder: (context, index) => _SuggestionRow(
                suggestion: _suggestions[index],
                onTap: () {
                  final completion = TagCompletionContext.parse(_search.text);
                  if (completion == null) return;
                  _search.value = TextEditingValue(
                    text: completion.inserting(_suggestions[index]),
                    selection: TextSelection.collapsed(offset: completion.inserting(_suggestions[index]).length),
                  );
                  setState(() => _suggestions = []);
                },
              ),
            ),
          )
        else if (_searchFocus.hasFocus && _suggesting)
          Semantics(
            label: L10n.text('Finding tags'),
            child: const SearchResultsPanel(height: 60, child: Center(child: CupertinoActivityIndicator())),
          ),
      ],
    );
  }

  Widget _filters() {
    final language = BrowseFilterMenu<String>(
      title: L10n.text(_capitalized(_query.language)),
      icon: Symbols.globe,
      options: [('korean', L10n.text('Korean')), ('japanese', L10n.text('Japanese')), ('english', L10n.text('English')), ('all', L10n.text('All'))],
      selected: _query.language,
      onSelected: (value) => _changeQuery(_query.copyWith(language: value)),
    );
    final available = GalleryCategory.available;
    final selectedCategory = available.contains(_category) ? _category : '';
    final category = BrowseFilterMenu<String>(
      title: selectedCategory.isEmpty ? L10n.text('Category') : GalleryCategory.title(selectedCategory),
      icon: Symbols.squareStack,
      options: [('', L10n.text('All Categories')), for (final value in available) (value, GalleryCategory.title(value))],
      selected: selectedCategory,
      onSelected: (value) {
        _category = value;
        _loader.load(_effectiveQuery, reset: true);
      },
    );
    final sort = BrowseFilterMenu<GallerySort>(
      title: _query.sort.title,
      icon: Symbols.arrowUpArrowDown,
      options: [for (final value in GallerySort.available) (value, value.title)],
      selected: _query.sort,
      onSelected: (value) => _changeQuery(_query.copyWith(sort: value)),
    );
    // `ViewThatFits`: one row when it fits, otherwise category moves below.
    return LayoutBuilder(
      builder: (context, constraints) => _FitsInRow(
        width: constraints.maxWidth,
        wide: Row(children: [language, const SizedBox(width: 8), category, const Spacer(), sort]),
        narrow: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [language, const Spacer(), sort]),
            const SizedBox(height: 8),
            category,
          ],
        ),
        measure: Row(mainAxisSize: MainAxisSize.min, children: [language, const SizedBox(width: 8), category, const SizedBox(width: 8), sort]),
      ),
    );
  }

  Widget _footer(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    if (_loader.loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            const CupertinoActivityIndicator(),
            const SizedBox(height: 8),
            Text(L10n.text('Loading'), style: TegnalType.style(15, color: secondary)),
          ],
        ),
      );
    }
    if (_loader.error != null) {
      return ContentUnavailable(
        icon: Symbols.wifiExclamationmark,
        title: L10n.text('Unable to Load'),
        message: _loader.error,
        action: (L10n.text('Try Again'), () => _loader.retry(_effectiveQuery)),
      );
    }
    if (_loader.ids.isEmpty && _loader.didLoad) {
      if (_effectiveQuery != _effective('')) {
        return ContentUnavailable(
          icon: Symbols.squareStack,
          title: L10n.text('No Works in This Category'),
          action: (
            L10n.text('Show All Categories'),
            () {
              _category = '';
              _loader.load(_effectiveQuery, reset: true);
            },
          ),
        );
      }
      return ContentUnavailable(
        icon: Symbols.magnifyingglass,
        title: _query.text.isEmpty ? L10n.text('No Results') : L10n.text('No Results for “%@”', [_query.text]),
        message: L10n.text('Check the spelling or try a new search.'),
      );
    }
    if (_loader.hasMore) {
      return CupertinoButton(onPressed: () => _loader.load(_effectiveQuery, reset: false), child: Text(L10n.text('Load More')));
    }
    return const SizedBox.shrink();
  }

  static String _capitalized(String value) => value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);
}

/// Picks the wide layout when its natural width fits.
class _FitsInRow extends StatelessWidget {
  const _FitsInRow({required this.width, required this.wide, required this.narrow, required this.measure});
  final double width;
  final Widget wide;
  final Widget narrow;
  final Widget measure;

  @override
  Widget build(BuildContext context) {
    final painter = _MeasuredWidth.of(measure, context);
    return painter <= width ? wide : narrow;
  }
}

abstract final class _MeasuredWidth {
  /// Filter capsules are text plus fixed chrome, so their width is measured from the text.
  static double of(Widget row, BuildContext context) {
    double total = 0;
    void visit(Widget widget) {
      if (widget is Row) {
        widget.children.forEach(visit);
      } else if (widget is SizedBox) {
        total += widget.width ?? 0;
      } else if (widget is BrowseFilterMenu) {
        final painter = TextPainter(
          text: TextSpan(
            text: widget.title,
            style: TegnalType.style(15, weight: FontWeight.w500),
          ),
          textDirection: TextDirection.ltr,
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        total += painter.width + 12 * 2 + 19 + 6;
      }
    }

    visit(row);
    return total;
  }
}

/// `ContentUnavailableView`: a centered symbol, title, message and optional action.
class ContentUnavailable extends StatelessWidget {
  const ContentUnavailable({super.key, required this.icon, required this.title, this.message, this.action});
  final IconData icon;
  final String title;
  final String? message;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
      child: Column(
        children: [
          Icon(icon, size: 44, color: secondary),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TegnalType.style(22, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
          ),
          if (message != null) ...[
            const SizedBox(height: 8),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: TegnalType.style(15, color: secondary),
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: 16),
            CupertinoButton.filled(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              borderRadius: const BorderRadius.all(Radius.circular(999)),
              onPressed: action!.$2,
              child: Text(
                action!.$1,
                style: TegnalType.style(15, weight: FontWeight.w600, color: const Color(0xFFFFFFFF)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _GalleryGridCard extends StatefulWidget {
  const _GalleryGridCard({super.key, required this.id, required this.preview, required this.style, required this.bookmarked, required this.open, this.hold});
  final int id;
  final GalleryFeedPreview? preview;
  final ArtworkCellStyle style;
  final bool bookmarked;
  final VoidCallback open;
  final VoidCallback? hold;

  @override
  State<_GalleryGridCard> createState() => _GalleryGridCardState();
}

class _GalleryGridCardState extends State<_GalleryGridCard> {
  @override
  void initState() {
    super.initState();
    widget.preview?.addListener(_changed);
    widget.preview?.load();
  }

  @override
  void didUpdateWidget(_GalleryGridCard old) {
    super.didUpdateWidget(old);
    if (old.preview != widget.preview) {
      old.preview?.removeListener(_changed);
      widget.preview?.addListener(_changed);
      widget.preview?.load();
    }
  }

  @override
  void dispose() {
    widget.preview?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final display = widget.preview?.display;
    final image = widget.preview?.displayImage;
    final type = display?.type ?? '';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.open,
      onLongPress: widget.hold,
      child: Stack(
        children: [
          GalleryCardLayout(
            style: style,
            title: display?.title ?? L10n.text('Work %@', ['${widget.id}']),
            artists: display?.artists ?? '',
            language: display?.language ?? '',
            category: type.isEmpty ? '' : GalleryCategory.title(type),
            categoryColor: galleryCategoryColor(type),
            cover: image != null
                ? RawImage(image: image, fit: BoxFit.cover, filterQuality: ui.FilterQuality.medium)
                : ColoredBox(
                    color: TegnalColors.coverPlaceholder.resolveFrom(context),
                    child: Center(child: Icon(Symbols.book, color: TegnalColors.secondaryLabel.resolveFrom(context))),
                  ),
          ),
          if (widget.bookmarked)
            Positioned(
              left: style.inset(7),
              top: style.inset(7),
              child: Container(
                padding: EdgeInsets.all(style.inset(8)),
                decoration: const ShapeDecoration(color: Color(0xB8000000), shape: CircleBorder()),
                child: Icon(Symbols.bookmarkFill, size: style.fontSize(14), color: CupertinoColors.systemYellow),
              ),
            ),
        ],
      ),
    );
  }
}

/// One tag completion: namespace, name and how many works use it.
class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({required this.suggestion, required this.onTap});
  final TagSuggestion suggestion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final count = suggestion.count;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 46),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Text(suggestion.namespace, style: TegnalType.style(12, color: secondary)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                suggestion.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TegnalType.style(15, color: TegnalColors.label.resolveFrom(context)),
              ),
            ),
            if (count != null) ...[const SizedBox(width: 4), Text(_grouped(count), style: TegnalType.style(12, color: secondary))],
          ],
        ),
      ),
    );
  }

  /// `Int.formatted()`: digits grouped by thousands.
  static String _grouped(int value) => value.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
}
