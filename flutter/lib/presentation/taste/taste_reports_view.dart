import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/booru/booru_models.dart';
import '../../core/support/l10n.dart';
import '../../core/taste/recommendation_service.dart';
import '../../core/taste/taste_analyzer.dart';
import '../../core/taste/taste_models.dart';
import '../../core/taste/taste_recap.dart';
import '../../domain/models.dart';
import '../booru/booru_feed_view.dart';
import '../design/grouped_form.dart';
import '../design/symbols.dart';
import '../design/tegnal_theme.dart';
import '../library/local_thumbnail.dart';
import '../navigation/app_header.dart';
import '../navigation/app_state.dart';
import '../navigation/root_tab_view.dart';
import '../settings/settings_page.dart';
import '../settings/settings_rows.dart';
import 'taste_context.dart';
import 'taste_dashboard.dart' show TasteProminentButton;
import 'taste_presentation.dart';
import 'taste_settings_view.dart' show TasteListPage;

/// The month a period starts in, as its title.
String _monthTitle(DateTime date) => switch (L10n.language) {
  'ko' => '${date.year}년 ${date.month}월',
  'ja' => '${date.year}年${date.month}月',
  _ =>
    '${const ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'][date.month - 1]} ${date.year}',
};

/// `TasteReportsView`: one period's statistics and what stands out, with the period stepper
/// and a mode switch that previews either library.
class TasteReportsView extends StatefulWidget {
  const TasteReportsView({super.key, required this.taste, required this.mode, required this.period});
  final TasteContext taste;
  final TasteMode mode;
  final TastePeriod period;

  @override
  State<TasteReportsView> createState() => _TasteReportsViewState();
}

class _TasteReportsViewState extends State<TasteReportsView> {
  late final _preview = AppState(mode: widget.mode == TasteMode.booru ? AppMode.booru : AppMode.manga);
  late int _offset = widget.period == TastePeriod.month ? -1 : 0;
  TasteSnapshot? _snapshot;
  TasteReport? _report;
  bool _failed = false;
  final _loaded = <String, (TasteSnapshot, TasteReport?)>{};

  TasteContext get _taste => widget.taste;
  TasteMode get _mode => _preview.mode == AppMode.booru ? TasteMode.booru : TasteMode.comics;
  String get _key => '${_mode.name}:$_offset:${_taste.controller.control.analysisKey(_mode)}';

  @override
  void initState() {
    super.initState();
    _preview.addListener(_load);
    _taste.controller.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _preview.removeListener(_load);
    _taste.controller.removeListener(_load);
    _preview.dispose();
    super.dispose();
  }

  void _load() {
    if (!mounted) return;
    final key = _key;
    setState(() => _failed = false);
    final controller = _taste.controller;
    if (!controller.control.enabled) {
      setState(() {
        _snapshot = null;
        _report = null;
      });
      return;
    }
    if (_loaded[key] case final existing?) {
      setState(() {
        _snapshot = existing.$1;
        _report = existing.$2;
      });
      return;
    }
    try {
      final result = controller.snapshot(_mode, period: widget.period, offset: _offset);
      final control = controller.control;
      final cached = controller.store(_mode).report(digest: result.digest, language: L10n.language, epoch: control.epoch);
      TasteReport report;
      if (cached != null && cached.isValid(result)) {
        report = cached;
      } else {
        report = StatisticalInsightService.report(snapshot: result, control: control, language: L10n.language);
        controller.store(_mode).saveReport(report);
      }
      _loaded[key] = (result, report);
      setState(() {
        _snapshot = result;
        _report = report;
      });
    } on Object {
      setState(() => _failed = true);
    }
  }

  void _setOffset(int value) {
    _offset = value;
    _load();
  }

