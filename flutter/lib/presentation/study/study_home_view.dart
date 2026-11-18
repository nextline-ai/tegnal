import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/study/study_dtext.dart';
import '../../core/study/study_engine.dart';
import '../../core/study/study_models.dart';
import '../../core/study/study_session.dart';
import '../../core/study/study_store.dart';
import '../../core/support/l10n.dart';
import '../booru/booru_common.dart';
import '../design/alert_dialog.dart';
import '../design/context_menu.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';
import '../design/system_colors.dart';
import '../library/folders_view.dart' show LibrarySearchField, anchorOf;
import '../navigation/app_header.dart';
import '../generation/generator_view.dart';
import 'study_guide_view.dart';
import 'study_quiz_view.dart';
import 'study_tag_view.dart';
import 'study_widgets.dart';

/// `StudyEntrySection`: the way into tag study, shown at the top of the image library's Tags tab.
class StudyEntrySection extends StatefulWidget {
  const StudyEntrySection({super.key, required this.booru});
  final BooruContext booru;

  @override
  State<StudyEntrySection> createState() => _StudyEntrySectionState();
}

class _StudyEntrySectionState extends State<StudyEntrySection> {
  final _board = StudyBoard();

  @override
  void initState() {
    super.initState();
    _board.reload(widget.booru.store);
    _board.addListener(_changed);
    widget.booru.state.addListener(_reload);
  }

  @override
  void dispose() {
    widget.booru.state.removeListener(_reload);
    _board.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _reload() => _board.reload(widget.booru.store);

  String get _detail {
    final summary = _board.summary;
    if (summary.started == 0) return L10n.text('Learn the tags image AI is prompted with, from real pictures.');
    if (summary.due > 0) return L10n.text('%@ to review · %@ of %@ learned', ['${summary.due}', '${summary.learned}', '${summary.total}']);
    return L10n.text('%@ of %@ learned', ['${summary.learned}', '${summary.total}']);
  }

  @override
  Widget build(BuildContext context) => FormSection(
    rowColor: FormColors.listRow.resolveFrom(context),
    children: [
      FormRow(
        key: const Key('study.entry'),
        minHeight: 64,
        onTap: () async {
          await pushStudy<void>(context, (context) => StudyHomeView(booru: widget.booru));
          if (mounted) _reload();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              const StudyTile(icon: StudySymbols.graduationCap, width: 42, height: 48, radius: 12, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      L10n.text('Tag Study'),
                      style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                    ),
                    const SizedBox(height: 4),
                    Text(_detail, style: TegnalType.style(12, color: TegnalColors.secondaryLabel.resolveFrom(context))),
                  ],
                ),
              ),
              Icon(CupertinoIcons.chevron_right, size: 15, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
            ],
          ),
        ),
      ),
    ],
  );
}

/// `StudyReviewCard`: a reminder on the Smart tab, shown only while tags are due again, so the tab
/// stays as it is for people who do not study.
class StudyReviewCard extends StatefulWidget {
  const StudyReviewCard({super.key, required this.booru});
  final BooruContext booru;

  @override
  State<StudyReviewCard> createState() => _StudyReviewCardState();
}

class _StudyReviewCardState extends State<StudyReviewCard> {
  final _board = StudyBoard();

  @override
  void initState() {
    super.initState();
    _board.reload(widget.booru.store);
    _board.addListener(_changed);
    widget.booru.state.addListener(_reload);
  }

