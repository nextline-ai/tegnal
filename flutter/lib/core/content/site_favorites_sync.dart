import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../storage/app_database.dart';
import '../storage/folder_rules.dart';
import '../support/preferences.dart';
import 'combined_catalog.dart';
import 'content_environment.dart';
import 'gallery_content.dart';
import 'manga_urls.dart';
import 'site_account.dart';

/// `SiteFavoriteFolders`: the app folder each signed-in website's favorites are kept in step with,
/// named after the website, and what both held after the last sync, which tells a change on one
/// side from a change on the other. Kept as JSON text, since stored preferences hold only plain values.
class SiteFavoriteFolders {
  SiteFavoriteFolders(this._preferences);

  static SiteFavoriteFolders get shared => SiteFavoriteFolders(ContentPreferences.defaults);

  final Preferences _preferences;
  static const _linksKey = 'manga.siteFavoriteFolders';
  static const _baselinesKey = 'manga.siteFavoriteBaselines';
  static const _declinedKey = 'manga.siteFavoriteFoldersDeclined';
  static const _pulledKey = 'manga.siteFavoritePulled';

  Map<String, Object?> _map(String key) {
    final text = _preferences.string(key);
    if (text == null) return {};
    try {
      final value = jsonDecode(text);
      return value is Map<String, Object?> ? value : {};
    } on FormatException {
      return {};
    }
  }

  void _setMap(String key, Map<String, Object?> value) => _preferences.set(key, jsonEncode(value));

  Set<String> get _declined {
    final stored = _preferences.object(_declinedKey);
    return stored is List ? stored.whereType<String>().toSet() : {};
  }

  /// The linked folder's sync identity.
  String? folder(String site) => _map(_linksKey)[site] as String?;
  List<String> get linkedSites => _map(_linksKey).keys.toList()..sort();

  /// Links a folder; its first sync takes both sides as they are.
  void link(String site, String folder) {
    _setMap(_linksKey, {..._map(_linksKey), site: folder});
    _setMap(_baselinesKey, {..._map(_baselinesKey)}..remove(site));
    _preferences.set(_declinedKey, (_declined..remove(site)).toList()..sort());
  }

  /// Stops syncing a website. Turned off by hand, it is not set up again on its own.
  void unlink(String site, {required bool declined}) {
    _setMap(_linksKey, {..._map(_linksKey)}..remove(site));
    _setMap(_baselinesKey, {..._map(_baselinesKey)}..remove(site));
    if (declined) _preferences.set(_declinedKey, (_declined..add(site)).toList()..sort());
  }

  bool isDeclined(String site) => _declined.contains(site);

  /// The works both sides held after the last sync; null before the first.
  Set<int>? baseline(String site) {
    final ids = _map(_baselinesKey)[site];
    return ids is List ? ids.whereType<int>().toSet() : null;
  }

  void setBaseline(Set<int> ids, String site) => _setMap(_baselinesKey, {..._map(_baselinesKey), site: ids.toList()..sort()});

  /// When the website's favorites were last read, so reading them again waits a while.
  DateTime? lastPull(String site) {
    final seconds = _map(_pulledKey)[site];
    return seconds is num ? DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round()) : null;
  }

  void notePull(String site, [DateTime? at]) => _setMap(_pulledKey, {..._map(_pulledKey), site: (at ?? DateTime.now()).millisecondsSinceEpoch / 1000});
}

/// `FavoriteSyncPlan`: what one sync changes on each side. A work in the baseline that one side no
/// longer has was removed there; one that is new on a side was added there. The other side follows.
class FavoriteSyncPlan {
  const FavoriteSyncPlan({
    this.addLocally = const [],
    this.removeLocally = const [],
    this.addOnSite = const [],
    this.removeFromSite = const [],
    this.settled = const {},
  });

  final List<int> addLocally;
  final List<int> removeLocally;
  final List<int> addOnSite;
  final List<int> removeFromSite;

  /// Both sides once the plan is carried out.
  final Set<int> settled;

  bool get isEmpty => addLocally.isEmpty && removeLocally.isEmpty && addOnSite.isEmpty && removeFromSite.isEmpty;

  /// [remote] is what the website holds now; passing the baseline instead only sends local changes.
  /// Without a baseline nothing is removed: the first sync adds each side's works to the other.
  static FavoriteSyncPlan make({required Set<int> local, required Set<int> remote, required Set<int>? base}) {
    final known = base ?? const <int>{};
    List<int> sorted(Iterable<int> ids) => ids.toList()..sort();
    final addLocally = sorted(remote.difference(known).difference(local));
    final removeLocally = sorted(known.difference(remote).intersection(local));
    return FavoriteSyncPlan(
      addLocally: addLocally,
      removeLocally: removeLocally,
      addOnSite: sorted(local.difference(known).difference(remote)),
      removeFromSite: sorted(known.difference(local).intersection(remote)),
      settled: local.union(addLocally.toSet()).difference(removeLocally.toSet()),
    );
  }
}

/// `SiteFavoritesSync`: keeps each signed-in website's favorites and the folder named after it the
/// same while the app is open. The first time a website's favorites can be read, the folder is made
/// (or the one already named so is used) and filled with them.
class SiteFavoritesSync extends ChangeNotifier {
  SiteFavoritesSync({required this.database, required this.content, this.startCoverQueue, this.linksOverride, SiteContent Function(String site)? siteContent})
    : _siteContent = siteContent ?? SiteContent.of;

  final AppDatabase database;
  final ContentEnvironment content;
  final void Function()? startCoverQueue;

