import 'package:material_ui/material_ui.dart';

import '../core/content.dart';
import 'thumbnail_image_provider.dart';

/// Thumbnail pixels are bounded by the display size. The shared provider looks
/// up browser cookies only when a network request is actually needed, allowing
/// cached and offline thumbnails to appear without an asynchronous header gate.
class SessionImage extends StatelessWidget {
  const SessionImage({
    super.key,
    required this.url,
    this.referer,
    this.fit = BoxFit.cover,
    this.height,
    this.width,
    this.cacheWidth,
    this.headers = const {},
    this.errorBuilder,
  });
  final Uri url;
  final Uri? referer;
  final BoxFit fit;
  final double? height;
  final double? width;
  final int? cacheWidth;
  final Map<String, String> headers;
  final ImageErrorWidgetBuilder? errorBuilder;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final limit =
          cacheWidth ??
          thumbnailDecodeLimit(
            Size(
              width ?? constraints.maxWidth,
              height ?? constraints.maxHeight,
            ),
            MediaQuery.devicePixelRatioOf(context),
          );
      return Image(
        image: thumbnailImageProvider(url, {
          if (referer != null) 'Referer': referer.toString(),
          ...headers,
        }, limit),
        fit: fit,
        height: height,
        width: width,
        filterQuality: FilterQuality.low,
        errorBuilder:
            errorBuilder ??
            (_, _, _) => const Icon(Icons.broken_image_outlined),
      );
    },
  );
}

class ReaderPageThumbnail extends StatelessWidget {
  const ReaderPageThumbnail({
    super.key,
    required this.page,
    this.referer,
    this.fit = BoxFit.cover,
  });
  final ReaderPage page;
  final Uri? referer;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) => page.previewUrl == null
      ? ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: const Center(child: Icon(Icons.image_outlined)),
        )
      : SessionImage(
          url: page.previewUrl!,
          headers: page.headers,
          referer: referer,
          fit: fit,
        );
}
