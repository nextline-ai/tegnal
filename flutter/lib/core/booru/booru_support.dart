import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier;

import '../content/manga_urls.dart';
import '../support/l10n.dart';
import '../support/preferences.dart';
import '../taste/taste_models.dart';
import 'booru_browser.dart';
import 'booru_client.dart';
import 'booru_models.dart';
import 'booru_store.dart';

/// The launch warmup's image-mode pages (`LaunchFeedWarmup`), which the first feed may use.
abstract interface class BooruLaunchPages {
  Future<BooruBatch> booruPage(BooruServer server, String query, BooruSort sort, {bool initialConsumer = false});
  void didPublishBooru(BooruServer server, String query, BooruSort sort);
  Future<void> invalidateBooru(BooruServer server, String query, BooruSort sort);
}

/// The image grid's posts across the selected servers, page by page.
class BooruFeedLoader extends ChangeNotifier {
  List<BooruPost> posts = [];
  List<BooruPost> visiblePosts = [];
  bool loading = false;
  bool didLoad = false;
  String? contentID;
  bool unsupportedSort = false;
  Map<String, String> errors = {};

  String? get error => errors.values.firstOrNull;
  bool get hasMore => _remaining.any((id) => !errors.containsKey(id));

  var _pages = <String, int>{};
  var _pageFingerprints = <String, List<int>>{};
  var _remaining = <String>{};
  var _generation = 0;
  int? _cancelled;
  var _blacklistText = <String, String>{};
  var _blacklists = <String, BooruBlacklist>{};
  var _excludedPostIDs = <String>{};

  static const _mapEquality = MapEquality<String, String>();
  static const _setEquality = SetEquality<String>();
  static const _listEquality = ListEquality<int>();

  void setExcludedPostIDs(Set<String> ids) {
    if (_setEquality.equals(ids, _excludedPostIDs)) return;
    _excludedPostIDs = {...ids};
    _updateVisiblePosts();
    notifyListeners();
  }

  void setBlacklists(Map<String, String> text) {
    if (_mapEquality.equals(text, _blacklistText)) return;
    _blacklistText = {...text};
    _blacklists = text.map((key, value) => MapEntry(key, BooruBlacklist(value)));
    _updateVisiblePosts();
    notifyListeners();
  }

  void _publish(List<BooruPost> values) {
    if (const ListEquality<BooruPost>().equals(posts, values)) return;
    posts = values;
    _updateVisiblePosts();
  }

  void _updateVisiblePosts() {
    visiblePosts = _blacklists.values.every((blacklist) => blacklist.rules.isEmpty) && _excludedPostIDs.isEmpty
        ? posts
        : posts.where((post) => !_excludedPostIDs.contains(post.id) && !(_blacklists[post.serverID]?.contains(post) ?? false)).toList();
  }

  var _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  /// Stops the load in progress without changing what is shown, as cancelling its task does.
  void cancel() {
    if (!loading) return;
    _cancelled = _generation;
    loading = false;
    notifyListeners();
  }

