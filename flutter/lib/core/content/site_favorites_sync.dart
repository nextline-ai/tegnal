import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../storage/app_database.dart';
import '../storage/folder_rules.dart';
import '../support/preferences.dart';
import 'combined_catalog.dart';
import 'content_environment.dart';
import 'content_errors.dart';
import 'gallery_content.dart';
import 'keyed_work_extras.dart';
import 'manga_urls.dart';
import 'site_account.dart';

/// `FavoritePlace`: where a saved work sits for a website's favorites: a category's (or list's)
/// folder, or anywhere else.
class FavoritePlace {
  const FavoritePlace.category(int this.category);
  const FavoritePlace._unassigned() : category = null;
  static const unassigned = FavoritePlace._unassigned();

  final int? category;

  /// A work in a category's folder is not also "anywhere else".
  static Set<FavoritePlace> normalized(Set<FavoritePlace> places) => places.any((place) => place.category != null) ? places.difference({unassigned}) : places;

  @override
  bool operator ==(Object other) => other is FavoritePlace && other.category == category;
  @override
  int get hashCode => category.hashCode;
  @override
  String toString() => category == null ? 'unassigned' : 'category($category)';
}

/// What `SiteFavoriteFolders` keeps for one website.
class SiteFavoriteState {
  SiteFavoriteState({Map<int, String>? folders, this.unassigned, this.baseline, Set<int>? localOnly, this.lastPull, this.exclusive})
    : folders = folders ?? {},
      localOnly = localOnly ?? {};

  /// Favorites category or list → the sync identity of its folder.
  final Map<int, String> folders;

  /// Where works in other folders are kept on the website: a category the account left empty, or
  /// one chosen in settings. Null keeps them in the app only.
  int? unassigned;

  /// The categories holding each work after the last sync; null before the first.
  Map<int, Set<int>>? baseline;

  /// Works never sent to the website: saved before the sync began, or ones it cannot keep.
  final Set<int> localOnly;
  DateTime? lastPull;

  /// Whether a favorite sits in one category at a time; null reads as true.
  bool? exclusive;

  Map<String, Object?> toJson() => {
    'folders': {for (final MapEntry(:key, :value) in folders.entries) '$key': value},
    'unassigned': ?unassigned,
    if (baseline case final baseline?) 'baseline': {for (final MapEntry(:key, :value) in baseline.entries) '$key': value.toList()..sort()},
    'localOnly': localOnly.toList()..sort(),
    if (lastPull case final lastPull?) 'lastPull': lastPull.millisecondsSinceEpoch / 1000,
    'exclusive': ?exclusive,
  };

  static SiteFavoriteState? fromJson(Object? json) {
    if (json is! Map) return null;
    Set<int> ints(Object? list) => list is List ? list.whereType<num>().map((value) => value.toInt()).toSet() : {};
    final folders = <int, String>{};
    if (json['folders'] case final Map map) {
      for (final MapEntry(:key, :value) in map.entries) {
        final category = int.tryParse('$key');
        if (category != null && value is String) folders[category] = value;
      }
    }
    Map<int, Set<int>>? baseline;
    if (json['baseline'] case final Map map) {
      baseline = {for (final MapEntry(:key, :value) in map.entries) ?int.tryParse('$key'): ints(value)};
    }
    final pulled = json['lastPull'];
    return SiteFavoriteState(
      folders: folders,
      unassigned: (json['unassigned'] as num?)?.toInt(),
      baseline: baseline,
      localOnly: ints(json['localOnly']),
      lastPull: pulled is num ? DateTime.fromMillisecondsSinceEpoch((pulled * 1000).round()) : null,
      exclusive: json['exclusive'] as bool?,
    );
  }
}

/// `SiteFavoriteFolders`: each signed-in website's favorites categories and the app folders kept in
/// step with them. Kept as JSON text, since stored preferences hold only plain values.
class SiteFavoriteFolders {
  SiteFavoriteFolders(this._preferences);

  static SiteFavoriteFolders get shared => SiteFavoriteFolders(ContentPreferences.defaults);

  final Preferences _preferences;
  static const _statesKey = 'manga.favoriteSync';
  static const _declinedKey = 'manga.favoriteSyncDeclined';

