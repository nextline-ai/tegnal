import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/study/study_dtext.dart';
import '../../core/study/study_engine.dart';
import '../../core/study/study_guide.dart';
import '../../core/study/study_models.dart';
import '../../core/support/l10n.dart';
import '../booru/booru_common.dart';
import '../design/grouped_form.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import 'study_widgets.dart';

/// The monospaced face of prompt text.
TextStyle studyMono(double size, {FontWeight weight = FontWeight.w400, Color? color}) =>
    TegnalType.style(size, weight: weight, color: color).copyWith(fontFamily: 'monospace', fontFamilyFallback: const []);

/// `StudyLessonView.text`: running text with the words between backticks set as prompt syntax,
/// monospaced in the accent colour.
TextSpan studyProse(String source, {required TextStyle style, required Color accent}) => TextSpan(
  style: style,
  children: [
    for (final (index, piece) in source.split('`').indexed)
      if (piece.isNotEmpty)
        index.isOdd
            ? TextSpan(
                text: piece,
                style: studyMono(style.fontSize ?? 17, weight: FontWeight.w500, color: accent),
              )
            : TextSpan(text: piece),
  ],
);

/// `StudyGuideView`: the lessons on writing prompts, listed.
class StudyGuideView extends StatefulWidget {
  const StudyGuideView({super.key, required this.booru});
  final BooruContext booru;

  @override
  State<StudyGuideView> createState() => _StudyGuideViewState();
}

class _StudyGuideViewState extends State<StudyGuideView> {
  @override
  Widget build(BuildContext context) {
    final guide = StudyGuide.bundled;
    final finished = StudyGuide.finished(widget.booru.booruDefaults.string(StudyGuide.finishedKey) ?? '');
    return StudyPage(
      title: L10n.text('Writing Prompts'),
      children: [
        FormSection(
          rowColor: StudyPresentation.rowColor(context),
          footer: Text(
            L10n.text(
              'Written from the documentation of NovelAI, the Stable Diffusion web UI and the model cards, as read in %@. Each lesson lists its sources.',
              [guide.checked],
            ),
          ),
          children: [
            for (final lesson in guide.lessons)
              StudyLinkRow(
                key: Key('study.lesson.${lesson.id}'),
                icon: StudySymbols.lesson(lesson.symbol),
                title: lesson.title.resolved(),
                detail: lesson.summary.resolved(),
                trailing: finished.contains(lesson.id)
                    ? Semantics(
                        label: L10n.text('Learned'),
                        child: Icon(StudySymbols.right, size: 22, color: SystemColors.green.resolveFrom(context)),
                      )
                    : null,
                onTap: () async {
                  await pushStudy<void>(context, (context) => StudyLessonView(booru: widget.booru, lesson: lesson));
                  if (mounted) setState(() {});
                },
              ),
          ],
        ),
      ],
    );
  }
}

/// `StudyCodeBlock`: prompt text in a box, copied with a tap.
class StudyCodeBlock extends StatefulWidget {
  const StudyCodeBlock({super.key, required this.code, this.note});
  final String code;
  final String? note;

  @override
  State<StudyCodeBlock> createState() => _StudyCodeBlockState();
}

