import 'dart:async';
import 'dart:io';

import '../../core/booru/booru_models.dart';
import '../../core/booru/booru_store.dart';
import '../../core/content/content_environment.dart';
import '../../core/content/gallery_content.dart';
import '../../core/content/manga_content_source.dart';
import '../../core/content/manga_urls.dart';
import '../../core/storage/app_database.dart';
import '../../core/storage/app_storage.dart';
import '../../core/storage/folder_rules.dart';
import '../../core/support/l10n.dart';
import '../../core/support/swift_json.dart';
import '../../core/taste/taste_models.dart';
import 'page_image_store.dart';

/// Lets a removal made by accident come back to where it was, for as long as the app runs.
class RemovedBookmark {
  const RemovedBookmark({required this.folders, this.note});
  final List<int> folders;
  final String? note;
}

/// What the native `AppEnvironment` keeps for bookmarks during a run: removals that can be
/// undone, the folder each save went to, and the hooks a save starts.
class BookmarkSession {
  BookmarkSession({required this.database, required this.content, this.startCoverQueue, this.isTesting = false});

  final AppDatabase database;
  final ContentEnvironment content;

  /// Fills covers and information of saved works in the background (arrives with saved works).
  final void Function()? startCoverQueue;

  /// Fixture runs and tests do not start the cover queue, as in the native app.
  final bool isTesting;

  final Map<int, RemovedBookmark> removedBookmarks = {};

  /// The folder each work saved this session went to, which Change Folder moves it out of.
  final Map<int, int> savedFolders = {};

  /// Mirrors a bookmark change to the account's favorites when that is turned on.
  void syncAccountFavorite(int id, {required bool saved}) {
    if (!content.syncsAccountFavorites || !content.siteAccountSignedIn || !MangaUrls.hasResolvedBackend || MangaUrls.backend != MangaBackend.keyed) return;
    unawaited(MangaContentSource.shared.setAccountFavorite(id, saved: saved).catchError((Object _) {}));
  }
}

/// Bookmarking a comic from Explore, work information or the reader.
abstract final class ContentBookmarkAction {
  /// [site] is the website the work is shown from, the checked one unless given, kept as where
  /// it was saved from: the work has the same number everywhere, but not every website carries it.
  static WorkSaveResult toggle(int id, {NativeGallery? gallery, required BookmarkSession session, PageImageStore? images, DiscoveryContext? context, String? site}) {
    final website = site ?? ComicSites.active;
    final database = session.database;
    final work = database.getWork(id);
    if (work != null) {
      final folders = database.folderIDs(id);
      database.deleteWork(id);
      session.removedBookmarks[id] = RemovedBookmark(folders: folders, note: work.note);
      if (website == ComicSites.active) session.syncAccountFavorite(id, saved: false);
      return const WorkSaveResult.removed(TasteMode.comics);
    }
    return save(id, gallery: gallery, session: session, images: images, context: context, site: website);
  }

  static WorkSaveResult save(int id, {NativeGallery? gallery, required BookmarkSession session, PageImageStore? images, DiscoveryContext? context, String? site}) {
    final website = site ?? ComicSites.active;
    final database = session.database;
    if (database.getWork(id) != null) return const WorkSaveResult.unchanged(TasteMode.comics);
    final removed = session.removedBookmarks.remove(id);
    final existing = {for (final folder in database.listFolders()) ?folder.id};
    final restored = (removed?.folders ?? const <int>[]).where(existing.contains).toList();
    final folder = restored.firstOrNull ?? database.defaultSaveFolder().id;
    if (folder != null) session.savedFolders[id] = folder;
    database.upsertWork(
      galleryId: id,
      folderId: folder,
      title: gallery?.title,
      artists: gallery?.artists.join(', '),
      language: gallery?.language,
      type: gallery?.type,
      tags: gallery?.tags.join(', '),
      metadataSource: 'remote',
      site: website,
      discoveryContext: context ?? DiscoveryContext.unknown,
    );
    for (final other in restored.skip(1)) {
      database.addWork(id, other);
    }
    final note = removed?.note;
    if (note != null) database.setNote(id, note);
    if (website == ComicSites.active) session.syncAccountFavorite(id, saved: true);
    final page = gallery?.pages.firstOrNull;
    if (page != null && images != null) unawaited(_storeCover(id, page, session: session, images: images));
    if (!session.isTesting) session.startCoverQueue?.call();
    return const WorkSaveResult.added(TasteMode.comics);
  }

  /// Keeps the cover the person just saw as the saved work's thumbnail.
  static Future<void> _storeCover(int id, GalleryPage page, {required BookmarkSession session, required PageImageStore images}) async {
    try {
      final data = await images.data(page, galleryID: id, thumbnail: true);
      if (session.database.getWork(id) == null) return;
      final file = File('${AppStorage.thumbsDir.path}/native_$id.jpg');
      await file.writeAsBytes(data, flush: true);
      session.database.setThumb(id, 'ready', path: file.path, page: 1);
    } on Object {
      if (!session.isTesting) session.startCoverQueue?.call();
    }
  }
}

