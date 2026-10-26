import 'package:material_ui/material_ui.dart';

import '../data/booru_extras.dart';
import '../ui/l10n.dart';

/// Notes use the original image's pixel coordinates and live inside the image's
/// zoom transform, so their geometry follows letterboxing, resizing, and zoom.
class ReaderNotesOverlay extends StatelessWidget {
  const ReaderNotesOverlay({
    super.key,
    required this.notes,
    required this.imageSize,
  });
  final List<BooruNote> notes;
  final Size imageSize;

  @override
  Widget build(BuildContext context) {
    if (imageSize.isEmpty || notes.isEmpty) return const SizedBox();
    return LayoutBuilder(
      builder: (context, constraints) {
        final destination = applyBoxFit(
          BoxFit.contain,
          imageSize,
          constraints.biggest,
        ).destination;
        final scale = destination.width / imageSize.width;
        final dx = (constraints.maxWidth - destination.width) / 2;
        final dy = (constraints.maxHeight - destination.height) / 2;
        return ClipRect(
          child: Stack(
            children: [
              for (final note in notes)
                Positioned(
                  left: dx + note.x * scale,
                  top: dy + note.y * scale,
                  width: note.width * scale,
                  height: note.height * scale,
                  child: Semantics(
                    label: note.body,
                    button: true,
                    child: GestureDetector(
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text(L10n.tr(context, 'Note')),
                          content: Text(note.body),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: Text(L10n.tr(context, 'Done')),
                            ),
                          ],
                        ),
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0x35FFD60A),
                          border: Border.all(
                            color: const Color(0xFFFFD60A),
                            width: 1.5,
                          ),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
