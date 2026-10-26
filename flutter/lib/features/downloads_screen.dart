import 'package:material_ui/material_ui.dart';

import '../core/app_controller.dart';
import '../data/download_manager.dart';
import '../ui/common.dart';
import '../ui/l10n.dart';
import '../ui/session_image.dart';
import 'reader_screen.dart';

class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({
    super.key,
    required this.controller,
    required this.downloads,
  });
  final AppController controller;
  final DownloadManager downloads;

  Widget _entry(BuildContext context, DownloadEntry entry) {
    final complete = entry.status == DownloadStatus.complete;
    final active =
        entry.status == DownloadStatus.downloading ||
        entry.status == DownloadStatus.queued;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: complete ? () => _open(context, entry) : null,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 64,
                  height: 88,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: entry.item.thumbnailUrl == null
                      ? const Icon(Icons.menu_book, color: Colors.grey)
                      : SessionImage(
                          url: entry.item.thumbnailUrl!,
                          referer: entry.item.pageUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.image_outlined,
                            color: Colors.grey,
                          ),
                        ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onTap: complete ? () => _open(context, entry) : null,
                    child: Text(
                      entry.item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        height: 1.2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${entry.completed} / ${entry.pages.length} · ${L10n.tr(context, entry.status.name)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: complete
                          ? const Color(0xFF34C759)
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 9),
                  LinearProgressIndicator(
                    value:
                        (entry.pages.isEmpty
                                ? 0.0
                                : entry.completed / entry.pages.length)
                            .clamp(0.0, 1.0),
                    minHeight: 4,
                    borderRadius: BorderRadius.circular(3),
                    color: complete
                        ? const Color(0xFF34C759)
                        : Theme.of(context).colorScheme.primary,
                    semanticsLabel: L10n.tr(context, 'Downloads'),
                    semanticsValue:
                        '${entry.completed} / ${entry.pages.length}',
                  ),
                  if (entry.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        entry.error!,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFFFF3B30),
                        ),
                      ),
                    ),
                  Row(
                    children: [
                      TextButton(
                        onPressed: complete
                            ? () => _open(context, entry)
                            : () => active
                                  ? downloads.pause(entry.item)
                                  : downloads.resume(entry.item),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              complete
                                  ? Icons.menu_book
                                  : active
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              size: 18,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              L10n.tr(
                                context,
                                complete
                                    ? 'Read'
                                    : active
                                    ? 'Pause'
                                    : 'Resume',
                              ),
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () async {
                          if (await confirmAction(
                            context,
                            'Delete Download',
                            'Saved library items will remain.',
                          )) {
                            await downloads.remove(entry.item);
                          }
                        },
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.fromLTRB(12, 8, 0, 8),
                        ),
                        child: Semantics(
                          label: L10n.tr(context, 'Delete Download'),
                          child: const Icon(
                            Icons.delete_outline,
                            size: 24,
                            color: Color(0xFFFF3B30),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _open(BuildContext context, DownloadEntry entry) =>
      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => ReaderScreen(
            controller: controller,
            item: entry.item,
            downloads: downloads,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: downloads,
    builder: (context, _) => Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: SafeArea(
        child: downloads.entries.isEmpty
            ? const EmptyState(
                icon: Icons.download,
                title: 'No Downloads',
                message: 'Download works from their details to read offline.',
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 20),
                    child: Text(
                      L10n.tr(
                        context,
                        'Keep the app open while downloading. Interrupted downloads can be resumed.',
                      ),
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  for (final entry in downloads.entries) _entry(context, entry),
                ],
              ),
      ),
      appBar: AppBar(
        leading: const TegnalBackButton(),
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text(L10n.tr(context, 'Downloads')),
      ),
    ),
  );
}
