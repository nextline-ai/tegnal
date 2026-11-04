import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../content/content_errors.dart';
import '../taste/taste_models.dart';
import 'booru_client.dart';
import 'booru_models.dart';
import 'booru_store.dart';

/// The launch options of the native image-mode UI tests that change what the fixture returns.
enum BooruFixtureOption {
  /// `--booru-initial-error`: the first page fails as if offline.
  initialError,

  /// `--booru-tag-limit-test`: a search for `mountain` exceeds the server's tag limit.
  tagLimit,

  /// `--taste-recap-demo`: 16 posts a page from a small tag vocabulary, four pages.
  tasteRecapDemo,

  /// `--taste-ui-rich`: searches return two pages of twelve; eight saved favorites.
  tasteRich,

  /// `--booru-restored-badge-test`: one post that a restored backup already holds.
  restoredBadge,

  /// `--booru-import-badge-test`: one post that an imported backup already holds.
  importBadge,

  /// `--booru-media-test`: an animated GIF and a video.
  media,

  /// `--booru-gold-test`: a post whose media needs an upgraded account.
  gold,

  /// `--challenge-scroll-test`: three pages of forty posts.
  challengeScroll,

  /// `--booru-multi-test`: the second server's posts carry other IDs.
  multi,

  /// `--booru-long-suggestions`: twelve suggestions.
  longSuggestions,

  /// `--no-sites-test`: no servers are connected.
  noSites,
}

/// Synthetic posts keep image-mode automation independent of private data and the network.
/// The same posts as the native `BooruFixtureSource`, so screens can be compared.
class BooruFixtureSource implements BooruProviding {
  BooruFixtureSource({this.options = const {}, this.delay = const Duration(milliseconds: 100)});

  final Set<BooruFixtureOption> options;
  final Duration delay;
  var _failed = false;

  static const restrictedPostID = 12403879;
  static const restoredPostID = 5194309;

