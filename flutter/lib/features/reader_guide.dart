import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/app_controller.dart';
import '../core/content.dart';
import '../core/library.dart';
import '../ui/l10n.dart';

/// Uses the native guide's artwork, three lessons, and saved dismissal choice.
Future<void> showReaderGuide(
  BuildContext context,
  AppController controller,
  AppMode mode,
) async {
  final theme = Theme.of(context);
  final hide = await Navigator.of(context, rootNavigator: true).push<bool>(
    MaterialPageRoute<bool>(
      fullscreenDialog: true,
      builder: (_) => Theme(
        data: theme,
        child: ReaderGuideScreen(controller: controller, mode: mode),
      ),
    ),
  );
  if (hide == true) controller.setPreference('reader.helpHidden', true);
}

class ReaderGuideScreen extends StatefulWidget {
  const ReaderGuideScreen({
    super.key,
    required this.controller,
    required this.mode,
  });
  final AppController controller;
  final AppMode mode;
  @override
  State<ReaderGuideScreen> createState() => _ReaderGuideScreenState();
}

class _ReaderGuideScreenState extends State<ReaderGuideScreen> {
  final ScrollController _scroll = ScrollController();
  int _step = 0;
  ReaderPreferences get _prefs =>
      widget.controller.readerPreferences(widget.mode);
  bool get _continuous =>
      widget.mode == AppMode.manga &&
      _prefs.readingMode == ReadingMode.continuous;
  bool get _images => widget.mode == AppMode.booru;
  String _t(String key) => L10n.tr(context, key);
  String get _title =>
      ['Read with Taps', 'Zoom and Translate', 'Exit the Work'][_step];
  String get _description => switch (_step) {
    0 =>
      _continuous
          ? 'Scroll to read. Tap the page for the quick menu, or hold anywhere to bookmark.'
          : _images
          ? 'Tap the sides or swipe to change images. Tap the center for the quick menu, or hold anywhere to favorite.'
          : _prefs.tapNavigation
          ? 'Tap either side to turn pages. Tap the center for the quick menu, or hold anywhere to bookmark.'
          : 'Swipe to turn pages. Tap for the quick menu, or hold anywhere to bookmark.',
    1 => 'Double tap or pinch to zoom. Drag to position the area you want, then choose Translate in the quick menu.',
    _ =>
      _continuous
          ? 'In Continuous Scroll, drag down from the top handle to close. Dragging the pages only scrolls.'
          : 'At the original zoom level, swipe down to exit. While zoomed, dragging only moves the image. You can also exit from the quick menu.',
  };
  String get _secondary => _step == 1
      ? 'Translation opens the installed Google Translate app. Choose languages there.'
      : _step == 2
      ? 'Try the gesture on the illustration.'
      : _images
      ? 'From the bottom of the image, swipe up for details.'
      : _continuous && !_prefs.continuousPreviewSwipe
      ? 'Open previews from the quick menu.'
      : 'From the bottom of the page, swipe up for previews.';

