import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/content/cover_queue.dart';
import '../../core/support/l10n.dart';
import '../design/alert_dialog.dart';

enum _Answer { addWebsite, fillAnyway, later }

/// `CoverFillSiteWarning`: asks before a fill reads many works from websites that block bulk
/// reading, offering to add another website to read from instead. Imports, restores and sync
/// start fills from many screens, so it is shown on the root navigator over whatever is open.
/// The fill runs again once the website editor closes, reading from the new website when one
/// was added.
Future<void> showCoverFillSiteWarning(
  BuildContext context, {
  required CoverQueue queue,
  required int pending,
  required List<String> sites,
  required Future<void> Function() addWebsite,
}) async {
  final answer = await showCupertinoDialog<_Answer>(
    context: context,
    useRootNavigator: true,
    builder: (context) => TegnalAlertDialog(
      title: Text(L10n.text('Add Another Website First?')),
      content: Text(
        L10n.text(
          '%1\$@ works are missing covers, titles or tags. Filling them reads each work from %2\$@, and this website may block your network address when one device reads many works in a short time.\n\nAdd another comics website and the missing information is read from there instead. If you fill anyway, one work is read every few seconds.',
          ['$pending', sites.join(', ')],
        ),
      ),
      actions: [
        CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context, _Answer.addWebsite), child: Text(L10n.text('Add Website'))),
        CupertinoDialogAction(
          isDestructiveAction: true,
          onPressed: () => Navigator.pop(context, _Answer.fillAnyway),
          child: Text(L10n.text('Fill Slowly Anyway')),
        ),
        CupertinoDialogAction(onPressed: () => Navigator.pop(context, _Answer.later), child: Text(L10n.text('Later'))),
      ],
    ),
  );
  switch (answer) {
    case _Answer.fillAnyway:
      queue.answerBulkFill(CoverFillDecision.approved, pending);
    case _Answer.addWebsite:
      queue.answerBulkFill(CoverFillDecision.declined, pending);
      await addWebsite();
      queue.start();
    case _Answer.later || null:
      queue.answerBulkFill(CoverFillDecision.declined, pending);
  }
}

/// The connected websites, when every one of them blocks bulk reading, for the fill row's note.
String? sitesBlockingBulkReading(List<String> sites, {bool Function(String site) blocks = CoverFillGuard.blocksBulkReading}) {
  if (sites.isEmpty || !sites.every(blocks)) return null;
  return sites.join(', ');
}
