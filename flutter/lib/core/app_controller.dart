import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/booru_source.dart';
import '../data/library_store.dart';
import '../data/manga_source.dart';
import 'content.dart';
import 'content_filter.dart';
import 'library.dart';
import 'taste_controller.dart';

typedef SourceFactory = ContentSource Function(SourceConfig);

class ExploreState {
  final Map<String, int> sourcePages = {};
  final Set<String> exhaustedSources = {};
  List<ContentItem> items = [];
  String query = '';
  String contentLanguage = 'all';
  bool popular = false;
  BooruSort booruSort = BooruSort.latest;
  bool loading = false;
  bool hasMore = false;
  int page = 0;
  int generation = 0;
  String? error;
}

/// The controller owns source lifetimes and mode-scoped state; widgets do not
/// construct HTTP clients or perform database writes themselves.
class AppController extends ChangeNotifier {
  AppController(this.store, {SourceFactory? sourceFactory})
    : _sourceFactory = sourceFactory ?? _createSource {
    mode =
        AppMode.values
            .where((v) => v.name == store.setting('mode'))
            .firstOrNull ??
        AppMode.manga;
    taste = LocalTasteController(store);
    // Existing libraries need only keys at startup. Avoid decoding every saved
    // payload for a one-time taste seed that has already completed.
    if (!taste.initialized) {
      taste.seed(AppMode.values.expand((value) => store.items(value)));
    }
    _knownSavedKeys.addAll(store.savedKeys());
    _metadataAutomaticPending =
        store.setting('metadata.fillPending', false) == true;
    _metadataUserPaused = store.setting('metadata.fillPaused', false) == true;
    _metadataCoverFailures.addAll(
      (store.setting('metadata.coverRetryIds', <String>[]) as List)
          .cast<String>(),
    );
  }
  final LibraryStore store;
  late final LocalTasteController taste;
  final Set<String> _knownSavedKeys = {};
  final SourceFactory _sourceFactory;
  final Map<String, ContentSource> _clients = {};
  final Map<AppMode, ExploreState> _explore = {
    for (final m in AppMode.values) m: ExploreState(),
  };
  late AppMode mode;
  bool _disposed = false;
  DeviceAiCapabilities get ai => const DeviceAiCapabilities();
  bool get onboardingComplete => store.setting('onboarding', false) == true;
  String get language => store.setting('language', 'system') as String;
  String get appearance => appearanceFor(mode);
  String appearanceFor(AppMode value) => store.setting(
    'appearance.${value.name}',
    store.setting('appearance', 'dark'),
  ) as String;
  int columns(String kind, AppMode value) =>
      (store.setting('$kind.${value.name}', 0) as num).toInt().clamp(0, 5);
  bool modePreference(String key, AppMode value, [bool fallback = false]) =>
      store.setting('$key.${value.name}', fallback) == true;
  ExploreState explore([AppMode? value]) => _explore[value ?? mode]!;
  Set<String> get _archivedSources =>
      (store.setting('archivedSources', <String>[]) as List)
          .cast<String>()
          .toSet();
  List<SourceConfig> sources([AppMode? value]) => store
      .sources(value ?? mode)
      .where((s) => !_archivedSources.contains(s.id))
      .toList();
  List<SourceConfig> get allSources =>
      store.sources().where((s) => !_archivedSources.contains(s.id)).toList();
  List<LibraryFolder> folders([AppMode? value]) => store.folders(value ?? mode);
  List<SavedItem> savedItems({
    AppMode? mode,
    String? folderId,
    String query = '',
  }) => store.items(mode ?? this.mode, folderId: folderId, query: query);
  List<SearchEntry> history([AppMode? value]) {
    final target = value ?? mode;
    final days = (store.setting('historyRetention.${target.name}', 0) as num)
        .toInt();
    if (days > 0) {
      store.pruneHistory(target, DateTime.now().subtract(Duration(days: days)));
    }
    return store.history(target);
  }

