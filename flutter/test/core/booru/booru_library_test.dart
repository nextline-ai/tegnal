// Ported from native-ios/TEGNALTests/BooruLibraryTests.swift.
//
// The anime boxes import (AnimeBoxesImport.swift) has not been ported yet, so:
// - In "legacy import folders are repaired on upgrade and reimport", the favorites the
//   import would have written into the former shared folder are inserted directly, and the
//   reimport step calls organizeLegacyImports(), the repair the import runs, instead of
//   importing again. The `added == 0` check of the reimport is left out.
// - In "imported favorite index survives reopening and tracks removal", the favorites are
//   saved through the store instead of imported.
// Gold restriction tests are not ported: that session state arrives with image browsing.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/support/swift_json.dart';

import '../../support/fixtures.dart';

void main() {
  String databasePath() => '${temporaryDirectory(addTearDown).path}/booru.sqlite';
  BooruStore open(String path) => BooruStore(path: path, preferences: AppPreferences.memory());

  test('legacy import folders are repaired on upgrade and reimport', () {
    final path = databasePath();
    final store = open(path);
    final servers = [server('alpha'), server('beta', engine: BooruEngine.gelbooru)];
    for (final value in servers) {
      store.saveServer(value);
    }
    store.database.write((db) {
      db.execute("INSERT INTO folders VALUES ('anime-boxes', 'Anime Boxes', 1, 99)");
      for (final (index, value) in servers.indexed) {
        final imported = post(201, value);
        db.execute('INSERT INTO favorites VALUES (?, ?, ?, ?, ?)', [value.id, 201, encodeSwiftJson(imported.toJson()), 1000.0 + index, 'anime-boxes']);
      }
    });
    final custom = store.saveFolder(name: 'My picks');
    final preserved = post(999, servers[0]);
    store.saveFavorite(preserved, folderID: custom);
    List<double> dates(BooruStore store) => store.database.read((db) => db.column<double>('SELECT saved_at FROM favorites ORDER BY server_id, post_id'));
    final before = dates(store);
    // Simulate a database written by the previous app version.
    store.database.write((db) => db.execute("DELETE FROM grdb_migrations WHERE identifier = 'booru_v6_import_site_folders'"));
    store.database.close();
    final upgraded = open(path);
    for (final value in servers) {
      expect(upgraded.favorites([value.id], folderID: 'site:${value.canonicalAddress}').length, 1);
    }
    expect(upgraded.folderIDFor(preserved), custom);
    expect(dates(upgraded), before);
    // A backup imported later into the former shared folder is repaired on reimport too.
    upgraded.database.write((db) {
      db.execute("INSERT INTO folders VALUES ('anime-boxes', 'Anime Boxes', 1, 99)");
      db.execute("UPDATE favorites SET folder_id = 'anime-boxes' WHERE post_id = 201");
    });
    upgraded.organizeLegacyImports();
    expect(upgraded.visibleFavorites().length, 3);
    expect(upgraded.folderIDFor(preserved), custom);
    expect(upgraded.folders().any((folder) => folder.id == 'anime-boxes'), isFalse);
  });

  test('address display names do not change connection addresses', () {
    final alpha = server('alpha')..name = '  HTTPS://alpha.example/  ';
    final store = BooruStore.inMemory();
    store.saveServer(alpha);
    store.saveFavorite(post(42, alpha));
    expect(alpha.displayName, 'alpha.example');
    expect(store.folders().firstWhere((folder) => folder.id.startsWith('site:')).displayName, 'alpha.example');
    expect(store.servers[0].baseURL, 'https://alpha.example');
    expect(BooruServer.displayNameOf('My collection'), 'My collection');
    expect(BooruServer.displayNameOf('https://media.example/booru'), 'media.example/booru');
  });

  test('content controls match post and artist without hiding unrelated posts', () {
    final value = post(123, server('alpha'))
      ..artists = ['sample_artist']
      ..tags = ['scenery'];
    expect(BooruBlacklist('id:123').contains(value), isTrue);
    expect(BooruBlacklist('id:124').contains(value), isFalse);
    expect(BooruBlacklist('artist:SAMPLE_ARTIST').contains(value), isTrue);
    expect(BooruBlacklist('artist:someone_else').contains(value), isFalse);
    expect(BooruBlacklist('artist:sample_artist -spoilers').contains(value), isTrue);
  });

  test('multiple selection and folders persist without mixing servers', () {
    final path = databasePath();
    final store = open(path);
    store.saveServer(server('alpha'));
    store.saveServer(server('gamma', engine: BooruEngine.gelbooru));
    final a = store.servers[0], b = store.servers[1];
    store.toggleServer(b);
    expect(store.selectedServers.map((value) => value.id), [a.id, b.id]);
    final folder = store.saveFolder(name: 'Landscapes');
    final first = post(101, a), second = post(101, b);
    store.saveFavorite(first, folderID: folder);
    store.saveFavorite(second);
    final restored = open(path);
    expect(restored.selectedServerIDs, [a.id, b.id]);
    expect(restored.favorites(restored.selectedServerIDs).length, 2);
    expect(restored.favorites([a.id, b.id], folderID: folder).map((value) => value.id), [first.id]);
    restored.setBlacklist('scenery', serverID: a.id);
    expect(restored.visibleFavorites().map((value) => value.id), [second.id]);
    restored.deleteFolder(folder);
    expect(restored.folderIDFor(first), 'unsorted');
    expect(restored.isFavorite(first), isTrue);
    restored.toggleServer(a);
    restored.toggleServer(b);
    expect(restored.selectedServerIDs, isEmpty);
    restored.reload();
    expect(restored.selectedServerIDs, isEmpty);
  });

  test('legacy favorites and single selection migrate', () {
    final path = databasePath();
    final legacy = server('beta', engine: BooruEngine.gelbooru);
    final db = sqlite.sqlite3.open(path);
    db.execute('''
      CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
      INSERT INTO grdb_migrations VALUES ('booru_v1');
      CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE servers (id TEXT PRIMARY KEY, payload BLOB NOT NULL, position INTEGER NOT NULL);
      CREATE TABLE favorites (server_id TEXT NOT NULL, post_id INTEGER NOT NULL, payload BLOB NOT NULL, saved_at DOUBLE NOT NULL, PRIMARY KEY(server_id, post_id));
      CREATE TABLE history (server_id TEXT NOT NULL, query TEXT NOT NULL, used_at DOUBLE NOT NULL, PRIMARY KEY(server_id, query));
      CREATE TABLE saved_tags (server_id TEXT NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL, PRIMARY KEY(server_id, name, kind));
      CREATE INDEX favorite_date ON favorites(server_id, saved_at DESC);
      ''');
    db.execute('INSERT INTO servers VALUES (?, ?, 0)', [legacy.id, encodeSwiftJson(legacy.toJson())]);
    db.execute('INSERT INTO favorites VALUES (?, 101, ?, 123)', [legacy.id, encodeSwiftJson(post(101, legacy).toJson())]);
    db.execute("INSERT INTO settings VALUES ('selected_server', ?)", [legacy.id]);
    db.close();
    final store = open(path);
    expect(store.selectedServerIDs, ['beta']);
    expect(store.favorites(['beta'], folderID: 'site:${legacy.canonicalAddress}').length, 1);
  });

  test('imported favorite index survives reopening and tracks removal', () {
    final path = databasePath();
    final store = open(path);
    for (final value in [server('alpha'), server('beta', engine: BooruEngine.gelbooru)]) {
      store.saveServer(value);
      store.saveFavorite(post(5194309, value));
    }
    store.setSelectedServers(store.servers.map((value) => value.id).toList());
    store.database.close();
    final restored = open(path);
    expect(restored.selectedServers, hasLength(2));
    for (final value in restored.selectedServers) {
      final saved = post(5194309, value);
      expect(restored.favoriteIDs.contains(saved.id), isTrue);
      expect(restored.isFavorite(saved), isTrue);
      restored.saveFavorite(saved);
      expect(restored.favoritesOn(value.id).length, 1);
      restored.toggleFavorite(saved);
      expect(restored.favoriteIDs.contains(saved.id), isFalse);
      expect(restored.isFavorite(saved), isFalse);
    }
  });

  test('saved library ignores server selection and defaults to site folders', () {
    final store = BooruStore.inMemory();
    final a = server('alpha'), b = server('beta', engine: BooruEngine.gelbooru);
    store.saveServer(a);
    store.saveServer(b);
    final first = post(1, a), second = post(2, b);
    store.toggleFavorite(first);
    store.saveFavorite(second);
    store.setSelectedServers([a.id]);
    expect(store.visibleFavorites().map((value) => value.id).toSet(), {first.id, second.id});
    store.setSelectedServers([]);
    expect(store.visibleFavorites().map((value) => value.id).toSet(), {first.id, second.id});
    expect(store.favorites([a.id, b.id]).length, 2);
    expect(store.folderIDFor(first), 'site:${a.canonicalAddress}');
    expect(store.folderIDFor(second), 'site:${b.canonicalAddress}');
    store.setBlacklist('id:1', serverID: a.id);
    store.setSelectedServers([b.id]);
    expect(store.visibleFavorites().map((value) => value.id), [second.id]);
    final custom = store.saveFolder(name: 'Custom');
    store.saveFavorite(first, folderID: custom);
    store.saveFavorite(first);
    expect(store.folderIDFor(first), custom);
  });
}
