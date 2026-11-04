// `testSmartPicksTreatOtherVersionsOfSavedWorksAsSaved` from native-ios/TEGNALTests/TasteTests.swift.

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/gallery_content.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/taste/recommendation_service.dart';

void main() {
  test('smart picks treat other versions of saved works as saved', () {
    final db = AppDatabase.inMemory();
    db.upsertWork(galleryId: 1001, title: 'Career Women to sono Joushi | 커리어 우먼과 그 상사', artists: 'mira, noa');
    db.upsertWork(galleryId: 1002, title: 'Ai', artists: 'mira');
    final index = SavedWorkIndex(db);
    NativeGallery gallery(int id, String title, List<String> artists, {List<int> versions = const []}) => NativeGallery(
      id: id,
      title: title,
      artists: artists,
      language: 'japanese',
      type: 'doujinshi',
      tags: const [],
      pages: const [],
      versions: [for (final version in versions) GalleryVersion(id: version, language: 'korean')],
    );
    expect(index.contains(gallery(1001, 'Anything', [])), isTrue, reason: 'The saved number itself');
    expect(index.contains(gallery(2001, 'Other Title', [], versions: [1001])), isTrue, reason: 'A version the site lists for a saved work');
    expect(index.contains(gallery(2002, '[Mira] Career Women to Sono Joushi (C99) [Digital]', ['Mira'])), isTrue, reason: 'The same original by a shared artist');
    expect(index.contains(gallery(2003, 'Career Women to sono Joushi', ['theo'])), isFalse, reason: "Another artist's work of the same name");
    expect(index.contains(gallery(2004, 'Career Women to sono Joushi 2', ['mira'])), isFalse, reason: 'A sequel');
    expect(index.contains(gallery(2005, 'AI', ['mira'])), isFalse, reason: 'Titles this short are not matched');
  });
}
