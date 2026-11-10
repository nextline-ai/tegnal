import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';

import '../support/swift_json.dart';
import '../support/swift_url.dart';
import 'booru_models.dart';

/// Only extracts inert metadata; no remote markup or JavaScript is executed.
abstract final class BooruHTML {
  static final _patterns = <String, RegExp>{};

  /// Every match of [pattern] (case-insensitive, `.` matching line breaks), each as its groups; a group that did not take part is empty.
  static List<List<String>> matches(String pattern, String string) {
    final RegExp regex;
    try {
      regex = _patterns[pattern] ??= RegExp(pattern, caseSensitive: false, dotAll: true);
    } on FormatException {
      return [];
    }
    return [
      for (final match in regex.allMatches(string)) [for (var group = 0; group <= match.groupCount; group++) match[group] ?? ''],
    ];
  }

  static String decode(String value) {
    var result = value;
    for (final match in matches('&#(x[0-9a-f]+|[0-9]+);', result).reversed) {
      final token = match[1];
      final number = token.toLowerCase().startsWith('x') ? int.tryParse(token.substring(1), radix: 16) : int.tryParse(token);
      if (number != null && number <= 0x10FFFF && (number < 0xD800 || number > 0xDFFF)) {
        result = result.replaceAll(match[0], String.fromCharCode(number));
      }
    }
    for (final (key, replacement) in const [
      ('&quot;', '"'),
      ('&#39;', "'"),
      ('&apos;', "'"),
      ('&lt;', '<'),
      ('&gt;', '>'),
      ('&nbsp;', ' '),
      ('&rsquo;', '’'),
      ('&lsquo;', '‘'),
      ('&rdquo;', '”'),
      ('&ldquo;', '“'),
      ('&amp;', '&'),
    ]) {
      result = result.replaceAll(key, replacement);
    }
    return result;
  }

  static final _breaks = RegExp(r'<br\s*/?>|</p>', caseSensitive: false);
  static final _tags = RegExp('<[^>]*>');

  static String plainText(String text) => decode(text.replaceAll(_breaks, '\n').replaceAll(_tags, '')).trim();

  static Map<String, String> attributes(String text) => {
    for (final match in matches(r'''([a-z0-9_-]+)\s*=\s*(["'])(.*?)\2''', text)) match[1].toLowerCase(): decode(match[3]),
  };

  /// The document text, or [BooruErrorKind.invalidResponse] for a non-document or a browser check.
  static String html(Uint8List data) {
    final String html;
    try {
      html = utf8.decode(data);
    } on FormatException {
      throw const BooruError(BooruErrorKind.invalidResponse);
    }
    if (!html.contains('<html') || html.contains('Just a moment...') || html.contains('cf-chl-')) throw const BooruError(BooruErrorKind.invalidResponse);
    return html;
  }

  static List<BooruPool> pools(Uint8List data) {
    final document = html(data);
    final counts = <int, int>{};
    for (final row in matches(r'<tr\b[^>]*>(.*?)</tr>', document)) {
      final cells = matches(r'<td\b[^>]*>(.*?)</td>', row[1]);
      if (cells.length < 3) continue;
      final link = matches(r'<a\b([^>]*)>', cells[0][1]).firstOrNull;
      if (link == null) continue;
      final id = _poolID(attributes(link[1])['href']);
      final count = parseInt64(plainText(cells[2][1]).replaceAll(',', ''));
      if (id == null || count == null) continue;
      counts[id] = count;
    }
    final seen = <int>{};
    return [
      for (final match in matches(r'<a\b([^>]*)>(.*?)</a>', document))
        if (_poolID(attributes(match[1])['href']) case final id? when seen.add(id))
          BooruPool(id: id, name: plainText(match[2]), count: counts[id] ?? 0, hasKnownCount: counts.containsKey(id)),
    ];
  }

  static int? _poolID(String? href) {
    if (href == null) return null;
    final items = linkQueryItems(href);
    if (items == null) return null;
    if (!items.any((item) => item.$1 == 'page' && item.$2 == 'pool') || !items.any((item) => item.$1 == 's' && item.$2 == 'show')) return null;
    final raw = linkQueryValue(items, 'id');
    return raw == null ? null : parseInt64(raw);
  }

