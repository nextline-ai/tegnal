import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../../core/support/l10n.dart';
import '../design/app_sheet.dart';
import '../design/system_colors.dart';
import '../library/add_work_sheet.dart';
import '../design/tegnal_theme.dart';
import 'content_bookmark.dart';

OverlayEntry? _current;
Timer? _timer;

/// `workSaveFeedback`: a capsule notice at the bottom with the result's icon and message,
/// played with the native haptic and dismissed after its duration. A new comic save offers
/// Change Folder, which opens the folders and then confirms where the work went.
void showWorkSaveFeedback(BuildContext context, WorkSaveFeedback feedback, {BookmarkSession? session, double? bottom}) {
  switch (feedback.result.haptic) {
    case WorkSaveHaptic.success:
      HapticFeedback.mediumImpact();
    case WorkSaveHaptic.selection:
      HapticFeedback.selectionClick();
    case WorkSaveHaptic.error:
      HapticFeedback.heavyImpact();
  }
  _timer?.cancel();
  _current?.remove();
  final overlay = Overlay.of(context, rootOverlay: true);
  final navigator = Navigator.of(context, rootNavigator: true);
  final id = feedback.galleryID;
  VoidCallback? changeFolder;
  if (id != null && session != null) {
    changeFolder = () async {
      _timer?.cancel();
      _current?.remove();
      _current = null;
      String? filed;
      await showAppSheet<void>(
        navigator.context,
        grabber: true,
        builder: (context, controller) => WorkFolderSheet(
          database: session.database,
          galleryID: id,
          savedFolders: session.savedFolders,
          scrollController: controller,
          filed: (folder) => filed = folder,
        ),
      );
      // The screen that saved the work shows where it went.
      if (filed != null && context.mounted) {
        showWorkSaveFeedback(
          context,
          WorkSaveFeedback(feedback.result, galleryID: id, folder: filed),
          session: session,
          bottom: bottom,
        );
      }
    };
  }
  final entry = OverlayEntry(
    builder: (context) => _Notice(feedback: feedback, changeFolder: changeFolder, bottom: bottom),
  );
  _current = entry;
  overlay.insert(entry);
  _timer = Timer(feedback.duration, () {
    if (_current == entry) {
      entry.remove();
      _current = null;
    }
  });
}

class _Notice extends StatelessWidget {
  const _Notice({required this.feedback, this.changeFolder, this.bottom});
  final WorkSaveFeedback feedback;
  final VoidCallback? changeFolder;

  /// Inside a tab the notice sits above the tab bar; the reader has none.
  final double? bottom;

  IconData get _icon => switch (feedback.result.icon) {
    'bookmark.fill' => CupertinoIcons.bookmark_fill,
    'bookmark.slash' => CupertinoIcons.bookmark,
    'heart.fill' => CupertinoIcons.heart_fill,
    'heart.slash' => CupertinoIcons.heart_slash,
    _ => CupertinoIcons.exclamationmark_circle,
  };

  Color _color(BuildContext context) => switch (feedback.result.color) {
    WorkSaveColor.yellow => SystemColors.yellow.resolveFrom(context),
    WorkSaveColor.pink => SystemColors.pink.resolveFrom(context),
    WorkSaveColor.secondary => TegnalColors.secondaryLabel.resolveFrom(context),
    WorkSaveColor.orange => SystemColors.orange.resolveFrom(context),
  };

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return Positioned(
      left: 16,
      right: 16,
      // Above the home indicator's 34 pt as on iOS, even where immersive Android reports no inset.
      bottom: bottom ?? 16 + math.max(MediaQuery.paddingOf(context).bottom, 34),
      child: IgnorePointer(
        ignoring: changeFolder == null,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          builder: (context, value, child) => Opacity(
            opacity: value,
            child: Transform.scale(scale: 0.96 + 0.04 * value, child: child),
          ),
          child: Center(
            child: Semantics(
              liveRegion: true,
              label: feedback.message,
              child: DecoratedBox(
                decoration: const ShapeDecoration(
                  shape: StadiumBorder(),
                  shadows: [BoxShadow(color: Color(0x1F000000), blurRadius: 16, offset: Offset(0, 3))],
                ),
                child: ClipPath(
                  clipper: const ShapeBorderClipper(shape: StadiumBorder()),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                      color: dark ? const Color(0xCC2C2C2E) : const Color(0xD9F2F2F7),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_icon, size: 17, color: _color(context)),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              feedback.message,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TegnalType.style(15, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                            ),
                          ),
                          if (changeFolder != null) ...[
                            const SizedBox(width: 12),
                            GestureDetector(
                              onTap: changeFolder,
                              child: Text(
                                L10n.text('Change Folder'),
                                style: TegnalType.style(15, weight: FontWeight.w600, color: TegnalColors.tint.resolveFrom(context)),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