  static BooruPost post(int id, BooruServer server, {List<String> tags = const ['scenery', 'mountain']}) => BooruPost(
    serverID: server.id,
    postID: id,
    previewURL: 'https://fixture.invalid/preview.png',
    sampleURL: 'https://fixture.invalid/sample.png',
    fileURL: 'https://fixture.invalid/original.png',
    width: 1600,
    height: 1200,
    tags: [...tags],
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

  @override
  Future<BooruBatch> posts(BooruServer server, String query, int page) async {
    await Future<void>.delayed(delay);
    if (options.contains(BooruFixtureOption.initialError) && !_failed) {
      _failed = true;
      throw const NetworkError(NetworkErrorCode.notConnectedToInternet);
    }
    if (options.contains(BooruFixtureOption.tagLimit) && query.contains('mountain')) throw const BooruError(BooruErrorKind.unavailable, 422);
    if (query == 'empty') return const BooruBatch(posts: [], hasMore: false);
    if (options.contains(BooruFixtureOption.tasteRecapDemo)) {
      const extra = ['lantern', 'snow', 'shrine', 'fox', 'aurora', 'rain', 'neon', 'harbor', 'forest', 'mist'];
      final terms = query.split(' ').where((term) => term.isNotEmpty && !term.contains(':')).toList();
      final base = 9000 + (_stableHash(query) % 700).abs() * 20 + page * 20;
      return BooruBatch(
        posts: [
          for (var index = 0; index < 16; index++)
            () {
              final value = post(base + index, server, tags: {...terms, extra[index % 10], extra[(index * 3 + 1) % 10], 'scenery'}.toList())
                ..fileExtension = 'png';
              final artist = ['mira_sato', 'noa_lindqvist', 'new_painter'][index % 3];
              return value
                ..artists = [artist]
                ..tags.add(artist)
                ..tagCategories = {artist: 1};
            }(),
        ],
        hasMore: page < 3,
      );
    }
    if (options.contains(BooruFixtureOption.tasteRich) && query.isNotEmpty) {
      return BooruBatch(posts: [for (var id = 201 + page * 10; id <= 212 + page * 10; id++) post(id, server)], hasMore: page < 2);
    }
    if (options.contains(BooruFixtureOption.restoredBadge)) return BooruBatch(posts: [post(restoredPostID, server)], hasMore: false);
    if (options.contains(BooruFixtureOption.importBadge)) return BooruBatch(posts: [post(201, server)], hasMore: false);
    if (options.contains(BooruFixtureOption.media)) return BooruBatch(posts: [post(104, server), post(105, server)], hasMore: false);
    if (options.contains(BooruFixtureOption.gold)) {
      final restricted = post(restrictedPostID, server)
        ..previewURL = null
        ..sampleURL = null
        ..fileURL = null;
      return BooruBatch(posts: [post(101, server), restricted, post(102, server)], hasMore: false);
    }
    if (options.contains(BooruFixtureOption.challengeScroll)) {
      return BooruBatch(posts: [for (var id = 101 + page * 40; id < 141 + page * 40; id++) post(id, server)], hasMore: page < 2);
    }
    final offset = options.contains(BooruFixtureOption.multi) && server.id == BooruFixtureEnvironment.servers[1].id ? 1000 : 0;
    final posts = page == 0
        ? [
            post(101 + offset, server),
            post(102 + offset, server, tags: const ['city', 'night']),
          ]
        : [post(103 + offset, server)];
    return BooruBatch(posts: posts, hasMore: page == 0);
  }

  /// A hash that does not change between runs, unlike `hashValue`, so demo pages repeat.
  static int _stableHash(String value) => utf8.encode(value).fold(17, (hash, byte) => (hash * 31 + byte) & 0x7fffffff);

  @override
  Future<List<BooruTag>> suggestions(BooruServer server, String token) async {
    if (options.contains(BooruFixtureOption.longSuggestions)) {
      return [for (var index = 0; index < 12; index++) BooruTag(name: 'sc_${index.toString().padLeft(2, '0')}', count: 100 - index, category: 0)]
          .where((tag) => tag.name.startsWith(token))
          .toList();
    }
    return const [
      BooruTag(name: 'scenery', count: 240, category: 0),
      BooruTag(name: 'sample_artist', count: 42, category: 1),
    ].where((tag) => tag.name.startsWith(token)).toList();
  }

  @override
  Future<List<BooruPool>> pools(BooruServer server, String query, int page) async => page == 0
      ? [
          BooruPool(id: 78, name: 'Empty collection', count: 0, hasKnownCount: true),
          BooruPool(id: 77, name: 'Mountain_collection', count: 2, description: 'A synthetic collection for testing.', hasKnownCount: true),
        ]
      : [];

  @override
  Future<BooruBatch> poolPosts(BooruServer server, int poolID, int page) async =>
      BooruBatch(posts: page == 0 ? [post(102, server), post(101, server)] : [], hasMore: false);

  @override
  Future<List<BooruNote>> notes(BooruServer server, int postID) async => const [
    BooruNote(id: 1, x: 120, y: 90, width: 700, height: 180, body: 'A mountain in the morning.'),
  ];

  @override
  Future<BooruPost> details(BooruServer server, BooruPost post) async {
    if (options.contains(BooruFixtureOption.gold) && post.postID == restrictedPostID) throw BooruPostAccessError.goldRequired;
    return post;
  }
}

/// The fixture servers and library, as `ContentUITestSupport.environment()` seeds them for
/// image mode. Servers have neutral names and reserved `.invalid` addresses.
abstract final class BooruFixtureEnvironment {
  static final servers = [
    BooruServer(id: 'images-a', name: 'Images A', baseURL: 'https://images-a.invalid', engine: BooruEngine.danbooru),
    BooruServer(id: 'images-b', name: 'Images B', baseURL: 'https://images-b.invalid', engine: BooruEngine.gelbooru),
    BooruServer(id: 'images-c', name: 'Images C', baseURL: 'https://images-c.invalid', engine: BooruEngine.gelbooru),
  ];

