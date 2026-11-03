// The database dumps of the native fixture test (`dumpComics` and `dumpImages` in the
// temporary XCTest described in test/fixtures/native/README.md), run on the Dart stores.
import 'dart:convert';
import 'dart:typed_data';

import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/storage/folder_rules.dart';
import 'package:tegnal/core/support/sql_database.dart';

Object? _value(Object? value) {
  if (value is Uint8List) {
    try {
      return jsonDecode(utf8.decode(value));
    } on FormatException {
      return {'base64': base64Encode(value)};
    }
  }
  return value;
}

List<Map<String, Object?>> _rows(SqlDatabase db, String sql, {Set<String> skip = const {}}) => [
  for (final row in db.rows(sql))
    {
      for (final entry in row.entries)
        if (!skip.contains(entry.key)) entry.key: _value(entry.value),
    },
];

/// `dumpComics` from the native fixture test.
Map<String, Object?> dumpComics(AppDatabase database) => database.dbWriter.read((db) {
  final syncNames = <String, String>{
    for (final row in db.rows('SELECT name, sync_id FROM folders WHERE sync_id IS NOT NULL'))
      row['sync_id'] as String: row['sync_id'] == 'unsorted' ? 'unsorted' : '<sync:${row['name']}>',
  };
  Object? mapIDs(Object? value) => switch (value) {
    String text => syncNames[text] ?? text,
    List list => list.map(mapIDs).toList(),
    Map map => map.map((key, value) => MapEntry(key, mapIDs(value))),
    _ => value,
  };
  final folders = [
    for (final row in db.rows('SELECT * FROM folders ORDER BY sort_order, id'))
      {
        'name': row['name'],
        'description': row['description'],
        'color': row['color'],
        'sort_order': row['sort_order'],
        'source_group_id': row['source_group_id'],
        'sync_id_is_unsorted': row['sync_id'] == 'unsorted',
        'sync_id_present': row['sync_id'] != null,
      },
  ];
  final order = [
    for (final row in db.rows('SELECT key, value FROM library_order ORDER BY key'))
      {
        'key': (row['key'] as String).startsWith(FolderRule.keyPrefix)
            ? FolderRule.keyPrefix + (syncNames[(row['key'] as String).substring(FolderRule.keyPrefix.length)] ?? '?')
            : row['key'],
        'value': mapIDs(_value(row['value'])),
      },
  ]..sort((a, b) => (a['key'] as String).compareTo(b['key'] as String));
  return {
    'folders': folders,
    'works': _rows(db, 'SELECT * FROM works ORDER BY gallery_id', skip: {'id'}),
    'folder_works': _rows(
      db,
      'SELECT f.name AS folder, w.gallery_id, fw.added_at FROM folder_works fw JOIN folders f ON f.id = fw.folder_id JOIN works w ON w.id = fw.work_id ORDER BY f.name, w.gallery_id',
    ),
    'artists': _rows(db, 'SELECT name, kind, note, folder_id FROM artists ORDER BY name, kind'),
    'search_history': _rows(db, 'SELECT * FROM search_history ORDER BY used_at DESC'),
    'saved_searches': db.column<String>('SELECT query FROM saved_searches ORDER BY query'),
    'library_order': order,
  };
});

/// `dumpImages` from the native fixture test.
Map<String, Object?> dumpImages(BooruStore store) => store.database.read(
  (db) => {
    'servers': _rows(db, 'SELECT * FROM servers ORDER BY position'),
    'folders': _rows(db, 'SELECT * FROM folders ORDER BY position, name'),
    'favorites': _rows(db, 'SELECT * FROM favorites ORDER BY server_id, post_id'),
    'history': _rows(db, 'SELECT * FROM history ORDER BY server_id, query'),
    'saved_tags': _rows(db, 'SELECT * FROM saved_tags ORDER BY server_id, kind, name'),
    'settings': [
      for (final row in _rows(db, 'SELECT * FROM settings ORDER BY key'))
        if ((row['key'] as String).startsWith(FolderRule.keyPrefix))
          {...row, 'value': jsonDecode(row['value'] as String), 'value_parsed_from_unsorted_json_string': true}
        else
          row,
    ],
    'challenges': _rows(db, 'SELECT id, payload FROM challenges ORDER BY rowid'),
  },
);

Map<String, Object?> withoutNote(Object? value) => {...(value as Map<String, Object?>)}..remove('note');

/// Native comics folder rules sit under random sync-id keys, so their order is not fixed.
Map<String, Object?> sortedOrder(Map<String, Object?> state) => {
  ...state,
  'library_order': [...(state['library_order'] as List).cast<Map<String, Object?>>()]..sort((a, b) => (a['key'] as String).compareTo(b['key'] as String)),
};