class _StudyCodeBlockState extends State<StudyCodeBlock> {
  bool _copied = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.code));
    setState(() => _copied = true);
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final note = widget.note;
    return Semantics(
      button: true,
      label: widget.code,
      hint: L10n.text('Copy Prompt'),
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _copy,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: ShapeDecoration(
            color: StudyStyle.tertiaryFill.resolveFrom(context),
            shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (note != null && note.isNotEmpty) ...[Text(note, style: TegnalType.style(12, color: secondary)), const SizedBox(height: 5)],
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(widget.code, style: studyMono(16, color: TegnalColors.label.resolveFrom(context))),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Icon(
                      _copied ? StudySymbols.copied : StudySymbols.copy,
                      size: 13,
                      color: _copied ? SystemColors.green.resolveFrom(context) : secondary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `StudyLessonView`: one lesson, with its parts, examples, questions and sources.
class StudyLessonView extends StatefulWidget {
  const StudyLessonView({super.key, required this.booru, required this.lesson});
  final BooruContext booru;
  final StudyLesson lesson;

  @override
  State<StudyLessonView> createState() => _StudyLessonViewState();
}

class _StudyLessonViewState extends State<StudyLessonView> {
  /// The choice made for each question, by its place in the lesson.
  final Map<int, int> _chosen = {};

  StudyLesson get _lesson => widget.lesson;

  void _choose(int question, int place) {
    if (_chosen[question] != null) return;
    setState(() => _chosen[question] = place);
    _finishIfAllRight();
  }

  void _finishIfAllRight() {
    final checks = _lesson.checks;
    if (checks.isEmpty) return;
    for (var index = 0; index < checks.length; index++) {
      if (_chosen[index] != checks[index].answer) return;
    }
    final defaults = widget.booru.booruDefaults;
    defaults.set(StudyGuide.finishedKey, StudyGuide.finishing(_lesson.id, stored: defaults.string(StudyGuide.finishedKey) ?? ''));
  }

  @override
  Widget build(BuildContext context) {
    final rowColor = StudyPresentation.rowColor(context);
    final lesson = _lesson;
    final label = TegnalColors.label.resolveFrom(context);
    final accent = StudyStyle.accent(context);
    return StudyPage(
      title: lesson.title.resolved(),
      children: [
        FormSection(
          rowColor: rowColor,
          header: Text(lesson.summary.resolved()),
          children: [
            for (final part in lesson.parts)
              FormRow(
                child: SizedBox(
                  width: double.infinity,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if ((part.heading?.resolved() ?? '').isNotEmpty) ...[
                          Text(
                            part.heading!.resolved(),
                            style: TegnalType.style(17, weight: FontWeight.w600, color: label),
                          ),
                          const SizedBox(height: 10),
                        ],
                        if ((part.body?.resolved() ?? '').isNotEmpty) ...[
                          StudySelectable(
                            child: Text.rich(
                              studyProse(
                                part.body!.resolved(),
                                style: TegnalType.style(17, color: label),
                                accent: accent,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                        ],
                        for (final (index, example) in part.examples.indexed) ...[
                          if (index > 0) const SizedBox(height: 10),
                          StudyCodeBlock(code: example.code, note: example.note?.resolved()),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (lesson.tool == 'emphasis') ...[studySectionGap, StudyEmphasisTool(rowColor: rowColor)],
        if (lesson.checks.isNotEmpty) ...[
          studySectionGap,
          FormSection(
            rowColor: rowColor,
            header: Text(L10n.text('Check Yourself')),
            children: [for (final (index, check) in lesson.checks.indexed) _question(context, index, check)],
          ),
        ],
        if (lesson.sources.isNotEmpty) ...[
          studySectionGap,
          FormSection(
            rowColor: rowColor,
            header: Text(L10n.text('Sources')),
            children: [
              for (final source in lesson.sources)
                if (Uri.tryParse(source) case final url?)
                  FormRow(
                    onTap: () => launchUrl(url, mode: LaunchMode.externalApplication),
                    child: Text(
                      source.replaceAll('https://', ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TegnalType.style(13, color: accent),
                    ),
                  ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _question(BuildContext context, int index, StudyLessonCheck check) {
    final picked = _chosen[index];
    final green = SystemColors.green.resolveFrom(context);
    final red = SystemColors.red.resolveFrom(context);
    final label = TegnalColors.label.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final right = picked == check.answer;
    return FormRow(
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                check.question.resolved(),
                style: TegnalType.style(15, weight: FontWeight.w600, color: label),
              ),
              for (final (place, choice) in check.choices.indexed) ...[
                const SizedBox(height: 10),
                Builder(
                  builder: (context) {
                    final color = picked == null
                        ? null
                        : place == check.answer
                        ? green
                        : place == picked
                        ? red
                        : null;
                    return Semantics(
                      button: true,
                      value: color == green ? L10n.text('Correct') : (color == red ? L10n.text('Incorrect') : ''),
                      child: GestureDetector(
                        key: Key('study.check.$index.$place'),
                        behavior: HitTestBehavior.opaque,
                        onTap: picked == null ? () => _choose(index, place) : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: ShapeDecoration(
                            color: Color.alphaBlend(
                              (color ?? const Color(0x00000000)).withValues(alpha: color == null ? 0 : 0.14),
                              StudyStyle.tertiaryFill.resolveFrom(context),
                            ),
                            shape: RoundedSuperellipseBorder(
                              borderRadius: BorderRadius.circular(10),
                              side: color == null ? BorderSide.none : BorderSide(color: color, width: 1.5),
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(choice, style: studyMono(16, color: label)),
                              ),
                              if (color != null) ...[
                                const SizedBox(width: 8),
                                Icon(color == green ? StudySymbols.right : StudySymbols.wrong, size: 20, color: color),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
              if (picked != null) ...[
                const SizedBox(height: 10),
                Row(
                  key: Key('study.check.$index.why'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(right ? StudySymbols.right : StudySymbols.wrong, size: 16, color: right ? green : red),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text.rich(
                        studyProse(
                          check.why.resolved(),
                          style: TegnalType.style(13, color: secondary),
                          accent: StudyStyle.accent(context),
                        ),
                      ),
                    ),
                  ],
                ),
                if (!right) ...[
                  const SizedBox(height: 10),
                  GestureDetector(
                    key: Key('study.check.$index.retry'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _chosen.remove(index)),
                    child: Text(L10n.text('Try Again'), style: TegnalType.style(13, color: StudyStyle.accent(context))),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// `StudyEmphasisTool`: type a tag, set how strongly it should count, and read it in each notation.
class StudyEmphasisTool extends StatefulWidget {
  const StudyEmphasisTool({super.key, required this.rowColor});
  final Color rowColor;

  @override
  State<StudyEmphasisTool> createState() => _StudyEmphasisToolState();
}

class _StudyEmphasisToolState extends State<StudyEmphasisTool> {
  final _words = TextEditingController(text: 'rain');
  double _weight = 1.2;

  @override
  void initState() {
    super.initState();
    _words.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _words.dispose();
    super.dispose();
  }

  void _step(int direction) => setState(() => _weight = ((_weight + direction * 0.05).clamp(0.5, 2.0) * 100).round() / 100);

  @override
  Widget build(BuildContext context) {
    final label = TegnalColors.label.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return FormSection(
      rowColor: widget.rowColor,
      header: Text(L10n.text('Try It')),
      footer: Text(L10n.text('Braces move in steps of 1.05, so they give the nearest weight they can.')),
      children: [
        FormRow(
          child: CupertinoTextField.borderless(
            key: const Key('study.emphasis.tag'),
            controller: _words,
            padding: EdgeInsets.zero,
            placeholder: L10n.text('Tag'),
            textCapitalization: TextCapitalization.none,
            autocorrect: false,
            enableSuggestions: false,
            style: studyMono(17, color: label),
            placeholderStyle: studyMono(17, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
          ),
        ),
        FormRow(
          key: const Key('study.emphasis.weight'),
          child: Row(
            children: [
              Expanded(child: Text(L10n.text('Weight'))),
              Text(
                StudyEmphasis.number(_weight),
                key: const Key('study.emphasis.value'),
                style: TegnalType.style(17, color: secondary).digits,
              ),
              const SizedBox(width: 12),
              _Stepper(onMinus: _weight > 0.5 ? () => _step(-1) : null, onPlus: _weight < 2 ? () => _step(1) : null),
            ],
          ),
        ),
        _row('NovelAI { }', StudyEmphasis.braces),
        _row('NovelAI ::', StudyEmphasis.numbered),
        _row('Stable Diffusion', StudyEmphasis.weighted),
      ],
    );
  }

  Widget _row(String title, StudyEmphasis kind) {
    final tag = StudyPrompt.words(StudyDText.tagName(_words.text));
    final real = kind.effective(_weight);
    final note = (real - _weight).abs() > 0.0001 ? '$title · ${StudyEmphasis.number((real * 1000).round() / 1000)}' : title;
    return FormRow(
      key: Key('study.emphasis.${kind.name}'),
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: StudyCodeBlock(
            code: kind.written(tag, weight: _weight),
            note: note,
          ),
        ),
      ),
    );
  }
}

/// `Stepper`: a minus and a plus in one rounded control.
class _Stepper extends StatelessWidget {
  const _Stepper({required this.onMinus, required this.onPlus});
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;

  @override
  Widget build(BuildContext context) {
    final label = TegnalColors.label.resolveFrom(context);
    final disabled = TegnalColors.tertiaryLabel.resolveFrom(context);
    Widget side(Key key, IconData icon, VoidCallback? onTap) => GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(width: 47, height: 32, child: Icon(icon, size: 16, color: onTap == null ? disabled : label)),
    );
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: StudyStyle.tertiaryFill.resolveFrom(context),
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(9)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          side(const Key('study.emphasis.minus'), CupertinoIcons.minus, onMinus),
          Container(width: 0.5, height: 16, color: TegnalColors.separator.resolveFrom(context)),
          side(const Key('study.emphasis.plus'), CupertinoIcons.plus, onPlus),
        ],
      ),
    );
  }
}
