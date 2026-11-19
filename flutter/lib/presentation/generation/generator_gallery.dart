import 'dart:async';
import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/generation/generation_client.dart' show GenerationModel;
import '../../core/generation/generation_store.dart';
import '../../core/support/app_platform.dart';
import '../../core/support/document_files.dart';
import '../../core/support/l10n.dart';
import '../../core/support/privacy_settings.dart';
import '../design/grouped_form.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import '../library/library_routes.dart' show showTransientMessage;
import '../settings/settings_page.dart';
import '../study/study_widgets.dart' show StudyActionRow, StudySelectable, StudyStyle;
import 'generator_sheet.dart';

/// Generated pictures side by side (`GeneratedGrid`).
class GeneratedGrid extends StatelessWidget {
  const GeneratedGrid({super.key, required this.pictures, required this.store, required this.open});
  final List<GeneratedPicture> pictures;
  final GenerationStore store;
  final void Function(GeneratedPicture picture) open;

  static const _spacing = 10.0;
  static const _minimum = 150.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = ((constraints.maxWidth + _spacing) / (_minimum + _spacing)).floor().clamp(1, 8);
      final width = (constraints.maxWidth - _spacing * (columns - 1)) / columns;
      return Wrap(
        spacing: _spacing,
        runSpacing: _spacing,
        children: [for (final (index, picture) in pictures.indexed) SizedBox(width: width, child: _tile(context, index, picture))],
      );
    },
  );

  Widget _tile(BuildContext context, int index, GeneratedPicture picture) => Semantics(
    button: true,
    label: L10n.text('Generated Picture'),
    excludeSemantics: true,
    child: GestureDetector(
      key: Key('generator.result.$index'),
      behavior: HitTestBehavior.opaque,
      onTap: () => open(picture),
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(12),
        child: AspectRatio(
          aspectRatio: picture.width.clamp(1, 1 << 30) / picture.height.clamp(1, 1 << 30),
          child: ColoredBox(
            color: StudyStyle.tertiaryFill.resolveFrom(context),
            child: Image.file(store.file(picture), fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (context, error, stack) => const SizedBox()),
          ),
        ),
      ),
    ),
  );
}

/// Every picture made on this device (`GeneratedGalleryView`).
class GeneratedGalleryView extends StatefulWidget {
  const GeneratedGalleryView({super.key, required this.environment});
  final GeneratorEnvironment environment;

  @override
  State<GeneratedGalleryView> createState() => _GeneratedGalleryViewState();
}

class _GeneratedGalleryViewState extends State<GeneratedGalleryView> {
  GenerationStore get _store => widget.environment.store;

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

  @override
  Widget build(BuildContext context) => SettingsPage(
    title: L10n.text('Generated Pictures'),
    children: [
      const SizedBox(height: 16),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: GeneratedGrid(
          pictures: _store.pictures,
          store: _store,
          open: (picture) =>
              showGeneratorSheet<void>(context, (context) => GeneratedPictureView(environment: widget.environment, picture: picture, removed: () {})),
        ),
      ),
    ],
  );
}

/// One generated picture with what it was made from (`GeneratedPictureView`).
class GeneratedPictureView extends StatefulWidget {
  const GeneratedPictureView({super.key, required this.environment, required this.picture, required this.removed});
  final GeneratorEnvironment environment;
  final GeneratedPicture picture;
  final VoidCallback removed;

  @override
  State<GeneratedPictureView> createState() => _GeneratedPictureViewState();
}

class _GeneratedPictureViewState extends State<GeneratedPictureView> {
  bool _copied = false;
  Timer? _copiedTimer;

