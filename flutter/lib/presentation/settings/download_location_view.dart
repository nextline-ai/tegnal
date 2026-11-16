import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../core/downloads/download_store.dart';
import '../../core/support/document_files.dart';
import '../../core/support/l10n.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';
import 'settings_page.dart';
import 'settings_rows.dart';
import '../../core/support/app_platform.dart';

/// `DownloadSettingsView`: where downloads are saved, and moving the ones saved elsewhere, such
/// as in the app's own storage where versions before 1.5.2 kept them, without downloading them again.
class DownloadLocationView extends StatefulWidget {
  const DownloadLocationView({super.key, required this.store, this.files = const DocumentFiles()});
  final DownloadStore store;
  final DocumentFiles files;

  /// The device folder's title; a chosen folder shows its own name.
  static String title(DownloadLocation location) => location.isFiles ? L10n.text('On This Device') : location.name;

  @override
  State<DownloadLocationView> createState() => _DownloadLocationViewState();
}

class _DownloadLocationViewState extends State<DownloadLocationView> {
  DownloadStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    _store.addListener(_changed);
  }

  @override
  void dispose() {
    _store.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _choose() async {
    try {
      final folder = await widget.files.pickFolder();
      if (folder != null) _store.addFolder(folder.path, folder.name);
    } on PlatformException {
      _store.refuseFolder();
    }
  }

  /// Where a location sits on the device, shorter than its full path.
  String _subtitle(DownloadLocation location) {
    final root = _store.root(location.id);
    if (root == null) return L10n.text('Folder you chose');
    var path = root.path;
    for (final prefix in ['/storage/emulated/0/', '/sdcard/']) {
      if (path.startsWith(prefix)) path = path.substring(prefix.length);
    }
    return path.split(Platform.pathSeparator).where((part) => part.isNotEmpty).join(' › ');
  }

  Widget _location(DownloadLocation location) {
    final selected = _store.currentLocation.id == location.id;
    final tint = TegnalColors.tint.resolveFrom(context);
    final removable = !location.isFiles && !_store.items.any((item) => item.location == location.id);
    final row = FormRow(
      onTap: () => _store.setLocation(location.id),
      minHeight: 60,
      separatorInset: settingsIconInset,
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Center(child: Icon(location.isFiles ? CupertinoIcons.device_phone_portrait : CupertinoIcons.folder, size: 22, color: tint)),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(DownloadLocationView.title(location), style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context))),
                const SizedBox(height: 2),
                Text(
                  _subtitle(location),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TegnalType.style(12, color: TegnalColors.secondaryLabel.resolveFrom(context)),
                ),
              ],
            ),
          ),
          if (selected) Icon(CupertinoIcons.checkmark_alt, size: 20, color: tint),
        ],
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      customSemanticsActions: removable ? {CustomSemanticsAction(label: L10n.text('Remove')): () => _store.removeFolder(location.id)} : null,
      child: GestureDetector(onLongPress: removable ? () => _confirmRemove(location) : null, child: row),
    );
  }

  Future<void> _confirmRemove(DownloadLocation location) async {
    final remove = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(location.name),
        actions: [CupertinoActionSheetAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Remove')))],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (remove == true) _store.removeFolder(location.id);
  }

  @override
  Widget build(BuildContext context) {
    final rowColor = FormColors.listRow.resolveFrom(context);
    final movable = _store.movable;
    final moving = _store.moving;
    final error = _store.locationError;
    final red = CupertinoColors.systemRed.resolveFrom(context);
    return SettingsPage(
      title: L10n.text('Download Location'),
      children: [
        FormSection(
          prominentHeader: true,
          rowColor: rowColor,
          header: Text(L10n.text('Save Downloads To')),
          footer: Text(
            L10n.text(
              'Each work gets its own folder inside a Comics or Images folder, so the Files app and other apps can open it. A folder you choose must be on this device.',
            ),
          ),
          children: [
            for (final location in _store.locations) _location(location),
            SettingsLinkRow(title: L10n.text('Choose Folder…'), icon: CupertinoIcons.folder_badge_plus, tinted: true, chevron: false, onTap: _choose),
          ],
        ),
        if (!AppPlatform.isDesktop) ...[
          settingsSectionGap,
          FormSection(
            rowColor: rowColor,
            footer: Text(L10n.text('Downloaded images stay out of the photo gallery and other media apps. File managers still show them.')),
            children: [
              SettingsToggleRow(
                title: L10n.text('Hide from Gallery Apps'),
                value: _store.hidesFromGallery,
                onChanged: _store.setHidesFromGallery,
              ),
            ],
          ),
        ],
        settingsSectionGap,
        FormSection(
          prominentHeader: true,
          rowColor: rowColor,
          header: Text(L10n.text('Downloaded Files')),
          footer: Text(
            movable.isEmpty
                ? L10n.text('Every download is in the folder above.')
                : L10n.text(
                    "%@ downloads are saved elsewhere, such as in the app's own storage where earlier versions kept them. Moving them doesn't download them again.",
                    ['${movable.length}'],
                  ),
          ),
          children: [
            if (moving != null)
              FormRow(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: SizedBox(
                        height: 4,
                        child: Stack(
                          children: [
                            Container(color: TegnalColors.tertiaryLabel.resolveFrom(context)),
                            FractionallySizedBox(
                              widthFactor: moving.total == 0 ? 0 : moving.done / moving.total,
                              child: Container(color: TegnalColors.tint.resolveFrom(context)),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      L10n.text('Moving %@ of %@…', ['${moving.done + 1}', '${moving.total}']),
                      style: TegnalType.style(13, color: TegnalColors.secondaryLabel.resolveFrom(context)),
                    ),
                  ],
                ),
              )
            else
              SettingsLinkRow(
                title: L10n.text('Move to Selected Location'),
                icon: CupertinoIcons.tray_arrow_down,
                tinted: true,
                chevron: false,
                onTap: movable.isEmpty ? null : _store.moveElsewhereHere,
              ),
            if (error != null)
              FormRow(
                child: Text(error, style: TegnalType.style(13, color: red)),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
          child: Text(
            L10n.text('Keep the app open while downloading. Interrupted downloads can be resumed in Downloads.'),
            style: TegnalType.style(13, color: TegnalColors.secondaryLabel.resolveFrom(context)),
          ),
        ),
      ],
    );
  }
}