  /// Tests pass their own; the app reads the shared one.
  final SiteFavoriteFolders? linksOverride;
  final SiteContent Function(String site) _siteContent;
  final _syncing = <String>{};
  StreamSubscription<int>? _changes;
  Timer? _settle;

  /// Set at launch, so settings and sign-in reach the one the app runs.
  static SiteFavoritesSync? shared;

  SiteFavoriteFolders get links => linksOverride ?? SiteFavoriteFolders.shared;

  /// A website's signed-in account that can keep favorites, by host; null without one.
  String? accountHost(String site) {
    final host = SiteScope.run(site, () => MangaUrls.configuredHost);
    if (host.isEmpty || !SiteAccount.isSignedInAt(host) || SiteAccount.refusesAccess(host)) return null;
    return host;
  }

  /// The linked folder's database row, or null when it is not linked or was deleted.
  int? folderID(String site) {
    final identity = links.folder(site);
    return identity == null ? null : database.folderIDForIdentity(identity);
  }

  /// Sets up the folder once; turned off by hand, only [requested] sets it up again.
  Future<void> setUp(String site, {bool requested = false}) async {
    if (links.folder(site) != null || (!requested && links.isDeclined(site)) || accountHost(site) == null) return;
    // Read before anything is made, so a website that keeps the account out gets no folder.
    final Set<int> remote;
    try {
      remote = await _allFavorites(site);
    } on Object {
      return;
    }
    final folder = database.listFolders().where((folder) => folder.name == site).firstOrNull ?? database.createFolder(name: site);
    final id = folder.id;
    if (id == null) return;
    links.link(site, database.identityOfFolder(id));
    notifyListeners();
    await sync(site, remote: remote);
  }

  /// Stops keeping a website's favorites and its folder the same; both keep what they hold.
  void stop(String site) {
    links.unlink(site, declined: true);
    notifyListeners();
  }

  /// Every page of a website's favorites, across its categories.
  Future<Set<int>> _allFavorites(String site) async {
    final source = _siteContent(site);
    final ids = <int>{};
    String? next;
    var pages = 0;
    do {
      final (page, cursor) = await source.accountFavorites(after: next);
      ids.addAll(page);
      next = cursor;
      pages += 1;
    } while (next != null && pages < 500);
    return ids;
  }

  /// Brings a website's favorites and its folder into step: what was added or removed on one side
  /// since the last sync is added or removed on the other. [pull] reads the website's favorites
  /// again; without it only changes made in the app are sent.
  Future<FavoriteSyncPlan?> sync(String site, {bool pull = true, Set<int>? remote}) async {
    if (links.folder(site) == null || accountHost(site) == null) return null;
    final folder = folderID(site);
    if (folder == null) {
      // The folder was deleted: syncing stops, and the website's favorites stay as they are.
      stop(site);
      return null;
    }
    if (!_syncing.add(site)) return null;
    try {
      final base = links.baseline(site);
      final Set<int> answer;
      if (remote != null) {
        answer = remote;
        links.notePull(site);
      } else if (pull || base == null) {
        answer = await _allFavorites(site);
        links.notePull(site);
      } else {
        answer = base;
      }
      // Read after the website answers, so a change made meanwhile is not lost.
      final local = database.galleryIDsInFolder(folder).toSet();
      final plan = FavoriteSyncPlan.make(local: local, remote: answer, base: base);
      final settled = {...plan.settled};
      // Recorded first, so the folder changes below are not taken for new ones made by hand.
      links.setBaseline(settled, site);
      final source = _siteContent(site);
      for (final id in plan.addLocally) {
        if (database.getWork(id) != null) {
          database.addWork(id, folder);
          continue;
        }
        final NativeGallery? work = source.cachedPreview(id);
        database.upsertWork(
          galleryId: id,
          folderId: folder,
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
      for (final id in plan.removeLocally) {
        database.removeWorkFromFolder(id, folder);
      }
      // A failed request leaves the rest for the next sync instead of asking again and again.
      var failed = false;
      final category = content.accountFavoriteCategory;
      for (final id in plan.addOnSite) {
        if (!failed) {
          try {
            await source.setAccountFavorite(id, saved: true, category: category);
            continue;
          } on Object {
            failed = true;
          }
        }
        settled.remove(id);
      }
      for (final id in plan.removeFromSite) {
        if (!failed) {
          try {
            await source.setAccountFavorite(id, saved: false, category: category);
            continue;
          } on Object {
            failed = true;
          }
        }
        settled.add(id);
      }
      links.setBaseline(settled, site);
      if (plan.addLocally.isNotEmpty) startCoverQueue?.call();
      notifyListeners();
      return plan;
    } finally {
      _syncing.remove(site);
    }
  }

  /// While the app is in front: sets up folders for websites signed in since, reads each website's
  /// favorites again when it has not for half an hour, and sends folder changes made in the app.
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
        if (links.folder(site) == null) {
          await setUp(site);
        } else if ((links.lastPull(site) ?? DateTime(2000)).isBefore(DateTime.now().subtract(const Duration(minutes: 30)))) {
          await sync(site);
        }
      } on Object {
        // The next time the app comes to the front tries again.
      }
    }
  }

  Future<void> _sendChanges() async {
    for (final site in links.linkedSites) {
      final folder = folderID(site), base = links.baseline(site);
      if (folder == null || base == null) continue;
      if (setEquals(database.galleryIDsInFolder(folder).toSet(), base)) continue;
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
