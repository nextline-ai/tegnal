import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../core/storage/app_database.dart';
import '../../core/support/l10n.dart';
import '../../core/support/preferences.dart';
import '../../domain/models.dart';
import '../design/context_menu.dart';
import '../design/grouped_form.dart';
import '../design/pull_down_menu.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import '../navigation/app_header.dart';
import '../navigation/app_state.dart';
import '../navigation/root_tab_view.dart';
import 'library_routes.dart';

/// `SavedCollectionsModel` for comics: saved tags, artists and searches, and the search history.
/// Reads and writes stay in the comics database; order lives in preferences.
class SavedCollectionsModel extends ChangeNotifier {
  SavedCollectionsModel({required this.database, required this.preferences}) {
    refresh();
    _changes = database.changes.listen((_) => refresh());
  }

  final AppDatabase database;
  final Preferences preferences;
  StreamSubscription<int>? _changes;
  List<ArtistMemo> _tags = [];
  List<String> _searches = [];
  List<String> _history = [];

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  List<SavedCollectionKind> get sections => SavedCollectionKind.values
      .where(
        (kind) =>
            const {
              SavedCollectionKind.tag,
              SavedCollectionKind.artist,
              SavedCollectionKind.series,
              SavedCollectionKind.search,
              SavedCollectionKind.history,
            }.contains(kind) ||
            names(kind).isNotEmpty,
      )
      .toList();

  List<String> names(SavedCollectionKind kind) {
    final values = switch (kind) {
      SavedCollectionKind.search => _searches,
      SavedCollectionKind.history => _history,
      _ => [
        for (final tag in _tags)
          if (tag.kind == kind.mangaKind) tag.name,
      ],
    };
    // History follows its last-used time, even where an older install stored an order for it.
    if (kind == SavedCollectionKind.history) return values;
    final preferred = (preferences.object(_orderKey(kind)) as List?)?.whereType<String>().toList() ?? const [];
    return SavedCollectionOrdering.resolve(values, preferred: preferred);
  }

  void refresh() {
    _tags = database.listArtists();
    _searches = database.savedSearches();
    _history = database.searchHistory();
    notifyListeners();
  }

  String? save(String name, SavedCollectionKind kind) => _perform(() {
    final target = kind == SavedCollectionKind.history ? SavedCollectionKind.search : kind;
    final value = target.normalized(name);
    if (value.isEmpty) return null;
    database.saveCollectionTag(value, target);
    return L10n.text('Saved to Tags');
  });

  String? toggle(String name, SavedCollectionKind kind) => _perform(() {
    final target = kind == SavedCollectionKind.history ? SavedCollectionKind.search : kind;
    final saved = database.toggleCollectionTag(name, target);
    HapticFeedback.mediumImpact();
    return L10n.text(saved ? 'Saved to Tags' : 'Removed from Tags');
  });

  void remove(String name, SavedCollectionKind kind) => _perform(() {
    switch (kind) {
      case SavedCollectionKind.history:
        database.deleteSearch(name);
      case SavedCollectionKind.search:
        if (database.savedSearches().contains(name)) database.toggleSavedSearch(name);
      default:
        final code = kind.mangaKind;
        if (code != null) database.removeFavoriteArtist(name, kind: code);
    }
    return null;
  });

  void toggleSearch(String name) =>
      names(SavedCollectionKind.search).contains(name) ? remove(name, SavedCollectionKind.search) : save(name, SavedCollectionKind.search);

  void clearHistory() => _perform(() {
    database.clearSearchHistory();
    return null;
  });

  void reorder(SavedCollectionKind kind, int from, int to) {
    if (kind == SavedCollectionKind.history) return;
    final values = [...names(kind)];
    if (from < 0 || from >= values.length || to < 0 || to >= values.length) return;
    values.insert(to, values.removeAt(from));
    preferences.set(_orderKey(kind), values);
    notifyListeners();
  }

  void move(SavedCollectionKind kind, String name, int direction) {
    final values = names(kind);
    final index = values.indexOf(name);
    if (index < 0 || index + direction < 0 || index + direction >= values.length) return;
    reorder(kind, index, index + direction);
  }

  String query(SavedCollectionKind kind, String name) => kind.query(name, manga: true);

  String _orderKey(SavedCollectionKind kind) => 'collections.order.manga.${kind.rawValue}';

