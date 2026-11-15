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

/// Tags as words: spaces for underscores, joined the way the language lists things.
String spokenTags(String text) {
  final tags = [
    for (final tag in text.split(RegExp(r'\s+')))
      if (tag.isNotEmpty) tag.replaceAll('_', ' '),
  ];
  if (tags.length < 2) return tags.join();
  final head = tags.sublist(0, tags.length - 1), last = tags.last;
  return switch (L10n.language) {
    'ko' => '${head.join(', ')} 및 $last',
    'ja' => tags.join('、'),
    _ => tags.length == 2 ? '${tags[0]} and $last' : '${head.join(', ')}, and $last',
  };
}

/// What a rule does, in one line for the smart folder list: move or copy, and from where.
String smartFolderSummary(FolderRule rule, {required bool booru, required Map<String, String> names, required Set<String> defaultSources}) {
  final String places;
  if (rule.includesOtherFolders == true) {
    places = L10n.text('All Folders');
  } else {
    final ids = rule.sources?.toSet() ?? defaultSources;
    final list = [
      for (final MapEntry(:key, :value) in names.entries)
        if (ids.contains(key) && key != rule.folder) value,
    ]..sort();
    places = list.length > 2 ? L10n.text('%@ Folders', ['${list.length}']) : list.join(', ');
  }
  return L10n.text(!booru && rule.copies ? 'Copies here from %@' : 'Moves here from %@', [places]);
}