  @override
  void dispose() {
    widget.booru.state.removeListener(_reload);
    _board.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _reload() => _board.reload(widget.booru.store);

  Future<void> _start() async {
    final booru = widget.booru;
    await openStudyQuiz(
      context,
      booru: booru,
      session: StudySession(scope: StudyScope.review, store: booru.store, source: booru.source),
    );
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final due = _board.summary.due;
    if (due == 0) return const SizedBox.shrink();
    final accent = StudyStyle.accent(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        button: true,
        child: GestureDetector(
          key: const Key('study.reviewCard'),
          behavior: HitTestBehavior.opaque,
          onTap: _start,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: ShapeDecoration(
              color: TegnalColors.secondaryBackground.resolveFrom(context),
              shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: Row(
              children: [
                const StudyTile(icon: StudySymbols.graduationCap, width: 36, height: 48, radius: 5, alpha: 0.14, size: 17),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        L10n.text('Tags to Review'),
                        style: TegnalType.style(15, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        L10n.text('Tags due again: %@', ['$due']),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TegnalType.style(12, color: TegnalColors.secondaryLabel.resolveFrom(context)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Icon(StudySymbols.play, size: 12, color: accent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class StudyHomeView extends StatefulWidget {
  const StudyHomeView({super.key, required this.booru});
  final BooruContext booru;

  @override
  State<StudyHomeView> createState() => _StudyHomeViewState();
}

class _StudyHomeViewState extends State<StudyHomeView> {
  final _board = StudyBoard();
  final _search = TextEditingController();
  final _focus = FocusNode();

  BooruContext get _booru => widget.booru;

  @override
  void initState() {
    super.initState();
    _board.reload(_booru.store);
    _board.addListener(_changed);
    _search.addListener(_changed);
    _booru.store.addListener(_changed);
  }

  @override
  void dispose() {
    _booru.store.removeListener(_changed);
    _search.dispose();
    _focus.dispose();
    _board.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  List<StudyTag> get _matches {
    final text = _search.text.trim().toLowerCase();
    final name = text.replaceAll(' ', '_');
    if (text.isEmpty) return const [];
    final all = _board.curriculum.tags;
    final starts = all.where((tag) => tag.name.startsWith(name));
    final rest = all.where(
      (tag) => !tag.name.startsWith(name) && (tag.name.contains(name) || (tag.ko ?? '').contains(text) || (tag.ja ?? '').toLowerCase().contains(text)),
    );
    return [...starts, ...rest].take(60).toList();
  }

  Future<void> _start(StudyScope scope) async {
    await openStudyQuiz(
      context,
      booru: _booru,
      session: StudySession(scope: scope, store: _booru.store, source: _booru.source),
    );
    if (mounted) _board.reload(_booru.store);
  }

  Future<void> _confirmReset() async {
    final reset = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('Reset study progress?')),
        content: Text(L10n.text('Every tag goes back to not started. This cannot be undone.')),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Reset'))),
        ],
      ),
    );
    if (reset != true || !mounted) return;
    try {
      _booru.store.studyStore.reset();
    } on Object {
      // Nothing was written; the board shows what is stored.
    }
    _board.reload(_booru.store);
  }

  @override
  Widget build(BuildContext context) {
    final searching = _search.text.isNotEmpty;
    return StudyPage(
      title: L10n.text('Tag Study'),
      trailing: Builder(
        builder: (buttonContext) => ToolbarGroup(
          children: [
            ToolbarIconButton(
              key: const Key('study.more'),
              label: L10n.text('More'),
              icon: CupertinoIcons.ellipsis,
              onPressed: () => showActionMenu(
                buttonContext,
                anchor: anchorOf(buttonContext),
                actions: [
                  ContextMenuAction(
                    title: L10n.text('Reset Study Progress'),
                    icon: StudySymbols.reset,
                    destructive: true,
                    onSelected: _board.summary.started == 0 ? null : _confirmReset,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      children: [
        LibrarySearchField(controller: _search, focusNode: _focus, prompt: L10n.text('Search tags'), onSubmitted: (_) {}),
        const SizedBox(height: 16),
        if (searching) ..._results(context) else ..._home(context),
      ],
    );
  }

  List<Widget> _home(BuildContext context) {
    final rowColor = FormColors.listRow.resolveFrom(context);
    final summary = _board.summary;
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return [
      FormSection(
        rowColor: rowColor,
        footer: _booru.store.selectedServers.isEmpty
            ? Text(L10n.text('Choose a server to be asked with real pictures. Without one, questions ask by meaning only.'))
            : null,
        children: [
          FormRow(
            child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: _summary(context)),
          ),
          FormRow(
            child: StudyButton(
              key: const Key('study.start'),
              title: L10n.text(summary.started == 0 ? 'Start Learning' : "Today's Study"),
              icon: StudySymbols.play,
              prominent: true,
              onPressed: () => _start(StudyScope.today),
            ),
          ),
          if (summary.due > 0)
            FormRow(
              child: StudyButton(
                key: const Key('study.review'),
                title: L10n.text('Review Only (%@)', ['${summary.due}']),
                icon: StudySymbols.review,
                plain: true,
                onPressed: () => _start(StudyScope.review),
              ),
            ),
        ],
      ),
      studySectionGap,
      FormSection(
        prominentHeader: true,
        rowColor: rowColor,
        header: Text(L10n.text('Prompts')),
        children: [
          StudyLinkRow(
            key: const Key('study.guide'),
            icon: StudySymbols.guide,
            title: L10n.text('Writing Prompts'),
            detail: L10n.text('Emphasis, quality tags and what each model recommends.'),
            onTap: () => pushStudy<void>(context, (context) => StudyGuideView(booru: _booru)),
          ),
          StudyLinkRow(
            key: const Key('study.generator'),
            icon: CupertinoIcons.wand_stars,
            title: L10n.text('Generate a Picture'),
            detail: L10n.text('Try a prompt with your own Civitai API key.'),
            onTap: () => pushStudy<void>(context, (context) => GeneratorView.forBooru(_booru)),
          ),
        ],
      ),
      studySectionGap,
      FormSection(
        prominentHeader: true,
        rowColor: rowColor,
        header: Text(L10n.text('Units')),
        children: [for (final unit in _board.curriculum.units) _unitRow(context, unit)],
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
        child: Text(
          L10n.text('Anime image generators learned from pictures tagged this way. The more posts a tag has, the better such a model tends to follow it.'),
          style: TegnalType.style(13, color: secondary),
        ),
      ),
    ];
  }

  List<Widget> _results(BuildContext context) {
    final name = StudyDText.tagName(_search.text);
    final rowColor = FormColors.listRow.resolveFrom(context);
    final matches = _matches;
    final lookup = name.isNotEmpty && !_board.curriculum.contains(name) && _booru.store.selectedServers.isNotEmpty;
    if (matches.isEmpty && !lookup) return const [];
    return [
      FormSection(
        rowColor: rowColor,
        children: [
          for (final tag in matches)
            StudyTagRow(
              tag: tag,
              progress: _board.progress[tag.name],
              onTap: () => pushStudy<void>(context, (context) => StudyTagView(booru: _booru, name: tag.name)),
            ),
          // Any tag can be looked up, taught here or not.
          if (lookup)
            StudyActionRow(
              key: const Key('study.lookup'),
              title: L10n.text('Look up “%@” on the server', [name]),
              icon: StudySymbols.search,
              tinted: false,
              chevron: true,
              onTap: () => pushStudy<void>(context, (context) => StudyTagView(booru: _booru, name: name)),
            ),
        ],
      ),
    ];
  }

  Widget _summary(BuildContext context) {
    final value = _board.summary;
    final label = TegnalColors.label.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final accent = StudyStyle.accent(context);
    Widget stat(IconData icon, String title, String number) => Semantics(
      container: true,
      child: Row(
        children: [
          SizedBox(width: 18, child: Icon(icon, size: 14, color: accent)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TegnalType.style(15, color: secondary),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            number,
            style: TegnalType.style(15, weight: FontWeight.w600, color: label).digits,
          ),
        ],
      ),
    );
    return Row(
      children: [
        Semantics(
          label: L10n.text('%@ of %@ learned', ['${value.learned}', '${value.total}']),
          excludeSemantics: true,
          child: SizedBox.square(
            dimension: 88,
            child: CustomPaint(
              painter: _RingPainter(
                fraction: value.total == 0 ? 0 : value.learned / value.total,
                track: StudyStyle.tertiaryFill.resolveFrom(context),
                color: accent,
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${value.learned}',
                      style: TegnalType.style(22, weight: FontWeight.w700, color: label).digits,
                    ),
                    Text('/ ${value.total}', style: TegnalType.style(11, color: secondary).digits),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Column(
            children: [
              stat(StudySymbols.review, L10n.text('To review'), '${value.due}'),
              const SizedBox(height: 10),
              stat(StudySymbols.answered, L10n.text('Answered today'), '${value.today}'),
              const SizedBox(height: 10),
              stat(StudySymbols.streak, L10n.text('Day streak'), '${value.streak}'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _unitRow(BuildContext context, StudyUnit unit) {
    final state = StudySummary.unit(unit, progress: _board.progress);
    final done = state.learned == state.total && state.total > 0;
    return FormRow(
      key: Key('study.unit.${unit.id}'),
      // The line under a unit starts where its title does.
      separatorInset: 66,
      // A unit row is 71 pt tall on iOS: about 14 pt above and below its tile and text.
      minHeight: 71,
      onTap: () => pushStudy<void>(context, (context) => StudyUnitView(booru: _booru, unit: unit, board: _board)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            StudyTile(icon: StudySymbols.unit(unit.symbol), width: 36, height: 36, radius: 9, size: 19),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    unit.title.resolved(),
                    style: TegnalType.style(17, weight: FontWeight.w500, color: TegnalColors.label.resolveFrom(context)),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    unit.summary.resolved(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TegnalType.style(12, color: TegnalColors.secondaryLabel.resolveFrom(context)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${state.learned}/${state.total}',
              style: TegnalType.style(13, color: done ? SystemColors.green.resolveFrom(context) : TegnalColors.secondaryLabel.resolveFrom(context)).digits,
            ),
            const SizedBox(width: 10),
            Icon(CupertinoIcons.chevron_right, size: 15, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.fraction, required this.track, required this.color});
  final double fraction;
  final Color track;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const width = 9.0;
    final rect = (Offset.zero & size).deflate(width / 2);
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = track,
    );
    if (fraction > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2 * fraction.clamp(0.0, 1.0),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round
          ..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fraction != fraction || old.track != track || old.color != color;
}

/// One unit: its summary, a quiz for it and its groups of tags.
class StudyUnitView extends StatefulWidget {
  const StudyUnitView({super.key, required this.booru, required this.unit, required this.board});
  final BooruContext booru;
  final StudyUnit unit;
  final StudyBoard board;

  @override
  State<StudyUnitView> createState() => _StudyUnitViewState();
}

class _StudyUnitViewState extends State<StudyUnitView> {
  Map<String, int> _counts = {};
  int _generation = 0;
  String _servers = '';

  BooruContext get _booru => widget.booru;
  StudyBoard get _board => widget.board;

  @override
  void initState() {
    super.initState();
    _board.addListener(_changed);
    _servers = _booru.store.selectedServerIDs.join(',');
    _booru.store.addListener(_storeChanged);
    _loadCounts();
  }

  @override
  void dispose() {
    _board.removeListener(_changed);
    _booru.store.removeListener(_storeChanged);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _storeChanged() {
    final servers = _booru.store.selectedServerIDs.join(',');
    if (servers != _servers) {
      _servers = servers;
      _loadCounts();
    }
  }

  Future<void> _loadCounts() async {
    final generation = ++_generation;
    final found = await StudyLookup.counts([for (final tag in widget.unit.tags) tag.name], store: _booru.store, source: _booru.source);
    if (mounted && generation == _generation) setState(() => _counts = found);
  }

  Future<void> _quiz() async {
    await openStudyQuiz(
      context,
      booru: _booru,
      session: StudySession(scope: StudyScope.unit(widget.unit.id), store: _booru.store, source: _booru.source),
    );
    if (mounted) _board.reload(_booru.store);
  }

  @override
  Widget build(BuildContext context) {
    final rowColor = FormColors.listRow.resolveFrom(context);
    final unit = widget.unit;
    return StudyPage(
      title: unit.title.resolved(),
      children: [
        const SizedBox(height: 25),
        FormSection(
          rowColor: rowColor,
          children: [
            FormRow(
              child: Text(unit.summary.resolved(), style: TegnalType.style(15, color: TegnalColors.secondaryLabel.resolveFrom(context))),
            ),
            FormRow(
              child: StudyButton(
                key: const Key('study.unitQuiz'),
                title: L10n.text('Quiz This Unit'),
                icon: StudySymbols.play,
                prominent: true,
                onPressed: _quiz,
              ),
            ),
          ],
        ),
        for (final group in unit.groups) ...[
          studySectionGap,
          FormSection(
            prominentHeader: true,
            rowColor: rowColor,
            header: Text(group.title.resolved()),
            children: [
              for (final tag in group.tags)
                KeyedSubtree(
                  key: Key('study.tag.${tag.name}'),
                  child: StudyTagRow(
                    tag: tag,
                    progress: _board.progress[tag.name],
                    count: _counts[tag.name],
                    onTap: () => pushStudy<void>(context, (context) => StudyTagView(booru: _booru, name: tag.name)),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
