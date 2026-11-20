import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/booru/booru_account.dart';
import '../../core/booru/booru_store.dart';
import '../../core/support/l10n.dart';
import '../design/alert_dialog.dart';
import '../design/app_sheet.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';
import '../home/home_stage.dart';
import '../navigation/app_state.dart';
import '../settings/settings_rows.dart';

/// Folders that stand for a server's favorites lists; they keep their server whatever the style.
Set<String> booruListFolderIDs(BooruStore store, BooruAccountSync? accounts) => {
  if (accounts != null)
    for (final server in store.servers) ...?accounts.accounts.favorites.state(server.id)?.folders.values,
};

/// What switching to a style does, in a sentence or two.
String booruFolderStyleEffect(BooruFolderStyle style, ({int folders, int mixed}) impact) => switch (style) {
  BooruFolderStyle.byServer =>
    impact.mixed > 0
        ? L10n.text(
            "Each folder goes to the server its images come from. %@ folders hold images from several servers; each becomes one folder of the same name for each server. New folders belong to the server you're browsing.",
            ['${impact.mixed}'],
          )
        : L10n.text("Each folder goes to the server its images come from. New folders belong to the server you're browsing."),
  BooruFolderStyle.shared => L10n.text(
    "Folders hold images from any server, as before. A server's copy of a folder joins the folder it came from. Folders kept with a server's favorites stay with that server.",
  ),
};

void _showError(BuildContext context, Object error) => showCupertinoDialog<void>(
  context: context,
  builder: (context) => TegnalAlertDialog(
    title: Text(L10n.text('Unable to Save')),
    content: Text('$error'),
    actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('Done')))],
  ),
);

/// `BooruFolderStyleSection`: whether image folders belong to one server each or are shared by all
/// servers, switched with a word on what changes.
class BooruFolderStyleSection extends StatelessWidget {
  const BooruFolderStyleSection({super.key, required this.store});
  final BooruStore store;

  Future<void> _change(BuildContext context, BooruFolderStyle style) async {
    if (style == store.folderStyle) return;
    final apply = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(L10n.text('Change Folder Style?')),
        message: Text(booruFolderStyleEffect(style, store.folderStyleImpact())),
        actions: [CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Change')))],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (apply != true) return;
    try {
      store.adoptFolderStyle(style, kept: booruListFolderIDs(store, BooruAccountSync.shared));
    } on Object catch (error) {
      if (context.mounted) _showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) => FormSection(
      prominentHeader: true,
      rowColor: FormColors.listRow.resolveFrom(context),
      header: Text(L10n.text('Folders')),
      children: [
        Semantics(
          identifier: 'booru.folderStyle',
          child: SettingsPickerRow<BooruFolderStyle>(
            title: L10n.text('Folder Style'),
            help: L10n.text(
              "Each Server's Own Folders: a folder holds one server's images and shows when that server is chosen; new folders belong to the server you're browsing. Folders Shared by All Servers: folders hold images from any server, as before.",
            ),
            options: [for (final style in BooruFolderStyle.values) (style, L10n.text(style.title))],
            selected: store.folderStyle,
            onSelected: (style) => _change(context, style),
          ),
        ),
      ],
    ),
  );
}

/// `BooruFolderStyleSheet`: asked once of a library from before server folders: give each server
/// its own folders, or keep the folders shared as they were. Nothing changes until one is chosen;
/// closing it asks again later.
class BooruFolderStyleSheet extends StatelessWidget {
  const BooruFolderStyleSheet({super.key, required this.impact, required this.controller});
  final ({int folders, int mixed}) impact;
  final ScrollController controller;

  static Future<BooruFolderStyle?> show(BuildContext context, BooruStore store) => showAppSheet<BooruFolderStyle>(
    context,
    builder: (context, controller) => BooruFolderStyleSheet(impact: store.folderStyleImpact(), controller: controller),
  );

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return ScrollEdgeSheet(
      bar: SheetNavigationBar(title: L10n.text('Image Folders')),
      child: ListView(
        controller: controller,
        padding: EdgeInsets.only(top: 76 + 4, bottom: 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Text(
              L10n.text(
                'Image folders can now belong to a server, so each server shows only its own folders. Choose how your folders work; you can change it later in Library Management.',
              ),
              style: TegnalType.style(15, color: secondary),
            ),
          ),
          FormSection(
            children: [_choice(context, BooruFolderStyle.byServer, CupertinoIcons.rectangle_stack, booruFolderStyleEffect(BooruFolderStyle.byServer, impact))],
          ),
          const SizedBox(height: 24),
          FormSection(
            children: [
              _choice(
                context,
                BooruFolderStyle.shared,
                CupertinoIcons.folder,
                L10n.text('Folders stay exactly as they are and hold images from any server. New folders are shared too.'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _choice(BuildContext context, BooruFolderStyle style, IconData icon, String detail) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return Semantics(
      identifier: 'booru.folderStyle.${style.name}',
      button: true,
      child: FormRow(
        separatorInset: 52,
        onTap: () => Navigator.of(context).pop(style),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 24, child: Icon(icon, size: 20, color: TegnalColors.tint.resolveFrom(context))),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      L10n.text(style.title),
                      style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                    ),
                    const SizedBox(height: 4),
                    Text(detail, style: TegnalType.style(13, color: secondary)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `BooruFolderStyleGate`: shows [BooruFolderStyleSheet] in image mode while a library from before
/// server folders waits for a choice, never over the home scene.
class BooruFolderStyleGate extends StatefulWidget {
  const BooruFolderStyleGate({super.key, required this.store, required this.state, required this.child});
  final BooruStore store;
  final AppState state;
  final Widget child;

  @override
  State<BooruFolderStyleGate> createState() => _BooruFolderStyleGateState();
}

class _BooruFolderStyleGateState extends State<BooruFolderStyleGate> {
  bool _asking = false;

  /// Closed without a choice, it waits until image mode is opened again.
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_check);
    widget.store.addListener(_check);
    HomeStage.shared.addListener(_check);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    widget.state.removeListener(_check);
    widget.store.removeListener(_check);
    HomeStage.shared.removeListener(_check);
    super.dispose();
  }

  Future<void> _check() async {
    if (widget.state.mode != AppMode.booru) _closed = false;
    if (!mounted || _asking || _closed || widget.state.mode != AppMode.booru || !widget.store.folderStylePending || HomeStage.shared.coversScreen) return;
    _asking = true;
    final style = await BooruFolderStyleSheet.show(context, widget.store);
    _asking = false;
    if (style == null) {
      _closed = true;
      return;
    }
    try {
      widget.store.adoptFolderStyle(style, kept: booruListFolderIDs(widget.store, BooruAccountSync.shared));
    } on Object catch (error) {
      if (mounted) _showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
