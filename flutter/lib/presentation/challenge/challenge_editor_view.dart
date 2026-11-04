import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../../core/challenge/challenge_models.dart';
import '../../core/challenge/challenge_store.dart';
import '../../core/support/l10n.dart';
import '../design/grouped_form.dart';
import '../design/ios_controls.dart';
import '../design/pull_down_menu.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import '../navigation/app_header.dart' show ToolbarGroup, ToolbarIconButton;
import 'challenge_library_view.dart' show showChallengeError;
import '../design/alert_dialog.dart';

/// Shows a playable preview of an unsaved challenge; supplied once play is available.
typedef ChallengePreviewer = void Function(BuildContext context, ChallengeDefinition game);

/// Pushes a page in the editor sheet; an [editable] page has an Edit button, as `.toolbar { EditButton() }`.
typedef _Push = void Function(String title, Widget Function(BuildContext context) builder, {bool editable});

/// `ChallengeEditorView`: three steps to make a challenge, with every rule a page away.
class ChallengeEditorView extends StatefulWidget {
  const ChallengeEditorView({super.key, required this.game, required this.store, this.preview});
  final ChallengeDefinition game;
  final ChallengeStore store;
  final ChallengePreviewer? preview;

  @override
  State<ChallengeEditorView> createState() => _ChallengeEditorViewState();
}

class _ChallengeEditorViewState extends State<ChallengeEditorView> {
  // Edits stay on a copy until Save.
  late final ChallengeDefinition _game = ChallengeDefinition.fromJson(widget.game.toJson());
  final _navigator = GlobalKey<NavigatorState>();

  void _changed() => setState(() {});

  Future<void> _cancel() async {
    final discard = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('Discard Changes?')),
        actions: [
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Discard'))),
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  void _save() {
    try {
      widget.store.save(_game);
      Navigator.of(context).pop();
    } on Object catch (error) {
      showChallengeError(context, error);
    }
  }

  void _preview() {
    try {
      _game.validate();
      widget.preview?.call(context, _game);
    } on Object catch (error) {
      showChallengeError(context, error);
    }
  }

  void _push(String title, Widget Function(BuildContext context) builder, {bool editable = false}) => _navigator.currentState!
      .push(
        CupertinoPageRoute<void>(
          builder: (context) => _EditorPage(
            title: title,
            onChanged: _changed,
            editable: editable,
            child: Builder(builder: builder),
          ),
        ),
      )
      .then((_) => _changed());

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: Navigator(
      key: _navigator,
      onGenerateRoute: (_) => CupertinoPageRoute<void>(builder: (context) => _main(context)),
    ),
  );

