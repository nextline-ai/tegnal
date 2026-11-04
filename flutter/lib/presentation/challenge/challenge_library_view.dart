import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/booru/booru_store.dart';
import '../../core/challenge/challenge_models.dart';
import '../../core/challenge/challenge_store.dart';
import '../../core/support/document_files.dart';
import '../../core/support/l10n.dart';
import '../../core/support/swift_json.dart' show uuidString;
import '../design/app_sheet.dart';
import '../design/context_menu.dart';
import '../design/grouped_form.dart';
import '../design/symbols.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import '../library/folders_view.dart' show anchorOf;
import '../library/library_routes.dart' show showTransientMessage;
import '../settings/settings_page.dart';
import '../settings/settings_rows.dart';
import '../booru/booru_common.dart';
import 'challenge_editor_view.dart';
import 'challenge_play_view.dart';
import '../design/alert_dialog.dart';

/// `ChallengeLibraryView`: the built-in croquis example, a person's own challenges and
/// their backups.
class ChallengeLibraryView extends StatefulWidget {
  const ChallengeLibraryView({super.key, required this.booru});

  /// Image mode, where challenges are stored and their reference images come from.
  final BooruContext booru;

  @override
  State<ChallengeLibraryView> createState() => _ChallengeLibraryViewState();
}

class _ChallengeLibraryViewState extends State<ChallengeLibraryView> {
  late final _store = ChallengeStore(widget.booru.store);
  List<ChallengeDefinition> _games = [];
  Set<String> _sessions = {};
  String? _busy;

  @override
  void initState() {
    super.initState();
    _reload();
    widget.booru.store.addListener(_reload);
  }

  @override
  void dispose() {
    widget.booru.store.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (!mounted || _busy != null) return;
    try {
      setState(() {
        _games = _store.definitions().where((game) => game.id != ChallengeDefinition.exampleID).toList();
        _sessions = _store.sessionIDs();
      });
    } on Object catch (error) {
      showChallengeError(context, error);
    }
  }

  Future<void> _run(String label, Future<void> Function() action) async {
    if (_busy != null) return;
    setState(() => _busy = label);
    try {
      await action();
    } on Object catch (error) {
      if (mounted) showChallengeError(context, error);
    }
    if (!mounted) return;
    setState(() => _busy = null);
    _reload();
  }

  Future<void> _edit(ChallengeDefinition game) async {
    await showAppSheet<void>(
      context,
      builder: (context, controller) => ChallengeEditorView(game: game, store: _store, preview: previewChallenge),
    );
    _reload();
  }

  Future<void> _play(ChallengeDefinition game) async {
    await openChallenge(context, booru: widget.booru, game: game);
    _reload();
  }