  void _select(int step) {
    if (step == _step) return;
    setState(() => _step = step);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 20;
    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(
          _t('Reader Guide'),
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontFamilyFallback: const ['Pretendard JP'],
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: colors.onSurface,
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('reader-guide-close'),
            onPressed: () => Navigator.pop(context),
            child: Text(_t('Close')),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<int>(
                      style: SegmentedButton.styleFrom(
                        textStyle: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontFamilyFallback: ['Pretendard JP'],
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                        minimumSize: const Size(0, 38),
                        padding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: largeText ? 10 : 0,
                        ),
                      ),
                      segments: [
                        for (final (index, title) in [
                          'Taps',
                          largeText ? 'Zoom' : 'Zoom & Translate',
                          'Exit',
                        ].indexed)
                          ButtonSegment<int>(
                            value: index,
                            label: Text(
                              _t(title),
                              maxLines: 1,
                              textAlign: TextAlign.center,
                            ),
                          ),
                      ],
                      selected: {_step},
                      showSelectedIcon: false,
                      onSelectionChanged: (value) => _select(value.first),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, viewport) {
                  final availableWidth = math.min(
                    viewport.maxWidth - 32,
                    428.0,
                  );
                  final pictureHeight = largeText
                      ? availableWidth * 1.5
                      : math.min(
                          availableWidth * 1.5,
                          (viewport.maxHeight * .70).clamp(260.0, 540.0),
                        );
                  return SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 428),
                        child: Column(
                          children: [
                            SizedBox(
                              height: pictureHeight,
                              width: pictureHeight * 2 / 3,
                              child: _GestureIllustration(
                                key: ValueKey(
                                  'reader-guide-illustration-$_step',
                                ),
                                step: _step,
                                rightToLeft:
                                    _prefs.rightToLeft &&
                                    (_images ||
                                        _prefs.readingMode ==
                                            ReadingMode.horizontal),
                                tapNavigation: _prefs.tapNavigation,
                                continuous: _continuous,
                                images: _images,
                                description: _t(_description),
                              ),
                            ),
                            const SizedBox(height: 18),
                            Text(
                              _t(_title),
                              key: const ValueKey('reader-guide-step-title'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 20,
                                height: 1.25,
                                fontWeight: FontWeight.w700,
                                color: colors.onSurface,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              _t(_description),
                              textAlign: TextAlign.start,
                              style: TextStyle(
                                fontSize: 15,
                                height: 1.5,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  _step == 1
                                      ? Icons.translate
                                      : _step == 2
                                      ? Icons.touch_app_outlined
                                      : Icons.swipe_up_outlined,
                                  size: 17,
                                  color: colors.primary,
                                ),
                                const SizedBox(width: 7),
                                Expanded(
                                  child: Text(
                                    _t(_secondary),
                                    style: TextStyle(
                                      fontSize: 13,
                                      height: 1.4,
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (largeText) ...[
                              const SizedBox(height: 16),
                              Text(
                                _t(
                                  'You can reopen this guide in Reader Settings or Settings.',
                                ),
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.4,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border(
                  top: BorderSide(
                    color: colors.outlineVariant.withValues(alpha: .5),
                    width: .5,
                  ),
                ),
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Semantics(
                              label: '${_step + 1} / 3',
                              child: Row(
                                children: [
                                  for (var index = 0; index < 3; index++)
                                    Container(
                                      width: 6,
                                      height: 6,
                                      margin: const EdgeInsets.only(right: 6),
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: index == _step
                                            ? colors.primary
                                            : colors.onSurfaceVariant
                                                  .withValues(alpha: .25),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            if (_step > 0)
                              IconButton(
                                key: const ValueKey('reader-guide-previous'),
                                tooltip: _t('Previous Tip'),
                                onPressed: () => _select(_step - 1),
                                icon: const Icon(Icons.arrow_back, size: 22),
                              ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: TextButton.icon(
                                  key: const ValueKey('reader-guide-next'),
                                  onPressed: _step < 2
                                      ? () => _select(_step + 1)
                                      : () => Navigator.pop(context),
                                  iconAlignment: IconAlignment.end,
                                  icon: Icon(
                                    _step < 2
                                        ? Icons.arrow_forward
                                        : Icons.check,
                                    size: 20,
                                  ),
                                  label: Text(
                                    _t(
                                      _step < 2
                                          ? (largeText ? 'Next' : 'Next Tip')
                                          : 'Done',
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (!_images)
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton(
                              key: const ValueKey('reader-guide-never'),
                              onPressed: () => Navigator.pop(context, true),
                              child: Text(
                                _t("Don't Show Again"),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        if (!largeText) const SizedBox(height: 6),
                        if (!largeText)
                          Text(
                            _t(
                              'You can reopen this guide in Reader Settings or Settings.',
                            ),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.35,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The exact native artwork carries deterministic Flutter gesture diagrams.
/// Demos affect only this illustration; no library action or app launch occurs.
class _GestureIllustration extends StatefulWidget {
  const _GestureIllustration({
    super.key,
    required this.step,
    required this.rightToLeft,
    required this.tapNavigation,
    required this.continuous,
    required this.images,
    required this.description,
  });
  final int step;
  final bool rightToLeft, tapNavigation, continuous, images;
  final String description;
  @override
  State<_GestureIllustration> createState() => _GestureIllustrationState();
}

class _GestureIllustrationState extends State<_GestureIllustration> {
  double _zoom = 1, _startZoom = 1, _exitOffset = 0;
  Offset _pan = Offset.zero;
  bool _bookmark = false, _menu = false, _handle = false;
  String? _feedback;
  int _pulse = 0;
  String _t(String key) => L10n.tr(context, key);
  void _tap(TapUpDetails details, Size size) {
    if (widget.step == 0) {
      final fraction = details.localPosition.dx / size.width;
      setState(() {
        _pulse++;
        if (!widget.continuous &&
            widget.tapNavigation &&
            (fraction < .3 || fraction > .7)) {
          final next = widget.rightToLeft ? fraction < .3 : fraction > .7;
          _feedback = _t(next ? 'Next' : 'Previous');
          _menu = false;
        } else {
          _menu = !_menu;
          _feedback = _t('Quick Menu');
        }
      });
    } else if (widget.step == 2) {
      setState(() {
        _exitOffset = 0;
        _feedback = null;
      });
    }
  }

  Widget _tip(String title, IconData icon, {double? width, Color? color}) =>
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width ?? 240),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xD9000000),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: color ?? Colors.white, size: 23),
                const SizedBox(height: 5),
                Text(
                  _t(title),
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontFamilyFallback: ['Pretendard JP'],
                    color: Colors.white,
                    fontSize: 11,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
  Widget _at(Size size, double x, double y, Widget child) => Positioned.fill(
    child: CustomSingleChildLayout(
      delegate: _TipPosition(Offset(x, y)),
      child: child,
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      final left = widget.continuous
          ? 'Scroll'
          : widget.tapNavigation
          ? widget.rightToLeft
                ? 'Next'
                : 'Previous'
          : 'Quick Menu';
      final right = widget.continuous
          ? 'Scroll'
          : widget.tapNavigation
          ? widget.rightToLeft
                ? 'Previous'
                : 'Next'
          : 'Quick Menu';
      return Semantics(
        image: true,
        label: widget.description,
        child: ExcludeSemantics(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: GestureDetector(
              key: const ValueKey('reader-guide-demo'),
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) => _tap(details, size),
              onLongPress: widget.step == 0
                  ? () => setState(() {
                      _bookmark = !_bookmark;
                      _feedback = _t(
                        widget.images
                            ? 'Saved to Favorites'
                            : 'Saved to bookmarks',
                      );
                      _pulse++;
                    })
                  : null,
              onDoubleTap: widget.step == 1
                  ? () => setState(() {
                      _zoom = _zoom > 1 ? 1 : 1.65;
                      _pan = Offset.zero;
                    })
                  : null,
              onScaleStart: widget.step == 1 ? (_) => _startZoom = _zoom : null,
              onScaleUpdate: widget.step == 1
                  ? (details) => setState(() {
                      _zoom = (_startZoom * details.scale).clamp(1.0, 3.0);
                      if (_zoom > 1) {
                        _pan = Offset(
                          (_pan.dx + details.focalPointDelta.dx).clamp(
                            -size.width * .3,
                            size.width * .3,
                          ),
                          (_pan.dy + details.focalPointDelta.dy).clamp(
                            -size.height * .3,
                            size.height * .3,
                          ),
                        );
                      }
                    })
                  : null,
              onVerticalDragDown: widget.step == 2
                  ? (details) {
                      _handle =
                          details.localPosition.dy <=
                          math.max(24, size.height * .1);
                    }
                  : null,
              onVerticalDragUpdate: widget.step == 2
                  ? (details) => setState(() {
                      if (!widget.continuous || _handle) {
                        _exitOffset = (_exitOffset + details.delta.dy).clamp(
                          0.0,
                          size.height * .25,
                        );
                      } else {
                        _feedback = _t('Dragging the pages only scrolls.');
                      }
                    })
                  : null,
              onVerticalDragEnd: widget.step == 2
                  ? (_) => setState(() {
                      if (_exitOffset > 45) _feedback = _t('Done');
                      _exitOffset = 0;
                    })
                  : null,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Colors.black),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    transform: Matrix4.translationValues(
                      widget.step == 1 ? _pan.dx : 0,
                      widget.step == 1 ? _pan.dy : _exitOffset,
                      0,
                    ),
                    child: AnimatedScale(
                      scale: widget.step == 1 ? _zoom : 1,
                      duration: const Duration(milliseconds: 240),
                      child: Image.asset(
                        'assets/branding/reader-guide.png',
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  IgnorePointer(
                    child: MediaQuery.withClampedTextScaling(
                      maxScaleFactor: 1.25,
                      child: Stack(
                        children: [
                          if (widget.step == 0) ...[
                            Positioned(
                              left: 0,
                              right: 0,
                              top: size.height * .1,
                              bottom: size.height * .1,
                              child: Row(
                                children: [
                                  Expanded(
                                    flex: 3,
                                    child: ColoredBox(
                                      color: const Color(0x1F007AFF),
                                    ),
                                  ),
                                  Expanded(
                                    flex: 4,
                                    child: ColoredBox(
                                      color: const Color(0x1F30B0C7),
                                    ),
                                  ),
                                  Expanded(
                                    flex: 3,
                                    child: ColoredBox(
                                      color: const Color(0x1F007AFF),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            _at(
                              size,
                              .16,
                              .43,
                              _tip(
                                left,
                                widget.continuous
                                    ? Icons.swipe_vertical
                                    : Icons.touch_app,
                                width: size.width * .29,
                              ),
                            ),
                            _at(
                              size,
                              .5,
                              .43,
                              _tip(
                                'Quick Menu',
                                Icons.touch_app,
                                width: size.width * .36,
                              ),
                            ),
                            _at(
                              size,
                              .84,
                              .43,
                              _tip(
                                right,
                                widget.continuous
                                    ? Icons.swipe_vertical
                                    : Icons.touch_app,
                                width: size.width * .29,
                              ),
                            ),
                            _at(
                              size,
                              .5,
                              .68,
                              _tip(
                                widget.images
                                    ? 'Hold to favorite'
                                    : 'Hold to bookmark',
                                _bookmark
                                    ? Icons.bookmark
                                    : Icons.bookmark_outline,
                                width: size.width * .72,
                                color: _bookmark
                                    ? const Color(0xFFFFD60A)
                                    : null,
                              ),
                            ),
                            if (_menu)
                              Positioned(
                                left: 20,
                                right: 20,
                                bottom: size.height * .08,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: const Color(0xE6252527),
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                  child: const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceEvenly,
                                      children: [
                                        Icon(
                                          Icons.bookmark_outline,
                                          color: Colors.white,
                                          size: 22,
                                        ),
                                        Icon(
                                          Icons.translate,
                                          color: Colors.white,
                                          size: 22,
                                        ),
                                        Icon(
                                          Icons.tune,
                                          color: Colors.white,
                                          size: 22,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                          if (widget.step == 1) ...[
                            _at(
                              size,
                              .5,
                              .27,
                              _tip(
                                'Double tap or pinch to zoom',
                                Icons.pinch,
                                width: size.width * .76,
                              ),
                            ),
                            _at(
                              size,
                              .5,
                              .5,
                              Container(
                                padding: EdgeInsets.all(size.width * .055),
                                decoration: const BoxDecoration(
                                  color: Color(0xA6000000),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.open_with,
                                  color: Colors.white,
                                  size: size.width * .16,
                                ),
                              ),
                            ),
                            _at(
                              size,
                              .5,
                              .7,
                              _tip(
                                'Drag to position',
                                Icons.pan_tool_alt,
                                width: size.width * .72,
                              ),
                            ),
                            _at(
                              size,
                              .5,
                              .85,
                              _tip(
                                'Tap center → Translate',
                                Icons.translate,
                                width: size.width * .76,
                              ),
                            ),
                          ],
                          if (widget.step == 2) ...[
                            if (widget.continuous)
                              Positioned(
                                left: size.width * .22,
                                right: size.width * .22,
                                top: 0,
                                height: 22,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: const Color(0xFF009DFF),
                                      width: 2,
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              ),
                            _at(
                              size,
                              .5,
                              .2,
                              _tip(
                                widget.continuous
                                    ? 'Drag the top handle down'
                                    : 'At original zoom',
                                widget.continuous
                                    ? Icons.drag_handle
                                    : Icons.zoom_in_map,
                                width: size.width * .76,
                              ),
                            ),
                            _at(
                              size,
                              .5,
                              .48,
                              TweenAnimationBuilder<double>(
                                key: ValueKey(
                                  'exit-arrow-${widget.continuous}',
                                ),
                                tween: Tween(begin: -12, end: 0),
                                duration: const Duration(milliseconds: 650),
                                curve: Curves.easeOutCubic,
                                builder: (_, offset, child) =>
                                    Transform.translate(
                                      offset: Offset(0, offset),
                                      child: child,
                                    ),
                                child: Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: size.width * .065,
                                    vertical: size.width * .07,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xA6000000),
                                    borderRadius: BorderRadius.circular(70),
                                  ),
                                  child: Icon(
                                    Icons.arrow_downward,
                                    color: Colors.white,
                                    size: size.width * .25,
                                  ),
                                ),
                              ),
                            ),
                            _at(
                              size,
                              .5,
                              .77,
                              _tip(
                                'Swipe down to exit',
                                Icons.swipe_down_alt,
                                width: size.width * .76,
                              ),
                            ),
                          ],
                          if (_feedback != null)
                            Positioned(
                              top: size.height * .08,
                              left: 10,
                              right: 10,
                              child: Center(
                                child: TweenAnimationBuilder<double>(
                                  key: ValueKey('$_feedback-$_pulse'),
                                  tween: Tween(begin: .9, end: 1),
                                  duration: const Duration(milliseconds: 180),
                                  builder: (_, scale, child) => Transform.scale(
                                    scale: scale,
                                    child: child,
                                  ),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 7,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xE6000000),
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                    child: Text(
                                      _feedback!,
                                      key: const ValueKey(
                                        'reader-guide-feedback',
                                      ),
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontFamily: 'Pretendard',
                                        fontFamilyFallback: ['Pretendard JP'],
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _TipPosition extends SingleChildLayoutDelegate {
  const _TipPosition(this.anchor);
  final Offset anchor;
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest);
  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    (size.width * anchor.dx - childSize.width / 2).clamp(
      0.0,
      math.max(0, size.width - childSize.width),
    ),
    (size.height * anchor.dy - childSize.height / 2).clamp(
      0.0,
      math.max(0, size.height - childSize.height),
    ),
  );
  @override
  bool shouldRelayout(_TipPosition oldDelegate) => anchor != oldDelegate.anchor;
}