  /// Connects the fixture servers and selects the first. A restored-badge run instead holds
  /// the post a restored backup brought back, on the first two servers, with nothing selected.
  static void seed(BooruStore store, {Set<BooruFixtureOption> options = const {}}) {
    if (options.contains(BooruFixtureOption.noSites)) return;
    for (final server in servers) {
      store.saveServer(server);
    }
    if (options.contains(BooruFixtureOption.restoredBadge)) {
      // The native run imports a backup file; the backup import arrives with the imports step,
      // so the favorites it would add are saved directly.
      store.setSelectedServers([]);
      store.saveFavorite(BooruFixtureSource.post(BooruFixtureSource.restoredPostID, servers[0], tags: const ['scenery', 'mountain']));
      store.saveFavorite(BooruFixtureSource.post(BooruFixtureSource.restoredPostID, servers[1], tags: const ['city']));
    } else {
      store.select(servers[0]);
    }
    if (options.contains(BooruFixtureOption.tasteRich)) {
      for (var index = 1; index <= 8; index++) {
        final post = BooruFixtureSource.post(100 + index, servers[0], tags: ['scenery', 'mountain', index.isEven ? 'cloud' : 'river']);
        store.toggleFavorite(
          post,
          context: DiscoveryContext(origin: DiscoveryOrigin.search, query: 'scenery', session: 'fixture-$index'),
        );
      }
    }
  }
}

/// Fixture media drawn on the device, so thumbnails and the viewer exercise their real
/// decoding paths offline. Mirrors the native fixture drawings and `BooruTestMedia`.
abstract final class BooruFixtureMedia {
  static Uint8List? _thumbnail;

  /// A wide indigo and cyan preview, as the native fixture thumbnail draws it.
  static Future<Uint8List> thumbnail() async => _thumbnail ??= await _render(1600, 300, (canvas) {
    canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 1600, 300), ui.Paint()..color = const ui.Color(0xFF5856D6));
    canvas.drawRect(const ui.Rect.fromLTWH(800, 0, 800, 300), ui.Paint()..color = const ui.Color(0xFF32ADE6));
  });

  /// The viewer's still image: a mountain line on dark blue with the post number.
  static Future<Uint8List> still(int postID) => _render(1600, 1200, (canvas) {
    canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 1600, 1200), ui.Paint()..color = const ui.Color(0xFF193655));
    final path = ui.Path()
      ..moveTo(0, 1000)
      ..lineTo(500, 250)
      ..lineTo(850, 750)
      ..lineTo(1150, 400)
      ..lineTo(1600, 1000)
      ..close();
    canvas.drawPath(path, ui.Paint()..color = const ui.Color(0xFF65C8CF));
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: 64))
      ..pushStyle(ui.TextStyle(color: const ui.Color(0xFFFFFFFF)))
      ..addText('Booru · Post $postID');
    final paragraph = builder.build()..layout(const ui.ParagraphConstraints(width: 1400));
    canvas.drawParagraph(paragraph, const ui.Offset(140, 100));
  });

  /// Bytes for a fixture address: the preview for thumbnails, otherwise the post's media.
  static Future<Uint8List> load(String url, BooruPost? post) async {
    if (url.endsWith('/preview.png')) return thumbnail();
    if (post?.fileExtension == 'gif') return base64Decode(gif.substring(gif.indexOf(',') + 1));
    if (post?.fileExtension == 'mp4') return base64Decode(mp4.substring(mp4.indexOf(',') + 1));
    return still(post?.postID ?? 0);
  }

  static Future<Uint8List> _render(int width, int height, void Function(ui.Canvas canvas) draw) async {
    final recorder = ui.PictureRecorder();
    draw(ui.Canvas(recorder));
    final image = await recorder.endRecording().toImage(width, height);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  // Synthetic one-second color patterns generated with FFmpeg for device media tests.
  static const mp4 =
      'data:video/mp4;base64,'
      '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';

  static const gif =
      'data:image/gif;base64,'
      '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';
}
