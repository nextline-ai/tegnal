import 'package:material_ui/material_ui.dart';

import '../core/app_controller.dart';
import '../core/content.dart';
import '../core/library.dart';
import '../ui/common.dart';
import '../ui/content_tile.dart';
import '../ui/l10n.dart';
import '../ui/page_header.dart';

class ArtistsScreen extends StatefulWidget {
  const ArtistsScreen({
    super.key,
    required this.controller,
    required this.onOpen,
    required this.onSearch,
    this.mode,
    this.onOpenSequence,
  });
  final AppController controller;
  final void Function(ContentItem) onOpen;
  final void Function(String) onSearch;
  final AppMode? mode;
  final void Function(ContentItem, List<ContentItem>)? onOpenSequence;
  @override
  State<ArtistsScreen> createState() => _ArtistsScreenState();
}

class _ArtistsScreenState extends State<ArtistsScreen> {
  String _query = '';
  final FocusNode _searchFocus = FocusNode();
  AppMode get _mode => widget.mode ?? widget.controller.mode;

  @override
  void dispose() {
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final mode = _mode;
      final entries = widget.controller
          .artists(mode)
          .where(
            (artist) => '${artist.name} ${artist.note}'.toLowerCase().contains(
              _query.toLowerCase(),
            ),
          )
          .toList();
      final saved = widget.controller.savedItems(mode: mode);
      final searches = _savedSearches
          .where(
            (entry) => entry.query.toLowerCase().contains(_query.toLowerCase()),
          )
          .toList();
      final history = widget.controller
          .history(mode)
          .where(
            (entry) => entry.query.toLowerCase().contains(_query.toLowerCase()),
          )
          .toList();
      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: TegnalFloatingHeader(
          header: TegnalPageHeader(
            controller: widget.controller,
            mode: mode,
            title: mode == AppMode.booru ? 'Tags' : 'Artists',
            trailing: IconButton(
              onPressed: () => _edit(context),
              style: IconButton.styleFrom(padding: const EdgeInsets.all(8)),
              icon: Icon(
                Icons.add,
                size: 30,
                semanticLabel: L10n.tr(context, 'Add Artist'),
              ),
            ),
          ),
          searchFocusNode: _searchFocus,
          search: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextField(
              key: const ValueKey('artists.search'),
              focusNode: _searchFocus,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: L10n.tr(
                  context,
                  mode == AppMode.booru ? 'Search Tags' : 'Search artists',
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 14,
                ),
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                  borderSide: BorderSide.none,
                ),
                filled: true,
              ),
            ),
          ),
          child: ListView(
            padding: EdgeInsets.only(bottom: navigationScrollInset(context)),
            children: [
              const SizedBox(height: tegnalHeaderExtent + 72),
              if (mode == AppMode.booru)
                _section(context, 'Tags', [
                  for (final artist in entries.where(
                    (entry) => entry.kind != 0,
                  ))
                    _artistRow(context, artist, saved),
                ]),
              if (mode == AppMode.manga)
                _section(context, 'Groups', [
                  for (final artist in entries.where(
                    (entry) => entry.kind != 0,
                  ))
                    _artistRow(context, artist, saved),
                ]),
              _section(context, 'Artists', [
                for (final artist in entries.where((entry) => entry.kind == 0))
                  _artistRow(context, artist, saved),
              ]),
              _section(context, 'Saved Searches', [
                for (final entry in searches) _savedSearchRow(context, entry),
              ]),
              _section(
                context,
                'Search History',
                [for (final entry in history) _historyRow(context, entry)],
                trailing: IconButton(
                  onPressed: history.isEmpty ? null : _clearHistory,
                  style: IconButton.styleFrom(padding: const EdgeInsets.all(8)),
                  icon: Icon(
                    Icons.delete_outline,
                    size: 26,
                    semanticLabel: L10n.tr(context, 'Clear Search History'),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _section(
    BuildContext context,
    String title,
    List<Widget> rows, {
    Widget? trailing,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  L10n.tr(context, title),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: Column(
              children: rows.isEmpty
                  ? [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Text(
                            L10n.tr(
                              context,
                              _query.isEmpty
                                  ? 'Nothing Saved Yet'
                                  : 'No Results',
                            ),
                            style: TextStyle(
                              fontSize: 16,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ]
                  : [
                      for (var index = 0; index < rows.length; index++) ...[
                        if (index > 0)
                          Padding(
                            padding: const EdgeInsets.only(left: 56, right: 16),
                            child: Container(
                              height: .5,
                              color: Theme.of(context)
                                  .colorScheme
                                  .outlineVariant,
                            ),
                          ),
                        rows[index],
                      ],
                    ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _artistRow(
    BuildContext context,
    ArtistEntry artist,
    List<SavedItem> saved,
  ) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onLongPress: () => _actions(context, artist),
    onSecondaryTap: () => _actions(context, artist),
    child: TextButton(
      onPressed: () => artist.mode == AppMode.manga
          ? _openLocalWorks(artist)
          : _search(context, artist),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.fromLTRB(17, 12, 10, 12),
      ),
      child: Row(
        children: [
          Icon(
            artist.kind == 0 ? Icons.star : Icons.tag,
            size: artist.kind == 0 ? 22 : 28,
            color: artist.kind == 0
                ? Theme.of(context).colorScheme.tertiary
                : Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  artist.name.replaceAll('_', ' '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w500,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                if (artist.note.isNotEmpty || _count(artist, saved) > 0) ...[
                  const SizedBox(height: 3),
                  Text(
                    artist.note.isNotEmpty
                        ? artist.note
                        : '${_count(artist, saved)} ${L10n.tr(context, 'saved works')}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            onPressed: () => _actions(context, artist),
            style: IconButton.styleFrom(padding: const EdgeInsets.all(8)),
            icon: Icon(
              Icons.more_horiz,
              size: 28,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              semanticLabel: L10n.tr(context, 'Edit Artist'),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _savedSearchRow(BuildContext context, SearchEntry entry) =>
      GestureDetector(
        onLongPress: () => _searchActions(entry),
        onSecondaryTap: () => _searchActions(entry),
        child: TextButton(
          onPressed: () => _openSearch(entry),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 18),
          ),
          child: Row(
            children: [
              Icon(
                Icons.tag,
                color: Theme.of(context).colorScheme.primary,
                size: 28,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  entry.query.replaceAll('_', ' '),
                  style: TextStyle(
                    fontSize: 17,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 24,
                color: Theme.of(context).colorScheme.outline,
              ),
            ],
          ),
        ),
      );

  Widget _historyRow(BuildContext context, SearchEntry entry) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
    child: Row(
      children: [
        Expanded(
          child: TextButton(
            onPressed: () => _openSearch(entry),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 16),
              alignment: Alignment.centerLeft,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.history,
                  size: 25,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    entry.query.replaceAll('_', ' '),
                    style: const TextStyle(fontSize: 17),
                  ),
                ),
              ],
            ),
          ),
        ),
        IconButton(
          onPressed: () => _toggleSearch(entry),
          style: IconButton.styleFrom(padding: const EdgeInsets.all(9)),
          icon: Icon(
            _isSavedSearch(entry) ? Icons.star : Icons.star_border,
            size: 28,
            color: Theme.of(context).colorScheme.tertiary,
            semanticLabel: L10n.tr(context, 'Saved Searches'),
          ),
        ),
      ],
    ),
  );

  List<SearchEntry> get _savedSearches {
    final controller = widget.controller;
    if (_mode == AppMode.manga) {
      final saved =
          controller.store.portable('backup.comics')?['saved_searches']
              as List? ??
          [];
      return [
        for (final query in saved.whereType<String>())
          SearchEntry(
            AppMode.manga,
            '',
            query,
            DateTime.fromMillisecondsSinceEpoch(0),
          ),
      ];
    }
    final records =
        controller.store.portable('backup.images')?['savedTags'] as List? ?? [];
    return [
      for (final record in records.whereType<Map>())
        if (record['kind'] == 'search' &&
            record['name'] is String &&
            record['serverID'] is String)
          SearchEntry(
            AppMode.booru,
            record['serverID'] as String,
            record['name'] as String,
            DateTime.fromMillisecondsSinceEpoch(0),
          ),
    ];
  }

  bool _isSavedSearch(SearchEntry entry) => _savedSearches.any(
    (saved) =>
        saved.query == entry.query &&
        (entry.mode == AppMode.manga || saved.sourceId == entry.sourceId),
  );

  void _toggleSearch(SearchEntry entry) => _guard(context, () {
    final controller = widget.controller;
    final key = entry.mode == AppMode.manga ? 'backup.comics' : 'backup.images';
    final data = controller.store.portable(key) ?? <String, dynamic>{};
    final isSaved = _isSavedSearch(entry);
    if (entry.mode == AppMode.manga) {
      final queries = (data['saved_searches'] as List? ?? [])
          .whereType<String>()
          .toSet();
      isSaved ? queries.remove(entry.query) : queries.add(entry.query);
      data['saved_searches'] = queries.toList();
    } else {
      final records = (data['savedTags'] as List? ?? []).toList();
      if (isSaved) {
        records.removeWhere(
          (value) =>
              value is Map &&
              value['kind'] == 'search' &&
              value['name'] == entry.query &&
              value['serverID'] == entry.sourceId,
        );
      } else {
        records.add({
          'kind': 'search',
          'name': entry.query,
          'serverID': entry.sourceId,
        });
      }
      data['savedTags'] = records;
    }
    controller.store.setPortable(key, data);
    controller.changed();
  });

  void _openSearch(SearchEntry entry) {
    final source = widget.controller.sourceById(entry.sourceId);
    if (entry.sourceId.isNotEmpty && source == null) {
      showMessage(
        context,
        'Source unavailable',
        'Connect this artist’s source in Settings first.',
      );
      return;
    }
    if (source != null) widget.controller.selectSource(source);
    widget.onSearch(entry.query);
  }

  Future<void> _searchActions(SearchEntry entry) async {
    final remove = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: DefaultTextStyle(
                  style: Theme.of(context).textTheme.titleLarge!,
                  child: Text(entry.query),
                ),
              ),
              ...[
                ListTile(
                  title: Text(L10n.tr(context, 'Remove')),
                  onTap: () => Navigator.pop(context, true),
                  textColor: Theme.of(context).colorScheme.error,
                ),
              ],
              const Divider(),
              ListTile(
                title: Text(L10n.tr(context, 'Cancel')),
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      ),
    );
    if (remove == true && mounted) _toggleSearch(entry);
  }

  Future<void> _clearHistory() async {
    final mode = _mode;
    if (await confirmAction(
      context,
      'Clear Search History',
      'This clears search history for the current mode.',
      action: 'Clear History',
    )) {
      if (mounted) _guard(context, () => widget.controller.clearHistory(mode));
    }
  }

  int _count(ArtistEntry artist, List<SavedItem> saved) {
    final name = artist.name.replaceAll(' ', '_').toLowerCase();
    return saved
        .where(
          (entry) =>
              (artist.sourceId.isEmpty ||
                  entry.item.sourceId == artist.sourceId) &&
              (artist.kind == 0
                  ? entry.item.artists.any(
                      (value) =>
                          value.replaceAll(' ', '_').toLowerCase() == name,
                    )
                  : entry.item.tags.any(
                      (value) => value == name || value == 'group:$name',
                    )),
        )
        .length;
  }

  void _search(BuildContext context, ArtistEntry artist) {
    final source = widget.controller.sourceById(artist.sourceId);
    if (artist.sourceId.isNotEmpty && source == null) {
      showMessage(
        context,
        'Source unavailable',
        'Connect this artist’s source in Settings first.',
      );
      return;
    }
    if (source != null) widget.controller.selectSource(source);
    final token = artist.name.replaceAll(' ', '_');
    widget.onSearch(
      artist.mode == AppMode.booru
          ? token
          : '${artist.kind == 0 ? 'artist' : 'group'}:$token',
    );
  }

  void _openLocalWorks(ArtistEntry artist) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ArtistWorksScreen(
          controller: widget.controller,
          artist: artist,
          onOpen: widget.onOpen,
          onOpenSequence: widget.onOpenSequence,
        ),
      ),
    );
  }

  Future<void> _actions(BuildContext context, ArtistEntry artist) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: DefaultTextStyle(
                  style: Theme.of(context).textTheme.titleLarge!,
                  child: Text(artist.name),
                ),
              ),
              ...[
                ListTile(
                  title: Text(L10n.tr(context, 'Search')),
                  onTap: () => Navigator.pop(context, 'search'),
                ),
                ListTile(
                  title: Text(L10n.tr(context, 'Edit Artist')),
                  onTap: () => Navigator.pop(context, 'edit'),
                ),
                ListTile(
                  title: Text(L10n.tr(context, 'Delete')),
                  onTap: () => Navigator.pop(context, 'delete'),
                  textColor: Theme.of(context).colorScheme.error,
                ),
              ],
              const Divider(),
              ListTile(
                title: Text(L10n.tr(context, 'Cancel')),
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'search') _search(context, artist);
    if (action == 'edit') {
      await _edit(context, artist: artist);
      return;
    }
    if (action == 'delete' &&
        await confirmAction(
          context,
          'Delete Artist',
          'Remove this bookmark?',
        )) {
      if (context.mounted) {
        _guard(context, () => widget.controller.removeArtist(artist));
      }
    }
  }

  Future<void> _edit(BuildContext context, {ArtistEntry? artist}) async {
    final mode = artist?.mode ?? _mode;
    final name = TextEditingController(text: artist?.name ?? '');
    final note = TextEditingController(text: artist?.note ?? '');
    final sources = widget.controller.sources(mode);
    var sourceId =
        artist?.sourceId ?? widget.controller.selectedSource(mode)?.id ?? '';
    var kind = artist?.kind ?? 0;
    var invalid = false;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(
            L10n.tr(context, artist == null ? 'Add Artist' : 'Edit Artist'),
          ),
          content: Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  maxLength: 120,
                  onChanged: (_) {
                    if (invalid) setState(() => invalid = false);
                  },
                  decoration: InputDecoration(
                    hintText: L10n.tr(context, 'Artist name'),
                  ),
                ),
                if (invalid)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      L10n.tr(context, 'Enter an artist name.'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 10),
                TextField(
                  controller: note,
                  minLines: 2,
                  maxLines: 3,
                  maxLength: 10000,
                  decoration: InputDecoration(
                    hintText: L10n.tr(context, 'Note'),
                  ),
                ),
                const SizedBox(height: 14),
                SegmentedButton<int>(
                  segments: [
                    ButtonSegment<int>(
                      value: 0,
                      label: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(L10n.tr(context, 'Artist')),
                      ),
                    ),
                    ButtonSegment<int>(
                      value: 1,
                      label: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          L10n.tr(
                            context,
                            mode == AppMode.manga ? 'Group' : 'Tag',
                          ),
                        ),
                      ),
                    ),
                  ],
                  selected: {kind},
                  onSelectionChanged: (values) {
                    setState(() => kind = values.first);
                  },
                ),
                if (sources.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  RadioGroup<String>(
                    groupValue: sourceId,
                    onChanged: (value) {
                      if (value != null) setState(() => sourceId = value);
                    },
                    child: Column(
                      children: [
                        for (final source in sources)
                          RadioListTile<String>(
                            value: source.id,
                            title: Text(source.name, maxLines: 2),
                            contentPadding: EdgeInsets.zero,
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(L10n.tr(context, 'Cancel')),
            ),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isEmpty) {
                  setState(() => invalid = true);
                  return;
                }
                Navigator.pop(context, true);
              },
              child: Text(L10n.tr(context, 'Save')),
            ),
          ],
          scrollable: true,
        ),
      ),
    );
    if (accepted == true && context.mounted) {
      _guard(context, () {
        final replacement = ArtistEntry(
          name: name.text.trim(),
          mode: mode,
          sourceId: sourceId,
          kind: kind,
          note: note.text,
        );
        widget.controller.saveArtist(replacement);
        if (artist != null &&
            (artist.name != replacement.name ||
                artist.sourceId != sourceId ||
                artist.kind != kind)) {
          widget.controller.removeArtist(artist);
        }
      });
    }
    name.dispose();
    note.dispose();
  }

  void _guard(BuildContext context, VoidCallback operation) {
    try {
      operation();
    } catch (error) {
      showMessage(context, 'Unable to save', AppController.errorMessage(error));
    }
  }
}

