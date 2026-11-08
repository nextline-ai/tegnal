// `RecentWorksTests` and the Safe Mode server rule from native-ios/TEGNALTests.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/content/reading_queue.dart';
import 'package:tegnal/core/content/recent_works.dart';
import 'package:tegnal/core/storage/work_query.dart';
import 'package:tegnal/core/support/preferences.dart';

void main() {
  late Directory covers;
  setUp(() => covers = Directory.systemTemp.createTempSync('recent-works'));
  tearDown(() {
    if (covers.existsSync()) covers.deleteSync(recursive: true);
  });

  RecentWork work(int id, {String title = '', List<String> tags = const []}) => RecentWork(
    item: ReadingQueueItem(id: id, title: title.isEmpty ? 'Work $id' : title, artists: '', details: ''),
    openedAt: DateTime.fromMillisecondsSinceEpoch(id * 1000),
    language: 'korean',
    type: 'manga',
    tags: tags,
  );

  test('recent works keep the newest first up to the chosen count', () async {
    final preferences = MemoryPreferences();
    final recents = RecentWorks(preferences, covers: covers);
    expect(recents.limit, 50, reason: 'Fifty works unless changed');
    for (var id = 1; id <= 70; id++) {
      recents.opened(work(id));
    }
    expect(recents.entries.length, 50);
    expect(recents.entries.first.id, 70);
    expect(recents.entries.last.id, 21);

    recents.opened(work(30), cover: Future.value(Uint8List.fromList([1, 2, 3])));
    expect(recents.entries.first.id, 30, reason: 'Opening a work again moves it to the top');
    expect(recents.entries.where((entry) => entry.id == 30).length, 1);
    await Future<void>.delayed(Duration.zero);
    expect(recents.cover(30), [1, 2, 3]);

    recents.setLimit(20);
    expect(recents.entries.length, 20, reason: 'A lower count drops the oldest at once');
    expect(RecentWorks(preferences, covers: covers).entries.map((entry) => entry.id), recents.entries.map((entry) => entry.id));

    recents.setLimit(900);
    expect(recents.limit, 500, reason: 'Five hundred at most');

    recents.setLimit(0);
    expect(recents.entries, isEmpty, reason: "Don't Keep clears the list");
    recents.opened(work(99));
    expect(recents.entries, isEmpty, reason: 'and keeps nothing new');
  });

  test('recent works are searched as Saved is', () {
    final entry = work(7, title: 'Summer Trip', tags: ['female:glasses', 'artist:someone', 'tag:school']);
    expect(entry.matches(WorkQuery('summer')), isTrue);
    expect(entry.matches(WorkQuery('female:glasses')), isTrue);
    expect(entry.matches(WorkQuery('artist:someone summer')), isTrue);
    expect(entry.matches(WorkQuery('language:korean')), isTrue);
    expect(entry.matches(WorkQuery('7')), isTrue);
    expect(entry.matches(WorkQuery('-female:glasses')), isFalse);
    expect(entry.matches(WorkQuery('female:glass')), isFalse, reason: 'A namespaced term matches a whole tag');
    expect(entry.matches(WorkQuery('winter')), isFalse);
  });

  test('recent images keep their own count', () {
    final preferences = MemoryPreferences();
    final recents = RecentImages(preferences);
    expect(recents.limit, 50);
    recents.setLimit(0);
    expect(RecentImages(preferences).limit, 0);
  });

  test('Safe Mode goes to Safebooru and rates only other servers', () {
    final store = BooruStore.inMemory();
    store.selectSafebooru();
    expect(store.selectedServers.map((server) => server.isSafebooru), [true]);
    expect(store.needsSafeRating, isFalse, reason: 'Safebooru is searched without a rating tag');
    store.selectSafebooru();
    expect(store.servers.where((server) => server.isSafebooru).length, 1, reason: 'An existing Safebooru is reused');
    final other = BooruServer(id: 'other', name: 'Other', baseURL: 'https://images.example', engine: BooruEngine.danbooru);
    store.saveServer(other);
    store.select(other);
    expect(store.needsSafeRating, isTrue);

    // Saved images show only when their rating fits; Safebooru's always do.
    final safebooruID = store.servers.firstWhere((server) => server.isSafebooru).id;
    BooruPost post(String server, int id, String rating) =>
        BooruPost(serverID: server, postID: id, width: 1, height: 1, tags: ['scenery'], artists: const [], rating: rating, score: 0, fileExtension: 'jpg');
    for (final saved in [post('other', 1, 'g'), post('other', 2, 'explicit'), post('other', 3, 'general'), post(safebooruID, 4, 'q')]) {
      store.saveFavorite(saved);
    }
    BooruSafeRating? rating = BooruSafeRating.general;
    store.safeRating = () => rating;
    expect(store.visibleFavorites().map((post) => post.postID).toSet(), {1, 3, 4});
    rating = BooruSafeRating.questionable;
    store.safeModeChanged();
    expect(store.visibleFavorites().map((post) => post.postID).toSet(), {4});
    rating = null;
    store.safeModeChanged();
    expect(store.visibleFavorites().map((post) => post.postID).toSet(), {1, 2, 3, 4}, reason: 'Without Safe Mode every saved image shows');
  });
}
