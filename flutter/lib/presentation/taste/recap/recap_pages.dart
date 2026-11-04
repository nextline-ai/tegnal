import 'dart:async';
import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../../core/support/l10n.dart';
import '../../../core/taste/recap_shelf.dart';
import '../../../core/taste/taste_models.dart';
import '../../../core/taste/taste_recap.dart';
import '../../design/tegnal_theme.dart';
import 'recap_artwork.dart';
import 'recap_cover.dart';
import 'recap_cover_art.dart';
import 'recap_style.dart';

/// What a page can ask the story to do.
class RecapActions {
  const RecapActions({
    required this.openWork,
    required this.openTag,
    required this.search,
    required this.showSaved,
    required this.share,
    required this.replay,
    required this.close,
  });
  final void Function(RecapWork work) openWork;
  final void Function(RecapTag tag) openTag;
  final void Function(String query, String source) search;
  final VoidCallback showSaved;
  final VoidCallback share;
  final VoidCallback replay;
  final VoidCallback close;
}

String _grouped(int value) => '$value'.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

/// Fades and lifts into place when the page opens, each line a beat after the last.
class _Rise extends StatefulWidget {
  const _Rise(this.order, this.child);
  final int order;
  final Widget child;

  @override
  State<_Rise> createState() => _RiseState();
}

class _RiseState extends State<_Rise> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(Duration(milliseconds: widget.order * 90 + 100), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final value = Curves.easeOutBack.transform(_controller.value).clamp(0.0, 1.1);
        return Opacity(
          opacity: _controller.value,
          child: Transform.translate(offset: Offset(0, still ? 0 : (1 - value) * 22), child: child),
        );
      },
      child: widget.child,
    );
  }
}

/// `RecapCount`: rolls up to its value when the page opens. Reduced motion lands on it at once.
class _Count extends StatelessWidget {
  const _Count(this.value, this.style);
  final int value;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return Text(_grouped(value), style: style, maxLines: 1);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value.toDouble()),
      duration: const Duration(milliseconds: 1300),
      curve: const Interval(0.15, 1, curve: Curves.easeOut),
      builder: (context, shown, _) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(_grouped(shown.round()), style: style, maxLines: 1),
      ),
    );
  }
}

class _Eyebrow extends StatelessWidget {
  const _Eyebrow(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(text.toUpperCase(), style: RecapType.folio(12, color: color, letterSpacing: 1.4)),
  );
}

/// `RecapButton`: a capsule action, in the issue's accent or a quiet glass.
class RecapButton extends StatelessWidget {
  const RecapButton({super.key, required this.title, required this.icon, required this.palette, required this.onPressed, this.prominent = true});
  final String title;
  final IconData icon;
  final bool prominent;
  final RecapPalette palette;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final foreground = prominent ? palette.paperInkColor : const Color(0xFFFFFFFF);
    return Semantics(
      button: true,
      enabled: onPressed != null,
      child: GestureDetector(
        onTap: onPressed,
        child: Opacity(
          opacity: onPressed == null ? 0.4 : 1,
          child: Container(
            constraints: const BoxConstraints(minHeight: 46),
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: ShapeDecoration(color: prominent ? palette.accentColor : const Color(0x24FFFFFF), shape: const StadiumBorder()),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: foreground),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TegnalType.style(15, weight: FontWeight.w600, color: foreground),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `RecapPageView`: one page of an issue, laid out for its kind.
class RecapPageView extends StatefulWidget {
  const RecapPageView({super.key, required this.page, required this.recap, required this.palette, required this.safeArea, required this.actions});

  final RecapPage page;
  final TasteRecap recap;
  final RecapPalette palette;
  final EdgeInsets safeArea;
  final RecapActions actions;

  @override
  State<RecapPageView> createState() => _RecapPageViewState();
}

class _RecapPageViewState extends State<RecapPageView> {
  bool _revealed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _revealed = true);
    });
  }

  TasteRecap get recap => widget.recap;
  RecapPalette get palette => widget.palette;
  RecapActions get actions => widget.actions;
  String get periodWord => L10n.text(recap.period == TastePeriod.week ? 'this week' : 'this issue');
  double get top => widget.safeArea.top + 72;
  double get bottom => math.max(widget.safeArea.bottom, 12) + 54;