/// Shared result and presentation for saves from feeds, recommendations and readers.
class WorkSaveResult {
  const WorkSaveResult.added(TasteMode this.mode) : kind = WorkSaveKind.added;
  const WorkSaveResult.removed(TasteMode this.mode) : kind = WorkSaveKind.removed;
  const WorkSaveResult.unchanged(TasteMode this.mode) : kind = WorkSaveKind.unchanged;
  const WorkSaveResult.failed() : kind = WorkSaveKind.failed, mode = null;

  final WorkSaveKind kind;
  final TasteMode? mode;

  static String accessibilityValue({required bool saved, required TasteMode mode}) =>
      L10n.text(mode == TasteMode.comics ? (saved ? 'Bookmarked' : 'Not bookmarked') : (saved ? 'Saved' : 'Not favorited'));

  static String actionTitle({required bool saved, required TasteMode mode}) =>
      L10n.text(mode == TasteMode.comics ? (saved ? 'Remove Bookmark' : 'Bookmark') : (saved ? 'Remove Favorite' : 'Add Favorite'));

  String get message => switch ((kind, mode)) {
    (WorkSaveKind.added, TasteMode.comics) => L10n.text('Saved to bookmarks'),
    (WorkSaveKind.removed, TasteMode.comics) => L10n.text('Bookmark removed'),
    (WorkSaveKind.unchanged, _) => L10n.text('Already bookmarked'),
    (WorkSaveKind.added, TasteMode.booru) => L10n.text('Saved to Favorites'),
    (WorkSaveKind.removed, TasteMode.booru) => L10n.text('Favorite removed'),
    _ => L10n.text('Unable to save. Please try again.'),
  };

  /// SF Symbol name of the notice icon.
  String get icon => switch ((kind, mode)) {
    (WorkSaveKind.added || WorkSaveKind.unchanged, TasteMode.comics) => 'bookmark.fill',
    (WorkSaveKind.removed, TasteMode.comics) => 'bookmark.slash',
    (WorkSaveKind.added || WorkSaveKind.unchanged, TasteMode.booru) => 'heart.fill',
    (WorkSaveKind.removed, TasteMode.booru) => 'heart.slash',
    _ => 'exclamationmark.circle',
  };

  /// The icon's color: yellow, pink, secondary or orange.
  WorkSaveColor get color => switch ((kind, mode)) {
    (WorkSaveKind.added || WorkSaveKind.unchanged, TasteMode.comics) => WorkSaveColor.yellow,
    (WorkSaveKind.added || WorkSaveKind.unchanged, TasteMode.booru) => WorkSaveColor.pink,
    (WorkSaveKind.removed, _) => WorkSaveColor.secondary,
    _ => WorkSaveColor.orange,
  };

  /// The haptic a native save plays.
  WorkSaveHaptic get haptic => switch (kind) {
    WorkSaveKind.added => WorkSaveHaptic.success,
    WorkSaveKind.removed || WorkSaveKind.unchanged => WorkSaveHaptic.selection,
    WorkSaveKind.failed => WorkSaveHaptic.error,
  };

  @override
  bool operator ==(Object other) => other is WorkSaveResult && other.kind == kind && other.mode == mode;
  @override
  int get hashCode => Object.hash(kind, mode);
  @override
  String toString() => 'WorkSaveResult.${kind.name}(${mode?.name ?? ''})';
}

enum WorkSaveKind { added, removed, unchanged, failed }

enum WorkSaveColor { yellow, pink, secondary, orange }

enum WorkSaveHaptic { success, selection, error }

/// The notice a save shows at the bottom for 3 seconds, or 5 with Change Folder.
class WorkSaveFeedback {
  WorkSaveFeedback(this.result, {int? galleryID, this.folder})
    : id = uuidString(),
      galleryID = result == const WorkSaveResult.added(TasteMode.comics) ? galleryID : null;

  final String id;
  final WorkSaveResult result;

  /// The saved comic, while its folder can still be changed from this notice.
  final int? galleryID;

  /// Names the folder a person just chose for the work.
  final String? folder;

  String get message => folder == null ? result.message : L10n.text("Saved to folder '%@'", [folder!]);

  /// How long the notice stays: longer while it offers Change Folder.
  Duration get duration => Duration(seconds: galleryID == null ? 3 : 5);

  static WorkSaveFeedback perform(WorkSaveResult Function() action, {int? galleryID}) {
    try {
      return WorkSaveFeedback(action(), galleryID: galleryID);
    } on Object {
      return WorkSaveFeedback(const WorkSaveResult.failed());
    }
  }
}

/// Favoriting an image from the viewer or recommendations.
abstract final class BooruFavoriteAction {
  static WorkSaveResult toggle(BooruPost post, {required BooruStore store, DiscoveryContext? context}) {
    store.toggleFavorite(post, context: context);
    return store.isFavorite(post) ? const WorkSaveResult.added(TasteMode.booru) : const WorkSaveResult.removed(TasteMode.booru);
  }
}
