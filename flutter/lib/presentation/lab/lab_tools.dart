import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/lab/lab_course.dart';
import '../../core/support/l10n.dart';
import '../design/ios_controls.dart';
import '../design/tegnal_theme.dart';
import '../study_mode/study_kit.dart';
import 'lab_kit.dart';

// The hands-on part of an episode, chosen by the tool's kind. Ported from `LabTools.swift`.

/// Shows the tool for [tool]. [onPass] is called once the learner has done what the tool asks.
class LabToolView extends StatelessWidget {
  const LabToolView({super.key, required this.tool, required this.passed, required this.onPass});
  final LabTool tool;
  final bool passed;
  final VoidCallback onPass;

  @override
  Widget build(BuildContext context) => switch (tool.kind) {
    LabToolKind.switches => LabSwitchesTool(tool: tool, passed: passed, onPass: onPass),
    LabToolKind.chips =>
      tool.mode == 'toggle' ? LabComposeTool(tool: tool, passed: passed, onPass: onPass) : LabChipsTool(tool: tool, passed: passed, onPass: onPass),
    LabToolKind.stamps => LabStampsTool(tool: tool, passed: passed, onPass: onPass),
    LabToolKind.marks => LabMarksTool(tool: tool, passed: passed, onPass: onPass),
    LabToolKind.equip => LabEquipTool(tool: tool, passed: passed, onPass: onPass),
    LabToolKind.rot => LabRotTool(tool: tool, passed: passed, onPass: onPass),
  };
}

Color _quietLine(BuildContext context) => labSecondary(context).withValues(alpha: 0.3);

/// The AI's answer under a tool, with a small label above it in the measuring voice.
class _LabAnswer extends StatelessWidget {
  const _LabAnswer({this.meta, required this.text, this.note, this.tone = LabTone.measure});
  final String? meta;
  final String text;
  final String? note;
  final LabTone tone;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('lab.answer'),
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: ShapeDecoration(
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: _quietLine(context)),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (meta != null && meta!.isNotEmpty) ...[Text(meta!, style: LabFont.number(11, color: labSecondary(context), tracking: 1)), const SizedBox(height: 8)],
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          layoutBuilder: (current, previous) => Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
          child: SizedBox(
            key: ValueKey(text),
            width: double.infinity,
            child: Text(studyWords(text), style: LabFont.text(15, color: labLabel(context))),
          ),
        ),
        if (note != null && note!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            note!,
            style: LabFont.text(13, weight: FontWeight.w600, color: labToneColor(context, tone)),
          ),
        ],
      ],
    ),
  );
}

/// Pieces that wrap in rows, like words.
class _Flow extends StatelessWidget {
  const _Flow({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: Wrap(spacing: 8, runSpacing: 8, children: children),
  );
}

/// A chip: glass when off, the main button's ink when on.
class _Chip extends StatelessWidget {
  const _Chip({super.key, required this.label, required this.on, required this.onTap, this.icon});
  final String label;
  final bool on;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => LabButton(
    onPressed: onTap,
    style: on ? LabButtonStyle.primary : LabButtonStyle.secondary,
    radius: null,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 15), const SizedBox(width: 6)],
        Flexible(
          child: Text(
            label,
            style: LabFont.text(15, weight: FontWeight.w600, color: on ? LabPalette.onPrimary.resolveFrom(context) : labLabel(context)),
          ),
        ),
      ],
    ),
  );
}

Widget _grouped(BuildContext context, List<Widget> rows, {double inset = 16}) => Container(
  decoration: ShapeDecoration(
    color: TegnalColors.secondaryBackground.resolveFrom(context),
    shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(18)),
  ),
  child: Column(
    children: [
      for (final (index, row) in rows.indexed) ...[
        if (index > 0)
          Container(
            height: 0.5,
            margin: EdgeInsets.only(left: inset),
            color: TegnalColors.separator.resolveFrom(context),
          ),
        row,
      ],
    ],
  ),
);

// MARK: - Switches

/// Switches under a prompt: each setting has its own answer, or, once every switch is set, an answer put together from them.
class LabSwitchesTool extends StatefulWidget {
  const LabSwitchesTool({super.key, required this.tool, required this.passed, required this.onPass});
  final LabTool tool;
  final bool passed;
  final VoidCallback onPass;
  @override
  State<LabSwitchesTool> createState() => _LabSwitchesToolState();
}