  List<ArtistEntry> artists([AppMode? value]) => store.artists(value ?? mode);
  bool isSaved(ContentItem item) => store.isSaved(item.key);
  SavedItem? saved(ContentItem item) => store.saved(item.key);
  SourceConfig? sourceById(String id) =>
      allSources.where((s) => s.id == id).firstOrNull;
  SourceConfig? selectedSource([AppMode? value]) {
    final m = value ?? mode;
    final list = sources(m);
    final id = store.setting('source.${m.name}');
    return list.where((s) => s.id == id).firstOrNull ?? list.firstOrNull;
  }

  List<SourceConfig> selectedSources([AppMode? value]) {
    final m = value ?? mode;
    if (m == AppMode.manga) {
      final source = selectedSource(m);
      return source == null ? [] : [source];
    }
    final selection =
        store.setting('selected.booru') ??
        store.portable('backup.images')?['selectedServerIDs'];
    // A deliberately empty selection is different from a new installation.
    if (selection == null) {
      final first = selectedSource(m);
      return first == null ? [] : [first];
    }
    final ids = (selection as List).cast<String>().toSet();
    return sources(m).where((source) => ids.contains(source.id)).toList();
  }

  static ContentSource _createSource(SourceConfig s) =>
      s.kind == SourceKind.manga ? MangaSource(s) : BooruSource(s);
  ContentSource client(SourceConfig source) =>
      _clients.putIfAbsent(source.id, () => _sourceFactory(source));
  void changed() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  void setMode(AppMode value) {
    if (value == AppMode.manga && modePreference('safeMode', AppMode.booru)) {
      return;
    }
    mode = value;
    store.setSetting('mode', value.name);
    changed();
  }

  void setPreference(String key, dynamic value) {
    store.setSetting(key, value);
    if (key.startsWith('historyRetention.')) {
      history(AppMode.values.byName(key.split('.').last));
    }
    if (key == 'safeMode.booru' && value == true) {
      mode = AppMode.booru;
      store.setSetting('mode', mode.name);
    }
    changed();
  }

  ReaderPreferences readerPreferences(AppMode mode) =>
      ReaderPreferences.fromJson(
        Map<String, dynamic>.from(
          store.setting('reader.${mode.name}', <String, dynamic>{}) as Map,
        ),
      );
  void setReaderPreferences(AppMode mode, ReaderPreferences prefs) =>
      setPreference('reader.${mode.name}', prefs.toJson());
  void finishOnboarding() => setPreference('onboarding', true);

  SourceConfig addSource(String address, SourceKind kind, {String? name}) {
    final uri = SourceConfig.validateUrl(address);
    final candidate = SourceConfig(id: '', name: '', baseUrl: uri, kind: kind);
    final existing = store
        .sources()
        .where(
          (s) =>
              s.mode == candidate.mode &&
              s.canonicalAddress == candidate.canonicalAddress,
        )
        .firstOrNull;
    if (existing != null) {
      final updated = SourceConfig(
        id: existing.id,
        name: name?.trim().isNotEmpty == true ? name!.trim() : existing.name,
        baseUrl: Uri.parse(candidate.canonicalAddress),
        kind: kind,
      );
      _clients.remove(existing.id)?.close();
      store.saveSource(updated);
      selectSource(updated);
      return updated;
    }
    final source = SourceConfig(
      id: newId('source'),
      name: name?.trim().isNotEmpty == true ? name!.trim() : uri.host,
      baseUrl: Uri.parse(candidate.canonicalAddress),
      kind: kind,
    );
    store.saveSource(source);
    selectSource(source);
    return source;
  }

  void selectSource(SourceConfig source) {
    final archived = _archivedSources..remove(source.id);
    store.setSetting('archivedSources', archived.toList());
    if (source.mode == AppMode.booru) {
      store.setSetting('selected.booru', [source.id]);
    }
    store.setSetting('source.${source.mode.name}', source.id);
    _resetExplore(source.mode);
    changed();
    if (source.mode == AppMode.manga) _resumeMetadataFill(sourceChanged: true);
  }

