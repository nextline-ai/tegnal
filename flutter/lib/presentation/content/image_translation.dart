import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/content/content_errors.dart';
import '../../core/support/l10n.dart';
import '../../core/support/preferences.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';
import '../settings/settings_page.dart';

/// One piece of translated text and where it sits, as fractions of the image.
class TranslatedRegion {
  const TranslatedRegion({
    required this.text,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    this.vertical = false,
    this.lines = 1,
  });
  final String text;
  final double left, top, width, height;

  /// How many lines or columns the original ran over; the label's text matches one of them.
  final int lines;

  /// The original ran in vertical columns, so the label sizes its text by width.
  final bool vertical;
}

/// On-device image translation (ML Kit): text recognition, language identification and
/// translation run on the phone. Translation models download from Google once per language pair.
abstract final class ImageTranslation {
  static const _channel = MethodChannel('work.nextline.tegnal/translation');

  /// Supported target languages with names in the app's language, sorted by name.
  static Future<List<(String, String)>> languages() async {
    try {
      final list = await _channel.invokeListMethod<Object?>('languages', {'display': L10n.language});
      final languages = [
        for (final item in list ?? const [])
          if (item is Map && item['code'] is String) (item['code'] as String, '${item['name'] ?? item['code']}'),
      ]..sort((a, b) => a.$2.toLowerCase().compareTo(b.$2.toLowerCase()));
      return languages;
    } on Object {
      return [];
    }
  }

  static Future<List<TranslatedRegion>> translate(Uint8List image, String target) async {
    final folder = Directory('${(await getApplicationCacheDirectory()).path}/translation');
    await folder.create(recursive: true);
    final file = File('${folder.path}/page');
    await file.writeAsBytes(image, flush: true);
    try {
      final result = await _channel.invokeMapMethod<Object?, Object?>('translate', {'path': file.path, 'target': target});
      return [
        for (final item in (result?['regions'] as List?) ?? const [])
          if (item is Map && item['text'] is String)
            TranslatedRegion(
              text: item['text'] as String,
              left: (item['left'] as num).toDouble(),
              top: (item['top'] as num).toDouble(),
              width: (item['width'] as num).toDouble(),
              height: (item['height'] as num).toDouble(),
              vertical: item['vertical'] == true,
              lines: math.max(1, (item['lines'] as num?)?.toInt() ?? 1),
            ),
      ];
    } on PlatformException catch (error) {
      throw TranslationError(switch (error.code) {
        'noText' => L10n.text('No text was found in this image.'),
        'alreadyTarget' => L10n.text('This image is already in the translation language.'),
        'download' => L10n.text('The translation model could not be downloaded. Check your connection and try again.'),
        'recognition' => L10n.text('This device does not support on-device text recognition.'),
        'unsupportedLanguage' => L10n.text('This translation language is not available.'),
        _ => L10n.text('Unable to translate this image.'),
      });
    } on MissingPluginException {
      throw TranslationError(L10n.text('This device does not support on-device text recognition.'));
    } finally {
      if (await file.exists()) await file.delete();
    }
  }
}

class TranslationError implements Exception {
  const TranslationError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// `ReaderTranslationLanguage`: the device language unless one is chosen; comics and image modes
/// keep separate choices.
abstract final class TranslationLanguage {
  static const key = 'reader.translationLanguage';
  static String preference(Preferences preferences) => preferences.string(key) ?? 'system';
  static String resolved(String value) {
    if (value != 'system') return value;
    final locale = WidgetsBinding.instance.platformDispatcher.locale;
    return locale.languageCode;
  }
}

/// `TranslationLanguageSettings`.
class TranslationLanguagePage extends StatefulWidget {
  const TranslationLanguagePage({super.key, required this.preferences});
  final Preferences preferences;

  @override
  State<TranslationLanguagePage> createState() => _TranslationLanguagePageState();
}

class _TranslationLanguagePageState extends State<TranslationLanguagePage> {
  List<(String, String)> _languages = [];

  @override
  void initState() {
    super.initState();
    ImageTranslation.languages().then((value) {
      if (mounted) setState(() => _languages = value);
    });
  }

  String get _selected => TranslationLanguage.preference(widget.preferences);

