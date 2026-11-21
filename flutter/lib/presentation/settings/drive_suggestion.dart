import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/content/content_environment.dart';
import '../../core/support/l10n.dart';
import '../../core/sync/library_drive_sync.dart';
import '../design/alert_dialog.dart';
import '../home/home_stage.dart';

/// Android only: once, someone who set up the app before Google Drive existed (or skipped it) is
/// asked to connect it, as iOS needs no such step for iCloud. New installs see onboarding's Drive
/// page instead, which counts as the suggestion.
class DriveSuggestionGate extends StatefulWidget {
  const DriveSuggestionGate({super.key, required this.sync, required this.content, required this.child, this.isTesting = false});
  final LibraryDriveSync? sync;
  final ContentEnvironment content;
  final Widget child;
  final bool isTesting;

  /// True once the suggestion was shown in this launch, so other launch prompts wait for the next one.
  static bool askedThisLaunch = false;

  /// The suggestion's own text, shared with onboarding's page.
  static String get message => L10n.text(
    'Sign in with Google to keep your libraries, folders and settings in sync across your Android devices, and to keep a copy of each automatic backup in Google Drive. TEGNAL only sees the files it creates in its own TEGNAL folder.',
  );

  @override
  State<DriveSuggestionGate> createState() => _DriveSuggestionGateState();
}

class _DriveSuggestionGateState extends State<DriveSuggestionGate> {
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(onResume: _check);
  bool _covered = false;
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    _lifecycle;
    _covered = HomeStage.shared.coversScreen;
    HomeStage.shared.addListener(_stageChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    HomeStage.shared.removeListener(_stageChanged);
    _lifecycle.dispose();
    super.dispose();
  }

  /// Nothing is asked over the home scene; the suggestion waits until a place is on screen.
  void _stageChanged() {
    final covered = HomeStage.shared.coversScreen;
    if (covered == _covered) return;
    _covered = covered;
    if (!covered && WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final sync = widget.sync;
    if (!mounted || _asking || widget.isTesting || sync == null || HomeStage.shared.coversScreen) return;
    // A first run's onboarding shows the Drive page itself.
    if (!widget.content.isOnboardingCompleted || !sync.shouldSuggest) return;
    sync.markSuggested();
    DriveSuggestionGate.askedThisLaunch = true;
    _asking = true;
    final connect = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('Keep Your Library in Google Drive')),
        content: Text(DriveSuggestionGate.message),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Not Now'))),
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Connect'))),
        ],
      ),
    );
    _asking = false;
    if (connect != true || !mounted) return;
    final error = await sync.connect();
    if (error == null || !mounted) return;
    await showCupertinoDialog<void>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('Google Drive')),
        content: Text(error),
        actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('OK')))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
