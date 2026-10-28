import 'package:material_ui/material_ui.dart';

import '../core/app_controller.dart';
import '../core/content.dart';
import 'l10n.dart';
import 'session_image_provider.dart';

/// Uses the visible thumbnail's byte-cache key, without decoding every cover.
Future<void> cacheMetadataCover(ContentItem item) async {
  final url = item.thumbnailUrl;
  if (url == null) throw const ContentException('Unable to load image');
  if (url.scheme == 'file') return;
  await SessionImageLoader(maximumBytes: 2 * 1024 * 1024).load(
    url,
    headers: {if (item.pageUrl != null) 'Referer': item.pageUrl.toString()},
  );
}

/// Keeps import enrichment alive across tabs and onboarding, only in foreground.
class MetadataFillScope extends StatefulWidget {
  const MetadataFillScope({
    super.key,
    required this.controller,
    required this.child,
  });
  final AppController controller;
  final Widget child;
  @override
  State<MetadataFillScope> createState() => _MetadataFillScopeState();
}

class _MetadataFillScopeState extends State<MetadataFillScope>
    with WidgetsBindingObserver {
  void _attach() {
    final state = WidgetsBinding.instance.lifecycleState;
    widget.controller.setMetadataFillForeground(
      state == null || state == AppLifecycleState.resumed,
      notify: false,
    );
    widget.controller.setMetadataCoverCache(cacheMetadataCover);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _attach();
  }

  @override
  void didUpdateWidget(covariant MetadataFillScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.setMetadataFillForeground(false, notify: false);
      _attach();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => widget.controller
      .setMetadataFillForeground(state == AppLifecycleState.resumed);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.setMetadataFillForeground(false, notify: false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class MetadataFillNotice extends StatelessWidget {
  const MetadataFillNotice({
    super.key,
    required this.controller,
    required this.onConnect,
  });
  final AppController controller;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller;
      if (!c.metadataFillNoticeVisible) return const SizedBox.shrink();
      final waiting = c.metadataFillWaitingForSource;
      final running = c.metadataFillRunning;
      final subtitle = waiting
          ? 'Connect a comics website to fill imported covers, titles and tags.'
          : c.metadataFillPaused
          ? 'Metadata filling is paused.'
          : c.metadataFillError ??
                (c.metadataFillTotal >= 100
                    ? 'Filling %@ works in the background may warm up your device and use battery. Recently saved works are processed first.'
                    : 'Fetch missing covers and metadata in the background.');
      return Padding(
        key: const ValueKey('metadata-fill-notice'),
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: Material(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xff3d2f1b)
              : const Color(0xffffedd1),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 4, right: 10),
                      child: Icon(
                        waiting ? Icons.link : Icons.thermostat_outlined,
                        size: 22,
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            L10n.tr(context, 'Filling missing information'),
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 3),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 96),
                            child: SingleChildScrollView(
                              child: Text(
                                L10n.tr(
                                  context,
                                  subtitle,
                                ).replaceFirst('%@', '${c.metadataFillTotal}'),
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: L10n.tr(context, 'Dismiss filling notice'),
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: c.dismissMetadataFillNotice,
                    ),
                  ],
                ),
                if (running)
                  Padding(
                    padding: const EdgeInsets.only(top: 8, right: 8),
                    child: LinearProgressIndicator(
                      value: c.metadataFillTotal == 0
                          ? 0
                          : (c.metadataFillCompleted / c.metadataFillTotal)
                                .clamp(0, 1),
                    ),
                  ),
                const SizedBox(height: 2),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  children: [
                    if (c.metadataFillTotal > 0)
                      Text(
                        '${c.metadataFillCompleted} / ${c.metadataFillTotal}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    TextButton.icon(
                      icon: Icon(
                        waiting
                            ? Icons.add_link
                            : running
                            ? Icons.pause
                            : Icons.play_arrow,
                        size: 18,
                      ),
                      label: Text(
                        L10n.tr(
                          context,
                          waiting
                              ? 'Connect a Website'
                              : running
                              ? 'Pause'
                              : 'Fill Covers, Titles, and Tags',
                        ),
                      ),
                      onPressed: waiting
                          ? onConnect
                          : running
                          ? c.pauseMetadataFill
                          : () => c.fillMissingMetadata(),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