class _LabSwitchesToolState extends State<LabSwitchesTool> {
  late List<int?> picks = [for (final control in controls) control.unset == true ? null : 0];

  /// The passing settings reached so far, for tools that ask for more than one.
  final Set<String> reached = {};

  LabTool get tool => widget.tool;
  List<LabControl> get controls => tool.controls ?? const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  ({String? meta, String text, int score})? get composed {
    final compose = tool.compose;
    if (compose == null || picks.isEmpty || picks.any((pick) => pick == null)) return null;
    final lines = [
      for (final (index, control) in controls.indexed)
        if (control.options[picks[index]!].line case final line?) '· ${line.text}',
    ];
    final text = [?compose.head?.text, ...lines, ?compose.tail?.text].join('\n');
    return (meta: compose.meta?.text, text: text, score: compose.score);
  }

  LabResult? get result => (tool.results ?? const <LabResult>[]).where((result) => result.matches(picks)).firstOrNull;

  void _check() {
    if (composed != null) return _pass();
    final result = this.result;
    if (result == null || result.pass != true) return;
    reached.add(picks.map((pick) => pick ?? -1).join(','));
    if (reached.length >= (tool.need ?? 1)) _pass();
  }

  void _pass() {
    if (widget.passed) return;
    LabHaptic.pass();
    widget.onPass();
  }

  @override
  Widget build(BuildContext context) {
    final composed = this.composed, result = this.result;
    final score = composed?.score ?? result?.score ?? 0;
    final need = tool.need;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (tool.prompt != null) ...[LabPromptBox(text: tool.prompt!.text), const SizedBox(height: 16)],
        for (final (index, control) in controls.indexed) ...[
          _LabControlView(
            control: control,
            index: index,
            pick: picks[index],
            onPick: (value) {
              setState(() => picks[index] = value);
              LabHaptic.tick();
              _check();
            },
          ),
          const SizedBox(height: 16),
        ],
        if (tool.gauge != null) ...[
          LabMeter(label: tool.gauge!.text, value: score, tone: widget.passed ? LabTone.pass : LabTone.measure),
          const SizedBox(height: 16),
        ],
        if (composed != null)
          _LabAnswer(meta: composed.meta, text: composed.text, tone: LabTone.pass)
        else if (result != null)
          _LabAnswer(meta: result.meta?.text, text: result.reply.text, note: result.note?.text, tone: result.pass == true ? LabTone.pass : LabTone.measure),
        if (need != null && need > 1) ...[
          const SizedBox(height: 12),
          Text(
            L10n.text('lab.switches.reached', ['${reached.length < need ? reached.length : need}', '$need']),
            style: LabFont.number(12, color: labSecondary(context)),
          ),
        ],
      ],
    );
  }
}

/// One switch: a segmented control when its positions are short, a column of rows when they are sentences.
class _LabControlView extends StatelessWidget {
  const _LabControlView({required this.control, required this.index, required this.pick, required this.onPick});
  final LabControl control;
  final int index;
  final int? pick;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    final long = control.options.any((option) => option.label.text.characters.length > 12);
    final tint = TegnalColors.tint.resolveFrom(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          control.label.text,
          style: LabFont.text(13, weight: FontWeight.w600, color: labSecondary(context)),
        ),
        const SizedBox(height: 8),
        if (long)
          for (final (option, value) in control.options.indexed) ...[
            LabButton(
              key: Key('lab.switch.$index.$option'),
              onPressed: () => onPick(option),
              radius: 16,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    pick == option ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle,
                    size: 20,
                    color: pick == option ? tint : labSecondary(context),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      studyWords(value.label.text),
                      style: LabFont.text(15, weight: FontWeight.w500, color: labLabel(context)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ]
        else
          SizedBox(
            key: Key('lab.switch.$index'),
            width: double.infinity,
            child: TegnalSegmented<int?>(
              options: [for (final (option, value) in control.options.indexed) (option, value.label.text)],
              selected: pick,
              onSelected: (value) {
                if (value != null) onPick(value);
              },
            ),
          ),
      ],
    );
  }
}

// MARK: - Chips

/// Chips that go after the prompt, one at a time. Each press shows the AI's inner voice first, then its answer.
class LabChipsTool extends StatefulWidget {
  const LabChipsTool({super.key, required this.tool, required this.passed, required this.onPass});
  final LabTool tool;
  final bool passed;
  final VoidCallback onPass;
  @override
  State<LabChipsTool> createState() => _LabChipsToolState();
}

