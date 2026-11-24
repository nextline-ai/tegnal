import 'dart:math' as math;
import 'dart:async';
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../../core/lab/lab_course.dart';
import '../../core/lab/lab_sheet.dart';
import '../../core/lab/lab_shop.dart';
import '../../core/lab/lab_sheet_alerts.dart';
import '../../core/lab/lab_store.dart';
import '../../core/support/l10n.dart';
import '../design/alert_dialog.dart';
import '../design/app_sheet.dart';
import '../design/glass.dart';
import '../design/ios_controls.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';
import '../study_mode/study_kit.dart';
import 'creator_view.dart';
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
                  // The page and the day it was curated, as a small red stamp beside the title.
                  LabHeader(
                    kicker: TextSpan(text: L10n.text('lab.sheet.subtitle')),
                    title: L10n.text('lab.tab.sheet'),
                    trailing: edition == null ? null : LabSheetStamp(edition: edition),
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
                  const SizedBox(height: 24),
                  if (edition != null)
                    LabSheetBoard(edition: edition)
                  else
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 80),
                      child: Text(
                        L10n.text('lab.sheet.none'),
                        textAlign: TextAlign.center,
                        style: LabFont.text(17, weight: FontWeight.w600, color: labSecondary(context)),
                      ),
                    ),
                  // At the very foot: whether a new edition should be told when it comes out.
                  if (LabSheetAlerts.supported) ...[const SizedBox(height: 24), const LabSheetAlertToggle()],
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// The switch at the foot of the cheat sheet: a notification when a new edition is published (`LabSheetAlertToggle`).
/// Turning it on asks Android for permission; refused, or taken back later in the system settings, it says where to allow it.
class LabSheetAlertToggle extends StatefulWidget {
  const LabSheetAlertToggle({super.key});

  @override
  State<LabSheetAlertToggle> createState() => _LabSheetAlertToggleState();
}

class _LabSheetAlertToggleState extends State<LabSheetAlertToggle> {
  bool on = false, blocked = false, working = false;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _refresh);
    _refresh();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  /// The switch can be on while Android no longer lets the app notify; that is said, not hidden.
  Future<void> _refresh() async {
    final value = await LabSheetAlerts.isOn(), allowed = await LabSheetAlerts.allowed();
    if (!mounted) return;
    setState(() {
      on = value;
      blocked = (on || blocked) && !allowed;
    });
  }

  Future<void> _change(bool wanted) async {
    LabHaptic.tick();
    setState(() {
      on = wanted;
      working = true;
    });
    final done = await LabSheetAlerts.set(wanted, known: LabStore.shared.edition?.date);
    final value = await LabSheetAlerts.isOn();
    if (!mounted) return;
    setState(() {
      on = value;
      blocked = wanted && !done;
      working = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final secondary = labSecondary(context);
    final red = LabPalette.fail.resolveFrom(context);
    return Container(
      key: const Key('lab.sheet.alerts'),
      padding: const EdgeInsets.all(14),
      decoration: ShapeDecoration(
        color: FormColors.listRow.resolveFrom(context),
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(on ? CupertinoIcons.bell_fill : CupertinoIcons.bell, size: 20, color: on ? red : secondary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(L10n.text('lab.sheet.alerts'), style: LabFont.text(16, weight: FontWeight.w600, color: labLabel(context))),
                    const SizedBox(height: 2),
                    Text(L10n.text('lab.sheet.alerts.detail'), style: LabFont.text(13, color: secondary)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TegnalSwitch(value: on, onChanged: working ? null : _change),
            ],
          ),
          if (blocked) ...[
            const SizedBox(height: 10),
            Text(L10n.text('lab.sheet.alerts.blocked'), style: LabFont.text(13, color: red)),
            const SizedBox(height: 4),
            CupertinoButton(
              key: const Key('lab.sheet.alerts.settings'),
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              onPressed: LabSheetAlerts.openSettings,
              child: Text(L10n.text('lab.sheet.alerts.settings'), style: LabFont.text(13, weight: FontWeight.w600, color: CupertinoTheme.of(context).primaryColor)),
            ),
          ],
        ],
      ),
    );
  }
}

