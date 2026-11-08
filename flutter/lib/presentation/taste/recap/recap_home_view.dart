import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../../core/support/l10n.dart';
import '../../../core/taste/recap_shelf.dart';
import '../../../core/taste/taste_models.dart';
import '../../../core/taste/taste_recap.dart';
import '../../design/alert_dialog.dart';
import '../../design/glass.dart';
import '../../design/system_colors.dart';
import '../../design/tegnal_theme.dart';
import '../../navigation/app_header.dart';
import '../../navigation/app_state.dart';
import '../taste_context.dart';
import '../taste_reports_view.dart';
import 'recap_artwork.dart';
import 'recap_cover.dart';
import 'recap_cover_art.dart';
import 'recap_story_view.dart';
import 'recap_style.dart';

String _grouped(int value) => '$value'.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

/// `RecapHomeView`: the magazine rack. The latest issue up front, the current week beside
/// it, every back issue kept, and the shape of a person's taste across them.
class RecapHomeView extends StatefulWidget {
  const RecapHomeView({super.key, required this.taste, required this.mode, this.opening, this.onBack});
  final TasteContext taste;
  final TasteMode mode;

  /// Opens this month's issue as soon as it has loaded, for the arrival banner.
  final DateTime? opening;
  final VoidCallback? onBack;

  @override
  State<RecapHomeView> createState() => _RecapHomeViewState();
}

class _RecapHomeViewState extends State<RecapHomeView> {
  late TasteMode _mode = widget.mode;
  late RecapShelf _shelf = RecapShelf(controller: _taste.controller, mode: _mode);
  late final _artwork = RecapArtwork(_taste);
  late final _preview = AppState(mode: _mode == TasteMode.booru ? AppMode.booru : AppMode.manga);
  bool _openedArrival = false;
  int _generation = 0;

  TasteContext get _taste => widget.taste;
  bool get _private => _taste.booru.safeMode;
  String get _requestKey => '${_mode.name}:${_taste.controller.control.analysisKey(_mode)}:${_taste.booru.store.revision}';

  @override
  void initState() {
    super.initState();
    _shelf.addListener(_changed);
    _taste.controller.addListener(_reload);
    _preview.addListener(_modeChanged);
    _load();
  }

  @override
  void dispose() {
    _shelf.removeListener(_changed);
    _taste.controller.removeListener(_reload);
    _preview.removeListener(_modeChanged);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _reload() {
    if (_shelf.loadedKey != _requestKey) _load();
    _changed();
  }

  /// The mode switch previews the other library's recap without leaving this screen.
  void _modeChanged() {
    final mode = _preview.mode == AppMode.booru ? TasteMode.booru : TasteMode.comics;
    if (mode == _mode) return;
    _shelf.removeListener(_changed);
    setState(() {
      _mode = mode;
      _shelf = RecapShelf(controller: _taste.controller, mode: mode)..addListener(_changed);
    });
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final shelf = _shelf;
    shelf.load(key: _requestKey);
    if (!mounted || generation != _generation) return;
    final opening = widget.opening;
    if (!_openedArrival && opening != null) {
      final recap = shelf.recap(opening);
      if (recap != null) {
        _openedArrival = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _open(recap));
      }
    }
    for (final recap in [?shelf.latest, ?shelf.year, ?shelf.week, ?shelf.sample, ...shelf.pastIssues.take(8)]) {
      if (!mounted || generation != _generation) return;
      await shelf.measure(recap, _artwork.pixels);
    }
  }