  static List<BooruPool> danbooruPools(Uint8List data) {
    final document = html(data);
    if (matches(r'''\bid=["']c-pools["']''', document).isEmpty) throw const BooruError(BooruErrorKind.invalidResponse);
    final seen = <int>{};
    final result = <BooruPool>[];
    for (final row in matches(r'<tr\b[^>]*>(.*?)</tr>', document)) {
      final cells = matches(r'<td\b[^>]*>(.*?)</td>', row[1]);
      final nameCell = cells.firstOrNull;
      if (nameCell == null) continue;
      for (final link in matches(r'<a\b([^>]*)>(.*?)</a>', nameCell[1])) {
        final href = attributes(link[1])['href'];
        if (href == null) continue;
        final raw = matches(r'(?:^|/)pools/([0-9]+)$', href).firstOrNull?[1];
        final id = raw == null ? null : parseInt64(raw);
        if (id == null || !seen.add(id)) continue;
        final count = cells.length > 1 ? parseInt64(plainText(cells[1][1]).replaceAll(',', '')) ?? 0 : 0;
        result.add(BooruPool(id: id, name: plainText(link[2]), count: count, hasKnownCount: cells.length > 1));
        break;
      }
    }
    return result;
  }

  static List<int> postIDs(Uint8List data) {
    final seen = <int>{};
    final result = <int>[];
    for (final match in matches(r'<(?:a|span|article)\b([^>]*)>', html(data))) {
      final attrs = attributes(match[1]);
      final markedRaw = attrs['id'] == null ? null : matches(r'^p([0-9]+)$', attrs['id']!).firstOrNull?[1];
      final markedID = markedRaw == null ? null : parseInt64(markedRaw);
      final items = attrs['href'] == null ? null : linkQueryItems(attrs['href']!);
      final isPost = items != null && items.any((item) => item.$1 == 'page' && item.$2 == 'post') && items.any((item) => item.$1 == 's' && item.$2 == 'view');
      final linkedRaw = isPost ? linkQueryValue(items, 'id') : null;
      final id = markedID ?? (linkedRaw == null ? null : parseInt64(linkedRaw));
      if (id != null && seen.add(id)) result.add(id);
    }
    return result;
  }

  static int? nextPoolOffset(Uint8List data, int offset) {
    int? next;
    for (final match in matches(r'<a\b([^>]*)>', html(data))) {
      final href = attributes(match[1])['href'];
      final items = href == null ? null : linkQueryItems(href);
      if (items == null || !items.any((item) => item.$1 == 'page' && item.$2 == 'pool')) continue;
      final value = linkQueryValue(items, 'pid');
      final number = value == null ? null : parseInt64(value);
      if (number != null && number > offset && (next == null || number < next)) next = number;
    }
    return next;
  }

  static List<BooruNote> notes(Uint8List data) {
    final document = html(data);
    final result = <BooruNote>[];
    for (final (index, match) in matches(r'<article\b([^>]*)>', document).indexed) {
      final attrs = attributes(match[1]);
      final body = attrs['data-body'];
      final x = double.tryParse(attrs['data-x'] ?? ''), y = double.tryParse(attrs['data-y'] ?? '');
      final width = double.tryParse(attrs['data-width'] ?? ''), height = double.tryParse(attrs['data-height'] ?? '');
      if (body == null || x == null || y == null || width == null || height == null) continue;
      result.add(BooruNote(id: index + 1, x: x, y: y, width: width, height: height, body: plainText(body)));
    }
    return result;
  }
}

/// Gelbooru 0.1.11 and hosted legacy galleries expose HTML pages rather than the modern DAPI.
abstract final class BooruLegacyHTML {
  static String? _url(String? value, BooruServer server) {
    if (value == null) return null;
    var resolved = value;
    // Old templates still emit HTTP media links. Request their HTTPS equivalent.
    if (resolved.startsWith('http:')) resolved = 'https:${resolved.substring(5)}';
    return safeBooruURL(resolved, server.baseURL);
  }