  Map<String, Object?> get _states {
    final text = _preferences.string(_statesKey);
    if (text == null) return {};
    try {
      final value = jsonDecode(text);
      return value is Map<String, Object?> ? value : {};
    } on FormatException {
      return {};
    }
  }

  Set<String> get _declined {
    final stored = _preferences.object(_declinedKey);
    return stored is List ? stored.whereType<String>().toSet() : {};
  }

  /// A website whose favorites are synced, with what was learned about them.
  SiteFavoriteState? state(String site) => SiteFavoriteState.fromJson(_states[site]);

  void setState(SiteFavoriteState state, String site) {
    _preferences.set(_statesKey, jsonEncode({..._states, site: state.toJson()}));
    _preferences.set(_declinedKey, (_declined..remove(site)).toList()..sort());
  }

  List<String> get syncedSites => _states.keys.toList()..sort();

  /// Stops syncing a website. Turned off by hand, it is not set up again on its own.
  void remove(String site, {required bool declined}) {
    _preferences.set(_statesKey, jsonEncode({..._states}..remove(site)));
    if (declined) _preferences.set(_declinedKey, (_declined..add(site)).toList()..sort());
  }

  bool isDeclined(String site) => _declined.contains(site);
}

/// One request a sync sends: a work added to a category (moved there, where a favorite has one) or
/// taken out of it.
class FavoriteSiteChange {
  const FavoriteSiteChange(this.id, this.category, {required this.adds});
  final int id;
  final int category;
  final bool adds;

  @override
  bool operator ==(Object other) => other is FavoriteSiteChange && other.id == id && other.category == category && other.adds == adds;
  @override
  int get hashCode => Object.hash(id, category, adds);
  @override
  String toString() => '${adds ? 'add' : 'remove'}($id, $category)';
}

/// `FavoriteSyncPlan`: what one sync changes on each side. Comparing each work's places with where
/// it was after the last sync tells which side added or took it away; the other side follows, and
/// when both changed the same place, the website wins.
class FavoriteSyncPlan {
  /// The places each saved work ends up in; an empty set removes it from the library.
  final local = <int, Set<FavoritePlace>>{};
  final site = <FavoriteSiteChange>[];

  /// The categories holding each work once the plan is carried out.
  final settled = <int, Set<int>>{};

  /// Works that stop being sent, and works that start being sent again.
  final keepLocal = <int>[];
  final stopKeepingLocal = <int>[];

  bool get isEmpty => local.isEmpty && site.isEmpty;