  void selectSources(List<SourceConfig> selected) {
    if (selected.isEmpty) {
      store.setSetting('selected.booru', <String>[]);
      _resetExplore(AppMode.booru);
      changed();
      return;
    }
    final m = selected.first.mode;
    if (m == AppMode.manga) {
      selectSource(selected.first);
      return;
    }
    store.setSetting(
      'selected.booru',
      selected.where((s) => s.mode == m).map((s) => s.id).toSet().toList(),
    );
    store.setSetting('source.booru', selected.first.id);
    _resetExplore(m);
    changed();
  }

  void _resetExplore(AppMode mode) {
    final state = explore(mode);
    state.generation++;
    state.items = [];
    state.error = null;
    state.page = 0;
    state.hasMore = false;
    state.loading = false;
    state.sourcePages.clear();
    state.exhaustedSources.clear();
    if (mode == AppMode.booru &&
        !BooruSort.supportedBy(selectedSources(mode))
            .contains(state.booruSort)) {
      state.booruSort = BooruSort.latest;
      state.popular = false;
    }
  }

  void removeSource(SourceConfig source) {
    // Keep server identity for saved posts and portable backup validation.
    // Removing a connection must not strand those posts or invalidate exports.
    store.setSetting(
      'archivedSources',
      (_archivedSources..add(source.id)).toList(),
    );
    _clients.remove(source.id)?.close();
    _resetExplore(source.mode);
    changed();
  }

  void libraryRestored({bool fillMissingMetadata = false}) {
    // Import invalidates pending responses, but the old single flight must
    // finish before another request is started.
    if (metadataFillRunning) {
      _metadataGeneration++;
      metadataFillRunning = false;
    }
    final current = [for (final value in AppMode.values) ...store.items(value)];
    for (final entry in current) {
      if (!_knownSavedKeys.contains(entry.item.key)) {
        taste.record('imported', entry.item);
      }
    }
    _knownSavedKeys
      ..clear()
      ..addAll(current.map((entry) => entry.item.key));
    for (final m in AppMode.values) {
      _resetExplore(m);
    }
    for (final client in _clients.values) {
      client.close();
    }
    _clients.clear();
    changed();
    if (fillMissingMetadata) {
      unawaited(this.fillMissingMetadata());
    } else {
      _resumeMetadataFill();
    }
  }

  /// Native defaults augment requests without rewriting the user's saved query.
  String effectiveSearchQuery(String query, AppMode value) {
    final terms = query.trim().split(RegExp(r'\s+')).where((v) => v.isNotEmpty);
    if (value == AppMode.booru) {
      final explicit = terms.any(
        (term) => term
            .replaceFirst(RegExp(r'^[-~]+'), '')
            .toLowerCase()
            .startsWith('rating:'),
      );
      if (!modePreference('safeMode', value) || explicit) return query;
      final rating = store.setting('safeRating.booru', 'g');
      return [
        ...terms,
        'rating:${const {'g', 's', 'q'}.contains(rating) ? rating : 'g'}',
      ].join(' ');
    }
    final includes = (store.setting('defaultTags.manga', '') as String).split(
      RegExp(r'\s+'),
    );
    final excludes = (store.setting('defaultExcludedTags.manga', '') as String)
        .split(RegExp(r'\s+'));
    return <String>{
      ...terms,
      ...includes.where((v) => v.isNotEmpty),
      ...excludes
          .where((v) => v.isNotEmpty)
          .map((v) => '-${v.replaceFirst(RegExp(r'^-+'), '')}'),
    }.join(' ');
  }

