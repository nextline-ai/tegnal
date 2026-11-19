import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/support/l10n.dart';
import '../design/app_sheet.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';
import 'works_models.dart';

/// What the saved-date sheet answers: a run or month to jump to, or to select.
class SavedDateChoice<T> {
  const SavedDateChoice(this.ids, {required this.select});
  final List<T> ids;
  final bool select;
}

/// `SavedDateView`: saved items by when they were saved: runs saved together, and months. A row
/// jumps to its first item; its select button picks all of them, to move or delete together.
class SavedDateView<T> extends StatelessWidget {
  const SavedDateView({
    super.key,
    required this.months,
    required this.runs,
    required this.broughtIn,
    required this.identifier,
    required this.controller,
    this.images = false,
  });
  final List<SavedMonth<T>> months;
  final List<SavedRun<T>> runs;
  final List<DateTime> broughtIn;

  /// Starts each row's accessibility identifier, such as `works`.
  final String identifier;
  final ScrollController controller;

  /// Images are named as such; works otherwise.
  final bool images;

  static Future<SavedDateChoice<T>?> show<T>(
    BuildContext context, {
    required List<SavedMonth<T>> months,
    required List<SavedRun<T>> runs,
    required List<DateTime> broughtIn,
    required String identifier,
    bool images = false,
  }) => showAppSheet<SavedDateChoice<T>>(
    context,
    grabber: true,
    builder: (context, controller) =>
        SavedDateView<T>(months: months, runs: runs, broughtIn: broughtIn, identifier: identifier, controller: controller, images: images),
  );

  /// `Date.formatted(.dateTime.year().month().day().hour().minute())` for the three app languages.
  static String _date(DateTime date) {
    final minute = date.minute.toString().padLeft(2, '0');
    final hour12 = date.hour % 12 == 0 ? 12 : date.hour % 12;
    switch (L10n.language) {
      case 'ko':
        return '${date.year}년 ${date.month}월 ${date.day}일 ${date.hour < 12 ? '오전' : '오후'} $hour12:$minute';
      case 'ja':
        return '${date.year}年${date.month}月${date.day}日 ${date.hour}:$minute';
      default:
        const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        return '${months[date.month - 1]} ${date.day}, ${date.year} at $hour12:$minute ${date.hour < 12 ? 'AM' : 'PM'}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScrollEdgeSheet(
      bar: SheetNavigationBar(
        title: L10n.text('Browse by Saved Date'),
        leading: GlassTextButton(label: L10n.text('Close'), onPressed: () => Navigator.of(context).pop()),
      ),
      child: ListView(
        controller: controller,
        padding: EdgeInsets.only(top: 76 + 4, bottom: 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          if (runs.isNotEmpty) ...[
            FormSection(
              header: Text(L10n.text('Saved Together')),
              footer: Text(
                L10n.text(
                  images
                      ? 'Images saved within a minute of each other, such as website favorites brought in or an import. Select them to move or delete them together.'
                      : 'Works saved within a minute of each other, such as website favorites brought in or an import. Select them to move or delete them together.',
                ),
              ),
              children: [
                for (final run in runs)
                  _row(
                    context,
                    title: _date(run.start.toLocal()),
                    subtitle: run.broughtIn(broughtIn) ? L10n.text('Brought in from website favorites') : null,
                    ids: run.ids,
                    identifier: '$identifier.batch.${run.start.millisecondsSinceEpoch ~/ 1000}',
                  ),
              ],
            ),
            const SizedBox(height: 24),
          ],
          FormSection(
            header: Text(L10n.text('By Month')),
            children: [for (final month in months) _row(context, title: month.title, ids: month.ids, identifier: '$identifier.month.${month.id}')],
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, {required String title, String? subtitle, required List<T> ids, required String identifier}) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return FormRow(
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              identifier: identifier,
              button: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).pop(SavedDateChoice<T>(ids, select: false)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(title),
                            if (subtitle != null) Text(subtitle, style: TegnalType.style(12, color: secondary)),
                          ],
                        ),
                      ),
                      Text(L10n.text('%@ items', ['${ids.length}']), style: TegnalType.style(17, color: secondary)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Semantics(
            identifier: '$identifier.select',
            label: L10n.text(images ? 'Select These Images' : 'Select These Works'),
            button: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).pop(SavedDateChoice<T>(ids, select: true)),
              child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(CupertinoIcons.check_mark_circled, size: 22, color: TegnalColors.tint.resolveFrom(context)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
