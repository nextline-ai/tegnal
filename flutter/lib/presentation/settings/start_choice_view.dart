import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../../core/support/l10n.dart';
import '../../core/support/preferences.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';
import '../study_mode/study_kit.dart';

/// The image-mode preference that records the first-run question has been answered.
const String startChoiceMadeKey = 'study.startChoiceMade';

/// The first choice of how the app opens: learning mode or the library (`OnboardingView.modes`). It becomes
/// the default, and the question is asked once.
class StartChoiceView extends StatefulWidget {
  const StartChoiceView({super.key, required this.preferences, this.mode});

  /// The image-mode preferences, where the answer is recorded.
  final Preferences preferences;

  /// The mode to set; null is [StudyMode.shared].
  final StudyMode? mode;

  /// Whether the question was answered before.
  static bool isAnswered(Preferences preferences) => preferences.boolean(startChoiceMadeKey) ?? false;

  @override
  State<StartChoiceView> createState() => _StartChoiceViewState();
}

class _StartChoiceViewState extends State<StartChoiceView> {
  /// True for learning mode, false for viewing mode; null until one is picked.
  bool? _startsLearning;

  StudyMode get _mode => widget.mode ?? StudyMode.shared;

  void _choose(bool learning) {
    if (_startsLearning == learning) return;
    HapticFeedback.selectionClick();
    setState(() => _startsLearning = learning);
  }

  void _next() {
    final learning = _startsLearning;
    if (learning == null) return;
    // What is chosen here is how the app opens from now on.
    _mode.startsActive = learning;
    _mode.startsInLibrary = !learning;
    widget.preferences.set(startChoiceMadeKey, true);
    Navigator.of(context).pop();
    if (learning) _mode.enter();
  }

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    return PopScope(
      canPop: false,
      child: CupertinoPageScaffold(
        backgroundColor: FormColors.listBackground.resolveFrom(context),
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Semantics(
                        container: true,
                        key: const ValueKey('onboarding.mode'),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              L10n.text('Choose How to Start'),
                              style: TegnalType.style(34, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
                            ),
                            const SizedBox(height: 20),
                            Text(
                              L10n.text('The app opens in the mode you choose here. You can change it anytime in Settings.'),
                              style: TegnalType.style(17, color: TegnalColors.secondaryLabel.resolveFrom(context)).copyWith(height: 1.3),
                            ),
                            const SizedBox(height: 20),
                            _card(
                              context,
                              learning: true,
                              title: 'Learning Mode',
                              detail: 'Learn to make anime-style pictures with AI from the very start, one short lesson at a time.',
                              picture: SizedBox(
                                width: 64,
                                child: StudyMascot(pose: StudyMascotPose.fullBody, size: 84, lively: _startsLearning == true),
                              ),
                            ),
                            const SizedBox(height: 20),
                            _card(
                              context,
                              learning: false,
                              title: 'Viewing Mode',
                              detail: 'Find, save and enjoy comics and images in your own library.',
                              picture: SizedBox(
                                width: 64,
                                height: 84,
                                child: Center(child: StudyIcon('books.vertical.fill', size: 38, color: tint)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Container(
                color: TegnalColors.background.resolveFrom(context).withValues(alpha: 0.92),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: _ContinueButton(
                      key: const ValueKey('onboarding.continue'),
                      label: L10n.text(_startsLearning == true ? 'Start Learning' : 'Continue'),
                      onPressed: _startsLearning == null ? null : _next,
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

  /// `mode(_:title:detail:picture:)`.
  Widget _card(BuildContext context, {required bool learning, required String title, required String detail, required Widget picture}) {
    final chosen = _startsLearning == learning;
    final tint = TegnalColors.tint.resolveFrom(context);
    return Semantics(
      key: ValueKey(learning ? 'onboarding.mode.learning' : 'onboarding.mode.viewing'),
      button: true,
      selected: chosen,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _choose(learning),
        child: AnimatedScale(
          scale: chosen ? 1.02 : 1,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutBack,
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: ShapeDecoration(
              color: FormColors.listRow.resolveFrom(context),
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(22),
                side: BorderSide(color: chosen ? tint : const Color(0x00000000), width: 3, strokeAlign: BorderSide.strokeAlignInside),
              ),
            ),
            child: Row(
              children: [
                picture,
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        L10n.text(title),
                        style: TegnalType.style(22, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
                      ),
                      const SizedBox(height: 6),
                      Text(L10n.text(detail), style: TegnalType.style(15, color: TegnalColors.secondaryLabel.resolveFrom(context))),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Icon(
                  chosen ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle,
                  size: 24,
                  color: chosen ? tint : TegnalColors.secondaryLabel.resolveFrom(context).withValues(alpha: 0.4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `.borderedProminent` with `.controlSize(.large)`: a filled tint capsule, dimmed while disabled.
class _ContinueButton extends StatelessWidget {
  const _ContinueButton({super.key, required this.label, required this.onPressed});

  /// `quaternarySystemFill`, behind a disabled prominent button.
  static const _disabledFill = CupertinoDynamicColor.withBrightness(color: Color(0x14747480), darkColor: Color(0x2E767680));
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onPressed != null,
    label: label,
    excludeSemantics: true,
    child: CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      // Disabled, iOS draws it in a faint grey fill with grey words rather than a dimmed tint.
      child: Container(
        height: 52,
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: onPressed == null ? _disabledFill.resolveFrom(context) : TegnalColors.tint.resolveFrom(context),
          shape: const StadiumBorder(),
        ),
        child: Text(
          label,
          style: TegnalType.style(
            17,
            weight: FontWeight.w600,
            color: onPressed == null ? TegnalColors.tertiaryLabel.resolveFrom(context) : const Color(0xFFFFFFFF),
          ),
        ),
      ),
    ),
  );
}