  void _open(TasteRecap recap) {
    if (!mounted) return;
    openRecapStory(context, taste: _taste, recap: _shelf.opened(recap), palette: _shelf.palette(recap), artwork: _artwork);
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top + rootBarHeight;
    final Widget body;
    if (!_taste.controller.control.enabled) {
      body = _message(
        CupertinoIcons.pause_circle,
        L10n.text('Taste analysis is paused on your devices.'),
        L10n.text('Enable Taste Analysis'),
        () => _taste.controller.change((control) => control.enabled = true),
      );
    } else if (_shelf.failed) {
      body = _message(CupertinoIcons.exclamationmark_circle, L10n.text('Unable to update taste analysis.'), L10n.text('Try Again'), _load);
    } else if (!_shelf.loaded) {
      body = const Center(child: CupertinoActivityIndicator());
    } else {
      body = _content(top);
    }
    return RecapScope(
      artwork: _artwork,
      private: _private,
      child: ColoredBox(
        color: TegnalColors.background.resolveFrom(context),
        child: Stack(
          children: [
            Positioned.fill(child: body),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: Padding(
                padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
                child: SizedBox(
                  height: rootBarHeight,
                  child: Stack(
                    children: [
                      if (widget.onBack != null) Positioned(left: 16, top: 0, child: _BackButton(onPressed: widget.onBack!)),
                      if (!_private)
                        Align(
                          alignment: Alignment.topCenter,
                          child: AppModeSwitch(state: _preview),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _message(IconData icon, String text, String action, VoidCallback perform) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: TegnalColors.secondaryLabel.resolveFrom(context)),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TegnalType.style(22, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
          ),
          const SizedBox(height: 16),
          CupertinoButton(onPressed: perform, child: Text(action)),
        ],
      ),
    ),
  );

  Widget _content(double top) {
    final shelf = _shelf;
    final latest = shelf.latest, sample = shelf.sample, week = shelf.week, year = shelf.year;
    final sections = <Widget>[
      _masthead(),
      if (latest != null) _hero(latest) else if (sample != null) _first(sample),
      if (week != null && week.hasActivity) _weekly(week),
      if (year != null) _yearly(year),
      if (shelf.pastIssues.isNotEmpty) _backIssues(),
      if (shelf.issues.length >= 2) _trend(),
      _privacy(),
    ];
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: EdgeInsets.fromLTRB(20, top + 8, 20, 32 + MediaQuery.paddingOf(context).bottom),
          children: [
            for (final (index, section) in sections.indexed) ...[if (index > 0) const SizedBox(height: 28), section],
          ],
        ),
      ),
    );
  }

  Widget _masthead() => Semantics(
    container: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('RECAP', style: RecapType.display(44, color: TegnalColors.label.resolveFrom(context), letterSpacing: -0.5)),
        const SizedBox(height: 4),
        Text(L10n.text('A magazine made from what you loved.'), style: TegnalType.style(15, color: TegnalColors.secondaryLabel.resolveFrom(context))),
      ],
    ),
  );