/// The summary line under a rule, with the move or copy symbol.
class SmartFolderSummaryRow extends StatelessWidget {
  const SmartFolderSummaryRow({super.key, required this.rule, required this.booru, required this.names, required this.defaultSources});
  final FolderRule rule;
  final bool booru;
  final Map<String, String> names;
  final Set<String> defaultSources;

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return Row(
      children: [
        Icon(!booru && rule.copies ? CupertinoIcons.plus_square_on_square : CupertinoIcons.arrow_right_square, size: 12, color: secondary),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            smartFolderSummary(rule, booru: booru, names: names, defaultSources: defaultSources),
            style: TegnalType.style(12, color: secondary),
          ),
        ),
      ],
    );
  }
}

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

  /// Comics only. New rules move, so each work sits in one place; a rule saved before the
  /// choice existed loads as copying, which is what it did.
  bool _copies = false;

  /// Where it looks and whether it moves or copies: shown open only when a folder already
  /// changed them, so a newcomer sees just the tags.
  bool _showsMore = false;
  int _matches = 0;
  int _matchesElsewhere = 0;
  Timer? _count;

  bool get _fixedFolder => !widget.creatingFolder && widget.folder != null;
  WorkQuery get _query => WorkQuery(_tag.text, excluding: _excluded.text);
  bool get _usesTags => widget.creatingFolder || _isSmart;

  /// What the tags do, said as a sentence a newcomer can check: which works go in, how many
  /// already saved match, and how many more sit where the folder does not look.
  String get _matchFooter {
    final booru = widget.booru;
    if (_query.isEmpty) {
      return L10n.text(
        booru
            ? 'Enter tags separated by spaces, such as landscape. An image needs every tag to go in.'
            : 'Enter tags separated by spaces, such as language:korean. A work needs every tag to go in.',
      );
    }
    final included = spokenTags(_tag.text), left = spokenTags(_excluded.text);
    return [
      if (left.isEmpty)
        L10n.text(booru ? 'Images tagged %@ go in.' : 'Works tagged %@ go in.', [included])
      else
        L10n.text(booru ? 'Images tagged %@ go in, unless they are tagged %@.' : 'Works tagged %@ go in, unless they are tagged %@.', [included, left]),
      L10n.text(booru ? '%@ saved images match now.' : '%@ saved works match now.', ['$_matches']),
      if (_matchesElsewhere > 0)
        L10n.text('%@ more are in other folders and stay there. To bring them in too, choose those folders under More Options.', ['$_matchesElsewhere']),
    ].join(' ');
  }

  String get _smartFooter {
    if (_isSmart) {
      return L10n.text(
        widget.booru
            ? 'Images you save that have the tags below are put here on their own. An image you move yourself stays where you put it.'
            : 'Works you save that have the tags below are put here on their own. A work you move yourself stays where you put it.',
      );
    }
    return L10n.text(widget.booru ? 'This folder holds only the images you put in it.' : 'This folder holds only the works you put in it.');
  }

  String get _sourceFooter {
    if (_everyFolder) return L10n.text('It looks in every folder, including ones you make later.');
    if (_sources == null) {
      return L10n.text(
        widget.booru
            ? "It looks where new favorites land: Uncategorized and each site's folder. Images you filed in other folders yourself stay put."
            : 'It looks where new saves land: Unfiled and your default save folder. Works you filed in other folders yourself stay put.',
      );
    }
    return L10n.text(
      widget.booru
          ? 'It looks only in the folders checked here. Images in other folders stay put.'
          : 'It looks only in the folders checked here. Works in other folders stay put.',
    );
  }

  String get _actionFooter {
    if (widget.booru) return L10n.text('An image is in one folder at a time, so a matching image moves here from the folder it was in.');
    return L10n.text(
      _copies
          ? 'A matching work is added here and also stays in the folder it came from, so it appears in both.'
          : 'A matching work leaves the folder it came from, so it appears only here.',
    );
  }

  /// The switch files works already saved once, when Save is tapped; a smart folder alone
  /// only takes works saved after it.
  String get _fillFooter {
    if (_fillsSavedWorks || !_isSmart) {
      if (widget.booru) return L10n.text('When you tap Save, matching images you already saved move here.');
      return L10n.text(
        _copies ? 'When you tap Save, matching works you already saved are copied here.' : 'When you tap Save, matching works you already saved move here.',
      );
    }
    return L10n.text(widget.booru ? 'Only images you save from now on come here.' : 'Only works you save from now on come here.');
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
    keepsOriginal: widget.booru ? null : _copies,
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
      int matches, elsewhere;
      try {
        matches = widget.library.matchingCount(_rule);
        elsewhere = widget.library.matchingCountElsewhere(_rule);
      } on Object {
        matches = 0;
        elsewhere = 0;
      }
      setState(() {
        _matches = matches;
        _matchesElsewhere = elsewhere;
      });
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
    _copies = rule.copies;
    final existing = rule.sources?.toSet().intersection(_choices.map((choice) => choice.id).toSet());
    _sources = existing != null && existing.isNotEmpty ? existing : null;
    _showsMore = _sources != null || _everyFolder || _copies;
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
      // A new folder hands its identity back to whoever asked for it.
      Navigator.of(context).pop(widget.creatingFolder ? target : null);
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

  /// A tag entry under a short label, as a form row that holds a longer entry shows it.
  Widget _tagField(String title, TextEditingController controller, String prompt) => FormRow(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Text(
              title,
              style: TegnalType.style(15, weight: FontWeight.w600, color: TegnalColors.secondaryLabel.resolveFrom(context)),
            ),
          ),
          const SizedBox(height: 4),
          CupertinoTextField.borderless(
            controller: controller,
            autocorrect: false,
            enableSuggestions: false,
            minLines: 1,
            maxLines: 4,
            padding: EdgeInsets.zero,
            placeholder: prompt,
            placeholderStyle: TegnalType.style(17, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
            style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context)),
          ),
        ],
      ),
    ),
  );

  /// A note under a row inside a section, in the footer's type.
  Widget _caption(String text) => Text(text, style: TegnalType.style(13, color: TegnalColors.secondaryLabel.resolveFrom(context)));

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
            footer: footer(_smartFooter),
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
              FormRow(
                child: Row(
                  children: [
                    Icon(CupertinoIcons.sparkles, size: 20, color: tint),
                    const SizedBox(width: 10),
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
          if (_usesTags) ...[
            const SizedBox(height: 23),
            FormSection(
              header: Text(L10n.text(widget.booru ? 'Which Images Go In' : 'Which Works Go In')),
              footer: footer(_matchFooter),
              children: [
                _tagField(L10n.text('Include'), _tag, widget.booru ? 'landscape' : 'language:korean'),
                _tagField(L10n.text('Leave Out'), _excluded, L10n.text('Optional')),
              ],
            ),
            const SizedBox(height: 23),
            FormSection(
              footer: footer(_fillFooter),
              children: [
                FormRow(
                  child: Row(
                    children: [
                      Expanded(child: Text(L10n.text(widget.booru ? 'Also Bring In Saved Images' : 'Also Bring In Saved Works'))),
                      Transform.translate(
                        offset: const Offset(2, 0),
                        child: TegnalSwitch(value: _fillsSavedWorks, onChanged: (value) => setState(() => _fillsSavedWorks = value)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 23),
            FormSection(
              children: [
                FormRow(
                  onTap: () => setState(() => _showsMore = !_showsMore),
                  child: Semantics(
                    button: true,
                    expanded: _showsMore,
                    child: Row(
                      children: [
                        Expanded(child: Text(L10n.text('More Options'))),
                        AnimatedRotation(
                          turns: _showsMore ? 0.25 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: Icon(CupertinoIcons.chevron_right, size: 15, color: tint),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_showsMore) ...[
                  Builder(
                    builder: (context) => FormRow(
                      onTap: () => _openSources(context),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(L10n.text('Look In')),
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
                            const SizedBox(height: 6),
                            _caption(_sourceFooter),
                          ],
                        ),
                      ),
                    ),
                  ),
                  FormRow(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.booru)
                            Row(
                              children: [
                                Expanded(child: Text(L10n.text('Matching Images'))),
                                Text(L10n.text('Move Here'), style: TegnalType.style(17, color: secondary)),
                              ],
                            )
                          else ...[
                            Text(L10n.text('Matching Works')),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: CupertinoSlidingSegmentedControl<bool>(
                                groupValue: _copies,
                                children: {false: Text(L10n.text('Move Here')), true: Text(L10n.text('Copy Here'))},
                                onValueChanged: (value) {
                                  if (value == null) return;
                                  setState(() => _copies = value);
                                  _changed();
                                },
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
                          _caption(_actionFooter),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}
