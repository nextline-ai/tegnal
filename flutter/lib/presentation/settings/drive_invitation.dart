import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/booru/booru_store.dart';
import '../../core/downloads/download_store.dart' show FileByteCount;
import '../../core/storage/app_database.dart';
import '../../core/support/l10n.dart';
import '../../core/sync/library_drive_sync.dart';
import '../design/alert_dialog.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';

/// What the library holds now, so an earlier install sees what Google Drive would keep safe
/// (`CloudSyncFootprint`).
class DriveFootprint {
  const DriveFootprint({this.works = 0, this.comicFolders = 0, this.images = 0, this.imageFolders = 0});
  final int works;
  final int comicFolders;
  final int images;
  final int imageFolders;

  factory DriveFootprint.of({required AppDatabase database, required BooruStore images}) => DriveFootprint(
    works: database.worksCount(),
    comicFolders: database.listFolders().length,
    images: images.favoriteIDs.length,
    imageFolders: images.folders().length,
  );

  bool get isEmpty => works + comicFolders + images + imageFolders == 0;
}

/// Why to connect Google Drive, in the iCloud sync screen's cards (`CloudSyncTurnOffView`) turned
/// around: what Drive keeps safe, how little room it takes, and that it sees only its own folder.
/// Onboarding's Drive page and the one-time invitation both show it.
class DriveInvitationContent extends StatelessWidget {
  const DriveInvitationContent({super.key, this.footprint, this.connectedEmail});

  /// The library's size now; an earlier install sees it, a first run has nothing yet.
  final DriveFootprint? footprint;

  /// Shown in place of the pitch's closing note once an account is connected.
  final String? connectedEmail;

  /// A 2,000-bookmark library syncs in about 5 MB; every Google account has 15 GB for free.
  static const sampleBookmarks = 2000;
  static const sampleBytes = 5000000;
  static const freeDriveBytes = 15000000000;

  static const green = CupertinoColors.systemGreen;

