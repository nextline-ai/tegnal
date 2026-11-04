import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../../core/content/gallery_id_parser.dart';
import '../../core/storage/app_database.dart';
import '../../core/storage/folder_rules.dart';
import '../../core/support/l10n.dart';
import '../../core/taste/taste_models.dart';
import '../../domain/models.dart';
import '../design/grouped_form.dart';
import '../design/symbols.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import 'folder_name_prompt.dart';
import 'library_routes.dart';
import '../../core/content/manga_urls.dart';

/// `AddWorkSheet`: saves every work number or link in the text into the chosen folder.
class AddWorkSheet extends StatefulWidget {
  const AddWorkSheet({super.key, required this.routes, this.initialText = '', this.discovery, this.scrollController});
  final LibraryRoutes routes;
  final String initialText;
  final DiscoveryContext? discovery;
  final ScrollController? scrollController;

  @override
  State<AddWorkSheet> createState() => _AddWorkSheetState();
}

class _AddWorkSheetState extends State<AddWorkSheet> {
  late final _input = TextEditingController(text: widget.initialText);
  List<Folder> _folders = [];
  int? _selectedFolderID;
  List<int> _detected = [];
  bool _saving = false;
  bool _canPaste = false;

  AppDatabase get _database => widget.routes.database;

  @override
  void initState() {
    super.initState();
    _detected = GalleryIDParser.parse(widget.initialText);
    _input.addListener(() => setState(() => _detected = GalleryIDParser.parse(_input.text)));
    _loadFolders();
    Clipboard.hasStrings().then((value) {
      if (mounted) setState(() => _canPaste = value);
    });
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _loadFolders() {
    _folders = _database.listFolders();
    _selectedFolderID ??= _database.defaultSaveFolder().id ?? _folders.firstOrNull?.id;
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && mounted) _input.text = text;
  }

  Future<void> _createFolder() async {
    final result = await showFolderNamePrompt(context);
    if (!mounted || result == null || result.name.isEmpty) return;
    final created = _database.createFolder(name: result.name);
    setState(() {
      _loadFolders();
      _selectedFolderID = created.id;
    });
  }

