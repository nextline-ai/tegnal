import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/app_controller.dart';
import '../core/content.dart';
import '../core/recap.dart';
import '../data/backup_files.dart';
import '../ui/common.dart';
import '../ui/l10n.dart';
import '../ui/recap_palette.dart';
import '../ui/session_image.dart';

String _t(
  BuildContext context,
  String key, [
  List<String> arguments = const [],
]) {
  var text = L10n.tr(context, key);
  for (final (index, value) in arguments.indexed) {
    text = text.replaceAll('%${index + 1}\$@', value).replaceFirst('%@', value);
  }
  return text.replaceAll('%%', '%');
}

String _line(BuildContext context, RecapLine line) =>
    _t(context, line.key, line.arguments);

const _serifFallback = [
  'Noto Serif',
  'Noto Serif CJK KR',
  'Georgia',
  'Times New Roman',
];
TextStyle _display(
  double size, {
  FontWeight weight = FontWeight.w900,
  Color? color,
}) => TextStyle(
  fontFamily: 'serif',
  fontFamilyFallback: _serifFallback,
  fontSize: size,
  fontWeight: weight,
  height: 1.05,
  color: color,
);
TextStyle _folio(double size, {Color? color}) => TextStyle(
  fontFamily: 'monospace',
  fontSize: size,
  fontWeight: FontWeight.w600,
  letterSpacing: 1.2,
  color: color,
);

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
String _monthName(BuildContext context, DateTime date) {
  final language = Localizations.localeOf(context).languageCode;
  return language == 'en'
      ? _months[date.month - 1]
      : (language == 'ko' ? '${date.month}월' : '${date.month}月');
}

String _dayName(BuildContext context, DateTime date) {
  final language = Localizations.localeOf(context).languageCode;
  if (language == 'en') return '${_months[date.month - 1]} ${date.day}';
  return language == 'ko'
      ? '${date.month}월 ${date.day}일'
      : '${date.month}月${date.day}日';
}

String _periodTitle(BuildContext context, Recap recap) {
  final language = Localizations.localeOf(context).languageCode;
  final start = recap.start;
  return switch (recap.period) {
    RecapPeriod.year => '${start.year}',
    RecapPeriod.week =>
      '${_dayName(context, start)} – ${_dayName(context, recap.end.subtract(const Duration(days: 1)))}',
    RecapPeriod.month =>
      language == 'en'
          ? '${_months[start.month - 1]} ${start.year}'
          : (language == 'ko'
                ? '${start.year}년 ${start.month}월'
                : '${start.year}年${start.month}月'),
  };
}

String _duration(BuildContext context, int seconds) {
  final minutes = (seconds / 60).round();
  if (minutes >= 60) {
    return minutes % 60 == 0
        ? _t(context, '%@ hr', ['${minutes ~/ 60}'])
        : _t(context, '%@ hr %@ min', ['${minutes ~/ 60}', '${minutes % 60}']);
  }
  return _t(context, '%@ min', ['${math.max(1, minutes)}']);
}

String _personaTitle(BuildContext context, RecapPersona persona) =>
    _t(context, '%@ %@', [
      _t(context, 'persona.rhythm.${persona.rhythm.name}'),
      _t(context, 'persona.style.${persona.style.name}'),
    ]);

/// Everything the recap surfaces read for one mode.
class RecapShelf extends ChangeNotifier {
  RecapShelf(this.controller, this.mode) {
    reload();
  }
  final AppController controller;
  final AppMode mode;
  List<Recap> issues = const [];
  Recap? week;
  Recap? year;
  Recap? sample;
  RecapIndex? _index;
  final Map<String, RecapPalette> _palettes = {};
  bool _disposed = false;

  Recap? get latest {
    for (final issue in issues) {
      if (issue.isComplete) return issue;
    }
    return issues.isEmpty ? null : issues.first;
  }

  List<Recap> get pastIssues =>
      issues.where((issue) => issue.id != latest?.id).toList();

  void reload() {
    final taste = controller.taste;
    final index = RecapIndex(
      taste.recapEvents(mode),
      mode: mode,
      preferences: taste.preferences(mode),
      library: {
        for (final saved in controller.savedItems(mode: mode))
          saved.item.key: saved,
      },
    );
    _index = index;
    final now = DateTime.now();
    issues = index.issues(now: now);
    week = index.recap(RecapPeriod.week, 0, now: now);
    final thisYear = index.yearly(0, now: now);
    final lastYear = index.yearly(-1, now: now);
    year = thisYear.saves >= 3
        ? thisYear
        : (lastYear.saves >= 3 ? lastYear : null);
    sample = issues.isEmpty ? recapSample(mode, now: now) : null;
    notifyListeners();
    unawaited(_measureAll());
  }

  /// The full issue, including matches from the wider library.
  Recap opened(Recap recap) {
    if (recap.period != RecapPeriod.month || recap.isSample) return recap;
    final full = _index?.recap(RecapPeriod.month, recap.offset);
    return full == null ? recap : (full..issue = recap.issue);
  }

  RecapPalette palette(Recap recap) {
    final known = _palettes[recap.id];
    if (known != null) return known;
    final stored = RecapPalette.fromJson(
      controller.store.setting('recap.palette.${recap.id}'),
    );
    if (stored != null) return _palettes[recap.id] = stored;
    return RecapPalette.seeded(
      recap.tags.isEmpty ? recap.id : recap.tags.first.name,
    );
  }

  Future<void> _measureAll() async {
    for (final recap in [?latest, ?year, ?week, ...pastIssues.take(8)]) {
      if (_disposed) return;
      await _measure(recap);
    }
  }

