import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/app_controller.dart';
import '../core/content.dart';
import '../data/booru_extras.dart';
import '../ui/content_tile.dart';
import '../ui/l10n.dart';

class BooruPoolsScreen extends StatefulWidget {
  const BooruPoolsScreen({
    super.key,
    required this.controller,
    required this.source,
    required this.onOpen,
    this.onOpenSequence,
  });
  final AppController controller;
  final SourceConfig source;
  final ValueChanged<ContentItem> onOpen;
  final void Function(ContentItem, List<ContentItem>)? onOpenSequence;
  @override
  State<BooruPoolsScreen> createState() => _BooruPoolsScreenState();
}

class _BooruPoolsScreenState extends State<BooruPoolsScreen> {
  late final BooruExtras _extras = BooruExtras(widget.source);
  final TextEditingController _query = TextEditingController();
  final ScrollController _scroll = ScrollController();
  List<BooruPool> _pools = [];
  int _page = 0;
  int _generation = 0;
  bool _loading = false;
  bool _hasMore = false;
  String? _error;

  bool get _idLookup =>
      widget.source.kind == SourceKind.gelbooru ||
      widget.source.kind == SourceKind.oldGelbooru;
  String _t(String key) => L10n.tr(context, key);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 500 && _hasMore && !_loading) {
        unawaited(_load(more: true));
      }
    });
    if (!_idLookup && _extras.supported) unawaited(_load());
  }

  Future<void> _load({bool more = false}) async {
    if (_idLookup || !_extras.supported) return;
    if (more && (_loading || !_hasMore)) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      if (!more) {
        _page = 0;
        _pools = [];
      }
    });
    try {
      final response = await _extras.pools(_query.text, page: _page + 1);
      if (!mounted || generation != _generation) return;
      final ids = _pools.map((pool) => pool.id).toSet();
      _pools = [..._pools, ...response.pools.where((pool) => ids.add(pool.id))];
      _hasMore = response.hasMore;
      _page++;
    } catch (error) {
      if (mounted && generation == _generation) {
        _error = AppController.errorMessage(error);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _submitSearch() async {
    if (_idLookup) {
      final id = int.tryParse(_query.text.trim());
      if (id == null || id < 1) {
        setState(() => _error = _t('Enter a pool ID.'));
        return;
      }
      await _openPool(BooruPool(id: id, name: '#$id'));
    } else {
      await _load();
    }
  }

  Future<void> _openPool(BooruPool pool) => Navigator.push<void>(
    context,
    MaterialPageRoute<void>(
      builder: (_) => _BooruPoolFeedScreen(
        controller: widget.controller,
        source: widget.source,
        pool: pool,
        extras: _extras,
        onOpen: widget.onOpen,
        onOpenSequence: widget.onOpenSequence,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(_t('Pools'))),
    body: SafeArea(
      top: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _query,
                  onSubmitted: (_) => unawaited(_submitSearch()),
                  decoration: InputDecoration(
                    hintText: _t(_idLookup ? 'Pool ID' : 'Search Pools'),
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: IconButton(
                      onPressed: () {
                        _query.clear();
                        unawaited(_load());
                      },
                      icon: const Icon(Icons.close),
                      tooltip: L10n.tr(context, 'Clear'),
                    ),
                  ),
                ),
                if (_idLookup)
                  Padding(
                    padding: const EdgeInsets.only(top: 8, left: 12, right: 12),
                    child: Text(
                      _t('Browse pools or enter a pool ID to open it.'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(child: Text(_error!, textAlign: TextAlign.center)),
                  if (_extras.supported)
                    TextButton(
                      onPressed: () => unawaited(_load()),
                      child: Text(_t('Retry')),
                    ),
                ],
              ),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              itemCount: _pools.length + (_loading ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == _pools.length) {
                  return const Padding(
                    padding: EdgeInsets.all(30),
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 3),
                    ),
                  );
                }
                final pool = _pools[index];
                return ListTile(
                  leading: Icon(
                    Icons.collections_bookmark_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  title: Text(pool.name.replaceAll('_', ' '), maxLines: 2),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '#${pool.id}${pool.postCount == null ? '' : ' · ${pool.postCount} ${_t('posts')}'}',
                      ),
                      if (pool.description.isNotEmpty)
                        Text(
                          pool.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => unawaited(_openPool(pool)),
                );
              },
            ),
          ),
          if (!_loading && _error == null && !_idLookup && _pools.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_t('No results')),
            ),
          if (!_loading && _hasMore && !_idLookup)
            TextButton(
              onPressed: () => unawaited(_load(more: true)),
              child: Text(_t('Load More')),
            ),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    _generation++;
    _extras.close();
    _scroll.dispose();
    _query.dispose();
    super.dispose();
  }
}