class _LabChipsToolState extends State<LabChipsTool> {
  int? chosen;
  final Map<int, int> presses = {};
  bool thinking = false;
  Timer? _timer;

  List<LabChip> get chips => widget.tool.chips ?? const [];

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _reply(LabChip chip, int count) {
    final replies = chip.replies ?? const [];
    if (replies.isEmpty) return '';
    return replies[(count < replies.length ? count : replies.length) - 1].text;
  }

  void _press(int index) {
    LabHaptic.tick();
    final chip = chips[index];
    setState(() {
      presses[index] = (presses[index] ?? 0) + 1;
      chosen = index;
      thinking = chip.think != null;
    });
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: chip.think != null ? 700 : 0), () {
      if (!mounted) return;
      setState(() => thinking = false);
      if (chip.pass == true && !widget.passed) {
        LabHaptic.pass();
        widget.onPass();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final chosen = this.chosen;
    final chip = chosen == null ? null : chips[chosen];
    final tint = TegnalColors.tint.resolveFrom(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LabPromptBox(
          text: widget.tool.prompt?.text ?? '',
          footer: [
            if (chip?.attach case final attach?)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: ShapeDecoration(
                  color: LabPalette.paper.withValues(alpha: 0.9),
                  shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(attach.text, style: LabFont.text(13, color: LabPalette.paperMuted)),
              ),
            if (chip != null)
              Text(
                '+ ${chip.label.text}',
                style: LabFont.text(14, weight: FontWeight.w600, color: tint),
              ),
          ],
        ),
        const SizedBox(height: 16),
        _Flow(
          children: [
            for (final (index, value) in chips.indexed) _Chip(key: Key('lab.chip.$index'), label: value.label.text, on: false, onTap: () => _press(index)),
          ],
        ),
        if (chip != null) ...[
          if (chip.think case final think?) ...[
            const SizedBox(height: 16),
            Row(
              key: const Key('lab.think'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(CupertinoIcons.lightbulb, size: 17, color: labSecondary(context)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    think.text,
                    style: LabFont.text(14, color: labSecondary(context)).copyWith(fontStyle: FontStyle.italic),
                  ),
                ),
              ],
            ),
          ],
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: thinking
                ? const SizedBox(width: double.infinity)
                : Column(
                    key: ValueKey('$chosen-${presses[chosen]}'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.tool.gauge != null) ...[
                        const SizedBox(height: 16),
                        LabMeter(label: widget.tool.gauge!.text, value: chip.score ?? 0, tone: chip.pass == true ? LabTone.pass : LabTone.measure),
                      ],
                      const SizedBox(height: 16),
                      _LabAnswer(text: _reply(chip, presses[chosen] ?? 1), tone: chip.pass == true ? LabTone.pass : LabTone.measure),
                    ],
                  ),
          ),
        ],
      ],
    );
  }
}

/// Chips that are switched on and off, each adding a line to a card the learner can copy.
class LabComposeTool extends StatefulWidget {
  const LabComposeTool({super.key, required this.tool, required this.passed, required this.onPass});
  final LabTool tool;
  final bool passed;
  final VoidCallback onPass;
  @override
  State<LabComposeTool> createState() => _LabComposeToolState();
}

class _LabComposeToolState extends State<LabComposeTool> {
  final Set<int> on = {};
  List<LabChip> get chips => widget.tool.chips ?? const [];

