import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/content/content_errors.dart';
import '../../core/content/gallery_content.dart';
import 'image_translation.dart';
import 'page_image_store.dart';
import 'reader_models.dart';
import 'reader_translation.dart';

/// How a page reports a tap: the horizontal position as a fraction of the reader's width.
typedef ReaderTap = void Function(double x);

/// The pages a reader shows at once (`ReaderLayout.count`), never fewer than one.
int readerSpreadCount(int pagesPerSpread) => math.max(1, math.min(4, pagesPerSpread));

/// `ReaderPager`: one spread per screen, swiped horizontally (optionally right to left) or vertically.
class ReaderPager extends StatefulWidget {
  const ReaderPager({
    super.key,
    required this.gallery,
    required this.images,
    required this.vertical,
    required this.rtl,
    required this.current,
    required this.onPageChanged,
    required this.tap,
    required this.bookmark,
    required this.count,
    required this.onZoomChanged,
    this.isActive = true,
  });

  final NativeGallery gallery;
  final PageImageStore images;
  final bool vertical;
  final bool rtl;
  final int current;
  final ValueChanged<int> onPageChanged;
  final ReaderTap tap;
  final VoidCallback bookmark;
  final int count;
  final void Function(int index, bool zoomed) onZoomChanged;
  final bool isActive;

  @override
  State<ReaderPager> createState() => _ReaderPagerState();
}

class _ReaderPagerState extends State<ReaderPager> {
  late final PageController _controller = PageController(initialPage: _spread(widget.current));
  final _zoomed = <int>{};

  int _spread(int page) => page ~/ widget.count;
  int get _spreads => (widget.gallery.pages.length + widget.count - 1) ~/ widget.count;

  @override
  void didUpdateWidget(ReaderPager old) {
    super.didUpdateWidget(old);
    final target = _spread(widget.current);
    if (_controller.hasClients && (_controller.page?.round() ?? target) != target) {
      _controller.jumpToPage(target);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageView.builder(
      controller: _controller,
      scrollDirection: widget.vertical ? Axis.vertical : Axis.horizontal,
      reverse: widget.rtl && !widget.vertical,
      physics: _zoomed.isEmpty ? const PageScrollPhysics() : const NeverScrollableScrollPhysics(),
      itemCount: _spreads,
      onPageChanged: (spread) => widget.onPageChanged(spread * widget.count),
      itemBuilder: (context, spread) => ReaderSpreadView(
        gallery: widget.gallery,
        images: widget.images,
        start: spread * widget.count,
        count: widget.count,
        rtl: widget.rtl,
        tap: widget.tap,
        bookmark: widget.bookmark,
        isActive: widget.isActive,
        onZoomChanged: (index, zoomed) {
          setState(() => zoomed ? _zoomed.add(index) : _zoomed.remove(index));
          widget.onZoomChanged(index, zoomed);
        },
      ),
    );
  }
}

/// `ReaderContinuousView`: spreads stacked top to bottom at their natural height.
class ReaderContinuousView extends StatefulWidget {
  const ReaderContinuousView({
    super.key,
    required this.gallery,
    required this.images,
    required this.current,
    required this.onPageChanged,
    required this.tap,
    required this.bookmark,
    required this.count,
    required this.rtl,
    required this.onZoomChanged,
    this.isActive = true,
  });

  final NativeGallery gallery;
  final PageImageStore images;
  final int current;
  final ValueChanged<int> onPageChanged;
  final ReaderTap tap;
  final VoidCallback bookmark;
  final int count;
  final bool rtl;
  final void Function(int index, bool zoomed) onZoomChanged;
  final bool isActive;

  @override
  State<ReaderContinuousView> createState() => _ReaderContinuousViewState();
}

class _ReaderContinuousViewState extends State<ReaderContinuousView> {
  ScrollController? _controller;
  double _width = 0;
  int _reported = -1;

  double _ratio(int start) {
    final end = math.min(widget.gallery.pages.length, start + widget.count);
    var ratio = 1.0;
    for (var index = start; index < end; index++) {
      final page = widget.gallery.pages[index];
      ratio = index == start ? math.max(1, page.height) / math.max(1, page.width) : math.max(ratio, math.max(1, page.height) / math.max(1, page.width));
    }
    return ratio;
  }

  double _height(int start) => _width / math.max(1, math.min(widget.count, widget.gallery.pages.length - start)) * _ratio(start);

  double _offset(int page) {
    var offset = 0.0;
    for (var start = 0; start < page; start += widget.count) {
      offset += _height(start) + 4;
    }
    return offset;
  }

