import 'dart:async';
import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:video_player/video_player.dart';

import '../../core/booru/booru_models.dart';
import '../../core/booru/booru_support.dart';
import '../../core/support/l10n.dart';
import '../booru/booru_media_view.dart' show BooruVideoControls;
import '../content/gallery_detail_view.dart' show GlassIconButton;
import '../content/reader_models.dart' show ReaderPreferences;

/// The native downloads screen's QuickLook preview: one downloaded file, full screen, an image
/// that zooms or a video that plays.
class DownloadPreviewPage extends StatefulWidget {
  const DownloadPreviewPage({super.key, required this.file});
  final File file;

  static Future<void> open(BuildContext context, File file) => Navigator.of(context, rootNavigator: true).push(
    CupertinoPageRoute<void>(fullscreenDialog: true, builder: (_) => DownloadPreviewPage(file: file)),
  );

  static bool isVideo(File file) {
    final name = file.uri.pathSegments.lastOrNull ?? '';
    final dot = name.lastIndexOf('.');
    return dot >= 0 && BooruPost.videoExtensions.contains(name.substring(dot + 1).toLowerCase());
  }

  @override
  State<DownloadPreviewPage> createState() => _DownloadPreviewPageState();
}

class _DownloadPreviewPageState extends State<DownloadPreviewPage> {
  VideoPlayerController? _video;
  bool _failed = false;
  bool _controls = true;
  Timer? _hide;

  BooruVideoAudioPreferences get _audio => BooruVideoAudioPreferences(ReaderPreferences.booruDefaults);

  @override
  void initState() {
    super.initState();
    if (DownloadPreviewPage.isVideo(widget.file)) _loadVideo();
  }

  Future<void> _loadVideo() async {
    final controller = _video = VideoPlayerController.file(widget.file, videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true));
    controller.addListener(_changed);
    try {
      await controller.initialize();
      if (!mounted) return;
      await controller.setVolume(_audio.muted ? 0 : 1);
      await controller.play();
      _scheduleHide();
    } on Object {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _scheduleHide() {
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 3), () {
      if (mounted && (_video?.value.isPlaying ?? false)) setState(() => _controls = false);
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    _video?.removeListener(_changed);
    _video?.dispose();
    super.dispose();
  }

  Widget _content() {
    const white = Color(0xFFFFFFFF);
    final unavailable = Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(CupertinoIcons.exclamationmark_triangle, size: 36, color: white),
          const SizedBox(height: 12),
          Text(widget.file.uri.pathSegments.lastOrNull ?? '', style: const TextStyle(color: white)),
        ],
      ),
    );
    final video = _video;
    if (video == null) {
      return InteractiveViewer(
        maxScale: 8,
        child: Center(
          child: Image.file(widget.file, fit: BoxFit.contain, gaplessPlayback: true, errorBuilder: (context, error, stack) => unavailable),
        ),
      );
    }
    if (_failed) return unavailable;
    if (!video.value.isInitialized) return const Center(child: CupertinoActivityIndicator(color: white));
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() => _controls = !_controls);
        _scheduleHide();
      },
      child: Center(
        child: AspectRatio(
          aspectRatio: video.value.aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              VideoPlayer(video),
              if (_controls)
                BooruVideoControls(
                  controller: video,
                  onMute: (muted) {
                    _audio.update(muted: muted);
                    video.setVolume(muted ? 0 : 1);
                    _scheduleHide();
                  },
                  onInteraction: _scheduleHide,
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFF000000),
    child: SafeArea(
      child: Stack(
        children: [
          Positioned.fill(child: _content()),
          Positioned(
            top: 8,
            left: 16,
            child: GlassIconButton(icon: CupertinoIcons.xmark, label: L10n.text('Close'), onPressed: () => Navigator.of(context).pop()),
          ),
        ],
      ),
    ),
  );
}