  Future<void> load({
    required List<BooruServer> servers,
    required BooruProviding source,
    required String query,
    int? poolID,
    BooruSort sort = BooruSort.latest,
    required bool reset,
    String? contentID,
    BooruLaunchPages? startup,
    bool useLaunchPage = false,
    void Function(String serverID, List<int> postIDs)? onGoldRestricted,
  }) async {
    if (!reset && (loading || !hasMore)) return;
    if (reset) _generation += 1;
    final token = _generation;
    bool stale() => token != _generation || _cancelled == token;
    unsupportedSort = false;
    final nextPages = reset ? <String, int>{} : {..._pages};
    final nextFingerprints = reset ? <String, List<int>>{} : {..._pageFingerprints};
    final nextPosts = reset ? <BooruPost>[] : [...posts];
    final seen = nextPosts.map((post) => post.id).toSet();
    final nextErrors = reset ? <String, String>{} : {...errors};
    final nextRemaining = reset ? servers.map((server) => server.id).toSet() : {..._remaining};
    final requests = [
      for (final server in servers)
        if (nextRemaining.contains(server.id) && !nextErrors.containsKey(server.id)) (server, nextPages[server.id] ?? 0),
    ];
    loading = true;
    notifyListeners();
    try {
      final results = StreamController<(String, BooruBatch?, String?)>();
      var pending = requests.length;
      if (pending == 0) unawaited(results.close());
      for (final (server, page) in requests) {
        () async {
          try {
            final BooruBatch batch;
            if (poolID != null) {
              batch = await source.poolPosts(server, poolID, page);
            } else if (reset && useLaunchPage && startup != null) {
              batch = await startup.booruPage(server, query, sort, initialConsumer: true);
            } else {
              if (reset && startup != null) await startup.invalidateBooru(server, query, sort);
              batch = await BooruSortValidation.posts(source: source, server: server, query: query, page: page, sort: sort);
            }
            return (server.id, batch, null);
          } on UnsupportedBooruSort {
            return (server.id, null, 'unsupported-sort');
          } catch (error) {
            return (server.id, null, BooruConnectionMessage.describe(error));
          }
        }().then((result) {
          results.add(result);
          if (--pending == 0) results.close();
        });
      }
      await for (final (id, batch, error) in results.stream) {
        if (stale()) return;
        if (error == 'unsupported-sort') {
          unsupportedSort = true;
          continue;
        }
        if (batch != null) {
          if (batch.goldRestrictedIDs.isNotEmpty) onGoldRestricted?.call(id, batch.goldRestrictedIDs);
          final incoming = batch.posts.where((post) => seen.add(post.id)).toList();
          nextPosts.addAll(incoming);
          if (poolID == null && nextPosts.isNotEmpty && nextPosts.every((post) => sort.metric(post) != null)) {
            mergeSort(
              nextPosts,
              compare: (a, b) {
                final left = sort.metric(a)!, right = sort.metric(b)!;
                return left == right ? a.id.compareTo(b.id) : right.compareTo(left);
              },
            );
          }
          nextPages[id] = (nextPages[id] ?? 0) + 1;
          final fingerprint = [...batch.posts.map((post) => post.postID), ...batch.goldRestrictedIDs]..sort();
          final previous = nextFingerprints[id];
          if (!batch.hasMore ||
              batch.sourcePostCount == 0 ||
              previous != null && _listEquality.equals(previous, fingerprint) ||
              !reset && incoming.isEmpty && batch.goldRestrictedIDs.isEmpty) {
            nextRemaining.remove(id);
          }
          nextFingerprints[id] = fingerprint;
        } else {
          nextErrors[id] = error!;
        }
        // Publish each server as it finishes so slow hosts do not delay the first images.
        // Popular sorting stays atomic until every server validates the requested sort.
        if (sort == BooruSort.latest && !unsupportedSort && nextPosts.isNotEmpty) {
          _publish([...nextPosts]);
          _pages = {...nextPages};
          _pageFingerprints = {...nextFingerprints};
          errors = {...nextErrors};
          _remaining = {...nextRemaining};
          this.contentID = contentID;
          didLoad = true;
          if (reset && useLaunchPage && batch != null) {
            final server = servers.where((value) => value.id == id).firstOrNull;
            if (server != null) startup?.didPublishBooru(server, query, sort);
          }
          notifyListeners();
        }
      }
      // A cancelled refresh must never replace a populated feed with an empty one.
      if (stale() || unsupportedSort) return;
      _publish(nextPosts);
      _pages = nextPages;
      _pageFingerprints = nextFingerprints;
      errors = nextErrors;
      _remaining = nextRemaining;
      this.contentID = contentID;
      didLoad = true;
      if (reset && useLaunchPage) {
        for (final server in servers) {
          if (nextPages.containsKey(server.id)) startup?.didPublishBooru(server, query, sort);
        }
      }
    } finally {
      if (token == _generation && _cancelled != token) loading = false;
      notifyListeners();
    }
  }
}

/// Keeps viewer pagination in shared state so an in-flight response reads the latest
/// lifecycle, rather than the one captured when it started.
class BooruViewerPagination extends ChangeNotifier {
  bool _active = false;
  bool _loading = false;
  bool _hasMore = true;
  String? _requestedFromID;

  bool get isActive => _active;
  set isActive(bool value) {
    _active = value;
    notifyListeners();
  }

  bool get hasMore => _hasMore;
  set hasMore(bool value) {
    _hasMore = value;
    notifyListeners();
  }

  bool get isLoading => _loading;
  String? get requestedFromID => _requestedFromID;
  bool get wantsNext => _requestedFromID != null;