class _BooruPoolFeedScreen extends StatefulWidget {
  const _BooruPoolFeedScreen({
    required this.controller,
    required this.source,
    required this.pool,
    required this.extras,
    required this.onOpen,
    this.onOpenSequence,
  });
  final AppController controller;
  final SourceConfig source;
  final BooruPool pool;
  final BooruExtras extras;
  final ValueChanged<ContentItem> onOpen;
  final void Function(ContentItem, List<ContentItem>)? onOpenSequence;

  @override
  State<_BooruPoolFeedScreen> createState() => _BooruPoolFeedScreenState();
}

class _BooruPoolFeedScreenState extends State<_BooruPoolFeedScreen> {
  final ScrollController _scroll = ScrollController();
  List<ContentItem> _posts = [];
  int _page = 0;
  int _generation = 0;
  bool _loading = false;
  bool _hasMore = true;
  String? _error;

  String _t(String key) => L10n.tr(context, key);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 500 && _hasMore && !_loading) {
        unawaited(_load(more: true));
      }
    });
    unawaited(_load());
  }

  Future<void> _load({bool more = false}) async {
    if (more && (_loading || !_hasMore)) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      if (!more) {
        _page = 0;
        _posts = [];
      }
    });
    try {
      final ContentPage response;
      if (widget.extras.supported) {
        response = await widget.extras.poolPosts(
          widget.pool.id,
          page: _page + 1,
        );
      } else {
        final poolTag = widget.source.kind == SourceKind.danbooru
            ? 'ordpool:${widget.pool.id}'
            : 'pool:${widget.pool.id}';
        response = await widget.controller
            .client(widget.source)
            .search(poolTag, page: _page + 1);
      }
      if (!mounted || generation != _generation) return;
      final ids = _posts.map((post) => post.key).toSet();
      _posts = [
        ..._posts,
        ...response.items.where((post) => ids.add(post.key)),
      ];
      _hasMore = response.hasMore;
      _page++;
    } catch (error) {
      if (mounted && generation == _generation) {
        _error = AppController.errorMessage(error);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.pool.name.replaceAll('_', ' '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    body: SafeArea(
      top: false,
      child: Column(
        children: [
          if (widget.pool.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(widget.pool.description),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(_error!, textAlign: TextAlign.center),
                  TextButton(
                    onPressed: () => unawaited(_load(more: _page > 0)),
                    child: Text(_t('Retry')),
                  ),
                ],
              ),
            ),
          Expanded(
            child: CustomScrollView(
              controller: _scroll,
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 220,
                          childAspectRatio: .66,
                          crossAxisSpacing: 14,
                          mainAxisSpacing: 16,
                        ),
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final post = _posts[index];
                      return ContentTile(
                        item: post,
                        saved: widget.controller.isSaved(post),
                        onTap: () => widget.onOpenSequence == null
                            ? widget.onOpen(post)
                            : widget.onOpenSequence!(post, _posts),
                      );
                    }, childCount: _posts.length),
                  ),
                ),
                if (_loading)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(30),
                      child: Center(
                        child: CircularProgressIndicator(strokeWidth: 3),
                      ),
                    ),
                  ),
                if (!_loading && _error == null && _posts.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: Text(_t('No results'))),
                  ),
                if (_hasMore && !_loading)
                  SliverToBoxAdapter(
                    child: Center(
                      child: TextButton(
                        onPressed: () => unawaited(_load(more: true)),
                        child: Text(_t('Load More')),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    _generation++;
    _scroll.dispose();
    super.dispose();
  }
}