  Widget _cover(TasteRecap recap, {double radius = 14, bool shadow = false}) {
    final palette = _shelf.palette(recap);
    return AspectRatio(
      aspectRatio: 0.74,
      child: Container(
        decoration: shadow
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                boxShadow: [BoxShadow(color: palette.inkColor.withValues(alpha: 0.4), blurRadius: 36, offset: const Offset(0, 10))],
              )
            : null,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: RecapCoverView(recap: recap, palette: palette),
        ),
      ),
    );
  }

  Widget _readButton(String title, RecapPalette palette, VoidCallback onTap) => Semantics(
    button: true,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        height: 50,
        decoration: ShapeDecoration(color: palette.deepColor, shape: const StadiumBorder()),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(CupertinoIcons.book, size: 20, color: Color(0xFFFFFFFF)),
            const SizedBox(width: 8),
            Text(
              title,
              style: TegnalType.style(17, weight: FontWeight.w600, color: const Color(0xFFFFFFFF)),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _hero(TasteRecap recap) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      RecapPressable(onTap: () => _open(recap), child: _cover(recap, shadow: true)),
      const SizedBox(height: 14),
      _readButton(L10n.text(recap.isComplete ? 'Read this issue' : 'Read so far'), _shelf.palette(recap), () => _open(recap)),
    ],
  );

  /// Before the first issue: a veiled cover that says plainly the recap is not ready, and a tap
  /// that explains when it will be rather than opening a sample.
  Widget _first(TasteRecap sample) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Semantics(
        button: true,
        label: L10n.text('Recap is not ready yet'),
        child: RecapPressable(
          onTap: _explainNotReady,
          child: Stack(
            children: [
              _cover(sample),
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: ColoredBox(
                    color: const Color(0x73000000),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(CupertinoIcons.hourglass, size: 40, color: Color(0xFFFFFFFF)),
                          const SizedBox(height: 10),
                          Text(
                            L10n.text('Recap is not ready yet'),
                            textAlign: TextAlign.center,
                            style: TegnalType.style(20, weight: FontWeight.w700, color: const Color(0xFFFFFFFF)),
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
      ),
      const SizedBox(height: 14),
      Text(
        L10n.text('Your first issue is on its way'),
        style: TegnalType.style(20, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
      ),
      const SizedBox(height: 14),
      Text(
        L10n.text('Recap arrives after 30 days of using TEGNAL. Save and open works in the meantime: your cover, colors and persona will come from them.'),
        style: TegnalType.style(15, color: TegnalColors.secondaryLabel.resolveFrom(context)),
      ),
    ],
  );

  void _explainNotReady() => showCupertinoDialog<void>(
    context: context,
    builder: (context) => TegnalAlertDialog(
      title: Text(L10n.text('Recap is not ready yet')),
      content: Text(L10n.text('Your first recap arrives after 30 days of using TEGNAL.')),
      actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('OK')))],
    ),
  );

  Widget _surface(Widget child) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: ShapeDecoration(
      color: TegnalColors.secondaryBackground.resolveFrom(context),
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(22)),
    ),
    child: child,
  );

  Widget _weekly(TasteRecap recap) {
    final peak = math.max(1, recap.days.map((day) => day.touched).fold(0, math.max));
    final accent = SystemColors.indigo.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final label = TegnalColors.label.resolveFrom(context);
    Widget fact(String value, String title) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: TegnalType.style(20, weight: FontWeight.w700, color: label),
        ),
        const SizedBox(height: 2),
        Text(L10n.text(title), style: TegnalType.style(12, color: secondary)),
      ],
    );
    final top = recap.signature ?? recap.tags.firstOrNull;
    return RecapPressable(
      onTap: () => _open(recap),
      child: _surface(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  L10n.text('This week'),
                  style: TegnalType.style(17, weight: FontWeight.w600, color: label),
                ),
                const Spacer(),
                Text(RecapFormat.title(recap), style: TegnalType.style(12, color: secondary)),
                const SizedBox(width: 6),
                Icon(CupertinoIcons.chevron_right, size: 12, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 54,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final (index, day) in recap.days.indexed) ...[
                    if (index > 0) const SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        height: 8 + 44 * day.touched / peak,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(5),
                          color: day.touched > 0 ? accent.withValues(alpha: 0.35 + 0.65 * day.touched / peak) : secondary.withValues(alpha: 0.14),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                fact(_grouped(recap.saves), 'Saved'),
                const SizedBox(width: 22),
                fact(_grouped(recap.opens), 'Opened'),
                if (recap.seconds >= 60) ...[const SizedBox(width: 22), fact(RecapText.duration(recap.seconds), 'Viewing time')],
              ],
            ),
            if (top != null) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Icon(CupertinoIcons.number, size: 15, color: secondary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      RecapText.tag(top.name),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TegnalType.style(15, weight: FontWeight.w500, color: secondary),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _yearly(TasteRecap recap) {
    final palette = _shelf.palette(recap);
    const white = Color(0xFFFFFFFF);
    return RecapPressable(
      onTap: () => _open(recap),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            Positioned.fill(child: RecapColorField(palette: palette, seed: 21)),
            Positioned.fill(child: ColoredBox(color: palette.inkColor.withValues(alpha: 0.32))),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Opacity(
                          opacity: 0.8,
                          child: Text(L10n.text('Year in review').toUpperCase(), style: RecapType.folio(11, color: white, letterSpacing: 1.2)),
                        ),
                        const SizedBox(height: 4),
                        Text(RecapFormat.title(recap), style: RecapType.display(38, color: white)),
                        const SizedBox(height: 4),
                        Text(
                          L10n.text('%@ works · %@ active days', [_grouped(recap.saves), _grouped(recap.activeDays)]),
                          style: TegnalType.style(15, color: white.withValues(alpha: 0.85)),
                        ),
                      ],
                    ),
                  ),
                  const Icon(CupertinoIcons.arrow_up_right, size: 22, color: white),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _heading(String title, {String? subtitle}) => Semantics(
    header: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          L10n.text(title),
          style: TegnalType.style(20, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(subtitle, style: TegnalType.style(15, color: TegnalColors.secondaryLabel.resolveFrom(context))),
        ],
      ],
    ),
  );

  Widget _backIssues() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _heading('Back issues'),
      const SizedBox(height: 12),
      SizedBox(
        height: 222,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          padding: EdgeInsets.zero,
          itemCount: _shelf.pastIssues.length,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (context, index) {
            final recap = _shelf.pastIssues[index];
            return RecapPressable(
              onTap: () => _open(recap),
              child: SizedBox(
                width: 164,
                height: 222,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: RecapCoverView(recap: recap, palette: _shelf.palette(recap)),
                ),
              ),
            );
          },
        ),
      ),
    ],
  );

  Widget _trend() {
    final months = _shelf.issues.take(12).toList();
    final peak = math.max(1, months.map((recap) => recap.saves).fold(0, math.max));
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final label = TegnalColors.label.resolveFrom(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading('Your taste over time', subtitle: L10n.text('Each bar is an issue, labeled with the tag that set it apart.')),
        const SizedBox(height: 12),
        _surface(
          Column(
            children: [
              for (final (index, recap) in months.indexed) ...[
                if (index > 0) const SizedBox(height: 9),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _open(recap),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 24),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 36,
                          child: Text(RecapFormat.month(recap.interval.start), style: TegnalType.style(12, color: secondary)),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, constraints) => Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                width: math.max(6, constraints.maxWidth * recap.saves / peak),
                                height: 10,
                                decoration: ShapeDecoration(
                                  color: _shelf.palette(recap).swatches.first.color.withValues(alpha: 0.85),
                                  shape: const StadiumBorder(),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 104,
                          child: Text(
                            _signature(recap),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.right,
                            style: TegnalType.style(12, weight: FontWeight.w500, color: label),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  static String _signature(TasteRecap recap) {
    final tag = recap.signature ?? recap.tags.firstOrNull;
    return tag == null ? '—' : RecapText.tag(tag.name);
  }

  Widget _privacy() {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final accent = SystemColors.indigo.resolveFrom(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(CupertinoIcons.lock, size: 14, color: secondary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                L10n.text('Made on this device from your own activity. Nothing is uploaded to build it.'),
                style: TegnalType.style(13, color: secondary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        GestureDetector(
          onTap: () => Navigator.of(context).push(
            CupertinoPageRoute<void>(
              builder: (_) => TasteReportsView(taste: _taste, mode: _mode, period: TastePeriod.week),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(CupertinoIcons.chart_bar, size: 14, color: accent),
              const SizedBox(width: 6),
              Text(
                L10n.text('Weekly statistics'),
                style: TegnalType.style(13, weight: FontWeight.w500, color: accent),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The iOS 26 back button: a chevron in its own glass circle.
class _BackButton extends StatelessWidget {
  const _BackButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: L10n.text('Back'),
    excludeSemantics: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: Glass.circle(
        child: SizedBox.square(dimension: 44, child: Icon(CupertinoIcons.chevron_left, size: 22, color: TegnalColors.label.resolveFrom(context))),
      ),
    ),
  );
}

/// `RecapEntryCard`: the Smart tab's way in, the latest cover on a single quiet row.
class RecapEntryCard extends StatefulWidget {
  const RecapEntryCard({super.key, required this.taste, required this.mode});
  final TasteContext taste;
  final TasteMode mode;

  @override
  State<RecapEntryCard> createState() => _RecapEntryCardState();
}

class _RecapEntryCardState extends State<RecapEntryCard> {
  late RecapShelf _shelf = RecapShelf(controller: widget.taste.controller, mode: widget.mode);
  int _revision = -1;

  @override
  void initState() {
    super.initState();
    widget.taste.controller.addListener(_load);
    _load();
  }

  @override
  void didUpdateWidget(RecapEntryCard old) {
    super.didUpdateWidget(old);
    if (old.mode != widget.mode) {
      _shelf = RecapShelf(controller: widget.taste.controller, mode: widget.mode);
      _revision = -1;
      _load();
    }
  }

  @override
  void dispose() {
    widget.taste.controller.removeListener(_load);
    super.dispose();
  }

  void _load() {
    final revision = widget.taste.controller.revision;
    if (revision == _revision) return;
    _revision = revision;
    _shelf.load(key: widget.mode.name);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final recap = _shelf.latest ?? _shelf.sample;
    final latest = _shelf.latest;
    return Semantics(
      button: true,
      label: 'RECAP',
      child: RecapPressable(
        onTap: () => Navigator.of(context).push(
          CupertinoPageRoute<void>(
            builder: (context) => RecapHomeView(taste: widget.taste, mode: widget.mode, onBack: () => Navigator.of(context).pop()),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: ShapeDecoration(
            color: TegnalColors.secondaryBackground.resolveFrom(context),
            shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 36,
                height: 48,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: recap == null
                      ? ColoredBox(color: SystemColors.indigo.resolveFrom(context).withValues(alpha: 0.14))
                      : RecapCoverArt(palette: _shelf.palette(recap), seed: recap.coverSeed),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('RECAP', style: RecapType.display(16, color: TegnalColors.label.resolveFrom(context))),
                    if (latest != null) ...[
                      const SizedBox(height: 1),
                      Text(
                        RecapFormat.title(latest),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TegnalType.style(12, color: TegnalColors.secondaryLabel.resolveFrom(context)),
                      ),
                    ],
                    if (latest == null && _shelf.sample != null) ...[
                      const SizedBox(height: 1),
                      Text(
                        L10n.text('Recap is not ready yet'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TegnalType.style(12, color: TegnalColors.secondaryLabel.resolveFrom(context)),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(CupertinoIcons.chevron_right, size: 12, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
            ],
          ),
        ),
      ),
    );
  }
}
