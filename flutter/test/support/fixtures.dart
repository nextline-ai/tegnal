import 'dart:io';

import 'package:tegnal/core/booru/booru_models.dart';

/// A server on a reserved example host, standing in for the native presets.
BooruServer server(String name, {String? id, BooruEngine engine = BooruEngine.danbooru, String? baseURL}) =>
    BooruServer(id: id ?? name, name: name, baseURL: baseURL ?? 'https://$name.example', engine: engine);

/// `BooruFixtureSource.post`, with media on an example host.
BooruPost post(
  int id,
  BooruServer server, {
  List<String> tags = const ['scenery', 'mountain'],
  List<String> artists = const ['sample_artist'],
  String rating = 'g',
}) => BooruPost(
  serverID: server.id,
  postID: id,
  previewURL: 'https://media.example/preview.png',
  sampleURL: 'https://media.example/sample.png',
  fileURL: 'https://media.example/original.png',
  width: 1600,
  height: 1200,
  tags: [...tags],
  artists: [...artists],
  rating: rating,
  score: 42,
  fileExtension: id == 104
      ? 'gif'
      : id == 105
      ? 'mp4'
      : 'png',
  poolIDs: [77],
);

/// A fresh directory removed when the test ends.
Directory temporaryDirectory(void Function(void Function() body) addTearDown) {
  final directory = Directory.systemTemp.createTempSync('tegnal-test-');
  addTearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  return directory;
}
