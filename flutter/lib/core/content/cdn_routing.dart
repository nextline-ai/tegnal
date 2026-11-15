import 'content_errors.dart';
import 'manga_urls.dart';

/// The image server routing an indexed catalog publishes as a small script, read without running it.
/// It is read in pieces, so a reformatted file, another group of cases or another server number still
/// routes; only a script with a piece this reading can't explain is refused.
class CDNRouting {
  CDNRouting._(this.prefix, this.defaultValue, this.bucketValues);

  final String prefix;
  final int defaultValue;

  /// The server number each listed bucket goes to instead of the default.
  final Map<int, int> bucketValues;

  static final _prefix = RegExp(r'''\bb\s*:\s*['"]([0-9]+/)['"]''');
  static final _default = RegExp(r'\bvar\s+o\s*=\s*([0-9]{1,2})\s*;');
  static final _group = RegExp(r'((?:\bcase\s+[0-9]+\s*:\s*)+)o\s*=\s*([0-9]{1,2})\s*;\s*break\s*;');
  static final _case = RegExp(r'\bcase\s+([0-9]+)\s*:');

  factory CDNRouting(String text) {
    final prefix = _prefix.firstMatch(text)?[1];
    final initial = int.tryParse(_default.firstMatch(text)?[1] ?? '');
    if (prefix == null || initial == null || initial >= 26) throw ContentError.unsupportedFormat;
    final values = <int, int>{};
    var read = 0;
    for (final group in _group.allMatches(text)) {
      final value = int.tryParse(group[2]!);
      if (value == null || value >= 26) throw ContentError.unsupportedFormat;
      for (final item in _case.allMatches(group[1]!)) {
        final bucket = int.tryParse(item[1]!);
        if (bucket == null || bucket < 0 || bucket >= 4096) throw ContentError.unsupportedFormat;
        values[bucket] = value;
        read += 1;
      }
    }
    // Every case the script lists has to be one this reading understood.
    if (read != _case.allMatches(text).length) throw ContentError.unsupportedFormat;
    return CDNRouting._(prefix, initial, values);
  }

  Uri url({required String hash, required String format, required bool thumbnail}) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) || !['webp', 'avif'].contains(format)) throw ContentError.unsupportedFormat;
    final last = hash.substring(63), middle = hash.substring(61, 63);
    final bucket = int.tryParse(last + middle, radix: 16);
    if (bucket == null) throw ContentError.unsupportedFormat;
    final value = bucketValues[bucket] ?? defaultValue;
    // Thumbnail servers are lettered from a, page servers numbered from 1.
    final host = thumbnail ? '${String.fromCharCode(97 + value)}tn' : '${format == 'webp' ? 'w' : 'a'}${1 + value}';
    final path = thumbnail ? '${format}smalltn/$last/$middle/$hash.$format' : '$prefix$bucket/$hash.$format';
    final cdn = MangaUrls.cdnHost;
    final url = cdn.isEmpty ? null : Uri.tryParse('https://$host.$cdn/$path');
    if (url == null) throw ContentError.invalidResponse;
    return url;
  }
}