  Widget _main(BuildContext context) {
    final purple = SystemColors.purple.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final game = _game;
    return ScrollEdgeSheet(
      bar: SheetNavigationBar(
        title: L10n.text('Edit Challenge'),
        leading: GlassTextButton(label: L10n.text('Cancel'), onPressed: _cancel),
        trailing: ToolbarGroup(
          children: [
            if (widget.preview != null)
              ToolbarIconButton(label: L10n.text('Preview Challenge'), icon: CupertinoIcons.play_circle, size: 24, onPressed: _preview),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _save,
              child: SizedBox(
                height: 44,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      L10n.text('Save'),
                      style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      child: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.only(top: 69 + 35, bottom: 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          FormSection(
            prominentHeader: true,
            rowColor: purple.withValues(alpha: 0.06),
            children: [
              FormRow(
                separatorInset: 56,
                child: Row(
                  children: [
                    Icon(CupertinoIcons.wand_stars, size: 22, color: purple),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Text(
                        L10n.text('Make it yours in three steps'),
                        style: TegnalType.style(17, weight: FontWeight.w600, color: purple),
                      ),
                    ),
                  ],
                ),
              ),
              FormRow(
                child: Text(
                  L10n.text('Start with a ready-to-play example. Add a title, change the choices, and choose a goal.'),
                  style: TegnalType.style(15, color: secondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          FormSection(
            prominentHeader: true,
            header: Text(L10n.text('1. Introduce Your Game')),
            footer: Text(L10n.text('Explain how to play. These instructions appear before and during the game and are included in backups.')),
            children: [
              ChallengeTextRow(value: game.title, placeholder: L10n.text('Title'), onChanged: (value) => game.title = value),
              ChallengeTextRow(value: game.detail, placeholder: L10n.text('Game Instructions'), lines: 3, onChanged: (value) => game.detail = value),
              _LinkRow(
                title: L10n.text('Help Tabs'),
                value: '${game.helpPages?.length ?? 0}',
                onTap: () => _push(L10n.text('Help Tabs'), (context) => _HelpEditor(game: game, push: _push), editable: true),
              ),
            ],
          ),
          const SizedBox(height: 15),
          FormSection(
            prominentHeader: true,
            header: Text(L10n.text('2. Choose What to Draw')),
            footer: Text(L10n.text('One choice is drawn from each list. Tap a list to type, paste, or reorder choices.')),
            children: [
              for (final group in game.reels)
                FormRow(
                  onTap: () => _push(group.title, (context) => _GroupEditor(group: group), editable: true),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                group.title,
                                style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                group.options.take(4).map((option) => option.text).join(' · '),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TegnalType.style(12, color: secondary),
                              ),
                            ],
                          ),
                        ),
                        const _Chevron(),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 15),
          FormSection(
            prominentHeader: true,
            header: Text(L10n.text('3. Set a Goal')),
            footer: Text(L10n.text('Finish each mission yourself to earn points. The default scoring and endings are ready to use.')),
            children: [
              ChallengePickerRow<ChallengeGoalMode>(
                tint: purple,
                title: L10n.text('Goal Type'),
                options: [for (final mode in ChallengeGoalMode.values) (mode, L10n.text(_capitalized(mode.name)))],
                selected: game.goal.mode,
                onSelected: (mode) => setState(() => game.goal.mode = mode),
              ),
              if (game.goal.mode != ChallengeGoalMode.count)
                _LinkRow(
                  title: L10n.text('Time Range (Seconds)'),
                  value: '${game.goal.time.minimum}…${game.goal.time.maximum}',
                  onTap: () => _push(
                    L10n.text('Time Range (Seconds)'),
                    (context) => _RangeEditor(range: game.goal.time, limit: 86400, onChanged: (range) => game.goal.time = range),
                  ),
                ),
              if (game.goal.mode != ChallengeGoalMode.time)
                _LinkRow(
                  title: L10n.text('Count Range'),
                  value: '${game.goal.count.minimum}…${game.goal.count.maximum}',
                  onTap: () => _push(
                    L10n.text('Count Range'),
                    (context) => _RangeEditor(range: game.goal.count, limit: 10000, onChanged: (range) => game.goal.count = range),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 22),
          FormSection(
            prominentHeader: true,
            footer: Text(L10n.text('Optional: customize mission text, supporting groups, probabilities, points, and endings.')),
            children: [
              if (widget.preview != null)
                FormRow(
                  onTap: _preview,
                  separatorInset: 56,
                  child: Row(
                    children: [
                      Icon(CupertinoIcons.play_circle_fill, size: 24, color: purple),
                      const SizedBox(width: 16),
                      Text(L10n.text('Preview Challenge'), style: TegnalType.style(17, color: purple)),
                    ],
                  ),
                ),
              FormRow(
                onTap: () => _push(L10n.text('Advanced Rules'), (context) => _AdvancedRules(game: game, push: _push), editable: true),
                child: Row(
                  children: [
                    Icon(CupertinoIcons.slider_horizontal_3, size: 22, color: purple),
                    const SizedBox(width: 18),
                    Expanded(child: Text(L10n.text('Advanced Rules'))),
                    const _Chevron(),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// `move(fromOffsets:toOffset:)` for one row, on a copy as the list's other edits make.
List<T> _moved<T>(List<T> list, int from, int to) {
  final copy = [...list];
  copy.insert(to, copy.removeAt(from));
  return copy;
}

String _capitalized(String value) => value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

/// A pushed page inside the editor sheet, with Back and the page's title; an editable page
/// also has `EditButton`, which turns its lists' edit mode on and off.
class _EditorPage extends StatefulWidget {
  const _EditorPage({required this.title, required this.onChanged, required this.child, this.editable = false});
  final String title;
  final VoidCallback onChanged;
  final bool editable;
  final Widget child;

  @override
  State<_EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<_EditorPage> {
  bool _editing = false;

  @override
  Widget build(BuildContext context) => ScrollEdgeSheet(
    bar: SheetNavigationBar(
      title: widget.title,
      leading: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Semantics(
          button: true,
          label: L10n.text('Back'),
          child: Container(
            width: 44,
            height: 44,
            decoration: ShapeDecoration(color: TegnalColors.elevatedGlassFill.resolveFrom(context), shape: const CircleBorder()),
            child: Icon(CupertinoIcons.chevron_left, size: 20, color: TegnalColors.label.resolveFrom(context)),
          ),
        ),
      ),
      trailing: !widget.editable
          ? null
          : _editing
          // While editing, Done is a checkmark in a filled accent circle.
          ? Semantics(
              button: true,
              label: L10n.text('Done'),
              excludeSemantics: true,
              child: GestureDetector(
                onTap: () => setState(() => _editing = false),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: ShapeDecoration(color: TegnalColors.tint.resolveFrom(context), shape: const CircleBorder()),
                  child: const Icon(CupertinoIcons.checkmark_alt, size: 22, color: Color(0xFFFFFFFF)),
                ),
              ),
            )
          : GlassTextButton(label: L10n.text('Edit'), onPressed: () => setState(() => _editing = true)),
    ),
    child: _Editing(editing: _editing, child: widget.child),
  );
}

/// SwiftUI's `editMode` for the page's lists.
class _Editing extends InheritedWidget {
  const _Editing({required this.editing, required super.child});
  final bool editing;

  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_Editing>()?.editing ?? false;

  @override
  bool updateShouldNotify(_Editing oldWidget) => editing != oldWidget.editing;
}

EdgeInsets _listPadding(BuildContext context) => EdgeInsets.only(top: 69 + 35, bottom: 32 + MediaQuery.paddingOf(context).bottom);

class _Chevron extends StatelessWidget {
  const _Chevron();
  @override
  Widget build(BuildContext context) => Icon(CupertinoIcons.chevron_right, size: 14, color: TegnalColors.tertiaryLabel.resolveFrom(context));
}

/// A `NavigationLink` row. In edit mode the link is off and its title dimmed.
class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.title, required this.onTap, this.value, this.editing = false});
  final String title;
  final String? value;
  final VoidCallback onTap;
  final bool editing;

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return FormRow(
      onTap: editing ? null : onTap,
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: editing ? TegnalType.style(17, color: secondary) : null),
          ),
          if (value != null) ...[Text(value!, style: TegnalType.style(17, color: secondary)), const SizedBox(width: 6)],
          const _Chevron(),
        ],
      ),
    );
  }
}

/// A text field in a form row that writes through to the model as the person types.
class ChallengeTextRow extends StatefulWidget {
  const ChallengeTextRow({super.key, required this.value, required this.placeholder, required this.onChanged, this.lines = 1});
  final String value;
  final String placeholder;
  final ValueChanged<String> onChanged;
  final int lines;

  @override
  State<ChallengeTextRow> createState() => _ChallengeTextRowState();
}

class _ChallengeTextRowState extends State<ChallengeTextRow> {
  late final _controller = TextEditingController(text: widget.value);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FormRow(
    child: CupertinoTextField.borderless(
      controller: _controller,
      padding: EdgeInsets.zero,
      minLines: widget.lines,
      maxLines: widget.lines == 1 ? 1 : null,
      placeholder: widget.placeholder,
      placeholderStyle: TegnalType.style(17, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
      style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context)),
      onChanged: widget.onChanged,
    ),
  );
}

/// `ChallengeNumberField`: a title with a number typed at the trailing edge.
class _NumberRow extends StatefulWidget {
  const _NumberRow({required this.title, required this.value, required this.onChanged});
  final String title;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<_NumberRow> createState() => _NumberRowState();
}

class _NumberRowState extends State<_NumberRow> {
  late final _controller = TextEditingController(text: '${widget.value}');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FormRow(
    child: Row(
      children: [
        Expanded(child: Text(widget.title)),
        SizedBox(
          width: 120,
          child: CupertinoTextField.borderless(
            controller: _controller,
            padding: EdgeInsets.zero,
            textAlign: TextAlign.right,
            keyboardType: TextInputType.number,
            style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context)),
            onChanged: (text) {
              final value = int.tryParse(text);
              if (value != null) widget.onChanged(value);
            },
          ),
        ),
      ],
    ),
  );
}

/// A `Picker` row: the choice at the trailing edge opens a pull-down menu.
class ChallengePickerRow<T> extends StatelessWidget {
  const ChallengePickerRow({super.key, required this.title, required this.options, required this.selected, required this.onSelected, this.tint});
  final String title;

  /// A form with its own tint shows the value in it; otherwise the value is secondary.
  final Color? tint;
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final color = tint ?? TegnalColors.secondaryLabel.resolveFrom(context);
    return Builder(
      builder: (rowContext) => FormRow(
        onTap: () async {
          final value = await showPullDownMenu<T>(
            rowContext,
            anchor: anchorRectOf(rowContext),
            items: [for (final (value, label) in options) PullDownMenuItem(value: value, title: label, checked: value == selected)],
          );
          if (value != null) onSelected(value);
        },
        child: Row(
          children: [
            Expanded(child: Text(title)),
            Text(options.where((option) => option.$1 == selected).firstOrNull?.$2 ?? '', style: TegnalType.style(17, color: color)),
            const SizedBox(width: 4),
            Icon(CupertinoIcons.chevron_up_chevron_down, size: 15, color: color),
          ],
        ),
      ),
    );
  }
}

/// A row that removes itself when swiped, as `.onDelete` lists do.
Widget _deletable(BuildContext context, Key key, VoidCallback delete, Widget child) => Dismissible(
  key: key,
  direction: DismissDirection.endToStart,
  onDismissed: (_) => delete(),
  background: Container(
    color: SystemColors.red.resolveFrom(context),
    alignment: Alignment.centerRight,
    padding: const EdgeInsets.only(right: 16),
    child: Text(L10n.text('Delete'), style: TegnalType.style(17, color: const Color(0xFFFFFFFF))),
  ),
  child: child,
);

/// The rows of an `.onDelete` / `.onMove` list. Out of edit mode a row is swiped away; in edit mode
/// each row leads with the red delete control and trails a handle that drags it within the list.
List<Widget> _editableRows<T>(
  BuildContext context, {
  required List<T> items,
  required String Function(T item) id,
  required void Function(T item) delete,
  required void Function(int from, int to) move,
  required Widget Function(T item, bool editing) row,
}) {
  if (!_Editing.of(context)) {
    return [for (final item in items) _deletable(context, ValueKey(id(item)), () => delete(item), row(item, false))];
  }
  if (items.isEmpty) return const [];
  final separator = TegnalColors.separator.resolveFrom(context);
  final red = SystemColors.red.resolveFrom(context);
  final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
  final background = FormColors.row.resolveFrom(context);
  return [
    _EditingRows(
      child: ReorderableList(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: items.length,
        onReorderStart: (_) => HapticFeedback.selectionClick(),
        onReorderItem: move,
        proxyDecorator: (child, index, animation) => DecoratedBox(
          decoration: BoxDecoration(
            color: background,
            boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 16, offset: Offset(0, 6))],
          ),
          child: child,
        ),
        itemBuilder: (context, index) {
          final item = items[index];
          return Stack(
            key: ValueKey(id(item)),
            children: [
              // The title moves to 56 pt, past the delete control; the handle follows the chevron.
              Padding(
                padding: const EdgeInsets.only(left: _EditingRows.inset - 16, right: 34),
                child: row(item, true),
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: _EditingRows.inset,
                child: Semantics(
                  button: true,
                  label: L10n.text('Delete'),
                  excludeSemantics: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => delete(item),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        // The minus is white on the red circle, as on iOS.
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(width: 12, height: 3, color: const Color(0xFFFFFFFF)),
                            Icon(CupertinoIcons.minus_circle_fill, size: 22, color: red),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 6,
                top: 0,
                bottom: 0,
                width: 44,
                child: Center(
                  child: ReorderableDragStartListener(
                    index: index,
                    child: SizedBox(width: 44, height: 52, child: Icon(CupertinoIcons.line_horizontal_3, size: 22, color: secondary)),
                  ),
                ),
              ),
              if (index < items.length - 1)
                Positioned(
                  left: _EditingRows.inset,
                  right: 16,
                  bottom: 0,
                  height: 0.5,
                  child: ColoredBox(color: separator),
                ),
            ],
          );
        },
      ),
    ),
  ];
}

/// The editing rows as one child of a [FormSection], whose line below starts under their titles too.
class _EditingRows extends FormRow {
  const _EditingRows({required super.child}) : super(separatorInset: inset);

  /// Where an editing row's title and separator start.
  static const double inset = 56;

  @override
  Widget build(BuildContext context) => child;
}

Widget _actionRow(BuildContext context, String title, VoidCallback? onTap, {IconData? icon}) {
  final tint = TegnalColors.tint.resolveFrom(context).withValues(alpha: onTap == null ? 0.4 : 1);
  return FormRow(
    onTap: onTap,
    child: Row(
      children: [
        if (icon != null) ...[Icon(icon, size: 22, color: tint), const SizedBox(width: 12)],
        Text(title, style: TegnalType.style(17, color: tint)),
      ],
    ),
  );
}

/// `ChallengeRangeEditor`: quick fixed goals, or a custom random range.
class _RangeEditor extends StatefulWidget {
  const _RangeEditor({required this.range, required this.limit, required this.onChanged});
  final ChallengeRange range;
  final int limit;
  final ValueChanged<ChallengeRange> onChanged;

  @override
  State<_RangeEditor> createState() => _RangeEditorState();
}

class _RangeEditorState extends State<_RangeEditor> {
  late ChallengeRange _range = widget.range;
  bool _custom = false;

  void _set(ChallengeRange value) {
    setState(() => _range = value);
    widget.onChanged(value);
  }

  String _goal(int value) {
    final time = widget.limit == 86400;
    return L10n.text(time ? (value == 1 ? '%@ second' : '%@ seconds') : (value == 1 ? '%@ repetition' : '%@ repetitions'), ['$value']);
  }

  @override
  Widget build(BuildContext context) {
    final purple = SystemColors.purple.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    final quick = widget.limit == 86400 ? const [30, 60, 90, 120] : const [1, 5, 10, 20];
    return ListView(
      padding: _listPadding(context),
      children: [
        FormSection(
          prominentHeader: true,
          children: [
            FormRow(
              child: Text(
                _range.minimum == _range.maximum ? '${_range.minimum}' : '${_range.minimum}…${_range.maximum}',
                style: TegnalType.style(34, weight: FontWeight.w700, color: purple),
              ),
            ),
            FormRow(
              child: Text(
                L10n.text('Choose a fixed goal below, or customize a random range.'),
                style: TegnalType.style(15, color: TegnalColors.secondaryLabel.resolveFrom(context)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),
        FormSection(
          prominentHeader: true,
          header: Text(L10n.text('Quick Goals')),
          children: [
            for (final goal in quick)
              FormRow(
                onTap: () => _set(ChallengeRange(minimum: goal, maximum: goal)),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(_goal(goal), style: TegnalType.style(17, color: tint)),
                    ),
                    if (_range.minimum == goal && _range.maximum == goal) Icon(CupertinoIcons.checkmark_alt, size: 20, color: tint),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 28),
        FormSection(
          prominentHeader: true,
          children: [
            FormRow(
              onTap: () => setState(() => _custom = !_custom),
              child: Row(
                children: [
                  Expanded(child: Text(L10n.text('Custom Goal Range'))),
                  AnimatedRotation(
                    turns: _custom ? 0.25 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(CupertinoIcons.chevron_right, size: 15, color: tint),
                  ),
                ],
              ),
            ),
            if (_custom) ...[
              _NumberRow(
                title: L10n.text('Minimum'),
                value: _range.minimum,
                onChanged: (value) => _set(ChallengeRange(minimum: value, maximum: _range.maximum, step: _range.step)),
              ),
              _NumberRow(
                title: L10n.text('Maximum'),
                value: _range.maximum,
                onChanged: (value) => _set(ChallengeRange(minimum: _range.minimum, maximum: value, step: _range.step)),
              ),
              _NumberRow(
                title: L10n.text('Step'),
                value: _range.step,
                onChanged: (value) => _set(ChallengeRange(minimum: _range.minimum, maximum: _range.maximum, step: value)),
              ),
            ],
            if (!_range.validate(widget.limit))
              FormRow(
                child: Text(
                  L10n.text('Use a positive range with evenly spaced steps.'),
                  style: TegnalType.style(17, color: SystemColors.red.resolveFrom(context)),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// `ChallengeGroupEditor`: a list's title, filter and options, with lines pasted in at once.
class _GroupEditor extends StatefulWidget {
  const _GroupEditor({required this.group});
  final ChallengeGroup group;

  @override
  State<_GroupEditor> createState() => _GroupEditorState();
}

class _GroupEditorState extends State<_GroupEditor> {
  final _lines = TextEditingController();
  bool _advanced = false;
  final _expanded = <String>{};

  ChallengeGroup get _group => widget.group;

  @override
  void initState() {
    super.initState();
    _lines.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _lines.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: _listPadding(context),
      children: [
        FormSection(
          prominentHeader: true,
          children: [
            ChallengeTextRow(value: _group.title, placeholder: L10n.text('Title'), onChanged: (value) => _group.title = value),
            FormRow(
              onTap: () => setState(() => _advanced = !_advanced),
              child: Row(
                children: [
                  Expanded(child: Text(L10n.text('Advanced Rules'))),
                  AnimatedRotation(
                    turns: _advanced ? 0.25 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(CupertinoIcons.chevron_right, size: 15, color: tint),
                  ),
                ],
              ),
            ),
            if (_advanced)
              ChallengeTextRow(value: _group.filter, placeholder: L10n.text('Group Filter (Empty = All)'), onChanged: (value) => _group.filter = value),
          ],
        ),
        const SizedBox(height: 28),
        FormSection(
          prominentHeader: true,
          header: Text(L10n.text('Options')),
          children: [
            ..._editableRows(
              context,
              items: _group.options,
              id: (option) => option.id,
              delete: (option) => setState(() => _group.options.remove(option)),
              move: (from, to) => setState(() => _group.options.insert(to, _group.options.removeAt(from))),
              row: (option, editing) => Column(
                children: [
                  ChallengeTextRow(
                    key: ValueKey('text:${option.id}'),
                    value: option.text,
                    placeholder: L10n.text('Text'),
                    onChanged: (value) => option.text = value,
                  ),
                  FormRow(
                    onTap: () => setState(() => _expanded.contains(option.id) ? _expanded.remove(option.id) : _expanded.add(option.id)),
                    child: Row(
                      children: [
                        Icon(option.enabled ? CupertinoIcons.slider_horizontal_3 : CupertinoIcons.eye_slash, size: 15, color: secondary),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(L10n.text('Tags and Probability'), style: TegnalType.style(12, color: secondary)),
                        ),
                        AnimatedRotation(
                          turns: _expanded.contains(option.id) ? 0.25 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: Icon(CupertinoIcons.chevron_right, size: 13, color: tint),
                        ),
                      ],
                    ),
                  ),
                  if (_expanded.contains(option.id)) ...[
                    ChallengeTextRow(
                      value: option.tags.join(' '),
                      placeholder: L10n.text('Search Tags'),
                      onChanged: (value) => option.tags = value.split(RegExp(r'\s+')).where((tag) => tag.isNotEmpty).toList(),
                    ),
                    FormRow(
                      child: Text(
                        L10n.text('Use space-separated tags. Rating and servers are chosen when playing.'),
                        style: TegnalType.style(12, color: secondary),
                      ),
                    ),
                    ChallengeTextRow(value: option.group, placeholder: L10n.text('Group'), onChanged: (value) => option.group = value),
                    FormRow(
                      child: Row(
                        children: [
                          Expanded(child: Text(L10n.text('Enabled'))),
                          TegnalSwitch(value: option.enabled, onChanged: (value) => setState(() => option.enabled = value)),
                        ],
                      ),
                    ),
                    _NumberRow(title: L10n.text('Weight'), value: option.weight, onChanged: (value) => option.weight = value),
                  ],
                ],
              ),
            ),
            _actionRow(context, L10n.text('Add Option'), () => setState(() => _group.options.add(ChallengeOption(text: L10n.text('New Option'))))),
          ],
        ),
        const SizedBox(height: 28),
        FormSection(
          prominentHeader: true,
          header: Text(L10n.text('Add Multiple Options')),
          children: [
            FormRow(
              child: CupertinoTextField.borderless(
                controller: _lines,
                padding: EdgeInsets.zero,
                minLines: 3,
                maxLines: 8,
                placeholder: L10n.text('One choice per line'),
                placeholderStyle: TegnalType.style(17, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
                style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context)),
              ),
            ),
            _actionRow(
              context,
              L10n.text('Add Lines'),
              _lines.text.trim().isEmpty
                  ? null
                  : () => setState(() {
                      _group.options.addAll([
                        for (final line in _lines.text.split('\n'))
                          if (line.trim().isNotEmpty) ChallengeOption(text: line.trim()),
                      ]);
                      _lines.clear();
                    }),
            ),
          ],
        ),
      ],
    );
  }
}

/// `ChallengeHelpEditor`: each page becomes a tab in How to Play.
class _HelpEditor extends StatefulWidget {
  const _HelpEditor({required this.game, required this.push});
  final ChallengeDefinition game;
  final _Push push;

  @override
  State<_HelpEditor> createState() => _HelpEditorState();
}

class _HelpEditorState extends State<_HelpEditor> {
  List<ChallengeHelpPage> get _pages => widget.game.helpPages ??= [];

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return ListView(
      padding: _listPadding(context),
      children: [
        FormSection(
          prominentHeader: true,
          footer: Text(L10n.text('Each page becomes a tab in How to Play. The game instructions appear first when filled in. Add rules, tips, or a glossary.')),
          children: [
            ..._editableRows(
              context,
              items: _pages,
              id: (page) => page.id,
              delete: (page) => setState(() => _pages.remove(page)),
              move: (from, to) => setState(() => _pages.insert(to, _pages.removeAt(from))),
              row: (page, editing) => FormRow(
                onTap: editing ? null : () => widget.push(L10n.text('Edit Help Tab'), (context) => _HelpPageEditor(page: page)),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(page.title.isEmpty ? L10n.text('New Help Tab') : page.title, style: editing ? TegnalType.style(17, color: secondary) : null),
                          if (page.body.isNotEmpty)
                            Text(
                              page.body,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TegnalType.style(12, color: secondary),
                            ),
                        ],
                      ),
                    ),
                    const _Chevron(),
                  ],
                ),
              ),
            ),
            _actionRow(
              context,
              L10n.text('Add Help Tab'),
              _pages.length >= 12 ? null : () => setState(() => _pages.add(ChallengeHelpPage(title: L10n.text('New Help Tab'), body: ''))),
              icon: CupertinoIcons.plus,
            ),
          ],
        ),
      ],
    );
  }
}

class _HelpPageEditor extends StatelessWidget {
  const _HelpPageEditor({required this.page});
  final ChallengeHelpPage page;

  @override
  Widget build(BuildContext context) => ListView(
    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
    padding: _listPadding(context),
    children: [
      FormSection(
        prominentHeader: true,
        children: [ChallengeTextRow(value: page.title, placeholder: L10n.text('Tab Title'), onChanged: (value) => page.title = value)],
      ),
      const SizedBox(height: 28),
      FormSection(
        prominentHeader: true,
        header: Text(L10n.text('Game Instructions')),
        children: [ChallengeTextRow(value: page.body, placeholder: '', lines: 10, onChanged: (value) => page.body = value)],
      ),
    ],
  );
}

/// The advanced rules: supporting groups, mission text, goal odds, scoring and endings.
class _AdvancedRules extends StatefulWidget {
  const _AdvancedRules({required this.game, required this.push});
  final ChallengeDefinition game;
  final _Push push;

  @override
  State<_AdvancedRules> createState() => _AdvancedRulesState();
}

class _AdvancedRulesState extends State<_AdvancedRules> {
  /// `.bordered` buttons fill with the tertiary system fill.
  static const _chipFill = CupertinoDynamicColor.withBrightness(color: Color(0x1F767680), darkColor: Color(0x3D767680));

  ChallengeDefinition get _game => widget.game;
  late final _template = TextEditingController(text: _game.template);

  @override
  void dispose() {
    _template.dispose();
    super.dispose();
  }

  String _variableTitle(String variable) {
    if (variable == 'goal') return L10n.text('Goal');
    if (variable == 'reel1') return _game.reels[0].title;
    if (variable == 'reel2') return _game.reels[1].title;
    final index = int.tryParse(variable.replaceAll('extra', ''));
    if (index != null && index >= 1 && index <= _game.groups.length) return _game.groups[index - 1].title;
    return variable;
  }

  void _push(String title, Widget Function(BuildContext context) builder, {bool editable = false}) {
    widget.push(title, builder, editable: editable);
  }

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final game = _game;
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: _listPadding(context),
      children: [
        FormSection(
          prominentHeader: true,
          header: Text(L10n.text('Supporting Groups')),
          children: [
            ..._editableRows(
              context,
              items: game.groups,
              id: (group) => group.id,
              delete: (group) => setState(() => game.groups = [...game.groups]..remove(group)),
              move: (from, to) => setState(() => game.groups = _moved(game.groups, from, to)),
              row: (group, editing) => _LinkRow(
                title: group.title,
                value: '${group.options.length}',
                editing: editing,
                onTap: () => _push(group.title, (context) => _GroupEditor(group: group), editable: true),
              ),
            ),
            _actionRow(
              context,
              L10n.text('Add Supporting Group'),
              game.groups.length >= 12
                  ? null
                  : () => setState(
                      () => game.groups = [
                        ...game.groups,
                        ChallengeGroup(
                          title: L10n.text('Supporting Group'),
                          options: [ChallengeOption(text: L10n.text('New Option'))],
                        ),
                      ],
                    ),
            ),
          ],
        ),
        const SizedBox(height: 28),
        FormSection(
          prominentHeader: true,
          header: Text(L10n.text('Mission Text')),
          children: [
            FormRow(
              // `TextEditor` insets its text and is at least 100 pt tall.
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 112),
                child: CupertinoTextField.borderless(
                  controller: _template,
                  padding: const EdgeInsets.fromLTRB(5, 16, 5, 8),
                  minLines: 4,
                  maxLines: null,
                  style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context)),
                  onChanged: (value) => game.template = value,
                ),
              ),
            ),
            FormRow(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final variable in game.variables) ...[
                      GestureDetector(
                        onTap: () {
                          _template.text += '{$variable}';
                          game.template = _template.text;
                        },
                        child: Container(
                          height: 34,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: ShapeDecoration(color: _chipFill.resolveFrom(context), shape: const StadiumBorder()),
                          child: Center(
                            widthFactor: 1,
                            child: Text(_variableTitle(variable), style: TegnalType.style(17, color: tint)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
            ),
            FormRow(
              child: Text(
                L10n.text('Tap a variable to insert a drawn value. Supporting groups use their current order.'),
                style: TegnalType.style(12, color: secondary),
              ),
            ),
          ],
        ),
        if (game.goal.mode == ChallengeGoalMode.mixed) ...[
          const SizedBox(height: 28),
          FormSection(
            prominentHeader: true,
            header: Text(L10n.text('Goal Probability')),
            children: [
              _NumberRow(title: L10n.text('Time Weight'), value: game.goal.timeWeight, onChanged: (value) => game.goal.timeWeight = value),
              _NumberRow(title: L10n.text('Count Weight'), value: game.goal.countWeight, onChanged: (value) => game.goal.countWeight = value),
            ],
          ),
        ],
        const SizedBox(height: 28),
        FormSection(
          prominentHeader: true,
          header: Text(L10n.text('Scoring')),
          children: [
            _NumberRow(title: L10n.text('Target Score'), value: game.target, onChanged: (value) => game.target = value),
            ChallengePickerRow<double>(
              title: L10n.text('Score Multiplier'),
              options: [
                for (final value in const [0.5, 1.0, 1.5, 2.0]) (value, '${value.toStringAsFixed(1)}×'),
              ],
              selected: game.multiplier,
              onSelected: (value) => setState(() => game.multiplier = value),
            ),
            ..._editableRows(
              context,
              items: game.bands,
              id: (band) => band.id,
              delete: (band) => setState(() => game.bands = [...game.bands]..remove(band)),
              move: (from, to) => setState(() => game.bands = _moved(game.bands, from, to)),
              row: (band, editing) => _LinkRow(
                title: '≤ ${band.through}: +${band.minimum}…${band.maximum}',
                editing: editing,
                onTap: () => _push(
                  L10n.text('Score Band'),
                  (context) => ListView(
                    padding: _listPadding(context),
                    children: [
                      FormSection(
                        prominentHeader: true,
                        children: [
                          _NumberRow(title: L10n.text('Through Score'), value: band.through, onChanged: (value) => band.through = value),
                          _NumberRow(title: L10n.text('Minimum'), value: band.minimum, onChanged: (value) => band.minimum = value),
                          _NumberRow(title: L10n.text('Maximum'), value: band.maximum, onChanged: (value) => band.maximum = value),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _actionRow(
              context,
              L10n.text('Add Score Band'),
              () => setState(
                () => game.bands = [
                  ...game.bands,
                  ChallengeScoreBand(through: ((game.bands.lastOrNull?.through ?? 0) + 100).clamp(0, 100000), minimum: 1, maximum: 5),
                ],
              ),
            ),
            FormRow(
              child: Text(
                L10n.text('Bands must increase and cover the target score. Points use the score before completion.'),
                style: TegnalType.style(12, color: secondary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),
        FormSection(
          prominentHeader: true,
          header: Text(L10n.text('Endings')),
          children: [
            ChallengePickerRow<String?>(
              title: L10n.text('Final Result'),
              options: [(null, L10n.text('Random')), for (final ending in game.endings) (ending.id, ending.title)],
              selected: game.fixedEndingID,
              onSelected: (value) => setState(() => game.fixedEndingID = value),
            ),
            ..._editableRows(
              context,
              items: game.endings,
              id: (ending) => ending.id,
              delete: (ending) => setState(() {
                if (game.fixedEndingID == ending.id) game.fixedEndingID = null;
                game.endings = [...game.endings]..remove(ending);
              }),
              move: (from, to) => setState(() => game.endings = _moved(game.endings, from, to)),
              row: (ending, editing) => _LinkRow(
                title: ending.title,
                editing: editing,
                onTap: () => _push(L10n.text('Edit Ending'), (context) => _EndingEditor(ending: ending)),
              ),
            ),
            _actionRow(
              context,
              L10n.text('Add Ending'),
              () => setState(() => game.endings = [...game.endings, ChallengeEnding(title: L10n.text('New Ending'), detail: '', badge: '★')]),
            ),
          ],
        ),
      ],
    );
  }
}

/// `ChallengeEndingEditor`.
class _EndingEditor extends StatefulWidget {
  const _EndingEditor({required this.ending});
  final ChallengeEnding ending;

  @override
  State<_EndingEditor> createState() => _EndingEditorState();
}

class _EndingEditorState extends State<_EndingEditor> {
  ChallengeEnding get _ending => widget.ending;

  @override
  Widget build(BuildContext context) => ListView(
    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
    padding: _listPadding(context),
    children: [
      FormSection(
        prominentHeader: true,
        children: [
          ChallengeTextRow(value: _ending.title, placeholder: L10n.text('Title'), onChanged: (value) => setState(() => _ending.title = value)),
          ChallengeTextRow(
            value: _ending.detail,
            placeholder: L10n.text('Description'),
            lines: 3,
            onChanged: (value) => setState(() => _ending.detail = value),
          ),
          ChallengeTextRow(value: _ending.badge, placeholder: L10n.text('Badge'), onChanged: (value) => setState(() => _ending.badge = value)),
          ChallengePickerRow<String>(
            title: L10n.text('Color'),
            options: [for (final color in ChallengeEnding.colors) (color, L10n.text(_capitalized(color)))],
            selected: _ending.color,
            onSelected: (value) => setState(() => _ending.color = value),
          ),
          _NumberRow(title: L10n.text('Weight'), value: _ending.weight, onChanged: (value) => _ending.weight = value),
        ],
      ),
      const SizedBox(height: 28),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ChallengeEndingCard(ending: _ending),
      ),
    ],
  );
}

/// The color an ending's card uses.
Color challengeEndingColor(String name, BuildContext context) => switch (name) {
  'pink' => SystemColors.pink,
  'green' => SystemColors.green,
  'orange' => SystemColors.orange,
  'blue' => SystemColors.blue,
  _ => SystemColors.purple,
}.resolveFrom(context);

/// `ChallengeEndingCard`: the badge, title and description of a result.
class ChallengeEndingCard extends StatelessWidget {
  const ChallengeEndingCard({super.key, required this.ending});
  final ChallengeEnding ending;

  @override
  Widget build(BuildContext context) {
    final color = challengeEndingColor(ending.color, context);
    final label = TegnalColors.label.resolveFrom(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: ShapeDecoration(
        color: color.withValues(alpha: 0.12),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: color.withValues(alpha: 0.5)),
        ),
      ),
      child: Column(
        children: [
          Text(ending.badge, style: TegnalType.style(34, color: label)),
          const SizedBox(height: 12),
          Text(
            ending.title,
            textAlign: TextAlign.center,
            style: TegnalType.style(22, weight: FontWeight.w700, color: label),
          ),
          const SizedBox(height: 12),
          Text(
            ending.detail,
            textAlign: TextAlign.center,
            style: TegnalType.style(17, color: label),
          ),
        ],
      ),
    );
  }
}
