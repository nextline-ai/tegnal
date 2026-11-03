// Edge cases of WorkQuery (native-ios/TEGNAL/Core/Storage/WorkQuery.swift), taken from
// FolderRuleTests.swift and LibrarySyncTests.swift searches.

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/storage/work_query.dart';

void main() {
  test('a field term matches one whole entry in its column or tags', () {
    final (sql, arguments) = WorkQuery('artist:some_artist').conditions;
    String entry(String column) => "', ' || REPLACE(COALESCE($column, ''), '_', ' ') || ', ' LIKE ? ESCAPE '\\'";
    expect(sql, '(${entry('w.artists')} OR ${entry('w.tags')})');
    expect(arguments, ['%, some artist, %', '%, artist:some artist, %']);
  });

  test('field names are case insensitive and unknown fields are plain words', () {
    expect(WorkQuery('LANGUAGE:korean').conditions.$2, ['%, korean, %', '%, language:korean, %']);
    final (_, plain) = WorkQuery('other:url').conditions;
    expect(plain, List.filled(8, '%other:url%'));
  });

  test('a leading minus or the excluded text negates a term', () {
    final (sql, _) = WorkQuery('-language:japanese').conditions;
    expect(sql, startsWith('NOT ('));
    final query = WorkQuery('tag:color', excluding: 'tag:spoiler, tag:old');
    expect(query.conditions.$1.split(' AND ').where((clause) => clause.startsWith('NOT (')).length, 2);
    expect(query.isEmpty, isFalse);
    expect(WorkQuery('-tag:a', excluding: 'tag:b').isEmpty, isTrue);
    expect(WorkQuery('').isEmpty, isTrue);
  });

  test('spaces and commas separate terms and every term must match', () {
    expect(WorkQuery('a, b  c,,d').conditions.$1.split(' AND ').length, 4);
  });

  test('a number also matches the gallery id', () {
    final (sql, arguments) = WorkQuery('12345').conditions;
    expect(sql, endsWith('OR w.gallery_id = ?)'));
    expect(arguments.last, 12345);
    expect(WorkQuery('12_').conditions.$1, isNot(contains('gallery_id')), reason: 'The underscore becomes a space, which is not a number');
    expect(WorkQuery('0x10').conditions.$1, isNot(contains('gallery_id')));
  });

  test('percent and backslash are matched literally', () {
    expect(WorkQuery('100%').conditions.$2.first, r'%100\%%');
    expect(WorkQuery(r'a\b').conditions.$2.first, r'%a\\b%');
  });

  test('an empty field value or a leading colon is a plain word', () {
    expect(WorkQuery('artist:').conditions.$2.first, '%artist:%');
    expect(WorkQuery(':foo').conditions.$2.first, '%:foo%');
    expect(WorkQuery('series:a:b').conditions.$2, ['%, a:b, %', '%, series:a:b, %']);
  });

  test('literal matches run against saved works', () {
    final database = AppDatabase.inMemory();
    database.upsertWork(galleryId: 1, title: '100% done', tags: 'tag:full color');
    database.upsertWork(galleryId: 2, title: '100 done', tags: 'tag:full_color, female:sole female');
    database.upsertWork(galleryId: 3, title: r'back\slash', language: 'korean');
    List<int> ids(String query) => database.listWorks(query: query).map((work) => work.galleryId).toList()..sort();
    expect(ids('100%'), [1]);
    expect(ids('tag:full_color'), [1, 2], reason: 'Stored underscores and spaces are the same');
    expect(ids(r'back\slash'), [3]);
    expect(ids('2'), [2], reason: 'Only the gallery id matches a bare number here');
    expect(ids('female:sole'), isEmpty);
    expect(ids('100 -female:sole_female'), [1]);
  });
}