class _ArtistWorksScreen extends StatelessWidget {
  const _ArtistWorksScreen({
    required this.controller,
    required this.artist,
    required this.onOpen,
    required this.onOpenSequence,
  });

  final AppController controller;
  final ArtistEntry artist;
  final ValueChanged<ContentItem> onOpen;
  final void Function(ContentItem, List<ContentItem>)? onOpenSequence;

  bool _matches(ContentItem item) {
    final needle = artist.name.replaceAll(' ', '_').toLowerCase();
    if (artist.kind == 0) {
      return item.artists.any(
        (value) => value.replaceAll(' ', '_').toLowerCase() == needle,
      );
    }
    return item.tags.any((value) {
      final tag = value.toLowerCase();
      return tag == needle || tag == 'group:$needle';
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final items = controller
          .savedItems(mode: artist.mode)
          .where(
            (saved) =>
                (artist.sourceId.isEmpty ||
                    saved.item.sourceId == artist.sourceId) &&
                _matches(saved.item),
          )
          .map((saved) => saved.item)
          .toList();
      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        appBar: AppBar(
          leading: const TegnalBackButton(),
          title: Text(artist.name.replaceAll('_', ' ')),
          backgroundColor: Theme.of(context).colorScheme.surface,
        ),
        body: items.isEmpty
            ? EmptyState(
                icon: Icons.person_search_outlined,
                title: 'No Saved Works',
                message:
                    'Save works from Explore to add them to your collection.',
              )
            : GridView.builder(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 18,
                  crossAxisSpacing: 10,
                  childAspectRatio: .61,
                ),
                itemCount: items.length,
                itemBuilder: (context, index) => ContentTile(
                  item: items[index],
                  saved: true,
                  onTap: () {
                    final sequence = onOpenSequence;
                    if (sequence == null) {
                      onOpen(items[index]);
                    } else {
                      sequence(items[index], items);
                    }
                  },
                ),
              ),
      );
    },
  );
}