  Future<ContentPage> searchSource(
    SourceConfig source,
    String query, {
    int page = 1,
    bool popular = false,
    BooruSort? sort,
    String? mangaSort,
  }) {
    final adapter = client(source);
    final effective = effectiveSearchQuery(query, source.mode);
    if (adapter is MangaSource && mangaSort != null) {
      return adapter.search(
        effective,
        page: page,
        popular: !{'recommended', 'latest'}.contains(mangaSort),
        period: mangaSort == 'popular' ? 'week' : mangaSort,
      );
    }
    if (source.mode == AppMode.booru &&
        adapter is SortedContentSource &&
        sort != null) {
      return (adapter as SortedContentSource).searchSorted(
        effective,
        page: page,
        sort: sort,
      );
    }
    return adapter.search(effective, page: page, popular: popular);
  }

  Future<void> search({
    String? query,
    bool? popular,
    BooruSort? booruSort,
    bool more = false,
    AppMode? forMode,
  }) async {
    final m = forMode ?? mode;
    final state = explore(m);
    final selected = selectedSources(m);
    if (selected.isEmpty || (more && (state.loading || !state.hasMore))) {
      return;
    }
    final previous = (
      sort: state.booruSort,
      popular: state.popular,
      query: state.query,
      items: state.items,
      page: state.page,
      hasMore: state.hasMore,
      sourcePages: Map<String, int>.of(state.sourcePages),
      exhausted: Set<String>.of(state.exhaustedSources),
    );
    final generation = ++state.generation;
    if (!more) {
      state.page = 0;
      state.items = [];
      state.hasMore = false;
      state.sourcePages.clear();
      state.exhaustedSources.clear();
    }
    state.query = query ?? state.query;
    state.popular = popular ?? state.popular;
    if (m == AppMode.booru) {
      state.booruSort =
          booruSort ??
          (popular == null
              ? state.booruSort
              : popular
              ? BooruSort.popular
              : BooruSort.latest);
      state.popular = state.booruSort != BooruSort.latest;
    }
    state.loading = true;
    state.error = null;
    changed();
    try {
      final targets = selected
          .where((s) => !state.exhaustedSources.contains(s.id))
          .toList();
      // Keep a failed source's own cursor unchanged while successful sources
      // advance independently, avoiding gaps and duplicate pages on Retry.
      final results = await Future.wait(
        targets.map((source) async {
          try {
            final adapter = client(source);
            if (adapter is MangaSource) {}
            var requestQuery = effectiveSearchQuery(state.query, m);
            if (m == AppMode.manga &&
                state.contentLanguage != 'all' &&
                !RegExp(r'(?:^|\s)language:').hasMatch(requestQuery)) {
              requestQuery = '$requestQuery language:${state.contentLanguage}'
                  .trim();
            }
            final nextPage = (state.sourcePages[source.id] ?? 0) + 1;
            final ContentPage result;
            if (m == AppMode.booru && adapter is SortedContentSource) {
              result = await (adapter as SortedContentSource).searchSorted(
                requestQuery,
                page: nextPage,
                sort: state.booruSort,
              );
            } else {
              if (m == AppMode.booru &&
                  state.booruSort != BooruSort.latest &&
                  state.booruSort != BooruSort.popular) {
                throw UnsupportedBooruSort(state.booruSort);
              }
              result = await adapter.search(
                requestQuery,
                page: nextPage,
                popular: state.popular,
              );
            }
            return (source: source, page: result, error: null as Object?);
          } catch (e) {
            return (source: source, page: null as ContentPage?, error: e);
          }
        }),
      );
      if (_disposed || generation != state.generation) {
        return;
      }
      if (results.any((result) => result.error is UnsupportedBooruSort)) {
        state.booruSort = previous.sort;
        state.popular = previous.popular;
        state.query = previous.query;
        state.items = previous.items;
        state.page = previous.page;
        state.hasMore = previous.hasMore;
        state.sourcePages
          ..clear()
          ..addAll(previous.sourcePages);
        state.exhaustedSources
          ..clear()
          ..addAll(previous.exhausted);
        state.error = 'The selected servers do not support this sort.';
        return;
      }
      final keys = state.items.map((i) => i.key).toSet();
      final added = <ContentItem>[];
      final errors = <String>[];
      var succeeded = false;
      for (final result in results) {
        final source = result.source;
        final page = result.page;
        if (page == null) {
          errors.add('${source.name}: ${errorMessage(result.error!)}');
          continue;
        }
        succeeded = true;
        state.sourcePages[source.id] = (state.sourcePages[source.id] ?? 0) + 1;
        if (!page.hasMore) {
          state.exhaustedSources.add(source.id);
        }
        final blocked = ContentFilter(
          store.setting('blacklist.${source.id}', '') as String,
        );
        added.addAll(
          page.items.where((i) => keys.add(i.key) && !blocked.contains(i)),
        );
        if (store.setting('rememberHistory.${m.name}', true) == true) {
          store.recordSearch(m, source.id, state.query);
        }
      }
      if (state.popular &&
          selected.length > 1 &&
          !RegExp(
            r'(?:^|\s)(?:order|sort):',
            caseSensitive: false,
          ).hasMatch(state.query)) {
        final metric = switch (state.booruSort) {
          BooruSort.mostFavorited => 'favoriteCount',
          BooruSort.mostUpvoted => 'upvoteCount',
          BooruSort.mostDiscussed => 'commentCount',
          _ => null,
        };
        if (metric != null) {
          added.sort(
            (a, b) => ((b.metadata[metric] as num?) ?? 0).compareTo(
              (a.metadata[metric] as num?) ?? 0,
            ),
          );
        } else if (state.booruSort != BooruSort.trending) {
          added.sort((a, b) => b.score.compareTo(a.score));
        }
      }
      state.items = [...state.items, ...added];
      if (succeeded) {
        state.page++;
      }
      state.hasMore = selected.any(
        (s) => !state.exhaustedSources.contains(s.id),
      );
      state.error = errors.isEmpty ? null : errors.join('\n');
    } catch (e) {
      if (!_disposed && generation == state.generation) {
        state.error = errorMessage(e);
      }
    } finally {
      if (!_disposed && generation == state.generation) {
        state.loading = false;
        changed();
      }
    }
  }

