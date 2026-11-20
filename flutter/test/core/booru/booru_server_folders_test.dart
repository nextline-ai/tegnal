// Ported from `BooruServerFolderTests`: folders belong to servers; each server has its own folders,
// starting with Uncategorized, and a global folder is shown and takes images whichever servers are chosen.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_backup.dart';
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/storage/folder_palette.dart';
import 'package:tegnal/core/storage/folder_rules.dart';
import 'package:tegnal/core/support/l10n.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/support/swift_json.dart';

import '../../support/fixtures.dart' as fixtures;

void main() {
  final danbooru = BooruServer(id: 'd', name: 'Danbooru', baseURL: 'https://danbooru.donmai.us', engine: BooruEngine.danbooru);
  final gelbooru = BooruServer(id: 'g', name: 'Gelbooru', baseURL: 'https://gelbooru.com', engine: BooruEngine.gelbooru);
  BooruPost post(int id, BooruServer server) => fixtures.post(id, server, tags: const ['scenery']);
  String uncategorized(BooruServer server) => 'site:${server.canonicalAddress}';

  /// A library from before folder ownership, as the version before this one left it.
  String legacyLibrary() {
    final directory = Directory.systemTemp.createTempSync('tegnal-folders-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/booru.sqlite';
    final store = BooruStore(path: path, preferences: AppPreferences.memory());
    store.saveServer(danbooru);
    store.saveServer(gelbooru);
    store.database.write((db) {
      db.execute('DELETE FROM folders');
      db.execute('ALTER TABLE folders DROP COLUMN server_id');
      db.execute("DELETE FROM grdb_migrations WHERE identifier = 'booru_v13_server_folders'");
      db.execute('DELETE FROM settings WHERE key = ?', [BooruFolderStyle.key]);
      final folders = [
        ('unsorted', '', FolderPalette.unsorted),
        (uncategorized(danbooru), 'danbooru.donmai.us', FolderPalette.colors[1]),
        ('mixed', 'Mixed', FolderPalette.colors[2]),
        ('empty', 'Empty', FolderPalette.colors[3]),
        ('only-g', 'Only Gelbooru', FolderPalette.colors[4]),
      ];
      for (final (position, (id, name, color)) in folders.indexed) {
        db.execute('INSERT INTO folders VALUES (?, ?, ?, ?)', [id, name, color, position]);
      }
      final saved = [
        (post(1, danbooru), 'unsorted'),
        (post(2, gelbooru), 'unsorted'),
        (post(3, danbooru), uncategorized(danbooru)),
        (post(4, danbooru), 'mixed'),
        (post(5, gelbooru), 'mixed'),
        (post(6, gelbooru), 'only-g'),
      ];
      for (final (index, (value, folder)) in saved.indexed) {
        db.execute('INSERT INTO favorites (server_id, post_id, payload, saved_at, folder_id) VALUES (?, ?, ?, ?, ?)', [
          value.serverID,
          value.postID,
          encodeSwiftJson(value.toJson()),
          index.toDouble(),
          folder,
        ]);
      }
      final rule = FolderRule(folder: 'mixed', query: 'scenery', sources: ['unsorted']);
      db.execute('INSERT INTO settings VALUES (?, ?)', ['${FolderRule.keyPrefix}mixed', encodeSwiftJsonString(rule.toJson())]);
    });
    store.database.close();
    return path;
  }

  test('the update keeps folders shared until each server is chosen to have its own', () {
    final path = legacyLibrary();
    final store = BooruStore(path: path, preferences: AppPreferences.memory());
    final copy = 'mixed@${gelbooru.canonicalAddress}';
    expect(store.folder('unsorted'), isNull, reason: "the shared Uncategorized splits into each server's own");
    expect(store.folderIDFor(post(1, danbooru)), uncategorized(danbooru));
    expect(store.folderIDFor(post(2, gelbooru)), uncategorized(gelbooru));
    expect(store.folderIDFor(post(3, danbooru)), uncategorized(danbooru), reason: "the server's own folder is its Uncategorized");
    expect(store.folder(uncategorized(danbooru))?.plainName, L10n.text('Uncategorized'));
    expect(store.folder(uncategorized(danbooru))?.color, FolderPalette.colors[1], reason: 'keeping its color');
    // Nothing else changes until the person chooses.
    expect(store.folderStylePending, isTrue);
    expect(store.folderStyle, BooruFolderStyle.shared);
    expect(store.folder('mixed')?.serverID, isNull, reason: 'a folder of several servers stays shared');
    expect(store.folderIDFor(post(4, danbooru)), 'mixed');
    expect(store.folderIDFor(post(5, gelbooru)), 'mixed');
    expect(store.folder('only-g')?.serverID, isNull);
    expect(store.folder(copy), isNull);
    expect(store.rule('mixed')?.sources?.toSet(), {uncategorized(danbooru), uncategorized(gelbooru)});
    expect(store.folderStyleImpact(), (folders: 2, mixed: 1));
    expect(store.newFolderServer(danbooru.id), isNull, reason: 'a new folder is shared too');

    // Each server's own folders: the folder goes to the server whose address comes first.
    store.adoptFolderStyle(BooruFolderStyle.byServer);
    expect(store.folderStylePending, isFalse);
    expect(store.folderIDFor(post(4, danbooru)), 'mixed');
    expect(store.folderIDFor(post(5, gelbooru)), copy);
    expect(store.folder('mixed')?.serverID, danbooru.id);
    expect(store.folder(copy)?.serverID, gelbooru.id);
    expect(store.folder(copy)?.plainName, 'Mixed');
    expect(store.folder(copy)?.color, FolderPalette.colors[2], reason: 'the same name and color in each server');
    expect(store.folder('only-g')?.serverID, gelbooru.id);
    expect(store.folder('empty')?.serverID, isNull, reason: 'a folder holding nothing stays global, shown as before');
    expect(store.rule('mixed')?.sources, [uncategorized(danbooru)]);
    expect(store.rule(copy)?.sources, [uncategorized(gelbooru)]);
    expect(store.newFolderServer(danbooru.id), danbooru.id);

    // Back to shared folders: the copy joins the folder it came from.
    store.adoptFolderStyle(BooruFolderStyle.shared);
    expect(store.folder(copy), isNull);
    expect(store.folderIDFor(post(5, gelbooru)), 'mixed');
    expect(store.folder('mixed')?.serverID, isNull);
    expect(store.folder('only-g')?.serverID, isNull);
    expect(store.folder(uncategorized(danbooru))?.serverID, danbooru.id, reason: 'each server keeps its Uncategorized');
    final ids = store.folders().map((folder) => folder.id).toList();
    store.database.close();
    final reopened = BooruStore(path: path, preferences: AppPreferences.memory());
    expect(reopened.folderStyle, BooruFolderStyle.shared);
    expect(reopened.folderStylePending, isFalse);
    expect(reopened.folders().map((folder) => folder.id), ids, reason: 'reopening changes nothing more');
  });

  test("a new library starts with each server's own folders, and favorites lists stay with their server", () {
    final store = BooruStore.inMemory();
    store.saveServer(danbooru);
    store.saveServer(gelbooru);
    expect(store.folderStylePending, isFalse, reason: "a library with nothing to change isn't asked");
    expect(store.folderStyle, BooruFolderStyle.byServer);
    final list = store.saveFolder(name: 'Group', serverID: danbooru.id);
    final mine = store.saveFolder(name: 'Mine', serverID: danbooru.id);
    store.adoptFolderStyle(BooruFolderStyle.shared, kept: {list});
    expect(store.folder(list)?.serverID, danbooru.id, reason: "a folder kept with the server's favorites stays its own");
    expect(store.folder(mine)?.serverID, isNull);
  });

  test("saved shows the chosen servers' folders and the global ones", () {
    final store = BooruStore.inMemory();
    store.saveServer(danbooru);
    store.saveServer(gelbooru);
    store.setSelectedServers([danbooru.id]);
    final mine = store.saveFolder(name: 'Cats', serverID: danbooru.id);
    final theirs = store.saveFolder(name: 'Cats', serverID: gelbooru.id);
    final global = store.saveFolder(name: 'Everything');
    expect(store.visibleFolders().map((folder) => folder.id).toSet(), {uncategorized(danbooru), mine, global});
    store.setSelectedServers([danbooru.id, gelbooru.id]);
    expect(store.visibleFolders().map((folder) => folder.id).toSet(), {uncategorized(danbooru), uncategorized(gelbooru), mine, theirs, global});
    expect(store.serverNameOfFolder(store.folder(theirs)!), 'Gelbooru');
    expect(store.serverNameOfFolder(store.folder(global)!), isNull);
    expect(() => store.saveFavorite(post(1, gelbooru), folderID: mine), throwsA(isA<BooruError>()));
    store.saveFavorite(post(1, gelbooru), folderID: global);
    store.saveFavorite(post(2, danbooru), folderID: global);
    store.moveFavorites([post(1, gelbooru), post(2, danbooru)], mine);
    expect(store.folderIDFor(post(2, danbooru)), mine);
    expect(store.folderIDFor(post(1, gelbooru)), global, reason: "another server's image stays where it was");
    expect(store.foldersForServer(gelbooru.id).map((folder) => folder.id).toSet(), {uncategorized(gelbooru), theirs, global});
    store.setSelectedServers([gelbooru.id]);
    expect(store.visibleFavorites(query: 'scenery').map((value) => value.id).toSet(), {post(1, gelbooru).id});
  });

  test('a global folder turned back stays in each server it holds images of', () {
    final store = BooruStore.inMemory();
    store.saveServer(danbooru);
    store.saveServer(gelbooru);
    final folder = store.saveFolder(name: 'Wallpapers', serverID: danbooru.id);
    store.setGlobal(folder, true);
    expect(store.folder(folder)!.isGlobal, isTrue);
    store.saveFavorite(post(1, danbooru), folderID: folder);
    store.saveFavorite(post(2, gelbooru), folderID: folder);
    store.setGlobal(folder, false, emptyServer: gelbooru.id);
    final copy = '$folder@${gelbooru.canonicalAddress}';
    expect(store.folder(folder)?.serverID, danbooru.id);
    expect(store.folderIDFor(post(2, gelbooru)), copy);
    expect(store.folder(copy)?.plainName, 'Wallpapers');
    final empty = store.saveFolder(name: 'Later');
    store.setGlobal(empty, false, emptyServer: gelbooru.id);
    expect(store.folder(empty)?.serverID, gelbooru.id);
    store.setGlobal(uncategorized(danbooru), true);
    expect(store.folder(uncategorized(danbooru))?.serverID, danbooru.id, reason: 'Uncategorized is never global');
  });

  test('each server saves where it is told and falls back to uncategorized', () {
    final store = BooruStore.inMemory();
    store.saveServer(danbooru);
    final favorites = store.saveFolder(name: 'Favorites', serverID: danbooru.id);
    store.saveServer(BooruServer(id: danbooru.id, name: danbooru.name, baseURL: danbooru.baseURL, engine: danbooru.engine, saveFolder: favorites));
    store.toggleFavorite(post(1, danbooru));
    expect(store.folderIDFor(post(1, danbooru)), favorites);
    store.deleteFolder(favorites);
    expect(store.folderIDFor(post(1, danbooru)), uncategorized(danbooru), reason: "a deleted save folder's images go to Uncategorized");
    store.toggleFavorite(post(2, danbooru));
    expect(store.folderIDFor(post(2, danbooru)), uncategorized(danbooru));
  });

  test('devices that split differently end up with one folder per server', () {
    final store = BooruStore.inMemory();
    store.saveServer(danbooru);
    store.saveServer(gelbooru);
    final folder = store.saveFolder(name: 'Mixed', serverID: gelbooru.id);
    final copy = '$folder@${gelbooru.canonicalAddress}';
    store.database.write((db) => db.execute("INSERT INTO folders (id, name, color, position, server_id) VALUES (?, 'Mixed', 1, 5, ?)", [copy, gelbooru.id]));
    store.saveFavorite(post(1, gelbooru), folderID: copy);
    store.database.write(BooruStore.settleFolders);
    store.refresh();
    expect(store.folder(copy), isNull);
    expect(store.folderIDFor(post(1, gelbooru)), folder);
  });

  test('an older backup splits like the update', () {
    final store = BooruStore.inMemory();
    store.saveServer(danbooru);
    store.saveServer(gelbooru);
    final backup = BooruBackup(
      servers: [danbooru, gelbooru],
      folders: [
        BooruBackupFolder(id: 'unsorted', name: '', color: FolderPalette.unsorted),
        BooruBackupFolder(id: 'mixed', name: 'Mixed', color: FolderPalette.colors[2]),
      ],
      favorites: [
        BooruBackupFavorite(post: post(1, danbooru), folderID: 'mixed', savedAt: 1),
        BooruBackupFavorite(post: post(2, gelbooru), folderID: 'mixed', savedAt: 2),
        BooruBackupFavorite(post: post(3, gelbooru), folderID: 'unsorted', savedAt: 3),
      ],
      history: const [],
      savedTags: const [],
      blacklist: const {},
      selectedServerIDs: const [],
    );
    store.restoreBackup(backup);
    expect(store.folder('unsorted'), isNull);
    expect(store.folderIDFor(post(1, danbooru)), 'mixed');
    expect(store.folderIDFor(post(2, gelbooru)), 'mixed@${gelbooru.canonicalAddress}');
    expect(store.folderIDFor(post(3, gelbooru)), uncategorized(gelbooru));
    final again = BooruStore.inMemory();
    again.restoreBackup(BooruBackup.decode(store.exportBackup().encoded()));
    expect(
      again.folder('mixed@${gelbooru.canonicalAddress}')?.serverID,
      again.servers.firstWhere((server) => server.canonicalAddress == gelbooru.canonicalAddress).id,
    );
  });
}