  @override
  Widget build(BuildContext context) {
    final lines = [
      for (final index in on.toList()..sort())
        if (chips[index].line case final line?) line.text,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Flow(
          children: [
            for (final (index, chip) in chips.indexed)
              _Chip(
                key: Key('lab.chip.$index'),
                label: chip.label.text,
                on: on.contains(index),
                icon: on.contains(index) ? CupertinoIcons.checkmark_alt : CupertinoIcons.add,
                onTap: () {
                  LabHaptic.tick();
                  setState(() => on.contains(index) ? on.remove(index) : on.add(index));
                  if (on.length >= (widget.tool.need ?? 1) && !widget.passed) {
                    LabHaptic.pass();
                    widget.onPass();
                  }
                },
              ),
          ],
        ),
        const SizedBox(height: 16),
        LabCardBackground(
          state: LabCardState.blank,
          radius: 18,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.tool.head?.text ?? '', style: LabFont.number(11, color: LabPalette.paperMuted, tracking: 1)),
                  const SizedBox(height: 10),
                  if (lines.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: LabDashedRule(color: LabPalette.paperRule),
                    )
                  else ...[
                    SizedBox(
                      width: double.infinity,
                      child: Text(
                        lines.join('\n'),
                        style: LabFont.text(15, weight: FontWeight.w500, color: LabPalette.paperInk),
                      ),
                    ),
                    const SizedBox(height: 10),
                    LabCopyButton(text: lines.join('\n'), color: LabPalette.paperInk),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// MARK: - Stamps

/// Paper cards one after another, each stamped with one of two verdicts; the answer shows once it is stamped.
class LabStampsTool extends StatefulWidget {
  const LabStampsTool({super.key, required this.tool, required this.passed, required this.onPass});
  final LabTool tool;
  final bool passed;
  final VoidCallback onPass;
  @override
  State<LabStampsTool> createState() => _LabStampsToolState();
}

class _LabStampsToolState extends State<LabStampsTool> {
  final List<int> stamped = [];
  List<LabStampItem> get items => widget.tool.items ?? const [];
  List<String> get labels => [for (final stamp in widget.tool.stamps ?? const <LabText>[]) stamp.text];

  void _stamp(int index) {
    if (items[stamped.length].answer == index) {
      LabHaptic.press();
    } else {
      LabMistake.of(context);
    }
    setState(() => stamped.add(index));
    if (stamped.length == items.length) {
      LabHaptic.pass();
      widget.onPass();
    }
  }

  @override
  Widget build(BuildContext context) {
    final done = stamped.length >= items.length;
    final right = [
      for (final (index, pick) in stamped.indexed)
        if (items[index].answer == pick) pick,
    ].length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${done ? items.length : stamped.length + 1} / ${items.length}', style: LabFont.number(12, color: labSecondary(context))),
        const SizedBox(height: 14),
        if (!done) ...[
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 380),
            transitionBuilder: (child, animation) => SlideTransition(
              position: Tween(begin: const Offset(0.3, 0), end: Offset.zero).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutBack)),
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: LabCardBackground(
              key: ValueKey(stamped.length),
              state: LabCardState.blank,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 90),
                      child: SizedBox(
                        width: double.infinity,
                        child: Text(labWords(items[stamped.length].text.text), style: LabFont.voice(21, color: LabPalette.paperInk)),
                      ),
                    ),
                    const SizedBox(height: 14),
                    const LabDashedRule(color: LabPalette.paperRule),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              for (final (index, label) in labels.indexed) ...[
                if (index > 0) const SizedBox(width: 10),
                Expanded(
                  child: LabButton(key: Key('lab.stamp.$index'), onPressed: () => _stamp(index), radius: 16, expand: true, child: Text(label)),
                ),
              ],
            ],
          ),
        ] else ...[
          Text(L10n.text('lab.stamps.score', ['$right', '${items.length}']), style: LabFont.number(15, color: LabPalette.pass.resolveFrom(context))),
          if (widget.tool.summary case final summary?) ...[
            const SizedBox(height: 6),
            Text(labWords(summary.text), style: LabFont.voice(22, color: labLabel(context))),
          ],
        ],
        for (final (index, pick) in stamped.indexed.toList().reversed) ...[
          const SizedBox(height: 8),
          // The stamp shows the right answer: green when it was picked, red when another was.
          _StampedRow(item: items[index], pick: pick, label: items[index].answer < labels.length ? labels[items[index].answer] : ''),
        ],
      ],
    );
  }
}