  Future<List<String>> suggestions(String query, {AppMode? mode}) async {
    final s = selectedSource(mode);
    return s == null ? [] : client(s).suggestions(query);
  }

  Future<ContentItem> detail(ContentItem item, {bool recordOpen = true}) async {
    final source =
        sourceById(item.sourceId) ??
        (item.mode == AppMode.manga ? selectedSource(AppMode.manga) : null);
    if (source == null) {
      throw const ContentException(
        'Connect this work’s source in Settings first.',
      );
    }
    final resolved = await client(source).detail(item.id);
    if (recordOpen) recordTasteOpen(resolved);
    return resolved;
  }

  void recordTasteOpen(ContentItem item) {
    if (_disposed || !taste.enabled) return;
    taste.record('open', item);
    changed();
  }

  Future<List<ReaderPage>> pages(ContentItem item) async {
    final source =
        sourceById(item.sourceId) ??
        (item.mode == AppMode.manga ? selectedSource(AppMode.manga) : null);
    if (source == null) {
      if (item.mediaUrl != null && item.mode == AppMode.booru) {
        return [ReaderPage(url: item.mediaUrl!)];
      }
      throw const ContentException(
        'Connect this work’s source in Settings first.',
      );
    }
    final resolved = item.sourceId == source.id
        ? item
        : await client(source).detail(item.id);
    return client(source).pages(resolved);
  }

  bool discordInvitationVisible = false;
  bool _discordInvitationRecorded = false;
  void presentDiscordInvitationIfDue({DateTime? at}) {
    final now = at ?? DateTime.now();
    final next = (store.setting(
      'discord.invitation.nextPresentation',
      0,
    ) as num).toDouble();
    if (discordInvitationVisible || next > now.millisecondsSinceEpoch / 1000) {
      return;
    }
    discordInvitationVisible = true;
    _discordInvitationRecorded = false;
  }

