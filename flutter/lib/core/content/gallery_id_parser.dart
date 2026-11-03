import 'content_url.dart';
import 'keyed_catalog_source.dart';
import 'site_account.dart';

abstract final class GalleryIDParser {
  static final _mangaIdRegex = RegExp(
    r'(?:(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}/)?(?:galleries|reader|r)/(\d{4,10})(?:\.html)?|(?:(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}/)?[^/\s]+/[^/\s]*-(\d{4,10})\.html',
    caseSensitive: false,
  );
  static final _nestedUrlRegex = RegExp(r'[?&]u=([^&\s]+)', caseSensitive: false);
  static final _tokenDigitsRegex = RegExp(r'^\d{4,10}$');

  /// Extracts gallery IDs from text, URLs, or share payloads.
  static List<int> parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return [];

    final ids = <int>[];
    final seen = <int>{};

    void add(String digits) {
      final id = int.tryParse(digits);
      if (id == null || id < 1000 || id > 9999999999) return;
      if (seen.add(id)) ids.add(id);
    }

    void addFrom(String value, [int depth = 0]) {
      if (depth > 3) return;
      final keyed = KeyedCatalogSource.links(value);
      GalleryKeys.shared.rememberAll([for (final link in keyed) (link.id, link.key)]);
      for (final link in keyed) {
        if (seen.add(link.id)) ids.add(link.id);
      }
      for (final match in _mangaIdRegex.allMatches(value)) {
        final first = match.group(1), second = match.group(2);
        if (first != null) {
          add(first);
        } else if (second != null) {
          add(second);
        }
      }
      for (final match in _nestedUrlRegex.allMatches(value)) {
        final decoded = ContentURL.removingPercentEncoding(match.group(1)!);
        if (decoded != null) addFrom(decoded, depth + 1);
      }
    }

    addFrom(text);
    if (ids.isNotEmpty) return ids;

    // Fallback: split by whitespace, comma, semicolons
    for (final token in text.split(RegExp('[ \t\r\n,;]'))) {
      if (_tokenDigitsRegex.hasMatch(token)) add(token);
    }
    return ids;
  }
}
