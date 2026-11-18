import 'dart:async';
import 'dart:typed_data';

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/booru/booru_models.dart';
import '../../core/study/study_models.dart';
import '../../core/study/study_session.dart';
import '../../core/study/study_store.dart';
import '../../core/support/l10n.dart';
import '../booru/booru_common.dart';
import '../design/grouped_form.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import '../navigation/app_header.dart';
import 'study_result_view.dart';
import 'study_tag_view.dart';
import 'study_widgets.dart';

/// Opens one round full screen over everything, as `appFullScreenCover` with `StudyQuizView` does.
/// The future completes when the round is closed.
Future<void> openStudyQuiz(BuildContext context, {required BooruContext booru, required StudySession session}) =>
    Navigator.of(context, rootNavigator: true).push<void>(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 380),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (context, animation, secondary) => StudyQuizHost(booru: booru, session: session),
        transitionsBuilder: (context, animation, secondary, child) => SlideTransition(
          position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: child,
        ),
      ),
    );

/// The round's own navigation stack, so that a tag's page opens inside it and Close returns to where the round began.
class StudyQuizHost extends StatefulWidget {
  const StudyQuizHost({super.key, required this.booru, required this.session});
  final BooruContext booru;
  final StudySession session;

  @override
  State<StudyQuizHost> createState() => _StudyQuizHostState();
}

class _StudyQuizHostState extends State<StudyQuizHost> {
  final _navigator = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) => NavigatorPopHandler<Object?>(
    onPopWithResult: (_) {
      final nested = _navigator.currentState;
      if (nested != null && nested.canPop()) {
        nested.pop();
      } else {
        Navigator.of(context, rootNavigator: true).maybePop();
      }
    },
    child: Navigator(
      key: _navigator,
      onGenerateRoute: (settings) => CupertinoPageRoute<void>(
        settings: settings,
        builder: (context) => StudyQuizView(booru: widget.booru, session: widget.session),
      ),
    ),
  );
}

/// One round of questions, shown over the whole screen.
class StudyQuizView extends StatefulWidget {
  const StudyQuizView({super.key, required this.booru, required this.session});
  final BooruContext booru;
  final StudySession session;

  @override
  State<StudyQuizView> createState() => _StudyQuizViewState();
}

class _StudyQuizViewState extends State<StudyQuizView> {
  late StudySession _session;
  final _scroll = ScrollController();
  final _explanation = GlobalKey();
  Timer? _reveal;
  String? _shownQuestion;
  bool _wasAnswered = false;
  bool _wasFinished = false;
  final _board = StudyBoard();

  /// How things stood when the round began, so the results can show what the round changed.
  StudySummary? _before;

  /// The index chosen, once an answer is given.
  int? get _answered => _session.phase.kind == StudyPhaseKind.answered ? _session.phase.choice : null;

  @override
  void initState() {
    super.initState();
    _attach(widget.session);
  }

  void _attach(StudySession session) {
    _session = session..addListener(_changed);
    _shownQuestion = null;
    _wasAnswered = false;
    _wasFinished = false;
    _board.reload(widget.booru.store);
    _before = _board.summary;
    session.start();
  }