  void requestAdvance(String id) {
    _requestedFromID = id;
    notifyListeners();
  }

  void cancelAdvance() {
    _requestedFromID = null;
    notifyListeners();
  }

  bool beginRequest() {
    if (!_active || _loading || !_hasMore) return false;
    _loading = true;
    notifyListeners();
    return true;
  }

  void finishRequest() {
    _loading = false;
    notifyListeners();
  }

  bool takeAdvance({required String currentID, required bool nextExists}) {
    final requested = _requestedFromID;
    if (requested == null) return false;
    if (requested != currentID) {
      cancelAdvance();
      return false;
    }
    if (!_active) return false;
    if (!nextExists) {
      if (!_loading) cancelAdvance();
      return false;
    }
    cancelAdvance();
    return true;
  }
}

sealed class BooruViewerDestination {
  const BooruViewerDestination();
}

class BooruViewerPost extends BooruViewerDestination {
  const BooruViewerPost(this.index);
  final int index;
  @override
  bool operator ==(Object other) => other is BooruViewerPost && other.index == index;
  @override
  int get hashCode => index.hashCode;
}

class BooruViewerLoadMore extends BooruViewerDestination {
  const BooruViewerLoadMore();
  @override
  bool operator ==(Object other) => other is BooruViewerLoadMore;
  @override
  int get hashCode => 1;
}

class BooruViewerClose extends BooruViewerDestination {
  const BooruViewerClose();
  @override
  bool operator ==(Object other) => other is BooruViewerClose;
  @override
  int get hashCode => 2;
}

/// Where the viewer goes when the shown post turns out restricted or removed.
class BooruViewerAccessNavigation {
  BooruViewerAccessNavigation({Set<String> removedIDs = const {}}) : _restrictedIDs = {...removedIDs};

  final Set<String> _restrictedIDs;
  String? _pendingID;
  int _direction = 1;
  bool _enteredByNavigation = false;
  bool _requestedMore = false;

  Set<String> get restrictedIDs => Set.unmodifiable(_restrictedIDs);
  String? get pendingID => _pendingID;
  int get direction => _direction;
  bool get enteredByNavigation => _enteredByNavigation;

  void moved(int delta) {
    if (delta != 0) {
      _direction = delta < 0 ? -1 : 1;
      _enteredByNavigation = true;
    }
    _pendingID = null;
    _requestedMore = false;
  }

  void restrict(String id) {
    _restrictedIDs.add(id);
    if (_pendingID == id) return;
    _pendingID = id;
    _requestedMore = false;
  }

  bool removed(String id) {
    _restrictedIDs.add(id);
    if (!_enteredByNavigation) return false;
    restrict(id);
    return true;
  }

  void recordRemovals(List<BooruPost> posts) => _restrictedIDs.addAll(posts.where((post) => post.isRemoved).map((post) => post.id));

  int? candidate(List<String> ids, {required int startingAt, required int direction, required Set<String> excluding}) {
    var index = startingAt;
    while (index >= 0 && index < ids.length) {
      if (!_restrictedIDs.contains(ids[index]) && !excluding.contains(ids[index])) return index;
      index += direction < 0 ? -1 : 1;
    }
    return null;
  }

  BooruViewerDestination destination(List<String> ids, {required int current, required bool canLoadMore, required Set<String> excluding}) {
    final next = candidate(ids, startingAt: current + _direction, direction: _direction, excluding: excluding);
    if (next != null) return BooruViewerPost(next);
    if (_direction > 0 && canLoadMore && !_requestedMore) {
      _requestedMore = true;
      return const BooruViewerLoadMore();
    }
    final previous = candidate(ids, startingAt: current - _direction, direction: -_direction, excluding: excluding);
    if (previous != null) return BooruViewerPost(previous);
    if (canLoadMore && !_requestedMore) {
      _requestedMore = true;
      return const BooruViewerLoadMore();
    }
    return const BooruViewerClose();
  }
}

abstract final class BooruFailureNavigation {
  /// A horizontal swipe over the failure page: 1 for the next post, -1 for the previous.
  static int? swipe(double dx, double dy) {
    if (dx.abs() <= 50 || dx.abs() <= dy.abs() * 1.3) return null;
    return dx < 0 ? 1 : -1;
  }
}