  /// Like native onAppear, preparing an offscreen Settings route consumes no
  /// display date. The banner records its first actual paint instead.
  void recordDiscordInvitationDisplay({DateTime? at}) {
    if (!discordInvitationVisible || _discordInvitationRecorded) return;
    _discordInvitationRecorded = true;
    store.setSetting(
      'discord.invitation.nextPresentation',
      (at ?? DateTime.now())
              .add(const Duration(days: 3))
              .millisecondsSinceEpoch /
          1000,
    );
  }

  void dismissDiscordInvitation({DateTime? at}) {
    discordInvitationVisible = false;
    store.setSetting(
      'discord.invitation.nextPresentation',
      (at ?? DateTime.now())
              .add(const Duration(days: 7))
              .millisecondsSinceEpoch /
          1000,
    );
    changed();
  }

  bool metadataFillRunning = false;
  bool metadataFillWaitingForSource = false;
  int metadataFillCompleted = 0;
  int metadataFillTotal = 0;
  int metadataFillFailed = 0;
  String? metadataFillError;
  bool metadataFillNoticeDismissed = false;
  int _metadataGeneration = 0;
  bool _metadataAutomaticPending = false;
  bool _metadataUserPaused = false;
  bool _metadataForeground = true;
  bool _metadataRequested = false;
  Future<void>? _metadataFlight;
  Future<void> Function(ContentItem)? _metadataCoverCache;
  final Set<String> _metadataCoverFailures = {};

  bool get metadataFillPaused =>
      _metadataAutomaticPending && _metadataUserPaused;
  bool get metadataFillNoticeVisible =>
      !metadataFillNoticeDismissed &&
      (metadataFillRunning ||
          metadataFillWaitingForSource ||
          metadataFillPaused ||
          metadataFillError != null);

  bool needsMetadata(ContentItem item) =>
      item.thumbnailUrl == null ||
      item.title.trim().isEmpty ||
      item.title == '#${item.id}' ||
      item.tags.isEmpty ||
      _metadataCoverFailures.contains(item.key);

  /// The app host supplies the same encoded-image cache used by visible covers.
  void setMetadataCoverCache(Future<void> Function(ContentItem)? cache) {
    _metadataCoverCache = cache;
    _resumeMetadataFill();
  }

  void setMetadataFillForeground(bool active, {bool notify = true}) {
    if (_disposed || active == _metadataForeground) return;
    _metadataForeground = active;
    if (!active && metadataFillRunning) {
      _metadataGeneration++;
      metadataFillRunning = false;
      _metadataRequested = true;
    }
    if (notify) changed();
    if (active) _resumeMetadataFill();
  }

  void _resumeMetadataFill({bool sourceChanged = false}) {
    if (_disposed ||
        !_metadataAutomaticPending ||
        _metadataUserPaused ||
        !_metadataForeground) {
      return;
    }
    if (sourceChanged) {
      metadataFillError = null;
      metadataFillWaitingForSource = false;
    }
    if (metadataFillError != null) {
      return; // Explicit retry after a failed pass.
    }
    _metadataRequested = true;
    unawaited(_ensureMetadataFill());
  }

  Future<void> fillMissingMetadata({
    Future<void> Function(ContentItem)? cacheCover,
  }) {
    if (_disposed) return Future.value();
    if (cacheCover != null) _metadataCoverCache = cacheCover;
    _metadataAutomaticPending = true;
    _metadataUserPaused = false;
    _metadataRequested = true;
    metadataFillNoticeDismissed = false;
    metadataFillError = null;
    store.setSetting('metadata.fillPending', true);
    store.setSetting('metadata.fillPaused', false);
    return _ensureMetadataFill();
  }