  static List<BooruPost> posts(Uint8List data, BooruServer server, {bool modernRatings = false}) {
    final html = BooruHTML.html(data);
    final seen = <int>{};
    final posts = <BooruPost>[];
    for (final match in BooruHTML.matches(r'<a\b([^>]*)>((?:(?!</a>).)*<img\b[^>]*>(?:(?!</a>).)*)</a>', html)) {
      final anchor = BooruHTML.attributes(match[1]);
      final imageMatch = BooruHTML.matches(r'<img\b([^>]*)>', match[2]).firstOrNull;
      if (imageMatch == null) continue;
      final image = BooruHTML.attributes(imageMatch[1]);
      final link = anchor['href'] == null ? null : linkQueryItems(anchor['href']!);
      final linkedRaw = link != null && link.any((item) => item.$1 == 's' && item.$2 == 'view') ? linkQueryValue(link, 'id') : null;
      final linkedID = linkedRaw == null ? null : parseInt64(linkedRaw);
      final anchorID = anchor['id'];
      final elementID = anchorID != null && anchorID.startsWith('p') ? parseInt64(anchorID.substring(1)) : null;
      final id = elementID ?? linkedID;
      if (id == null || !seen.add(id)) continue;
      final preview = _url(image['data-original'] ?? image['data-src'] ?? image['src'], server);
      if (preview == null) continue;
      final title = image['title'] ?? image['alt'] ?? '';
      final terms = splitWhitespace(title);
      final metadata =
          BooruHTML.matches(
            r'posts\['
            '$id'
            r'\]\s*=\s*\{(.*?)\}',
            html,
          ).firstOrNull?[1] ??
          '';
      final scoreTerm = terms.where((term) => term.startsWith('score:')).firstOrNull;
      final score =
          (scoreTerm == null ? null : int.tryParse(scoreTerm.substring(6))) ??
          int.tryParse(BooruHTML.matches(r'''["']?score["']?\s*:\s*["']?(-?\d+)''', metadata).firstOrNull?[1] ?? '') ??
          0;
      final ratingTerm = terms.where((term) => term.startsWith('rating:')).firstOrNull;
      final rating = ratingTerm?.substring(7) ?? BooruHTML.matches(r'''["']?rating["']?\s*:\s*["']([^"']+)''', metadata).firstOrNull?[1] ?? '';
      posts.add(
        BooruPost(
          serverID: server.id,
          postID: id,
          previewURL: preview,
          width: 0,
          height: 0,
          tags: terms.where((term) => !term.startsWith('score:') && !term.startsWith('rating:')).toList(),
          artists: [],
          rating: normalizedRating(rating, server, modernRatings: modernRatings),
          score: score,
          fileExtension: '',
        ),
      );
    }
    final lower = html.toLowerCase();
    if (posts.isEmpty && !['nobody here', 'no images', 'no posts', 'no results'].any(lower.contains)) throw const BooruError(BooruErrorKind.invalidResponse);
    return posts;
  }

  static BooruPost post(Uint8List data, BooruServer server, int id, {String? preview, bool modernRatings = false}) {
    final html = BooruHTML.html(data);
    final images = BooruHTML.matches(r'<(?:img|video|source)\b([^>]*)>', html).map((match) => BooruHTML.attributes(match[1])).toList();
    final image =
        images.where((attrs) => attrs['id'] == 'image' || attrs['alt'] == 'img' || (attrs['onclick']?.contains('Note.toggle') ?? false)).firstOrNull ??
        images.where((attrs) => attrs['type']?.startsWith('video/') ?? false).firstOrNull;
    // The sidebar may contain a tag named "original" before the download link.
    String? original;
    for (final match in BooruHTML.matches(r'<a\b([^>]*)>(.*?)</a>', html)) {
      if (!['original image', 'original', 'original video'].contains(BooruHTML.plainText(match[2]).toLowerCase())) continue;
      final candidate = _url(BooruHTML.attributes(match[1])['href'], server);
      if (candidate == null) continue;
      if (!['jpg', 'jpeg', 'png', 'gif', 'webp', 'avif', 'jxl', 'mp4', 'webm', 'mov'].contains(urlPathExtension(candidate).toLowerCase())) continue;
      original = candidate;
      break;
    }
    // Some video pages expose the playable MP4 only in a nested source
    // element; the video itself has no src (and may have a poster).
    final videoSources = images.where((attrs) => (attrs['type'] ?? '').startsWith('video/')).toList();
    final playableVideo = videoSources.where((attrs) => attrs['type'] == 'video/mp4').firstOrNull ?? videoSources.firstOrNull;
    final videoURL = _url(playableVideo?['src'] ?? playableVideo?['data-src'], server);
    final imageURL = _url(image?['data-original'] ?? image?['data-src'] ?? image?['src'], server);
    final file = videoURL ?? original ?? imageURL;
    if (file == null) throw const BooruError(BooruErrorKind.invalidResponse);
    final textarea = BooruHTML.matches(
      r'<textarea\b([^>]*)>(.*?)</textarea>',
      html,
    ).where((match) => BooruHTML.attributes(match[1])['name'] == 'tags').firstOrNull;
    final rawTags = textarea == null ? '' : BooruHTML.plainText(textarea[2]);
    final dimensions = BooruHTML.matches(r'Size:\s*(\d+)\s*x\s*(\d+)', html).firstOrNull;
    final rating = BooruHTML.matches(r'Rating:\s*([a-z]+)', html).firstOrNull?[1] ?? '';
    final score = int.tryParse(BooruHTML.matches(r'Score:\s*(?:<[^>]*>\s*)?(-?\d+)', html).firstOrNull?[1] ?? '') ?? 0;
    final sidebar = tags(data);
    final tagNames = rawTags.isEmpty ? sidebar.map((tag) => tag.name).toList() : splitWhitespace(rawTags);
    final categories = <String, int>{};
    for (final tag in sidebar) {
      categories.putIfAbsent(tag.name, () => tag.category);
    }
    return BooruPost(
      serverID: server.id,
      postID: id,
      previewURL: preview,
      sampleURL: imageURL,
      fileURL: file,
      width: int.tryParse(dimensions?[1] ?? image?['width'] ?? '') ?? 0,
      height: int.tryParse(dimensions?[2] ?? image?['height'] ?? '') ?? 0,
      tags: tagNames,
      artists: sidebar.where((tag) => tag.isArtist).map((tag) => tag.name).toList(),
      rating: normalizedRating(rating, server, modernRatings: modernRatings),
      score: score,
      fileExtension: urlPathExtension(file),
      metadataTags: sidebar.where((tag) => tag.isMetadata).map((tag) => tag.name).toList(),
      reducedDataURL: imageURL,
      tagCategories: categories,
    );
  }