  static const white = Color(0xFFFFFFFF);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      final unit = math.min(size.width / 390, size.height / 760);
      return DefaultTextStyle(
        style: TegnalType.style(17, color: white),
        child: SizedBox.fromSize(size: size, child: _content(unit, size)),
      );
    },
  );

  Widget _content(double unit, Size size) => switch (widget.page) {
    RecapPage.cover => _cover(),
    RecapPage.numbers => _numbers(unit, size),
    RecapPage.chart => _chart(unit),
    RecapPage.person => _person(unit),
    RecapPage.palette => _swatches(unit, size),
    RecapPage.discovery => _discovery(unit),
    RecapPage.rhythm => _rhythm(unit),
    RecapPage.time => _time(unit),
    RecapPage.year => _year(unit),
    RecapPage.favorite => _favorite(unit),
    RecapPage.rediscover => _rediscover(unit),
    RecapPage.persona => _persona(unit),
    RecapPage.next => _next(unit),
  };

  Widget _tile(RecapWork? work, {bool large = false, int seed = 3}) =>
      RecapArtTile(work: work, palette: palette, large: large, generated: recap.isSample, seed: seed);

  Widget _rounded(Widget child, double radius, {Color? border}) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: border == null
        ? child
        : Stack(
            fit: StackFit.expand,
            children: [
              child,
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(color: border),
                ),
              ),
            ],
          ),
  );

  Widget _gradient(List<Color> colors, List<double> stops) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: colors, stops: stops),
    ),
  );

  Widget _cover() {
    final art = AnimatedScale(
      scale: _revealed ? 1 : 1.08,
      duration: const Duration(milliseconds: 2400),
      curve: Curves.easeOut,
      child: RecapCoverArt(palette: palette, seed: recap.coverSeed),
    );
    return Stack(
      alignment: Alignment.bottomCenter,
      children: [
        RecapCoverLayout(
          recap: recap,
          palette: palette,
          note: recap.hasActivity ? recap.editorNote?.text : null,
          insets: EdgeInsets.only(top: widget.safeArea.top + 44, bottom: math.max(widget.safeArea.bottom, 12) + 30),
          background: art,
        ),
        if (!recap.hasActivity)
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 132),
            child: Text(
              L10n.text('No saved works in this period. Try the previous period to see earlier activity.'),
              style: TegnalType.style(15, color: white),
            ),
          ),
      ],
    );
  }

  Widget _stat(int value, String title) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        _grouped(value),
        style: RecapType.display(26, weight: FontWeight.w700, color: white),
      ),
      const SizedBox(height: 2),
      Text(L10n.text(title), style: TegnalType.style(12, color: white.withValues(alpha: 0.72))),
    ],
  );

  Widget _numbers(double unit, Size size) {
    final side = (size.width + 60) / 5;
    final works = recap.saved.take(24).toList();
    final ink = palette.inkColor;
    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: ink)),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: size.height * 0.56,
          child: ClipRect(
            child: Stack(
              children: [
                Positioned(
                  left: -30,
                  top: -24,
                  child: Transform.rotate(
                    angle: -7 * math.pi / 180,
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final (position, work) in works.indexed)
                          SizedBox(
                            width: side,
                            height: side * 1.3,
                            child: AnimatedOpacity(
                              opacity: _revealed ? 1 : 0,
                              duration: Duration(milliseconds: 550 + position * 25),
                              child: AnimatedScale(
                                scale: _revealed ? 1 : 0.86,
                                duration: Duration(milliseconds: 550 + position * 25),
                                curve: Curves.easeOutBack,
                                child: _rounded(_tile(work, seed: position), 6),
                              ),
                            ),
                          ),
                      ].take(24).toList(),
                    ),
                  ),
                ),
                Positioned.fill(child: _gradient([ink.withValues(alpha: 0.1), ink], const [0, 1])),
              ],
            ),
          ),
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: bottom + 18,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _Rise(0, _Eyebrow(L10n.text('You saved %@', [periodWord]), palette.accentColor)),
              SizedBox(height: 8 * unit),
              _Rise(1, _Count(recap.saves, RecapType.display(132 * unit, color: white))),
              SizedBox(height: 8 * unit),
              _Rise(
                2,
                Row(
                  children: [
                    Text(
                      L10n.text(recap.mode == TasteMode.booru ? 'recap.unit.images' : 'recap.unit.works'),
                      style: RecapType.display(26 * unit, weight: FontWeight.w600, color: white),
                    ),
                    const SizedBox(width: 8),
                    if ((recap.offset < 0 || recap.previousSaves > 0) && recap.saves != recap.previousSaves)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: const ShapeDecoration(color: Color(0x24FFFFFF), shape: StadiumBorder()),
                        child: Text(
                          L10n.text('%@ vs last period', [RecapFormat.signed(recap.saves - recap.previousSaves)]),
                          style: TegnalType.style(13 * unit, weight: FontWeight.w600, color: white),
                        ),
                      ),
                  ],
                ),
              ),
              _Rise(
                3,
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 10 * unit + 8 * unit),
                  child: Container(height: 1, color: white.withValues(alpha: 0.28)),
                ),
              ),
              _Rise(
                4,
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _stat(recap.opens, 'Opened'),
                    const Spacer(),
                    _stat(recap.searches, 'Searches'),
                    const Spacer(),
                    _stat(recap.activeDays, 'Active days'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Popular tags share works, so each row claims one the rows above have not used.
  Map<String, RecapWork> _thumbnails(List<RecapTag> rows) {
    final used = <String>{}, result = <String, RecapWork>{};
    for (final tag in rows) {
      final works = recap.saved.where((work) => tag.works.contains(work.id)).toList();
      final work = works.where((work) => !used.contains(work.id)).firstOrNull ?? works.firstOrNull;
      if (work == null) continue;
      used.add(work.id);
      result[tag.name] = work;
    }
    return result;
  }

  Widget _chart(double unit) {
    final rows = recap.tags.take(recap.period == TastePeriod.week ? 4 : 5).toList();
    final peak = math.max(1, rows.firstOrNull?.count ?? 1);
    final thumbnails = _thumbnails(rows);
    final heading = recap.period == TastePeriod.week
        ? 'The tags that defined your week'
        : recap.period == TastePeriod.year
        ? 'The tags that defined your year'
        : 'The tags that defined your month';
    return ColoredBox(
      color: palette.inkColor,
      child: Padding(
        padding: EdgeInsets.fromLTRB(22, top, 22, bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Rise(0, _Eyebrow(L10n.text('The chart'), palette.accentColor)),
            SizedBox(height: 18 * unit),
            _Rise(
              1,
              Text(
                L10n.text(heading),
                maxLines: 3,
                style: RecapType.display(33 * unit, weight: FontWeight.w800, color: white),
              ),
            ),
            SizedBox(height: 18 * unit),
            for (final (position, tag) in rows.indexed) ...[
              if (position > 0) SizedBox(height: 8 * unit),
              _Rise(
                position + 2,
                GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => actions.openTag(tag), child: _chartRow(tag, peak, unit, thumbnails[tag.name])),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _chartRow(RecapTag tag, int peak, double unit, RecapWork? work) {
    final accent = palette.accentColor;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: 82 * unit),
      child: Row(
        children: [
          SizedBox(
            width: 62 * unit,
            height: 82 * unit,
            child: _rounded(_tile(work, seed: tag.rank), 8),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 34 * unit,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text('${tag.rank}', style: RecapType.display(40 * unit, color: tag.rank == 1 ? accent : white)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Expanded(
                      child: Text(
                        RecapText.tag(tag.name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TegnalType.style(18 * unit, weight: FontWeight.w700, color: white),
                      ),
                    ),
                    const SizedBox(width: 4),
                    _movement(tag),
                    const SizedBox(width: 6),
                    Text('${tag.count}', style: RecapType.folio(13, color: white.withValues(alpha: 0.8))),
                  ],
                ),
                const SizedBox(height: 6),
                LayoutBuilder(
                  builder: (context, constraints) => Stack(
                    children: [
                      Container(
                        height: 4,
                        decoration: const ShapeDecoration(color: Color(0x21FFFFFF), shape: StadiumBorder()),
                      ),
                      AnimatedContainer(
                        duration: Duration(milliseconds: 800 + tag.rank * 70),
                        curve: Curves.easeOutCubic,
                        width: _revealed ? constraints.maxWidth * tag.count / peak : 0,
                        height: 4,
                        decoration: ShapeDecoration(color: tag.rank == 1 ? accent : white.withValues(alpha: 0.7), shape: const StadiumBorder()),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _movement(RecapTag tag) {
    if (tag.isNew) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: ShapeDecoration(color: palette.accentColor, shape: const StadiumBorder()),
        child: Text(L10n.text('NEW'), style: RecapType.folio(10, color: palette.paperInkColor)),
      );
    }
    final change = tag.movement;
    if (change == null || change == 0) return const SizedBox.shrink();
    final color = change > 0 ? palette.accentColor : white.withValues(alpha: 0.55);
    return Semantics(
      label: L10n.text(change > 0 ? 'Up %@' : 'Down %@', ['${change.abs()}']),
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(change > 0 ? CupertinoIcons.arrow_up : CupertinoIcons.arrow_down, size: 11, color: color),
          const SizedBox(width: 2),
          Text('${change.abs()}', style: RecapType.folio(11, color: color)),
        ],
      ),
    );
  }

  List<RecapWork> _artworks(List<String> keys) => [for (final key in keys) ?recap.work(key)];

  String _query(RecapPerson person) {
    final name = person.name.replaceAll(' ', '_');
    return recap.mode == TasteMode.comics ? '${person.role.name}:$name' : name;
  }

  String _source(RecapPerson person) {
    final first = person.works.firstOrNull;
    return first == null ? '' : recap.work(first)?.item.source ?? '';
  }

  Widget _person(double unit) {
    final lead = recap.person(RecapRole.artist) ?? recap.people.first;
    final works = _artworks(lead.works);
    final ink = palette.inkColor;
    final role = switch (lead.role) {
      RecapRole.artist => 'Artist of the issue',
      RecapRole.series => 'Series of the issue',
      RecapRole.character => 'Character of the issue',
    };
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedScale(
          scale: _revealed ? 1.06 : 1,
          duration: const Duration(seconds: 8),
          curve: Curves.easeOut,
          child: _tile(works.firstOrNull, large: true, seed: 11),
        ),
        _gradient([ink.withValues(alpha: 0.5), ink.withValues(alpha: 0), ink], const [0, 0.3, 0.82]),
        Positioned(
          left: 24,
          right: 24,
          bottom: bottom + 6,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _Rise(
                0,
                Row(
                  children: [
                    for (final work in works.skip(1).take(3)) ...[
                      SizedBox(
                        width: 64 * unit,
                        height: 86 * unit,
                        child: _rounded(_tile(work), 8, border: white.withValues(alpha: 0.45)),
                      ),
                      const SizedBox(width: 6),
                    ],
                  ],
                ),
              ),
              SizedBox(height: 10 * unit),
              _Rise(1, _Eyebrow(L10n.text(role), palette.accentColor)),
              SizedBox(height: 10 * unit),
              _Rise(2, Text(RecapText.capitalized(RecapText.tag(lead.name)), maxLines: 2, style: RecapType.display(46 * unit, color: white))),
              SizedBox(height: 10 * unit),
              _Rise(
                3,
                Text(
                  L10n.text('%@ works saved %@', [_grouped(lead.count), periodWord]),
                  style: TegnalType.style(17 * unit, weight: FontWeight.w500, color: white.withValues(alpha: 0.86)),
                ),
              ),
              SizedBox(height: 10 * unit + 6),
              _Rise(
                4,
                RecapButton(
                  title: L10n.text('See more'),
                  icon: CupertinoIcons.search,
                  palette: palette,
                  onPressed: recap.isSample ? null : () => actions.search(_query(lead), _source(lead)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _swatches(double unit, Size size) {
    const weights = [0.34, 0.24, 0.18, 0.14, 0.1];
    final ink = palette.inkColor;
    return Stack(
      fit: StackFit.expand,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (position, swatch) in palette.swatches.take(5).indexed)
              AnimatedContainer(
                duration: Duration(milliseconds: 800 + position * 80),
                curve: Curves.easeOutCubic,
                width: size.width * weights[position],
                height: _revealed ? size.height : 0,
                color: swatch.color,
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 62),
                  child: _Rise(
                    5,
                    RotatedBox(
                      quarterTurns: 3,
                      child: Text(
                        swatch.hex,
                        style: RecapType.folio(9.5, color: swatch.luminance > 0.55 ? const Color(0xB3000000) : white.withValues(alpha: 0.8)),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        _gradient([ink.withValues(alpha: 0.94), ink.withValues(alpha: 0.74), ink.withValues(alpha: 0)], const [0, 0.34, 0.52]),
        Padding(
          padding: EdgeInsets.fromLTRB(24, top, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Rise(1, _Eyebrow(L10n.text('The colors of your covers'), white)),
              SizedBox(height: 10 * unit),
              _Rise(2, Text(L10n.text('This issue was %@', [palette.moodName]), maxLines: 3, style: RecapType.display(52 * unit, color: white))),
              SizedBox(height: 10 * unit),
              _Rise(
                3,
                Text(
                  L10n.text('Measured from the covers you kept. Every issue gets its own.'),
                  style: TegnalType.style(15 * unit, weight: FontWeight.w500, color: white.withValues(alpha: 0.86)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _discovery(double unit) {
    final highlight = recap.highlights.first, tag = highlight.tag;
    final works = _artworks(tag.works).take(3).toList();
    final (heading, detail) = switch (highlight.kind) {
      RecapHighlightKind.hidden => (
        L10n.text('A new side of your taste'),
        L10n.text('You saved %@ works with this tag without searching for it, across %@ sessions.', ['${tag.hidden}', '${tag.sessions.length}']),
      ),
      RecapHighlightKind.comeback => (
        L10n.text('Back in rotation'),
        L10n.text('You had drifted away from this tag. %@ works brought it back.', ['${tag.count}']),
      ),
      RecapHighlightKind.newcomer => (
        L10n.text('New to your collection'),
        L10n.text('You had never saved this tag before. Now it has %@ works.', ['${tag.count}']),
      ),
      RecapHighlightKind.rising => (
        L10n.text('On the rise'),
        L10n.text('Saved works with this tag increased from %@ to %@.', ['${tag.previousCount}', '${tag.count}']),
      ),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topRight, end: Alignment.bottomLeft, colors: [palette.deepColor, palette.inkColor]),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, top, 24, bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Rise(0, _Eyebrow(heading, palette.accentColor)),
            SizedBox(height: 12 * unit),
            _Rise(1, Text(RecapText.tag(tag.name), maxLines: 3, style: RecapType.display(54 * unit, color: white))),
            SizedBox(height: 12 * unit),
            _Rise(
              2,
              Text(
                detail,
                style: TegnalType.style(17 * unit, weight: FontWeight.w500, color: white.withValues(alpha: 0.86)),
              ),
            ),
            const Spacer(),
            SizedBox(
              height: 222 * unit,
              width: double.infinity,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  for (final (position, work) in works.indexed)
                    Builder(
                      builder: (context) {
                        final shift = position - (works.length - 1) / 2;
                        return AnimatedSlide(
                          offset: _revealed
                              ? Offset(shift * 92 * unit / (148 * unit), shift.abs() * 12 / (200 * unit))
                              : Offset(0, shift.abs() * 12 / (200 * unit)),
                          duration: const Duration(milliseconds: 700),
                          curve: Curves.easeOutBack,
                          child: AnimatedRotation(
                            turns: _revealed ? shift * 7 / 360 : 0,
                            duration: const Duration(milliseconds: 700),
                            curve: Curves.easeOutBack,
                            child: GestureDetector(
                              onTap: () => actions.openWork(work),
                              child: Container(
                                width: 148 * unit,
                                height: 200 * unit,
                                decoration: const BoxDecoration(
                                  boxShadow: [BoxShadow(color: Color(0x59000000), blurRadius: 24, offset: Offset(0, 6))],
                                ),
                                child: _rounded(_tile(work, seed: position), 12, border: white.withValues(alpha: 0.3)),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
            const Spacer(),
            _Rise(
              4,
              RecapButton(
                title: L10n.text('Explore this tag'),
                icon: CupertinoIcons.search,
                palette: palette,
                onPressed: recap.isSample ? null : () => actions.search(tag.name, tag.source),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rhythm(double unit) {
    final streak = recap.longestStreak;
    final day = recap.busiestDay;
    return ColoredBox(
      color: palette.inkColor,
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, top, 24, bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Rise(0, _Eyebrow(L10n.text('Your rhythm'), palette.accentColor)),
            SizedBox(height: 14 * unit),
            _Rise(
              1,
              Text(
                streak >= 2 ? L10n.text('%@ days in a row', ['$streak']) : L10n.text('%@ active days', ['${recap.activeDays}']),
                maxLines: 2,
                style: RecapType.display(42 * unit, color: white),
              ),
            ),
            if (day != null) ...[
              SizedBox(height: 14 * unit),
              _Rise(
                2,
                Text(
                  L10n.text('Your busiest day was %@, with %@ works.', [RecapFormat.day(day.date), '${day.touched}']),
                  style: TegnalType.style(16 * unit, weight: FontWeight.w500, color: white.withValues(alpha: 0.86)),
                ),
              ),
            ],
            const Spacer(),
            _Rise(3, _Heatmap(recap: recap, palette: palette)),
            const Spacer(),
            _Rise(
              4,
              Row(
                children: [
                  SizedBox(
                    width: 136 * unit,
                    height: 136 * unit,
                    child: CustomPaint(painter: _ClockPainter(recap.hours, palette.accentColor)),
                  ),
                  SizedBox(width: 18 * unit),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(L10n.text('Peak hour'), style: TegnalType.style(12, color: white.withValues(alpha: 0.72))),
                        const SizedBox(height: 4),
                        Text(RecapPersonaClock.hour(recap.peakHour ?? 12), style: RecapType.display(32 * unit, color: white)),
                        const SizedBox(height: 4),
                        Text(L10n.text('The hour you were most often here.'), style: TegnalType.style(12, color: white.withValues(alpha: 0.72))),
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

  Widget _time(double unit) {
    final ink = palette.inkColor;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: ink),
        Opacity(
          opacity: 0.72,
          child: AnimatedScale(
            scale: _revealed ? 1.08 : 1,
            duration: const Duration(seconds: 8),
            curve: Curves.easeOut,
            child: _tile(recap.revisited ?? recap.saved.skip(1).firstOrNull, large: true, seed: 9),
          ),
        ),
        _gradient([ink.withValues(alpha: 0.55), ink.withValues(alpha: 0.15), ink], const [0, 0.3, 0.72]),
        Positioned(
          left: 24,
          right: 24,
          bottom: bottom + 12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _Rise(0, _Eyebrow(L10n.text('Time with your art'), palette.accentColor)),
              SizedBox(height: 12 * unit),
              _Rise(1, Text(RecapText.duration(recap.seconds), maxLines: 2, style: RecapType.display(68 * unit, color: white))),
              SizedBox(height: 12 * unit),
              _Rise(
                2,
                Text(
                  L10n.text('Time counts only while a work is on screen and you keep moving.'),
                  style: TegnalType.style(15 * unit, weight: FontWeight.w500, color: white.withValues(alpha: 0.8)),
                ),
              ),
              _Rise(
                3,
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 8 + 12 * unit),
                  child: Container(height: 1, color: white.withValues(alpha: 0.28)),
                ),
              ),
              _Rise(
                4,
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _stat(recap.pages, recap.mode == TasteMode.booru ? 'Images viewed' : 'Pages read'),
                    if (recap.mode == TasteMode.comics) ...[const SizedBox(width: 34), _stat(recap.finished, 'Finished')],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _year(double unit) {
    final peak = math.max(1, recap.months.map((month) => month.saves).fold(0, math.max));
    TasteRecapMonth? best;
    for (final month in recap.months) {
      if (best == null || month.saves > best.saves) best = month;
    }
    return ColoredBox(
      color: palette.inkColor,
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, top, 24, bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Rise(0, _Eyebrow(L10n.text('The shape of your year'), palette.accentColor)),
            SizedBox(height: 14 * unit),
            if (best != null)
              _Rise(
                1,
                Text(L10n.text('%@ was your biggest month', [RecapFormat.month(best.start)]), maxLines: 3, style: RecapType.display(40 * unit, color: white)),
              ),
            SizedBox(height: 14 * unit),
            _Rise(
              2,
              SizedBox(
                height: 270 * unit,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final (index, month) in recap.months.indexed) ...[
                      if (index > 0) const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Opacity(
                              opacity: month.saves > 0 ? 0.8 : 0,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text('${month.saves}', style: RecapType.folio(9, color: white)),
                              ),
                            ),
                            const SizedBox(height: 6),
                            AnimatedContainer(
                              duration: Duration(milliseconds: 700 + (month.saves / peak * 200).round()),
                              curve: Curves.easeOutCubic,
                              height: _revealed ? math.max(3, 210 * unit * month.saves / peak) : 3,
                              decoration: BoxDecoration(
                                color: month.start == best?.start ? palette.accentColor : white.withValues(alpha: 0.32),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                            const SizedBox(height: 6),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                RecapFormat.month(month.start).characters.take(3).toString(),
                                style: RecapType.folio(8, color: white.withValues(alpha: 0.7)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
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

  Widget _favorite(double unit) {
    final work = recap.revisited!;
    final ink = palette.inkColor;
    final title = work.info.title ?? work.info.artists.map((artist) => RecapText.capitalized(RecapText.tag(artist))).firstOrNull;
    return Stack(
      fit: StackFit.expand,
      children: [
        _tile(work, large: true, seed: 5),
        _gradient([ink.withValues(alpha: 0.55), ink.withValues(alpha: 0), ink], const [0, 0.3, 0.86]),
        Positioned(
          left: 24,
          right: 24,
          bottom: bottom + 6,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _Rise(0, _Eyebrow(L10n.text('The one you kept coming back to'), palette.accentColor)),
              if (title != null) ...[SizedBox(height: 10 * unit), _Rise(1, Text(title, maxLines: 3, style: RecapType.display(36 * unit, color: white)))],
              SizedBox(height: 10 * unit),
              _Rise(
                2,
                Text(
                  work.seconds >= 60
                      ? L10n.text('Opened %@ times · %@', ['${work.opens}', RecapText.duration(work.seconds)])
                      : L10n.text('Opened %@ times', ['${work.opens}']),
                  style: TegnalType.style(17 * unit, weight: FontWeight.w500, color: white.withValues(alpha: 0.86)),
                ),
              ),
              SizedBox(height: 10 * unit + 6),
              _Rise(
                3,
                RecapButton(
                  title: L10n.text('Open again'),
                  icon: CupertinoIcons.arrow_up_right,
                  palette: palette,
                  onPressed: recap.isSample ? null : () => actions.openWork(work),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _rediscover(double unit) {
    final works = recap.rediscover.take(4).toList();
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [palette.inkColor, palette.deepColor]),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(22, top, 22, bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Rise(0, _Eyebrow(L10n.text('From your own shelves'), palette.accentColor)),
            SizedBox(height: 14 * unit),
            _Rise(1, Text(L10n.text('Saved long ago, waiting for now'), maxLines: 3, style: RecapType.display(38 * unit, color: white))),
            SizedBox(height: 14 * unit),
            _Rise(
              2,
              Text(
                L10n.text("These match this issue's taste, and you haven't opened them in a while."),
                style: TegnalType.style(15 * unit, weight: FontWeight.w500, color: white.withValues(alpha: 0.84)),
              ),
            ),
            SizedBox(height: 14 * unit),
            for (var row = 0; row < (works.length / 2).ceil(); row++) ...[
              if (row > 0) const SizedBox(height: 10),
              Row(
                children: [
                  for (var column = 0; column < 2; column++) ...[
                    if (column > 0) const SizedBox(width: 10),
                    Expanded(
                      child: row * 2 + column < works.length
                          ? _Rise(row * 2 + column + 3, _rediscoverTile(works[row * 2 + column], row * 2 + column, unit))
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ],
            const Spacer(),
          ],
        ),
      ),
    );
  }

  Widget _rediscoverTile(RecapWork work, int position, double unit) => GestureDetector(
    onTap: () => actions.openWork(work),
    child: SizedBox(
      height: 196 * unit,
      child: _rounded(
        Stack(
          fit: StackFit.expand,
          children: [
            _tile(work, seed: position),
            if (work.info.title case final title?)
              Align(
                alignment: Alignment.bottomLeft,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x00000000), Color(0xB3000000)]),
                  ),
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TegnalType.style(12, weight: FontWeight.w600, color: white),
                  ),
                ),
              ),
          ],
        ),
        12,
      ),
    ),
  );

  Widget _persona(double unit) {
    final persona = recap.persona!;
    final ink = palette.paperInkColor;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: palette.paperColor),
        Padding(
          padding: EdgeInsets.fromLTRB(24, top, 24, bottom + 4),
          child: DefaultTextStyle(
            style: TegnalType.style(17, color: ink),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Rise(
                  0,
                  Text(L10n.text('This issue, you were').toUpperCase(), style: RecapType.folio(12, color: ink.withValues(alpha: 0.65), letterSpacing: 1.4)),
                ),
                SizedBox(height: 14 * unit),
                _Rise(1, Text(persona.title, maxLines: 3, style: RecapType.display(58 * unit, color: ink))),
                SizedBox(height: 14 * unit),
                _Rise(2, Text.rich(RecapType.italicSpan(persona.summary, RecapType.display(19 * unit, weight: FontWeight.w500, italic: true, color: ink)))),
                _Rise(
                  3,
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 6 + 14 * unit),
                    child: Container(height: 1, color: ink.withValues(alpha: 0.35)),
                  ),
                ),
                for (final (position, trait) in persona.traits.indexed) ...[
                  if (position > 0) SizedBox(height: 14 * unit),
                  _Rise(
                    position + 4,
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text((position + 1).toString().padLeft(2, '0'), style: RecapType.folio(12, color: ink.withValues(alpha: 0.55))),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            trait.text,
                            style: TegnalType.style(16 * unit, weight: FontWeight.w600, color: ink),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const Spacer(),
                _Rise(
                  6,
                  Row(
                    children: [
                      for (final (position, work) in recap.saved.take(4).indexed) ...[
                        if (position > 0) const SizedBox(width: 6),
                        Expanded(
                          child: AspectRatio(aspectRatio: 0.74, child: _rounded(_tile(work, seed: position), 8)),
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(height: 14 * unit),
                _Rise(
                  6,
                  ClipRRect(
                    borderRadius: BorderRadius.circular(5),
                    child: Row(
                      children: [for (final swatch in palette.swatches) Expanded(child: Container(height: 10, color: swatch.color))],
                    ),
                  ),
                ),
                const Spacer(),
                _Rise(
                  7,
                  Text(
                    L10n.text('Patterns describe your activity in this app. They are suggestions, not conclusions about you.'),
                    style: TegnalType.style(12, color: ink.withValues(alpha: 0.62)),
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: widget.safeArea.top + 60,
          child: IgnorePointer(child: _gradient([palette.inkColor.withValues(alpha: 0.75), palette.inkColor.withValues(alpha: 0)], const [0, 1])),
        ),
      ],
    );
  }

  Widget _next(double unit) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [palette.deepColor, palette.inkColor]),
    ),
    child: Padding(
      padding: EdgeInsets.fromLTRB(24, top, 24, math.max(widget.safeArea.bottom, 12) + 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Rise(0, _Eyebrow(L10n.text('Next issue'), palette.accentColor)),
          SizedBox(height: 14 * unit),
          _Rise(1, Text(L10n.text('Where to go from here'), maxLines: 2, style: RecapType.display(40 * unit, color: white))),
          for (final (position, tag) in recap.next.indexed)
            _Rise(
              position + 2,
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: recap.isSample ? null : () => actions.search(tag.name, tag.source),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 2),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: Color(0x42FFFFFF))),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          RecapText.tag(tag.name),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: RecapType.display(23 * unit, weight: FontWeight.w700, color: white),
                        ),
                      ),
                      const Icon(CupertinoIcons.arrow_up_right, size: 16, color: white),
                    ],
                  ),
                ),
              ),
            ),
          const Spacer(),
          _Rise(
            5,
            Center(
              child: Container(
                width: 136 * unit,
                height: 184 * unit,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(7),
                  boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 28, offset: Offset(0, 8))],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: RecapCoverLayout(
                    recap: recap,
                    palette: palette,
                    background: RecapCoverArt(palette: palette, seed: recap.coverSeed),
                  ),
                ),
              ),
            ),
          ),
          const Spacer(),
          if (recap.saved.isNotEmpty)
            _Rise(
              6,
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: actions.showSaved,
                child: SizedBox(
                  height: 44,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(CupertinoIcons.square_grid_2x2, size: 16, color: white),
                      const SizedBox(width: 6),
                      Text(
                        L10n.text('All %@ saved works', [_grouped(recap.saves)]),
                        style: TegnalType.style(15, weight: FontWeight.w600, color: white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          _Rise(
            7,
            Row(
              children: [
                Flexible(
                  child: RecapButton(title: L10n.text('Share cover'), icon: CupertinoIcons.square_arrow_up, palette: palette, onPressed: actions.share),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: RecapButton(
                    title: L10n.text('Replay'),
                    icon: CupertinoIcons.arrow_counterclockwise,
                    prominent: false,
                    palette: palette,
                    onPressed: actions.replay,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _Rise(8, RecapButton(title: L10n.text('Done'), icon: CupertinoIcons.checkmark_alt, prominent: false, palette: palette, onPressed: actions.close)),
        ],
      ),
    ),
  );
}

/// `RecapHeatmap`: calendar-shaped for a week or month; a year reads as twelve rows of days.
class _Heatmap extends StatelessWidget {
  const _Heatmap({required this.recap, required this.palette});
  final TasteRecap recap;
  final RecapPalette palette;

  List<RecapDay?> get _monthCells {
    final first = recap.days.firstOrNull;
    if (first == null) return [];
    final lead = (first.date.weekday - 1) % 7;
    return [...List<RecapDay?>.filled(lead, null), ...recap.days];
  }

  List<RecapDay?> get _yearCells {
    final byDay = {for (final day in recap.days) DateTime(day.date.year, day.date.month, day.date.day): day};
    final start = recap.interval.start;
    final result = <RecapDay?>[];
    for (var month = 0; month < 12; month++) {
      final first = DateTime(start.year, start.month + month);
      for (var day = 0; day < 31; day++) {
        final date = DateTime(first.year, first.month, day + 1);
        if (date.month != first.month) {
          result.add(null);
          continue;
        }
        result.add(byDay[date] ?? RecapDay(date));
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final year = recap.period == TastePeriod.year;
    final peak = math.max(1, recap.days.map((day) => day.touched).fold(0, math.max));
    final columns = year ? 31 : 7;
    final spacing = year ? 2.0 : 4.0;
    final cells = year ? _yearCells : _monthCells;
    final accent = palette.accentColor;
    return Semantics(
      label: L10n.text('%@ active days', ['${recap.activeDays}']),
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = (constraints.maxWidth - spacing * (columns - 1)) / columns;
          final height = year ? side : side / 1.2;
          return Wrap(
            spacing: spacing,
            runSpacing: spacing,
            children: [
              for (final day in cells)
                Container(
                  width: side,
                  height: height,
                  decoration: day == null
                      ? null
                      : BoxDecoration(
                          borderRadius: BorderRadius.circular(year ? 1.5 : 4),
                          color: day.touched == 0 ? const Color(0x17FFFFFF) : accent.withValues(alpha: 0.32 + 0.68 * day.touched / peak),
                        ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// `RecapClock`: the day's 24 hours as spokes, longer where the person was here more.
class _ClockPainter extends CustomPainter {
  _ClockPainter(this.hours, this.accent);
  final List<int> hours;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final peak = math.max(1, hours.fold(0, math.max)).toDouble();
    final center = size.center(Offset.zero), radius = math.min(size.width, size.height) / 2;
    for (var hour = 0; hour < 24; hour++) {
      final angle = hour / 24 * math.pi * 2 - math.pi / 2, value = hours[hour] / peak;
      final inner = radius * 0.42, outer = inner + (radius - inner) * math.max(0.06, value);
      canvas.drawLine(
        center + Offset(math.cos(angle) * inner, math.sin(angle) * inner),
        center + Offset(math.cos(angle) * outer, math.sin(angle) * outer),
        Paint()
          ..color = value > 0 ? accent.withValues(alpha: 0.45 + value * 0.55) : const Color(0x24FFFFFF)
          ..strokeWidth = math.max(3, radius * 0.075)
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_ClockPainter old) => old.hours != hours || old.accent != accent;
}