  /// [local] is where each saved work sits; [remote] the categories holding each favorite, or the
  /// baseline to send only changes made in the app. A category without a folder counts as
  /// anywhere else, and a work kept anywhere else stays in the categories without folders it is in.
  static FavoriteSyncPlan make({
    required Map<int, Set<FavoritePlace>> local,
    required Map<int, Set<int>> remote,
    required Map<int, Set<int>>? base,
    required Set<int> folders,
    required int? unassigned,
    required Set<int> localOnly,
    bool exclusive = true,
  }) {
    Set<FavoritePlace> places(Set<int> categories) =>
        FavoritePlace.normalized({for (final category in categories) folders.contains(category) ? FavoritePlace.category(category) : FavoritePlace.unassigned});
    final plan = FavoriteSyncPlan();
    final ids = {...local.keys, ...remote.keys, ...?base?.keys}.toList()..sort();
    for (final id in ids) {
      final l = FavoritePlace.normalized(local[id] ?? const {});
      final rawRemote = remote[id] ?? const <int>{};
      final r = places(rawRemote);
      var b = base == null ? null : places(base[id] ?? const {});
      if (localOnly.contains(id)) {
        if (rawRemote.isNotEmpty) {
          plan.stopKeepingLocal.add(id);
        } else if (l.any((place) => place.category != null)) {
          // Put in a category folder by hand, it is sent after all.
          plan.stopKeepingLocal.add(id);
          b = {};
        } else {
          continue;
        }
      }
      final Set<FavoritePlace> result;
      if (b case final b?) {
        result = FavoritePlace.normalized({
          for (final place in {...l, ...r, ...b})
            if (l.contains(place) == r.contains(place)
                ? l.contains(place)
                // Changed on the website, or on both sides: the website wins.
                : r.contains(place) != b.contains(place)
                ? r.contains(place)
                : l.contains(place))
              place,
        });
      } else {
        // The library saved before the sync began is not sent all at once.
        if (rawRemote.isEmpty && setEquals(l, {FavoritePlace.unassigned})) {
          plan.keepLocal.add(id);
          continue;
        }
        result = FavoritePlace.normalized({...l, ...r});
      }
      if (!setEquals(result, l) && (result.isNotEmpty || l.isNotEmpty)) plan.local[id] = result;
      // The categories the website should hold the work in.
      var wanted = {for (final place in result) ?place.category};
      if (setEquals(result, {FavoritePlace.unassigned})) {
        // Without a category kept for other folders the work stays in the app, rather than being
        // mixed into a category the account uses for something else.
        final elsewhere = rawRemote.difference(folders);
        if (elsewhere.isNotEmpty) {
          wanted = elsewhere;
        } else if (unassigned != null) {
          wanted = {unassigned};
        }
      } else if (!exclusive && result.isNotEmpty) {
        // Lists without folders keep what they hold; only a work taken away leaves them too.
        wanted.addAll(rawRemote.difference(folders));
      }
      if (exclusive && wanted.length > 1) {
        // The website keeps one: where it already is, else the folder it was just put in.
        final added = wanted.where((category) => !(b ?? const {}).contains(FavoritePlace.category(category))).toList()..sort();
        final chosen = rawRemote.where(wanted.contains).firstOrNull ?? added.firstOrNull ?? (wanted.toList()..sort()).first;
        wanted = {chosen};
      }
      if (setEquals(wanted, rawRemote)) {
        if (wanted.isNotEmpty) plan.settled[id] = wanted;
        continue;
      }
      if (exclusive) {
        if (wanted.isNotEmpty) {
          plan.site.add(FavoriteSiteChange(id, wanted.first, adds: true));
        } else {
          plan.site.add(FavoriteSiteChange(id, (rawRemote.toList()..sort()).first, adds: false));
        }
      } else {
        for (final category in wanted.difference(rawRemote).toList()..sort()) {
          plan.site.add(FavoriteSiteChange(id, category, adds: true));
        }
        for (final category in rawRemote.difference(wanted).toList()..sort()) {
          plan.site.add(FavoriteSiteChange(id, category, adds: false));
        }
      }
      if (wanted.isNotEmpty) plan.settled[id] = wanted;
    }
    return plan;
  }
}

/// `SiteFavoritesSync`: keeps each signed-in website's favorites categories and their folders the
/// same while the app is open. The first time a website's favorites can be read, each category or
/// list that holds works becomes a folder of the same name (or the folder already named so).
class SiteFavoritesSync extends ChangeNotifier {
  SiteFavoritesSync({required this.database, required this.content, this.startCoverQueue, this.storeOverride, SiteContent Function(String site)? siteContent})
    : _siteContent = siteContent ?? SiteContent.of;

  final AppDatabase database;
  final ContentEnvironment content;
  final void Function()? startCoverQueue;

  /// Tests pass their own; the app reads the shared one.
  final SiteFavoriteFolders? storeOverride;
  final SiteContent Function(String site) _siteContent;
  final _syncing = <String>{};
  StreamSubscription<int>? _changes;
  Timer? _settle;

  /// At most this many favorites are changed on a website in one sync; the rest wait for the next.
  static const sendsPerSync = 30;

  /// Set at launch, so settings and sign-in reach the one the app runs.
  static SiteFavoritesSync? shared;

  SiteFavoriteFolders get store => storeOverride ?? SiteFavoriteFolders.shared;

  /// A website's signed-in account that can keep favorites, by host; null without one.
  String? accountHost(String site) {
    final host = SiteScope.run(site, () => MangaUrls.configuredHost);
    if (host.isEmpty || !SiteAccount.isSignedInAt(host) || SiteAccount.refusesAccess(host)) return null;
    return host;
  }

