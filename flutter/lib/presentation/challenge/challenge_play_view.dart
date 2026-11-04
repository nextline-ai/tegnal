import 'dart:async';
import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../core/booru/booru_client.dart';
import '../../core/booru/booru_models.dart';
import '../../core/challenge/challenge_engine.dart';
import '../../core/challenge/challenge_models.dart';
import '../../core/challenge/challenge_reference.dart';
import '../../core/challenge/challenge_store.dart';
import '../../core/support/l10n.dart';
import '../booru/booru_common.dart';
import '../booru/booru_feed_view.dart';
import '../design/app_sheet.dart';
import '../design/context_menu.dart';
import '../design/grouped_form.dart';
import '../design/ios_controls.dart';
import '../design/symbols.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import '../library/folders_view.dart' show anchorOf;
import '../navigation/app_header.dart';
import '../settings/website_setup.dart';
import 'challenge_editor_view.dart';
import 'challenge_library_view.dart' show showChallengeError;
import '../design/alert_dialog.dart';

/// Opens a challenge full screen, as `appFullScreenCover` with `ChallengePlayHost` does.
Future<void> openChallenge(BuildContext context, {required BooruContext booru, required ChallengeDefinition game}) =>
    Navigator.of(context, rootNavigator: true).push<void>(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 380),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (context, animation, secondary) => ChallengePlayHost(booru: booru, game: game),
        transitionsBuilder: (context, animation, secondary, child) => SlideTransition(
          position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: child,
        ),
      ),
    );

/// Shows an unsaved challenge in a sheet, without keeping its progress.
void previewChallenge(BuildContext context, ChallengeDefinition game) {
  final ChallengeSessionController controller;
  try {
    controller = ChallengeSessionController(game: ChallengeDefinition.fromJson(game.toJson()));
  } on Object catch (error) {
    showChallengeError(context, error);
    return;
  }
  showAppSheet<void>(
    context,
    builder: (context, scroll) => ChallengePreviewView(controller: controller, scrollController: scroll),
  );
}

/// `ChallengePlayHost`: loads the saved session, or says why it cannot.
class ChallengePlayHost extends StatefulWidget {
  const ChallengePlayHost({super.key, required this.booru, required this.game});
  final BooruContext booru;
  final ChallengeDefinition game;

  @override
  State<ChallengePlayHost> createState() => _ChallengePlayHostState();
}

class _ChallengePlayHostState extends State<ChallengePlayHost> {
  ChallengeSessionController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    try {
      _controller = ChallengeSessionController(game: widget.game, store: ChallengeStore(widget.booru.store));
    } on Object catch (error) {
      _error = error is ChallengeError ? error.errorDescription : '$error';
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller != null) return ChallengePlayView(controller: controller, booru: widget.booru);
    final top = MediaQuery.paddingOf(context).top + rootBarHeight;
    return ColoredBox(
      color: FormColors.listBackground.resolveFrom(context),
      child: Stack(
        children: [
          Positioned.fill(
            top: top,
            child: Center(
              child: _error == null ? const CupertinoActivityIndicator() : _Unavailable(title: L10n.text('Unable to Continue'), message: _error!),
            ),
          ),
          Positioned(left: 0, right: 0, top: 0, child: _ChallengeBar(title: widget.game.title)),
        ],
      ),
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.title, required this.message});
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(CupertinoIcons.exclamationmark_triangle, size: 44, color: secondary),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TegnalType.style(22, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TegnalType.style(15, color: secondary),
          ),
        ],
      ),
    );
  }
}

/// The play screen's bar: Close, the challenge's title and its menu.
class _ChallengeBar extends StatelessWidget {
  const _ChallengeBar({required this.title, this.menu});
  final String title;
  final List<ContextMenuAction> Function()? menu;

