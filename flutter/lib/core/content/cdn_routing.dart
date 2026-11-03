import 'content_errors.dart';
import 'manga_urls.dart';

/// The image server routing an indexed catalog publishes as a small script, read without running it.
class CDNRouting {
  CDNRouting._(this.prefix, this.defaultValue, this.alternateValue, this.alternateBuckets);

  final String prefix;
  final int defaultValue;
  final int alternateValue;
  final Set<int> alternateBuckets;

  static final _pattern = RegExp(
    r"^\s*'use strict';\s*gg\s*=\s*\{\s*m:\s*function\(g\)\s*\{\s*var o = ([01]);\s*switch \(g\) \{\s*((?:case \d+:\s*)+)o = ([01]); break;\s*\}\s*return o;\s*\},\s*s: function\(h\) \{ var m = /\(\.\.\)\(\.\)\$/.exec\(h\); return parseInt\(m\[2\]\+m\[1\], 16\).toString\(10\); \},\s*b: '([0-9]+/)'\s*\};\s*$",
    dotAll: true,
  );

  factory CDNRouting(String text) {
    final match = _pattern.firstMatch(text);
    if (match == null) throw ContentError.unsupportedFormat;
    final initial = int.tryParse(match[1]!), alternate = int.tryParse(match[3]!);
    if (initial == null || alternate == null) throw ContentError.unsupportedFormat;
    final buckets = RegExp(r'case (\d+):').allMatches(match[2]!).map((value) => int.tryParse(value[1]!)).nonNulls.toList();
    if (!buckets.every((bucket) => bucket >= 0 && bucket < 4096)) throw ContentError.unsupportedFormat;
    return CDNRouting._(match[4]!, initial, alternate, buckets.toSet());
  }

  Uri url({required String hash, required String format, required bool thumbnail}) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) || !['webp', 'avif'].contains(format)) throw ContentError.unsupportedFormat;
    final last = hash.substring(63), middle = hash.substring(61, 63);
    final bucket = int.tryParse(last + middle, radix: 16);
    if (bucket == null) throw ContentError.unsupportedFormat;
    final alternate = alternateBuckets.contains(bucket) ? alternateValue : defaultValue;
    final host = thumbnail ? (alternate == 0 ? 'atn' : 'btn') : '${format == 'webp' ? 'w' : 'a'}${1 + alternate}';
    final path = thumbnail ? '${format}smalltn/$last/$middle/$hash.$format' : '$prefix$bucket/$hash.$format';
    final cdn = MangaUrls.cdnHost;
    final url = cdn.isEmpty ? null : Uri.tryParse('https://$host.$cdn/$path');
    if (url == null) throw ContentError.invalidResponse;
    return url;
  }
}