class _StampedRow extends StatelessWidget {
  const _StampedRow({required this.item, required this.pick, required this.label});
  final LabStampItem item;
  final int pick;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = item.answer == pick ? LabPalette.pass.resolveFrom(context) : LabPalette.fail.resolveFrom(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Transform.rotate(
            angle: -0.07,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                border: Border.all(color: color, width: 1.5),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                label,
                style: LabFont.text(12, weight: FontWeight.w800, color: color),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.text.text,
                  style: LabFont.text(14, weight: FontWeight.w600, color: labLabel(context)),
                ),
                if (item.reveal case final reveal?) ...[const SizedBox(height: 4), Text(reveal.text, style: LabFont.text(13, color: labSecondary(context)))],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// MARK: - Marks

/// Pieces of text to strike out (`cut`), stamp as made up (`flag`) or black out (`mask`).
class LabMarksTool extends StatefulWidget {
  const LabMarksTool({super.key, required this.tool, required this.passed, required this.onPass});
  final LabTool tool;
  final bool passed;
  final VoidCallback onPass;
  @override
  State<LabMarksTool> createState() => _LabMarksToolState();
}

class _LabMarksToolState extends State<LabMarksTool> {
  final Set<int> marked = {};
  int? shaking;
  String? complaint;
  final Stopwatch _clock = Stopwatch()..start();
  double? took;
  Timer? _timer;

  LabTool get tool => widget.tool;
  List<LabPiece> get pieces => tool.pieces ?? const [];
  String get style => tool.style ?? 'cut';
  int get targets => pieces.where((piece) => piece.isTarget).length;
  int get hits => marked.where((index) => pieces[index].isTarget).length;
  int get misses => marked.where((index) => !pieces[index].isTarget).length;
  int get score => targets == 0 ? 0 : ((hits - misses) * 100 ~/ targets).clamp(0, 100);

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _tap(int index) {
    final piece = pieces[index];
    if (style != 'cut' && !piece.isTarget) {
      // Only made-up or private pieces can be marked; anything else says why and stays.
      LabMistake.of(context);
      setState(() {
        complaint = tool.wrong?.text;
        shaking = index;
      });
      _timer?.cancel();
      _timer = Timer(const Duration(milliseconds: 180), () {
        if (mounted) setState(() => shaking = null);
        _timer = Timer(const Duration(milliseconds: 1400), () {
          if (mounted) setState(() => complaint = null);
        });
      });
      return;
    }
    if (style != 'cut' && marked.contains(index)) return;
    LabHaptic.tick();
    setState(() => marked.contains(index) ? marked.remove(index) : marked.add(index));
    if (hits == targets && misses == 0 && !widget.passed) {
      setState(() => took = _clock.elapsedMilliseconds / 1000);
      LabHaptic.pass();
      widget.onPass();
    }
  }

  @override
  Widget build(BuildContext context) {
    final LabText? output = misses > 0
        ? (tool.wrong ?? tool.before)
        : widget.passed
        ? tool.after
        : hits * 2 >= targets
        ? (tool.middle ?? tool.before)
        : tool.before;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (style == 'mask') _mask(context) else _lines(context),
        if (tool.gauge != null) ...[
          const SizedBox(height: 14),
          LabMeter(label: tool.gauge!.text, value: score, tone: misses > 0 ? LabTone.fail : (widget.passed ? LabTone.pass : LabTone.measure)),
        ],
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: complaint == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Text(
                    complaint!,
                    style: LabFont.text(13, weight: FontWeight.w600, color: LabPalette.fail.resolveFrom(context)),
                  ),
                ),
        ),
        if (style == 'cut' && output != null) ...[
          const SizedBox(height: 14),
          _LabAnswer(text: output.text, tone: misses > 0 ? LabTone.fail : (widget.passed ? LabTone.pass : LabTone.measure)),
        ],
        if (took != null && widget.passed) ...[
          const SizedBox(height: 14),
          Text(L10n.text('lab.marks.time', [took!.toStringAsFixed(1)]), style: LabFont.number(15, color: LabPalette.pass.resolveFrom(context))),
        ],
      ],
    );
  }

  Widget _shake(int index, Widget child) =>
      AnimatedSlide(offset: Offset(shaking == index ? 0.02 : 0, 0), duration: const Duration(milliseconds: 90), curve: Curves.elasticOut, child: child);

  Widget _lines(BuildContext context) {
    final fail = LabPalette.fail.resolveFrom(context);
    return _grouped(context, inset: 27, [
      for (final (index, piece) in pieces.indexed)
        _shake(
          index,
          GestureDetector(
            key: Key('lab.piece.$index'),
            behavior: HitTestBehavior.opaque,
            onTap: () => _tap(index),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 3,
                      height: 18,
                      margin: const EdgeInsets.only(top: 1),
                      decoration: BoxDecoration(
                        color: marked.contains(index) ? labSecondary(context).withValues(alpha: 0.3) : LabPalette.gauge.resolveFrom(context),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            studyWords(piece.text.text),
                            style: LabFont.text(
                              14,
                              color: style == 'cut' && marked.contains(index) ? labSecondary(context) : labLabel(context),
                            ).copyWith(decoration: style == 'cut' && marked.contains(index) ? TextDecoration.lineThrough : null),
                          ),
                          if (style == 'flag' && marked.contains(index) && piece.why != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              piece.why!.text,
                              style: LabFont.text(12, weight: FontWeight.w600, color: fail),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (style == 'flag' && marked.contains(index))
                      Transform.rotate(
                        angle: -0.1,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                          decoration: BoxDecoration(
                            border: Border.all(color: fail, width: 1.5),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            L10n.text('lab.marks.fake'),
                            style: LabFont.text(11, weight: FontWeight.w800, color: fail),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
    ]);
  }

  Widget _mask(BuildContext context) {
    final label = labLabel(context), background = TegnalColors.background.resolveFrom(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: ShapeDecoration(
        color: TegnalColors.secondaryBackground.resolveFrom(context),
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(18)),
      ),
      child: Wrap(
        runSpacing: 6,
        children: [
          for (final (index, piece) in pieces.indexed)
            _shake(
              index,
              GestureDetector(
                key: Key('lab.piece.$index'),
                onTap: () => _tap(index),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: marked.contains(index) ? 6 : 0, vertical: 2),
                  decoration: BoxDecoration(color: marked.contains(index) ? label : null, borderRadius: BorderRadius.circular(5)),
                  child: Text(
                    marked.contains(index) ? (piece.swap?.text ?? '●●●') : piece.text.text,
                    style: LabFont.text(
                      16,
                      weight: piece.isTarget || marked.contains(index) ? FontWeight.w600 : FontWeight.w400,
                      color: marked.contains(index) ? background : label,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// MARK: - Equip

/// A brain (or a prompt box) in the middle and gear to fit to it, by dragging or tapping; missions clear as the right
/// gear goes on.
class LabEquipTool extends StatefulWidget {
  const LabEquipTool({super.key, required this.tool, required this.passed, required this.onPass});
  final LabTool tool;
  final bool passed;
  final VoidCallback onPass;
  @override
  State<LabEquipTool> createState() => _LabEquipToolState();
}

class _LabEquipToolState extends State<LabEquipTool> {
  final List<String> fitted = [];
  String? note;
  bool targeted = false;

  List<LabGear> get gear => widget.tool.gear ?? const [];
  List<LabMission> get missions => widget.tool.missions ?? const [];
  bool _done(LabMission mission) => mission.needs.every(fitted.contains);

  void _toggle(LabGear item) {
    LabHaptic.press();
    setState(() {
      if (fitted.remove(item.id)) {
        note = null;
        return;
      }
      fitted.add(item.id);
      note = item.miss?.text;
    });
    if (missions.every(_done) && !widget.passed) {
      LabHaptic.pass();
      widget.onPass();
    }
  }

  @override
  Widget build(BuildContext context) {
    final gaugeColor = LabPalette.gauge.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    return Column(
      children: [
        DragTarget<String>(
          onWillAcceptWithDetails: (details) {
            setState(() => targeted = true);
            return true;
          },
          onLeave: (_) => setState(() => targeted = false),
          onAcceptWithDetails: (details) {
            setState(() => targeted = false);
            final item = gear.where((value) => value.id == details.data).firstOrNull;
            if (item != null && !fitted.contains(item.id)) _toggle(item);
          },
          builder: (context, _, _) => Column(
            key: const Key('lab.core'),
            children: [
              AnimatedScale(
                scale: targeted ? 1.06 : 1,
                duration: const Duration(milliseconds: 200),
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    color: TegnalColors.secondaryBackground.resolveFrom(context),
                    shape: BoxShape.circle,
                    border: Border.all(color: targeted ? tint : labSecondary(context).withValues(alpha: 0.25), width: targeted ? 3 : 1),
                  ),
                  child: Icon(widget.tool.core == null ? CupertinoIcons.lightbulb : CupertinoIcons.person_crop_square, size: 44, color: labSecondary(context)),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                widget.tool.core?.text ?? '',
                textAlign: TextAlign.center,
                style: LabFont.text(13, weight: FontWeight.w600, color: labSecondary(context)),
              ),
              if (fitted.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  [for (final id in fitted) ?gear.where((value) => value.id == id).firstOrNull?.label.text].join(' + '),
                  textAlign: TextAlign.center,
                  style: LabFont.number(12, color: gaugeColor),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
        _Flow(
          children: [
            for (final item in gear)
              LongPressDraggable<String>(
                data: item.id,
                delay: const Duration(milliseconds: 150),
                feedback: Opacity(
                  opacity: 0.9,
                  child: _Chip(label: item.label.text, on: true, onTap: () {}, icon: StudyGlyph.icon(item.symbol ?? 'puzzlepiece')),
                ),
                child: _Chip(
                  key: Key('lab.gear.${item.id}'),
                  label: item.label.text,
                  on: fitted.contains(item.id),
                  icon: StudyGlyph.icon(item.symbol ?? 'puzzlepiece'),
                  onTap: () => _toggle(item),
                ),
              ),
          ],
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: note == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 18),
                  child: Text(
                    note!,
                    style: LabFont.text(13, weight: FontWeight.w600, color: LabPalette.fail.resolveFrom(context)),
                  ),
                ),
        ),
        const SizedBox(height: 18),
        _grouped(context, inset: 44, [
          for (final (index, mission) in missions.indexed)
            Padding(
              key: Key('lab.mission.$index'),
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _done(mission) ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle,
                    size: 18,
                    color: _done(mission) ? LabPalette.pass.resolveFrom(context) : labSecondary(context),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          labWords(mission.text.text),
                          style: LabFont.text(15, weight: FontWeight.w600, color: labLabel(context)),
                        ),
                        const SizedBox(height: 4),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: Text(
                            (_done(mission) ? mission.after : mission.before).text,
                            key: ValueKey(_done(mission)),
                            style: LabFont.text(13, color: _done(mission) ? labLabel(context) : labSecondary(context)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ]),
      ],
    );
  }
}

// MARK: - Rot

/// "Write it again" pressed over and over: each answer is worse, until the learner leaves for a new chat.
class LabRotTool extends StatefulWidget {
  const LabRotTool({super.key, required this.tool, required this.passed, required this.onPass});
  final LabTool tool;
  final bool passed;
  final VoidCallback onPass;
  @override
  State<LabRotTool> createState() => _LabRotToolState();
}

class _LabRotToolState extends State<LabRotTool> {
  int retries = 0;
  bool fresh = false;

  LabTool get tool => widget.tool;
  List<LabText> get replies => tool.replies ?? const [];
  int get rot => fresh ? 0 : (retries * 100 ~/ (replies.isEmpty ? 1 : replies.length)).clamp(0, 100);

  @override
  Widget build(BuildContext context) {
    final fail = LabPalette.fail.resolveFrom(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (tool.gauge != null) ...[
          LabMeter(label: tool.gauge!.text, value: rot, tone: fresh ? LabTone.pass : (rot >= 75 ? LabTone.fail : LabTone.measure)),
          const SizedBox(height: 14),
        ],
        AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: Column(
            children: fresh
                ? [
                    Text(L10n.text('lab.rot.newChat'), style: LabFont.number(11, color: labSecondary(context), tracking: 1)),
                    const SizedBox(height: 10),
                    LabBubble(text: tool.carry?.text ?? '', mine: true),
                    const SizedBox(height: 10),
                    LabBubble(text: tool.fresh?.text ?? ''),
                  ]
                : [
                    for (var index = 0; index < retries; index++) ...[
                      LabBubble(text: tool.retry?.text ?? '', mine: true),
                      const SizedBox(height: 10),
                      LabBubble(
                        text: replies[index < replies.length ? index : replies.length - 1].text,
                        tint: fail.withValues(alpha: (index + 1) / (replies.isEmpty ? 1 : replies.length) * 0.22),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ],
          ),
        ),
        if (!fresh) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: LabButton(
                  key: const Key('lab.rot.retry'),
                  onPressed: () {
                    LabHaptic.tick();
                    setState(() => retries += 1);
                  },
                  radius: 16,
                  expand: true,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(CupertinoIcons.arrow_clockwise),
                      const SizedBox(width: 6),
                      Flexible(child: Text(tool.retry?.text ?? '', maxLines: 1, overflow: TextOverflow.ellipsis)),
                    ],
                  ),
                ),
              ),
              if (retries >= (tool.minRetries ?? 2)) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: LabButton(
                    key: const Key('lab.rot.reset'),
                    style: LabButtonStyle.primary,
                    onPressed: () {
                      LabHaptic.pass();
                      setState(() => fresh = true);
                      widget.onPass();
                    },
                    radius: 16,
                    expand: true,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(CupertinoIcons.square_pencil),
                        const SizedBox(width: 6),
                        Flexible(child: Text(tool.reset?.text ?? '', maxLines: 1, overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}