  @override
  void dispose() {
    _reveal?.cancel();
    _session.removeListener(_changed);
    _board.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final question = _session.question?.id;
    final answered = _answered != null;
    if (question != _shownQuestion) {
      _shownQuestion = question;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
    // The meaning of the right answer is the lesson, so it is brought into view once an answer is given.
    if (answered && !_wasAnswered) {
      _reveal?.cancel();
      _reveal = Timer(const Duration(milliseconds: 120), () {
        final target = _explanation.currentContext;
        if (mounted && target != null) Scrollable.ensureVisible(target, alignment: 1, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      });
    }
    _wasAnswered = answered;
    final finished = _session.phase.kind == StudyPhaseKind.finished;
    if (finished && !_wasFinished) _board.reload(widget.booru.store);
    _wasFinished = finished;
    setState(() {});
  }

  void _close() => Navigator.of(context, rootNavigator: true).pop();

  void _again() {
    final old = _session;
    old.removeListener(_changed);
    _attach(StudySession(scope: old.scope, store: widget.booru.store, source: widget.booru.source));
    old.dispose();
    setState(() {});
  }

  void _openTag(StudyTag tag) => pushStudy<void>(context, (context) => StudyTagView(booru: widget.booru, name: tag.name));

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final Widget body;
    switch (session.phase.kind) {
      case StudyPhaseKind.finished:
        body = _finished(context);
      case StudyPhaseKind.loading when session.question == null:
        body = const Center(child: CupertinoActivityIndicator());
      default:
        final question = session.question;
        body = question == null ? const SizedBox.shrink() : _asking(context, question);
    }
    final answered = _answered;
    return ColoredBox(
      color: FormColors.listBackground.resolveFrom(context),
      child: Stack(
        children: [
          Positioned.fill(child: body),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: _QuizBar(
              onClose: _close,
              progress: session.phase.kind != StudyPhaseKind.finished && session.tags.isNotEmpty
                  ? ((session.index + (answered == null ? 0 : 1)) / session.tags.length).clamp(0.0, 1.0)
                  : null,
              label: L10n.text('Question %@ of %@', ['${session.index + 1}', '${session.tags.length}']),
            ),
          ),
        ],
      ),
    );
  }

  // MARK: Asking

  Widget _asking(BuildContext context, StudyQuestion question) {
    final media = MediaQuery.of(context);
    final answered = _answered;
    final top = media.padding.top + rootBarHeight;
    final regular = media.size.width >= 600;
    return Stack(
      children: [
        // Once answered the scroll view ends above the Next bar, so the explanation card ends there too.
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          bottom: answered != null ? _barHeight + media.padding.bottom : 0,
          child: IgnorePointer(
            ignoring: _session.phase == StudyPhase.loading,
            child: SingleChildScrollView(
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(20, top + 12, 20, answered != null ? 12 : 24 + media.padding.bottom),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      switch (question.kind) {
                        StudyQuestionKind.pictureToTag => _pictureQuestion(context, question, regular),
                        StudyQuestionKind.meaningToTag => _meaningQuestion(context, question),
                        StudyQuestionKind.tagToPicture => _tagQuestion(context, question),
                      },
                      if (answered != null) ...[const SizedBox(height: 18), KeyedSubtree(key: _explanation, child: _explain(context, question))],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (answered != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: StudyBottomBar(
              children: [
                Expanded(
                  child: StudyButton(
                    key: const Key('study.next'),
                    title: L10n.text(_session.index + 1 >= _session.tags.length ? 'See Results' : 'Next'),
                    prominent: true,
                    onPressed: () => _session.advance(),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static const _barHeight = 74.0;

  Widget _pictureQuestion(BuildContext context, StudyQuestion question, bool regular) {
    final post = question.posts.firstOrNull;
    final server = post == null ? null : _server(post);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (post != null && server != null)
          Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: regular ? 520 : 320),
              child: AspectRatio(
                aspectRatio: _aspect(post),
                child: ClipRSuperellipse(
                  key: const Key('study.picture'),
                  borderRadius: BorderRadius.circular(14),
                  child: StudyPicture(booru: widget.booru, post: post, server: server),
                ),
              ),
            ),
          ),
        const SizedBox(height: 18),
        _prompt(context, L10n.text('Which tag does this picture carry?')),
        const SizedBox(height: 18),
        _choices(context, question),
      ],
    );
  }

  Widget _meaningQuestion(BuildContext context, StudyQuestion question) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        padding: const EdgeInsets.all(18),
        decoration: ShapeDecoration(
          color: FormColors.listRow.resolveFrom(context),
          shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: Text(
          question.tag.note.resolved(),
          style: TegnalType.style(20, weight: FontWeight.w500, color: TegnalColors.label.resolveFrom(context)),
        ),
      ),
      const SizedBox(height: 18),
      _prompt(context, L10n.text('Which tag means this?')),
      const SizedBox(height: 18),
      _choices(context, question),
    ],
  );

  Widget _tagQuestion(BuildContext context, StudyQuestion question) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      // Tags are asked in the words a prompt is written in, so no translated name is shown beside them.
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          question.tag.english,
          textAlign: TextAlign.center,
          style: TegnalType.style(28, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
        ),
      ),
      const SizedBox(height: 18),
      _prompt(context, L10n.text('Which picture carries this tag?')),
      const SizedBox(height: 18),
      _pictures(context, question),
    ],
  );