abstract final class BooruViewerReturn {
  /// The post the grid scrolls to after the viewer closes: the last one viewed, when it
  /// differs from the opened one and the grid still shows it.
  static String? targetID({required String? openedID, required String viewedID, required Iterable<String> availableIDs}) {
    if (openedID == null || viewedID == openedID || !availableIDs.contains(viewedID)) return null;
    return viewedID;
  }
}

/// Native storage survives media replacement and viewer reopening.
class BooruVideoAudioPreferences {
  BooruVideoAudioPreferences(this.defaults);
  final Preferences defaults;
  bool get muted => defaults.boolean('booru.videoMuted') ?? true;
  void update({required bool muted}) => defaults.set('booru.videoMuted', muted);
}

/// What an entered website address turned out to be.
sealed class ServerType {
  const ServerType();

  static const comics = ComicsServerType();
  static BooruServerType booru(BooruEngine engine) => BooruServerType(engine);

  String get id;
  String get title;

  /// Recognizes a website by its own response: comics protocols by their page structure,
  /// galleries by the software signature their pages carry.
  static ServerType? recognizing(String html) {
    if (MangaUrls.isDocumentPage(html) || MangaUrls.isIndexedPage(html)) return comics;
    if (RegExp(r'''Danbooru\.|content=["']Danbooru''').hasMatch(html)) return booru(BooruEngine.danbooru);
    if (RegExp(r'Gelbooru\s+Beta\s+0\.1\.11', caseSensitive: false).hasMatch(html)) return booru(BooruEngine.oldGelbooru);
    if (html.toLowerCase().contains('moebooru')) return booru(BooruEngine.moebooru);
    if (html.toLowerCase().contains('gelbooru')) return booru(BooruEngine.gelbooru);
    return null;
  }

  /// Loads the website's home page with [loadHTML] and recognizes it. The native app also
  /// recognizes a few named hosts without loading them; here every site is identified by its response.
  static Future<ServerType?> detect(Uri url, {required Future<String> Function(Uri url) loadHTML}) async => recognizing(await loadHTML(url));

  @override
  bool operator ==(Object other) => other is ServerType && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

class ComicsServerType extends ServerType {
  const ComicsServerType();
  @override
  String get id => 'comics';
  @override
  String get title => L10n.text('Comics Mode');
}

class BooruServerType extends ServerType {
  const BooruServerType(this.engine);
  final BooruEngine engine;
  @override
  String get id => engine.rawValue;
  @override
  String get title => engine.title;
}

/// The image-mode half of `WebsiteConnectionEditor.save`.
abstract final class BooruServerConnection {
  /// Saves a server from the editor's fields and selects a new one alongside the others.
  /// Throws [BooruError] for an invalid address, a duplicate, or account details with one half missing.
  static BooruServer save({
    required BooruStore store,
    BooruServer? existing,
    required String address,
    required BooruEngine engine,
    String name = '',
    String account = '',
    String apiKey = '',
  }) {
    final url = BooruServer.validatedURL(address);
    final displayName = name.trim();
    final host = Uri.tryParse(url)?.host;
    final value = BooruServer(
      id: existing?.id,
      name: displayName.isEmpty ? (host == null || host.isEmpty ? url : host) : displayName,
      baseURL: url,
      engine: engine,
    );
    if (store.servers.any((server) => server.id != value.id && server.baseURL == url)) throw const BooruError(BooruErrorKind.duplicateServer);
    final credentials = BooruCredentials(account: account.trim(), apiKey: apiKey.trim());
    if (credentials.account.isEmpty != credentials.apiKey.isEmpty) throw const BooruError(BooruErrorKind.authentication);
    store.credentials.save(credentials, value.id);
    store.saveServer(value);
    if (existing == null) store.setSelectedServers([...store.selectedServerIDs, value.id]);
    return value;
  }
}

enum BooruFavoriteToggle { added, removed }

/// `BooruFavoriteAction`: toggles a favorite and says which way it went, for the save toast.
abstract final class BooruFavoriteAction {
  static BooruFavoriteToggle toggle(BooruPost post, BooruStore store, DiscoveryContext context) {
    store.toggleFavorite(post, context: context);
    return store.isFavorite(post) ? BooruFavoriteToggle.added : BooruFavoriteToggle.removed;
  }
}