  @override
  Widget build(BuildContext context) {
    final label = TegnalColors.label.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final footprint = this.footprint;
    return Column(
      key: const Key('drive.invitation'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _badge(context, CupertinoIcons.cloud_upload_fill, TegnalColors.tint, size: 64, icon: 34),
        const SizedBox(height: 20),
        Text(
          L10n.text('Keep Your Library Safe in Google Drive'),
          style: TegnalType.style(30, weight: FontWeight.w700, color: label),
        ),
        const SizedBox(height: 12),
        Text(
          L10n.text('Without it, your library lives only on this phone. Sign in once and TEGNAL keeps it in your Google Drive.'),
          style: TegnalType.style(17, color: secondary),
        ),
        const SizedBox(height: 24),
        if (footprint != null && !footprint.isEmpty) ...[_footprintCard(context, footprint), const SizedBox(height: 16)],
        _card(
          context,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              _row(
                context,
                CupertinoIcons.cloud_upload_fill,
                CupertinoColors.systemGreen,
                'Your Library Is Backed Up',
                'Bookmarks, image favorites, folders and notes go to your Google Drive as you save them.',
              ),
              _divider(context),
              _row(
                context,
                CupertinoIcons.arrow_counterclockwise,
                CupertinoColors.systemBlue,
                'It Comes Back After Reinstalling',
                'If TEGNAL is deleted, or this phone is lost, reset or replaced, sign in again and your library returns.',
              ),
              _divider(context),
              _row(
                context,
                CupertinoIcons.device_phone_portrait,
                CupertinoColors.systemOrange,
                'Your Android Devices Stay in Step',
                'Saves, folders and settings on one device reach your other Android devices.',
              ),
              _divider(context),
              _row(
                context,
                CupertinoIcons.clock_fill,
                CupertinoColors.systemPurple,
                'Automatic Backups Are Kept There Too',
                'The backup made before each update is also copied to Google Drive.',
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _storageCard(context),
        const SizedBox(height: 16),
        _card(
          context,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _row(
            context,
            CupertinoIcons.lock_fill,
            CupertinoColors.systemGrey,
            'Only Its Own Folder',
            'TEGNAL can see only the files it creates in a TEGNAL folder. Your other Google Drive files stay private.',
          ),
        ),
        if (connectedEmail case final email?) ...[
          const SizedBox(height: 16),
          Row(
            key: const Key('drive.invitation.connected'),
            children: [
              const Icon(CupertinoIcons.checkmark_circle_fill, size: 20, color: green),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  L10n.text('Connected as %@', [email]),
                  style: TegnalType.style(15, weight: FontWeight.w600, color: label),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  static Widget _card(BuildContext context, {required Widget child, EdgeInsets padding = const EdgeInsets.all(18), Color? border}) => Container(
    width: double.infinity,
    padding: padding,
    decoration: ShapeDecoration(
      color: FormColors.row.resolveFrom(context),
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(20),
        side: border == null ? BorderSide.none : BorderSide(color: border),
      ),
    ),
    child: child,
  );

  static Widget _badge(BuildContext context, IconData symbol, Color tint, {double size = 30, double icon = 17}) {
    final color = tint is CupertinoDynamicColor ? tint.resolveFrom(context) : tint;
    return Container(
      width: size,
      height: size,
      decoration: ShapeDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color.lerp(color, const Color(0xFFFFFFFF), 0.15)!, color]),
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(size * 0.27)),
      ),
      child: Icon(symbol, size: icon, color: const Color(0xFFFFFFFF)),
    );
  }

  static Widget _divider(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 58),
    child: Container(height: 0.5, color: TegnalColors.separator.resolveFrom(context)),
  );

  static Widget _row(BuildContext context, IconData symbol, Color tint, String title, String detail) => Semantics(
    container: true,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _badge(context, symbol, tint),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  L10n.text(title),
                  style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                ),
                const SizedBox(height: 4),
                Text(L10n.text(detail), style: TegnalType.style(15, color: TegnalColors.secondaryLabel.resolveFrom(context))),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  /// Answers the storage worry up front: the bar is the free 15 GB, and the library is a sliver.
  Widget _storageCard(BuildContext context) {
    final language = L10n.language;
    final share = sampleBytes / freeDriveBytes;
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final free = FileByteCount.format(freeDriveBytes, language: language);
    final percent = '${(share * 100).toStringAsFixed(2)}%';
    return _card(
      context,
      border: green.withValues(alpha: 0.35),
      child: Column(
        key: const Key('drive.invitation.storage'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _badge(context, CupertinoIcons.cloud_fill, green),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  L10n.text('Uses Almost No Google Drive Storage'),
                  style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: 8,
            children: [
              Text(
                L10n.text('Approximately %@', [FileByteCount.format(sampleBytes, language: language)]),
                style: TegnalType.style(32, weight: FontWeight.w700, color: green),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Text(
                  L10n.text('for %@ bookmarks', [_grouped(sampleBookmarks)]),
                  style: TegnalType.style(15, weight: FontWeight.w600, color: secondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) => Stack(
              children: [
                Container(
                  height: 10,
                  decoration: ShapeDecoration(color: secondary.withValues(alpha: 0.2), shape: const StadiumBorder()),
                ),
                Container(
                  height: 10,
                  width: (constraints.maxWidth * share).clamp(5, constraints.maxWidth),
                  decoration: const ShapeDecoration(color: green, shape: StadiumBorder()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  L10n.text('About %@ of the free %@', [percent, free]),
                  style: TegnalType.style(12, weight: FontWeight.w600, color: green),
                ),
              ),
              Text(
                free,
                style: TegnalType.style(12, weight: FontWeight.w600, color: secondary),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            L10n.text('Every Google account comes with 15 GB of storage for free. Syncing your library barely touches it.'),
            style: TegnalType.style(15, color: secondary),
          ),
        ],
      ),
    );
  }

  static String _grouped(int value) => value.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

  Widget _footprintCard(BuildContext context, DriveFootprint footprint) {
    final label = TegnalColors.label.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    Widget tile(int count, String title, IconData symbol) => Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: ShapeDecoration(
          color: FormColors.background.resolveFrom(context),
          shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(symbol, size: 15, color: tint),
            const SizedBox(height: 4),
            Text(
              _grouped(count),
              style: TegnalType.style(22, weight: FontWeight.w700, color: label),
            ),
            Text(
              L10n.text(title),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TegnalType.style(12, color: secondary),
            ),
          ],
        ),
      ),
    );
    return _card(
      context,
      child: Column(
        key: const Key('drive.invitation.footprint'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            L10n.text('What Google Drive Would Protect'),
            style: TegnalType.style(17, weight: FontWeight.w600, color: label),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              tile(footprint.works, 'Saved Works', CupertinoIcons.book_fill),
              const SizedBox(width: 12),
              tile(footprint.comicFolders, 'Comics Folders', CupertinoIcons.folder_fill),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              tile(footprint.images, 'Saved Images', CupertinoIcons.photo_fill),
              const SizedBox(width: 12),
              tile(footprint.imageFolders, 'Image Folders', CupertinoIcons.folder_fill),
            ],
          ),
        ],
      ),
    );
  }
}

/// The bottom of a Drive invitation: one prominent way to connect, and a quiet line to skip, as the
/// iCloud screen keeps its way on small and at the end.
class DriveInvitationBar extends StatelessWidget {
  const DriveInvitationBar({super.key, required this.primary, required this.onPrimary, this.busy = false, this.skip, this.onSkip, this.footer});
  final String primary;
  final VoidCallback? onPrimary;
  final bool busy;
  final String? skip;
  final VoidCallback? onSkip;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: primary,
          excludeSemantics: true,
          child: GestureDetector(
            key: const Key('drive.invitation.primary'),
            behavior: HitTestBehavior.opaque,
            onTap: busy ? null : onPrimary,
            child: Container(
              height: 69,
              alignment: Alignment.center,
              decoration: ShapeDecoration(color: tint, shape: const StadiumBorder()),
              child: busy
                  ? const CupertinoActivityIndicator(color: Color(0xFFFFFFFF))
                  : Text(
                      primary,
                      style: TegnalType.style(17, weight: FontWeight.w600, color: const Color(0xFFFFFFFF)),
                    ),
            ),
          ),
        ),
        if (skip case final skip?)
          Semantics(
            button: true,
            label: skip,
            excludeSemantics: true,
            child: GestureDetector(
              key: const Key('drive.invitation.skip'),
              behavior: HitTestBehavior.opaque,
              onTap: busy ? null : onSkip,
              child: Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 2),
                child: Text(skip, style: TegnalType.style(13, color: secondary)),
              ),
            ),
          ),
        ?footer,
      ],
    );
  }
}