  BooruServer? _server(BooruPost post) => widget.booru.store.servers.where((server) => server.id == post.serverID).firstOrNull;

  double _aspect(BooruPost post) => post.width > 0 && post.height > 0 ? (post.width / post.height).clamp(0.6, 2.0) : 1;

  Widget _prompt(BuildContext context, String text) => Text(
    text,
    style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
  );

  Color? _mark(BuildContext context, int index, StudyQuestion question) {
    final answered = _answered;
    if (answered == null) return null;
    if (index == question.answer) return SystemColors.green.resolveFrom(context);
    return index == answered ? SystemColors.red.resolveFrom(context) : null;
  }

  /// Tags are asked in the words a prompt is written in, so no translated name is shown beside them.
  /// Short tags share a line two by two; a long one keeps a line to itself.
  Widget _choices(BuildContext context, StudyQuestion question) {
    final media = MediaQuery.of(context);
    // `typeSize.isAccessibilitySize`: the text is scaled to roughly 1.6 times or more.
    final accessibility = media.textScaler.scale(17) / 17 >= 1.6;
    final limit = accessibility
        ? 0
        : media.size.width >= 600
        ? 22
        : 13;
    final rows = StudyQuestion.rows([for (final tag in question.choices) tag.english.characters.length], limit: limit);
    return Column(
      children: [
        for (final (position, row) in rows.indexed) ...[
          if (position > 0) const SizedBox(height: 10),
          Row(
            children: [
              for (final (place, index) in row.indexed) ...[
                if (place > 0) const SizedBox(width: 10),
                Expanded(child: _choice(context, index, question, paired: row.length > 1)),
              ],
            ],
          ),
        ],
      ],
    );
  }

