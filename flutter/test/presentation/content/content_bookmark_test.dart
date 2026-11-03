// Bookmarks and save notices from native-ios/TEGNALTests/ReaderUXTests.swift.
// testSaveFeedbackUsesSameModeSpecificResultAndRecordsToggle is ported without its first half, which
// saves through a taste recommendation (TasteRecommendationAction arrives with recommendations, step 7).
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/content/content_environment.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/support/l10n.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/taste/taste_models.dart';
import 'package:tegnal/presentation/content/content_bookmark.dart';

BookmarkSession _session() {
  final preferences = AppPreferences.memory();
  return BookmarkSession(
    database: AppDatabase.inMemory(preferences: preferences),
    content: ContentEnvironment.fixture(preferences: preferences.defaults),
    isTesting: true,
  );
}

void main() {
  test('explore bookmark toggles on off and on', () {
    final session = _session();
    const id = 900000001;
    ContentBookmarkAction.toggle(id, session: session);
    expect(session.database.getWork(id), isNotNull);
    expect(ContentBookmarkAction.toggle(id, session: session).message, L10n.text('Bookmark removed'));
    expect(session.database.getWork(id), isNull);
    ContentBookmarkAction.toggle(id, session: session);
    expect(session.database.listWorks().where((work) => work.galleryId == id).length, 1);
  });

  test('bookmark is idempotent and preserves folders', () {
    final session = _session();
    for (final folder in session.database.listFolders()) {
      session.database.deleteFolder(folder.id!);
    }
    expect(ContentBookmarkAction.save(900000001, session: session).message, L10n.text('Saved to bookmarks'));
    expect(ContentBookmarkAction.save(900000001, session: session).message, L10n.text('Already bookmarked'));
    expect(session.database.listWorks().where((work) => work.galleryId == 900000001).length, 1);
    expect(session.database.getWork(900000001)!.folders, isNotEmpty);
  });

  test('a removed bookmark returns to its folders and note', () {
    final session = _session();
    final database = session.database;
    final first = database.createFolder(name: 'First'), second = database.createFolder(name: 'Second');
    database.upsertWork(galleryId: 77, folderId: first.id);
    database.addWorkToFolder(database.getWork(77)!.id!, second.id!);
    database.setNote(77, 'Keep this');
    expect(ContentBookmarkAction.toggle(77, session: session), const WorkSaveResult.removed(TasteMode.comics));
    expect(ContentBookmarkAction.toggle(77, session: session), const WorkSaveResult.added(TasteMode.comics));
    final work = database.getWork(77)!;
    expect(work.folders.map((folder) => folder.name).toSet(), {'First', 'Second'});
    expect(work.note, 'Keep this');
    expect(session.savedFolders[77], first.id);
  });

  test('save feedback uses same mode specific result and records toggle', () {
    final booru = BooruStore.inMemory();
    final server = BooruServer(id: 'preset-one', name: 'Preset One', baseURL: 'https://alpha.example', engine: BooruEngine.danbooru);
    booru.saveServer(server);
    final post = BooruPost(
      serverID: server.id,
      postID: 201,
      width: 1600,
      height: 1200,
      tags: ['blue_hair', 'green_eyes'],
      artists: ['sample_artist'],
      rating: 'g',
      score: 42,
      fileExtension: 'png',
    );
    final saved = BooruFavoriteAction.toggle(
      post,
      store: booru,
      context: DiscoveryContext.recommended('blue_hair', session: 'test'),
    );
    expect(saved, const WorkSaveResult.added(TasteMode.booru));
    expect(saved.message, L10n.text('Saved to Favorites'));
    final removed = BooruFavoriteAction.toggle(
      post,
      store: booru,
      context: DiscoveryContext.recommended('blue_hair', session: 'test'),
    );
    expect(removed, const WorkSaveResult.removed(TasteMode.booru));
    expect(removed.message, L10n.text('Favorite removed'));
    expect(booru.isFavorite(post), isFalse);
    final kinds = booru.database.column<String>('SELECT kind FROM taste_events');
    expect(kinds.where((kind) => kind == 'save').length, 1);
    expect(kinds.where((kind) => kind == 'remove').length, 1);
    final feedback = WorkSaveFeedback.perform(() => throw StateError('failed'));
    expect(feedback.result, const WorkSaveResult.failed());
    expect(WorkSaveFeedback(saved).id, isNot(WorkSaveFeedback(saved).id));
  });

  test('only a new comic save offers change folder for longer', () {
    final added = WorkSaveFeedback(const WorkSaveResult.added(TasteMode.comics), galleryID: 5);
    expect(added.galleryID, 5);
    expect(added.duration, const Duration(seconds: 5));
    final removed = WorkSaveFeedback(const WorkSaveResult.removed(TasteMode.comics), galleryID: 5);
    expect(removed.galleryID, isNull);
    expect(removed.duration, const Duration(seconds: 3));
    expect(
      WorkSaveFeedback(const WorkSaveResult.added(TasteMode.comics), galleryID: 5, folder: 'Reading').message,
      L10n.text("Saved to folder '%@'", ['Reading']),
    );
  });
}
