import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/challenge/challenge_models.dart';
import 'package:tegnal/core/challenge/challenge_store.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/support/swift_json.dart';

/// The first native preset server, with an example address in place of a site.
BooruServer presetServer() => BooruServer(id: 'preset-one', name: 'Preset One', baseURL: 'https://alpha.example', engine: BooruEngine.danbooru);

/// `BooruFixtureSource.post(_:server:tags:)`.
BooruPost fixturePost(int id, BooruServer server, {List<String> tags = const ['scenery', 'mountain']}) => BooruPost(
  serverID: server.id,
  postID: id,
  previewURL: 'https://fixture.invalid/preview.png',
  sampleURL: 'https://fixture.invalid/sample.png',
  fileURL: 'https://fixture.invalid/original.png',
  width: 1600,
  height: 1200,
  tags: tags,
  artists: ['sample_artist'],
  rating: 'g',
  score: 42,
  fileExtension: id == 104
      ? 'gif'
      : id == 105
      ? 'mp4'
      : 'png',
  poolIDs: [77],
);

/// The game `ChallengeTests` builds from the croquis example.
ChallengeDefinition testGame() {
  final game = ChallengeDefinition.croquis();
  game.reels[0].options = [
    ChallengeOption(text: 'Subject', tags: ['scenery']),
  ];
  game.reels[1].options = [ChallengeOption(text: 'Method')];
  game.goal
    ..mode = ChallengeGoalMode.count
    ..count = const ChallengeRange(minimum: 1, maximum: 1);
  return game;
}

/// A value copy, as Swift structs are.
ChallengeDefinition copyGame(ChallengeDefinition game) => ChallengeDefinition.fromJson(decodeJsonObject(encodeJson(game.toJson())));

/// Compares challenges the way `Equatable` does, field by field.
String gameJson(ChallengeDefinition game) => encodeJsonString(game.toJson());

/// `LibraryBackupTests.populated()`.
(AppDatabase, BooruStore, ChallengeDefinition) populated() {
  final comics = AppDatabase.inMemory(), images = BooruStore.inMemory();
  final folder = comics.createFolder(name: 'Reading', color: 0xFF123456, sourceGroupId: 42);
  comics.upsertWork(galleryId: 1234, folderId: folder.id, title: 'Comic', artists: 'Artist', tags: 'tag:test');
  comics.setNote(1234, 'Keep this note');
  comics.setThumbPage(1234, 3);
  comics.addFavoriteArtist('Artist');
  comics.recordSearch('saved query');
  comics.toggleSavedSearch('favorite query');
  comics.dbWriter.write((db) {
    db.execute("UPDATE works SET thumb_path = '/private/local-cache.jpg' WHERE gallery_id = 1234");
    db.execute("UPDATE artists SET note = 'Artist note' WHERE name = 'Artist'");
  });
  final server = presetServer();
  images.saveServer(server);
  final imageFolder = images.saveFolder(name: 'References');
  images.setFolderColor(imageFolder, 0xFFABCDEF);
  images.saveFavorite(fixturePost(72, server), folderID: imageFolder);
  images.recordSearch('scenery', serverID: server.id);
  images.toggleTag('scenery', serverID: server.id, kind: 'tag');
  images.setBlacklist('gore', serverID: server.id);
  final game = ChallengeDefinition.croquis();
  ChallengeStore(images).save(game);
  return (comics, images, game);
}