  void _scrolled() {
    final position = _controller!.offset;
    var offset = 0.0;
    var start = 0;
    while (start < widget.gallery.pages.length) {
      final next = offset + _height(start) + 4;
      if (next > position + 1) break;
      offset = next;
      start += widget.count;
    }
    if (start != _reported && start < widget.gallery.pages.length) {
      _reported = start;
      widget.onPageChanged(start);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _width = constraints.maxWidth;
        if (_controller == null) {
          _reported = widget.current;
          _controller = ScrollController(initialScrollOffset: _offset(widget.current))..addListener(_scrolled);
        }
        final spreads = (widget.gallery.pages.length + widget.count - 1) ~/ widget.count;
        return ListView.separated(
          controller: _controller,
          itemCount: spreads,
          separatorBuilder: (_, _) => const SizedBox(height: 4),
          itemBuilder: (context, spread) => SizedBox(
            height: _height(spread * widget.count),
            child: ReaderSpreadView(
              gallery: widget.gallery,
              images: widget.images,
              start: spread * widget.count,
              count: widget.count,
              rtl: widget.rtl,
              tap: widget.tap,
              bookmark: widget.bookmark,
              isActive: widget.isActive,
              onZoomChanged: widget.onZoomChanged,
            ),
          ),
        );
      },
    );
  }
}

/// `ReaderSpreadView`: up to four pages side by side, 2 pt apart, reversed when reading right to left.
class ReaderSpreadView extends StatelessWidget {
  const ReaderSpreadView({
    super.key,
    required this.gallery,
    required this.images,
    required this.start,
    required this.count,
    required this.rtl,
    required this.tap,
    required this.bookmark,
    required this.onZoomChanged,
    this.isActive = true,
  });

