import 'dart:async';
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/storage/local_thumbnail_cache.dart';

/// `LocalThumbnailView`: a saved cover from its file through the shared cache. Only visible
/// cells request files, a removed cell cancels its request, and a changed cover redraws.
class LocalThumbnail extends StatefulWidget {
  const LocalThumbnail({super.key, required this.path, required this.placeholder, this.revision = ''});
  final String? path;
  final String revision;
  final Widget placeholder;

  @override
  State<LocalThumbnail> createState() => _LocalThumbnailState();
}

class _LocalThumbnailState extends State<LocalThumbnail> {
  ui.Image? _image;
  LocalThumbnailRequest? _request;
  StreamSubscription<String?>? _invalidations;

  @override
  void initState() {
    super.initState();
    _invalidations = LocalThumbnailCache.shared.invalidations.listen((path) {
      if (path == null || path == widget.path) _load();
    });
    _load();
  }

  @override
  void didUpdateWidget(LocalThumbnail old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path || old.revision != widget.revision) _load();
  }

  @override
  void dispose() {
    _request?.cancel();
    _invalidations?.cancel();
    super.dispose();
  }

  void _load() {
    _request?.cancel();
    final path = widget.path;
    if (path == null) {
      setState(() => _image = null);
      return;
    }
    final cached = LocalThumbnailCache.shared.image(path);
    if (cached != null) {
      setState(() => _image = cached);
      return;
    }
    final request = LocalThumbnailCache.shared.request(path);
    _request = request;
    request.image.then((image) {
      if (mounted && _request == request) setState(() => _image = image);
    });
  }

  @override
  Widget build(BuildContext context) =>
      _image == null ? widget.placeholder : RawImage(image: _image, fit: BoxFit.cover, filterQuality: ui.FilterQuality.medium);
}
