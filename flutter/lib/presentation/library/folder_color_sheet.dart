import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../../core/storage/app_database.dart';
import '../../core/support/l10n.dart';
import '../../domain/models.dart';
import '../content/gallery_detail_view.dart';
import '../design/tegnal_theme.dart';

/// `NativeColorPickerSheet` (`UIColorPickerViewController` in its grid style, without opacity):
/// twelve hues by nine shades under a row of grays. Each tap recolors the folder at once.
class FolderColorSheet extends StatefulWidget {
  const FolderColorSheet({super.key, required this.folder, required this.database, required this.onChanged});
  final Folder folder;
  final AppDatabase database;
  final VoidCallback onChanged;

  /// Hues of the grid's columns, from cyan through green, as the system grid orders them.
  static const hues = [196.0, 214.0, 248.0, 280.0, 325.0, 355.0, 12.0, 28.0, 40.0, 52.0, 62.0, 84.0];

  /// Saturation and brightness of the grid's rows, from deep to pale.
  static const shades = [(1.0, 0.24), (1.0, 0.38), (1.0, 0.53), (1.0, 0.70), (1.0, 0.87), (0.78, 1.0), (0.58, 1.0), (0.40, 1.0), (0.22, 1.0)];

  static List<List<Color>> get grid => [
    [for (var column = 0; column < 12; column++) HSVColor.fromAHSV(1, 0, 0, 1 - column / 11).toColor()],
    for (final (saturation, value) in shades) [for (final hue in hues) HSVColor.fromAHSV(1, hue, saturation, value).toColor()],
  ];

  /// `NativeColorPickerSheet.argb`: opaque, rounded to whole channels.
  static int argb(Color color) => 0xFF000000 | ((color.r * 255).round() << 16) | ((color.g * 255).round() << 8) | (color.b * 255).round();

  @override
  State<FolderColorSheet> createState() => _FolderColorSheetState();
}

class _FolderColorSheetState extends State<FolderColorSheet> {
  late int _color = widget.folder.color;

  void _select(Color color) {
    final value = FolderColorSheet.argb(color);
    final id = widget.folder.id;
    if (id == null) return;
    HapticFeedback.selectionClick();
    widget.database.setFolderColor(id, value);
    setState(() => _color = value);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final label = TegnalColors.label.resolveFrom(context);
    final grid = FolderColorSheet.grid;
    return ColoredBox(
      color: TegnalColors.secondaryBackground.resolveFrom(context),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            SizedBox(
              height: 76,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Text(
                    L10n.text('%@ color', [widget.folder.displayName]),
                    style: TegnalType.style(17, weight: FontWeight.w600, color: label),
                  ),
                  Positioned(
                    right: 16,
                    child: GlassIconButton(icon: CupertinoIcons.xmark, label: L10n.text('Close'), onPressed: () => Navigator.of(context).pop()),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Column(
                  children: [
                    for (final row in grid)
                      Row(
                        children: [
                          for (final color in row)
                            Expanded(
                              child: Semantics(
                                button: true,
                                selected: FolderColorSheet.argb(color) == _color,
                                child: GestureDetector(
                                  onTap: () => _select(color),
                                  child: AspectRatio(
                                    aspectRatio: 1,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: color,
                                        border: FolderColorSheet.argb(color) == _color ? Border.all(color: const Color(0xFFFFFFFF), width: 3) : null,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: ShapeDecoration(
                      color: Color(_color),
                      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
