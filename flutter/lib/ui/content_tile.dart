import 'package:material_ui/material_ui.dart';

import '../core/content.dart';
import 'l10n.dart';
import 'artwork_layout.dart';
import 'session_image.dart';

/// Image browsing stays edge to edge; comics retain their identifying text.
class ContentTile extends StatelessWidget {
  const ContentTile({
    super.key,
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.onMore,
    this.saved = false,
    this.showSavedBadge = true,
    this.selecting = false,
    this.selected = false,
    this.layout,
  });
  final ContentItem item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;
  final VoidCallback? onMore;
  final bool saved;
  final bool showSavedBadge;
  final bool selecting;
  final bool selected;
  final ArtworkLayout? layout;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selecting ? selected : null,
    label: '${item.title}${saved ? ', ${L10n.tr(context, 'Saved')}' : ''}',
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onSecondaryTap ?? onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(layout?.radius ?? 12),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    child: item.thumbnailUrl == null
                        ? const Center(
                            child: Icon(
                              Icons.image_outlined,
                              size: 38,
                              color: Colors.grey,
                            ),
                          )
                        : SessionImage(
                            url: item.thumbnailUrl!,
                            fit: layout?.fitsThumbnails == true
                                ? BoxFit.contain
                                : BoxFit.cover,
                            referer: item.pageUrl,
                            errorBuilder: (_, _, _) => const Center(
                              child: Icon(
                                Icons.image_outlined,
                                size: 38,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                  ),
                  if (saved && showSavedBadge && !selecting)
                    Positioned(
                      top: 7,
                      left: 7,
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: const BoxDecoration(
                          color: Color(0x99808080),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.favorite_rounded,
                          size: 18,
                          color: Colors.pinkAccent,
                        ),
                      ),
                    ),
                  if (selecting)
                    Positioned(
                      top: 9,
                      right: 9,
                      child: Container(
                        width: 27,
                        height: 27,
                        decoration: BoxDecoration(
                          color: selected
                              ? Color(0xFF009DFF)
                              : const Color(0x18000000),
                          shape: BoxShape.circle,
                          border: selected
                              ? null
                              : Border.all(color: Colors.white, width: 2),
                        ),
                        child: selected
                            ? const Icon(
                                Icons.check_rounded,
                                size: 24,
                                color: Colors.white,
                              )
                            : null,
                      ),
                    ),
                  if (item.pageCount > 0 ||
                      item.mediaType == 'video' ||
                      item.mediaType == 'gif')
                    Positioned(
                      bottom: 7,
                      right: 7,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0xA6000000),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 4,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (item.mediaType == 'video')
                                const Icon(
                                  Icons.play_arrow_rounded,
                                  size: 14,
                                  color: Colors.white,
                                )
                              else
                                Text(
                                  item.mediaType == 'gif'
                                      ? 'GIF'
                                      : '${item.pageCount} P',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (item.mode == AppMode.manga && (layout?.showsTitles ?? true)) ...[
            const SizedBox(height: 8),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                height: 1.25,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (item.mode == AppMode.manga && (layout?.showsArtists ?? true)) ...[
            const SizedBox(height: 3),
            Text(
              item.artists.isEmpty ? '#${item.id}' : item.artists.join(', '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