  Future<void> _ensureMetadataFill() {
    if (_disposed || !_metadataForeground || _metadataUserPaused) {
      return Future.value();
    }
    final existing = _metadataFlight;
    if (existing != null) return existing;
    // Defer notifications until after the current widget build/import callback.
    final future = Future<void>.microtask(_drainMetadataFill);
    _metadataFlight = future;
    future.whenComplete(() {
      if (identical(_metadataFlight, future)) _metadataFlight = null;
      if (!_disposed &&
          _metadataRequested &&
          _metadataAutomaticPending &&
          _metadataForeground &&
          !_metadataUserPaused &&
          metadataFillError == null &&
          !metadataFillWaitingForSource) {
        unawaited(_ensureMetadataFill());
      }
    });
    return future;
  }

  Future<void> _drainMetadataFill() async {
    if (_disposed || !_metadataForeground || _metadataUserPaused) return;
    final generation = ++_metadataGeneration;
    final attempted = <String>{};
    var consecutiveFailures = 0;
    var connectionStopped = false;
    final clock = Stopwatch()..start();
    var lastNotification = Duration.zero;
    metadataFillCompleted = 0;
    metadataFillFailed = 0;
    metadataFillTotal = 0;
    metadataFillWaitingForSource = false;
    metadataFillError = null;
    try {
      do {
        _metadataRequested = false;
        final pending = savedItems(mode: AppMode.manga)
            .where(
              (entry) =>
                  needsMetadata(entry.item) &&
                  !attempted.contains(entry.item.key),
            )
            .toList(); // Store orders newest saved works first, as native does.
        metadataFillTotal = metadataFillCompleted + pending.length;
        if (pending.isEmpty) break;
        if (selectedSource(AppMode.manga) == null) {
          metadataFillWaitingForSource = true;
          changed();
          return;
        }
        metadataFillRunning = true;
        changed();
        for (final entry in pending) {
          if (!_metadataCanContinue(generation)) return;
          attempted.add(entry.item.key);
          try {
            final remote = await detail(entry.item, recordOpen: false);
            if (!_metadataCanContinue(generation)) return;
            final current = saved(entry.item);
            if (current != null) {
              final updated = _mergeMissingMetadata(current.item, remote);
              // Save useful metadata even if cover fetching later fails.
              store.saveItem(updated);
              if (_metadataCoverCache != null) {
                // Persist before the await, including pause/background/process
                // termination while an image request is still outstanding.
                _metadataCoverFailures.add(updated.key);
                _persistMetadataCoverFailures();
                await _metadataCoverCache!(updated);
                if (!_metadataCanContinue(generation)) return;
                _metadataCoverFailures.remove(updated.key);
                _persistMetadataCoverFailures();
              }
              if (needsMetadata(updated)) {
                throw const ContentException('Invalid work metadata.');
              }
            }
            consecutiveFailures = 0;
          } catch (error) {
            if (!_metadataCanContinue(generation)) return;
            metadataFillFailed++;
            // A missing work is isolated. Repeated transport/access failures
            // stop an offline library from spending hours on identical timeouts.
            if (error is ContentException &&
                const {404, 410}.contains(error.statusCode)) {
              consecutiveFailures = 0;
            } else {
              consecutiveFailures++;
            }
            connectionStopped = consecutiveFailures >= 3;
          }
          metadataFillCompleted++;
          if (metadataFillCompleted >= metadataFillTotal ||
              clock.elapsed - lastNotification >=
                  const Duration(milliseconds: 300)) {
            lastNotification = clock.elapsed;
            changed();
          }
          if (connectionStopped) break;
          // One request/cover at a time, without decoding the entire library.
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      } while (!connectionStopped &&
          _metadataRequested &&
          _metadataCanContinue(generation));
      if (!_metadataCanContinue(generation)) return;
      _persistMetadataCoverFailures();
      if (metadataFillFailed > 0) {
        metadataFillError = 'Some information could not be filled. Check the connection and retry.';
      } else {
        _metadataAutomaticPending = false;
        store.setSetting('metadata.fillPending', false);
      }
    } catch (_) {
      if (_disposed || generation != _metadataGeneration) return;
      metadataFillError = 'Some information could not be filled. Check the connection and retry.';
    } finally {
      if (!_disposed && generation == _metadataGeneration) {
        metadataFillRunning = false;
        changed();
      }
    }
  }

  bool _metadataCanContinue(int generation) =>
      !_disposed &&
      generation == _metadataGeneration &&
      _metadataForeground &&
      !_metadataUserPaused;

  void _persistMetadataCoverFailures() => store.setSetting(
    'metadata.coverRetryIds',
    _metadataCoverFailures.toList(),
  );

  ContentItem _mergeMissingMetadata(ContentItem existing, ContentItem remote) {
    if (remote.id != existing.id || remote.mode != AppMode.manga) {
      throw const ContentException('Invalid work metadata.');
    }
    final payload = remote.toJson();
    if (existing.title.trim().isNotEmpty &&
        existing.title != '#${existing.id}') {
      payload['title'] = existing.title;
    }
    if (existing.thumbnailUrl != null) {
      payload['thumbnailUrl'] = existing.thumbnailUrl.toString();
    }
    if (existing.tags.isNotEmpty) payload['tags'] = existing.tags;
    if (existing.artists.isNotEmpty) payload['artists'] = existing.artists;
    payload['metadata'] = {...remote.metadata, ...existing.metadata};
    return ContentItem.fromJson(payload);
  }

  void pauseMetadataFill() {
    _metadataGeneration++;
    _metadataUserPaused = true;
    _metadataRequested = false;
    metadataFillRunning = false;
    metadataFillWaitingForSource = false;
    store.setSetting('metadata.fillPaused', true);
    changed();
  }

  void dismissMetadataFillNotice() {
    metadataFillNoticeDismissed = true;
    changed();
  }

  void save(ContentItem item, {List<String>? folderIds, String? note}) {
    final wasSaved = store.isSaved(item.key);
    store.transaction(() {
      store.saveItem(item, folderIds: folderIds, note: note);
      if (!wasSaved) taste.record('save', item);
      _knownSavedKeys.add(item.key);
    });
    changed();
  }

  void unsave(ContentItem item) {
    if (!store.isSaved(item.key)) return;
    store.transaction(() {
      store.removeItem(item.key);
      taste.record('remove', item);
      _knownSavedKeys.remove(item.key);
    });
    changed();
  }

  LibraryFolder createFolder(String name, {AppMode? mode, int? color}) {
    final folder = store.createFolder(
      name,
      id: newId('folder'),
      mode: mode ?? this.mode,
      color: color,
    );
    changed();
    return folder;
  }

  void updateFolder(LibraryFolder folder) {
    store.saveFolder(folder);
    changed();
  }

  void deleteFolder(LibraryFolder folder) {
    store.deleteFolder(folder.id);
    changed();
  }

  void saveArtist(ArtistEntry artist) {
    store.saveArtist(artist);
    changed();
  }

  void removeArtist(ArtistEntry artist) {
    store.removeArtist(artist);
    changed();
  }

  void clearHistory(AppMode mode) {
    store.clearHistory(mode);
    changed();
  }

  int readingPosition(ContentItem item) => store.progress(item.key);
  void saveReadingPosition(ContentItem item, int page) =>
      store.setProgress(item.key, page);
  static int _sequence = 0;
  static String newId(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
  static String errorMessage(Object e) => e is ContentException
      ? e.message
      : e is FormatException
      ? e.message
      : 'Unable to load. Check the connection and try again.';
  @override
  void dispose() {
    _disposed = true;
    _metadataGeneration++;
    for (final source in _clients.values) {
      source.close();
    }
    _clients.clear();
    super.dispose();
  }
}
