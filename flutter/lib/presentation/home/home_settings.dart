import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/support/l10n.dart';
import '../design/grouped_form.dart';
import '../settings/settings_rows.dart';
import '../study_mode/study_kit.dart';
import 'home_stage.dart';

/// `StudyModeSettings`: where the app opens, shown beside Safe Mode in both modes' settings. Only one
/// of the two places can be the one the app goes straight on to.
class HomeStartSettings extends StatelessWidget {
  const HomeStartSettings({super.key, this.rowColor, this.gap = const SizedBox(height: 28)});
  final Color? rowColor;

  /// The space between the two sections, as the surrounding list leaves between its sections.
  final Widget gap;

  @override
  Widget build(BuildContext context) {
    final stage = HomeStage.shared;
    final row = rowColor ?? FormColors.listRow.resolveFrom(context);
    return ListenableBuilder(
      listenable: stage,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormSection(
            prominentHeader: true,
            rowColor: row,
            header: Text(L10n.text('Learning Mode')),
            children: [
              SettingsToggleRow(
                key: const Key('settings.startInStudyMode'),
                title: L10n.text('Open in Learning Mode'),
                help: L10n.text(
                  'Turning this on opens the app straight into learning mode, where tags for prompting image AI are learned step by step. The library stays one tap away.',
                ),
                value: stage.startsLearning,
                onChanged: (value) => stage.startsLearning = value,
              ),
              SettingsLinkRow(
                key: const Key('settings.enterStudyMode'),
                title: L10n.text('Enter Learning Mode'),
                tinted: true,
                chevron: false,
                onTap: () => StudyMode.shared.enterLab(),
              ),
            ],
          ),
          gap,
          FormSection(
            prominentHeader: true,
            rowColor: row,
            header: Text(L10n.text('Viewing Mode')),
            children: [
              SettingsToggleRow(
                key: const Key('settings.startInViewingMode'),
                title: L10n.text('Open in Viewing Mode'),
                help: L10n.text('Turning this on takes the app straight on from its opening scene into viewing mode, without waiting for a swipe.'),
                value: stage.startsInLibrary,
                onChanged: (value) => stage.startsInLibrary = value,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