  void _openTag(TasteTag tag) => Navigator.of(context).push(
    CupertinoPageRoute<void>(
      builder: (_) => TasteTagDetail(taste: _taste, tag: tag, mode: _mode),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final top = media.padding.top + rootBarHeight;
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final snapshot = _snapshot;
    final enabled = _taste.controller.control.enabled;
    Widget body;
    if (!enabled) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            L10n.text('Taste analysis is paused on your devices.'),
            textAlign: TextAlign.center,
            style: TegnalType.style(17, color: secondary),
          ),
        ),
      );
    } else if (snapshot != null) {
      body = ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, tabBarClearance(context)),
        children: [
          TasteStatisticsView(snapshot: snapshot, period: widget.period, timeZone: _taste.controller.control.timeZone),
          const SizedBox(height: 20),
          if (snapshot.saves == 0) ...[
            Text(L10n.text('No saved works in this period. Try the previous period to see earlier activity.'), style: TegnalType.style(17, color: secondary)),
            const SizedBox(height: 20),
          ],
          if (_report case final report? when report.insights.isNotEmpty) ...[
            const TasteSectionHeading(title: 'What stands out'),
            for (final insight in report.insights)
              if (snapshot.tags.where((tag) => tag.id == insight.tagKey).firstOrNull case final tag?) ...[
                const SizedBox(height: 20),
                GestureDetector(
                  onTap: () => _openTag(tag),
                  child: TasteSurface(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          TastePresentation.name(tag.name),
                          style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                        ),
                        const SizedBox(height: 10),
                        Text(TastePresentation.explanation(insight, tag, snapshot), style: TegnalType.style(15, color: secondary)),
                      ],
                    ),
                  ),
                ),
              ],
            const SizedBox(height: 20),
          ],
          if (snapshot.tags.isNotEmpty) ...[
            GestureDetector(
              onTap: () => Navigator.of(context).push(
                CupertinoPageRoute<void>(
                  builder: (_) => TasteTagListPage(taste: _taste, mode: _mode, tags: snapshot.tags),
                ),
              ),
              child: Row(
                children: [
                  Icon(CupertinoIcons.arrow_up_right, size: 17, color: TastePresentation.accent(context)),
                  const SizedBox(width: 6),
                  Text(L10n.text('Recommendation evidence'), style: TegnalType.style(17, color: TastePresentation.accent(context))),
                ],
              ),
            ),
            for (final tag in snapshot.tags.take(5)) ...[
              const SizedBox(height: 20),
              GestureDetector(
                onTap: () => _openTag(tag),
                child: TasteSurface(child: TasteTagRow(tag: tag)),
              ),
            ],
          ],
        ],
      );
    } else if (_failed) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(L10n.text('Unable to update taste analysis.'), style: TegnalType.style(17, color: secondary)),
            const SizedBox(height: 12),
            CupertinoButton(onPressed: _load, child: Text(L10n.text('Try Again'))),
          ],
        ),
      );
    } else {
      body = const Center(child: CupertinoActivityIndicator());
    }
    return ColoredBox(
      color: FormColors.listBackground.resolveFrom(context),
      child: Column(
        children: [
          SizedBox(
            height: top,
            child: Stack(
              children: [
                const Positioned.fill(child: InlineTitleHeader(title: '')),
                Positioned(
                  left: 0,
                  right: 0,
                  top: media.padding.top,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: AppModeSwitch(state: _preview),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TastePeriodNavigation(
              period: widget.period,
              offset: _offset,
              timeZone: _taste.controller.control.timeZone,
              latestOffset: widget.period == TastePeriod.month ? -1 : 0,
              onChanged: _setOffset,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// `TastePeriodNavigation`: the period's dates between previous and next.
class TastePeriodNavigation extends StatelessWidget {
  const TastePeriodNavigation({super.key, required this.period, required this.offset, required this.timeZone, required this.onChanged, this.latestOffset = 0});
  final TastePeriod period;
  final int offset;
  final String timeZone;
  final int latestOffset;
  final ValueChanged<int> onChanged;

  String get _label {
    final interval = period.interval(offset: offset, now: DateTime.now(), timeZone: timeZone);
    if (interval == null) return '';
    final calendar = TasteCalendar(timeZone);
    final start = calendar.local(interval.start);
    if (period == TastePeriod.month) return _monthTitle(start);
    return '${RecapFormat.day(start)} – ${RecapFormat.day(calendar.local(interval.end.subtract(const Duration(seconds: 1))))}';
  }

  @override
  Widget build(BuildContext context) {
    final label = TegnalColors.label.resolveFrom(context);
    Widget arrow(IconData icon, String title, VoidCallback? onTap) => Semantics(
      button: true,
      label: title,
      enabled: onTap != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox.square(
          dimension: 44,
          child: Icon(icon, size: 20, color: label.withValues(alpha: onTap == null ? 0.3 : 1)),
        ),
      ),
    );
    return Row(
      children: [
        arrow(CupertinoIcons.chevron_left, L10n.text('Previous Period'), () => onChanged(offset - 1)),
        Expanded(
          child: Column(
            children: [
              Text(
                _label,
                textAlign: TextAlign.center,
                style: TegnalType.style(17, weight: FontWeight.w600, color: label),
              ),
              const SizedBox(height: 5),
              if (offset == 0)
                Text(L10n.text('In progress'), style: TegnalType.style(12, color: TegnalColors.secondaryLabel.resolveFrom(context)))
              else if (offset < latestOffset)
                GestureDetector(
                  onTap: () => onChanged(latestOffset),
                  child: Text(
                    L10n.text(period == TastePeriod.week ? 'Back to this week' : 'Latest recap'),
                    style: TegnalType.style(12, color: TegnalColors.tint.resolveFrom(context)),
                  ),
                ),
            ],
          ),
        ),
        arrow(CupertinoIcons.chevron_right, L10n.text('Next Period'), offset >= latestOffset ? null : () => onChanged(offset + 1)),
      ],
    );
  }
}

/// `TasteStatisticsView`: new saves against the previous period, and saves per day.
class TasteStatisticsView extends StatelessWidget {
  const TasteStatisticsView({super.key, required this.snapshot, required this.period, required this.timeZone});
  final TasteSnapshot snapshot;
  final TastePeriod period;
  final String timeZone;

  Widget _metric(BuildContext context, String title, int value, IconData icon) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 13, color: secondary),
            // `Label` leaves its title-and-icon gap even at caption size.
            const SizedBox(width: 10),
            Text(L10n.text(title), style: TegnalType.style(12, color: secondary)),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '$value',
          style: TegnalType.style(22, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = TastePresentation.accent(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final label = TegnalColors.label.resolveFrom(context);
    final previous = snapshot.previousSaves;
    final interval = snapshot.period;
    return Column(
      children: [
        TasteSurface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(L10n.text('Newly saved works'), style: TegnalType.style(15, color: secondary)),
                  ),
                  Icon(CupertinoIcons.heart_fill, size: 17, color: accent),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '${snapshot.saves}',
                    style: TegnalType.style(34, weight: FontWeight.w700, color: label),
                  ),
                  if (previous != null) ...[
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: ShapeDecoration(color: accent.withValues(alpha: 0.1), shape: const StadiumBorder()),
                      child: Text(
                        '${snapshot.saves - previous > 0 ? '+' : ''}${snapshot.saves - previous}',
                        semanticsLabel: L10n.text('Change from previous period: %@', ['${snapshot.saves - previous}']),
                        style: TegnalType.style(15, weight: FontWeight.w700, color: accent),
                      ),
                    ),
                  ],
                ],
              ),
              if (previous != null) ...[
                const SizedBox(height: 16),
                Text(L10n.text('%@ saved in the previous period', ['$previous']), style: TegnalType.style(12, color: secondary)),
              ],
              const SizedBox(height: 16),
              Container(height: 0.5, color: TegnalColors.separator.resolveFrom(context)),
              const SizedBox(height: 16),
              Row(
                children: [
                  _metric(context, 'Active days', snapshot.activity.length, CupertinoIcons.calendar),
                  const SizedBox(width: 20),
                  const Spacer(),
                  _metric(context, 'Searches', snapshot.searches, CupertinoIcons.search),
                  const Spacer(),
                ],
              ),
            ],
          ),
        ),
        if (snapshot.activity.isNotEmpty && interval != null) ...[
          const SizedBox(height: 18),
          TasteSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  L10n.text('Your activity'),
                  style: TegnalType.style(17, weight: FontWeight.w600, color: label),
                ),
                const SizedBox(height: 20),
                Semantics(
                  label: L10n.text('Saved works over time'),
                  child: SizedBox(
                    height: 170,
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: _ActivityChart(
                        days: _days(interval),
                        stride: period == TastePeriod.month ? 7 : 1,
                        accent: accent,
                        text: secondary,
                        grid: TegnalColors.separator.resolveFrom(context),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// Every day of the period with its saves.
  List<(DateTime, int)> _days(TasteInterval interval) {
    final calendar = TasteCalendar(timeZone);
    final counts = <String, int>{};
    for (final entry in snapshot.activity.entries) {
      final day = calendar.local(entry.key);
      counts['${day.year}-${day.month}-${day.day}'] = entry.value;
    }
    final result = <(DateTime, int)>[];
    var day = calendar.startOfDay(interval.start);
    while (day.isBefore(interval.end)) {
      result.add((day, counts['${day.year}-${day.month}-${day.day}'] ?? 0));
      day = calendar.addDays(day, 1);
    }
    return result;
  }
}

/// Saves per day as rounded bars, with day labels and a leading count axis.
class _ActivityChart extends CustomPainter {
  _ActivityChart({required this.days, required this.stride, required this.accent, required this.text, required this.grid});
  final List<(DateTime, int)> days;
  final int stride;
  final Color accent;
  final Color text;
  final Color grid;

  TextPainter _label(String value) => TextPainter(
    text: TextSpan(
      text: value,
      style: TegnalType.style(11, color: text),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    if (days.isEmpty) return;
    final peak = math.max(1, days.map((day) => day.$2).reduce(math.max));
    final step = peak <= 3 ? 1 : (peak / 3).ceil();
    final ticks = [for (var value = 0; value <= peak; value += step) value];
    const labelHeight = 18.0;
    final axisWidth = _label('$peak').width + 6;
    final chart = Rect.fromLTRB(axisWidth, 0, size.width, size.height - labelHeight);
    final line = Paint()
      ..color = grid
      ..strokeWidth = 0.5;
    for (final tick in ticks) {
      final y = chart.bottom - chart.height * tick / peak;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), line);
      final label = _label('$tick');
      label.paint(canvas, Offset(0, y - label.height / 2));
    }
    final slot = chart.width / days.length;
    final width = math.max(2.0, slot * 0.6);
    final bar = Paint()
      ..shader = LinearGradient(colors: [accent, accent.withValues(alpha: 0.75)], begin: Alignment.topCenter, end: Alignment.bottomCenter).createShader(chart);
    for (final (index, (day, count)) in days.indexed) {
      final x = chart.left + slot * index + (slot - width) / 2;
      if (count > 0) {
        final height = chart.height * count / peak;
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, chart.bottom - height, width, height), const Radius.circular(4)), bar);
      }
      if (index % stride == 0) {
        final label = _label('${day.day}');
        label.paint(canvas, Offset(x + width / 2 - label.width / 2, chart.bottom + 4));
      }
    }
  }

  @override
  bool shouldRepaint(_ActivityChart old) => old.days != days || old.accent != accent;
}

/// `TasteTagDetail`: one tag's evidence, its supporting works and its exclusion.
class TasteTagDetail extends StatelessWidget {
  const TasteTagDetail({super.key, required this.taste, required this.tag, required this.mode});
  final TasteContext taste;
  final TasteTag tag;
  final TasteMode mode;

  bool get _connected =>
      mode == TasteMode.comics ? taste.comics.content.isSiteVerified : taste.booru.store.servers.any((server) => server.canonicalAddress == tag.source);

  void _explore(BuildContext context) {
    if (mode == TasteMode.booru) {
      final server = taste.booru.store.servers.where((server) => server.canonicalAddress == tag.source).firstOrNull;
      if (server != null) BooruFeedView.push(context, booru: taste.booru, server: server, query: tag.name);
    } else {
      taste.comics.search(context, tag.name);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: taste.controller,
    builder: (context, _) {
      final accent = TastePresentation.accent(context);
      final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
      final row = FormColors.listRow.resolveFrom(context);
      final excluded = taste.controller.control.excluded.contains(tag.id);
      final collecting = !tag.previouslySearched && tag.hidden > 0 && (tag.hidden < 5 || tag.sessions.length < 3);
      return TasteListPage(
        title: L10n.text('Taste details'),
        children: [
          FormSection(
            rowColor: row,
            footer: Text(L10n.text('Recommendation searches send the selected tags to your connected websites. Your taste profile is not sent.')),
            children: [
              FormRow(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(tag.discovery ? CupertinoIcons.sparkles : CupertinoIcons.heart, size: 15, color: accent),
                          const SizedBox(width: 6),
                          Text(
                            TastePresentation.category(tag),
                            style: TegnalType.style(15, weight: FontWeight.w500, color: accent),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        TastePresentation.name(tag.name),
                        style: TegnalType.style(34, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
                      ),
                      const SizedBox(height: 12),
                      Text(TastePresentation.host(tag.source), style: TegnalType.style(15, color: secondary)),
                      const SizedBox(height: 16),
                      TasteProminentButton(
                        title: L10n.text('Explore this tag'),
                        icon: CupertinoIcons.search,
                        onPressed: _connected ? () => _explore(context) : null,
                      ),
                      if (!_connected) ...[
                        const SizedBox(height: 12),
                        Text(L10n.text('Connect this source in Settings to explore this tag.'), style: TegnalType.style(13, color: secondary)),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
          settingsSectionGap,
          FormSection(
            rowColor: row,
            header: Text(L10n.text('Your evidence')),
            footer: Text(L10n.text('Patterns describe your activity in this app. They are suggestions, not conclusions about you.')),
            children: [
              SettingsValueRow(title: L10n.text('Saved works'), value: '${tag.count}'),
              SettingsValueRow(title: L10n.text('Confirmed by your choices'), value: '${tag.confirmed}'),
              SettingsValueRow(title: L10n.text('Saved without searching'), value: '${tag.hidden}'),
              if (tag.general > 0) SettingsValueRow(title: L10n.text('Other saved works'), value: '${tag.general}'),
              SettingsValueRow(title: L10n.text('Searches'), value: '${tag.searches}'),
              if (tag.lift case final lift?) FormRow(child: Text(L10n.text('%@× as frequent in saved works', [lift.toStringAsFixed(1)]))),
              if (collecting)
                FormRow(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          L10n.text('A pattern is taking shape'),
                          style: TegnalType.style(15, weight: FontWeight.w500, color: TegnalColors.label.resolveFrom(context)),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          L10n.text('We look for at least 5 saved works across 3 browsing sessions before suggesting a hidden preference.'),
                          style: TegnalType.style(13, color: secondary),
                        ),
                        const SizedBox(height: 8),
                        Semantics(
                          label: L10n.text('Collecting evidence'),
                          child: LayoutBuilder(
                            builder: (context, constraints) => Container(
                              height: 4,
                              alignment: Alignment.centerLeft,
                              decoration: ShapeDecoration(color: secondary.withValues(alpha: 0.2), shape: const StadiumBorder()),
                              child: Container(
                                width: constraints.maxWidth * (math.min(5, tag.hidden) + math.min(3, tag.sessions.length)) / 8,
                                decoration: ShapeDecoration(color: accent, shape: const StadiumBorder()),
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
          settingsSectionGap,
          FormSection(
            rowColor: row,
            header: Text(L10n.text('Supporting works')),
            footer: Text(L10n.text('Evidence comes from distinct saved works. Opening a work alone does not add preference points.')),
            children: [for (final item in tag.works) _EvidenceRow(taste: taste, item: item, tag: tag, mode: mode)],
          ),
          settingsSectionGap,
          FormSection(
            rowColor: row,
            children: [
              FormRow(
                onTap: () => taste.controller.change((control) => excluded ? control.excluded.remove(tag.id) : control.excluded.add(tag.id)),
                child: Row(
                  children: [
                    Icon(excluded ? CupertinoIcons.plus_circle : CupertinoIcons.minus_circle, size: 22, color: TegnalColors.tint.resolveFrom(context)),
                    const SizedBox(width: 12),
                    Text(
                      L10n.text(excluded ? 'Include in recommendations' : 'Exclude from recommendations'),
                      style: TegnalType.style(17, color: TegnalColors.tint.resolveFrom(context)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      );
    },
  );
}

/// One work behind a tag: its picture and title, opening it when still in the library.
class _EvidenceRow extends StatelessWidget {
  const _EvidenceRow({required this.taste, required this.item, required this.tag, required this.mode});
  final TasteContext taste;
  final TasteItem item;
  final TasteTag tag;
  final TasteMode mode;

  BooruPost? get _post {
    if (mode != TasteMode.booru) return null;
    final store = taste.booru.store;
    final servers = [
      for (final server in store.servers)
        if (server.canonicalAddress == item.source) server.id,
    ];
    return store.favorites(servers).where((post) => post.postID == item.id).firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final post = _post;
    final Work? work = mode == TasteMode.comics ? taste.controller.library.getWork(item.id) : null;
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final enabled = mode == TasteMode.comics || post != null;
    final placeholder = ColoredBox(
      color: secondary.withValues(alpha: 0.1),
      child: Center(child: Icon(mode == TasteMode.booru ? Symbols.photo : Symbols.book, size: 18, color: secondary)),
    );
    return FormRow(
      onTap: !enabled
          ? null
          : () {
              if (post != null) {
                openRecommendation(context, taste, TasteRecommendation(item: item, post: post, reason: tag, score: 0));
              } else {
                taste.comics.openThumbnail(context, item.id);
              }
            },
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 52,
              height: 64,
              child: post != null
                  ? TasteArtwork(taste: taste, post: post)
                  : work?.thumbPath != null
                  ? LocalThumbnail(path: work!.thumbPath, revision: '${work.thumbPage ?? 1}', placeholder: placeholder)
                  : placeholder,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  work?.title ?? L10n.text('Work %@', ['${item.id}']),
                  maxLines: 2,
                  style: TegnalType.style(15, weight: FontWeight.w500, color: TegnalColors.label.resolveFrom(context)),
                ),
                const SizedBox(height: 4),
                Text(
                  L10n.text(mode == TasteMode.booru && post == null ? 'No longer in your library' : 'Saved works'),
                  style: TegnalType.style(12, color: secondary),
                ),
              ],
            ),
          ),
          Icon(CupertinoIcons.chevron_right, size: 13, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
        ],
      ),
    );
  }
}

/// `TasteTagList`: every tag the recommendations draw on, searchable.
class TasteTagListPage extends StatefulWidget {
  const TasteTagListPage({super.key, required this.taste, required this.mode, required this.tags});
  final TasteContext taste;
  final TasteMode mode;
  final List<TasteTag> tags;

  @override
  State<TasteTagListPage> createState() => _TasteTagListPageState();
}

class _TasteTagListPageState extends State<TasteTagListPage> {
  final _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final control = widget.taste.controller.control;
    final query = _query.text.toLowerCase();
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final tags = [
      for (final tag in widget.tags)
        if (control.allows(tag.name, source: tag.source, mode: widget.mode) &&
            (query.isEmpty || tag.name.toLowerCase().contains(query) || TastePresentation.name(tag.name).toLowerCase().contains(query)))
          tag,
    ];
    return TasteListPage(
      title: L10n.text('Recommendation evidence'),
      headerFirst: true,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: CupertinoSearchTextField(controller: _query, placeholder: L10n.text('Search tags')),
        ),
        FormSection(
          rowColor: FormColors.listRow.resolveFrom(context),
          children: [
            for (final tag in tags)
              FormRow(
                onTap: () => Navigator.of(context).push(
                  CupertinoPageRoute<void>(
                    builder: (_) => TasteTagDetail(taste: widget.taste, tag: tag, mode: widget.mode),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              TastePresentation.name(tag.name),
                              style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                            ),
                            const SizedBox(height: 5),
                            Text(TastePresentation.host(tag.source), style: TegnalType.style(12, color: secondary)),
                          ],
                        ),
                      ),
                      Text('${tag.count}', style: TegnalType.style(17, color: secondary)),
                      const SizedBox(width: 6),
                      Icon(CupertinoIcons.chevron_right, size: 13, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
