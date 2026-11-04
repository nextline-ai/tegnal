import 'package:cupertino_ui/cupertino_ui.dart';

import '../../../core/support/l10n.dart';
import '../../../core/taste/taste_models.dart';
import '../../design/tegnal_theme.dart';
import '../taste_context.dart';
import 'recap_style.dart';

/// `TasteRecapBanner`: above the tabs when a new monthly issue arrives, opening it or
/// dismissing the prompt.
class TasteRecapBanner extends StatelessWidget {
  const TasteRecapBanner({super.key, required this.taste, required this.mode, required this.open});
  final TasteContext taste;
  final TasteMode mode;
  final VoidCallback open;

  static const _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

  /// The issue's month, written out in the app language.
  static String _title(DateTime date) => switch (L10n.language) {
    'ko' => '${date.year}년 ${date.month}월',
    'ja' => '${date.year}年${date.month}月',
    _ => '${_months[date.month - 1]} ${date.year}',
  };

  @override
  Widget build(BuildContext context) {
    final date = taste.controller.pendingRecap(mode);
    if (date == null) return const SizedBox.shrink();
    const white = Color(0xFFFFFFFF);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: const LinearGradient(colors: [Color(0xFF211733), Color(0xFF401A45)]),
        ),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                button: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: open,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 0, 12),
                    child: Row(
                      children: [
                        ExcludeSemantics(
                          child: Container(
                            width: 34,
                            height: 44,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(color: const Color(0x24FFFFFF), borderRadius: BorderRadius.circular(5)),
                            child: Text('R', style: RecapType.display(26, color: white)),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                L10n.text('Your new issue has arrived'),
                                style: TegnalType.style(15, weight: FontWeight.w700, color: white),
                              ),
                              const SizedBox(height: 3),
                              Text(_title(date), style: TegnalType.style(12, color: white)),
                            ],
                          ),
                        ),
                        const Icon(CupertinoIcons.chevron_right, size: 13, color: white),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Semantics(
              button: true,
              label: L10n.text('Dismiss recap banner'),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taste.controller.dismissRecap(mode),
                child: const SizedBox(width: 44, height: 44, child: Icon(CupertinoIcons.xmark, size: 15, color: white)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