  void _save() {
    if (_detected.isEmpty) return;
    setState(() => _saving = true);
    var created = 0;
    for (final id in _detected) {
      final existing = _database.getWork(id);
      final catalog = _database.getCatalog(id);
      _database.upsertWork(
        galleryId: id,
        folderId: _selectedFolderID,
        title: catalog?.title,
        artists: catalog?.artists,
        language: catalog?.language,
        type: catalog?.type,
        series: catalog?.series,
        groups: catalog?.groups,
        tags: catalog?.tags,
        publishedAt: catalog?.published,
        metadataSource: catalog != null ? 'catalog' : null,
        catalogMatched: catalog != null,
        site: ComicSites.active,
        discoveryContext: widget.discovery,
      );
      if (existing == null) created++;
    }
    if (created > 0) widget.routes.startCoverQueue?.call();
    widget.routes.notifyChanged();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    final label = TegnalColors.label.resolveFrom(context);
    return ScrollEdgeSheet(
      bar: SheetNavigationBar(
        title: L10n.text('Add Work Number'),
        leading: GlassTextButton(label: L10n.text('Cancel'), onPressed: () => Navigator.of(context).pop()),
        trailing: GlassTextButton(label: L10n.text('Save'), prominent: true, onPressed: _detected.isEmpty || _saving ? null : _save),
      ),
      child: ListView(
        controller: widget.scrollController,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.only(top: 76 + 4, bottom: 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          FormSection(
            header: Text(L10n.text('Work Number or Link')),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: CupertinoTextField.borderless(
                  controller: _input,
                  minLines: 5,
                  maxLines: 8,
                  padding: EdgeInsets.zero,
                  style: TegnalType.style(17, color: label),
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.multiline,
                ),
              ),
              if (_input.text.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _PasteButton(enabled: _canPaste, onPressed: _paste),
                  ),
                )
              else if (_detected.isNotEmpty)
                FormRow(
                  child: Row(
                    children: [
                      Icon(CupertinoIcons.checkmark_circle_fill, size: 17, color: SystemColors.green.resolveFrom(context)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(L10n.text('Found %@: %@', ['${_detected.length}', _detected.join('  ')]), style: TegnalType.style(12, color: secondary)),
                      ),
                    ],
                  ),
                )
              else if (_input.text.trim().isNotEmpty)
                FormRow(
                  child: Row(
                    children: [
                      Icon(CupertinoIcons.exclamationmark_triangle_fill, size: 17, color: SystemColors.orange.resolveFrom(context)),
                      const SizedBox(width: 8),
                      Text(L10n.text('No work numbers found'), style: TegnalType.style(12, color: secondary)),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 26),
          FormSection(
            header: Text(L10n.text('Save to Folder')),
            children: [
              FormRow(
                onTap: _createFolder,
                child: Row(
                  children: [
                    Icon(CupertinoIcons.folder_badge_plus, size: 22, color: tint),
                    const SizedBox(width: 8),
                    Text(L10n.text('Create New Folder…'), style: TegnalType.style(17, color: tint)),
                  ],
                ),
              ),
              for (final folder in _folders)
                FormRow(
                  onTap: () => setState(() => _selectedFolderID = folder.id),
                  child: FolderChoiceRow(folder: folder, selected: _selectedFolderID == folder.id),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A folder in a choice list: its color dot, name and a checkmark when chosen.
class FolderChoiceRow extends StatelessWidget {
  const FolderChoiceRow({super.key, required this.folder, required this.selected});
  final Folder folder;
  final bool selected;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: Row(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: Color(folder.color), shape: BoxShape.circle),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(folder.displayName, maxLines: 1, overflow: TextOverflow.ellipsis)),
        if (selected) Icon(Symbols.checkmark, size: 20, color: TegnalColors.tint.resolveFrom(context)),
      ],
    ),
  );
}

/// `PasteButton` at the small control size: a tinted capsule that reads the clipboard.
class _PasteButton extends StatelessWidget {
  const _PasteButton({required this.enabled, required this.onPressed});
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    final color = enabled ? tint : TegnalColors.tertiaryLabel.resolveFrom(context);
    return Semantics(
      button: true,
      enabled: enabled,
      child: GestureDetector(
        onTap: enabled ? onPressed : null,
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: ShapeDecoration(
            color: tint.withValues(alpha: enabled ? 0.15 : 0.12),
            shape: const StadiumBorder(),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(CupertinoIcons.doc_on_clipboard_fill, size: 16, color: color),
              const SizedBox(width: 6),
              Text(L10n.text('Paste'), style: TegnalType.style(15, color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

/// `WorkFolderSheet`: moves a work that was just saved. Tapping a folder is the whole action.
class WorkFolderSheet extends StatefulWidget {
  const WorkFolderSheet({super.key, required this.database, required this.galleryID, required this.savedFolders, required this.filed, this.scrollController});
  final AppDatabase database;
  final int galleryID;
  final Map<int, int> savedFolders;
  final ValueChanged<String> filed;
  final ScrollController? scrollController;

  @override
  State<WorkFolderSheet> createState() => _WorkFolderSheetState();
}

class _WorkFolderSheetState extends State<WorkFolderSheet> {
  late final List<Folder> _folders = widget.database.listFolders();

  void _file(Folder folder) {
    final id = folder.id;
    if (id == null) return;
    try {
      final current = widget.savedFolders[widget.galleryID];
      if (id != current) widget.database.moveWorkToFolder(widget.galleryID, id, currentFolderId: current);
      widget.savedFolders[widget.galleryID] = id;
      widget.filed(folder.displayName);
    } on Object {
      // The work stays where it was saved.
    }
    Navigator.of(context).pop();
  }

  Future<void> _create() async {
    final result = await showFolderNamePrompt(context);
    if (!mounted || result == null || result.name.isEmpty) return;
    _file(widget.database.createFolder(name: result.name));
  }

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    return ScrollEdgeSheet(
      bar: SheetNavigationBar(
        title: L10n.text('Save to Folder'),
        leading: GlassTextButton(label: L10n.text('Cancel'), onPressed: () => Navigator.of(context).pop()),
      ),
      child: ListView(
        controller: widget.scrollController,
        padding: EdgeInsets.only(top: 76 + 4, bottom: 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          FormSection(
            children: [
              FormRow(
                onTap: _create,
                child: Row(
                  children: [
                    Icon(CupertinoIcons.folder_badge_plus, size: 22, color: tint),
                    const SizedBox(width: 8),
                    Text(L10n.text('Create New Folder…'), style: TegnalType.style(17, color: tint)),
                  ],
                ),
              ),
              for (final folder in _folders)
                FormRow(
                  onTap: () => _file(folder),
                  child: FolderChoiceRow(folder: folder, selected: folder.id == widget.savedFolders[widget.galleryID]),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
