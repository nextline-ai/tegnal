import 'package:flutter/foundation.dart';

import '../data/booru_source.dart';
import '../data/library_store.dart';
import '../data/manga_source.dart';
import 'content.dart';
import 'content_filter.dart';
import 'library.dart';

typedef SourceFactory = ContentSource Function(SourceConfig);

class ExploreState {
  final Map<String, int> sourcePages = {};
  final Set<String> exhaustedSources = {};
  List<ContentItem> items = [];
  String query = '';
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
  }
  final LibraryStore store;
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
  String get appearance => store.setting('appearance', 'system') as String;
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
  List<SearchEntry> history([AppMode? value]) => store.history(value ?? mode);
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
    mode = value;
    store.setSetting('mode', value.name);
    changed();
  }

  void setPreference(String key, dynamic value) {
    store.setSetting(key, value);
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

  void libraryRestored() {
    for (final m in AppMode.values) {
      _resetExplore(m);
    }
    for (final client in _clients.values) {
      client.close();
    }
    _clients.clear();
    changed();
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
            final nextPage = (state.sourcePages[source.id] ?? 0) + 1;
            final ContentPage result;
            if (m == AppMode.booru && adapter is SortedContentSource) {
              result = await (adapter as SortedContentSource).searchSorted(
                state.query,
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
                state.query,
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

  Future<ContentItem> detail(ContentItem item) async {
    final source =
        sourceById(item.sourceId) ??
        (item.mode == AppMode.manga ? selectedSource(AppMode.manga) : null);
    if (source == null) {
      throw const ContentException(
        'Connect this work’s source in Settings first.',
      );
    }
    return client(source).detail(item.id);
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

  void save(ContentItem item, {List<String>? folderIds, String? note}) {
    store.saveItem(item, folderIds: folderIds, note: note);
    changed();
  }

  void unsave(ContentItem item) {
    store.removeItem(item.key);
    changed();
  }

  LibraryFolder createFolder(
    String name, {
    AppMode? mode,
    int color = 0xFF5E5CE6,
  }) {
    final m = mode ?? this.mode;
    final folder = LibraryFolder(
      id: newId('folder'),
      mode: m,
      name: name,
      color: color,
      position: folders(m).length,
    );
    store.saveFolder(folder);
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
    for (final source in _clients.values) {
      source.close();
    }
    _clients.clear();
    super.dispose();
  }
}
