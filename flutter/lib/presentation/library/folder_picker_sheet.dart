import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/storage/folder_rules.dart';
import '../../core/support/l10n.dart';
import '../design/app_sheet.dart';
import '../design/grouped_form.dart';
import '../design/symbols.dart';
import '../design/tegnal_theme.dart';
import 'folder_name_prompt.dart';

/// One folder in a picker, from either library.
class FolderPickerRow {
  const FolderPickerRow({required this.id, required this.name, required this.color, required this.isCurrent, this.isGlobal = false});
  final String id;
  final String name;
  final int color;
  final bool isCurrent;

  /// An image folder of every server, marked beside one of the image's own server.
  final bool isGlobal;
}

/// `FolderPickerSheet`: the folder list both modes show when a saved work changes folder. A new
/// folder first, then every folder with its color, the current one checked. Tapping a folder is
/// the whole action.
class FolderPickerSheet extends StatelessWidget {
  const FolderPickerSheet({
    super.key,
    required this.rows,
    required this.pick,
    required this.library,
    required this.create,
    this.booru = false,
    this.error,
    this.scrollController,
  });
  final List<FolderPickerRow> rows;
  final ValueChanged<FolderPickerRow> pick;

  /// Where a new folder is made, with the same prompt as everywhere else.
  final SmartFolderLibrary library;
  final bool booru;

  /// Files the work in a folder just made, by its identity.
  final ValueChanged<String> create;
  final String? error;
  final ScrollController? scrollController;

  Future<void> _create(BuildContext context) async {
    final identity = await createFolderWithPrompt(context, library: library, booru: booru);
    if (!context.mounted || identity == null) return;
    create(identity);
  }

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    return ScrollEdgeSheet(
      background: mediumSheetGlass,
      bar: SheetNavigationBar(
        title: L10n.text('Save to Folder'),
        leading: GlassTextButton(label: L10n.text('Cancel'), onPressed: () => Navigator.of(context).pop()),
      ),
      child: ListView(
        controller: scrollController,
        padding: EdgeInsets.only(top: 76 + 28, bottom: 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          FormSection(
            children: [
              FormRow(
                onTap: () => _create(context),
                child: Row(
                  children: [
                    SizedBox(width: 28, child: Icon(CupertinoIcons.folder_badge_plus, size: 22, color: tint)),
                    const SizedBox(width: 12),
                    Text(L10n.text('Create New Folder…'), style: TegnalType.style(17, color: tint)),
                  ],
                ),
              ),
              for (final row in rows)
                FormRow(
                  onTap: () => pick(row),
                  child: Semantics(
                    selected: row.isCurrent,
                    child: Row(
                      children: [
                        SizedBox(width: 28, child: Icon(CupertinoIcons.folder_fill, size: 22, color: Color(row.color))),
                        const SizedBox(width: 12),
                        Flexible(child: Text(row.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                        if (row.isGlobal) ...[
                          const SizedBox(width: 6),
                          Semantics(
                            label: L10n.text('Global Folder'),
                            child: Icon(CupertinoIcons.globe, size: 15, color: CupertinoColors.secondaryLabel.resolveFrom(context)),
                          ),
                        ],
                        const Spacer(),
                        if (row.isCurrent) Icon(Symbols.checkmark, size: 20, color: tint),
                      ],
                    ),
                  ),
                ),
              if (error != null)
                FormRow(
                  child: Text(error!, style: TegnalType.style(17, color: CupertinoColors.systemRed.resolveFrom(context))),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