  /// Errors come back as the message to show; a notice is returned the same way.
  String? error;
  String? _perform(String? Function() action) {
    try {
      final notice = action();
      refresh();
      return notice;
    } on Object catch (failure) {
      error = '$failure';
      notifyListeners();
      return null;
    }
  }
}

IconData savedCollectionSymbol(SavedCollectionKind kind) => switch (kind) {
  SavedCollectionKind.tag => CupertinoIcons.tag,
  SavedCollectionKind.artist => CupertinoIcons.person,
  SavedCollectionKind.series => CupertinoIcons.book,
  SavedCollectionKind.character => CupertinoIcons.person_crop_square,
  SavedCollectionKind.group => CupertinoIcons.person_2,
  SavedCollectionKind.language => CupertinoIcons.globe,
  SavedCollectionKind.type => CupertinoIcons.square_stack,
  SavedCollectionKind.female || SavedCollectionKind.male => CupertinoIcons.person_crop_rectangle,
  SavedCollectionKind.metadata => CupertinoIcons.info_circle,
  SavedCollectionKind.search => CupertinoIcons.star,
  SavedCollectionKind.history => CupertinoIcons.clock,
};

/// `ArtistsListView`: the Tags tab, each kind's first five entries and a form to save one.
class CollectionsView extends StatefulWidget {
  const CollectionsView({super.key, required this.state, required this.routes, required this.preferences});
  final AppState state;
  final LibraryRoutes routes;
  final Preferences preferences;

  @override
  State<CollectionsView> createState() => _CollectionsViewState();
}

