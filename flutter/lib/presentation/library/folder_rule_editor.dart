import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/storage/folder_rules.dart';
import '../../core/storage/work_query.dart';
import '../../core/support/l10n.dart';
import '../design/context_menu.dart';
import '../design/grouped_form.dart';
import '../design/ios_controls.dart';
import '../design/pull_down_menu.dart';
import '../design/tegnal_theme.dart';
import '../design/alert_dialog.dart';

/// `FolderRuleEditor`: makes a new folder from a tag, or sets up the smart folder of one that exists.
class FolderRuleEditor extends StatefulWidget {
  /// A new folder, filled from the tag a search already holds or kept filling as a smart folder.
  const FolderRuleEditor.create({super.key, required this.library, this.booru = false, this.name = '', this.tag = '', this.smart = true, this.scrollController})
    : creatingFolder = true,
      folder = null;

  /// An existing folder, or a choice of folders when none is given.
  const FolderRuleEditor.existing({super.key, required this.library, this.booru = false, required this.folder, this.scrollController})
    : creatingFolder = false,
      name = '',
      tag = '',
      smart = true;

  final SmartFolderLibrary library;
  final bool booru;
  final bool creatingFolder;
  final String? folder;
  final String name;
  final String tag;
  final bool smart;
  final ScrollController? scrollController;

  @override
  State<FolderRuleEditor> createState() => _FolderRuleEditorState();
}

class _FolderRuleEditorState extends State<FolderRuleEditor> {
  late final _name = TextEditingController(text: widget.name);
  late final _tag = TextEditingController(text: widget.tag);
  final _excluded = TextEditingController();
  late bool _isSmart = widget.smart;
  late bool _fillsSavedWorks = widget.creatingFolder;
  late String? _folder = widget.folder;
  List<SmartFolderChoice> _choices = [];
  List<SmartFolderChoice> _openFolders = [];
  Set<String> _defaultSources = {};

  /// Stays null until a person picks, so the rule keeps following the default save folder.
  Set<String>? _sources;
  bool _everyFolder = false;
  int _matches = 0;
  Timer? _count;

  bool get _fixedFolder => !widget.creatingFolder && widget.folder != null;
  WorkQuery get _query => WorkQuery(_tag.text, excluding: _excluded.text);
  bool get _usesTags => widget.creatingFolder || _isSmart;

  /// The toggle files works already saved once, when Save is tapped; a smart folder alone
  /// only takes works saved after it.
  String get _fillFooter {
    if (_fillsSavedWorks || !_isSmart) {
      return L10n.text(
        widget.booru
            ? 'When you tap Save, matching images already in the chosen folders move here once.'
            : 'When you tap Save, matching works already in the chosen folders are added here once. They stay in those folders too.',
      );
    }
    return L10n.text(
      widget.booru
          ? 'Only images saved from now on move here. Images you already saved stay where they are.'
          : 'Only works saved from now on come here. Works you already saved stay where they are.',
    );
  }

  List<SmartFolderChoice> get _sourceChoices => _choices.where((choice) => choice.id != _folder).toList();
  Set<String> get _selected => (_sources ?? _defaultSources).difference({?_folder});

  String get _sourceSummary {
    if (_everyFolder) return L10n.text('All Folders');
    final names = [
      for (final choice in _sourceChoices)
        if (_selected.contains(choice.id)) choice.name,
    ];
    return names.length > 2 ? L10n.text('%@ Folders', ['${names.length}']) : names.join(', ');
  }

  FolderRule get _rule => FolderRule(
    folder: _folder ?? '',
    query: _tag.text,
    excluded: _excluded.text,
    isEnabled: _isSmart ? null : false,
    sources: _sources == null ? null : (_sources!.toList()..sort()),
    includesOtherFolders: _everyFolder ? true : null,
  );

  bool get _canSave {
    if (widget.creatingFolder) return !_query.isEmpty && _name.text.trim().isNotEmpty;
    return _folder != null && (!_query.isEmpty || !_isSmart);
  }

