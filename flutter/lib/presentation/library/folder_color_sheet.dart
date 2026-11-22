import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../../core/storage/folder_palette.dart';
import '../../core/support/l10n.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';

/// `FolderColorSheet`: every folder color, Apple's system colors, with the folder's own marked.
/// A pick recolors the folder at once.
class FolderColorSheet extends StatefulWidget {
  const FolderColorSheet({super.key, required this.title, required this.color, required this.onSelected, required this.preview});

  /// The folder's display name.
  final String title;
  final int color;

  /// Saves the chosen opaque ARGB color.
  final ValueChanged<int> onSelected;

  /// The folder's card in a color.
  final Widget Function(int color) preview;

  @override
  State<FolderColorSheet> createState() => _FolderColorSheetState();
}

class _FolderColorSheetState extends State<FolderColorSheet> {
  late int _current = widget.color;

  void _pick(int color) {
    if (color == _current) return;
    HapticFeedback.selectionClick();
    widget.onSelected(color);
    setState(() => _current = color);
  }

  @override
  Widget build(BuildContext context) {
    final ring = TegnalColors.secondaryLabel.resolveFrom(context);
    final edge = TegnalColors.label.resolveFrom(context).withValues(alpha: 0.1);
    const colors = FolderPalette.colors;
    Widget swatch(int index) {
      if (index >= colors.length) return const SizedBox(width: 56, height: 56);
      final color = colors[index];
      final selected = color == _current;
      return Semantics(
        button: true,
        selected: selected,
        label: L10n.text('Color %@', ['${index + 1}']),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _pick(color),
          child: SizedBox(
            height: 56,
            child: Center(
              // The folder's color is ringed, as the system's own color pickers do.
              child: AnimatedContainer(
                key: ValueKey(color),
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                width: 56,
                height: 56,
                padding: const EdgeInsets.all(5),
                decoration: ShapeDecoration(
                  shape: CircleBorder(side: BorderSide(color: selected ? ring : const Color(0x00000000), width: 3)),
                ),
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    color: Color(color),
                    shape: CircleBorder(side: BorderSide(color: edge, width: 0.5)),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return ScrollEdgeSheet(
      bar: SheetNavigationBar(
        title: L10n.text('%@ color', [widget.title]),
        trailing: GlassTextButton(label: L10n.text('Done'), prominent: true, onPressed: () => Navigator.of(context).pop()),
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 76 + 8, 20, 16),
        children: [
          Center(
            child: SizedBox(
              width: 132,
              child: IgnorePointer(child: ExcludeSemantics(child: widget.preview(_current))),
            ),
          ),
          const SizedBox(height: 24),
          for (var row = 0; row < colors.length; row += 5) ...[
            if (row > 0) const SizedBox(height: 16),
            Row(
              children: [
                for (var index = row; index < row + 5; index++) ...[if (index > row) const SizedBox(width: 12), Expanded(child: swatch(index))],
              ],
            ),
          ],
        ],
      ),
    );
  }
}
