import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/booru/booru_store.dart';

void main() {
  test('both libraries open in memory', () {
    final database = AppDatabase.inMemory();
    final booru = BooruStore.inMemory();
    expect(database.listFolders().single.name, '미분류');
    expect(booru.folders(), isEmpty);
  });
}