  @override
  Widget build(BuildContext context) {
    final label = TegnalColors.label.resolveFrom(context);
    final background = FormColors.listBackground.resolveFrom(context);
    // iOS 26's soft scroll edge: the screen's background fades in behind the bar, so
    // content scrolling beneath it stays clear of the buttons.
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
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 110),
                  child: Align(
                    alignment: const Alignment(0, -0.2),
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TegnalType.style(17, weight: FontWeight.w600, color: label),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 16,
                top: 0,
                child: GlassTextButton(label: L10n.text('Close'), elevated: false, onPressed: () => Navigator.of(context).pop()),
              ),
              if (menu != null)
                Positioned(
                  right: 16,
                  top: 0,
                  child: Builder(
                    builder: (buttonContext) => ToolbarGroup(
                      children: [
                        ToolbarIconButton(
                          label: L10n.text('Challenge Settings'),
                          symbol: (_) => Icon(CupertinoIcons.ellipsis_circle, size: 22, color: SystemColors.purple.resolveFrom(context)),
                          onPressed: () => showActionMenu(buttonContext, anchor: anchorOf(buttonContext), actions: menu!()),
                        ),
                      ],
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

/// Runs the reels' staggered stops once a mission is drawn (`ChallengeRevealModifier`).
class _RevealDriver {
  _RevealDriver(this.controller);
  final ChallengeSessionController controller;
  String? _mission;
  final _timers = <Timer>[];

  void update() {
    final session = controller.session;
    final id = session.mission?.id;
    if (id == _mission) return;
    _mission = id;
    cancel();
    if (session.phase != ChallengePhase.spinning) return;
    if (session.spinSpeed == 'instant' || WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations) {
      controller.reveal();
      return;
    }
    final factor = session.spinSpeed == 'fast' ? 0.5 : 1.0;
    var elapsed = 0.0;
    for (final (index, delay) in [2.0, 0.8, 0.8].indexed) {
      elapsed += delay * factor;
      _timers.add(
        Timer(Duration(milliseconds: (elapsed * 1000).round()), () {
          controller.stopReel(index + 1);
          HapticFeedback.lightImpact();
        }),
      );
    }
    _timers.add(Timer(Duration(milliseconds: ((elapsed + 0.1 * factor) * 1000).round()), controller.reveal));
  }

  void cancel() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
  }
}

/// `ChallengePlayView`: the reels, the mission and its timer or counter over the reference
/// feed, then the ending once the target score is reached.
class ChallengePlayView extends StatefulWidget {
  const ChallengePlayView({super.key, required this.controller, required this.booru});
  final ChallengeSessionController controller;
  final BooruContext booru;

  @override
  State<ChallengePlayView> createState() => _ChallengePlayViewState();
}

class _ChallengePlayViewState extends State<ChallengePlayView> {
  late final _reveal = _RevealDriver(widget.controller);
  String? _shownError;

  ChallengeSessionController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
    _reveal.update();
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _reveal.cancel();
    super.dispose();
  }

  void _changed() {
    _reveal.update();
    final error = _controller.error;
    if (error != null && error != _shownError && mounted) {
      _shownError = error;
      _controller.error = null;
      showChallengeError(context, error);
    }
    if (mounted) setState(() {});
  }

  Future<void> _restart() async {
    final restart = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('Restart Challenge?')),
        actions: [
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Restart'))),
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
        ],
      ),
    );
    if (restart == true) _controller.restart();
  }

  List<ContextMenuAction> _menu() => [
    ContextMenuAction(title: L10n.text('How to Play'), icon: CupertinoIcons.book, onSelected: () => showChallengeHelp(context, _controller.session.definition)),
    ContextMenuAction(title: L10n.text('Restart'), destructive: true, onSelected: _restart),
  ];

  @override
  Widget build(BuildContext context) {
    final session = _controller.session;
    final bar = _ChallengeBar(title: session.definition.title, menu: _menu);
    final Widget body;
    if (session.phase == ChallengePhase.ended) {
      final top = MediaQuery.paddingOf(context).top + rootBarHeight;
      body = Stack(
        children: [
          Positioned.fill(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(24, top + 24, 24, 24 + MediaQuery.paddingOf(context).bottom),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
                    children: [
                      if (session.ending case final ending?) ...[
                        ChallengeEndingReveal(ending: ending, choices: session.definition.endings, instant: session.spinSpeed == 'instant'),
                        const SizedBox(height: 28),
                        ChallengeButton(
                          title: L10n.text('Play Again'),
                          icon: CupertinoIcons.arrow_clockwise,
                          prominent: true,
                          large: true,
                          onPressed: _controller.restart,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(left: 0, right: 0, top: 0, child: bar),
        ],
      );
    } else {
      body = ChallengeReferenceView(
        controller: _controller,
        booru: widget.booru,
        bar: bar,
        header: Column(
          children: [
            ChallengeReelsView(controller: _controller),
            if (session.mission case final mission? when session.phase != ChallengePhase.spinning) ...[
              const SizedBox(height: 16),
              _MissionCard(mission: mission),
            ],
            const SizedBox(height: 16),
            ChallengeSessionControls(controller: _controller),
          ],
        ),
      );
    }
    return ColoredBox(
      color: FormColors.listBackground.resolveFrom(context),
      child: IgnorePointer(ignoring: _controller.unavailable, child: body),
    );
  }
}

/// The drawn mission with the tags its reference search uses.
class _MissionCard extends StatefulWidget {
  const _MissionCard({required this.mission});
  final ChallengeMission mission;

  @override
  State<_MissionCard> createState() => _MissionCardState();
}

class _MissionCardState extends State<_MissionCard> {
  bool _tags = false;

  @override
  Widget build(BuildContext context) {
    final purple = SystemColors.purple.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final mission = widget.mission;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: ShapeDecoration(
        color: FormColors.listRow.resolveFrom(context),
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(CupertinoIcons.sparkles, size: 16, color: purple),
              const SizedBox(width: 6),
              Text(
                L10n.text('Current Mission'),
                style: TegnalType.style(15, weight: FontWeight.w600, color: purple),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            mission.text,
            style: TegnalType.style(20, weight: FontWeight.w500, color: TegnalColors.label.resolveFrom(context)),
          ),
          if (mission.tags.isNotEmpty) ...[
            const SizedBox(height: 10),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _tags = !_tags),
              child: Row(
                children: [
                  Text(L10n.text('Search Tags'), style: TegnalType.style(12, color: purple)),
                  const Spacer(),
                  AnimatedRotation(
                    turns: _tags ? 0.25 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(CupertinoIcons.chevron_right, size: 15, color: TegnalColors.label.resolveFrom(context)),
                  ),
                ],
              ),
            ),
            if (_tags) ...[
              const SizedBox(height: 8),
              Text(mission.tags.join(' '), style: TegnalType.style(12, color: secondary)),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => Clipboard.setData(ClipboardData(text: mission.tags.join(' '))),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(CupertinoIcons.doc_on_doc, size: 14, color: purple),
                    const SizedBox(width: 4),
                    Text(L10n.text('Copy Tags'), style: TegnalType.style(12, color: purple)),
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// `.borderedProminent` and `.bordered` in the challenge's purple.
class ChallengeButton extends StatelessWidget {
  const ChallengeButton({
    super.key,
    required this.title,
    required this.onPressed,
    this.icon,
    this.symbol,
    this.prominent = false,
    this.large = false,
    this.plain = false,
  });
  final String title;
  final IconData? icon;

  /// A drawn symbol in place of [icon], given its color and size.
  final Widget Function(Color color, double size)? symbol;

  /// A borderless button: tinted text and icon only.
  final bool plain;
  final bool prominent;
  final bool large;
  final VoidCallback? onPressed;

  static const _disabledFill = CupertinoDynamicColor.withBrightness(color: Color(0x33787880), darkColor: Color(0x5C787880));

  @override
  Widget build(BuildContext context) {
    final purple = SystemColors.purple.resolveFrom(context);
    final enabled = onPressed != null;
    // Disabled bordered buttons turn system gray, as SwiftUI draws them.
    final foreground = !enabled
        ? TegnalColors.tertiaryLabel.resolveFrom(context)
        : prominent
        ? const Color(0xFFFFFFFF)
        : purple;
    final fill = !enabled
        ? _disabledFill.resolveFrom(context)
        : prominent
        ? purple
        : purple.withValues(alpha: 0.15);
    return Semantics(
      button: true,
      enabled: onPressed != null,
      child: GestureDetector(
        onTap: onPressed,
        child: Opacity(
          opacity: plain && !enabled ? 0.4 : 1,
          child: Container(
            height: large ? 50 : 36,
            padding: EdgeInsets.symmetric(horizontal: plain ? 0 : 16),
            decoration: plain ? null : ShapeDecoration(color: fill, shape: const StadiumBorder()),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (symbol != null) ...[
                  symbol!(foreground, large ? 21 : 18),
                  const SizedBox(width: 6),
                ] else if (icon != null) ...[
                  Icon(icon, size: large ? 19 : 18, color: foreground),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TegnalType.style(17, weight: large ? FontWeight.w600 : FontWeight.w400, color: plain && !enabled ? purple : foreground),
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

/// `ChallengeReelsView`: progress toward the target, the two lists and the goal as reels,
/// and Draw Mission.
class ChallengeReelsView extends StatelessWidget {
  const ChallengeReelsView({super.key, required this.controller});
  final ChallengeSessionController controller;

  String _final(int index) {
    final mission = controller.session.mission;
    if (mission == null) return '—';
    return index < 2 ? mission.selections[index].text : mission.goalText;
  }

  List<String> _options(int index) {
    final session = controller.session;
    if (index < 2) return [for (final option in session.definition.reels[index].eligible) option.text];
    final time = session.mission?.kind == ChallengeGoalMode.time;
    final range = time ? session.definition.goal.time : session.definition.goal.count;
    final count = math.min(20, (range.maximum - range.minimum) ~/ range.step + 1);
    return [
      for (var step = 0; step < count; step++)
        ChallengeMission.goalTextFor(time ? ChallengeGoalMode.time : ChallengeGoalMode.count, range.minimum + step * range.step),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final purple = SystemColors.purple.resolveFrom(context);
    final session = controller.session;
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final spinning = session.phase == ChallengePhase.spinning;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: ShapeDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [purple.withValues(alpha: 0.08), purple.withValues(alpha: 0.03)],
        ),
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(24)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              CheckeredFlagSymbol(size: 20, color: secondary),
              const SizedBox(width: 6),
              Text(
                L10n.text('Progress'),
                style: TegnalType.style(17, weight: FontWeight.w600, color: secondary),
              ),
              const Spacer(),
              Text(
                '${session.score} / ${session.definition.target}',
                style: TegnalType.style(28, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
              ),
            ],
          ),
          const SizedBox(height: 22),
          LayoutBuilder(
            builder: (context, constraints) => Container(
              height: 12,
              decoration: ShapeDecoration(color: purple.withValues(alpha: 0.12), shape: const StadiumBorder()),
              alignment: Alignment.centerLeft,
              child: Container(
                width: constraints.maxWidth * session.progress.clamp(0, 1),
                decoration: ShapeDecoration(
                  gradient: LinearGradient(colors: [purple.withValues(alpha: 0.65), purple]),
                  shape: const StadiumBorder(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 22),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var index = 0; index < 3; index++) ...[
                if (index > 0) const SizedBox(width: 8),
                Expanded(
                  child: _Reel(
                    title: index < 2 ? session.definition.reels[index].title : L10n.text('Goal'),
                    value: _final(index),
                    options: _options(index),
                    token: session.mission?.id ?? '',
                    settled: session.mission != null && (!spinning || controller.stoppedReels > index || reduceMotion),
                    spinning: spinning && !reduceMotion && session.spinSpeed != 'instant',
                    duration: [2.0, 2.8, 3.6][index] * (session.spinSpeed == 'fast' ? 0.5 : 1),
                  ),
                ),
              ],
            ],
          ),
          if (session.phase == ChallengePhase.idle || spinning) ...[
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: ChallengeButton(
                title: L10n.text('Draw Mission'),
                symbol: (color, size) => DiceSymbol(size: size, color: color),
                prominent: true,
                large: true,
                onPressed: session.phase == ChallengePhase.idle ? controller.draw : null,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One reel: its title above a tile that spins through choices and lands on the drawn one.
class _Reel extends StatelessWidget {
  const _Reel({
    required this.title,
    required this.value,
    required this.options,
    required this.token,
    required this.settled,
    required this.spinning,
    required this.duration,
  });
  final String title;
  final String value;
  final List<String> options;
  final String token;
  final bool settled;
  final bool spinning;
  final double duration;

  @override
  Widget build(BuildContext context) {
    final purple = SystemColors.purple.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return Semantics(
      label: title,
      value: settled ? value : L10n.text('Drawing Mission…'),
      excludeSemantics: true,
      child: Column(
        children: [
          SizedBox(
            height: 44,
            child: Center(
              child: Text(
                title,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TegnalType.style(15, weight: FontWeight.w500, color: secondary),
              ),
            ),
          ),
          const SizedBox(height: 10),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            padding: const EdgeInsets.all(10),
            decoration: ShapeDecoration(
              color: settled ? purple : FormColors.listRow.resolveFrom(context),
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: purple.withValues(alpha: settled ? 0.9 : 0.3), width: 1.5),
              ),
              shadows: [if (settled) BoxShadow(color: purple.withValues(alpha: 0.25), blurRadius: 12, offset: const Offset(0, 4))],
            ),
            child: _ReelStrip(
              value: value,
              options: options,
              token: token,
              spinning: spinning,
              duration: duration,
              color: settled ? const Color(0xFFFFFFFF) : TegnalColors.label.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }
}

/// `ChallengeReelStrip`: nineteen choices roll past and settle on the drawn value.
class _ReelStrip extends StatefulWidget {
  const _ReelStrip({required this.value, required this.options, required this.token, required this.spinning, required this.duration, required this.color});
  final String value;
  final List<String> options;
  final String token;
  final bool spinning;
  final double duration;
  final Color color;

  @override
  State<_ReelStrip> createState() => _ReelStripState();
}

class _ReelStripState extends State<_ReelStrip> with SingleTickerProviderStateMixin {
  static const double _rowHeight = 116;
  late final _roll = AnimationController(vsync: this);
  String _prepared = '';

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(_ReelStrip old) {
    super.didUpdateWidget(old);
    if (old.token != widget.token || old.spinning != widget.spinning) _start();
  }

  @override
  void dispose() {
    _roll.dispose();
    super.dispose();
  }

  void _start() {
    if (!widget.spinning) {
      _roll.value = 1;
      return;
    }
    _roll
      ..duration = Duration(milliseconds: (widget.duration * 1000).round())
      ..value = 0;
    Future<void>.delayed(const Duration(milliseconds: 30), () {
      if (!mounted || !widget.spinning) return;
      setState(() => _prepared = widget.token);
      _roll.animateTo(1, curve: const Cubic(0.1, 0.8, 0.1, 1));
    });
  }

  Text _text(String value) => Text(
    value,
    textAlign: TextAlign.center,
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    style: TegnalType.style(20, weight: FontWeight.w700, color: widget.color),
  );

  @override
  Widget build(BuildContext context) {
    if (!widget.spinning) {
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _rowHeight),
        child: Center(child: _text(widget.value)),
      );
    }
    final items = [widget.value, for (var index = 0; index < 19; index++) widget.options.isEmpty ? '—' : widget.options[index % widget.options.length]];
    return Opacity(
      opacity: _prepared == widget.token ? 1 : 0,
      child: SizedBox(
        height: _rowHeight,
        child: ClipRect(
          child: AnimatedBuilder(
            animation: _roll,
            builder: (context, _) => OverflowBox(
              alignment: Alignment.topCenter,
              minHeight: _rowHeight * items.length,
              maxHeight: _rowHeight * items.length,
              child: Transform.translate(
                offset: Offset(0, -19 * _rowHeight * (1 - _roll.value)),
                child: Column(
                  children: [
                    for (final item in items)
                      SizedBox(
                        height: _rowHeight,
                        child: Center(child: _text(item)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Calls `tick` every second while shown, so timers expire and goals are reached.
mixin _Ticking<T extends StatefulWidget> on State<T> {
  ChallengeSessionController get ticking;
  Timer? _ticker;

  void startTicking() {
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      ticking.tick();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}

String _clock(int seconds) => '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';

/// `ChallengeSessionControls`: the mission's timer or counter, Complete Mission and Skip.
class ChallengeSessionControls extends StatefulWidget {
  const ChallengeSessionControls({super.key, required this.controller, this.compact = false});
  final ChallengeSessionController controller;
  final bool compact;

  @override
  State<ChallengeSessionControls> createState() => _ChallengeSessionControlsState();
}

class _ChallengeSessionControlsState extends State<ChallengeSessionControls> with _Ticking {
  ChallengePhase? _phase;

  @override
  ChallengeSessionController get ticking => widget.controller;

  @override
  void initState() {
    super.initState();
    _phase = widget.controller.session.phase;
    widget.controller.addListener(_changed);
    startTicking();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final phase = widget.controller.session.phase;
    if (!widget.compact && _phase == ChallengePhase.active && phase == ChallengePhase.ready) {
      HapticFeedback.heavyImpact();
      SemanticsService.sendAnnouncement(View.of(context), L10n.text('Goal Reached'), Directionality.of(context));
    }
    _phase = phase;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final session = controller.session;
    final mission = session.mission;
    final purple = SystemColors.purple.resolveFrom(context);
    final label = TegnalColors.label.resolveFrom(context);
    final playing = mission != null && (session.phase == ChallengePhase.active || session.phase == ChallengePhase.ready);
    if (!playing) return const SizedBox(width: double.infinity);
    final compact = widget.compact;
    final content = Column(
      children: [
        if (compact) ...[Text(mission.text, maxLines: 3, style: TegnalType.style(12, color: label)), const SizedBox(height: 12)],
        if (mission.kind == ChallengeGoalMode.time) ...[
          Text(
            _clock(controller.seconds(DateTime.now())),
            style: TegnalType.style(compact ? 20 : 34, weight: FontWeight.w400, color: label),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              ChallengeButton(
                title: L10n.text(session.deadline == null ? 'Start Timer' : 'Pause Timer'),
                icon: session.deadline == null ? CupertinoIcons.play_fill : CupertinoIcons.pause_fill,
                onPressed: session.phase == ChallengePhase.ready ? null : controller.toggleTimer,
              ),
              ChallengeButton(title: L10n.text('Reset'), icon: CupertinoIcons.arrow_counterclockwise, onPressed: controller.resetTimer),
            ],
          ),
        ] else
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Semantics(
                button: true,
                label: L10n.text('Decrease Count'),
                child: GestureDetector(
                  onTap: () => controller.adjust(-1),
                  child: Icon(CupertinoIcons.minus_circle_fill, size: 34, color: purple),
                ),
              ),
              const SizedBox(width: 24),
              Text('${session.count} / ${mission.goal}', style: TegnalType.style(28, color: label)),
              const SizedBox(width: 24),
              Semantics(
                button: true,
                label: L10n.text('Increase Count'),
                child: GestureDetector(
                  onTap: () => controller.adjust(1),
                  child: Icon(CupertinoIcons.plus_circle_fill, size: 34, color: purple),
                ),
              ),
            ],
          ),
        if (session.phase == ChallengePhase.ready) ...[
          const SizedBox(height: 12),
          Text(
            L10n.text('Goal Reached'),
            style: TegnalType.style(17, weight: FontWeight.w600, color: purple),
          ),
        ],
        const SizedBox(height: 12),
        ChallengeButton(
          title: L10n.text('Complete Mission'),
          icon: CupertinoIcons.checkmark_circle_fill,
          prominent: true,
          onPressed: session.phase == ChallengePhase.ready ? controller.complete : null,
        ),
        if (!compact) ...[
          const SizedBox(height: 12),
          GestureDetector(
            onTap: controller.skip,
            child: Text(L10n.text('Skip Without Points'), style: TegnalType.style(13, color: purple)),
          ),
        ],
      ],
    );
    if (compact) return content;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: ShapeDecoration(
        color: FormColors.listRow.resolveFrom(context),
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(22)),
      ),
      child: content,
    );
  }
}

/// `ChallengeViewerControls`: the mission over the reference image, as a capsule that opens
/// into a panel.
class ChallengeViewerControls extends StatefulWidget {
  const ChallengeViewerControls({super.key, required this.controller});
  final ChallengeSessionController controller;

  @override
  State<ChallengeViewerControls> createState() => _ChallengeViewerControlsState();
}

class _ChallengeViewerControlsState extends State<ChallengeViewerControls> with _Ticking {
  bool _expanded = false;

  @override
  ChallengeSessionController get ticking => widget.controller;

  @override
  void initState() {
    super.initState();
    startTicking();
  }

  Widget _button(IconData icon, String label, VoidCallback? onTap) => Semantics(
    button: true,
    label: label,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 36,
        height: 44,
        child: Icon(icon, size: 17, color: const Color(0xFFFFFFFF).withValues(alpha: onTap == null ? 0.4 : 1)),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final session = controller.session;
    final mission = session.mission;
    const white = Color(0xFFFFFFFF);
    final purple = SystemColors.purple.resolveFrom(context);
    final glass = TegnalColors.elevatedGlassFill.resolveFrom(context);
    final Widget content;
    if (_expanded) {
      content = Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.all(16),
        decoration: ShapeDecoration(
          color: glass,
          shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _expanded = false),
              child: Row(
                children: [
                  const Icon(CupertinoIcons.sparkles, size: 15, color: white),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      L10n.text('Current Mission'),
                      style: TegnalType.style(15, weight: FontWeight.w700, color: white),
                    ),
                  ),
                  const Icon(CupertinoIcons.chevron_up, size: 15, color: white),
                ],
              ),
            ),
            const SizedBox(height: 12),
            ChallengeSessionControls(controller: controller, compact: true),
          ],
        ),
      );
    } else {
      content = Container(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: ShapeDecoration(
          color: glass,
          shape: StadiumBorder(
            side: BorderSide(color: purple.withValues(alpha: session.phase == ChallengePhase.ready ? 0.6 : 0.15)),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _button(CupertinoIcons.chevron_down, L10n.text('Current Mission'), () => setState(() => _expanded = true)),
            if (mission != null) ...[
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  mission.kind == ChallengeGoalMode.time ? _clock(controller.seconds(DateTime.now())) : '${session.count}/${mission.goal}',
                  style: TegnalType.style(15, weight: FontWeight.w600, color: white),
                ),
              ),
              if (mission.kind == ChallengeGoalMode.time)
                _button(
                  session.deadline == null ? CupertinoIcons.play_fill : CupertinoIcons.pause_fill,
                  L10n.text(session.deadline == null ? 'Start Timer' : 'Pause Timer'),
                  session.phase == ChallengePhase.ready ? null : controller.toggleTimer,
                )
              else
                _button(CupertinoIcons.plus, L10n.text('Increase Count'), () => controller.adjust(1)),
              _button(CupertinoIcons.checkmark_circle_fill, L10n.text('Complete Mission'), session.phase == ChallengePhase.ready ? controller.complete : null),
            ],
          ],
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 24 + MediaQuery.paddingOf(context).top, 12, 0),
      child: Align(
        alignment: Alignment.topRight,
        child: IgnorePointer(ignoring: controller.unavailable, child: content),
      ),
    );
  }
}

/// `ChallengeEndingReveal`: the endings roll past and stop on the result, then confetti.
class ChallengeEndingReveal extends StatefulWidget {
  const ChallengeEndingReveal({super.key, required this.ending, required this.choices, required this.instant});
  final ChallengeEnding ending;
  final List<ChallengeEnding> choices;
  final bool instant;

  @override
  State<ChallengeEndingReveal> createState() => _ChallengeEndingRevealState();
}

class _ChallengeEndingRevealState extends State<ChallengeEndingReveal> with TickerProviderStateMixin {
  static const _winning = 24;
  late final _roll = AnimationController(vsync: this, duration: const Duration(milliseconds: 3600));
  late final _celebration = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200));
  bool _revealed = false;
  final _timers = <Timer>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  void _start() {
    if (!mounted) return;
    if (widget.instant || MediaQuery.disableAnimationsOf(context)) {
      _roll.value = 1;
      setState(() => _revealed = true);
      return;
    }
    _timers.add(Timer(const Duration(milliseconds: 80), () => _roll.animateTo(1, curve: const Cubic(0.12, 0.75, 0.12, 1))));
    _timers.add(
      Timer(const Duration(milliseconds: 3780), () {
        if (!mounted) return;
        setState(() => _revealed = true);
        _celebration.forward(from: 0);
        HapticFeedback.heavyImpact();
        SemanticsService.sendAnnouncement(View.of(context), widget.ending.title, Directionality.of(context));
      }),
    );
  }

  @override
  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _roll.dispose();
    _celebration.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final purple = SystemColors.purple.resolveFrom(context);
    final label = TegnalColors.label.resolveFrom(context);
    final choices = widget.choices.isEmpty ? [widget.ending] : widget.choices;
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            children: [
              AnimatedScale(
                scale: _revealed ? 1 : 0.85,
                duration: const Duration(milliseconds: 550),
                curve: Curves.elasticOut,
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: ShapeDecoration(color: purple.withValues(alpha: 0.1), shape: const CircleBorder()),
                  child: Icon(CupertinoIcons.rosette, size: 46, color: purple),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                L10n.text('Challenge Complete'),
                textAlign: TextAlign.center,
                style: TegnalType.style(34, weight: FontWeight.w700, color: label),
              ),
              const SizedBox(height: 12),
              Text(
                L10n.text(_revealed ? 'Your Final Result' : 'Revealing Result'),
                style: TegnalType.style(15, color: TegnalColors.secondaryLabel.resolveFrom(context)),
              ),
              const SizedBox(height: 28),
              SizedBox(
                height: 180,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = math.min(156.0, constraints.maxWidth * 0.44);
                    return ClipRect(
                      child: AnimatedBuilder(
                        animation: _roll,
                        builder: (context, _) {
                          final position = _roll.value * _winning;
                          return Stack(
                            children: [
                              Positioned(
                                left: (constraints.maxWidth - width) / 2 - position * (width + 14),
                                top: 12,
                                child: Row(
                                  children: [
                                    for (var index = 0; index < _winning + 4; index++) ...[
                                      if (index > 0) const SizedBox(width: 14),
                                      _EndingChip(
                                        ending: index == _winning ? widget.ending : choices[index % choices.length],
                                        width: width,
                                        highlighted: index == _winning && _revealed,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              Positioned(
                                left: (constraints.maxWidth - width - 8) / 2,
                                top: 7,
                                child: Container(
                                  width: width + 8,
                                  height: 166,
                                  decoration: ShapeDecoration(
                                    shape: RoundedSuperellipseBorder(
                                      borderRadius: BorderRadius.circular(22),
                                      side: BorderSide(color: purple, width: 2.5),
                                    ),
                                    shadows: [
                                      BoxShadow(
                                        color: purple.withValues(alpha: _revealed ? 0.6 : 0.2),
                                        blurRadius: _revealed ? 16 : 6,
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
                  },
                ),
              ),
              const SizedBox(height: 28),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 400),
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(scale: Tween(begin: 0.9, end: 1.0).animate(animation), child: child),
                ),
                child: _revealed
                    ? ChallengeEndingCard(key: const ValueKey('card'), ending: widget.ending)
                    : CupertinoActivityIndicator(key: const ValueKey('progress'), color: purple),
              ),
            ],
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _celebration,
              builder: (context, _) => _celebration.isAnimating ? CustomPaint(painter: _ConfettiPainter(_celebration.value, purple)) : const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );
  }
}

class _EndingChip extends StatelessWidget {
  const _EndingChip({required this.ending, required this.width, required this.highlighted});
  final ChallengeEnding ending;
  final double width;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final purple = SystemColors.purple.resolveFrom(context);
    final label = TegnalColors.label.resolveFrom(context);
    return Container(
      width: width,
      height: 156,
      padding: const EdgeInsets.all(12),
      decoration: ShapeDecoration(
        color: purple.withValues(alpha: highlighted ? 0.3 : 0.08),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: purple.withValues(alpha: 0.3)),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            ending.badge,
            maxLines: 1,
            style: TegnalType.style(28, weight: FontWeight.w700, color: label),
          ),
          const SizedBox(height: 12),
          Text(
            ending.title,
            maxLines: 3,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: TegnalType.style(15, weight: FontWeight.w600, color: label),
          ),
        ],
      ),
    );
  }
}

/// `ChallengeCelebration`: thirty-two pieces spiral out and fall.
class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.progress, this.color);
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color.withValues(alpha: (1 - progress) * 0.8);
    for (var index = 0; index < 32; index++) {
      final angle = index * 2.39996;
      final distance = (0.12 + progress * 0.7) * math.min(size.width, size.height);
      final x = size.width / 2 + math.cos(angle) * distance;
      final y = size.height * 0.45 + math.sin(angle) * distance + progress * progress * 90;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y, index % 3 == 0 ? 7 : 4, 8), const Radius.circular(2)), paint);
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.progress != progress;
}

/// `ChallengeReferenceView`: the challenge above a feed of reference images for the mission,
/// from the chosen servers or a saved folder.
class ChallengeReferenceView extends StatefulWidget {
  const ChallengeReferenceView({super.key, required this.controller, required this.booru, required this.header, required this.bar});
  final ChallengeSessionController controller;
  final BooruContext booru;
  final Widget header;
  final Widget bar;

  @override
  State<ChallengeReferenceView> createState() => _ChallengeReferenceViewState();
}

class _ChallengeReferenceViewState extends State<ChallengeReferenceView> {
  ChallengeSessionController get _controller => widget.controller;
  BooruContext get _booru => widget.booru;

  List<BooruServer> get _servers => _controller.session.sourceKind == 'folder'
      ? _booru.store.servers
      : _booru.store.servers.where((server) => _controller.session.serverIDs.contains(server.id)).toList();

  BooruProviding get _source {
    final folder = _controller.session.folderID;
    if (_controller.session.sourceKind == 'folder' && folder != null) {
      return ChallengeFolderSource(store: _booru.store, folderID: folder, source: _booru.source);
    }
    return _booru.source;
  }

  Widget _introduction(BuildContext context) {
    final session = _controller.session;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        widget.header,
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: Text(
                L10n.text('Reference Images'),
                style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
              ),
            ),
            ChallengeButton(
              title: L10n.text('Image Source'),
              icon: CupertinoIcons.slider_horizontal_3,
              plain: true,
              onPressed: () => showAppSheet<void>(
                context,
                builder: (context, scroll) => _ChallengeSourceView(controller: _controller, booru: _booru),
              ),
            ),
          ],
        ),
        if (session.sourceKind == 'folder') ...[
          const SizedBox(height: 20),
          Text(
            L10n.text('Saved images need a connection unless their media is already cached.'),
            style: TegnalType.style(12, color: TegnalColors.secondaryLabel.resolveFrom(context)),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = _controller.session;
    final servers = _servers;
    if (session.canSearchImages && servers.isNotEmpty && (session.sourceKind != 'folder' || session.folderID != null)) {
      final feedID = (session.mission?.id ?? 'idle') + session.sourceKind + session.serverIDs.join() + (session.folderID ?? '');
      return BooruFeedView(
        key: ValueKey(feedID),
        booru: _booru,
        servers: servers,
        source: _source,
        initialQuery: session.mission?.tags.join(' ') ?? '',
        challenge: _controller,
        header: _introduction(context),
        bar: widget.bar,
      );
    }
    final top = MediaQuery.paddingOf(context).top + rootBarHeight;
    final message = session.phase == ChallengePhase.spinning
        ? 'Images will load after the reels stop.'
        : session.mission == null
        ? 'Draw a mission to choose a reference image.'
        : 'Choose a registered server or a saved folder.';
    return Stack(
      children: [
        Positioned.fill(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(16, top + 16, 16, 32 + MediaQuery.paddingOf(context).bottom),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _introduction(context),
                const SizedBox(height: 20),
                Center(
                  child: Text(
                    L10n.text(message),
                    textAlign: TextAlign.center,
                    style: TegnalType.style(17, color: TegnalColors.secondaryLabel.resolveFrom(context)),
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(left: 0, right: 0, top: 0, child: widget.bar),
      ],
    );
  }
}

/// `ChallengeSourceView`: the servers to search, or one saved folder.
class _ChallengeSourceView extends StatefulWidget {
  const _ChallengeSourceView({required this.controller, required this.booru});
  final ChallengeSessionController controller;
  final BooruContext booru;

  @override
  State<_ChallengeSourceView> createState() => _ChallengeSourceViewState();
}

class _ChallengeSourceViewState extends State<_ChallengeSourceView> {
  late String _kind = widget.controller.session.sourceKind;
  late final List<String> _servers = widget.controller.session.serverIDs.isEmpty
      ? [...widget.booru.store.selectedServerIDs]
      : [...widget.controller.session.serverIDs];
  late String? _folder = widget.controller.session.folderID;

  bool get _valid => _kind == 'servers' ? _servers.isNotEmpty : _folder != null;

  @override
  void initState() {
    super.initState();
    widget.booru.store.addListener(_changed);
  }

  @override
  void dispose() {
    widget.booru.store.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.booru.store;
    final purple = SystemColors.purple.resolveFrom(context);
    return ScrollEdgeSheet(
      bar: SheetNavigationBar(
        title: '',
        leading: GlassTextButton(label: L10n.text('Cancel'), tint: purple, onPressed: () => Navigator.of(context).pop()),
        trailing: GlassTextButton(
          label: L10n.text('Done'),
          tint: purple,
          onPressed: _valid
              ? () {
                  widget.controller.source(kind: _kind, servers: _servers, folder: _folder);
                  Navigator.of(context).pop();
                }
              : null,
        ),
      ),
      child: ListView(
        padding: EdgeInsets.only(top: 72, bottom: 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          // The sheet's large navigation title, scrolling with the form.
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 9),
            child: Text(
              L10n.text('Image Source'),
              style: TegnalType.style(34, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)).copyWith(height: 1.2),
            ),
          ),
          FormSection(
            children: [
              FormRow(
                child: TegnalSegmented<String>(
                  options: [('servers', L10n.text('Servers')), ('folder', L10n.text('Saved Folder'))],
                  selected: _kind,
                  onSelected: (value) => setState(() => _kind = value),
                ),
              ),
              if (_kind == 'servers') ...[
                for (final server in store.servers)
                  FormRow(
                    child: Row(
                      children: [
                        Expanded(child: Text(server.displayName)),
                        TegnalSwitch(
                          tint: purple,
                          value: _servers.contains(server.id),
                          onChanged: (checked) => setState(() {
                            _servers.remove(server.id);
                            if (checked) _servers.add(server.id);
                          }),
                        ),
                      ],
                    ),
                  ),
                FormRow(
                  onTap: () => showWebsiteConnectionEditor(context, content: widget.booru.downloads.content, state: widget.booru.state, booru: store),
                  child: Row(
                    children: [
                      Icon(CupertinoIcons.plus, size: 22, color: purple),
                      const SizedBox(width: 12),
                      Text(L10n.text('Add a Server'), style: TegnalType.style(17, color: purple)),
                    ],
                  ),
                ),
              ] else
                ChallengePickerRow<String?>(
                  tint: purple,
                  title: L10n.text('Saved Folder'),
                  options: [(null, L10n.text('Choose a Folder')), for (final folder in store.folders()) (folder.id, folder.displayName)],
                  selected: _folder,
                  onSelected: (value) => setState(() => _folder = value),
                ),
              FormRow(
                child: Text(
                  L10n.text('This choice stays on this device. Existing blocked tags and artists still apply.'),
                  style: TegnalType.style(12, color: TegnalColors.secondaryLabel.resolveFrom(context)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// `ChallengePreviewView`: the challenge playable in a sheet, with every ending to look at.
class ChallengePreviewView extends StatefulWidget {
  const ChallengePreviewView({super.key, required this.controller, this.scrollController});
  final ChallengeSessionController controller;
  final ScrollController? scrollController;

  @override
  State<ChallengePreviewView> createState() => _ChallengePreviewViewState();
}

class _ChallengePreviewViewState extends State<ChallengePreviewView> {
  late final _reveal = _RevealDriver(widget.controller);
  final _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _reveal.cancel();
    widget.controller.dispose();
    super.dispose();
  }

  void _changed() {
    _reveal.update();
    final error = widget.controller.error;
    if (error != null && mounted) {
      widget.controller.error = null;
      showChallengeError(context, error);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final session = controller.session;
    final purple = SystemColors.purple.resolveFrom(context);
    final label = TegnalColors.label.resolveFrom(context);
    return ScrollEdgeSheet(
      bar: SheetNavigationBar(
        title: L10n.text('Preview Challenge'),
        leading: Builder(
          builder: (buttonContext) => ToolbarGroup(
            children: [
              ToolbarIconButton(
                label: L10n.text('Challenge Settings'),
                icon: CupertinoIcons.ellipsis_circle,
                onPressed: () => showActionMenu(
                  buttonContext,
                  anchor: anchorOf(buttonContext),
                  actions: [ContextMenuAction(title: L10n.text('How to Play'), onSelected: () => showChallengeHelp(context, session.definition))],
                ),
              ),
            ],
          ),
        ),
        trailing: GlassTextButton(label: L10n.text('Done'), prominent: true, onPressed: () => Navigator.of(context).pop()),
      ),
      child: ListView(
        controller: widget.scrollController,
        padding: EdgeInsets.fromLTRB(16, 69 + 16, 16, 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          ChallengeReelsView(controller: controller),
          if (session.mission case final mission?) ...[const SizedBox(height: 20), Text(mission.text, style: TegnalType.style(17, color: label))],
          const SizedBox(height: 20),
          ChallengeSessionControls(controller: controller),
          if (session.ending case final ending?) ...[const SizedBox(height: 20), ChallengeEndingCard(ending: ending)],
          const SizedBox(height: 20),
          Center(
            child: GestureDetector(
              onTap: controller.restart,
              child: Text(L10n.text('Restart'), style: TegnalType.style(17, color: purple)),
            ),
          ),
          for (final ending in session.definition.endings) ...[
            const SizedBox(height: 20),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _expanded.contains(ending.id) ? _expanded.remove(ending.id) : _expanded.add(ending.id)),
              child: Row(
                children: [
                  Expanded(
                    child: Text(ending.title, style: TegnalType.style(17, color: label)),
                  ),
                  AnimatedRotation(
                    turns: _expanded.contains(ending.id) ? 0.25 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(CupertinoIcons.chevron_right, size: 15, color: purple),
                  ),
                ],
              ),
            ),
            if (_expanded.contains(ending.id)) ...[const SizedBox(height: 12), ChallengeEndingCard(ending: ending)],
          ],
        ],
      ),
    );
  }
}

/// `ChallengeHelpView`: How to Play, one tab per page. Text only; nothing in a page runs.
Future<void> showChallengeHelp(BuildContext context, ChallengeDefinition game) =>
    showAppSheet<void>(context, builder: (context, scroll) => _ChallengeHelpView(game: game));

class _ChallengeHelpView extends StatefulWidget {
  const _ChallengeHelpView({required this.game});
  final ChallengeDefinition game;

  @override
  State<_ChallengeHelpView> createState() => _ChallengeHelpViewState();
}

class _ChallengeHelpViewState extends State<_ChallengeHelpView> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final pages = widget.game.instructionPages;
    final page = pages.where((item) => item.id == _selected).firstOrNull ?? pages.first;
    final purple = SystemColors.purple.resolveFrom(context);
    return ScrollEdgeSheet(
      bar: SheetNavigationBar(
        title: L10n.text('How to Play'),
        trailing: GlassTextButton(label: L10n.text('Done'), prominent: true, onPressed: () => Navigator.of(context).pop()),
      ),
      child: Column(
        children: [
          const SizedBox(height: 69),
          if (pages.length > 1) ...[
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  for (final item in pages) ...[
                    if (item != pages.first) const SizedBox(width: 8),
                    Semantics(
                      button: true,
                      selected: item.id == page.id,
                      child: GestureDetector(
                        onTap: () => setState(() => _selected = item.id),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          decoration: ShapeDecoration(color: item.id == page.id ? purple : purple.withValues(alpha: 0.08), shape: const StadiumBorder()),
                          child: Text(
                            item.title,
                            style: TegnalType.style(15, weight: FontWeight.w600, color: item.id == page.id ? const Color(0xFFFFFFFF) : purple),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Container(height: 0.5, color: TegnalColors.separator.resolveFrom(context)),
          ],
          Expanded(
            child: SingleChildScrollView(
              key: ValueKey(page.id),
              padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.paddingOf(context).bottom),
              child: SizedBox(
                width: double.infinity,
                child: Text(page.body, style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context))),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