  Widget _option(String value, String title, {Widget? help}) => FormRow(
    onTap: () => setState(() => widget.preferences.set(TranslationLanguage.key, value)),
    child: Row(
      children: [
        Text(title, style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context))),
        ?help,
        const Spacer(),
        if (_selected == value) Icon(CupertinoIcons.checkmark_alt, size: 20, color: TegnalColors.tint.resolveFrom(context)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final row = FormColors.listRow.resolveFrom(context);
    return SettingsPage(
      title: L10n.text('Translation Language'),
      children: [
        FormSection(
          rowColor: row,
          children: [
            _option(
              'system',
              L10n.text('System Language'),
              help: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: FormHelpButton(
                  title: L10n.text('Translation Language'),
                  message: L10n.text('Uses your device’s language unless you choose another language below. Comics and Image modes remember separate choices.'),
                ),
              ),
            ),
          ],
        ),
        if (_languages.isNotEmpty) ...[
          settingsSectionGap,
          FormSection(rowColor: row, header: Text(L10n.text('Choose a Language')), children: [for (final (code, name) in _languages) _option(code, name)]),
        ],
      ],
    );
  }
}

/// `ReaderTranslationView`: the page with its translated text laid over the original in white
/// labels that zoom and pan with it, an Original button to close, and a progress pill.
class ImageTranslationView extends StatefulWidget {
  const ImageTranslationView({super.key, required this.loadImage, required this.preferences, required this.finished, required this.failed});
  final Future<Uint8List> Function() loadImage;
  final Preferences preferences;
  final VoidCallback finished;
  final void Function(String message) failed;

  @override
  State<ImageTranslationView> createState() => _ImageTranslationViewState();
}

class _ImageTranslationViewState extends State<ImageTranslationView> {
  Uint8List? _image;
  Size? _size;
  List<TranslatedRegion> _regions = [];
  bool _analyzing = true;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final image = await widget.loadImage();
      final buffer = await ui.ImmutableBuffer.fromUint8List(image);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final size = Size(descriptor.width.toDouble(), descriptor.height.toDouble());
      descriptor.dispose();
      buffer.dispose();
      if (!mounted) return;
      setState(() {
        _image = image;
        _size = size;
      });
      final target = TranslationLanguage.resolved(TranslationLanguage.preference(widget.preferences));
      final regions = await ImageTranslation.translate(image, target);
      if (!mounted) return;
      setState(() {
        _regions = regions;
        _analyzing = false;
      });
    } on TranslationError catch (error) {
      if (mounted) widget.failed(error.message);
    } on Object catch (error) {
      if (mounted) widget.failed(ContentError.message(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image, size = _size;
    const white = Color(0xFFFFFFFF);
    final padding = MediaQuery.paddingOf(context);
    return ColoredBox(
      color: const Color(0xFF000000),
      child: Stack(
        children: [
          if (image != null && size != null)
            Positioned.fill(
              child: InteractiveViewer(
                maxScale: 5,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: size.width / size.height,
                    child: LayoutBuilder(
                      builder: (context, box) => Stack(
                        children: [
                          Positioned.fill(child: Image.memory(image, fit: BoxFit.fill, gaplessPlayback: true)),
                          for (final region in _regions) _label(region, box.biggest),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            top: padding.top + 16,
            right: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Semantics(
                  button: true,
                  child: GestureDetector(
                    onTap: widget.finished,
                    child: Container(
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: const ShapeDecoration(color: Color(0xCC000000), shape: StadiumBorder()),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(CupertinoIcons.xmark, size: 14, color: white),
                          const SizedBox(width: 6),
                          Text(
                            L10n.text('Original'),
                            style: TegnalType.style(15, weight: FontWeight.w600, color: white),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_analyzing) ...[
                  const SizedBox(height: 10),
                  Semantics(
                    label: L10n.text('Preparing image translation'),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: const ShapeDecoration(color: Color(0xBF000000), shape: StadiumBorder()),
                      child: const CupertinoActivityIndicator(color: white),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// White labels over each text block, three points larger than it, as the native labels are.
  Widget _label(TranslatedRegion region, Size box) {
    final frame = Rect.fromLTWH(region.left * box.width, region.top * box.height, region.width * box.width, region.height * box.height).inflate(3);
    final bounded = frame.intersect(Offset.zero & box);
    if (bounded.width <= 0 || bounded.height <= 0) return const SizedBox.shrink();
    final basis = (region.vertical ? bounded.width * 0.6 : bounded.height * 0.78) / region.lines;
    final fontSize = math.max(8.0, math.min(22.0, basis));
    return Positioned.fromRect(
      rect: bounded,
      child: DecoratedBox(
        decoration: BoxDecoration(color: const Color(0xFFFFFFFF), borderRadius: BorderRadius.circular(3)),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(
              width: bounded.width,
              child: Text(
                region.text,
                textAlign: TextAlign.center,
                style: TegnalType.style(fontSize, weight: FontWeight.w500, color: const Color(0xFF000000)).copyWith(height: 1.1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
