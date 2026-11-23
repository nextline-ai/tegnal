import 'dart:math' as math;
import 'dart:async';
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';

import '../../core/lab/lab_course.dart';
import '../../core/lab/lab_sheet.dart';
import '../../core/lab/lab_store.dart';
import '../../core/support/l10n.dart';
import '../design/alert_dialog.dart';
import '../design/app_sheet.dart';
import '../design/glass.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';
import '../study_mode/study_kit.dart';
import 'lab_episode_view.dart';
import 'lab_kit.dart';

// The cheat sheet, the 망작 gallery, the shop and the diagnosis. Ported from `LabPages.swift`.

/// Room under a tab's content for the floating dock.
const double labDockClearance = 110;

// MARK: - Cheat sheet

/// The cheat sheet: one sheet of paper, swapped whenever the field changes. Cards 001 and 004 open its sections.
class LabSheetView extends StatefulWidget {
  const LabSheetView({super.key, required this.shown});

  /// True while the sheet's tab is the one on screen; reading it then pays once per edition. It changes after the page is
  /// built, so it is followed rather than passed once.
  final ValueListenable<bool> shown;

  @override
  State<LabSheetView> createState() => _LabSheetViewState();
}

class _LabSheetViewState extends State<LabSheetView> {
  int paid = 0;
  LabStore get store => LabStore.shared;

  @override
  void initState() {
    super.initState();
    widget.shown.addListener(_later);
    _later();
  }

  @override
  void dispose() {
    widget.shown.removeListener(_later);
    super.dispose();
  }

  void _later() => WidgetsBinding.instance.addPostFrameCallback((_) => _readIfShown());

