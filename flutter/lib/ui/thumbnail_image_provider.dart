import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:material_ui/material_ui.dart';

import 'session_image_provider.dart';

/// One screen ahead, so covers are decoded before they scroll into view.
const thumbnailScrollCacheExtent = ScrollCacheExtent.viewport(1);

/// Quantized display pixels prevent nearly identical layouts producing a new
/// decoded cache entry each time. Both axes are bounded: width-only decoding
/// leaves very tall pages unexpectedly large in memory.
int thumbnailDecodeLimit(Size displaySize, double devicePixelRatio) {
  final edge = displaySize.longestSide * devicePixelRatio;
  if (!edge.isFinite || edge <= 0) return 600;
  return ((edge / 64).ceil() * 64).clamp(64, 768);
}

ImageProvider<Object> thumbnailImageProvider(
  Uri url,
  Map<String, String> headers,
  int decodeLimit,
) => ResizeImage(
  sessionImageProvider(url, headers, maximumBytes: thumbnailMaximumBytes),
  width: decodeLimit.clamp(1, 768),
  height: decodeLimit.clamp(1, 768),
  policy: ResizeImagePolicy.fit,
);