  /// Measured once from the covers. Open periods re-measure as they change.
  Future<void> _measure(Recap recap) async {
    if (_palettes.containsKey(recap.id) && recap.isComplete) return;
    final pixels = <Color>[];
    for (final work in recap.saved.take(12)) {
      final url = work.item.thumbnailUrl;
      if (url == null || _disposed) continue;
      try {
        pixels.addAll(
          await RecapPalette.pixels(url, {
            if (work.item.pageUrl != null) 'Referer': '${work.item.pageUrl}',
          }).timeout(const Duration(seconds: 6)),
        );
      } on Exception {
        continue;
      }
    }
    final palette = RecapPalette.extract(pixels);
    if (palette == null || _disposed) return;
    _palettes[recap.id] = palette;
    if (recap.isComplete) {
      controller.store.setSetting(
        'recap.palette.${recap.id}',
        palette.toJson(),
      );
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class RecapArt extends StatelessWidget {
  const RecapArt({
    super.key,
    required this.work,
    required this.palette,
    required this.private,
    this.sample = false,
    this.seed = 3,
  });
  final RecapWork? work;
  final RecapPalette palette;
  final bool private;
  final bool sample;
  final int seed;
  @override
  Widget build(BuildContext context) {
    final item = work?.item;
    final id = item?.key.hashCode.abs() ?? 0;
    if (private) return RecapColorField(palette: palette, seed: seed + id);
    if (sample) return RecapGeneratedArt(seed: seed + id % 997);
    final url = item?.thumbnailUrl;
    if (url == null) return RecapColorField(palette: palette, seed: seed + id);
    return ExcludeSemantics(
      child: SessionImage(
        url: url,
        referer: item?.pageUrl,
        errorBuilder: (_, _, _) =>
            RecapColorField(palette: palette, seed: seed + id),
      ),
    );
  }
}

/// A printed cover: masthead over artwork, with facts set like coverlines.
class RecapCover extends StatelessWidget {
  const RecapCover({
    super.key,
    required this.recap,
    required this.palette,
    required this.background,
    this.showsTags = true,
    this.note,
    this.padding = EdgeInsets.zero,
  });
  final Recap recap;
  final RecapPalette palette;
  final Widget background;
  final bool showsTags;
  final String? note;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final persona = recap.persona;
      return Stack(
        fit: StackFit.expand,
        children: [
          background,
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0, .34, .46, 1],
                colors: [
                  palette.ink.withValues(alpha: .78),
                  palette.ink.withValues(alpha: 0),
                  palette.ink.withValues(alpha: 0),
                  palette.ink.withValues(alpha: .94),
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.all(width * .058).add(padding),
            child: DefaultTextStyle.merge(
              style: const TextStyle(color: Colors.white),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'RECAP',
                      style: _display(width * .25, color: Colors.white),
                    ),
                  ),
                  Divider(
                    height: width * .03,
                    thickness: 1,
                    color: Colors.white70,
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        recap.isSample
                            ? _t(context, 'Sample issue')
                            : _t(context, 'No. %@', ['${recap.issue}']),
                        style: _folio(width * .028),
                      ),
                      Flexible(
                        child: Text(
                          _periodTitle(context, recap),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _folio(width * .028),
                        ),
                      ),
                      Text(
                        _t(
                          context,
                          recap.mode == AppMode.booru ? 'Images' : 'Comics',
                        ),
                        style: _folio(width * .028),
                      ),
                    ],
                  ),
                  const Spacer(),
                  if (note != null) ...[
                    Text(
                      note!,
                      style: _display(
                        width * .042,
                        weight: FontWeight.w500,
                      ).copyWith(fontStyle: FontStyle.italic, height: 1.25),
                    ),
                    SizedBox(height: width * .03),
                  ],
                  if (persona != null)
                    Text(
                      _personaTitle(context, persona),
                      maxLines: 2,
                      style: _display(width * .095, weight: FontWeight.w800),
                    ),
                  if (showsTags && recap.tags.isNotEmpty) ...[
                    SizedBox(height: width * .016),
                    Text(
                      recap.tags
                          .take(3)
                          .map((tag) => recapTagText(tag.name))
                          .join('  ·  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: width * .04,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  Divider(
                    height: width * .06,
                    thickness: .6,
                    color: Colors.white38,
                  ),
                  Wrap(
                    spacing: width * .05,
                    children: [
                      _fact(context, width, '${recap.saves}', 'Saved'),
                      _fact(context, width, '${recap.opens}', 'Opened'),
                      _fact(
                        context,
                        width,
                        '${recap.activeDays}',
                        'Active days',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
  Widget _fact(
    BuildContext context,
    double width,
    String value,
    String label,
  ) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.baseline,
    textBaseline: TextBaseline.alphabetic,
    children: [
      Text(value, style: _display(width * .05, weight: FontWeight.w700)),
      SizedBox(width: width * .012),
      Text(
        _t(context, label),
        style: TextStyle(fontSize: width * .03, color: Colors.white70),
      ),
    ],
  );
}

class RecapEntryCard extends StatefulWidget {
  const RecapEntryCard({
    super.key,
    required this.controller,
    required this.mode,
    required this.onSearch,
    this.onOpen,
  });
  final AppController controller;
  final AppMode mode;
  final ValueChanged<String> onSearch;
  final ValueChanged<ContentItem>? onOpen;
  @override
  State<RecapEntryCard> createState() => _RecapEntryCardState();
}

class _RecapEntryCardState extends State<RecapEntryCard> {
  late RecapShelf _shelf = RecapShelf(widget.controller, widget.mode);
  @override
  void didUpdateWidget(RecapEntryCard old) {
    super.didUpdateWidget(old);
    if (old.mode != widget.mode) {
      _shelf.dispose();
      _shelf = RecapShelf(widget.controller, widget.mode);
    }
  }

  @override
  void dispose() {
    _shelf.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _shelf,
    builder: (context, _) {
      final recap = _shelf.latest ?? _shelf.sample;
      final scheme = Theme.of(context).colorScheme;
      final latest = _shelf.latest;
      return Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => RecapScreen(
                controller: widget.controller,
                mode: widget.mode,
                onSearch: widget.onSearch,
                onOpen: widget.onOpen,
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: SizedBox(
                    width: 58,
                    height: 78,
                    child: recap == null
                        ? null
                        : RecapArt(
                            work: recap.cover,
                            palette: _shelf.palette(recap),
                            private:
                                widget.controller.store.setting(
                                  'recap.private',
                                  false,
                                ) ==
                                true,
                            sample: recap.isSample,
                          ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'RECAP',
                        style: _display(19, color: scheme.onSurface),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        latest == null
                            ? _t(context, 'Your first issue is on its way')
                            : _t(context, 'No. %@ · %@', [
                                '${latest.issue}',
                                _periodTitle(context, latest),
                              ]),
                        maxLines: 2,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, size: 22),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// The magazine rack: the latest issue up front, the current week beside it,
/// every back issue kept, and the shape of a person's taste across them.
class RecapScreen extends StatefulWidget {
  const RecapScreen({
    super.key,
    required this.controller,
    required this.mode,
    required this.onSearch,
    this.onOpen,
    this.autoAdvance = true,
  });
  final AppController controller;
  final AppMode mode;
  final ValueChanged<String> onSearch;
  final ValueChanged<ContentItem>? onOpen;
  final bool autoAdvance;
  @override
  State<RecapScreen> createState() => _RecapScreenState();
}

class _RecapScreenState extends State<RecapScreen> {
  late final RecapShelf _shelf = RecapShelf(widget.controller, widget.mode);
  bool get _private =>
      widget.controller.store.setting('recap.private', false) == true;

  @override
  void dispose() {
    _shelf.dispose();
    super.dispose();
  }

  void _read(Recap recap) => Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (_, _, _) => RecapStoryScreen(
        recap: _shelf.opened(recap),
        palette: _shelf.palette(recap),
        private: _private,
        autoAdvance: widget.autoAdvance,
        onSearch: widget.onSearch,
        onOpen: widget.onOpen,
      ),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        leading: const TegnalBackButton(),
        backgroundColor: scheme.surface,
        actions: [
          IconButton(
            tooltip: _t(context, 'Hide artwork in Recap'),
            icon: Icon(
              _private
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
            ),
            onPressed: () => setState(
              () => widget.controller.store.setSetting(
                'recap.private',
                !_private,
              ),
            ),
          ),
        ],
      ),
      body: !widget.controller.taste.enabled
          ? EmptyState(
              icon: Icons.pause_circle_outline,
              title: 'Taste analysis is paused on your devices.',
            )
          : ListenableBuilder(
              listenable: _shelf,
              builder: (context, _) => Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                    children: [
                      Text(
                        'RECAP',
                        style: _display(44, color: scheme.onSurface),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _t(context, 'A magazine made from what you loved.'),
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 24),
                      if (_shelf.latest != null)
                        ..._hero(_shelf.latest!)
                      else if (_shelf.sample != null)
                        ..._first(_shelf.sample!),
                      if (_shelf.week?.hasActivity == true) ...[
                        const SizedBox(height: 28),
                        _weekly(_shelf.week!),
                      ],
                      if (_shelf.year != null) ...[
                        const SizedBox(height: 16),
                        _yearly(_shelf.year!),
                      ],
                      if (_shelf.pastIssues.isNotEmpty) ...[
                        const SizedBox(height: 28),
                        _heading('Back issues'),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 222,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: _shelf.pastIssues.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 12),
                            itemBuilder: (context, index) {
                              final recap = _shelf.pastIssues[index];
                              return SizedBox(
                                width: 164,
                                child: _coverButton(recap),
                              );
                            },
                          ),
                        ),
                      ],
                      if (_shelf.issues.length >= 2) ...[
                        const SizedBox(height: 28),
                        _heading('Your taste over time'),
                        const SizedBox(height: 4),
                        Text(
                          _t(
                            context,
                            'Each bar is an issue, labeled with the tag that set it apart.',
                          ),
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 12),
                        _trend(),
                      ],
                      const SizedBox(height: 28),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(_t(context, 'Hide artwork in Recap')),
                        subtitle: Text(
                          _t(
                            context,
                            "Show each issue's colors instead of your covers.",
                          ),
                        ),
                        value: _private,
                        onChanged: (value) => setState(
                          () => widget.controller.store.setSetting(
                            'recap.private',
                            value,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.lock_outline,
                            size: 16,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _t(
                                context,
                                'Made on this device from your own activity. Nothing is uploaded to build it.',
                              ),
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _heading(String key) => Semantics(
    header: true,
    child: Text(
      _t(context, key),
      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
    ),
  );

  Widget _coverButton(Recap recap) {
    final palette = _shelf.palette(recap);
    return Semantics(
      button: true,
      label: _t(context, 'Recap issue %@, %@', [
        '${recap.issue}',
        _periodTitle(context, recap),
      ]),
      child: ExcludeSemantics(
        child: GestureDetector(
          onTap: () => _read(recap),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: RecapCover(
              recap: recap,
              palette: palette,
              background: RecapArt(
                work: recap.cover,
                palette: palette,
                private: _private,
                sample: recap.isSample,
                seed: recap.issue,
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _hero(Recap recap) => [
    AspectRatio(aspectRatio: .74, child: _coverButton(recap)),
    const SizedBox(height: 14),
    FilledButton.icon(
      key: const ValueKey('recap.latest'),
      onPressed: () => _read(recap),
      style: FilledButton.styleFrom(
        backgroundColor: _shelf.palette(recap).deep,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(50),
      ),
      icon: const Icon(Icons.auto_stories_outlined),
      label: Text(
        _t(context, recap.isComplete ? 'Read this issue' : 'Read so far'),
      ),
    ),
  ];

  List<Widget> _first(Recap sample) => [
    AspectRatio(aspectRatio: .74, child: _coverButton(sample)),
    const SizedBox(height: 14),
    Text(
      _t(context, 'Your first issue is on its way'),
      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
    ),
    const SizedBox(height: 6),
    Text(
      _t(
        context,
        'Save and open a few works. Your cover, colors and persona will come from them, not from this sample.',
      ),
      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
    const SizedBox(height: 14),
    FilledButton.icon(
      key: const ValueKey('recap.sample'),
      onPressed: () => _read(sample),
      style: FilledButton.styleFrom(
        backgroundColor: _shelf.palette(sample).deep,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(50),
      ),
      icon: const Icon(Icons.auto_stories_outlined),
      label: Text(_t(context, 'Read a sample issue')),
    ),
  ];

  Widget _weekly(Recap recap) {
    final scheme = Theme.of(context).colorScheme;
    final peak = math.max(
      1,
      recap.days.map((day) => day.touched).reduce(math.max),
    );
    final top =
        recap.signature ?? (recap.tags.isEmpty ? null : recap.tags.first);
    Widget fact(String value, String label) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        Text(
          _t(context, label),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ],
    );
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('recap.week'),
        onTap: () => _read(recap),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _t(context, 'This week'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 17,
                      ),
                    ),
                  ),
                  Text(
                    _periodTitle(context, recap),
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 54,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final day in recap.days)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Container(
                            height: 8 + 44 * day.touched / peak,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(5),
                              color: day.touched > 0
                                  ? scheme.primary.withValues(
                                      alpha: .35 + .65 * day.touched / peak,
                                    )
                                  : scheme.onSurface.withValues(alpha: .1),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 22,
                children: [
                  fact('${recap.saves}', 'Saved'),
                  fact('${recap.opens}', 'Opened'),
                  if (recap.seconds >= 60)
                    fact(_duration(context, recap.seconds), 'Viewing time'),
                ],
              ),
              if (top != null) ...[
                const SizedBox(height: 10),
                Text(
                  '# ${recapTagText(top.name)}',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _yearly(Recap recap) {
    final palette = _shelf.palette(recap);
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: 124,
        child: Stack(
          fit: StackFit.expand,
          children: [
            RecapColorField(palette: palette, seed: 21),
            ColoredBox(color: palette.ink.withValues(alpha: .32)),
            Material(
              color: Colors.transparent,
              child: InkWell(
                key: const ValueKey('recap.year'),
                onTap: () => _read(recap),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: DefaultTextStyle.merge(
                    style: const TextStyle(color: Colors.white),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(_t(context, 'Year in review'), style: _folio(11)),
                        Text(_periodTitle(context, recap), style: _display(36)),
                        Text(
                          _t(context, '%@ works · %@ active days', [
                            '${recap.saves}',
                            '${recap.activeDays}',
                          ]),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _trend() {
    final scheme = Theme.of(context).colorScheme;
    final months = _shelf.issues.take(12).toList();
    final peak = math.max(
      1,
      months.map((recap) => recap.saves).reduce(math.max),
    );
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          for (final recap in months)
            InkWell(
              onTap: () => _read(recap),
              child: SizedBox(
                height: 34,
                child: Row(
                  children: [
                    SizedBox(
                      width: 40,
                      child: Text(
                        _monthName(context, recap.start),
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) => Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            height: 10,
                            width: math.max(
                              6,
                              constraints.maxWidth * recap.saves / peak,
                            ),
                            decoration: BoxDecoration(
                              color: _shelf
                                  .palette(recap)
                                  .swatches
                                  .first
                                  .withValues(alpha: .85),
                              borderRadius: BorderRadius.circular(5),
                            ),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 108,
                      child: Text(
                        recapTagText(
                          (recap.signature ??
                                      (recap.tags.isEmpty
                                          ? null
                                          : recap.tags.first))
                                  ?.name ??
                              '—',
                        ),
                        textAlign: TextAlign.end,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
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

class _Rise extends StatefulWidget {
  const _Rise({required this.order, required this.child});
  final int order;
  final Widget child;
  @override
  State<_Rise> createState() => _RiseState();
}

class _RiseState extends State<_Rise> {
  bool _shown = false;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer(Duration(milliseconds: 100 + widget.order * 90), () {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return AnimatedSlide(
      duration: still ? Duration.zero : const Duration(milliseconds: 480),
      curve: Curves.easeOutCubic,
      offset: _shown || still ? Offset.zero : const Offset(0, .12),
      child: AnimatedOpacity(
        duration: still ? Duration.zero : const Duration(milliseconds: 380),
        opacity: _shown || still ? 1 : 0,
        child: widget.child,
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.value, required this.style});
  final int value;
  final TextStyle style;
  @override
  Widget build(BuildContext context) => Semantics(
    label: '$value',
    child: ExcludeSemantics(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: value.toDouble()),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 1100),
        curve: Curves.easeOutCubic,
        builder: (_, shown, _) => Text('${shown.round()}', style: style),
      ),
    ),
  );
}

/// A tap-through issue. Pages advance by themselves, stop while held or
/// covered, and never run on under a screen reader, where the reader sets
/// the pace.
class RecapStoryScreen extends StatefulWidget {
  const RecapStoryScreen({
    super.key,
    required this.recap,
    required this.palette,
    required this.private,
    required this.onSearch,
    this.onOpen,
    this.autoAdvance = true,
  });
  final Recap recap;
  final RecapPalette palette;
  final bool private;
  final ValueChanged<String> onSearch;
  final ValueChanged<ContentItem>? onOpen;
  final bool autoAdvance;
  @override
  State<RecapStoryScreen> createState() => _RecapStoryScreenState();
}

class _RecapStoryScreenState extends State<RecapStoryScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final List<RecapPage> _pages = RecapPage.pagesFor(widget.recap);
  late final AnimationController _progress = AnimationController(vsync: this)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed && _index < _pages.length - 1) {
        _go(_index + 1);
      }
    });
  final FocusNode _focus = FocusNode();
  int _index = 0;
  double _drag = 0;
  bool _covered = false;
  DateTime? _down;

  Recap get recap => widget.recap;
  RecapPage get _page => _pages[_index];

  Duration _duration(RecapPage page) => Duration(
    milliseconds: switch (page) {
      RecapPage.cover => 4500,
      RecapPage.chart || RecapPage.rhythm || RecapPage.persona => 9000,
      RecapPage.palette => 6000,
      _ => 7000,
    },
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _play());
  }

  void _play({bool restart = true}) {
    if (!mounted) return;
    final blocked =
        !widget.autoAdvance ||
        _covered ||
        MediaQuery.accessibleNavigationOf(context) ||
        _index >= _pages.length - 1;
    _progress.duration = _duration(_page);
    if (blocked) {
      _progress.stop();
      if (_index >= _pages.length - 1) _progress.value = 1;
    } else if (restart) {
      _progress.forward(from: 0);
    } else {
      _progress.forward();
    }
  }

  void _go(int target) {
    if (target < 0 || target >= _pages.length || target == _index) return;
    HapticFeedback.selectionClick();
    setState(() => _index = target);
    _progress.value = 0;
    _play();
  }

  Future<void> _cover(Future<void> Function() action) async {
    _progress.stop();
    _covered = true;
    await action();
    _covered = false;
    if (mounted) _play(restart: false);
  }

  void _openWork(RecapWork work) {
    if (recap.isSample) return;
    final open = widget.onOpen;
    if (open == null) return;
    open(work.item);
  }

  void _search(String query) {
    if (recap.isSample) return;
    Navigator.of(context).pop();
    widget.onSearch(query);
  }

  void _share() => _cover(
    () => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => RecapShareSheet(recap: recap, palette: widget.palette),
    ),
  );

  void _saved() => _cover(
    () => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecapWorksScreen(
          recap: recap,
          palette: widget.palette,
          private: widget.private,
          onOpen: _openWork,
        ),
      ),
    ),
  );

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _play(restart: false);
    } else {
      _progress.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _progress.dispose();
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _go(_index + 1);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _go(_index - 1);
    } else if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    return Scaffold(
      backgroundColor: palette.ink,
      body: Focus(
        autofocus: true,
        focusNode: _focus,
        onKeyEvent: _key,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 600;
            final width = compact
                ? constraints.maxWidth
                : math.min(constraints.maxWidth, constraints.maxHeight * .62);
            return Transform.translate(
              offset: Offset(0, _drag),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (!compact)
                    Positioned.fill(
                      child: Opacity(
                        opacity: .45,
                        child: RecapColorField(palette: palette),
                      ),
                    ),
                  SizedBox(
                    width: width,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (_) {
                        _down = DateTime.now();
                        _progress.stop();
                      },
                      onTapUp: (details) {
                        final quick =
                            DateTime.now().difference(_down ?? DateTime.now()) <
                            const Duration(milliseconds: 250);
                        if (quick) {
                          final next = details.localPosition.dx >= width * .28;
                          if (next ? _index < _pages.length - 1 : _index > 0) {
                            _go(_index + (next ? 1 : -1));
                            return;
                          }
                        }
                        _play(restart: false);
                      },
                      onTapCancel: () => _play(restart: false),
                      onVerticalDragUpdate: (details) => setState(
                        () => _drag = math.max(0, _drag + details.delta.dy),
                      ),
                      onVerticalDragEnd: (details) {
                        if (_drag > 110 ||
                            (details.primaryVelocity ?? 0) > 900) {
                          Navigator.of(context).pop();
                        } else {
                          setState(() => _drag = 0);
                          _play(restart: false);
                        }
                      },
                      onHorizontalDragEnd: (details) {
                        final velocity = details.primaryVelocity ?? 0;
                        if (velocity.abs() > 200) {
                          _go(_index + (velocity < 0 ? 1 : -1));
                        }
                      },
                      child: AnimatedSwitcher(
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 320),
                        child: KeyedSubtree(
                          key: ValueKey(_page),
                          child: _RecapPageView(
                            page: _page,
                            recap: recap,
                            palette: palette,
                            private: widget.private,
                            onTag: (tag) => _search(tag.name),
                            onPerson: (person) => _search(
                              recap.mode == AppMode.manga
                                  ? 'artist:${person.name}'
                                  : person.name,
                            ),
                            onWork: _openWork,
                            onShare: _share,
                            onSaved: _saved,
                            onReplay: () => _go(0),
                            onDone: () => Navigator.of(context).pop(),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: width, child: _chrome()),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _chrome() {
    final onPaper = _page == RecapPage.persona;
    final color = onPaper ? widget.palette.paperInk : Colors.white;
    return SafeArea(
      child: IgnorePointer(
        ignoring: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: ExcludeSemantics(
                child: AnimatedBuilder(
                  animation: _progress,
                  builder: (context, _) => Row(
                    children: [
                      for (var page = 0; page < _pages.length; page++)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                minHeight: 2.5,
                                backgroundColor: color.withValues(alpha: .28),
                                valueColor: AlwaysStoppedAnimation(color),
                                value: page < _index
                                    ? 1
                                    : (page > _index ? 0 : _progress.value),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Row(
              children: [
                const SizedBox(width: 14),
                Text('RECAP', style: _display(15, color: color)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _periodTitle(context, recap),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _folio(10, color: color.withValues(alpha: .75)),
                  ),
                ),
                IconButton(
                  key: const ValueKey('recap.story.share'),
                  tooltip: _t(context, 'Share cover'),
                  color: color,
                  onPressed: _share,
                  icon: const Icon(Icons.ios_share),
                ),
                IconButton(
                  key: const ValueKey('recap.story.close'),
                  tooltip: _t(context, 'Close'),
                  color: color,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const Spacer(),
            if (_index < _pages.length - 1)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: _t(context, 'Previous card'),
                    color: color,
                    onPressed: _index == 0 ? null : () => _go(_index - 1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  IconButton(
                    key: const ValueKey('recap.story.next'),
                    tooltip: _t(context, 'Next card'),
                    color: color,
                    onPressed: () => _go(_index + 1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _RecapPageView extends StatelessWidget {
  const _RecapPageView({
    required this.page,
    required this.recap,
    required this.palette,
    required this.private,
    required this.onTag,
    required this.onPerson,
    required this.onWork,
    required this.onShare,
    required this.onSaved,
    required this.onReplay,
    required this.onDone,
  });
  final RecapPage page;
  final Recap recap;
  final RecapPalette palette;
  final bool private;
  final ValueChanged<RecapTag> onTag;
  final ValueChanged<RecapPerson> onPerson;
  final ValueChanged<RecapWork> onWork;
  final VoidCallback onShare;
  final VoidCallback onSaved;
  final VoidCallback onReplay;
  final VoidCallback onDone;

  Widget _art(RecapWork? work, {int seed = 3}) => RecapArt(
    work: work,
    palette: palette,
    private: private,
    sample: recap.isSample,
    seed: seed,
  );
  Widget _eyebrow(
    BuildContext context,
    String key, {
    List<String> arguments = const [],
    Color? color,
  }) => Semantics(
    header: true,
    child: Text(
      _t(context, key, arguments),
      style: _folio(12, color: color ?? palette.accent),
    ),
  );
  Widget _button(
    BuildContext context,
    String key,
    IconData icon,
    VoidCallback? action, {
    bool prominent = true,
  }) => FilledButton.icon(
    onPressed: action,
    style: FilledButton.styleFrom(
      backgroundColor: prominent
          ? palette.accent
          : Colors.white.withValues(alpha: .14),
      foregroundColor: prominent ? palette.paperInk : Colors.white,
      minimumSize: const Size(0, 46),
    ),
    icon: Icon(icon, size: 18),
    label: Text(_t(context, key)),
  );
  Widget _stat(BuildContext context, int value, String label) => Semantics(
    container: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$value',
          style: _display(26, weight: FontWeight.w700, color: Colors.white),
        ),
        Text(
          _t(context, label),
          style: const TextStyle(fontSize: 12, color: Colors.white70),
        ),
      ],
    ),
  );
  Widget _scrim(List<double> stops, List<double> alphas) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: stops,
        colors: [
          for (final alpha in alphas) palette.ink.withValues(alpha: alpha),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final safe = MediaQuery.paddingOf(context);
      final size = constraints.biggest;
      final unit = math.min(size.width / 390, size.height / 760);
      final top = safe.top + 76;
      final bottom = math.max(safe.bottom, 12.0) + 58;
      return DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.white),
        child: SizedBox.expand(
          child: switch (page) {
            RecapPage.cover => _cover(context, safe),
            RecapPage.numbers => _numbers(context, size, unit, bottom),
            RecapPage.chart => _chart(context, unit, top, bottom),
            RecapPage.person => _person(context, unit, bottom),
            RecapPage.palette => _swatches(context, size, unit, top),
            RecapPage.discovery => _discovery(context, unit, top, bottom),
            RecapPage.year => _year(context, unit, top, bottom),
            RecapPage.rhythm => _rhythm(context, unit, top, bottom),
            RecapPage.time => _time(context, unit, bottom),
            RecapPage.favorite => _favorite(context, unit, bottom),
            RecapPage.rediscover => _rediscover(context, unit, top, bottom),
            RecapPage.persona => _personaPage(context, unit, top, bottom),
            RecapPage.next => _next(context, unit, top, safe),
          },
        ),
      );
    },
  );

  Widget _cover(BuildContext context, EdgeInsets safe) => RecapCover(
    recap: recap,
    palette: palette,
    note: recap.hasActivity && recap.editorNote != null
        ? _line(context, recap.editorNote!)
        : null,
    padding: EdgeInsets.only(
      top: safe.top + 48,
      bottom: math.max(safe.bottom, 12) + 34,
    ),
    background: _art(recap.cover, seed: recap.issue),
  );

  Widget _numbers(BuildContext context, Size size, double unit, double bottom) {
    final side = (size.width + 60) / 5;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: palette.ink),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: size.height * .58,
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.topCenter,
              maxWidth: size.width + 60,
              maxHeight: size.height,
              child: Transform.rotate(
                angle: -.12,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final (index, work) in recap.saved.take(20).indexed)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: SizedBox(
                          width: side - 6,
                          height: side * 1.3,
                          child: _art(work, seed: index),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: size.height * .58,
          child: _scrim(const [0, 1], const [.1, 1]),
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: bottom,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Rise(
                order: 0,
                child: _eyebrow(
                  context,
                  'You saved %@',
                  arguments: [
                    _t(
                      context,
                      recap.period == RecapPeriod.week
                          ? 'this week'
                          : 'this issue',
                    ),
                  ],
                ),
              ),
              _Rise(
                order: 1,
                child: _Count(
                  value: recap.saves,
                  style: _display(128 * unit, color: Colors.white),
                ),
              ),
              _Rise(
                order: 2,
                child: Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      _t(
                        context,
                        recap.mode == AppMode.booru
                            ? 'recap.unit.images'
                            : 'recap.unit.works',
                      ),
                      style: _display(26 * unit, weight: FontWeight.w600),
                    ),
                    if (recap.saves != recap.previousSaves)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .14),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          _t(context, '%@ vs last period', [
                            '${recap.saves > recap.previousSaves ? '+' : ''}${recap.saves - recap.previousSaves}',
                          ]),
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Divider(height: 28 * unit, color: Colors.white30),
              _Rise(
                order: 4,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _stat(context, recap.opens, 'Opened'),
                    _stat(context, recap.activeDays, 'Active days'),
                    _stat(context, recap.longestStreak, 'Peak streak'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _chart(BuildContext context, double unit, double top, double bottom) {
    final rows = recap.tags
        .take(recap.period == RecapPeriod.week ? 4 : 5)
        .toList();
    final peak = math.max(1, rows.first.count);
    final used = <String>{};
    return ColoredBox(
      color: palette.ink,
      child: Padding(
        padding: EdgeInsets.fromLTRB(22, top, 22, bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Rise(order: 0, child: _eyebrow(context, 'The chart')),
            SizedBox(height: 12 * unit),
            _Rise(
              order: 1,
              child: Text(
                _t(context, switch (recap.period) {
                  RecapPeriod.week => 'The tags that defined your week',
                  RecapPeriod.year => 'The tags that defined your year',
                  RecapPeriod.month => 'The tags that defined your month',
                }),
                style: _display(33 * unit, weight: FontWeight.w800),
              ),
            ),
            SizedBox(height: 14 * unit),
            for (final (index, tag) in rows.indexed)
              Expanded(
                child: _Rise(
                  order: index + 2,
                  child: _chartRow(context, tag, peak, unit, used),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _chartRow(
    BuildContext context,
    RecapTag tag,
    int peak,
    double unit,
    Set<String> used,
  ) {
    final works = tag.works.map(recap.work).whereType<RecapWork>().toList();
    RecapWork? work;
    for (final entry in works) {
      if (used.add(entry.key)) {
        work = entry;
        break;
      }
    }
    work ??= works.isEmpty ? null : works.first;
    final change = tag.movement;
    return InkWell(
      onTap: () => onTag(tag),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 56 * unit,
              height: 74 * unit,
              child: _art(work, seed: tag.rank),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 34 * unit,
            child: Text(
              '${tag.rank}',
              style: _display(
                36 * unit,
                color: tag.rank == 1 ? palette.accent : Colors.white,
              ),
            ),
          ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        recapTagText(tag.name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 18 * unit,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (tag.isNew)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: palette.accent,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(
                          _t(context, 'NEW'),
                          style: _folio(9, color: palette.paperInk),
                        ),
                      )
                    else if (change != null && change != 0)
                      Text(
                        '${change > 0 ? '↑' : '↓'}${change.abs()}',
                        style: _folio(
                          11,
                          color: change > 0 ? palette.accent : Colors.white54,
                        ),
                      ),
                    const SizedBox(width: 8),
                    Text(
                      '${tag.count}',
                      style: _folio(13, color: Colors.white70),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: tag.count / peak),
                    duration: const Duration(milliseconds: 800),
                    curve: Curves.easeOutCubic,
                    builder: (_, value, _) => LinearProgressIndicator(
                      minHeight: 4,
                      value: value,
                      backgroundColor: Colors.white.withValues(alpha: .13),
                      valueColor: AlwaysStoppedAnimation(
                        tag.rank == 1 ? palette.accent : Colors.white70,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _person(BuildContext context, double unit, double bottom) {
    final lead = recap.people.first;
    final works = lead.works.map(recap.work).whereType<RecapWork>().toList();
    return Stack(
      fit: StackFit.expand,
      children: [
        _art(works.isEmpty ? null : works.first, seed: 11),
        _scrim(const [0, .3, .82], const [.5, 0, 1]),
        Positioned(
          left: 24,
          right: 24,
          bottom: bottom,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Rise(
                order: 0,
                child: Row(
                  children: [
                    for (final work in works.skip(1).take(3))
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 64 * unit,
                            height: 86 * unit,
                            child: _art(work),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(height: 10 * unit),
              _Rise(order: 1, child: _eyebrow(context, 'Artist of the issue')),
              SizedBox(height: 6 * unit),
              _Rise(
                order: 2,
                child: Text(
                  recapTagText(lead.name),
                  maxLines: 2,
                  style: _display(44 * unit),
                ),
              ),
              SizedBox(height: 8 * unit),
              _Rise(
                order: 3,
                child: Text(
                  _t(context, '%@ works saved %@', [
                    '${lead.count}',
                    _t(context, 'this issue'),
                  ]),
                  style: TextStyle(fontSize: 17 * unit, color: Colors.white70),
                ),
              ),
              const SizedBox(height: 12),
              _Rise(
                order: 4,
                child: _button(
                  context,
                  'See more',
                  Icons.search,
                  recap.isSample ? null : () => onPerson(lead),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _swatches(BuildContext context, Size size, double unit, double top) {
    const flexes = [34, 24, 18, 14, 10];
    return Stack(
      fit: StackFit.expand,
      children: [
        Row(
          children: [
            for (final (index, color) in palette.swatches.indexed)
              Expanded(
                flex: flexes[index],
                child: ColoredBox(
                  color: color,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 90),
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: Text(
                          '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}',
                          style: _folio(
                            9.5,
                            color: color.computeLuminance() > .4
                                ? Colors.black54
                                : Colors.white70,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        _scrim(const [0, .34, .52], const [.94, .74, 0]),
        Padding(
          padding: EdgeInsets.fromLTRB(24, top, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Rise(
                order: 1,
                child: _eyebrow(
                  context,
                  'The colors of your covers',
                  color: Colors.white,
                ),
              ),
              SizedBox(height: 10 * unit),
              _Rise(
                order: 2,
                child: Text(
                  _t(context, 'This issue was %@', [
                    _t(context, 'palette.${palette.mood}'),
                  ]),
                  style: _display(50 * unit),
                ),
              ),
              SizedBox(height: 10 * unit),
              _Rise(
                order: 3,
                child: Text(
                  _t(
                    context,
                    'Measured from the covers you kept. Every issue gets its own.',
                  ),
                  style: TextStyle(fontSize: 15 * unit),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _discovery(
    BuildContext context,
    double unit,
    double top,
    double bottom,
  ) {
    final highlight = recap.highlights.first, tag = highlight.tag;
    final works = tag.works
        .map(recap.work)
        .whereType<RecapWork>()
        .take(3)
        .toList();
    final (heading, detail) = switch (highlight.kind) {
      RecapHighlightKind.comeback => (
        'Back in rotation',
        _t(
          context,
          'You had drifted away from this tag. %@ works brought it back.',
          ['${tag.count}'],
        ),
      ),
      RecapHighlightKind.newcomer => (
        'New to your collection',
        _t(
          context,
          'You had never saved this tag before. Now it has %@ works.',
          ['${tag.count}'],
        ),
      ),
      RecapHighlightKind.rising => (
        'On the rise',
        _t(context, 'Saved works with this tag increased from %@ to %@.', [
          '${tag.previousCount}',
          '${tag.count}',
        ]),
      ),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [palette.deep, palette.ink],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, top, 24, bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Rise(order: 0, child: _eyebrow(context, heading)),
            SizedBox(height: 10 * unit),
            _Rise(
              order: 1,
              child: Text(
                recapTagText(tag.name),
                maxLines: 3,
                style: _display(52 * unit),
              ),
            ),
            SizedBox(height: 10 * unit),
            _Rise(
              order: 2,
              child: Text(
                detail,
                style: TextStyle(fontSize: 17 * unit, color: Colors.white70),
              ),
            ),
            const Spacer(),
            _Rise(
              order: 3,
              child: Center(
                child: SizedBox(
                  height: 214 * unit,
                  width: double.infinity,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      for (final (index, work) in works.indexed)
                        Transform.translate(
                          offset: Offset(
                            (index - (works.length - 1) / 2) * 92 * unit,
                            (index - (works.length - 1) / 2).abs() * 12,
                          ),
                          child: Transform.rotate(
                            angle: (index - (works.length - 1) / 2) * .12,
                            child: GestureDetector(
                              onTap: () => onWork(work),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: SizedBox(
                                  width: 146 * unit,
                                  height: 196 * unit,
                                  child: _art(work, seed: index),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const Spacer(),
            _Rise(
              order: 4,
              child: _button(
                context,
                'Explore this tag',
                Icons.search,
                recap.isSample ? null : () => onTag(tag),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _year(BuildContext context, double unit, double top, double bottom) {
    final peak = math.max(
      1,
      recap.months.map((month) => month.saves).reduce(math.max),
    );
    final best = recap.months.reduce((a, b) => b.saves > a.saves ? b : a);
    return ColoredBox(
      color: palette.ink,
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, top, 24, bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Rise(order: 0, child: _eyebrow(context, 'The shape of your year')),
            SizedBox(height: 12 * unit),
            _Rise(
              order: 1,
              child: Text(
                _t(context, '%@ was your biggest month', [
                  _monthName(context, best.start),
                ]),
                style: _display(40 * unit),
              ),
            ),
            const Spacer(),
            _Rise(
              order: 2,
              child: SizedBox(
                height: 270 * unit,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final month in recap.months)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2.5),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (month.saves > 0)
                                Text(
                                  '${month.saves}',
                                  style: _folio(8, color: Colors.white70),
                                ),
                              const SizedBox(height: 4),
                              Container(
                                height: math.max(
                                  3,
                                  210 * unit * month.saves / peak,
                                ),
                                decoration: BoxDecoration(
                                  color: month.start == best.start
                                      ? palette.accent
                                      : Colors.white.withValues(alpha: .32),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${month.start.month}',
                                style: _folio(8, color: Colors.white70),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }

  Widget _rhythm(BuildContext context, double unit, double top, double bottom) {
    final peak = math.max(
      1,
      recap.days.map((day) => day.touched).reduce(math.max),
    );
    final yearly = recap.period == RecapPeriod.year;
    final lead = recap.days.first.date.weekday - 1;
    final busiest = recap.busiestDay;
    return ColoredBox(
      color: palette.ink,
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, top, 24, bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Rise(order: 0, child: _eyebrow(context, 'Your rhythm')),
            SizedBox(height: 10 * unit),
            _Rise(
              order: 1,
              child: Text(
                recap.longestStreak >= 2
                    ? _t(context, '%@ days in a row', [
                        '${recap.longestStreak}',
                      ])
                    : _t(context, '%@ active days', ['${recap.activeDays}']),
                style: _display(42 * unit),
              ),
            ),
            if (busiest != null) ...[
              SizedBox(height: 10 * unit),
              _Rise(
                order: 2,
                child: Text(
                  _t(context, 'Your busiest day was %@, with %@ works.', [
                    _dayName(context, busiest.date),
                    '${busiest.touched}',
                  ]),
                  style: TextStyle(fontSize: 16 * unit, color: Colors.white70),
                ),
              ),
            ],
            const Spacer(),
            _Rise(
              order: 3,
              child: ExcludeSemantics(
                child: GridView.count(
                  crossAxisCount: yearly ? 26 : 7,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: yearly ? 2 : 4,
                  crossAxisSpacing: yearly ? 2 : 4,
                  childAspectRatio: yearly ? 1 : 1.2,
                  children: [
                    if (!yearly)
                      ...List.generate(lead, (_) => const SizedBox()),
                    for (final day in recap.days)
                      DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(yearly ? 1.5 : 4),
                          color: day.touched == 0
                              ? Colors.white.withValues(alpha: .09)
                              : palette.accent.withValues(
                                  alpha: .32 + .68 * day.touched / peak,
                                ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            _Rise(
              order: 4,
              child: Row(
                children: [
                  SizedBox(
                    width: 128 * unit,
                    height: 128 * unit,
                    child: CustomPaint(
                      painter: _ClockPainter(recap.hours, palette.accent),
                    ),
                  ),
                  SizedBox(width: 18 * unit),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _t(context, 'Peak hour'),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white70,
                          ),
                        ),
                        Text(
                          _t(
                            context,
                            (recap.peakHour ?? 12) < 12 ? '%@ AM' : '%@ PM',
                            ['${(recap.peakHour ?? 12) % 12 == 0 ? 12 : (recap.peakHour ?? 12) % 12}'],
                          ),
                          style: _display(32 * unit),
                        ),
                        Text(
                          _t(context, 'The hour you were most often here.'),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }

  Widget _time(BuildContext context, double unit, double bottom) => Stack(
    fit: StackFit.expand,
    children: [
      Opacity(
        opacity: .72,
        child: _art(
          recap.revisited ??
              (recap.saved.length > 1 ? recap.saved[1] : recap.cover),
          seed: 9,
        ),
      ),
      _scrim(const [0, .3, .72], const [.55, .15, 1]),
      Positioned(
        left: 24,
        right: 24,
        bottom: bottom + 8,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Rise(order: 0, child: _eyebrow(context, 'Time with your art')),
            SizedBox(height: 10 * unit),
            _Rise(
              order: 1,
              child: Text(
                _duration(context, recap.seconds),
                style: _display(66 * unit),
              ),
            ),
            SizedBox(height: 10 * unit),
            _Rise(
              order: 2,
              child: Text(
                _t(
                  context,
                  'Time counts only while a work is on screen and you keep moving.',
                ),
                style: TextStyle(fontSize: 15 * unit, color: Colors.white70),
              ),
            ),
            Divider(height: 28 * unit, color: Colors.white30),
            _Rise(
              order: 3,
              child: Row(
                children: [
                  _stat(
                    context,
                    recap.pages,
                    recap.mode == AppMode.booru
                        ? 'Images viewed'
                        : 'Pages read',
                  ),
                  if (recap.mode == AppMode.manga) ...[
                    const SizedBox(width: 34),
                    _stat(context, recap.finished, 'Finished'),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _favorite(BuildContext context, double unit, double bottom) {
    final work = recap.revisited!;
    return Stack(
      fit: StackFit.expand,
      children: [
        _art(work, seed: 5),
        _scrim(const [0, .3, .86], const [.55, 0, 1]),
        Positioned(
          left: 24,
          right: 24,
          bottom: bottom,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Rise(
                order: 0,
                child: _eyebrow(context, 'The one you kept coming back to'),
              ),
              SizedBox(height: 8 * unit),
              _Rise(
                order: 1,
                child: Text(
                  work.item.title,
                  maxLines: 3,
                  style: _display(34 * unit),
                ),
              ),
              SizedBox(height: 8 * unit),
              _Rise(
                order: 2,
                child: Text(
                  work.seconds >= 60
                      ? _t(context, 'Opened %@ times · %@', [
                          '${work.opens}',
                          _duration(context, work.seconds),
                        ])
                      : _t(context, 'Opened %@ times', ['${work.opens}']),
                  style: TextStyle(fontSize: 17 * unit, color: Colors.white70),
                ),
              ),
              const SizedBox(height: 12),
              _Rise(
                order: 3,
                child: _button(
                  context,
                  'Open again',
                  Icons.north_east,
                  recap.isSample ? null : () => onWork(work),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _rediscover(
    BuildContext context,
    double unit,
    double top,
    double bottom,
  ) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [palette.ink, palette.deep],
      ),
    ),
    child: Padding(
      padding: EdgeInsets.fromLTRB(22, top, 22, bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Rise(order: 0, child: _eyebrow(context, 'From your own shelves')),
          SizedBox(height: 10 * unit),
          _Rise(
            order: 1,
            child: Text(
              _t(context, 'Saved long ago, waiting for now'),
              style: _display(36 * unit),
            ),
          ),
          SizedBox(height: 10 * unit),
          _Rise(
            order: 2,
            child: Text(
              _t(
                context,
                "These match this issue's taste, and you haven't opened them in a while.",
              ),
              style: TextStyle(fontSize: 15 * unit, color: Colors.white70),
            ),
          ),
          SizedBox(height: 14 * unit),
          Expanded(
            child: _Rise(
              order: 3,
              child: GridView.count(
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: .92,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final (index, work) in recap.rediscover.take(4).indexed)
                    GestureDetector(
                      onTap: () => onWork(work),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _art(work, seed: index),
                            Align(
                              alignment: Alignment.bottomLeft,
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(8),
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.transparent,
                                      Colors.black87,
                                    ],
                                  ),
                                ),
                                child: Text(
                                  work.item.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
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
          ),
        ],
      ),
    ),
  );

  Widget _personaPage(
    BuildContext context,
    double unit,
    double top,
    double bottom,
  ) {
    final persona = recap.persona!;
    return ColoredBox(
      color: palette.paper,
      child: DefaultTextStyle.merge(
        style: TextStyle(color: palette.paperInk),
        child: Padding(
          padding: EdgeInsets.fromLTRB(24, top, 24, bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Rise(
                order: 0,
                child: Text(
                  _t(context, 'This issue, you were'),
                  style: _folio(
                    12,
                    color: palette.paperInk.withValues(alpha: .65),
                  ),
                ),
              ),
              SizedBox(height: 10 * unit),
              _Rise(
                order: 1,
                child: Text(
                  _personaTitle(context, persona),
                  maxLines: 3,
                  style: _display(54 * unit, color: palette.paperInk),
                ),
              ),
              SizedBox(height: 10 * unit),
              _Rise(
                order: 2,
                child: Text(
                  _t(context, 'persona.summary.${persona.style.name}'),
                  style: _display(
                    19 * unit,
                    weight: FontWeight.w500,
                  ).copyWith(fontStyle: FontStyle.italic),
                ),
              ),
              Divider(
                height: 30 * unit,
                color: palette.paperInk.withValues(alpha: .35),
              ),
              for (final (index, trait) in persona.traits.indexed)
                _Rise(
                  order: index + 3,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: 10 * unit),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '0${index + 1}',
                          style: _folio(
                            12,
                            color: palette.paperInk.withValues(alpha: .55),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _line(context, trait),
                            style: TextStyle(
                              fontSize: 16 * unit,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const Spacer(),
              _Rise(
                order: 6,
                child: Row(
                  children: [
                    for (final (index, work) in recap.saved.take(4).indexed)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: AspectRatio(
                              aspectRatio: .74,
                              child: _art(work, seed: index),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const Spacer(),
              Text(
                _t(
                  context,
                  'Patterns describe your activity in this app. They are suggestions, not conclusions about you.',
                ),
                style: TextStyle(
                  fontSize: 12,
                  color: palette.paperInk.withValues(alpha: .62),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _next(
    BuildContext context,
    double unit,
    double top,
    EdgeInsets safe,
  ) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [palette.deep, palette.ink],
      ),
    ),
    child: Padding(
      padding: EdgeInsets.fromLTRB(24, top, 24, math.max(safe.bottom, 12) + 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Rise(order: 0, child: _eyebrow(context, 'Next issue')),
          SizedBox(height: 10 * unit),
          _Rise(
            order: 1,
            child: Text(
              _t(context, 'Where to go from here'),
              style: _display(38 * unit),
            ),
          ),
          SizedBox(height: 8 * unit),
          for (final (index, tag) in recap.next.indexed)
            _Rise(
              order: index + 2,
              child: InkWell(
                onTap: recap.isSample ? null : () => onTag(tag),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: Colors.white24)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          recapTagText(tag.name),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _display(23 * unit, weight: FontWeight.w700),
                        ),
                      ),
                      const Icon(
                        Icons.north_east,
                        size: 18,
                        color: Colors.white,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const Spacer(),
          if (recap.saved.isNotEmpty)
            TextButton.icon(
              key: const ValueKey('recap.saved'),
              onPressed: onSaved,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                padding: EdgeInsets.zero,
              ),
              icon: const Icon(Icons.grid_view, size: 18),
              label: Text(
                _t(context, 'All %@ saved works', ['${recap.saves}']),
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _button(context, 'Share cover', Icons.ios_share, onShare),
              _button(
                context,
                'Replay',
                Icons.replay,
                onReplay,
                prominent: false,
              ),
              _button(context, 'Done', Icons.check, onDone, prominent: false),
            ],
          ),
        ],
      ),
    ),
  );
}

class _ClockPainter extends CustomPainter {
  const _ClockPainter(this.hours, this.accent);
  final List<int> hours;
  final Color accent;
  @override
  void paint(Canvas canvas, Size size) {
    final peak = math.max(1, hours.reduce(math.max));
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(3, radius * .075);
    for (var hour = 0; hour < 24; hour++) {
      final angle = hour / 24 * math.pi * 2 - math.pi / 2;
      final value = hours[hour] / peak;
      final inner = radius * .42;
      final outer = inner + (radius - inner) * math.max(.06, value);
      final direction = Offset(math.cos(angle), math.sin(angle));
      paint.color = value > 0
          ? accent.withValues(alpha: .45 + value * .55)
          : Colors.white.withValues(alpha: .14);
      canvas.drawLine(
        center + direction * inner,
        center + direction * outer,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ClockPainter old) =>
      old.hours != hours || old.accent != accent;
}

/// Sharing is opt-in twice over: by default the card carries colors and
/// numbers only. Artwork and tags appear only after the person turns them on.
class RecapShareSheet extends StatefulWidget {
  const RecapShareSheet({
    super.key,
    required this.recap,
    required this.palette,
  });
  final Recap recap;
  final RecapPalette palette;
  @override
  State<RecapShareSheet> createState() => _RecapShareSheetState();
}

class _RecapShareSheetState extends State<RecapShareSheet> {
  final GlobalKey _card = GlobalKey();
  bool _square = false;
  bool _artwork = false;
  bool _tags = false;
  String? _message;

  Future<void> _save() async {
    final failed = _t(context, 'Unable to save. Please try again.');
    final done = _t(context, 'Saved');
    try {
      final boundary =
          _card.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final saved = await BackupFiles.exportImage(
        data!.buffer.asUint8List(),
        'tegnal-recap-${widget.recap.issue}.png',
      );
      if (mounted && saved) setState(() => _message = done);
    } on Exception {
      if (mounted) setState(() => _message = failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final recap = widget.recap, palette = widget.palette;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _t(context, 'Share cover'),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          Center(
            child: RepaintBoundary(
              key: _card,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: _square ? 260 : 214,
                  height: _square ? 260 : 380,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      RecapCover(
                        recap: recap,
                        palette: palette,
                        showsTags: _tags,
                        background: _artwork
                            ? RecapArt(
                                work: recap.cover,
                                palette: palette,
                                private: false,
                                sample: recap.isSample,
                                seed: recap.issue,
                              )
                            : RecapColorField(
                                palette: palette,
                                seed: recap.issue,
                              ),
                      ),
                      Align(
                        alignment: Alignment.bottomRight,
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Text(
                            'TEGNAL',
                            style: _display(
                              9,
                              weight: FontWeight.w800,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: false, label: Text(_t(context, 'Story'))),
              ButtonSegment(value: true, label: Text(_t(context, 'Square'))),
            ],
            selected: {_square},
            onSelectionChanged: (value) =>
                setState(() => _square = value.first),
          ),
          SwitchListTile(
            key: const ValueKey('recap.share.artwork'),
            title: Text(_t(context, 'Show cover artwork')),
            value: _artwork,
            onChanged: (value) => setState(() => _artwork = value),
          ),
          SwitchListTile(
            key: const ValueKey('recap.share.tags'),
            title: Text(_t(context, 'Show top tags')),
            value: _tags,
            onChanged: (value) => setState(() => _tags = value),
          ),
          Text(
            _t(
              context,
              "Off by default, so a shared card shows only colors and numbers. Check what's visible before you post.",
            ),
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          if (_message != null) ...[Text(_message!), const SizedBox(height: 8)],
          FilledButton.icon(
            onPressed: _save,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
            ),
            icon: const Icon(Icons.save_alt),
            label: Text(_t(context, 'Save image')),
          ),
        ],
      ),
    );
  }
}

/// The period's saves as a browsable shelf.
class RecapWorksScreen extends StatelessWidget {
  const RecapWorksScreen({
    super.key,
    required this.recap,
    required this.palette,
    required this.private,
    required this.onOpen,
  });
  final Recap recap;
  final RecapPalette palette;
  final bool private;
  final ValueChanged<RecapWork> onOpen;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: const TegnalBackButton(),
      title: Text(_periodTitle(context, recap)),
    ),
    body: GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 130,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        childAspectRatio: .74,
      ),
      itemCount: recap.saved.length,
      itemBuilder: (context, index) {
        final work = recap.saved[index];
        return Semantics(
          button: true,
          label: work.item.title,
          child: GestureDetector(
            onTap: () => onOpen(work),
            child: RecapArt(
              work: work,
              palette: palette,
              private: private,
              sample: recap.isSample,
              seed: index,
            ),
          ),
        );
      },
    ),
  );
}
