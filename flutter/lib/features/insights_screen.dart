import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/app_controller.dart';
import '../core/content.dart';
import '../core/insights.dart';
import '../ui/session_image.dart';
import '../ui/common.dart';
import '../ui/l10n.dart';
import '../ui/page_header.dart';

/// Local, deterministic summaries: every count comes from saved metadata.
class InsightsScreen extends StatefulWidget {
  const InsightsScreen({
    super.key,
    required this.controller,
    required this.onSearch,
    this.onOpen,
    this.mode,
  });
  final AppController controller;
  final AppMode? mode;
  final void Function(String) onSearch;
  final ValueChanged<ContentItem>? onOpen;
  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  AppMode get _mode => widget.mode ?? widget.controller.mode;
  String _section = 'tags';
  TasteRecommendations? _recommendations;
  AppMode? _recommendationMode;
  bool _fetching = false;
  int _requestGeneration = 0;

  InsightPreferences _preferences(AppMode mode) {
    final stored = widget.controller.store.setting(
      'insights.exclusions.${mode.name}',
    );
    return InsightPreferences(
      mode: mode,
      excludedTags: stored is List ? stored.whereType<String>().toSet() : null,
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final mode = _mode;
      final saved = widget.controller.savedItems(mode: mode);
      final snapshot = TasteAnalyzer.analyze(
        saved,
        mode: mode,
        preferences: _preferences(mode),
      );
      final tags = snapshot.tagCounts;
      final artists = snapshot.artists;
      final types = snapshot.categories;
      final counts = _section == 'artists'
          ? artists
          : _section == 'types'
          ? types
          : tags;
      final ranking = counts.entries.toList()
        ..sort((a, b) {
          final score = b.value.compareTo(a.value);
          return score == 0 ? a.key.compareTo(b.key) : score;
        });
      final totalPages = snapshot.totalPages;
      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: SafeArea(
          child: TegnalFloatingHeader(
            header: TegnalPageHeader(
              controller: widget.controller,
              title: 'Smart',
            ),
            child: saved.isEmpty
                ? const EmptyState(
                    icon: Icons.bar_chart,
                    title: 'Start with something you love',
                    message: 'Save a few works as you explore. Your collection statistics will grow from there.',
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(
                      20,
                      tegnalHeaderExtent + 20,
                      20,
                      navigationScrollInset(context, gap: 20),
                    ),
                    children: [
                      Text(
                        L10n.tr(context, 'Your taste, in numbers'),
                        style: const TextStyle(
                          fontSize: 29,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        L10n.tr(
                          context,
                          'Based on tags in your saved collection.',
                        ),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 22),
                      LayoutBuilder(
                        builder: (context, constraints) => Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            _metric(
                              context,
                              constraints.maxWidth,
                              '${saved.length}',
                              'Saved Works',
                              Icons.bookmark,
                            ),
                            _metric(
                              context,
                              constraints.maxWidth,
                              '${artists.length}',
                              'Artists',
                              Icons.group,
                            ),
                            _metric(
                              context,
                              constraints.maxWidth,
                              '${tags.length}',
                              'Tags',
                              Icons.sell,
                            ),
                            _metric(
                              context,
                              constraints.maxWidth,
                              '$totalPages',
                              'Pages',
                              Icons.copy_all,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      _recap(context, snapshot),
                      const SizedBox(height: 18),
                      _findings(context, snapshot),
                      TextButton(
                        onPressed: () => unawaited(_editExclusions(mode)),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: Text(L10n.tr(context, 'Excluded from analysis')),
                      ),
                      const SizedBox(height: 16),
                      SegmentedButton<String>(
                        segments: [
                          ButtonSegment<String>(
                            value: 'tags',
                            label: Text(L10n.tr(context, 'Tags')),
                          ),
                          ButtonSegment<String>(
                            value: 'artists',
                            label: Text(L10n.tr(context, 'Artists')),
                          ),
                          ButtonSegment<String>(
                            value: 'types',
                            label: Text(L10n.tr(context, 'Categories')),
                          ),
                        ],
                        selected: {_section},
                        onSelectionChanged: (values) {
                          setState(() => _section = values.first);
                        },
                      ),
                      const SizedBox(height: 18),
                      if (ranking.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(18),
                          child: Text(
                            L10n.tr(
                              context,
                              'No metadata in this category yet.',
                            ),
                            textAlign: TextAlign.center,
                          ),
                        )
                      else
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerLow,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Column(
                            children: [
                              for (final entry in ranking.take(30))
                                _ranking(context, entry, saved.length),
                            ],
                          ),
                        ),
                      const SizedBox(height: 18),
                      Text(
                        L10n.tr(
                          context,
                          'Each work counts once per tag. Tap a row to search your selected source.',
                        ),
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 24),
                      _recommendationSection(context, snapshot),
                      const SizedBox(height: 24),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerLow,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                L10n.tr(context, 'Local collection statistics'),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 7),
                              Text(
                                L10n.tr(
                                  context,
                                  'Calculated on this device from saved metadata. No model or library upload is required.',
                                ),
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.5,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      );
    },
  );

  Future<void> _editExclusions(AppMode mode) async {
    final text = TextEditingController(
      text: (_preferences(mode).excludedTags.toList()..sort()).join('\n'),
    );
    try {
      final value = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(L10n.tr(context, 'Excluded from analysis')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Text(
                L10n.tr(
                  context,
                  'One tag per line. These tags are omitted from insights and recommendation scoring. Source blacklists still control which works appear.',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: text,
                minLines: 4,
                maxLines: 8,
                autocorrect: false,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(L10n.tr(context, 'Cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, text.text),
              child: Text(L10n.tr(context, 'Save')),
            ),
          ],
          scrollable: true,
        ),
      );
      if (value != null && mounted) {
        _requestGeneration++;
        setState(() {
          _recommendations = null;
          _fetching = false;
        });
        widget.controller.setPreference(
          'insights.exclusions.${mode.name}',
          value
              .split(RegExp(r'[\r\n]+'))
              .map(InsightPreferences.normalize)
              .where((tag) => tag.isNotEmpty)
              .toSet()
              .toList()
            ..sort(),
        );
      }
    } finally {
      // Dialog route disposal follows its exit animation.
      Future<void>.delayed(const Duration(milliseconds: 400), text.dispose);
    }
  }

  Future<void> _fetchRecommendations(TasteSnapshot snapshot) async {
    final generation = ++_requestGeneration;
    final mode = snapshot.mode;
    setState(() {
      _fetching = true;
      _recommendationMode = mode;
      _recommendations = null;
    });
    final sources = widget.controller.selectedSources(mode);
    final service = RecommendationService(
      load: (source, query) => widget.controller.client(source).search(query),
    );
    final result = await service.fetch(
      snapshot: snapshot,
      sources: sources,
      blacklists: {
        for (final source in sources)
          source.id: widget.controller.store.setting(
            'blacklist.${source.id}',
            '',
          ) as String,
      },
      currentSavedKeys: () => widget.controller
          .savedItems(mode: mode)
          .map((entry) => entry.item.key)
          .toSet(),
      cancelled: () =>
          !mounted ||
          generation != _requestGeneration ||
          widget.controller.mode != mode,
    );
    if (mounted && generation == _requestGeneration) {
      setState(() {
        _fetching = false;
        if (widget.controller.mode == mode) _recommendations = result;
      });
    }
  }

  Widget _panel(BuildContext context, List<Widget> children) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    ),
  );

  Widget _recap(
    BuildContext context,
    TasteSnapshot snapshot,
  ) => _panel(context, [
    Text(
      L10n.tr(context, 'Recent saves'),
      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
    ),
    const SizedBox(height: 12),
    for (final recap in [snapshot.weekly, snapshot.monthly])
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Expanded(
              child: Text(
                L10n.tr(
                  context,
                  recap.days == 7 ? 'Past 7 days' : 'Past 30 days',
                ),
              ),
            ),
            Text(
              '${recap.saves} · ${recap.change >= 0 ? '+' : ''}${recap.change}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    const SizedBox(height: 9),
    Text(
      L10n.tr(
        context,
        'Change compares the previous equal period. Recaps use save dates of works still in your library; removed works and reading time are not tracked.',
      ),
      style: TextStyle(
        fontSize: 12,
        height: 1.4,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  ]);

  Widget _findings(
    BuildContext context,
    TasteSnapshot snapshot,
  ) => _panel(context, [
    Text(
      L10n.tr(context, 'Collection patterns'),
      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
    ),
    const SizedBox(height: 8),
    if (snapshot.findings.isEmpty)
      Text(
        L10n.tr(
          context,
          'Save works with tag metadata to build your local profile.',
        ),
      ),
    for (final finding in snapshot.findings)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              finding.tag.name.replaceAll('_', ' '),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              switch (finding.pattern) {
                InsightPattern.frequent =>
                  '${finding.count} ${L10n.tr(context, 'saved works include this tag.')}',
                InsightPattern.rising =>
                  '${finding.count} ${L10n.tr(context, 'saves in the past 30 days, compared with')} ${finding.previousCount} ${L10n.tr(context, 'in the previous period.')}',
                InsightPattern.association =>
                  '${finding.count} ${L10n.tr(context, 'saved works pair this tag with')} ${finding.related!.name.replaceAll('_', ' ')}.',
              },
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              widget.controller.sourceById(finding.tag.sourceId)?.name ??
                  L10n.tr(context, 'Disconnected source'),
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
  ]);

  Widget _recommendationSection(BuildContext context, TasteSnapshot snapshot) {
    final sources = widget.controller.selectedSources(snapshot.mode);
    final ready = sources.any(
      (source) => snapshot.tags.any((tag) => tag.sourceId == source.id),
    );
    final result = _recommendationMode == snapshot.mode
        ? _recommendations
        : null;
    final fetching = _recommendationMode == snapshot.mode && _fetching;
    final items =
        result?.items
            .where((entry) => !widget.controller.isSaved(entry.item))
            .toList() ??
        <TasteRecommendation>[];
    return _panel(context, [
      Text(
        L10n.tr(context, 'Recommendations'),
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
      ),
      const SizedBox(height: 8),
      Text(
        L10n.tr(
          context,
          'Fetch candidates from your selected sources using frequent eligible tags, then rank them on this device. Saved works and source blacklists are excluded.',
        ),
        style: TextStyle(
          fontSize: 13,
          height: 1.5,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      if (!ready)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            L10n.tr(
              context,
              'Connect a source with saved tag metadata to fetch recommendations.',
            ),
          ),
        )
      else if (fetching)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator(strokeWidth: 3)),
        )
      else
        TextButton(
          onPressed: () => unawaited(_fetchRecommendations(snapshot)),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          child: Text(L10n.tr(context, 'Fetch recommendations')),
        ),
      if (result != null) ...[
        Text(
          '${result.requestCount} ${L10n.tr(context, 'source requests completed. Ranked locally without AI.')}',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(
              L10n.tr(
                context,
                'No matching unsaved works were found in this bounded fetch.',
              ),
            ),
          ),
        for (final failure in result.failures)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              '${widget.controller.sourceById(failure.sourceId)?.name ?? failure.sourceId}: ${failure.message}',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.tertiary,
              ),
            ),
          ),
        if (result.skippedUnscored > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${result.skippedUnscored} ${L10n.tr(context, 'candidates lacked matching tag metadata and were skipped.')}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        if (result.omittedSources > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${result.omittedSources} ${L10n.tr(context, 'sources were outside this fetch’s six-request budget.')}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        for (final entry in items)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: TextButton(
              onPressed: () {
                if (widget.onOpen != null) {
                  widget.onOpen!(entry.item);
                } else {
                  widget.onSearch(entry.reason.name);
                }
              },
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: entry.item.thumbnailUrl == null
                        ? const SizedBox(
                            width: 65,
                            height: 88,
                            child: Icon(Icons.image_outlined),
                          )
                        : SessionImage(
                            url: entry.item.thumbnailUrl!,
                            referer: entry.item.pageUrl,
                            width: 65,
                            height: 88,
                            fit: BoxFit.cover,
                          ),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${L10n.tr(context, 'Matches')}: ${entry.reason.name.replaceAll('_', ' ')}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 22),
                ],
              ),
            ),
          ),
      ],
    ]);
  }

  @override
  void dispose() {
    _requestGeneration++;
    super.dispose();
  }

  Widget _metric(
    BuildContext context,
    double width,
    String value,
    String label,
    IconData icon,
  ) => SizedBox(
    width: width > 700 ? (width - 36) / 4 : (width - 12) / 2,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary, size: 28),
            const SizedBox(height: 14),
            Text(
              value,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              L10n.tr(context, label),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _ranking(
    BuildContext context,
    MapEntry<String, int> entry,
    int total,
  ) {
    final fraction = total == 0 ? 0.0 : entry.value / total;
    return TextButton(
      onPressed: () {
        var query = entry.key.replaceAll(' ', '_');
        if (_section == 'artists' && _mode == AppMode.manga) {
          query = 'artist:$query';
        }
        widget.onSearch(query);
      },
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  entry.key.replaceAll('_', ' '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${entry.value} · ${(fraction * 100).round()}%',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right, size: 20),
            ],
          ),
          const SizedBox(height: 9),
          LayoutBuilder(
            builder: (context, constraints) => Align(
              alignment: Alignment.centerLeft,
              child: Container(
                height: 4,
                width: constraints.maxWidth * fraction.clamp(0, 1),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary
                      .withValues(alpha: .65),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