  @override
  void initState() {
    super.initState();
    for (final controller in [_name, _tag, _excluded]) {
      controller.addListener(_changed);
    }
    _load();
    _changed();
  }

  @override
  void dispose() {
    _count?.cancel();
    _name.dispose();
    _tag.dispose();
    _excluded.dispose();
    super.dispose();
  }

  void _changed() {
    setState(() {});
    _count?.cancel();
    _count = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      int matches;
      try {
        matches = widget.library.matchingCount(_rule);
      } on Object {
        matches = 0;
      }
      setState(() => _matches = matches);
    });
  }

  void _load() {
    _choices = widget.library.folderChoices();
    _defaultSources = widget.library.defaultRuleSources();
    if (widget.creatingFolder) return;
    final taken = widget.library.smartRules().map((rule) => rule.folder).toSet();
    _openFolders = _choices.where((choice) => choice.canBeSmart && !taken.contains(choice.id)).toList();
    _folder ??= _openFolders.firstOrNull?.id;
    final folder = _folder;
    final rule = folder == null ? null : widget.library.rule(folder);
    if (rule == null) return;
    _tag.text = rule.query;
    _excluded.text = rule.excluded;
    _isSmart = rule.isActive;
    _everyFolder = rule.includesOtherFolders == true;
    final existing = rule.sources?.toSet().intersection(_choices.map((choice) => choice.id).toSet());
    _sources = existing != null && existing.isNotEmpty ? existing : null;
  }

  void _save() {
    try {
      final target = widget.creatingFolder ? widget.library.createRuleFolder(_name.text) : _folder;
      if (target == null) return;
      final saved = _rule..folder = target;
      if (!saved.workQuery.isEmpty && (!widget.creatingFolder || _isSmart)) {
        widget.library.saveRule(saved);
      } else if (!widget.creatingFolder) {
        widget.library.deleteRule(target);
      }
      if (_usesTags && _fillsSavedWorks) widget.library.fill(saved);
      Navigator.of(context).pop();
    } on Object catch (error) {
      showCupertinoDialog<void>(
        context: context,
        builder: (context) => TegnalAlertDialog(
          title: Text(L10n.text('Error')),
          content: Text('$error'),
          actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('OK')))],
        ),
      );
    }
  }

  void _openSources(BuildContext context) {
    showActionMenu(
      context,
      anchor: anchorRectOf(context),
      actions: [
        ContextMenuAction(title: L10n.text('All Folders'), checked: _everyFolder, onSelected: () => setState(() => _everyFolder = !_everyFolder)),
        for (final choice in _sourceChoices)
          ContextMenuAction(
            title: choice.name,
            checked: _everyFolder || _selected.contains(choice.id),
            onSelected: _everyFolder || _selected.length == 1 && _selected.contains(choice.id)
                ? null
                : () => setState(() {
                    final next = {..._selected};
                    next.contains(choice.id) ? next.remove(choice.id) : next.add(choice.id);
                    _sources = next;
                  }),
          ),
      ],
    ).then((_) => _changed());
  }

  Widget _tagField(TextEditingController controller, String prompt) => Expanded(
    child: CupertinoTextField.borderless(
      controller: controller,
      enabled: _usesTags,
      textAlign: TextAlign.right,
      autocorrect: false,
      enableSuggestions: false,
      padding: EdgeInsets.zero,
      placeholder: prompt,
      placeholderStyle: TegnalType.style(17, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
      style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    final label = TegnalColors.label.resolveFrom(context);
    Widget footer(String text) => Text(text);
    final folderName = _choices.where((choice) => choice.id == _folder).firstOrNull?.name ?? '';
    return ScrollEdgeSheet(
      bar: SheetNavigationBar(
        title: L10n.text(widget.creatingFolder ? 'New Folder' : 'Smart Folder'),
        leading: GlassTextButton(label: L10n.text('Cancel'), onPressed: () => Navigator.of(context).pop()),
        trailing: GlassTextButton(label: L10n.text('Save'), prominent: true, onPressed: _canSave ? _save : null),
      ),
      child: ListView(
        controller: widget.scrollController,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.only(top: 76 + 30, bottom: 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          FormSection(
            children: [
              if (widget.creatingFolder)
                FormRow(
                  child: CupertinoTextField.borderless(
                    controller: _name,
                    autofocus: _name.text.isEmpty,
                    padding: EdgeInsets.zero,
                    placeholder: L10n.text('Folder Name'),
                    placeholderStyle: TegnalType.style(17, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
                    style: TegnalType.style(17, color: label),
                  ),
                )
              else if (_fixedFolder)
                FormRow(
                  child: Row(
                    children: [
                      Expanded(child: Text(L10n.text('Folder'))),
                      Text(folderName, style: TegnalType.style(17, color: secondary)),
                    ],
                  ),
                )
              else if (_openFolders.isEmpty)
                FormRow(
                  child: Text(L10n.text('Create a folder to organize your works.'), style: TegnalType.style(17, color: secondary)),
                )
              else
                Builder(
                  builder: (context) => FormRow(
                    onTap: () async {
                      final value = await showPullDownMenu<String>(
                        context,
                        anchor: anchorRectOf(context),
                        items: [for (final choice in _openFolders) PullDownMenuItem(value: choice.id, title: choice.name, checked: choice.id == _folder)],
                      );
                      if (value != null) {
                        setState(() => _folder = value);
                        _changed();
                      }
                    },
                    child: Row(
                      children: [
                        Expanded(child: Text(L10n.text('Folder'))),
                        Text(folderName, style: TegnalType.style(17, color: secondary)),
                        const SizedBox(width: 4),
                        Icon(CupertinoIcons.chevron_up_chevron_down, size: 15, color: secondary),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          // A section without a footer leaves 35 pt; after a footer 23 pt, as the native form spaces them.
          const SizedBox(height: 35),
          FormSection(
            footer: footer(
              L10n.text('New saves with these tags come here on their own. A work you move yourself stays where you put it, even if its tags differ.'),
            ),
            children: [
              FormRow(
                child: Row(
                  children: [
                    Expanded(child: Text(L10n.text('Smart Folder'))),
                    Transform.translate(
                      offset: const Offset(2, 0),
                      child: TegnalSwitch(
                        value: _isSmart,
                        onChanged: (value) {
                          setState(() => _isSmart = value);
                          _changed();
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 23),
          Opacity(
            opacity: _usesTags ? 1 : 0.4,
            child: FormSection(
              footer: footer(
                _query.isEmpty ? L10n.text('Separate tags with spaces. Use _ for a space inside a tag.') : L10n.text('%@ saved works match.', ['$_matches']),
              ),
              children: [
                FormRow(
                  child: Row(children: [Text(L10n.text('Tag')), const SizedBox(width: 16), _tagField(_tag, widget.booru ? 'landscape' : 'language:korean')]),
                ),
                FormRow(
                  child: Row(
                    children: [Text(L10n.text('Excluded Tags')), const SizedBox(width: 16), _tagField(_excluded, widget.booru ? 'monochrome' : 'tag:example')],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 23),
          IgnorePointer(
            ignoring: !_usesTags,
            child: Opacity(
              opacity: _usesTags ? 1 : 0.4,
              child: FormSection(
                footer: footer(_fillFooter),
                children: [
                  Builder(
                    builder: (context) => FormRow(
                      onTap: () => _openSources(context),
                      child: Row(
                        children: [
                          Text(L10n.text('Take Works From')),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              _sourceSummary,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.right,
                              style: TegnalType.style(17, color: tint),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(CupertinoIcons.chevron_up_chevron_down, size: 15, color: tint),
                        ],
                      ),
                    ),
                  ),
                  FormRow(
                    child: Row(
                      children: [
                        Expanded(child: Text(L10n.text(widget.booru ? 'Move Saved Images Now' : 'Add Saved Works Now'))),
                        Transform.translate(
                          offset: const Offset(2, 0),
                          child: TegnalSwitch(value: _fillsSavedWorks, onChanged: (value) => setState(() => _fillsSavedWorks = value)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
