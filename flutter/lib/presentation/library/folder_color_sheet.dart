import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../../core/storage/folder_palette.dart';
import '../../core/support/l10n.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';

/// `FolderColorSheet`: ten colors no other folder in the library uses, in the palette's order.
/// A pick recolors the folder at once, and a color nobody uses yet takes its place, so each pick
/// brings a new one.
class FolderColorSheet extends StatefulWidget {
  const FolderColorSheet({super.key, required this.title, required this.color, required this.others, required this.onSelected, required this.preview});

  /// The folder's display name.
  final String title;
  final int color;

  /// The colors of the library's other folders.
  final Iterable<int> others;

  /// Saves the chosen opaque ARGB color.
  final ValueChanged<int> onSelected;

  /// The folder's card in a color.
  final Widget Function(int color) preview;

  @override
  State<FolderColorSheet> createState() => _FolderColorSheetState();
}

class _FolderColorSheetState extends State<FolderColorSheet> {
  late int _current = widget.color;
  late final Set<int> _others = widget.others.toSet();
  late final List<int> _choices = FolderPalette.unused({..._others, widget.color}, 10);

  /// Colors this sheet has shown or the folder had, never offered again while it is open.
  late final Set<int> _shown = {..._choices, widget.color};

  void _pick(int color) {
    final index = _choices.indexOf(color);
    if (index < 0) return;
    HapticFeedback.selectionClick();
    widget.onSelected(color);
    final replacement = FolderPalette.unused({..._others, ..._shown}, 1);
    setState(() {
      _current = color;
      if (replacement.isEmpty) {
        _choices.removeAt(index);
      } else {
        _choices[index] = replacement.first;
        _shown.add(replacement.first);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final edge = TegnalColors.label.resolveFrom(context).withValues(alpha: 0.1);
    Widget swatch(int index) {
      if (index >= _choices.length) return const SizedBox(width: 50, height: 50);
      final color = _choices[index];
      return Semantics(
        button: true,
        label: L10n.text('Color %@', ['${index + 1}']),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _pick(color),
          child: SizedBox(
            height: 50,
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                switchInCurve: Curves.easeOutBack,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(scale: Tween(begin: 0.3, end: 1.0).animate(animation), child: child),
                ),
                child: DecoratedBox(
                  key: ValueKey(color),
                  decoration: ShapeDecoration(
                    color: Color(color),
                    shape: CircleBorder(side: BorderSide(color: edge, width: 0.5)),
                  ),
                  child: const SizedBox(width: 50, height: 50),
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
          for (final row in [0, 5]) ...[
            if (row > 0) const SizedBox(height: 16),
            Row(
              children: [
                for (var index = row; index < row + 5; index++) ...[if (index > row) const SizedBox(width: 12), Expanded(child: swatch(index))],
              ],
            ),
          ],
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              L10n.text('These are colors no other folder uses. Each color you pick is replaced by a new one.'),
              textAlign: TextAlign.center,
              style: TegnalType.style(13, color: secondary),
            ),
          ),
        ],
      ),
    );
  }
}