  final NativeGallery gallery;
  final PageImageStore images;
  final int start;
  final int count;
  final bool rtl;
  final ReaderTap tap;
  final VoidCallback bookmark;
  final void Function(int index, bool zoomed) onZoomChanged;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final indices = [for (var index = start; index < math.min(gallery.pages.length, start + count); index++) index];
    final ordered = rtl ? indices.reversed.toList() : indices;
    return ColoredBox(
      color: const Color(0xFF000000),
      child: Row(
        children: [
          for (final (slotIndex, index) in ordered.indexed) ...[
            if (slotIndex > 0) const SizedBox(width: 2),
            Expanded(
              child: ReaderPageView(
                key: ValueKey(gallery.pages[index].hash),
                page: gallery.pages[index],
                galleryID: gallery.id,
                images: images,
                isActive: isActive,
                tap: (x) => tap((slotIndex + x) / ordered.length),
                bookmark: bookmark,
                onZoomChanged: (zoomed) => onZoomChanged(index, zoomed),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One page: the thumbnail while the full page loads, then a zoomable image.
class ReaderPageView extends StatefulWidget {
  const ReaderPageView({
    super.key,
    required this.page,
    required this.galleryID,
    required this.images,
    required this.tap,
    required this.bookmark,
    required this.onZoomChanged,
    this.isActive = true,
  });

  final GalleryPage page;
  final int galleryID;
  final PageImageStore images;
  final ReaderTap tap;
  final VoidCallback bookmark;
  final ValueChanged<bool> onZoomChanged;
  final bool isActive;

  @override
  State<ReaderPageView> createState() => _ReaderPageViewState();
}

class _ReaderPageViewState extends State<ReaderPageView> {
  ui.Image? _image;
  bool _fullResolution = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final full = widget.images.cachedImage(widget.page.hash);
    _image = full ?? widget.images.cachedImage(widget.page.hash, thumbnail: true);
    _fullResolution = full != null;
    _load();
  }

  @override
  void didUpdateWidget(ReaderPageView old) {
    super.didUpdateWidget(old);
    if (widget.isActive && !old.isActive) _load();
  }

  Future<void> _load() async {
    if (!widget.isActive || _fullResolution) return;
    setState(() => _error = null);
    try {
      final image = await widget.images.load(widget.page, galleryID: widget.galleryID);
      if (!mounted) return;
      setState(() {
        _image = image;
        _fullResolution = true;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = ContentError.message(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) {
      return LayoutBuilder(
        builder: (context, constraints) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => widget.tap(details.localPosition.dx / math.max(1, constraints.maxWidth)),
          child: Center(
            child: _error == null ? const CupertinoActivityIndicator(color: Color(0xFFFFFFFF)) : _PageError(message: _error!, retry: _load, prominent: true),
          ),
        ),
      );
    }
    return Stack(
      children: [
        Positioned.fill(
          child: ZoomablePageView(
            image: image,
            tap: widget.tap,
            bookmark: widget.bookmark,
            onZoomChanged: widget.onZoomChanged,
            translation: ReaderTranslationScope.of(context)?.balloons(widget.page.hash) ?? const [],
          ),
        ),
        if (_error != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 12,
            child: Center(
              child: _PageError(message: _error!, retry: _load),
            ),
          ),
      ],
    );
  }
}

class _PageError extends StatelessWidget {
  const _PageError({required this.message, required this.retry, this.prominent = false});
  final String message;
  final VoidCallback retry;
  final bool prominent;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: retry,
    child: Container(
      padding: const EdgeInsets.all(10),
      decoration: const ShapeDecoration(color: Color(0xBF000000), shape: StadiumBorder()),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(CupertinoIcons.arrow_clockwise, size: 13, color: Color(0xFFFFFFFF)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              message,
              style: TextStyle(fontSize: prominent ? 15 : 12, color: const Color(0xFFFFFFFF)),
            ),
          ),
        ],
      ),
    ),
  );
}

/// `ZoomablePageView`: the page fitted to the screen, pinch or double tap to zoom up to 5×.
/// A single tap reports where it landed (the center while zoomed); holding bookmarks.
class ZoomablePageView extends StatefulWidget {
  const ZoomablePageView({super.key, required this.image, required this.tap, required this.bookmark, required this.onZoomChanged, this.translation = const []});
  final ui.Image image;

  /// Translated balloons laid over the page, zooming and panning with it.
  final List<TranslatedRegion> translation;
  final ReaderTap tap;
  final VoidCallback bookmark;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<ZoomablePageView> createState() => _ZoomablePageViewState();
}

class _ZoomablePageViewState extends State<ZoomablePageView> with SingleTickerProviderStateMixin {
  final _transform = TransformationController();
  late final AnimationController _animation = AnimationController(vsync: this, duration: const Duration(milliseconds: 280));
  Animation<Matrix4>? _zoom;
  Offset? _doubleTapPosition;
  bool _zoomed = false;

  /// Read on every build, so a change in the viewer settings reaches pages already open.
  bool get _doubleTapZooms => ReaderPreferences.doubleTapZooms;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_reportZoom);
    _animation.addListener(() {
      if (_zoom != null) _transform.value = _zoom!.value;
    });
  }

  @override
  void dispose() {
    if (_zoomed) widget.onZoomChanged(false);
    _transform.dispose();
    _animation.dispose();
    super.dispose();
  }

  double get _scale => _transform.value.getMaxScaleOnAxis();

  void _reportZoom() {
    final zoomed = _scale > 1.01;
    if (zoomed != _zoomed) {
      _zoomed = zoomed;
      widget.onZoomChanged(zoomed);
      setState(() {});
    }
  }

  void _animateTo(Matrix4 target) {
    _zoom = Matrix4Tween(begin: _transform.value, end: target).animate(CurvedAnimation(parent: _animation, curve: Curves.easeOutCubic));
    _animation.forward(from: 0);
  }

  void _doubleTap(Size size) {
    if (_scale > 1.1) return _animateTo(Matrix4.identity());
    // Zoom to a rectangle 1/2.5 of the viewport around the tapped point.
    final point = _doubleTapPosition ?? size.center(Offset.zero);
    const scale = 2.5;
    final x = -point.dx * (scale - 1);
    final y = -point.dy * (scale - 1);
    _animateTo(
      Matrix4.identity()
        ..translateByDouble(x.clamp(-size.width * (scale - 1), 0), y.clamp(-size.height * (scale - 1), 0), 0, 1)
        ..scaleByDouble(scale, scale, 1, 1),
    );
  }

  /// Where the fitted page sits inside the view.
  Rect _imageRect(Size size) {
    final fitted = applyBoxFit(BoxFit.contain, Size(widget.image.width.toDouble(), widget.image.height.toDouble()), size).destination;
    return Alignment.center.inscribe(fitted, Offset.zero & size);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => widget.tap(_zoomed ? 0.5 : details.localPosition.dx / math.max(1, size.width)),
          // Without double tap zoom, quick taps on the sides only turn pages, and a tap no
          // longer waits to see whether a second one follows.
          onDoubleTapDown: _doubleTapZooms ? (details) => _doubleTapPosition = details.localPosition : null,
          onDoubleTap: _doubleTapZooms ? () => _doubleTap(size) : null,
          onLongPress: widget.bookmark,
          child: InteractiveViewer(
            transformationController: _transform,
            minScale: 1,
            maxScale: 5,
            panEnabled: _zoomed,
            boundaryMargin: _zoomed ? EdgeInsets.symmetric(horizontal: size.width / 2, vertical: size.height / 2) : EdgeInsets.zero,
            child: SizedBox.fromSize(
              size: size,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: RawImage(image: widget.image, fit: BoxFit.contain, filterQuality: ui.FilterQuality.medium),
                  ),
                  if (widget.translation.isNotEmpty)
                    Positioned.fromRect(
                      rect: _imageRect(size),
                      child: TranslatedRegionsLayer(regions: widget.translation),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
