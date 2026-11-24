import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/booru/booru_models.dart';
import '../../core/lab/lab_shop.dart';
import '../../core/lab/lab_store.dart';
import '../../core/support/l10n.dart';
import '../booru/booru_common.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';
import '../lab/lab_shop_views.dart';
import 'study_tag_view.dart';
import 'study_widgets.dart' show StudySymbols;

// The prompt analyzer, sold in the lab's shop (`feature.prompt-analyzer`, which needs 2D AI 배우기 first).
// Ported from `PromptAnalyzerRow` in `StudyTagView.swift`.

/// The picture details' way into the prompt analyzer: the analyzer itself once its key is bought, else the analyzer's page
/// in the shop, where it is bought. Both are pushed onto the details' own navigation, so no second sheet stacks on them.
class PromptAnalyzerRow extends StatelessWidget {
  const PromptAnalyzerRow({super.key, required this.booru, required this.post, required this.tint});
  final BooruContext booru;
  final BooruPost post;
  final Color tint;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: LabStore.shared,
    builder: (context, _) {
      final unlocked = LabStore.shared.unlocked(LabFeature.promptAnalyzer);
      return FormRow(
        key: const Key('booru.prompt'),
        onTap: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (context) => PromptAnalyzerDestination(booru: booru, post: post))),
        child: Row(
          children: [
            Icon(StudySymbols.prompt, size: 22, color: tint),
            const SizedBox(width: 12),
            Expanded(child: Text(L10n.text('Prompt Analyzer'))),
            if (!unlocked) ...[
              Icon(CupertinoIcons.lock_fill, size: 14, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
              const SizedBox(width: 8),
            ],
            Icon(CupertinoIcons.chevron_right, size: 14, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
          ],
        ),
      );
    },
  );
}

/// What the row opens, decided when it is opened: the shop page stays on screen through its purchase (and its celebration)
/// until "open" turns it into the analyzer.
class PromptAnalyzerDestination extends StatefulWidget {
  const PromptAnalyzerDestination({super.key, required this.booru, required this.post});
  final BooruContext booru;
  final BooruPost post;

  @override
  State<PromptAnalyzerDestination> createState() => _PromptAnalyzerDestinationState();
}

class _PromptAnalyzerDestinationState extends State<PromptAnalyzerDestination> {
  bool _buying = !LabStore.shared.unlocked(LabFeature.promptAnalyzer);

  @override
  Widget build(BuildContext context) => _buying
      ? LabShopItemPage(itemID: LabFeature.promptAnalyzer.item, outside: true, pushed: true, onOpen: () => setState(() => _buying = false))
      : StudyPromptView(booru: widget.booru, post: widget.post);
}