/// The day the sheet was curated, as a small red rubber stamp beside the title (`LabSheetStamp`).
class LabSheetStamp extends StatelessWidget {
  const LabSheetStamp({super.key, required this.edition});
  final LabEdition edition;

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFD0432A);
    return Semantics(
      key: const Key('lab.sheet.stamp'),
      label: L10n.text('lab.sheet.stamp', [edition.stamp]),
      child: ExcludeSemantics(
        child: Transform.rotate(
          angle: -4 * math.pi / 180,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              border: Border.all(color: red, width: 1.4),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  L10n.text('lab.sheet.basis'),
                  style: LabFont.text(9, weight: FontWeight.w900, color: red, tracking: 1),
                ),
                const SizedBox(height: 1),
                Text(edition.stamp, style: LabFont.number(13, color: red)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The sheet's questions, each a grid of tiles two across (`LabSheetBoard`). On a tile the answer, the pick, is the largest
/// thing; the job is its label and the reason one quiet line. A question no card has opened yet shows its jobs with the picks
/// held back, and which card opens them.
class LabSheetBoard extends StatelessWidget {
  const LabSheetBoard({super.key, required this.edition});
  final LabEdition edition;
  LabStore get store => LabStore.shared;

  @override
  Widget build(BuildContext context) {
    final secondary = labSecondary(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (index, section) in edition.sections.indexed) ...[if (index > 0) const SizedBox(height: 28), _section(context, section)],
        if (edition.footer case final footer?) ...[
          const SizedBox(height: 28),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(CupertinoIcons.info_circle, size: 15, color: secondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(footer.text, style: LabFont.text(13, color: secondary)),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _section(BuildContext context, LabSheetSection section) {
    final open = store.sectionOpened(section);
    final card = section.opens == null ? null : store.main.episode(section.opens!);
    final rows = section.rows;
    return Column(
      key: Key(open ? 'lab.sheet.section.${section.id}' : 'lab.sheet.locked.${section.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            section.title.text,
            style: LabFont.text(20, weight: FontWeight.w700, color: labLabel(context)),
          ),
        ),
        // Only while locked: which card opens it. Once open, nothing more needs saying.
        if (card != null && !open) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(CupertinoIcons.lock_fill, size: 12, color: LabPalette.fail.resolveFrom(context)),
              const SizedBox(width: 5),
              Text(
                L10n.text('lab.sheet.locked', [card.digits]),
                style: LabFont.text(12, weight: FontWeight.w600, color: LabPalette.fail.resolveFrom(context)),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        for (var start = 0; start < rows.length; start += 2) ...[
          if (start > 0) const SizedBox(height: 10),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var index = start; index < start + 2; index++) ...[
                  if (index > start) const SizedBox(width: 10),
                  Expanded(child: index < rows.length ? _tile(context, section, index, rows[index], open) : const SizedBox()),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// One job: its symbol and name as the label, the pick large, the reason in a line or two.
  Widget _tile(BuildContext context, LabSheetSection section, int index, LabSheetRow row, bool open) {
    final secondary = labSecondary(context);
    final tile = Container(
      padding: const EdgeInsets.all(14),
      decoration: ShapeDecoration(
        color: FormColors.listRow.resolveFrom(context),
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(labSheetSymbol(row.symbol), size: 13, color: labSheetTint(context, row)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  row.task.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: LabFont.text(13, weight: FontWeight.w600, color: secondary),
                ),
              ),
              if (!open)
                Icon(CupertinoIcons.lock_fill, size: 11, color: TegnalColors.tertiaryLabel.resolveFrom(context))
              else
                Flexible(child: LabSheetLabel(row: row)),
            ],
          ),
          const SizedBox(height: 8),
          if (open) ...[
            Text(
              row.pick,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: LabFont.text(21, weight: FontWeight.w700, color: labLabel(context)),
            ),
            if (row.why case final why?) ...[
              const SizedBox(height: 8),
              Text(
                why.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: LabFont.text(13, color: secondary),
              ),
            ],
          ] else ...[
            // Held back until its card is engraved.
            Container(
              width: 84,
              height: 18,
              margin: const EdgeInsets.symmetric(vertical: 4),
              decoration: ShapeDecoration(color: secondary.withValues(alpha: 0.22), shape: const StadiumBorder()),
            ),
            Container(
              width: 120,
              height: 10,
              decoration: ShapeDecoration(color: secondary.withValues(alpha: 0.14), shape: const StadiumBorder()),
            ),
          ],
        ],
      ),
    );
    if (!open) return ExcludeSemantics(child: tile);
    return Semantics(
      button: true,
      hint: L10n.text('lab.sheet.more'),
      child: LabPress(
        key: Key('lab.sheet.row.${section.id}.$index'),
        onTap: () {
          LabHaptic.tick();
          showAppSheet<void>(
            context,
            grabber: true,
            builder: (context, controller) => LabSheetRowDetail(row: row, controller: controller),
          );
        },
        child: tile,
      ),
    );
  }
}

/// The tag at a tile's top right (`LabSheetLabel`): the row's own `label` in its `labelColor` (a tinted capsule), or a quiet
/// dashed outline without a colour; "초안" for a draft pick that names no label of its own.
class LabSheetLabel extends StatelessWidget {
  const LabSheetLabel({super.key, required this.row, this.large = false});
  final LabSheetRow row;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final text = row.label?.text ?? (row.draft == true ? L10n.text('lab.sheet.draft') : null);
    if (text == null || text.isEmpty) return const SizedBox.shrink();
    final hex = labSheetHex(row.labelColor);
    final secondary = labSecondary(context);
    final color = hex ?? secondary;
    return Container(
      key: const Key('lab.sheet.label'),
      padding: EdgeInsets.symmetric(horizontal: hex == null ? 6 : 7, vertical: 2),
      decoration: hex == null
          ? ShapeDecoration(
              shape: StadiumBorder(side: BorderSide(color: secondary.withValues(alpha: 0.5))),
            )
          : ShapeDecoration(color: hex.withValues(alpha: 0.16), shape: const StadiumBorder()),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.clip,
        style: LabFont.text(large ? 12 : 10, weight: FontWeight.w900, color: color),
      ),
    );
  }
}

/// A row's colour from six hexadecimal digits, or null.
Color? labSheetHex(String? hex) {
  if (hex == null || !RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(hex)) return null;
  return Color(0xFF000000 | int.parse(hex, radix: 16));
}

/// The row's own colour for its symbol, or the lab's gauge colour.
Color labSheetTint(BuildContext context, LabSheetRow row) => labSheetHex(row.color) ?? LabPalette.gauge.resolveFrom(context);

/// A cheat-sheet row's symbol, by the SF Symbol name the sheet gives (as iOS draws it), or sparkles.
IconData labSheetSymbol(String? name) => switch (name) {
  'doc.text' => CupertinoIcons.doc_text,
  'doc.richtext' => CupertinoIcons.doc_richtext,
  'chevron.left.forwardslash.chevron.right' => CupertinoIcons.chevron_left_slash_chevron_right,
  'terminal' => CupertinoIcons.chevron_right_square,
  'magnifyingglass' => CupertinoIcons.search,
  'bubble.left.and.bubble.right' => CupertinoIcons.chat_bubble_2,
  'photo' => CupertinoIcons.photo,
  'film' => CupertinoIcons.film,
  'music.note' => CupertinoIcons.music_note,
  'mic' => CupertinoIcons.mic,
  'safari' => CupertinoIcons.compass,
  'globe' => CupertinoIcons.globe,
  'chart.bar' => CupertinoIcons.chart_bar,
  'book' => CupertinoIcons.book,
  'pencil' => CupertinoIcons.pencil,
  'paintbrush' => CupertinoIcons.paintbrush,
  'lightbulb' => CupertinoIcons.lightbulb,
  'briefcase' => CupertinoIcons.briefcase,
  'cart' => CupertinoIcons.cart,
  'envelope' => CupertinoIcons.envelope,
  'calendar' => CupertinoIcons.calendar,
  'person.2' => CupertinoIcons.person_2,
  'wand.and.stars' => CupertinoIcons.wand_stars,
  _ => CupertinoIcons.sparkles,
};

/// What a tap on a cheat-sheet row opens (`LabSheetRowDetail`): the job, the pick large, why and an example, then the row's
/// own writing rendered from Markdown.
class LabSheetRowDetail extends StatelessWidget {
  const LabSheetRowDetail({super.key, required this.row, required this.controller});
  final LabSheetRow row;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final label = labLabel(context), secondary = labSecondary(context);
    return ColoredBox(
      color: TegnalColors.background.resolveFrom(context),
      child: Stack(
        children: [
          ListView(
            key: const Key('lab.sheet.detail'),
            controller: controller,
            padding: const EdgeInsets.fromLTRB(20, 64, 20, 32),
            children: [
              // The answer first: the job as its label, the pick as large as the page's title, then why.
              Row(
                children: [
                  Icon(labSheetSymbol(row.symbol), size: 16, color: labSheetTint(context, row)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      row.task.text,
                      style: LabFont.text(15, weight: FontWeight.w600, color: secondary),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  Text(
                    row.pick,
                    style: LabFont.text(32, weight: FontWeight.w800, color: label),
                  ),
                  LabSheetLabel(row: row, large: true),
                ],
              ),
              if (row.why case final why?) ...[const SizedBox(height: 10), Text(why.text, style: LabFont.text(17, color: label))],
              if (row.example case final example?) ...[
                const SizedBox(height: 10),
                Text(L10n.text('lab.sheet.example', [example.text]), style: LabFont.text(14, color: secondary)),
              ],
              if (row.draft == true) ...[const SizedBox(height: 10), Text(L10n.text('lab.sheet.draftNote'), style: LabFont.text(12, color: secondary))],
              // The rest is the sheet's own writing, as Markdown.
              if (row.detail case final detail?) ...[
                const SizedBox(height: 22),
                Container(height: 0.5, color: TegnalColors.separator.resolveFrom(context)),
                const SizedBox(height: 22),
                LabMarkdown(text: detail.text),
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
                  child: SizedBox.square(dimension: 44, child: Icon(CupertinoIcons.xmark, size: 18, color: label)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One block of Markdown (`LabMarkdown.Block`).
sealed class LabMarkdownBlock {
  const LabMarkdownBlock();
}

class LabMarkdownHeading extends LabMarkdownBlock {
  const LabMarkdownHeading(this.level, this.text);
  final int level;
  final String text;
}

class LabMarkdownParagraph extends LabMarkdownBlock {
  const LabMarkdownParagraph(this.text);
  final String text;
}

class LabMarkdownBullet extends LabMarkdownBlock {
  const LabMarkdownBullet(this.text);
  final String text;
}

class LabMarkdownNumbered extends LabMarkdownBlock {
  const LabMarkdownNumbered(this.number, this.text);
  final String number;
  final String text;
}

class LabMarkdownQuote extends LabMarkdownBlock {
  const LabMarkdownQuote(this.text);
  final String text;
}

class LabMarkdownCode extends LabMarkdownBlock {
  const LabMarkdownCode(this.code);
  final String code;
}

class LabMarkdownRule extends LabMarkdownBlock {
  const LabMarkdownRule();
}

/// A small Markdown renderer for writing that comes with the app's own data, such as a cheat-sheet row's details (iOS
/// `LabMarkdown`): paragraphs, `#`–`###` headings, `-`/`*` and `1.` lists, `>` quotes, `---` rules and fenced code shown with a
/// copy button; inline **bold**, *italic* and `code`. Links show as their text and open nothing.
class LabMarkdown extends StatelessWidget {
  const LabMarkdown({super.key, required this.text});
  final String text;

  static final _numbered = RegExp(r'^(\d+)\. (.*)$');
  static final _heading = RegExp(r'^(#{1,6}) (.*)$');

  /// The blocks of a Markdown text, in order.
  static List<LabMarkdownBlock> blocks(String text) {
    final blocks = <LabMarkdownBlock>[];
    final paragraph = <String>[];
    List<String>? code;
    void flush() {
      if (paragraph.isEmpty) return;
      blocks.add(LabMarkdownParagraph(paragraph.join(' ')));
      paragraph.clear();
    }

    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.startsWith('```')) {
        if (code != null) {
          blocks.add(LabMarkdownCode(code.join('\n')));
          code = null;
        } else {
          flush();
          code = [];
        }
        continue;
      }
      if (code != null) {
        code.add(raw);
        continue;
      }
      if (line.isEmpty) {
        flush();
        continue;
      }
      final heading = _heading.firstMatch(line);
      final numbered = _numbered.firstMatch(line);
      if (heading != null) {
        flush();
        blocks.add(LabMarkdownHeading(heading[1]!.length.clamp(1, 3), heading[2]!.trim()));
      } else if (line == '---' || line == '***') {
        flush();
        blocks.add(const LabMarkdownRule());
      } else if (line.startsWith('- ') || line.startsWith('* ')) {
        flush();
        blocks.add(LabMarkdownBullet(line.substring(2)));
      } else if (numbered != null) {
        flush();
        blocks.add(LabMarkdownNumbered(numbered[1]!, numbered[2]!));
      } else if (line.startsWith('>')) {
        flush();
        blocks.add(LabMarkdownQuote(line.substring(1).trim()));
      } else {
        paragraph.add(line);
      }
    }
    if (code != null) blocks.add(LabMarkdownCode(code.join('\n')));
    flush();
    return blocks;
  }

  static final _inline = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`|\*(.+?)\*|_(.+?)_|\[([^\]]+)\]\([^)]*\)');

  /// Inline Markdown as styled spans, with links kept as plain words.
  static TextSpan inline(String text, TextStyle style) {
    final spans = <InlineSpan>[];
    var at = 0;
    for (final match in _inline.allMatches(text)) {
      if (match.start > at) spans.add(TextSpan(text: text.substring(at, match.start)));
      if (match[1] != null) {
        spans.add(
          TextSpan(
            text: match[1],
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        );
      } else if (match[2] != null) {
        spans.add(
          TextSpan(
            text: match[2],
            style: LabFont.number(style.fontSize ?? 16, weight: FontWeight.w500, color: style.color),
          ),
        );
      } else if (match[3] != null || match[4] != null) {
        spans.add(
          TextSpan(
            text: match[3] ?? match[4],
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        );
      } else {
        spans.add(TextSpan(text: match[5]));
      }
      at = match.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return TextSpan(style: style, children: spans);
  }

  @override
  Widget build(BuildContext context) {
    final label = labLabel(context), secondary = labSecondary(context);
    final body = LabFont.text(16, color: label);
    Widget item(Widget marker, String text) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 22, child: marker),
        Expanded(child: Text.rich(inline(text, body))),
      ],
    );
    final children = <Widget>[];
    for (final block in blocks(text)) {
      if (children.isNotEmpty) children.add(const SizedBox(height: 12));
      children.add(switch (block) {
        LabMarkdownHeading(:final level, :final text) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Semantics(
            header: true,
            child: Text.rich(inline(text, LabFont.text(const [22.0, 19.0, 17.0][level - 1], weight: FontWeight.w700, color: label))),
          ),
        ),
        LabMarkdownParagraph(:final text) => Text.rich(inline(text, body)),
        LabMarkdownBullet(:final text) => item(
          Text(
            '•',
            style: LabFont.text(16, weight: FontWeight.w700, color: secondary),
          ),
          text,
        ),
        LabMarkdownNumbered(:final number, :final text) => item(
          Text('$number.', style: LabFont.number(14, color: LabPalette.gauge.resolveFrom(context))),
          text,
        ),
        LabMarkdownQuote(:final text) => Container(
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: secondary.withValues(alpha: 0.4), width: 3)),
          ),
          child: Text.rich(inline(text, LabFont.text(16, color: secondary))),
        ),
        LabMarkdownCode(:final code) => LabCodeBlock(code: code),
        LabMarkdownRule() => Container(height: 0.5, color: TegnalColors.separator.resolveFrom(context)),
      });
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

/// Fenced code in Markdown: set in a fixed-width face on a tinted plate, with a button that copies it.
class LabCodeBlock extends StatefulWidget {
  const LabCodeBlock({super.key, required this.code});
  final String code;

  @override
  State<LabCodeBlock> createState() => _LabCodeBlockState();
}

class _LabCodeBlockState extends State<LabCodeBlock> {
  bool copied = false;

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: ShapeDecoration(
        color: FormColors.listRow.resolveFrom(context),
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.code, style: LabFont.text(15, color: labLabel(context))),
          const SizedBox(height: 10),
          GestureDetector(
            key: const Key('lab.sheet.copy'),
            behavior: HitTestBehavior.opaque,
            onTap: () {
              Clipboard.setData(ClipboardData(text: widget.code));
              LabHaptic.pass();
              setState(() => copied = true);
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(copied ? CupertinoIcons.checkmark_alt : CupertinoIcons.doc_on_doc, size: 16, color: tint),
                const SizedBox(width: 6),
                Text(
                  L10n.text(copied ? 'lab.sheet.copied' : 'lab.sheet.copy'),
                  style: LabFont.text(14, weight: FontWeight.w600, color: tint),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// MARK: - The gallery of 망작

/// Every trap's 망작, framed once it has been pressed. Traps not yet pressed are empty frames that call the learner back.
class LabFailsView extends StatelessWidget {
  const LabFailsView({super.key, this.play});

  /// Opens an episode, for a 망작 not won yet whose episode is open.
  final void Function(LabEpisode episode)? play;
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
                          : _go(context, fail);
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

  /// Brings a 망작 up close over everything, dock included, the same way it came up when it was won.
  void _open(BuildContext context, LabFail fail) {
    LabHaptic.tick();
    unawaited(
      Navigator.of(context, rootNavigator: true).push(
        PageRouteBuilder<void>(
          opaque: false,
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (routeContext, _, _) => LabFailReveal(fail: fail, won: false, done: () => Navigator.of(routeContext).pop()),
        ),
      ),
    );
  }

  Widget _frame(BuildContext context, LabFail fail) => LabFailFrame(fail: fail);

  /// A 망작 not won yet. When its episode is open, a tap goes straight there to win it.
  Widget _go(BuildContext context, LabFail fail) {
    final episode = store.course.episode(fail.episode);
    final play = this.play;
    if (episode == null || play == null || store.state(episode) == LabCardStatus.locked) return _empty(context, fail);
    return Semantics(
      button: true,
      hint: L10n.text('lab.fails.go'),
      child: LabPress(
        key: Key('lab.fail.go.${fail.id}'),
        onTap: () {
          LabHaptic.tick();
          play(episode);
        },
        child: _empty(context, fail),
      ),
    );
  }

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
          if (locked)
            Text(
              L10n.text('lab.card.locked'),
              style: LabFont.text(14, weight: FontWeight.w700, color: secondary),
            )
          else
            Row(
              children: [
                Icon(CupertinoIcons.arrow_right_circle_fill, size: 16, color: LabPalette.fail.resolveFrom(context)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    L10n.text('lab.fails.go'),
                    style: LabFont.text(14, weight: FontWeight.w700, color: LabPalette.fail.resolveFrom(context)),
                  ),
                ),
              ],
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

// MARK: - Shop

/// Asks before spending 보석, then buys. True when bought.
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

/// Opens the one-minute check over everything. As the lab's first welcome ([introduces]) it opens on who made the lab.
Future<void> showLabDiagnosis(BuildContext context, {bool introduces = false}) => Navigator.of(context, rootNavigator: true).push(
  PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 420),
    reverseTransitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (context, _, _) => LabDiagnosisView(introduces: introduces),
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
  const LabDiagnosisView({super.key, this.introduces = false});

  /// The lab's first welcome: who made it comes first, then the questions.
  final bool introduces;
  @override
  State<LabDiagnosisView> createState() => _LabDiagnosisViewState();
}

class _LabDiagnosisViewState extends State<LabDiagnosisView> {
  final List<int> answers = [];
  LabType? result;
  late bool introducing = widget.introduces;
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
                      if (!introducing)
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
                child: introducing
                    ? KeyedSubtree(key: const ValueKey('creator'), child: _creator(context, bottom))
                    : diagnosis == null
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

  /// Who made the lab, before its first question.
  Widget _creator(BuildContext context, double bottom) => Stack(
    children: [
      ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 90 + bottom),
        children: [
          Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: const CreatorProfile(onboarding: true))),
        ],
      ),
      Positioned(
        left: 20,
        right: 20,
        bottom: 10 + bottom,
        child: LabButton(
          key: const Key('lab.diagnosis.creator'),
          style: LabButtonStyle.primary,
          expand: true,
          onPressed: () {
            LabHaptic.tick();
            setState(() => introducing = false);
          },
          child: Text(L10n.text('Continue')),
        ),
      ),
    ],
  );

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
          for (final episode in type.episodes.map(store.main.episode).nonNulls) ...[
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
/// 망작 drops in from above, swings on its pin and settles a little crooked, and only then its name, number and the 보석 it
/// paid come in. Ported from `LabFailReveal` in `LabPages.swift`.
class LabFailReveal extends StatefulWidget {
  const LabFailReveal({super.key, required this.fail, required this.done, this.won = true});
  final LabFail fail;
  final VoidCallback done;

  /// Won just now; false when it is opened again from the gallery, which shows the trap that made it instead.
  final bool won;

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
                              if (widget.won)
                                Semantics(
                                  header: true,
                                  child: Text(
                                    L10n.text('lab.fail.got'),
                                    style: LabFont.text(24, weight: FontWeight.w700, color: white),
                                  ),
                                )
                              else
                                // The trap that made it, as the learner pressed it.
                                Text(
                                  '“${fail.choice.text}”',
                                  textAlign: TextAlign.center,
                                  style: LabFont.text(17, weight: FontWeight.w600, color: white.withValues(alpha: 0.85)),
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
                                widget.won
                                    ? '${L10n.text('lab.card.number', [episode?.digits ?? ''])} · '
                                          '${store.failReward > 0 ? L10n.text('lab.fail.gotNote', [store.shop.currency.text, '${store.failReward}']) : L10n.text('lab.fail.hungNote')}'
                                    : '${L10n.text('lab.card.number', [episode?.digits ?? ''])}${episode == null ? '' : ' · ${episode.title.text}'}',
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
