import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../core/app_controller.dart';
import '../core/content.dart';
import '../core/library.dart';
import '../ui/content_tile.dart';
import '../ui/l10n.dart';
import '../ui/page_header.dart';
import '../ui/source_picker.dart';
import '../ui/native_symbols.dart';
import '../ui/common.dart';
import 'browser_screen.dart';

class ExploreScreen extends StatefulWidget {
  const ExploreScreen({
    super.key,
    required this.controller,
    required this.mode,
    required this.onOpen,
    required this.onConnect,
    this.onOpenSequence,
  });
  final AppController controller;
  final AppMode mode;
  final void Function(ContentItem) onOpen;
  final VoidCallback onConnect;
  final void Function(ContentItem, List<ContentItem>)? onOpenSequence;
  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  late final TextEditingController _query = TextEditingController(
    text: widget.controller.explore(widget.mode).query,
  );
  final ScrollController _scroll = ScrollController();
  final FocusNode _queryFocus = FocusNode();
  Timer? _debounce;
  List<String> _suggestions = [];
  int _completion = 0;
  late String _lastSearchQuery = widget.controller.explore(widget.mode).query;
  @override
  void didUpdateWidget(ExploreScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final query = widget.controller.explore(widget.mode).query;
    if (query != _lastSearchQuery) {
      _lastSearchQuery = query;
      if (_query.text != query) {
        _query.value = TextEditingValue(
          text: query,
          selection: TextSelection.collapsed(offset: query.length),
        );
      }
      _completion++;
      _suggestions = [];
    }
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _queryFocus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (_queryFocus.hasFocus) setState(() {});
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter < 700) {
      widget.controller.search(more: true, forMode: widget.mode);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _queryFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _search([String? text]) {
    _debounce?.cancel();
    _completion++;
    if (text != null) {
      _query.text = text;
    }
    setState(() => _suggestions = []);
    FocusScope.of(context).unfocus();
    widget.controller.search(query: _query.text, forMode: widget.mode);
  }

  void _insertSuggestion(String suggestion) {
    final value = _query.text;
    final selection = _query.selection;
    final cursor = selection.isValid ? selection.extentOffset : value.length;
    var start = cursor;
    while (start > 0 && !RegExp(r'\s').hasMatch(value[start - 1])) {
      start--;
    }
    var end = cursor;
    while (end < value.length && !RegExp(r'\s').hasMatch(value[end])) {
      end++;
    }
    final current = value.substring(start, end);
    final negative = current.startsWith('-');
    final replacement = '${negative ? '-' : ''}$suggestion ';
    final next = value.replaceRange(start, end, replacement);
    final caret = start + replacement.length;
    _query.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: caret),
    );
    _debounce?.cancel();
    _completion++;
    setState(() => _suggestions = []);
    _queryFocus.requestFocus();
  }

  List<SearchEntry> get _visibleHistory {
    final selected = widget.controller
        .selectedSources(widget.mode)
        .map((source) => source.id)
        .toSet();
    final seen = <String>{};
    return widget.controller
        .history(widget.mode)
        .where((entry) => selected.contains(entry.sourceId))
        .where((entry) => seen.add(entry.query))
        .toList();
  }

  List<SearchEntry> get _savedSearches {
    if (widget.mode == AppMode.manga) {
      final saved =
          widget.controller.store.portable('backup.comics')?['saved_searches']
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
    final selected = widget.controller
        .selectedSources(widget.mode)
        .map((source) => source.id)
        .toSet();
    final records =
        widget.controller.store.portable('backup.images')?['savedTags']
            as List? ??
        [];
    return [
      for (final record in records.whereType<Map>())
        if (record['kind'] == 'search' &&
            record['name'] is String &&
            record['serverID'] is String &&
            selected.contains(record['serverID']))
          SearchEntry(
            AppMode.booru,
            record['serverID'] as String,
            record['name'] as String,
            DateTime.fromMillisecondsSinceEpoch(0),
          ),
    ];
  }

  bool _isSearchSaved(String query) =>
      _savedSearches.any((entry) => entry.query == query);

  void _toggleSavedSearch(String query) {
    if (widget.mode == AppMode.manga) {
      final data =
          widget.controller.store.portable('backup.comics') ??
          <String, dynamic>{};
      final records = (data['saved_searches'] as List? ?? [])
          .whereType<String>()
          .toSet();
      records.contains(query) ? records.remove(query) : records.add(query);
      data['saved_searches'] = records.toList();
      widget.controller.store.setPortable('backup.comics', data);
      widget.controller.changed();
      setState(() {});
      return;
    }
    final selected = widget.controller.selectedSources(widget.mode);
    final data =
        widget.controller.store.portable('backup.images') ??
        <String, dynamic>{};
    final records = (data['savedTags'] as List? ?? []).toList();
    final matches = records.where(
      (value) =>
          value is Map && value['kind'] == 'search' && value['name'] == query,
    );
    final allSaved =
        selected.isNotEmpty &&
        selected.every(
          (source) => matches.any(
            (value) => value is Map && value['serverID'] == source.id,
          ),
        );
    if (allSaved) {
      records.removeWhere(
        (value) =>
            value is Map &&
            value['kind'] == 'search' &&
            value['name'] == query &&
            selected.any((source) => source.id == value['serverID']),
      );
    } else {
      for (final source in selected) {
        if (!matches.any(
          (value) => value is Map && value['serverID'] == source.id,
        )) {
          records.add({'serverID': source.id, 'kind': 'search', 'name': query});
        }
      }
    }
    data['savedTags'] = records;
    widget.controller.store.setPortable('backup.images', data);
    widget.controller.changed();
    setState(() {});
  }

  void _removeSearch(SearchEntry entry) {
    for (final source in widget.controller.selectedSources(widget.mode)) {
      widget.controller.store.database.execute(
        'DELETE FROM history WHERE mode=? AND source_id=? AND query=?',
        [entry.mode.name, source.id, entry.query],
      );
    }
    widget.controller.changed();
    setState(() {});
  }

  Future<void> _clearHistory() async {
    if (await confirmAction(
      context,
      'Clear History?',
      'Search history will be deleted. Saved searches will be kept.',
      action: 'Clear History',
    )) {
      if (mounted) {
        for (final source in widget.controller.selectedSources(widget.mode)) {
          widget.controller.store.database.execute(
            'DELETE FROM history WHERE mode=? AND source_id=?',
            [widget.mode.name, source.id],
          );
        }
        widget.controller.changed();
        setState(() {});
      }
    }
  }

  Widget _historyPanel() {
    final history = _visibleHistory;
    final savedOnly = _savedSearches
        .where((entry) => !history.any((item) => item.query == entry.query))
        .toList();
    final entries = [...history, ...savedOnly];
    if (entries.isEmpty) return const SizedBox.shrink();
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 260,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      L10n.tr(context, 'Search History'),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    onPressed: history.isEmpty ? null : _clearHistory,
                    tooltip: L10n.tr(context, 'Clear History'),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final key = ValueKey('${entry.sourceId}:${entry.query}');
                  return Dismissible(
                    key: key,
                    direction: history.contains(entry)
                        ? DismissDirection.endToStart
                        : DismissDirection.none,
                    onDismissed: (_) => _removeSearch(entry),
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Icon(
                        Icons.delete_outline,
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                    child: ListTile(
                      dense: true,
                      leading: Icon(
                        history.contains(entry) ? Icons.history : Icons.star,
                      ),
                      title: Text(
                        entry.query,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        _query.text = entry.query;
                        _search();
                      },
                      trailing: IconButton(
                        tooltip: L10n.tr(context, 'Saved Searches'),
                        onPressed: () => _toggleSavedSearch(entry.query),
                        icon: Icon(
                          _isSearchSaved(entry.query)
                              ? Icons.star
                              : Icons.star_border,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _suggestionPanel() {
    if (_query.text.trim().isEmpty) return _historyPanel();
    if (_suggestions.isEmpty) return const SizedBox.shrink();
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 280),
        child: ListView.separated(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: _suggestions.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) => ListTile(
            dense: true,
            leading: const Icon(Icons.tag),
            title: Text(_suggestions[index]),
            onTap: () => _insertSuggestion(_suggestions[index]),
          ),
        ),
      ),
    );
  }

  Widget _searchField() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      TextField(
        key: const ValueKey('explore.search'),
        controller: _query,
        focusNode: _queryFocus,
        onChanged: _complete,
        onSubmitted: _search,
        decoration: InputDecoration(
          hintText: L10n.tr(
            context,
            widget.mode == AppMode.booru ? 'Search Tags' : 'Search',
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
          suffixIcon: IconButton(
            onPressed: () {
              _query.clear();
              _queryFocus.requestFocus();
              _complete('');
            },
            icon: const Icon(Icons.close),
            tooltip: L10n.tr(context, 'Clear'),
          ),
        ),
      ),
      if (_queryFocus.hasFocus)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: _suggestionPanel(),
        ),
    ],
  );

  void _complete(String text) {
    _debounce?.cancel();
    final token = ++_completion;
    if (text.trim().length < 2) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final result = await widget.controller.suggestions(
          text,
          mode: widget.mode,
        );
        if (mounted && token == _completion) {
          setState(() => _suggestions = result.take(6).toList());
        }
      } catch (_) {
        if (mounted && token == _completion) {
          setState(() => _suggestions = []);
        }
      }
    });
  }

  Future<void> _chooseSource() async {
    if (widget.mode == AppMode.booru) {
      final applied = await showBooruSourcePicker(context, widget.controller);
      if (applied && mounted) _search();
      return;
    }
    final source = await showModalBottomSheet<SourceConfig>(
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
                  child: Text(L10n.tr(context, 'Servers')),
                ),
              ),
              ...[
                for (final s in widget.controller.sources(widget.mode))
                  ListTile(
                    title: Text(s.name),
                    onTap: () => Navigator.pop(context, s),
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
    if (source != null) {
      widget.controller.selectSource(source);
      _search();
    }
  }

  Future<void> _itemActions(ContentItem item) async {
    await showModalBottomSheet<void>(
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
                  child: Text(item.title),
                ),
              ),
              ...[
                ListTile(
                  title: Text(L10n.tr(context, 'Open')),
                  onTap: () {
                    Navigator.pop(context);
                    if (widget.mode == AppMode.booru &&
                        widget.onOpenSequence != null) {
                      widget.onOpenSequence!(
                        item,
                        widget.controller.explore(widget.mode).items,
                      );
                    } else {
                      widget.onOpen(item);
                    }
                  },
                ),
                ListTile(
                  title: Text(
                    L10n.tr(
                      context,
                      widget.controller.isSaved(item)
                          ? 'Remove Bookmark'
                          : 'Save',
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    widget.controller.isSaved(item)
                        ? widget.controller.unsave(item)
                        : widget.controller.save(item);
                  },
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
  }

  void _toggleBookmark(ContentItem item) {
    final removing = widget.controller.isSaved(item);
    if (removing) {
      widget.controller.unsave(item);
    } else {
      widget.controller.save(item);
    }
    HapticFeedback.selectionClick();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            L10n.tr(context, removing ? 'Remove from Saved' : 'Saved'),
          ),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final state = controller.explore(widget.mode);
    final configuredSources = controller.sources(widget.mode);
    final selectedSources = controller.selectedSources(widget.mode);
    final source = selectedSources.firstOrNull;
    final sortTitle = widget.mode == AppMode.booru
        ? (BooruSort.supportedBy(selectedSources).contains(state.booruSort)
              ? state.booruSort.title
              : BooruSort.latest.title)
        : state.popular
        ? 'Popular'
        : 'Latest';
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: TegnalFloatingHeader(
        header: TegnalPageHeader(
          controller: controller,
          title: 'Explore',
          trailing: IconButton(
            onPressed: configuredSources.isEmpty
                ? widget.onConnect
                : _chooseSource,
            style: IconButton.styleFrom(padding: const EdgeInsets.all(8)),
            icon: TegnalServerIcon(
              size: 30,
              semanticLabel: L10n.tr(context, 'Servers'),
            ),
          ),
        ),
        searchFocusNode: _queryFocus,
        search:
            configuredSources.isEmpty ||
                (widget.mode == AppMode.booru && selectedSources.isEmpty)
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _searchField(),
              ),
        child: configuredSources.isEmpty
            ? EmptyState(
                icon: Icons.language,
                title: 'Connect a Website',
                message: 'Enter the website address you want to use to start browsing.',
                action: FilledButton(
                  onPressed: widget.onConnect,
                  child: Text(L10n.tr(context, 'Enter Website Address')),
                ),
              )
            : widget.mode == AppMode.booru && selectedSources.isEmpty
            ? EmptyState(
                icon: Icons.dns_outlined,
                title: 'No servers selected',
                message: 'Choose servers using the server button above.',
                action: OutlinedButton(
                  onPressed: _chooseSource,
                  child: Text(L10n.tr(context, 'Servers')),
                ),
              )
            : Stack(
                children: [
                  Scrollbar(
                    controller: _scroll,
                    child: RefreshIndicator(
                      onRefresh: () => controller.search(forMode: widget.mode),
                      child: CustomScrollView(
                        controller: _scroll,
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          const SliverToBoxAdapter(
                            child: SizedBox(height: tegnalHeaderExtent + 70),
                          ),
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(16, 6, 16, 20),
                            sliver: SliverToBoxAdapter(
                              child: Column(
                                children: [
                                  const SizedBox(height: 16),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextButton(
                                          onPressed: _chooseSource,
                                          style: TextButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 4,
                                              vertical: 8,
                                            ),
                                            alignment: Alignment.centerLeft,
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  controller
                                                              .selectedSources(
                                                                widget.mode,
                                                              )
                                                              .length >
                                                          1
                                                      ? '${controller.selectedSources(widget.mode).length} ${L10n.tr(context, 'Servers')}'
                                                      : source!.name,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onSurfaceVariant,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 4),
                                              Icon(
                                                Icons.expand_more,
                                                size: 18,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: _chooseSort,
                                        style: TextButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 10,
                                          ),
                                          backgroundColor: Theme.of(context)
                                              .colorScheme
                                              .primary
                                              .withValues(alpha: .09),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              24,
                                            ),
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.swap_vert,
                                              size: 24,
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              L10n.tr(context, sortTitle),
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
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
                          ),
                          if (state.error != null)
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  24,
                                  8,
                                  24,
                                  16,
                                ),
                                child: Column(
                                  children: [
                                    Text(
                                      state.error!,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error,
                                      ),
                                    ),
                                    Wrap(
                                      alignment: WrapAlignment.center,
                                      children: [
                                        TextButton(
                                          onPressed: () => controller.search(
                                            more: state.page > 0,
                                            forMode: widget.mode,
                                          ),
                                          child: Text(
                                            L10n.tr(context, 'Retry'),
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: () async {
                                            await Navigator.push(
                                              context,
                                              MaterialPageRoute<void>(
                                                builder: (_) => BrowserScreen(
                                                  url: source!.baseUrl,
                                                ),
                                              ),
                                            );
                                            if (mounted) _search();
                                          },
                                          child: Text(
                                            L10n.tr(context, 'Validate Client'),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          if (state.items.isEmpty &&
                              !state.loading &&
                              state.error == null)
                            SliverFillRemaining(
                              hasScrollBody: false,
                              child: state.page == 0
                                  ? EmptyState(
                                      icon: Icons.language,
                                      title: 'Explore',
                                      action: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          FilledButton(
                                            onPressed: () => _search(),
                                            child: Text(
                                              L10n.tr(context, 'Browse'),
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                  : const EmptyState(
                                      icon: Icons.search,
                                      title: 'No Results',
                                      message: 'Try a different search.',
                                    ),
                            ),
                          SliverPadding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            sliver: SliverLayoutBuilder(
                              builder: (context, constraints) =>
                                  SliverGrid.builder(
                                    gridDelegate:
                                        SliverGridDelegateWithFixedCrossAxisCount(
                                          crossAxisCount:
                                              widget.mode == AppMode.booru
                                              ? (constraints.crossAxisExtent /
                                                        170)
                                                    .floor()
                                                    .clamp(3, 8)
                                              : (constraints.crossAxisExtent /
                                                        185)
                                                    .floor()
                                                    .clamp(2, 7),
                                          mainAxisSpacing:
                                              widget.mode == AppMode.booru
                                              ? 10
                                              : 18,
                                          crossAxisSpacing: 10,
                                          childAspectRatio:
                                              widget.mode == AppMode.manga
                                              ? .61
                                              : .78,
                                        ),
                                    itemCount: state.items.length,
                                    itemBuilder: (context, index) {
                                      final item = state.items[index];
                                      return ContentTile(
                                        item: item,
                                        saved: controller.isSaved(item),
                                        onTap: () =>
                                            widget.mode != AppMode.booru ||
                                                widget.onOpenSequence == null
                                            ? widget.onOpen(item)
                                            : widget.onOpenSequence!(
                                                item,
                                                state.items,
                                              ),
                                        onLongPress: () =>
                                            _toggleBookmark(item),
                                        onSecondaryTap: () =>
                                            _itemActions(item),
                                        onMore: () => _itemActions(item),
                                      );
                                    },
                                  ),
                            ),
                          ),
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(
                                24,
                                24,
                                24,
                                navigationScrollInset(context, gap: 24),
                              ),
                              child: Center(
                                child: state.loading
                                    ? const CircularProgressIndicator(
                                        strokeWidth: 3,
                                      )
                                    : state.hasMore
                                    ? TextButton(
                                        onPressed: () => controller.search(
                                          more: true,
                                          forMode: widget.mode,
                                        ),
                                        child: Text(
                                          L10n.tr(context, 'Load More'),
                                        ),
                                      )
                                    : const SizedBox(height: 16),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Future<void> _chooseSort() async {
    if (widget.mode == AppMode.booru) {
      final options = BooruSort.supportedBy(
        widget.controller.selectedSources(widget.mode),
      );
      final value = await showModalBottomSheet<BooruSort>(
        context: context,
        useRootNavigator: true,
        builder: (context) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final option in options)
                  ListTile(
                    title: Text(L10n.tr(context, option.title)),
                    selected:
                        option ==
                        widget.controller.explore(widget.mode).booruSort,
                    onTap: () => Navigator.pop(context, option),
                  ),
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
      if (value != null && mounted) {
        widget.controller.search(
          query: _query.text,
          booruSort: value,
          forMode: widget.mode,
        );
      }
      return;
    }
    final value = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ...[
                for (final option in [false, true])
                  ListTile(
                    title: Text(
                      L10n.tr(context, option ? 'Popular' : 'Latest'),
                    ),
                    onTap: () => Navigator.pop(context, option),
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
    if (value != null && mounted) {
      widget.controller.search(
        query: _query.text,
        popular: value,
        forMode: widget.mode,
      );
    }
  }
}