  /// Sets up the folders once; turned off by hand, only [requested] sets it up again.
  Future<void> setUp(String site, {bool requested = false}) async {
    if (store.state(site) != null || (!requested && store.isDeclined(site)) || accountHost(site) == null) return;
    // Read before anything is made, so a website that keeps the account out gets no folders.
    final AccountFavorites favorites;
    try {
      favorites = await _siteContent(site).accountFavoriteLists();
    } on Object {
      return;
    }
    final state = SiteFavoriteState(exclusive: favorites.exclusive);
    final folders = database.listFolders();
    for (final category in favorites.categories.where((category) => category.count > 0)) {
      final folder = folders.where((folder) => folder.name == category.name).firstOrNull ?? database.createFolder(name: category.name);
      final id = folder.id;
      if (id == null) continue;
      state.folders[category.id] = database.identityOfFolder(id);
    }
    state.unassigned = favorites.spareCategory(besides: state.folders.keys.toSet());
    store.setState(state, site);
    notifyListeners();
    await sync(site, remote: favorites);
  }

  /// Stops keeping a website's favorites and its folders the same; both keep what they hold.
  void stop(String site) {
    store.remove(site, declined: true);
    notifyListeners();
  }

  /// The category works in other folders are kept in on the website; null keeps them in the app only.
  void setUnassigned(int? category, String site) {
    final state = store.state(site);
    if (state == null) return;
    state.unassigned = category;
    store.setState(state, site);
    notifyListeners();
  }

  /// Where each saved work sits: the categories' folders it is in, or anywhere else.
  Map<int, Set<FavoritePlace>> _savedPlaces(Map<int, int> folders) {
    final categoryOf = <int, int>{};
    for (final MapEntry(:key, :value) in folders.entries) {
      final known = categoryOf[value];
      if (known == null || key < known) categoryOf[value] = key;
    }
    return database.savedWorkFolders().map((id, inFolders) {
      final categories = {
        for (final folder in inFolders)
          if (categoryOf[folder] case final category?) FavoritePlace.category(category),
      };
      return MapEntry(id, categories.isEmpty ? {FavoritePlace.unassigned} : categories);
    });
  }