  static String normalizedRating(String raw, BooruServer server, {bool modernRatings = false}) {
    final rating = raw.toLowerCase();
    if (rating == 'safe' || rating == 's' && !(server.usesModernRatings || modernRatings)) return 'g';
    return rating.isEmpty ? '' : rating.substring(0, 1);
  }

  static List<BooruTag> autocompleteTags(Uint8List data, String token) {
    final html = BooruHTML.html(data);
    final result = tags(data);
    final seen = result.map((tag) => tag.name).toSet();
    for (final row in BooruHTML.matches(r'<tr\b[^>]*>(.*?)</tr>', html)) {
      for (final link in BooruHTML.matches(r'<a\b([^>]*)>(.*?)</a>', row[1])) {
        final href = BooruHTML.attributes(link[1])['href'];
        final name = href == null ? null : linkQueryValue(linkQueryItems(href), 'tags');
        if (name == null || name.isEmpty || name.contains(' ') || name.contains('*') || !seen.add(name)) continue;
        final numbers = BooruHTML.matches(r'<td\b[^>]*>\s*([0-9,]+)\s*</td>', row[1]);
        final count = numbers.isEmpty ? 0 : int.tryParse(numbers.last[1].replaceAll(',', '')) ?? 0;
        result.add(BooruTag(name: name, count: count, category: 0));
      }
    }
    final lowered = token.toLowerCase();
    final matching = result.where((tag) => tag.name.toLowerCase().contains(lowered)).toList();
    mergeSort(matching, compare: (a, b) => b.count.compareTo(a.count));
    return matching.take(12).toList();
  }

  static List<BooruTag> tags(Uint8List data) {
    final html = BooruHTML.html(data);
    final seen = <String>{};
    final result = <BooruTag>[];
    for (final item in BooruHTML.matches(r'<li\b([^>]*)>(.*?)</li>', html)) {
      for (final match in BooruHTML.matches(r'<a\b([^>]*)>(.*?)</a>', item[2])) {
        final href = BooruHTML.attributes(match[1])['href'];
        final name = href == null ? null : linkQueryValue(linkQueryItems(href), 'tags');
        if (name == null || ['+', '-', '?'].contains(BooruHTML.plainText(match[2])) || name.contains(' ') || name.isEmpty || !seen.add(name)) continue;
        final counts = BooruHTML.matches(r'(?:</a>\s*|<small[^>]*>)([0-9]+)', item[2]);
        final count = counts.isEmpty ? 0 : int.tryParse(counts.last[1]) ?? 0;
        final classes = splitWhitespace(BooruHTML.attributes(item[1])['class'] ?? '').toSet();
        result.add(
          BooruTag(
            name: name,
            count: count,
            category: item[1].contains('artist') ? 1 : 0,
            isMetadata: classes.intersection(const {'tag-type-metadata', 'tag-type-meta', 'tag-list-meta'}).isNotEmpty,
          ),
        );
        break;
      }
    }
    return result;
  }