  void _readIfShown() {
    if (!widget.shown.value || !mounted) return;
    final amount = store.read();
    if (amount > 0) setState(() => paid = amount);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final edition = store.edition;
      return CustomScrollView(
        slivers: [
          CupertinoSliverRefreshControl(
            onRefresh: () async {
              final next = await LabSheetSource.fetch();
              if (next != null) store.show(next);
              _readIfShown();
            },
          ),
          SliverSafeArea(
            bottom: false,
            sliver: SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, labDockClearance),
              sliver: SliverList.list(
                children: [
                  LabHeader(
                    kicker: TextSpan(text: L10n.text('lab.sheet.subtitle')),
                    title: L10n.text('lab.tab.sheet'),
                  ),
                  // What reading a new edition paid, where it is seen at once.
                  AnimatedSize(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    child: paid > 0
                        ? Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: LabTag(
                                key: const Key('lab.sheet.paid'),
                                text: L10n.text('lab.sheet.paid', ['$paid', store.shop.currency.text]),
                                color: LabPalette.gauge.resolveFrom(context),
                              ),
                            ),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                  const SizedBox(height: 18),
                  if (edition != null)
                    LabSheetPaper(edition: edition)
                  else
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 80),
                      child: Text(
                        L10n.text('lab.sheet.none'),
                        textAlign: TextAlign.center,
                        style: LabFont.text(17, weight: FontWeight.w600, color: labSecondary(context)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// The sheet itself, printed on paper: a masthead with the date stamp and what changed, a numbered section for each
/// family of jobs, and the footer under a double rule. A section no card has opened yet is shown blacked out.
class LabSheetPaper extends StatelessWidget {
  const LabSheetPaper({super.key, required this.edition});
  final LabEdition edition;

  static const ink = LabPalette.paperInk;
  static const muted = LabPalette.paperMuted;
  LabStore get store => LabStore.shared;

  @override
  Widget build(BuildContext context) => LabCardBackground(
    state: LabCardState.blank,
    radius: 22,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _masthead(),
          for (final (index, section) in edition.sections.indexed)
            Padding(padding: const EdgeInsets.only(top: 30), child: _section(context, index + 1, section)),
          if (edition.footer case final footer?)
            Padding(
              padding: const EdgeInsets.only(top: 30),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(height: 0.5, color: ink),
                  const SizedBox(height: 2),
                  Container(height: 2, color: ink),
                  const SizedBox(height: 12),
                  Text(labWords(footer.text), style: LabFont.line(14, color: muted)),
                ],
              ),
            ),
        ],
      ),
    ),
  );

  Widget _masthead() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('AI LAB · CHEAT SHEET', style: LabFont.number(10, color: muted, tracking: 1.8)),
                if (edition.change case final change?) ...[const SizedBox(height: 6), Text(change.text, style: LabFont.line(16, color: ink))],
              ],
            ),
          ),
          const SizedBox(width: 12),
          _stamp(),
        ],
      ),
      const SizedBox(height: 16),
      Container(height: 2, color: ink),
    ],
  );

  /// A rubber stamp in red ink: the day this sheet was curated.
  Widget _stamp() {
    const red = Color(0xFFB3392B);
    return Semantics(
      key: const Key('lab.sheet.stamp'),
      label: L10n.text('lab.sheet.stamp', [edition.stamp]),
      child: ExcludeSemantics(
        child: Opacity(
          opacity: 0.88,
          child: Transform.rotate(
            angle: -5 * 3.14159 / 180,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                border: Border.all(color: red, width: 0.8),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  border: Border.all(color: red, width: 1.6),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Column(
                  children: [
                    Text(
                      L10n.text('lab.sheet.basis'),
                      style: LabFont.text(10, weight: FontWeight.w800, color: red, tracking: 1.2),
                    ),
                    const SizedBox(height: 2),
                    Text(edition.stamp, style: LabFont.number(14, color: red)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _section(BuildContext context, int number, LabSheetSection section) {
    final opened = store.sectionOpened(section);
    final card = section.opens == null ? null : store.course.episode(section.opens!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(number.toString().padLeft(2, '0'), style: LabFont.number(14, color: muted)),
            const SizedBox(width: 10),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(labWords(section.title.text), style: LabFont.voice(21, color: ink)),
              ),
            ),
          ],
        ),
        if (card != null && opened) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(CupertinoIcons.lock_open_fill, size: 12, color: muted),
              const SizedBox(width: 6),
              Text(
                '${L10n.text('lab.card.number', [card.digits])} · ${card.label}',
                style: LabFont.text(12, weight: FontWeight.w600, color: muted),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        Container(height: 1, color: ink),
        if (opened)
          Column(
            key: Key('lab.sheet.section.${section.id}'),
            children: [
              for (final (index, row) in section.rows.indexed) ...[
                if (index > 0) Container(height: 0.5, color: LabPalette.paperRule.withValues(alpha: 0.4)),
                _row(row),
              ],
            ],
          )
        else
          _blackedOut(section, card),
      ],
    );
  }

  Widget _row(LabSheetRow row) {
    final job = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          studyWords(row.task.text),
          style: LabFont.text(17, weight: FontWeight.w700, color: ink),
        ),
        if (row.example case final example?) ...[const SizedBox(height: 2), Text(studyWords(example.text), style: LabFont.text(13, color: muted))],
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The pick sits beside the job when there is room, under it when there is not.
          LayoutBuilder(
            builder: (context, constraints) {
              final tag = _pick(row);
              final tagWidth = _tagWidth(row);
              if (tagWidth + 12 + 120 <= constraints.maxWidth) {
                return Row(
                  children: [
                    Expanded(child: job),
                    const SizedBox(width: 12),
                    tag,
                  ],
                );
              }
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [job, const SizedBox(height: 8), tag]);
            },
          ),
          if (row.why case final why?) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 3),
                  child: Icon(CupertinoIcons.arrow_turn_down_right, size: 12, color: muted),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(studyWords(why.text), style: LabFont.text(14, color: ink.withValues(alpha: 0.78))),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  double _tagWidth(LabSheetRow row) {
    final painter = TextPainter(
      text: TextSpan(
        text: row.pick,
        style: LabFont.text(15, weight: FontWeight.w700),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final draft = row.draft == true
        ? (TextPainter(
                text: TextSpan(
                  text: L10n.text('lab.sheet.draft'),
                  style: LabFont.text(10, weight: FontWeight.w800),
                ),
                textDirection: TextDirection.ltr,
              )..layout()).width +
              6
        : 0;
    return painter.width + draft + 26;
  }

  /// The pick on a tag: solid ink once settled; a pencilled outline, marked as a draft, while it is not.
  Widget _pick(LabSheetRow row) {
    final draft = row.draft == true;
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (draft) ...[
          Text(
            L10n.text('lab.sheet.draft'),
            style: LabFont.text(10, weight: FontWeight.w800, color: muted),
          ),
          const SizedBox(width: 6),
        ],
        Text(
          row.pick,
          maxLines: 1,
          style: LabFont.text(15, weight: FontWeight.w700, color: draft ? ink : LabPalette.paper),
        ),
      ],
    );
    return SizedBox(
      height: 32,
      child: draft
          ? CustomPaint(
              painter: _DashedCapsule(ink.withValues(alpha: 0.55)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 13),
                child: Center(widthFactor: 1, child: content),
              ),
            )
          : DecoratedBox(
              decoration: const ShapeDecoration(color: ink, shape: StadiumBorder()),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 13),
                child: Center(widthFactor: 1, child: content),
              ),
            ),
    );
  }

  /// A section not opened yet: its rows blacked out, and the card that opens it.
  Widget _blackedOut(LabSheetSection section, LabEpisode? card) {
    const widths = [(104.0, 150.0), (78.0, 118.0), (124.0, 168.0), (92.0, 134.0)];
    final text = L10n.text('lab.sheet.locked', [card?.digits ?? '']);
    return Semantics(
      key: Key('lab.sheet.locked.${section.id}'),
      label: text,
      child: ExcludeSemantics(
        child: Stack(
          alignment: Alignment.center,
          children: [
            Opacity(
              opacity: 0.35,
              child: Column(
                children: [
                  for (final (index, _) in section.rows.indexed) ...[
                    if (index > 0) Container(height: 0.5, color: LabPalette.paperRule.withValues(alpha: 0.4)),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Row(
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [_bar(widths[index % 4].$1, 13, 0.75), const SizedBox(height: 7), _bar(widths[index % 4].$2, 9, 0.3)],
                          ),
                          const Spacer(),
                          _bar(76, 28, 0.75),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: ShapeDecoration(
                color: LabPalette.paper,
                shape: StadiumBorder(side: BorderSide(color: ink.withValues(alpha: 0.25))),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(CupertinoIcons.lock_fill, size: 14, color: ink),
                  const SizedBox(width: 6),
                  Text(
                    text,
                    style: LabFont.text(14, weight: FontWeight.w700, color: ink),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bar(double width, double height, double alpha) => Container(
    width: width,
    height: height,
    decoration: ShapeDecoration(
      color: ink.withValues(alpha: alpha),
      shape: const StadiumBorder(),
    ),
  );
}

class _DashedCapsule extends CustomPainter {
  _DashedCapsule(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(0.6);
    final path = Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final metric in path.computeMetrics()) {
      for (var distance = 0.0; distance < metric.length; distance += 7) {
        canvas.drawPath(metric.extractPath(distance, distance + 4), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedCapsule old) => old.color != color;
}

// MARK: - The gallery of 망작

/// Every trap's 망작, framed once it has been pressed. Traps not yet pressed are empty frames that call the learner back.
class LabFailsView extends StatelessWidget {
  const LabFailsView({super.key});
  LabStore get store => LabStore.shared;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final fails = store.course.fails;
      final hung = fails.where(store.hung).length;
      return CustomScrollView(
        slivers: [
          SliverSafeArea(
            bottom: false,
            sliver: SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, labDockClearance),
              sliver: SliverMainAxisGroup(
                slivers: [
                  SliverToBoxAdapter(
                    child: LabHeader(
                      kicker: TextSpan(text: L10n.text('lab.fails.subtitle')),
                      title: L10n.text('lab.fails.title'),
                      trailing: Text.rich(
                        key: const Key('lab.fails.count'),
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '$hung',
                              style: LabFont.number(20, color: LabPalette.fail.resolveFrom(context)),
                            ),
                            TextSpan(
                              text: '/${fails.length}',
                              style: LabFont.number(20, color: labSecondary(context)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 20)),
                  SliverGrid.builder(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 18,
                      crossAxisSpacing: 14,
                      mainAxisExtent: 214,
                    ),
                    itemCount: fails.length,
                    itemBuilder: (context, index) {
                      final fail = fails[index];
                      return store.hung(fail)
                          ? LabPress(key: Key('lab.fail.${fail.id}'), onTap: () => _open(context, fail), child: _frame(context, fail))
                          : _empty(context, fail);
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );

  void _open(BuildContext context, LabFail fail) => showAppSheet<void>(
    context,
    medium: true,
    grabber: true,
    builder: (sheetContext, controller) => LabFailSheet(fail: fail, controller: controller),
  );

  Widget _frame(BuildContext context, LabFail fail) => LabFailFrame(fail: fail);

  Widget _empty(BuildContext context, LabFail fail) {
    final episode = store.course.episode(fail.episode);
    final locked = episode == null || store.state(episode) == LabCardStatus.locked;
    final secondary = labSecondary(context);
    return Semantics(
      key: Key('lab.fail.empty.${fail.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 138,
            width: double.infinity,
            child: CustomPaint(
              painter: _DashedFrame(secondary.withValues(alpha: 0.4)),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(locked ? CupertinoIcons.lock : CupertinoIcons.question, size: 18, color: secondary),
                  const SizedBox(height: 6),
                  Text(
                    L10n.text('lab.fails.empty'),
                    style: LabFont.text(12, weight: FontWeight.w600, color: secondary),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            L10n.text(locked ? 'lab.card.locked' : 'lab.fails.waiting'),
            style: LabFont.text(14, weight: FontWeight.w700, color: secondary),
          ),
          Text(
            '${L10n.text('lab.card.number', [episode?.digits ?? ''])}${episode == null ? '' : ' · ${episode.label}'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: LabFont.number(11, weight: FontWeight.w500, color: secondary),
          ),
        ],
      ),
    );
  }
}

class _DashedFrame extends CustomPainter {
  _DashedFrame(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addRRect(RRect.fromRectAndRadius((Offset.zero & size).deflate(0.6), const Radius.circular(4)));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final metric in path.computeMetrics()) {
      for (var distance = 0.0; distance < metric.length; distance += 9) {
        canvas.drawPath(metric.extractPath(distance, distance + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedFrame old) => old.color != color;
}

/// A 망작 up close: what was asked, what came back, and the episode to play again.
class LabFailSheet extends StatelessWidget {
  const LabFailSheet({super.key, required this.fail, required this.controller});
  final LabFail fail;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final store = LabStore.shared;
    final episode = store.course.episode(fail.episode);
    return Stack(
      children: [
        ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 64, 20, 32),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: LabTag(text: 'No. ${store.number(fail).toString().padLeft(2, '0')}', color: LabPalette.fail.resolveFrom(context), mono: true),
            ),
            const SizedBox(height: 14),
            Text(labWords(fail.name.text), style: LabFont.voice(26, color: labLabel(context))),
            const SizedBox(height: 14),
            LabBubble(text: fail.choice.text, mine: true),
            const SizedBox(height: 14),
            LabBubble(text: fail.reply.text),
            if (episode != null) ...[
              const SizedBox(height: 22),
              LabButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  showLabEpisode(context, episode);
                },
                expand: true,
                child: Text(L10n.text('lab.card.again')),
              ),
            ],
          ],
        ),
        Positioned(
          right: 16,
          top: 14,
          child: Semantics(
            button: true,
            label: L10n.text('Close'),
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Glass.circle(
                elevated: true,
                child: SizedBox.square(dimension: 44, child: Icon(CupertinoIcons.xmark, size: 18, color: labLabel(context))),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// MARK: - Shop

/// The shop: what 연구비 buys, as square cards.
class LabShopView extends StatelessWidget {
  const LabShopView({super.key, required this.openTags, this.controller});
  final VoidCallback openTags;

  /// The scroll controller of the sheet the shop is shown in, from the 2D AI course's 연구비 counter.
  final ScrollController? controller;
  LabStore get store => LabStore.shared;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) => CustomScrollView(
      controller: controller,
      slivers: [
        SliverSafeArea(
          bottom: false,
          sliver: SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, labDockClearance),
            sliver: SliverMainAxisGroup(
              slivers: [
                SliverToBoxAdapter(
                  child: LabHeader(
                    kicker: TextSpan(text: L10n.text('lab.shop.subtitle')),
                    title: L10n.text('lab.tab.shop'),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 22)),
                SliverToBoxAdapter(child: _balance(context)),
                for (final section in store.shop.sections) ...[
                  const SliverToBoxAdapter(child: SizedBox(height: 22)),
                  SliverToBoxAdapter(
                    child: Semantics(
                      header: true,
                      child: Text(
                        section.title.text,
                        style: LabFont.text(20, weight: FontWeight.w700, color: labLabel(context)),
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 10)),
                  SliverGrid.count(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    children: [for (final item in section.items) _card(context, item)],
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _balance(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: ShapeDecoration(
      color: LabPalette.surface(context),
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(22)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text(
                store.shop.currency.text,
                style: LabFont.text(15, weight: FontWeight.w600, color: labLabel(context)),
              ),
            ),
            TweenAnimationBuilder<double>(
              tween: Tween(end: store.balance.toDouble()),
              duration: const Duration(milliseconds: 500),
              builder: (context, value, _) => Text(
                '${value.round()}',
                key: const Key('lab.shop.balance'),
                style: LabFont.number(34, color: labLabel(context)),
              ),
            ),
          ],
        ),
        if (store.shop.note case final note?) ...[const SizedBox(height: 6), Text(note.text, style: LabFont.text(13, color: labSecondary(context)))],
      ],
    ),
  );

  /// One thing for sale: a square card with its symbol, name, what it is and its price tag.
  Widget _card(BuildContext context, LabShopItem item) {
    final state = store.canBuy(item);
    final owned = store.owns(item.id) && !item.isRepeat;
    final note = owned
        ? L10n.text('lab.shop.owned')
        : item.isSoon
        ? L10n.text('lab.shop.soon')
        : state.kind == 'short'
        ? L10n.text('lab.shop.short', ['${state.short}'])
        : item.summary?.text ?? '';
    return Opacity(
      key: Key('lab.shop.item.${item.id}'),
      opacity: item.isSoon ? 0.6 : 1,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: ShapeDecoration(
          color: LabPalette.surface(context),
          shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(22)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(color: LabPalette.surface(context, 2), shape: BoxShape.circle),
                  child: Center(child: StudyIcon(item.symbol ?? 'bag', size: 22, color: labLabel(context))),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.topRight,
                    child: item.isLimited
                        ? FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: const ShapeDecoration(color: LabPalette.paper, shape: StadiumBorder()),
                              child: Text(
                                L10n.text('lab.shop.limited'),
                                style: LabFont.text(11, weight: FontWeight.w700, color: LabPalette.paperInk),
                              ),
                            ),
                          )
                        : null,
                  ),
                ),
              ],
            ),
            // The name and what it is shrink a little rather than push the price tag out of the square.
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    width: constraints.maxWidth,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          item.name.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: LabFont.text(16, weight: FontWeight.w700, color: labLabel(context)),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          note,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: LabFont.text(12, color: labSecondary(context)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            _priceTag(context, item, state, owned),
          ],
        ),
      ),
    );
  }

  Widget _priceTag(BuildContext context, LabShopItem item, LabBuyResult state, bool owned) {
    // Inside the 2D AI course, its own item has nothing to open.
    if (owned && item.id == LabStore.tagCourse && !StudyMode.shared.tagsOpen) {
      return LabButton(
        key: Key('lab.shop.open.${item.id}'),
        onPressed: openTags,
        radius: null,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        child: Text(
          L10n.text('lab.shop.open'),
          style: LabFont.text(15, weight: FontWeight.w600, color: labLabel(context)),
        ),
      );
    }
    if (owned) {
      return Row(
        children: [
          Icon(CupertinoIcons.checkmark_alt, size: 15, color: labSecondary(context)),
          const SizedBox(width: 4),
          Text(
            L10n.text('lab.shop.ownedShort'),
            style: LabFont.text(14, weight: FontWeight.w600, color: labSecondary(context)),
          ),
        ],
      );
    }
    final price = item.price;
    if (price == null) return const SizedBox.shrink();
    if (state.isBought) {
      return LabButton(
        key: Key('lab.shop.buy.${item.id}'),
        style: LabButtonStyle.primary,
        radius: null,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        onPressed: () => confirmLabPurchase(context, item),
        child: Text('$price', style: LabFont.number(15, color: LabPalette.onPrimary.resolveFrom(context))),
      );
    }
    return Container(
      key: Key('lab.shop.buy.${item.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: ShapeDecoration(color: LabPalette.surface(context, 2), shape: const StadiumBorder()),
      child: Text('$price', style: LabFont.number(15, color: labSecondary(context))),
    );
  }
}

/// Asks before spending 연구비, then buys. True when bought.
Future<bool> confirmLabPurchase(BuildContext context, LabShopItem item) async {
  final store = LabStore.shared;
  final yes = await showCupertinoDialog<bool>(
    context: context,
    builder: (context) => TegnalAlertDialog(
      title: Text(L10n.text('lab.shop.confirm', [item.name.text])),
      content: Text(L10n.text('lab.shop.confirmNote', ['${store.balance - (item.price ?? 0)}'])),
      actions: [
        CupertinoDialogAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(context, true),
          child: Text(L10n.text('lab.shop.buy', ['${item.price ?? 0}'])),
        ),
      ],
    ),
  );
  if (yes != true) return false;
  if (store.buy(item).isBought) {
    LabHaptic.pass();
    return true;
  }
  return false;
}

// MARK: - Diagnosis

/// Opens the one-minute check over everything.
Future<void> showLabDiagnosis(BuildContext context) => Navigator.of(context, rootNavigator: true).push(
  PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 420),
    reverseTransitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (context, _, _) => const LabDiagnosisView(),
    transitionsBuilder: (context, animation, _, child) => SlideTransition(
      position: Tween(
        begin: const Offset(0, 1),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic)),
      child: child,
    ),
  ),
);

/// The one-minute check: four questions, then card No. 000 with the learner's type and the episodes to look for.
class LabDiagnosisView extends StatefulWidget {
  const LabDiagnosisView({super.key});
  @override
  State<LabDiagnosisView> createState() => _LabDiagnosisViewState();
}

class _LabDiagnosisViewState extends State<LabDiagnosisView> {
  final List<int> answers = [];
  LabType? result;
  LabStore get store => LabStore.shared;

  @override
  Widget build(BuildContext context) {
    final diagnosis = store.diagnosis;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return ColoredBox(
      color: TegnalColors.background.resolveFrom(context),
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            SizedBox(
              height: 56,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    if (result == null) ...[
                      GlassTextButton(
                        key: const Key('lab.diagnosis.skip'),
                        label: L10n.text('lab.diagnosis.skip'),
                        elevated: false,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const Spacer(),
                      Text('${answers.length + 1}/${diagnosis?.questions.length ?? 0}', style: LabFont.number(13, color: labSecondary(context))),
                    ],
                  ],
                ),
              ),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (child, animation) => SlideTransition(
                  position: Tween(begin: const Offset(0.2, 0), end: Offset.zero).animate(animation),
                  child: FadeTransition(opacity: animation, child: child),
                ),
                child: diagnosis == null
                    ? const SizedBox.shrink()
                    : result != null
                    ? KeyedSubtree(key: const ValueKey('result'), child: _result(context, result!, bottom))
                    : KeyedSubtree(key: ValueKey(answers.length), child: _question(context, diagnosis, answers.length, bottom)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _question(BuildContext context, LabDiagnosis diagnosis, int index, double bottom) {
    final question = diagnosis.questions[index];
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (index == 0) ...[
            Text(
              diagnosis.title.text,
              style: LabFont.text(15, weight: FontWeight.w600, color: labSecondary(context)),
            ),
            if (diagnosis.intro case final intro?) ...[const SizedBox(height: 6), Text(intro.text, style: LabFont.text(14, color: labSecondary(context)))],
            const SizedBox(height: 20),
          ],
          Text(
            labWords(question.text.text),
            key: const Key('lab.diagnosis.question'),
            style: LabFont.voice(26, color: labLabel(context)),
          ),
          const Spacer(),
          for (final (option, answer) in question.options.indexed) ...[
            LabButton(
              key: Key('lab.diagnosis.option.$option'),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              onPressed: () {
                LabHaptic.tick();
                setState(() => answers.add(option));
                if (answers.length == diagnosis.questions.length) {
                  final type = diagnosis.result(answers);
                  if (type != null) {
                    store.diagnose(type);
                    LabHaptic.pass();
                    setState(() => result = type);
                  }
                }
              },
              child: SizedBox(
                width: double.infinity,
                child: Text(
                  studyWords(answer.text.text),
                  textAlign: TextAlign.left,
                  style: LabFont.text(16, weight: FontWeight.w600, color: labLabel(context)),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _result(BuildContext context, LabType type, double bottom) => Stack(
    children: [
      SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 8, 20, 100 + bottom),
        child: Column(
          children: [
            Text(
              L10n.text('lab.diagnosis.done'),
              key: const Key('lab.diagnosis.done'),
              style: LabFont.text(22, weight: FontWeight.w700, color: labLabel(context)),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: 280,
              height: 352,
              child: LabCardFace(
                serial: 'No. 000',
                title: type.name.text,
                line: type.name.text,
                state: LabCardState.earned,
                footer: type.line.text,
                large: true,
              ),
            ),
            const SizedBox(height: 20),
            LabTypeEpisodes(type: type),
          ],
        ),
      ),
      Positioned(
        left: 20,
        right: 20,
        bottom: 10 + bottom,
        child: LabButton(
          key: const Key('lab.diagnosis.close'),
          style: LabButtonStyle.primary,
          expand: true,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(L10n.text('lab.engrave.put')),
        ),
      ),
    ],
  );
}

/// The episodes a type should look for first.
class LabTypeEpisodes extends StatelessWidget {
  const LabTypeEpisodes({super.key, required this.type});
  final LabType type;

  @override
  Widget build(BuildContext context) {
    final store = LabStore.shared;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: ShapeDecoration(
        color: TegnalColors.secondaryBackground.resolveFrom(context),
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            L10n.text('lab.diagnosis.recommended'),
            style: LabFont.text(13, weight: FontWeight.w600, color: labSecondary(context)),
          ),
          for (final episode in type.episodes.map(store.course.episode).nonNulls) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(episode.serial, style: LabFont.number(12, color: LabPalette.gauge.resolveFrom(context))),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    labWords(episode.title.text),
                    style: LabFont.text(15, weight: FontWeight.w600, color: labLabel(context)),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The back of card No. 000.
class LabTypeSheet extends StatelessWidget {
  const LabTypeSheet({super.key, required this.controller, required this.diagnose});
  final ScrollController controller;
  final VoidCallback diagnose;

  @override
  Widget build(BuildContext context) {
    final store = LabStore.shared;
    final type = store.type;
    return Stack(
      children: [
        if (type != null)
          ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(20, 64, 20, 32),
            children: [
              Center(
                child: SizedBox(
                  width: 280,
                  height: 352,
                  child: LabCardFace(
                    serial: 'No. 000',
                    title: type.name.text,
                    line: type.name.text,
                    state: LabCardState.earned,
                    footer: type.line.text,
                    date: store.progress.diagnosed == null ? null : labStamp(store.progress.diagnosed!),
                    large: true,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              LabTypeEpisodes(type: type),
              const SizedBox(height: 18),
              Center(
                child: LabButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    Future<void>.delayed(const Duration(milliseconds: 400), diagnose);
                  },
                  child: Text(L10n.text('lab.diagnosis.again')),
                ),
              ),
            ],
          ),
        Positioned(
          right: 16,
          top: 14,
          child: Semantics(
            button: true,
            label: L10n.text('Close'),
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Glass.circle(
                elevated: true,
                child: SizedBox.square(dimension: 44, child: Icon(CupertinoIcons.xmark, size: 18, color: labLabel(context))),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A 망작 as the gallery hangs it: what came out, on paper in a dark frame, with its name and number under it.
class LabFailFrame extends StatelessWidget {
  const LabFailFrame({super.key, required this.fail, this.lines = 5, this.captioned = true});
  final LabFail fail;

  /// Whether the name and number are written under the frame.
  final bool captioned;

  /// How many lines of the answer the paper holds; null shows all of it.
  final int? lines;

  @override
  Widget build(BuildContext context) {
    final store = LabStore.shared;
    final episode = store.course.episode(fail.episode);
    final lines = this.lines;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: const Color(0xFF2A2724),
            borderRadius: BorderRadius.circular(3),
            boxShadow: const [BoxShadow(color: Color(0x59000000), blurRadius: 16, offset: Offset(0, 4))],
          ),
          child: Container(
            height: captioned && lines != null ? 124 : null,
            constraints: const BoxConstraints(minHeight: 100),
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: LabPalette.paper,
            child: Text(
              labWords(fail.reply.text),
              maxLines: lines,
              overflow: lines == null ? null : TextOverflow.ellipsis,
              style: LabFont.line(13, color: LabPalette.paperInk),
            ),
          ),
        ),
        if (captioned) ...[
          const SizedBox(height: 8),
          Text(
            fail.name.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: LabFont.text(14, weight: FontWeight.w700, color: labLabel(context)),
          ),
          Text(
            'No. ${store.number(fail).toString().padLeft(2, '0')} · ${L10n.text('lab.card.number', [episode?.digits ?? ''])}',
            style: LabFont.number(11, weight: FontWeight.w500, color: labSecondary(context)),
          ),
        ],
      ],
    );
  }
}

/// The moment a 망작 is won, the first time its trap is pressed: the chat dims and blurs, a ring of light opens, the framed
/// 망작 drops in from above, swings on its pin and settles a little crooked, and only then its name, number and the 연구비 it
/// paid come in. Ported from `LabFailReveal` in `LabPages.swift`.
class LabFailReveal extends StatefulWidget {
  const LabFailReveal({super.key, required this.fail, required this.done});
  final LabFail fail;
  final VoidCallback done;

  @override
  State<LabFailReveal> createState() => _LabFailRevealState();
}

class _LabFailRevealState extends State<LabFailReveal> with TickerProviderStateMixin {
  late final AnimationController _dim = AnimationController(vsync: this, duration: const Duration(milliseconds: 250));
  late final AnimationController _hang = AnimationController.unbounded(vsync: this);
  late final AnimationController _settle = AnimationController.unbounded(vsync: this);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _play());
  }

  Future<void> _play() async {
    if (!mounted) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _dim.value = 1;
      _hang.value = 1;
      _settle.value = 1;
      return;
    }
    unawaited(_dim.forward());
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    // Dropped in, it swings past and back on its pin before it comes to rest (`.spring(duration: 0.9, bounce: 0.5)`).
    unawaited(_hang.animateWith(SpringSimulation(SpringDescription.withDampingRatio(mass: 1, stiffness: 49, ratio: 0.5), 0, 1, 0)));
    await Future<void>.delayed(const Duration(milliseconds: 380));
    if (!mounted) return;
    LabHaptic.snap();
    unawaited(_settle.animateWith(SpringSimulation(SpringDescription.withDampingRatio(mass: 1, stiffness: 110, ratio: 0.8), 0, 1, 0)));
  }

  Future<void> _close() async {
    await Future.wait([
      _dim.reverse(),
      _settle.animateTo(0, duration: const Duration(milliseconds: 200)),
      _hang.animateTo(0, duration: const Duration(milliseconds: 200)),
    ]);
    widget.done();
  }

  @override
  void dispose() {
    _dim.dispose();
    _hang.dispose();
    _settle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = LabStore.shared;
    final fail = widget.fail;
    final episode = store.course.episode(fail.episode);
    const white = Color(0xFFFFFFFF);
    final failColor = LabPalette.fail.resolveFrom(context);
    return Semantics(
      key: const Key('lab.fail.reveal'),
      scopesRoute: true,
      explicitChildNodes: true,
      child: AnimatedBuilder(
        animation: Listenable.merge([_dim, _hang, _settle]),
        builder: (context, _) {
          final dim = _dim.value;
          final hang = _hang.value;
          final settle = _settle.value;
          final shown = settle.clamp(0.0, 1.0);
          return Stack(
            fit: StackFit.expand,
            children: [
              // The chat goes dark and out of focus behind the card.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: ClipRect(
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 12 * dim, sigmaY: 12 * dim),
                    child: ColoredBox(color: Color.fromRGBO(0, 0, 0, 0.72 * dim)),
                  ),
                ),
              ),
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Opacity(
                        opacity: shown,
                        child: Transform.translate(
                          offset: Offset(0, -10 * (1 - settle)),
                          child: Column(
                            children: [
                              LabTag(text: 'No. ${store.number(fail).toString().padLeft(2, '0')}', color: failColor, mono: true),
                              const SizedBox(height: 8),
                              Semantics(
                                header: true,
                                child: Text(
                                  L10n.text('lab.fail.got'),
                                  style: LabFont.text(24, weight: FontWeight.w700, color: white),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 22),
                      Transform.translate(
                        offset: Offset(0, -320 * (1 - hang)),
                        child: Transform.rotate(
                          angle: (-22 + 19.5 * hang) * math.pi / 180,
                          alignment: Alignment.topCenter,
                          child: SizedBox(
                            width: 260,
                            child: Stack(
                              clipBehavior: Clip.none,
                              alignment: Alignment.topCenter,
                              children: [
                                // A ring of light behind the frame, opening as it lands.
                                Positioned(
                                  top: -150,
                                  child: IgnorePointer(
                                    child: Opacity(
                                      opacity: shown,
                                      child: Transform.scale(
                                        scale: 0.3 + 0.7 * settle,
                                        child: Container(
                                          width: 440,
                                          height: 440,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            gradient: RadialGradient(
                                              colors: [LabPalette.paper.withValues(alpha: 0.3), failColor.withValues(alpha: 0.18), const Color(0x00000000)],
                                              stops: const [0.05, 0.45, 1],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                LabFailFrame(fail: fail, lines: 7, captioned: false),
                                // The pin it hangs from.
                                Positioned(
                                  top: -4,
                                  child: Container(
                                    width: 10,
                                    height: 10,
                                    decoration: const BoxDecoration(
                                      color: Color(0xFF8A867D),
                                      shape: BoxShape.circle,
                                      boxShadow: [BoxShadow(color: Color(0x66000000), blurRadius: 2, offset: Offset(0, 1))],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 22),
                      Opacity(
                        opacity: shown,
                        child: Transform.translate(
                          offset: Offset(0, 12 * (1 - settle)),
                          child: Column(
                            children: [
                              Text(
                                fail.name.text,
                                textAlign: TextAlign.center,
                                style: LabFont.voice(24, color: white),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '${L10n.text('lab.card.number', [episode?.digits ?? ''])} · '
                                '${L10n.text('lab.fail.gotNote', [store.shop.currency.text, '${store.course.info.rewards.fail}'])}',
                                textAlign: TextAlign.center,
                                style: LabFont.text(13, weight: FontWeight.w600, color: white.withValues(alpha: 0.7)),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 22),
                      Opacity(
                        opacity: shown,
                        child: SizedBox(
                          width: 260,
                          child: LabButton(
                            key: const Key('lab.fail.reveal.done'),
                            style: LabButtonStyle.primary,
                            expand: true,
                            onPressed: shown > 0.5 ? _close : null,
                            child: Text(L10n.text('OK')),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