class _CollectionsViewState extends State<CollectionsView> {
  late final _model = SavedCollectionsModel(database: widget.routes.database, preferences: widget.preferences);
  final _name = TextEditingController();
  SavedCollectionKind _kind = SavedCollectionKind.tag;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _model.addListener(_modelChanged);
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _model.removeListener(_modelChanged);
    _model.dispose();
    _name.dispose();
    super.dispose();
  }

  void _modelChanged() {
    if (!mounted) return;
    final error = _model.error;
    if (error != null) {
      _model.error = null;
      showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: Text(L10n.text('Unable to Save')),
          content: Text(error),
          actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('Done')))],
        ),
      );
    }
    setState(() {});
  }

  void _add() {
    final notice = _model.save(_name.text, _kind);
    if (notice != null) {
      _name.clear();
      widget.routes.showMessage(context, notice);
    }
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top + rootBarHeight;
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final tertiary = TegnalColors.tertiaryLabel.resolveFrom(context);
    final row = FormColors.listRow.resolveFrom(context);
    final kinds = SavedCollectionKind.values.where((kind) => kind != SavedCollectionKind.history).toList();
    return ColoredBox(
      color: FormColors.listBackground.resolveFrom(context),
      child: Stack(
        children: [
          // The keyboard shortens the list, so the focused name field scrolls above it.
          Positioned.fill(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.only(top: top + 10, bottom: MediaQuery.viewInsetsOf(context).bottom > 0 ? 16 : tabBarClearance(context)),
              children: [
                for (final kind in _model.sections) ...[
                  CollectionSection(model: _model, kind: kind, full: false, editing: _editing, routes: widget.routes, preferences: widget.preferences),
                  const SizedBox(height: 28),
                ],
                FormSection(
                  prominentHeader: true,
                  rowColor: row,
                  header: Text(L10n.text('Save a Tag or Artist')),
                  footer: Text(L10n.text('Hold a tag or artist name in Work Information to save it here. Hold it again to remove it.')),
                  children: [
                    Builder(
                      builder: (context) => FormRow(
                        onTap: () async {
                          final value = await showPullDownMenu<SavedCollectionKind>(
                            context,
                            anchor: anchorRectOf(context),
                            items: [for (final kind in kinds) PullDownMenuItem(value: kind, title: L10n.text(kind.title), checked: kind == _kind)],
                          );
                          if (value != null) setState(() => _kind = value);
                        },
                        child: Row(
                          children: [
                            Expanded(child: Text(L10n.text('Type'))),
                            Text(L10n.text(_kind.title), style: TegnalType.style(17, color: secondary)),
                            const SizedBox(width: 4),
                            Icon(CupertinoIcons.chevron_up_chevron_down, size: 15, color: secondary),
                          ],
                        ),
                      ),
                    ),
                    FormRow(
                      child: Row(
                        children: [
                          Expanded(
                            child: CupertinoTextField.borderless(
                              controller: _name,
                              padding: EdgeInsets.zero,
                              autocorrect: false,
                              enableSuggestions: false,
                              placeholder: L10n.text('Tag name'),
                              placeholderStyle: TegnalType.style(17, color: tertiary),
                              style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context)),
                              onSubmitted: (_) => _add(),
                            ),
                          ),
                          GestureDetector(
                            onTap: _name.text.trim().isEmpty ? null : _add,
                            child: Text(
                              L10n.text('Add'),
                              style: TegnalType.style(17, color: _name.text.trim().isEmpty ? tertiary : TegnalColors.tint.resolveFrom(context)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: RootHeader(
              title: L10n.text('Tags'),
              state: widget.state,
              trailing: GlassTextButton(
                label: L10n.text(_editing ? 'Done' : 'Edit'),
                prominent: _editing,
                elevated: false,
                onPressed: () => setState(() => _editing = !_editing),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `SavedCollectionSection`: a kind's title and count, its entries, and Show More past five.
class CollectionSection extends StatelessWidget {
  const CollectionSection({
    super.key,
    required this.model,
    required this.kind,
    required this.full,
    required this.editing,
    required this.routes,
    required this.preferences,
  });
  final SavedCollectionsModel model;
  final SavedCollectionKind kind;
  final bool full;
  final bool editing;
  final LibraryRoutes routes;
  final Preferences preferences;

  Future<void> _confirmClear(BuildContext context) async {
    final clear = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(L10n.text('Clear History?')),
        content: Text(L10n.text('Search history will be deleted. Saved searches will be kept.')),
        actions: [
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Clear History'))),
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
        ],
      ),
    );
    if (clear == true) model.clearHistory();
  }

  @override
  Widget build(BuildContext context) {
    final names = model.names(kind);
    final shown = full ? names : SavedCollectionOrdering.preview(names);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final label = TegnalColors.label.resolveFrom(context);
    return FormSection(
      prominentHeader: true,
      rowColor: FormColors.listRow.resolveFrom(context),
      header: Row(
        children: [
          Text(L10n.text(kind.title)),
          const SizedBox(width: 8),
          Text(
            '${names.length}',
            style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
          ),
          const Spacer(),
          if (kind == SavedCollectionKind.history)
            Semantics(
              button: true,
              label: L10n.text('Clear History'),
              child: GestureDetector(
                onTap: names.isEmpty ? null : () => _confirmClear(context),
                child: Icon(
                  CupertinoIcons.trash,
                  size: 20,
                  color: names.isEmpty ? TegnalColors.tertiaryLabel.resolveFrom(context) : TegnalColors.tint.resolveFrom(context),
                ),
              ),
            ),
        ],
      ),
      children: [
        if (names.isEmpty)
          FormRow(
            child: Text(L10n.text('Nothing Saved Yet'), style: TegnalType.style(17, color: secondary)),
          ),
        for (final (index, name) in shown.indexed)
          _CollectionRow(
            key: ValueKey('${kind.rawValue}:$name'),
            model: model,
            kind: kind,
            name: name,
            full: full,
            editing: editing,
            first: index == 0,
            last: index == shown.length - 1,
            open: () => routes.openQuery(context, model.query(kind, name)),
          ),
        if (!full && SavedCollectionOrdering.showsMore(names.length))
          FormRow(
            onTap: () => Navigator.of(context).push(
              CupertinoPageRoute<void>(
                builder: (_) => _CollectionFullView(model: model, kind: kind, routes: routes, preferences: preferences),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(L10n.text('Show More'), style: TegnalType.style(17, color: label)),
                ),
                Icon(CupertinoIcons.chevron_right, size: 14, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
              ],
            ),
          ),
      ],
    );
  }
}

class _CollectionRow extends StatelessWidget {
  const _CollectionRow({
    super.key,
    required this.model,
    required this.kind,
    required this.name,
    required this.full,
    required this.editing,
    required this.first,
    required this.last,
    required this.open,
  });
  final SavedCollectionsModel model;
  final SavedCollectionKind kind;
  final String name;
  final bool full;
  final bool editing;
  final bool first;
  final bool last;
  final VoidCallback open;

  @override
  Widget build(BuildContext context) {
    final label = TegnalColors.label.resolveFrom(context);
    final tertiary = TegnalColors.tertiaryLabel.resolveFrom(context);
    final reorderable = kind != SavedCollectionKind.history;
    final content = Row(
      children: [
        if (editing) ...[
          GestureDetector(
            onTap: () => model.remove(name, kind),
            child: Icon(CupertinoIcons.minus_circle_fill, size: 22, color: SystemColors.red.resolveFrom(context)),
          ),
          const SizedBox(width: 12),
        ],
        Icon(savedCollectionSymbol(kind), size: 20, color: label),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            name.replaceAll('_', ' '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TegnalType.style(17, color: label),
          ),
        ),
        if (kind == SavedCollectionKind.history && !editing)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => model.toggleSearch(name),
            child: SizedBox(
              width: 32,
              height: 36,
              child: Icon(
                model.names(SavedCollectionKind.search).contains(name) ? CupertinoIcons.star_fill : CupertinoIcons.star,
                size: 19,
                color: SystemColors.yellow.resolveFrom(context),
              ),
            ),
          ),
        if (editing && reorderable)
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!first)
                GestureDetector(
                  onTap: () => model.move(kind, name, -1),
                  child: Icon(CupertinoIcons.chevron_up, size: 16, color: tertiary),
                ),
              if (!last)
                GestureDetector(
                  onTap: () => model.move(kind, name, 1),
                  child: Icon(CupertinoIcons.chevron_down, size: 16, color: tertiary),
                ),
            ],
          )
        else if (!editing) ...[
          const SizedBox(width: 4),
          Icon(CupertinoIcons.chevron_right, size: 14, color: tertiary),
        ],
      ],
    );
    return Builder(
      builder: (rowContext) => Semantics(
        button: true,
        customSemanticsActions: {
          if (reorderable) CustomSemanticsAction(label: L10n.text('Move Up')): () => model.move(kind, name, -1),
          if (reorderable) CustomSemanticsAction(label: L10n.text('Move Down')): () => model.move(kind, name, 1),
          CustomSemanticsAction(label: L10n.text('Save Tag')): () => model.toggle(name, kind),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: editing ? null : open,
          onLongPress: editing
              ? null
              : full
              ? () => model.toggle(name, kind)
              : () => showContextMenu(
                  rowContext,
                  anchor: _anchor(rowContext),
                  lift: 1.0,
                  child: ColoredBox(
                    color: FormColors.listRow.resolveFrom(context),
                    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: content),
                  ),
                  actions: [
                    ContextMenuAction(title: L10n.text('Remove'), icon: CupertinoIcons.trash, destructive: true, onSelected: () => model.remove(name, kind)),
                  ],
                ),
          child: Dismissible(
            key: ValueKey('dismiss:${kind.rawValue}:$name'),
            direction: editing ? DismissDirection.none : DismissDirection.endToStart,
            onDismissed: (_) => model.remove(name, kind),
            background: Container(
              color: SystemColors.red.resolveFrom(context),
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 24),
              child: const Icon(CupertinoIcons.trash, color: Color(0xFFFFFFFF)),
            ),
            child: FormRow(child: content),
          ),
        ),
      ),
    );
  }

  Rect _anchor(BuildContext context) {
    final box = context.findRenderObject()! as RenderBox;
    return box.localToGlobal(Offset.zero) & box.size;
  }
}

/// `SavedCollectionFullView`: every entry of one kind, pushed from Show More.
class _CollectionFullView extends StatefulWidget {
  const _CollectionFullView({required this.model, required this.kind, required this.routes, required this.preferences});
  final SavedCollectionsModel model;
  final SavedCollectionKind kind;
  final LibraryRoutes routes;
  final Preferences preferences;

  @override
  State<_CollectionFullView> createState() => _CollectionFullViewState();
}

class _CollectionFullViewState extends State<_CollectionFullView> {
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_changed);
  }

  @override
  void dispose() {
    widget.model.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top + rootBarHeight;
    return ColoredBox(
      color: FormColors.listBackground.resolveFrom(context),
      child: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              padding: EdgeInsets.only(top: top + 4, bottom: tabBarClearance(context)),
              children: [
                CollectionSection(
                  model: widget.model,
                  kind: widget.kind,
                  full: true,
                  editing: _editing,
                  routes: widget.routes,
                  preferences: widget.preferences,
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: RootHeader(
              title: L10n.text(widget.kind.title),
              state: widget.routes.state,
              onBack: () => Navigator.of(context).pop(),
              trailing: widget.kind == SavedCollectionKind.history
                  ? null
                  : GlassTextButton(
                      label: L10n.text(_editing ? 'Done' : 'Edit'),
                      prominent: _editing,
                      elevated: false,
                      onPressed: () => setState(() => _editing = !_editing),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
