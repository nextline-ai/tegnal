import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/content/site_fallback_content.dart';
import '../../core/support/l10n.dart';
import '../content/page_image_store.dart';
import '../design/alert_dialog.dart';
import '../design/grouped_form.dart';
import 'settings_page.dart';
import 'settings_rows.dart';

/// `ComicsCacheSettingsView`: how much room comics pages take on this device, how much they may
/// take, and which works open from another connected website.
class ComicsCacheSettingsView extends StatefulWidget {
  const ComicsCacheSettingsView({super.key});

  @override
  State<ComicsCacheSettingsView> createState() => _ComicsCacheSettingsViewState();
}

class _ComicsCacheSettingsViewState extends State<ComicsCacheSettingsView> {
  int _megabytes = ComicsPageCache.configuredMegabytes;

  /// Byte sizes in the memory style iOS uses for this screen: 512 MB, 1 GB.
  static String size(int bytes) {
    const units = ['bytes', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit += 1;
    }
    if (unit == 0) return bytes == 0 ? 'Zero KB' : '$bytes bytes';
    final text = value >= 100 || value == value.roundToDouble() ? value.round().toString() : value.toStringAsFixed(1);
    return '$text ${units[unit]}';
  }

  Future<void> _confirmClear() async {
    final clear = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('Clear Image Cache?')),
        content: Text(L10n.text('Saved works are kept. Images will be downloaded again when needed.')),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Clear Image Cache'))),
        ],
      ),
    );
    if (clear != true || !mounted) return;
    setState(ComicsPageCache.clear);
  }

  Future<void> _confirmForget() async {
    final forget = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(L10n.text('Forget Deleted Works')),
        actions: [CupertinoActionSheetAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Forget')))],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (forget != true || !mounted) return;
    setState(WorkSiteMemory.shared.removeAll);
  }

  @override
  Widget build(BuildContext context) {
    final row = FormColors.listRow.resolveFrom(context);
    final remembered = WorkSiteMemory.shared.count;
    return SettingsPage(
      title: L10n.text('Image Cache'),
      children: [
        FormSection(
          prominentHeader: true,
          rowColor: row,
          header: Text(L10n.text('Viewer and Preview Images')),
          footer: Text(
            L10n.text(
              'Pages and previews you’ve viewed are kept so they open without downloading again. When the cache is full, the least recently viewed images are removed first. Saved works and their covers are not affected.',
            ),
          ),
          children: [
            SettingsValueRow(title: L10n.text('In Use'), value: size(ComicsPageCache.usedBytes)),
            SettingsPickerRow<int>(
              title: L10n.text('Maximum Size'),
              options: [for (final value in ComicsPageCache.choices) (value, size(value * 1024 * 1024))],
              selected: _megabytes,
              onSelected: (value) => setState(() {
                _megabytes = value;
                ComicsPageCache.setMegabytes(value);
              }),
            ),
            SettingsLinkRow(title: L10n.text('Clear Image Cache'), destructive: true, chevron: false, onTap: _confirmClear),
          ],
        ),
        settingsSectionGap,
        FormSection(
          prominentHeader: true,
          rowColor: row,
          header: Text(L10n.text('Other Websites')),
          footer: Text(
            L10n.text(
              'Works always open from the checked website first. When it no longer has a work, the app opens it from another connected website and remembers that the checked website deleted it. Forgetting this asks every website again.',
            ),
          ),
          children: [
            SettingsValueRow(title: L10n.text('Works Deleted on a Website'), value: '$remembered'),
            SettingsLinkRow(title: L10n.text('Forget Deleted Works'), tinted: true, chevron: false, onTap: remembered == 0 ? null : _confirmForget),
          ],
        ),
      ],
    );
  }
}
