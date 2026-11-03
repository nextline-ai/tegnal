import 'dart:typed_data';
import 'dart:ui' as ui;

import 'content_errors.dart';
import 'gallery_content.dart';

/// The launch options of the native UI tests that change what the fixture returns.
enum FixtureOption {
  /// `--native-content-initial-error`: the first list fails as if offline.
  initialError,

  /// `--native-content-long-feed`: 120 works across the five categories.
  longFeed,

  /// `--work-links-test`: three language versions that link to each other.
  workLinks,

  /// `--taste-ui-rich`: two pages of 24 works.
  tasteRich,

  /// `--slow-detail-cover-test`: covers take 20 seconds.
  slowDetailCover,

  /// `--native-content-image-error`: every image times out.
  imageError,

  /// `--reader-short-page-test`: pages are wide and short.
  shortPages,

  /// `--reader-japanese-test`: pages carry Japanese text.
  japanesePages,
}

/// Synthetic pages keep device UI automation independent of private library data and the
/// network. The same works as the native `FixtureContentSource`, so screens can be compared.
class FixtureContentSource extends ContentProviding {
  FixtureContentSource({Set<FixtureOption> options = const {}}) : options = {...options}, _shouldFail = options.contains(FixtureOption.initialError);

  static const categories = ['doujinshi', 'manga', 'artistcg', 'gamecg', 'imageset'];
  final Set<FixtureOption> options;
  bool _shouldFail;
  int imageRequests = 0;

  @override
  Future<NativeGallery> gallery(int id) async {
    final scrolling = options.contains(FixtureOption.longFeed);
    final linked = options.contains(FixtureOption.workLinks);
    const versions = [
      GalleryVersion(id: 900000001, language: 'english', localName: 'English'),
      GalleryVersion(id: 900000002, language: 'korean', localName: '한국어'),
      GalleryVersion(id: 900000003, language: 'japanese', localName: '日本語'),
    ];
    final version = linked ? versions.where((version) => version.id == id).firstOrNull : null;
    return NativeGallery(
      id: id,
      title: linked ? 'Work $id' : '네이티브 읽기 테스트',
      artists: const ['TEGNAL'],
      language: version?.language ?? 'english',
      type: categories[id % 5],
      tags: const ['group:sample circle', 'female:sample', 'tag:example'],
      pages: [
        for (var index = 1; index <= 3; index++)
          GalleryPage(
            hash: scrolling || linked ? (id * 10 + index).toRadixString(16).padLeft(64, '0') : '${'a' * 63}$index',
            name: '$index.png',
            width: 800,
            height: 1200,
            hasAVIF: false,
          ),
      ],
      versions: version == null ? null : versions,
      relatedIDs: version == null ? null : const [900000002, 900000011, 900000012],
    );
  }

  @override
  Future<GalleryBatch> list(GalleryQuery query, {required int offset, required int count}) async {
    if (_shouldFail) {
      _shouldFail = false;
      throw const NetworkError(NetworkErrorCode.notConnectedToInternet);
    }
    if (options.contains(FixtureOption.tasteRich)) {
      return GalleryBatch(ids: offset < 48 ? [for (var index = 0; index < 24; index++) 900000001 + offset + index] : [], hasMore: offset < 24);
    }
    if (options.contains(FixtureOption.longFeed)) {
      final type = query.text.split(' ').where((term) => term.startsWith('type:')).firstOrNull?.substring(5);
      final ids = [for (var index = 0; index < 120; index++) 900000001 + index].where((id) => type == null || categories[id % 5] == type).toList();
      final end = offset + count < ids.length ? offset + count : ids.length;
      final start = offset < end ? offset : end;
      return GalleryBatch(ids: ids.sublist(start, end), hasMore: end < ids.length);
    }
    return GalleryBatch(ids: offset == 0 ? const [900000001] : const [], hasMore: false);
  }

  @override
  Future<List<TagSuggestion>> suggestions(String token) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return token == 'female:sa' ? const [TagSuggestion(namespace: 'female', name: 'sample tag', count: 42)] : const [];
  }

  @override
  Future<Uint8List> image(GalleryPage page, {required int galleryID, required bool thumbnail}) async {
    imageRequests += 1;
    if (thumbnail && options.contains(FixtureOption.longFeed)) await Future<void>.delayed(const Duration(milliseconds: 180));
    if (thumbnail && options.contains(FixtureOption.slowDetailCover)) await Future<void>.delayed(const Duration(seconds: 20));
    if (options.contains(FixtureOption.imageError)) throw const NetworkError(NetworkErrorCode.timedOut);
    final short = options.contains(FixtureOption.shortPages);
    final text = options.contains(FixtureOption.japanesePages)
        ? '今日はとてもいい天気です。\n\n一緒に公園に行きましょう。\n\n明日も楽しい一日になりますように。'
        : 'TEGNAL\n\nPage ${page.name.isEmpty ? '' : page.name[0]}\n\nNative Reader\n\nDouble tap to zoom';
    return renderPage(text, width: short ? 1200 : 800, height: short ? 400 : 1200);
  }

  /// A light blue page with large black text, as the native fixture draws it.
  static Future<Uint8List> renderPage(String text, {required int width, required int height}) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), ui.Paint()..color = const ui.Color.fromARGB(255, 230, 240, 255));
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: 48, fontWeight: ui.FontWeight.w600))
      ..pushStyle(ui.TextStyle(color: const ui.Color(0xFF000000)))
      ..addText(text);
    final paragraph = builder.build()..layout(const ui.ParagraphConstraints(width: 680));
    canvas.drawParagraph(paragraph, const ui.Offset(60, 120));
    final image = await recorder.endRecording().toImage(width, height);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }
}

/// The hosts the native UI test support recognizes when checking a website address.
abstract final class FixtureWebsites {
  static int _retryAttempts = 0;

  /// `ContentUITestSupport.websiteHTML(for:)`.
  static Future<String> html(Uri url) async {
    switch (url.host) {
      case 'catalog.example':
        return '<script src="/js/index.search.tail.js"></script>';
      case 'indexed.example':
        return '<script src="https://ltn.storage.example/common.js"></script>';
      case 'retry.example':
        _retryAttempts += 1;
        if (_retryAttempts == 1) throw const NetworkError(NetworkErrorCode.secureConnectionFailed);
        return '<script src="/js/index.search.tail.js"></script>';
      case 'delayed.example':
        await Future<void>.delayed(const Duration(seconds: 2));
        return '<script src="/js/index.search.tail.js"></script>';
      default:
        return '<html><title>Website</title></html>';
    }
  }
}
