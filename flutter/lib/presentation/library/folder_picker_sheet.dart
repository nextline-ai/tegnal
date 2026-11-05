import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/support/l10n.dart';
import '../design/app_sheet.dart';
import '../design/grouped_form.dart';
import '../design/symbols.dart';
import '../design/tegnal_theme.dart';
import 'folder_name_prompt.dart';

/// One folder in a picker, from either library.
class FolderPickerRow {
  const FolderPickerRow({required this.id, required this.name, required this.color, required this.isCurrent});
  final String id;
  final String name;
  final int color;
  final bool isCurrent;
}

/// `FolderPickerSheet`: the folder list both modes show when a saved work changes folder. A new
/// folder first, then every folder with its color, the current one checked. Tapping a folder is
/// the whole action.
class FolderPickerSheet extends StatelessWidget {
  const FolderPickerSheet({super.key, required this.rows, required this.pick, required this.create, this.error, this.scrollController});
  final List<FolderPickerRow> rows;
  final ValueChanged<FolderPickerRow> pick;

  /// Makes a folder and files the work in it.
  final ValueChanged<String> create;
  final String? error;
  final ScrollController? scrollController;

  Future<void> _create(BuildContext context) async {
    final result = await showFolderNamePrompt(context);
    if (!context.mounted || result == null || result.name.isEmpty) return;
    create(result.name);
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
                        Expanded(child: Text(row.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
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
