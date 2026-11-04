import 'dart:io';
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/rendering.dart';

import '../../../core/support/document_files.dart';
import '../../../core/support/l10n.dart';
import '../../../core/taste/recap_shelf.dart';
import '../../../core/taste/taste_models.dart';
import '../../../core/taste/taste_recap.dart';
import '../../design/grouped_form.dart';
import '../../design/ios_controls.dart';
import '../../design/tegnal_theme.dart';
import '../../library/library_routes.dart' show showTransientMessage;
import '../taste_context.dart';
import 'recap_artwork.dart';
import 'recap_cover.dart';
import 'recap_cover_art.dart';
import 'recap_style.dart';

enum _ShareFormat {
  story(Size(360, 640)),
  square(Size(360, 360));

  const _ShareFormat(this.size);
  final Size size;
}

/// `RecapShareView`: a share card never carries saved works. The cover is drawn, and
/// tags stay off until the person turns them on.
class RecapShareView extends StatefulWidget {
  const RecapShareView({super.key, required this.recap, required this.palette});
  final TasteRecap recap;
  final RecapPalette palette;

  @override
  State<RecapShareView> createState() => _RecapShareViewState();
}

class _RecapShareViewState extends State<RecapShareView> {
  final _poster = GlobalKey();
  _ShareFormat _format = _ShareFormat.story;
  bool _showsTags = false;
  bool _saving = false;

  /// Saves the card as a PNG wherever the person chooses, at three times its size.
  Future<void> _save() async {
    final boundary = _poster.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null || _saving) return;
    setState(() => _saving = true);
    try {
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data != null) {
        final file = File('${Directory.systemTemp.path}/tegnal-recap.png');
        await file.writeAsBytes(data.buffer.asUint8List());
        await const DocumentFiles().createDocument(name: 'TEGNAL Recap.png', source: file, mimeType: 'image/png');
      }
    } on Object catch (error) {
      if (mounted) showTransientMessage(context, '$error');
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final size = _format.size;
    final poster = RepaintBoundary(
      key: _poster,
      child: SizedBox.fromSize(
        size: size,
        child: Stack(
          children: [
            Positioned.fill(
              child: RecapCoverLayout(
                recap: widget.recap,
                palette: widget.palette,
                showsTags: _showsTags,
                background: RecapCoverArt(palette: widget.palette, seed: widget.recap.coverSeed),
              ),
            ),
            Positioned(
              right: 18,
              bottom: 18,
              child: Text(
                'TEGNAL',
                style: RecapType.display(13, weight: FontWeight.w800, color: const Color(0xE6FFFFFF), letterSpacing: 1),
              ),
            ),
          ],
        ),
      ),
    );
    return ScrollEdgeSheet(
      bar: SheetNavigationBar(
        title: L10n.text('Share cover'),
        leading: GlassTextButton(label: L10n.text('Close'), onPressed: () => Navigator.of(context).pop()),
        trailing: GlassTextButton(label: L10n.text('Share'), prominent: true, onPressed: _saving ? null : _save),
      ),
      child: ListView(
        padding: EdgeInsets.only(top: 69 + 16, bottom: 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          Semantics(
            label: L10n.text('Share card preview'),
            child: Center(
              child: SizedBox(
                height: 380,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: FittedBox(child: poster),
                ),
              ),
            ),
          ),
          const SizedBox(height: 28),
          FormSection(
            footer: Text(L10n.text('Share cards never include your saved works.')),
            children: [
              FormRow(
                child: TegnalSegmented<_ShareFormat>(
                  options: [(_ShareFormat.story, L10n.text('Story')), (_ShareFormat.square, L10n.text('Square'))],
                  selected: _format,
                  onSelected: (value) => setState(() => _format = value),
                ),
              ),
              FormRow(
                child: Row(
                  children: [
                    Expanded(child: Text(L10n.text('Show top tags'))),
                    TegnalSwitch(value: _showsTags, onChanged: (value) => setState(() => _showsTags = value)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// `RecapWorksView`: the period's saves as a browsable shelf, with a way to keep them together.
class RecapWorksView extends StatefulWidget {
  const RecapWorksView({super.key, required this.taste, required this.recap, required this.palette, required this.open});
  final TasteContext taste;
  final TasteRecap recap;
  final RecapPalette palette;
  final void Function(RecapWork work) open;

  @override
  State<RecapWorksView> createState() => _RecapWorksViewState();
}

class _RecapWorksViewState extends State<RecapWorksView> {
  TasteRecap get _recap => widget.recap;
  String get _folderName => L10n.text('%@ Recap', [RecapFormat.title(_recap)]);

  Future<void> _confirm() async {
    final create = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(L10n.text('Make a folder')),
        message: Text(
          L10n.text(
            _recap.mode == TasteMode.booru
                ? 'Images keep one folder each, so these %@ images will move into the new folder.'
                : 'These %@ works will also appear in the new folder.',
            ['${_recap.saved.length}'],
          ),
        ),
        actions: [
          CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Create “%@”', [_folderName]))),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (create == true) _collect();
  }

  void _collect() {
    final taste = widget.taste;
    try {
      if (_recap.mode == TasteMode.comics) {
        final database = taste.booru.database;
        final id = database.createFolder(name: _folderName).id;
        if (id == null) return;
        for (final work in _recap.saved) {
          final row = database.getWork(work.item.id)?.id;
          if (row != null) database.addWorkToFolder(row, id);
        }
      } else {
        final store = taste.booru.store;
        final id = store.saveFolder(name: _folderName);
        final artwork = RecapScope.of(context).artwork;
        for (final work in _recap.saved) {
          final post = artwork.post(work);
          if (post != null) store.saveFavorite(post, folderID: id);
        }
      }
      showTransientMessage(context, L10n.text('Folder created'));
    } on Object {
      showTransientMessage(context, L10n.text('Unable to create the folder'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    final bottom = MediaQuery.paddingOf(context).bottom;
    return ScrollEdgeSheet(
      bar: SheetNavigationBar(
        title: RecapFormat.title(_recap),
        trailing: GlassTextButton(label: L10n.text('Done'), prominent: true, onPressed: () => Navigator.of(context).pop()),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final columns = ((constraints.maxWidth - 4) / (108 + 4)).floor().clamp(1, 12);
                return GridView.builder(
                  padding: EdgeInsets.fromLTRB(4, 69 + 4, 4, 64 + bottom),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 4,
                    crossAxisSpacing: 4,
                    childAspectRatio: 0.74,
                  ),
                  itemCount: _recap.saved.length,
                  itemBuilder: (context, index) {
                    final work = _recap.saved[index];
                    return GestureDetector(
                      onTap: () => widget.open(work),
                      child: Semantics(
                        button: true,
                        label: work.info.title ?? L10n.text('Open'),
                        child: RecapArtTile(work: work, palette: widget.palette, generated: _recap.isSample),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottom),
              color: TegnalColors.secondaryBackground.resolveFrom(context).withValues(alpha: 0.92),
              child: GestureDetector(
                onTap: _recap.isSample ? null : _confirm,
                child: Opacity(
                  opacity: _recap.isSample ? 0.4 : 1,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(CupertinoIcons.folder_badge_plus, size: 20, color: tint),
                      const SizedBox(width: 6),
                      Text(L10n.text('Make a folder'), style: TegnalType.style(17, color: tint)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