  GenerationStore get _store => widget.environment.store;
  GeneratedPicture get _picture => widget.picture;

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  /// The system share sheet, as `ShareLink` opens it; a computer saves the file where the person chooses.
  Future<void> _share() async {
    try {
      final source = _store.file(_picture);
      final folder = Directory('${(await getApplicationCacheDirectory()).path}/shared');
      await folder.create(recursive: true);
      final extension = _picture.file.split('.').last;
      final copy = await source.copy('${folder.path}/TEGNAL Generated.$extension');
      if (AppPlatform.isDesktop) {
        await const DocumentFiles().createDocument(
          name: 'TEGNAL Generated.$extension',
          source: copy,
          mimeType: extension == 'jpg' ? 'image/jpeg' : 'image/$extension',
        );
      } else {
        await AppAway.run(
          () =>
              const MethodChannel('work.nextline.tegnal/screen').invokeMethod<void>('shareImage', {'path': copy.path, 'title': L10n.text('Generated Picture')}),
        );
      }
    } on Object catch (error) {
      if (mounted) showTransientMessage(context, '$error');
    }
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: _picture.prompt));
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  void _useSettings() {
    final store = _store;
    var settings = store.settings.copyWith(
      negative: _picture.negative,
      width: _picture.width,
      height: _picture.height,
      steps: _picture.steps,
      guidance: _picture.guidance,
      seed: _picture.seed,
      clearSeed: _picture.seed == null,
    );
    if (_picture.model.isNotEmpty) {
      settings = settings.use(GenerationModel(air: _picture.model, name: _picture.modelName.isEmpty ? _picture.model : _picture.modelName));
    }
    store.settings = settings;
    Navigator.of(context).pop();
  }

  Future<void> _confirmDelete() async {
    final delete = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(L10n.text('Delete this picture?')),
        actions: [
          CupertinoActionSheetAction(
            key: const Key('generator.confirmDelete'),
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: Text(L10n.text('Delete')),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (delete != true || !mounted) return;
    _store.delete(_picture);
    widget.removed();
    Navigator.of(context).pop();
  }

  static String _date(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  Widget _detail(BuildContext context, String title, String value) => FormRow(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: TegnalType.style(15, color: TegnalColors.label.resolveFrom(context))),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: TegnalType.style(15, color: TegnalColors.secondaryLabel.resolveFrom(context)),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final rowColor = FormColors.row.resolveFrom(context);
    final picture = _picture;
    return GeneratorSheetPage(
      title: _date(picture.date),
      leading: GlassTextButton(key: const Key('generator.close'), label: L10n.text('Close'), onPressed: () => Navigator.of(context).pop()),
      children: [
        FormSection(
          rowColor: rowColor,
          children: [
            Image.file(
              _store.file(picture),
              key: const Key('generator.picture'),
              fit: BoxFit.fitWidth,
              width: double.infinity,
              errorBuilder: (context, error, stack) => AspectRatio(aspectRatio: picture.width / picture.height, child: const SizedBox()),
            ),
          ],
        ),
        settingsSectionGap,
        FormSection(
          rowColor: rowColor,
          children: [
            StudyActionRow(key: const Key('generator.share'), title: L10n.text('Share or Save'), icon: CupertinoIcons.share_up, onTap: _share),
            StudyActionRow(
              key: const Key('generator.copy'),
              title: L10n.text(_copied ? 'Copied' : 'Copy Prompt'),
              icon: _copied ? CupertinoIcons.checkmark : CupertinoIcons.doc_on_doc,
              onTap: _copy,
            ),
            StudyActionRow(
              key: const Key('generator.useSettings'),
              title: L10n.text('Use These Settings'),
              icon: CupertinoIcons.slider_horizontal_3,
              onTap: _useSettings,
            ),
          ],
        ),
        settingsSectionGap,
        FormSection(
          prominentHeader: true,
          rowColor: rowColor,
          header: Text(L10n.text('Prompt')),
          children: [
            FormRow(
              child: SizedBox(
                width: double.infinity,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: StudySelectable(
                    child: Text(picture.prompt, key: const Key('generator.promptText'), style: generatorMonospace(context)),
                  ),
                ),
              ),
            ),
          ],
        ),
        settingsSectionGap,
        FormSection(
          rowColor: rowColor,
          children: [
            _detail(context, L10n.text('Model'), picture.modelName.isEmpty ? picture.model : picture.modelName),
            _detail(context, L10n.text('Size'), '${picture.width} × ${picture.height}'),
            _detail(context, L10n.text('Steps'), '${picture.steps}'),
            _detail(context, L10n.text('Guidance (CFG)'), picture.guidance.toStringAsFixed(1)),
            if (picture.seed != null) _detail(context, L10n.text('Seed'), '${picture.seed}'),
          ],
        ),
        settingsSectionGap,
        FormSection(
          rowColor: rowColor,
          children: [
            FormRow(
              key: const Key('generator.delete'),
              onTap: _confirmDelete,
              child: Text(L10n.text('Delete'), style: TegnalType.style(17, color: SystemColors.red.resolveFrom(context))),
            ),
          ],
        ),
      ],
    );
  }
}