  static int? nextOffset(Uint8List data, int offset) {
    int? next;
    for (final match in BooruHTML.matches(r'<a\b([^>]*)>', BooruHTML.html(data))) {
      final href = BooruHTML.attributes(match[1])['href'];
      final items = href == null ? null : linkQueryItems(href);
      if (items == null || !items.any((item) => item.$1 == 's' && item.$2 == 'list')) continue;
      final raw = linkQueryValue(items, 'pid');
      final value = raw == null ? null : parseInt64(raw);
      if (value != null && value > offset && (next == null || value < next)) next = value;
    }
    return next;
  }

  static String? nextPageURL(Uint8List data, BooruServer server, int offset) {
    (int, String)? best;
    final base = Uri.parse('${server.baseURL}/index.php');
    for (final match in BooruHTML.matches(r'<a\b([^>]*)>', BooruHTML.html(data))) {
      final href = BooruHTML.attributes(match[1])['href'];
      if (href == null || linkQueryItems(href) == null) continue;
      Uri resolved;
      try {
        resolved = base.resolve(href);
      } on FormatException {
        continue;
      }
      if (resolved.scheme == 'http') resolved = resolved.replace(scheme: 'https');
      final next = resolved.toString();
      final items = linkQueryItems(next);
      if (!booruSameOrigin(next, server.baseURL) || items == null || !items.any((item) => item.$1 == 's' && item.$2 == 'list')) continue;
      final raw = linkQueryValue(items, 'pid');
      final value = raw == null ? null : parseInt64(raw);
      if (value == null || value <= offset) continue;
      if (best == null || value < best.$1) best = (value, next);
    }
    return best?.$2;
  }

  static List<BooruNote> notes(Uint8List data) {
    final html = BooruHTML.html(data);
    // Legacy notes store geometry in note-box divs and text in corresponding bodies.
    final divs = BooruHTML.matches(r'<div\b([^>]*)>(.*?)</div>', html);
    final result = <BooruNote>[];
    for (final match in divs) {
      final attrs = BooruHTML.attributes(match[1]);
      final raw = attrs['id'], style = attrs['style'];
      if (raw == null || !raw.startsWith('note-box-') || style == null) continue;
      final id = parseInt64(raw.substring(9));
      if (id == null) continue;
      double? dimension(String name) => double.tryParse(
        BooruHTML.matches(
              r'(?:^|;)\s*'
              '$name'
              r':\s*([0-9.]+)px',
              style,
            ).firstOrNull?[1] ??
            '',
      );
      final x = dimension('left'), y = dimension('top'), width = dimension('width'), height = dimension('height');
      final body = divs.where((div) => BooruHTML.attributes(div[1])['id'] == 'note-body-$id').firstOrNull;
      if (x == null || y == null || width == null || height == null || body == null) continue;
      result.add(BooruNote(id: id, x: x, y: y, width: width, height: height, body: BooruHTML.plainText(body[2])));
    }
    return result;
  }
}

/// `BooruDecoder.safeURL`: an HTTPS address without credentials, resolved against the server.
String? safeBooruURL(Object? value, String base) {
  if (value is! String || value.isEmpty) return null;
  if (!RegExp(r"^[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]*$").hasMatch(value)) return null;
  final Uri server;
  Uri url;
  try {
    server = Uri.parse(base.endsWith('/') ? base : '$base/');
    url = server.resolve(value);
  } on FormatException {
    return null;
  }
  // A self-hosted server behind an HTTPS reverse proxy can report its own media as
  // http:// (some build URLs from the request they see). The app reached that
  // host over HTTPS, so upgrade it; plain HTTP on any other host stays rejected.
  if (url.scheme == 'http' && url.port == 80 && url.host.isNotEmpty && url.host == server.host && url.userInfo.isEmpty) {
    url = Uri(
      scheme: 'https',
      host: url.host,
      port: server.hasPort ? server.port : null,
      path: url.path,
      query: url.hasQuery ? url.query : null,
      fragment: url.hasFragment ? url.fragment : null,
    );
  }
  if (url.scheme != 'https' || url.host.isEmpty || url.userInfo.isNotEmpty) return null;
  return url.toString();
}

/// `BooruWebTransport.sameOrigin`: both HTTPS, the same host and port, and no credentials on the first.
bool booruSameOrigin(String lhs, String rhs) {
  final a = SwiftURLComponents.parse(lhs), b = SwiftURLComponents.parse(rhs);
  if (a == null || b == null) return false;
  return a.scheme == 'https' &&
      b.scheme == 'https' &&
      (a.host ?? '').toLowerCase() == (b.host ?? '').toLowerCase() &&
      (a.host ?? '').isNotEmpty &&
      (a.port ?? 443) == (b.port ?? 443) &&
      a.user == null &&
      a.password == null;
}