  Widget _choice(BuildContext context, int index, StudyQuestion question, {required bool paired}) {
    final answered = _answered;
    final green = SystemColors.green.resolveFrom(context);
    final color = _mark(context, index, question);
    final mark = color == null ? null : (color == green ? StudySymbols.right : StudySymbols.wrong);
    final text = Text(
      question.choices[index].english,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textAlign: paired ? TextAlign.center : TextAlign.left,
      style: TegnalType.style(20, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
    );
    return Semantics(
      button: true,
      value: color == null ? '' : L10n.text(color == green ? 'Correct' : 'Incorrect'),
      child: GestureDetector(
        key: Key('study.choice.$index'),
        behavior: HitTestBehavior.opaque,
        onTap: answered == null ? () => _session.choose(index) : null,
        child: Container(
          constraints: const BoxConstraints(minHeight: 58),
          padding: EdgeInsets.symmetric(horizontal: paired ? 10 : 16, vertical: 12),
          decoration: ShapeDecoration(
            color: Color.alphaBlend((color ?? const Color(0x00000000)).withValues(alpha: color == null ? 0 : 0.14), FormColors.listRow.resolveFrom(context)),
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(14),
              side: color == null ? BorderSide.none : BorderSide(color: color, width: 1.5),
            ),
          ),
          // A paired cell keeps its mark in the top corner, so the tag stays centred.
          child: paired
              ? Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    Center(child: text),
                    if (mark != null) Positioned(top: -6, right: -4, child: Icon(mark, size: 16, color: color)),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: text),
                    if (mark != null) ...[const SizedBox(width: 10), Icon(mark, size: 20, color: color)],
                  ],
                ),
        ),
      ),
    );
  }

  Widget _pictures(BuildContext context, StudyQuestion question) {
    final answered = _answered;
    final green = SystemColors.green.resolveFrom(context);
    Widget cell(int index) {
      final post = question.posts[index];
      final server = _server(post);
      final color = _mark(context, index, question);
      return Semantics(
        button: true,
        label: L10n.text('Picture %@', ['${index + 1}']),
        child: GestureDetector(
          key: Key('study.choice.$index'),
          behavior: HitTestBehavior.opaque,
          onTap: answered == null ? () => _session.choose(index) : null,
          child: AspectRatio(
            aspectRatio: 0.8,
            child: ClipRSuperellipse(
              borderRadius: BorderRadius.circular(14),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (server == null)
                    ColoredBox(color: StudyStyle.tertiaryFill.resolveFrom(context))
                  else
                    StudyPicture(booru: widget.booru, post: post, server: server, fills: true),
                  if (color != null)
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          shape: RoundedSuperellipseBorder(
                            borderRadius: BorderRadius.circular(14),
                            side: BorderSide(color: color, width: 4),
                          ),
                        ),
                      ),
                    ),
                  if (color != null)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: const ShapeDecoration(color: Color(0xFFFFFFFF), shape: CircleBorder()),
                        child: Icon(color == green ? StudySymbols.right : StudySymbols.wrong, size: 28, color: color),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final count = question.posts.length;
    return Column(
      children: [
        for (var start = 0; start < count; start += 2) ...[
          if (start > 0) const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: cell(start)),
              const SizedBox(width: 10),
              Expanded(child: start + 1 < count ? cell(start + 1) : const SizedBox.shrink()),
            ],
          ),
        ],
      ],
    );
  }

  /// After an answer: what the right tag means, and what the chosen one means when it was wrong.
  Widget _explain(BuildContext context, StudyQuestion question) {
    final answered = _answered!;
    final right = answered == question.answer;
    final chosen = question.kind == StudyQuestionKind.tagToPicture || !question.choices.asMap().containsKey(answered) ? null : question.choices[answered];
    final color = right ? SystemColors.green.resolveFrom(context) : SystemColors.red.resolveFrom(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: ShapeDecoration(
        color: FormColors.listRow.resolveFrom(context),
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            key: const Key('study.verdict'),
            children: [
              Icon(right ? StudySymbols.right : StudySymbols.wrong, size: 20, color: color),
              const SizedBox(width: 6),
              Text(
                L10n.text(right ? 'Correct' : 'Incorrect'),
                style: TegnalType.style(17, weight: FontWeight.w600, color: color),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _meaning(context, question.tag),
          if (!right && chosen != null && chosen.name != question.tag.name) ...[
            const SizedBox(height: 12),
            Container(height: 0.5, color: TegnalColors.separator.resolveFrom(context)),
            const SizedBox(height: 12),
            _meaning(context, chosen),
          ],
          const SizedBox(height: 12),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openTag(question.tag),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(StudySymbols.info, size: 18, color: StudyStyle.accent(context)),
                const SizedBox(width: 6),
                Text(L10n.text('About This Tag'), style: TegnalType.style(15, color: StudyStyle.accent(context))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _meaning(BuildContext context, StudyTag tag) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        tag.english,
        style: TegnalType.style(15, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
      ),
      const SizedBox(height: 3),
      Text(tag.note.resolved(), style: TegnalType.style(15, color: TegnalColors.secondaryLabel.resolveFrom(context))),
    ],
  );

  // MARK: Results

  Widget _finished(BuildContext context) =>
      StudyResultView(session: _session, before: _before ?? _board.summary, after: _board.summary, onOpen: _openTag, onAgain: _again, onDone: _close);
}

/// The round's bar: Close at the leading edge and the progress through the questions in the middle.
class _QuizBar extends StatelessWidget {
  const _QuizBar({required this.onClose, required this.progress, required this.label});
  final VoidCallback onClose;

  /// 0 to 1, or null once the results show.
  final double? progress;
  final String label;

  @override
  Widget build(BuildContext context) {
    final background = FormColors.listBackground.resolveFrom(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [background, background.withValues(alpha: 0.9), background.withValues(alpha: 0)],
          stops: const [0, 0.62, 1],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top, bottom: 16),
        child: SizedBox(
          height: rootBarHeight,
          child: Stack(
            children: [
              Positioned(
                left: 16,
                top: 0,
                child: GlassTextButton(key: const Key('study.close'), label: L10n.text('Close'), elevated: false, onPressed: onClose),
              ),
              if (progress case final value?)
                Positioned.fill(
                  child: Align(
                    alignment: const Alignment(0, -0.2),
                    child: Semantics(
                      label: label,
                      child: SizedBox(
                        width: 160,
                        height: 4,
                        child: DecoratedBox(
                          decoration: ShapeDecoration(color: StudyStyle.tertiaryFill.resolveFrom(context), shape: const StadiumBorder()),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: value,
                              child: DecoratedBox(
                                decoration: ShapeDecoration(color: StudyStyle.accent(context), shape: const StadiumBorder()),
                                child: const SizedBox.expand(),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `StudyPicture`: a picture at reading size for a question or an example, loaded through the image library's own cache.
class StudyPicture extends StatefulWidget {
  const StudyPicture({super.key, required this.booru, required this.post, required this.server, this.fills = false});
  final BooruContext booru;
  final BooruPost post;
  final BooruServer server;
  final bool fills;

  @override
  State<StudyPicture> createState() => _StudyPictureState();
}

class _StudyPictureState extends State<StudyPicture> {
  Uint8List? _image;
  bool _failed = false;
  int _generation = 0;

  String? get _url => widget.post.reducedDataURL ?? widget.post.sampleURL ?? widget.post.previewURL;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(StudyPicture old) {
    super.didUpdateWidget(old);
    if (old.post.id != widget.post.id) {
      _image = null;
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _failed = false;
    final url = _url;
    if (widget.booru.fixture) return;
    if (url == null) {
      _failed = true;
      return;
    }
    final cached = widget.booru.thumbnails.cached(url, widget.server);
    if (cached != null) {
      _image = cached;
      return;
    }
    try {
      final data = await widget.booru.thumbnails.load(url, widget.server);
      if (mounted && generation == _generation) setState(() => _image = data);
    } on Object {
      if (mounted && generation == _generation) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final Widget content;
    if (widget.booru.fixture) {
      content = DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [SystemColors.indigo.resolveFrom(context), SystemColors.cyan.resolveFrom(context).withValues(alpha: 0.6)],
          ),
        ),
        child: Center(child: Icon(StudySymbols.picture, size: 44, color: const Color(0xFFFFFFFF).withValues(alpha: 0.8))),
      );
    } else if (image != null) {
      content = Image.memory(
        image,
        fit: widget.fills ? BoxFit.cover : BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (context, _, _) => _failure(context),
      );
    } else if (_failed) {
      content = _failure(context);
    } else {
      content = const Center(child: CupertinoActivityIndicator());
    }
    return ColoredBox(
      color: StudyStyle.tertiaryFill.resolveFrom(context),
      child: SizedBox.expand(child: content),
    );
  }

  Widget _failure(BuildContext context) =>
      Center(child: Icon(CupertinoIcons.exclamationmark_triangle, color: TegnalColors.secondaryLabel.resolveFrom(context)));
}
