import 'package:material_ui/material_ui.dart';

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