/// The one-time invitation for an install that finished onboarding without Google Drive: the
/// same cards over a full page, connecting from its main button.
class DriveInvitationPage extends StatefulWidget {
  const DriveInvitationPage({super.key, required this.sync, this.footprint});
  final LibraryDriveSync sync;
  final DriveFootprint? footprint;

  static Future<void> show(BuildContext context, {required LibraryDriveSync sync, DriveFootprint? footprint}) =>
      Navigator.of(context, rootNavigator: true).push(
        CupertinoPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => DriveInvitationPage(sync: sync, footprint: footprint),
        ),
      );

  @override
  State<DriveInvitationPage> createState() => _DriveInvitationPageState();
}

class _DriveInvitationPageState extends State<DriveInvitationPage> {
  bool _connecting = false;

  Future<void> _connect() async {
    setState(() => _connecting = true);
    final error = await widget.sync.connect();
    if (!mounted) return;
    setState(() => _connecting = false);
    if (error == null) {
      if (widget.sync.account != null) Navigator.of(context).pop();
      return;
    }
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
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return CupertinoPageScaffold(
      backgroundColor: FormColors.background.resolveFrom(context),
      child: Stack(
        children: [
          Positioned.fill(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(24, media.padding.top + 32, 24, 24 + 69 + 40 + media.padding.bottom),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: DriveInvitationContent(footprint: widget.footprint),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: EdgeInsets.fromLTRB(24, 12, 24, 12 + media.padding.bottom),
              color: FormColors.row.resolveFrom(context).withValues(alpha: 0.94),
              child: DriveInvitationBar(
                primary: L10n.text('Connect Google Drive'),
                onPrimary: _connect,
                busy: _connecting,
                skip: L10n.text('Not Now'),
                onSkip: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
