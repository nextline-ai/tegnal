import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show mapEquals;

import '../data/session_client.dart';

import '../core/content.dart';
import 'session_image_provider.dart';

/// Shared by visible pages and prefetch so they use the same decoded cache key.
ImageProvider<Object> readerImageProvider(
  ReaderPage page,
  Map<String, String> headers,
  int decodeLimit,
) {
  final base = sessionImageProvider(page.url, headers);
  return ResizeImage(
    base,
    width: decodeLimit,
    height: decodeLimit,
    policy: ResizeImagePolicy.fit,
  );
}

/// Keeps only provider keys, never image pixels; Flutter owns decoded eviction.
class ReaderPreparedImages {
  final List<_PreparedImage> _entries = [];

  ImageProvider<Object>? find(ReaderPage page, int limit) {
    for (final entry in _entries.reversed) {
      if (entry.url == page.url &&
          entry.limit == limit &&
          entry.revision == BrowserSession.revisionFor(page.url) &&
          mapEquals(entry.pageHeaders, page.headers)) {
        final status = PaintingBinding.instance.imageCache.statusForKey(
          entry.key,
        );
        if (!status.pending && (status.keepAlive || status.live)) {
          return entry.provider;
        }
      }
    }
    return null;
  }

  Future<void> remember(
    ReaderPage page,
    int limit,
    ImageProvider<Object> provider,
    ImageConfiguration configuration,
  ) async {
    final revision = BrowserSession.revisionFor(page.url);
    final base = provider is ResizeImage ? provider.imageProvider : provider;
    if (base is SessionNetworkImage && base.sessionRevision != revision) return;
    final key = await provider.obtainKey(configuration);
    if (revision != BrowserSession.revisionFor(page.url)) return;
    _entries.removeWhere(
      (entry) => entry.url == page.url && entry.limit == limit,
    );
    _entries.add(
      _PreparedImage(
        page.url,
        Map.of(page.headers),
        limit,
        revision,
        provider,
        key,
      ),
    );
    while (_entries.length > 5) {
      _entries.removeAt(0);
    }
  }
}

class _PreparedImage {
  _PreparedImage(
    this.url,
    this.pageHeaders,
    this.limit,
    this.revision,
    this.provider,
    this.key,
  );
  final Uri url;
  final Map<String, String> pageHeaders;
  final int limit;
  final String revision;
  final ImageProvider<Object> provider;
  final Object key;
}