  /// Brings a website's favorites and its folders into step: what was added, removed or moved on
  /// one side since the last sync is done on the other. [pull] reads the website's favorites again;
  /// without it only changes made in the app are sent.
  Future<FavoriteSyncPlan?> sync(String site, {bool pull = true, AccountFavorites? remote}) async {
    final state = store.state(site);
    if (state == null || accountHost(site) == null) return null;
    if (!_syncing.add(site)) return null;
    try {
      // A deleted category folder lets its category go; its works were moved to Unfiled.
      final folders = <int, int>{};
      for (final MapEntry(key: category, value: identity) in {...state.folders}.entries) {
        final id = database.folderIDForIdentity(identity);
        if (id != null) {
          folders[category] = id;
        } else {
          state.folders.remove(category);
        }
      }
      final source = _siteContent(site);
      var favorites = remote;
      if (favorites == null && (pull || state.baseline == null)) favorites = await source.accountFavoriteLists();
      final Map<int, Set<int>> answer;
      if (favorites != null) {
        answer = favorites.members;
        state.exclusive = favorites.exclusive;
        state.lastPull = DateTime.now();
        // A category or list removed on the website lets its folder go; the folder keeps its works.
        final existing = {for (final category in favorites.categories) category.id};
        for (final category in state.folders.keys.toList()) {
          if (existing.contains(category)) continue;
          state.folders.remove(category);
          folders.remove(category);
        }
        if (state.unassigned case final unassigned? when !existing.contains(unassigned)) {
          state.unassigned = favorites.spareCategory(besides: state.folders.keys.toSet());
        }
      } else {
        answer = state.baseline ?? const {};
      }
      // Read after the website answers, so a change made meanwhile is not lost.
      final plan = FavoriteSyncPlan.make(
        local: _savedPlaces(folders),
        remote: answer,
        base: state.baseline,
        folders: folders.keys.toSet(),
        unassigned: state.unassigned,
        localOnly: state.localOnly,
        exclusive: state.exclusive ?? true,
      );
      final settled = {...plan.settled};
      state.localOnly
        ..addAll(plan.keepLocal)
        ..removeAll(plan.stopKeepingLocal);
      // Recorded first, so the folder changes below are not taken for new ones made by hand.
      state.baseline = {...settled};
      store.setState(state, site);
      final linked = folders.values.toSet();
      final unfiled = database.unfiledFolderID();
      var placed = false;
      for (final MapEntry(key: id, value: places) in plan.local.entries) {
        if (places.isEmpty) {
          database.deleteWork(id);
          continue;
        }
        placed = true;
        final targets = {for (final place in places) ?folders[place.category]};
        final current = database.folderIDs(id).toSet();
        if (current.isEmpty && database.getWork(id) == null) {
          // A favorite in no category's folder comes to Unfiled.
          final NativeGallery? work = source.cachedPreview(id);
          database.upsertWork(
            galleryId: id,
            folderId: targets.isEmpty ? unfiled : (targets.toList()..sort()).first,
            title: work?.title,
            artists: work?.artists.join(', '),
            language: work?.language,
            type: work?.type,
            tags: work?.tags.join(', '),
            metadataSource: 'remote',
            site: site,
            pageCount: work?.displayedPageCount,
          );
        }
        for (final target in targets.difference(current)) {
          database.addWork(id, target);
        }
        database.removeWorkFromFolders(id, linked.intersection(current).difference(targets));
      }
      // A failed request leaves the rest for the next sync instead of asking again and again.
      var sent = 0;
      var failed = false;
      final refused = <int>{};
      for (final change in plan.site) {
        if (refused.contains(change.id)) continue;
        if (failed || sent >= sendsPerSync) {
          if (answer[change.id] case final before?) {
            settled[change.id] = before;
          } else {
            settled.remove(change.id);
          }
          continue;
        }
        if (sent > 0) await Future<void>.delayed(const Duration(milliseconds: 500));
        sent += 1;
        try {
          await source.changeAccountFavorite(change.id, category: change.category, adds: change.adds);
        } on ContentError catch (error) {
          if (change.adds && (error.kind == ContentErrorKind.galleryNotFound || error.isUnavailable(422))) {
            refused.add(change.id);
          } else {
            failed = true;
            if (answer[change.id] case final before?) {
              settled[change.id] = before;
            } else {
              settled.remove(change.id);
            }
          }
        } on Object {
          failed = true;
          if (answer[change.id] case final before?) {
            settled[change.id] = before;
          } else {
            settled.remove(change.id);
          }
        }
      }
      // A work the website won't keep stays in the app only.
      for (final id in refused) {
        state.localOnly.add(id);
        if (answer[id] case final before?) {
          settled[id] = before;
        } else {
          settled.remove(id);
        }
      }
      state.baseline = settled;
      store.setState(state, site);
      if (placed) startCoverQueue?.call();
      notifyListeners();
      return plan;
    } finally {
      _syncing.remove(site);
    }
  }

  /// While the app is in front: sets up websites signed in since, reads each website's favorites
  /// again when it has not for half an hour, and sends library changes made in the app.
  Future<void> setActive(bool active) async {
    await _changes?.cancel();
    _changes = null;
    _settle?.cancel();
    if (!active) return;
    _changes = database.changes.listen((_) {
      // A moment's wait gathers a burst of changes into one sync.
      _settle?.cancel();
      _settle = Timer(const Duration(seconds: 1), _sendChanges);
    });
    for (final site in ComicSites.all) {
      if (accountHost(site) == null) continue;
      try {
        final state = store.state(site);
        if (state == null) {
          await setUp(site);
        } else if ((state.lastPull ?? DateTime(2000)).isBefore(DateTime.now().subtract(const Duration(minutes: 30)))) {
          await sync(site);
        }
      } on Object {
        // The next time the app comes to the front tries again.
      }
    }
  }

  Future<void> _sendChanges() async {
    for (final site in store.syncedSites) {
      try {
        await sync(site, pull: false);
      } on Object {
        // Left for the next change or the next time the app comes to the front.
      }
    }
  }

  @override
  void dispose() {
    _changes?.cancel();
    _settle?.cancel();
    super.dispose();
  }
}