  Future<void> _delete(ChallengeDefinition game) async {
    final delete = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('Delete Challenge?')),
        content: Text(L10n.text('This removes the challenge and its progress from this device.')),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Delete'))),
        ],
      ),
    );
    if (delete == true) await _run(L10n.text('Deleting…'), () async => _store.delete(game.id));
  }

  List<ContextMenuAction> _actions(ChallengeDefinition game) => [
    ContextMenuAction(title: L10n.text('Edit'), icon: CupertinoIcons.pencil, onSelected: () => _edit(game)),
    ContextMenuAction(
      title: L10n.text('Duplicate'),
      icon: CupertinoIcons.plus_square_on_square,
      onSelected: () {
        final copy = ChallengeDefinition.fromJson(game.toJson())
          ..id = uuidString()
          ..title = '${game.title.characters.take(190)} ${L10n.text('Copy')}';
        _edit(copy);
      },
    ),
    ContextMenuAction(title: L10n.text('Export Challenge Backup'), icon: CupertinoIcons.square_arrow_up, onSelected: () => exportChallenges(context, [game])),
    ContextMenuAction(title: L10n.text('Delete'), icon: CupertinoIcons.trash, destructive: true, onSelected: () => _delete(game)),
  ];

  @override
  Widget build(BuildContext context) {
    final purple = SystemColors.purple.resolveFrom(context);
    final row = FormColors.listRow.resolveFrom(context);
    return Stack(
      children: [
        SettingsPage(
          title: L10n.text('Challenge Roulette'),
          children: [
            // A first section without a header starts 35 pt under the bar.
            const SizedBox(height: 25),
            FormSection(
              rowColor: row,
              children: [
                FormRow(
                  onTap: () => _run(L10n.text('Loading…'), () async {
                    final game = _store.example();
                    if (mounted) await _play(game);
                  }),
                  child: _GameRow(
                    icon: CupertinoIcons.pencil_outline,
                    title: L10n.text('Croquis Challenge'),
                    detail: L10n.text('Choose a reference and practice a quick sketch.'),
                  ),
                ),
              ],
            ),
            settingsSectionGap,
            FormSection(
              rowColor: row,
              header: Text(L10n.text('My Challenges')),
              footer: Text(L10n.text('Challenge definitions, progress and image sources stay on this device.')),
              children: [
                for (final game in _games)
                  Builder(
                    builder: (rowContext) => FormRow(
                      onTap: () => _play(game),
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onLongPress: () => showActionMenu(rowContext, anchor: anchorOf(rowContext), actions: _actions(game)),
                        child: Row(
                          children: [
                            Expanded(
                              child: _GameRow(
                                icon: game.goal.mode == ChallengeGoalMode.time ? CupertinoIcons.timer : null,
                                title: game.title,
                                detail: game.detail,
                                trailing: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(_sessions.contains(game.id) ? CupertinoIcons.play_circle_fill : CupertinoIcons.play_circle, size: 26, color: purple),
                                    const SizedBox(height: 5),
                                    Text(
                                      L10n.text(_sessions.contains(game.id) ? 'Continue' : 'Play'),
                                      style: TegnalType.style(11, weight: FontWeight.w600, color: purple),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Semantics(
                              button: true,
                              label: L10n.text('Challenge Settings'),
                              child: Builder(
                                builder: (buttonContext) => GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => showActionMenu(buttonContext, anchor: anchorOf(buttonContext), actions: _actions(game)),
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(8, 16, 0, 16),
                                    child: Icon(CupertinoIcons.ellipsis, size: 20, color: purple),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                FormRow(
                  onTap: () => _edit(ChallengeDefinition.croquis()..title = L10n.text('New Challenge')),
                  child: Row(
                    children: [
                      Icon(CupertinoIcons.plus, size: 22, color: purple),
                      const SizedBox(width: 16),
                      Text(
                        L10n.text('New Challenge'),
                        style: TegnalType.style(17, weight: FontWeight.w600, color: purple),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            settingsSectionGap,
            FormSection(
              rowColor: row,
              children: [
                SettingsLinkRow(
                  title: L10n.text('Challenge Backup and Import'),
                  symbol: (_) => ExternalDriveSymbol(color: SystemColors.purple.resolveFrom(context)),
                  onTap: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => ChallengeBackupView(booru: widget.booru.store))),
                ),
              ],
            ),
          ],
        ),
        if (_busy != null)
          Positioned.fill(
            child: ColoredBox(
              color: const Color(0x00000000),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(28),
                  decoration: ShapeDecoration(
                    color: TegnalColors.elevatedGlassFill.resolveFrom(context),
                    shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CupertinoActivityIndicator(radius: 14),
                      const SizedBox(height: 12),
                      Text(
                        _busy!,
                        style: TegnalType.style(15, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// One challenge: a purple symbol in a soft tile, the title and its instructions.
class _GameRow extends StatelessWidget {
  const _GameRow({required this.icon, required this.title, required this.detail, this.trailing});

  /// Null draws `dice`.
  final IconData? icon;
  final String title;
  final String detail;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final purple = SystemColors.purple.resolveFrom(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 48,
            decoration: ShapeDecoration(
              color: purple.withValues(alpha: 0.08),
              shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: icon == null ? DiceSymbol(color: purple) : Icon(icon, size: 22, color: purple),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                ),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TegnalType.style(12, color: TegnalColors.secondaryLabel.resolveFrom(context)),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}

/// `ChallengeBackupView`: export every challenge or import a backup file.
class ChallengeBackupView extends StatefulWidget {
  const ChallengeBackupView({super.key, required this.booru});
  final BooruStore booru;

  @override
  State<ChallengeBackupView> createState() => _ChallengeBackupViewState();
}

class _ChallengeBackupViewState extends State<ChallengeBackupView> {
  bool _busy = false;

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final file = await const DocumentFiles().openDocument(mimeTypes: const ['application/json']);
      if (file != null) {
        final data = await file.readAsBytes();
        if (data.length > ChallengeBackup.maximumBytes) throw const ChallengeError.unsupported();
        ChallengeStore(widget.booru).restore(ChallengeBackup.decode(data), replace: false);
        widget.booru.refresh();
        if (mounted) showTransientMessage(context, L10n.text('Challenges imported successfully.'));
      }
    } on Object catch (error) {
      if (mounted) showChallengeError(context, error);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final purple = SystemColors.purple.resolveFrom(context);
    return SettingsPage(
      title: L10n.text('Challenge Backup and Import'),
      children: [
        IgnorePointer(
          ignoring: _busy,
          child: FormSection(
            rowColor: FormColors.listRow.resolveFrom(context),
            footer: Text(
              L10n.text('Back up challenge definitions only. Images, accounts, image sources and progress are not included. Maximum file size: 10 MB.'),
            ),
            children: [
              FormRow(
                onTap: () => exportChallenges(context, ChallengeStore(widget.booru).definitions()),
                child: Row(
                  children: [
                    Icon(CupertinoIcons.square_arrow_up, size: 22, color: purple),
                    const SizedBox(width: 16),
                    Text(L10n.text('Export Challenge Backup'), style: TegnalType.style(17, color: purple)),
                  ],
                ),
              ),
              FormRow(
                onTap: _import,
                child: Row(
                  children: [
                    Icon(CupertinoIcons.square_arrow_down, size: 22, color: purple),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(L10n.text('Import Challenge Backup'), style: TegnalType.style(17, color: purple)),
                    ),
                    if (_busy) const CupertinoActivityIndicator(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Writes [games] to a backup file the person places with the system picker.
Future<void> exportChallenges(BuildContext context, List<ChallengeDefinition> games) async {
  try {
    final file = File('${Directory.systemTemp.path}/tegnal-challenges.json');
    await file.writeAsBytes(ChallengeBackup(games: games).encoded());
    await const DocumentFiles().createDocument(name: 'tegnal-challenges.json', source: file);
  } on Object catch (error) {
    if (context.mounted) showChallengeError(context, error);
  }
}

/// `challengeError`: Unable to Continue, with the reason.
void showChallengeError(BuildContext context, Object error) => showCupertinoDialog<void>(
  context: context,
  builder: (context) => TegnalAlertDialog(
    title: Text(L10n.text('Unable to Continue')),
    content: Text(error is ChallengeError ? error.errorDescription : '$error'),
    actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('OK')))],
  ),
);
