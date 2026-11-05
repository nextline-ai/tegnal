import 'dart:async';
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../core/content/reading_queue.dart';
import '../../core/support/l10n.dart';
import '../design/glass.dart';
import '../design/grouped_form.dart';
import '../design/symbols.dart';
import '../design/tegnal_theme.dart';

/// Hands Up Next to every screen and route of the app.
class ReadingQueueScope extends InheritedNotifier<ReadingQueue> {
  const ReadingQueueScope({super.key, required ReadingQueue queue, required super.child}) : super(notifier: queue);

  static ReadingQueue? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ReadingQueueScope>()?.notifier;

  /// The queue without listening, for gestures and callbacks.
  static ReadingQueue? read(BuildContext context) => context.getInheritedWidgetOfExactType<ReadingQueueScope>()?.notifier;
}

/// How much room the Up Next bar takes at the bottom of the comics tabs, which
/// `tabBarClearance` adds so lists end above the bar and notices rise above it.
class ReadingQueueInset extends InheritedWidget {
  const ReadingQueueInset({super.key, required this.height, required super.child});
  final double height;

  static double of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ReadingQueueInset>()?.height ?? 0;

  @override
  bool updateShouldNotify(ReadingQueueInset oldWidget) => oldWidget.height != height;
}

const _cardFill = CupertinoDynamicColor.withBrightness(color: Color(0xFFFFFFFF), darkColor: Color(0xFF1C1C1E));

/// The Up Next bar's height: half again the system's accessory bar.
const double readingQueueBarHeight = 72;

/// `WorkHoldModifier`: holding a work bookmarks it while the finger is still down; moving soon
/// after the hold carries it down to the Up Next panel instead. While it is held the list under
/// it does not scroll, since the hold has won the gesture.
class WorkHold extends StatefulWidget {
  const WorkHold({super.key, required this.child, required this.onTap, required this.bookmark, this.queue, this.item, this.image, this.cover});
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback bookmark;

  /// Up Next and the work to carry there; without them a hold saves at once.
  final ReadingQueue? queue;
  final ReadingQueueItem Function()? item;
  final ui.Image? Function()? image;
  final Future<Uint8List?> Function()? cover;

  /// How long a still finger is held before the hold is noticed.
  static const holdDuration = Duration(milliseconds: 450);

  /// How long after the hold a move still means "carry" rather than "bookmark".
  static const decisionWindow = Duration(milliseconds: 600);

  /// How far the finger moves before a held work is being carried.
  static const carryDistance = 8.0;

  @override
  State<WorkHold> createState() => _WorkHoldState();
}

enum _HoldPhase { idle, deciding, bookmarked, carrying }

class _WorkHoldState extends State<WorkHold> {
  bool _pressed = false;
  _HoldPhase _phase = _HoldPhase.idle;
  Offset _start = Offset.zero;
  Timer? _decision;

  bool get _carries => widget.queue != null && widget.item != null;

  void _began(LongPressStartDetails details) {
    _start = details.globalPosition;
    HapticFeedback.lightImpact();
    setState(() => _pressed = true);
    if (!_carries) {
      _phase = _HoldPhase.bookmarked;
      HapticFeedback.mediumImpact();
      widget.bookmark();
      return;
    }
    _phase = _HoldPhase.deciding;
    _decision = Timer(WorkHold.decisionWindow, () {
      if (_phase != _HoldPhase.deciding || !mounted) return;
      _phase = _HoldPhase.bookmarked;
      // A work that can be carried springs back as it is bookmarked.
      setState(() => _pressed = false);
      HapticFeedback.mediumImpact();
      widget.bookmark();
    });
  }

  void _moved(LongPressMoveUpdateDetails details) {
    final queue = widget.queue;
    if (queue == null) return;
    if (_phase == _HoldPhase.deciding && (details.globalPosition - _start).distance > WorkHold.carryDistance) {
      _decision?.cancel();
      _phase = _HoldPhase.carrying;
      HapticFeedback.lightImpact();
      queue.beginCarry(widget.item!(), image: widget.image?.call(), cover: widget.cover?.call(), at: details.globalPosition);
      setState(() {});
    } else if (_phase == _HoldPhase.carrying) {
      queue.moveCarry(details.globalPosition);
    }
  }

  void _ended() {
    _decision?.cancel();
    final phase = _phase;
    _phase = _HoldPhase.idle;
    if (mounted) setState(() => _pressed = false);
    switch (phase) {
      // Let go before the window closed, the hold was still a bookmark.
      case _HoldPhase.deciding:
        HapticFeedback.mediumImpact();
        widget.bookmark();
      case _HoldPhase.carrying:
        if (widget.queue?.endCarry() ?? false) HapticFeedback.heavyImpact();
      case _HoldPhase.bookmarked || _HoldPhase.idle:
        break;
    }
  }

  void _cancelled() {
    _decision?.cancel();
    if (_phase == _HoldPhase.carrying) widget.queue?.endCarry();
    _phase = _HoldPhase.idle;
    if (mounted) setState(() => _pressed = false);
  }

  @override
  void dispose() {
    _decision?.cancel();
    // A cell scrolled away or rebuilt mid-gesture never reports the gesture's end.
    if (_phase == _HoldPhase.carrying) widget.queue?.endCarry();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final carrying = _phase == _HoldPhase.carrying;
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
          TapGestureRecognizer.new,
          (recognizer) => recognizer.onTap = widget.onTap,
        ),
        LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
          () => LongPressGestureRecognizer(duration: WorkHold.holdDuration),
          (recognizer) => recognizer
            ..onLongPressStart = _began
            ..onLongPressMoveUpdate = _moved
            ..onLongPressEnd = ((_) => _ended())
            ..onLongPressCancel = _cancelled,
        ),
      },
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        child: AnimatedOpacity(opacity: carrying && _pressed ? 0.45 : 1, duration: const Duration(milliseconds: 160), child: widget.child),
      ),
    );
  }
}

/// The horizontal card a carried work shows, as Saved shows a held work.
class ReadingQueueCard extends StatelessWidget {
  const ReadingQueueCard({super.key, required this.item, this.image, this.width = 320});
  final ReadingQueueItem item;
  final ui.Image? image;
  final double width;

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return Container(
      width: width,
      padding: const EdgeInsets.all(14),
      decoration: ShapeDecoration(
        color: _cardFill.resolveFrom(context),
        shape: RoundedSuperellipseBorder(
          borderRadius: const BorderRadius.all(Radius.circular(24)),
          side: BorderSide(color: const Color(0x1FFFFFFF), width: 0.5),
        ),
        shadows: const [BoxShadow(color: Color(0x47000000), blurRadius: 24, offset: Offset(0, 12))],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 104,
              height: 148,
              child: image != null
                  ? RawImage(image: image, fit: BoxFit.cover)
                  : ColoredBox(
                      color: TegnalColors.coverPlaceholder.resolveFrom(context),
                      child: Center(child: Icon(Symbols.book, color: secondary)),
                    ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.displayTitle,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TegnalType.style(17, weight: FontWeight.w600),
                ),
                if (item.artists.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    item.artists,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TegnalType.style(15, color: secondary),
                  ),
                ],
                if (item.details.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    item.details,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TegnalType.style(13, color: secondary),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The panel a carried work is let go on, with the card following the finger above it.
class ReadingQueueCarryOverlay extends StatefulWidget {
  const ReadingQueueCarryOverlay({super.key, required this.queue, required this.bottom});
  final ReadingQueue queue;

  /// The panel's distance from the bottom edge, just above the tabs.
  final double bottom;

  @override
  State<ReadingQueueCarryOverlay> createState() => _ReadingQueueCarryOverlayState();
}

class _ReadingQueueCarryOverlayState extends State<ReadingQueueCarryOverlay> {
  final _panelKey = GlobalKey();
  final _areaKey = GlobalKey();

  /// Where this overlay sits on screen, measured after layout: banners above the tabs move it.
  Offset _origin = Offset.zero;

  /// The last carried work, kept so the card can fade where it was let go.
  ReadingQueueItem? _shown;
  ui.Image? _shownImage;
  bool _wasOver = false;

  @override
  void initState() {
    super.initState();
    widget.queue.addListener(_changed);
  }

  @override
  void dispose() {
    widget.queue.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final queue = widget.queue;
    if (queue.carried != null) {
      _shown = queue.carried;
      _shownImage = queue.carriedCover;
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    }
    if (queue.isOverDropZone != _wasOver) {
      _wasOver = queue.isOverDropZone;
      if (_wasOver) HapticFeedback.selectionClick();
    }
    if (mounted) setState(() {});
  }

  void _measure() {
    final area = _areaKey.currentContext?.findRenderObject() as RenderBox?;
    if (area != null && area.hasSize) {
      final origin = area.localToGlobal(Offset.zero);
      if (origin != _origin && mounted) setState(() => _origin = origin);
    }
    final box = _panelKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    widget.queue.dropZone = box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    final queue = widget.queue;
    final active = queue.carried != null;
    final over = queue.isOverDropZone;
    final item = _shown;
    return IgnorePointer(
      key: _areaKey,
      child: Builder(
        builder: (context) {
          final location = queue.carryLocation - _origin;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              // Both stay in place and only fade and scale, so an interrupted animation never
              // leaves them frozen on screen.
              Positioned(
                left: 16,
                right: 16,
                bottom: widget.bottom,
                child: AnimatedSlide(
                  offset: active ? Offset.zero : const Offset(0, 0.3),
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    opacity: active ? 1 : 0,
                    duration: const Duration(milliseconds: 220),
                    child: _DropPanel(key: _panelKey, over: over, count: queue.items.length),
                  ),
                ),
              ),
              if (item != null)
                Positioned(
                  left: location.dx,
                  top: location.dy,
                  child: FractionalTranslation(
                    // Centred on the finger, even where that reaches past the screen's edge.
                    translation: const Offset(-0.5, -0.5),
                    child: AnimatedScale(
                      scale: active ? (over ? 0.82 : 1) : 0.3,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutBack,
                      child: AnimatedOpacity(
                        opacity: active ? 1 : 0,
                        duration: const Duration(milliseconds: 220),
                        child: ReadingQueueCard(item: item, image: _shownImage),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _DropPanel extends StatelessWidget {
  const _DropPanel({super.key, required this.over, required this.count});
  final bool over;
  final int count;

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    final label = TegnalColors.label.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final color = over ? tint : label;
    return AnimatedScale(
      scale: over ? 1.04 : 1,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutBack,
      child: Stack(
        children: [
          Positioned.fill(
            child: Glass.surface(
              cornerRadius: 26,
              child: AnimatedContainer(duration: const Duration(milliseconds: 200), color: over ? tint.withValues(alpha: 0.16) : const Color(0x00000000)),
            ),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: _DashedBorder(color: over ? tint : secondary.withValues(alpha: 0.4), dashed: !over),
            ),
          ),
          SizedBox(
            height: 133,
            width: double.infinity,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(over ? CupertinoIcons.plus_circle_fill : CupertinoIcons.text_badge_plus, size: 28, color: color),
                const SizedBox(height: 7),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    L10n.text(over ? 'Release to Add to Up Next' : 'Drag Here to Read Later'),
                    textAlign: TextAlign.center,
                    style: TegnalType.style(15, weight: FontWeight.w600, color: color),
                  ),
                ),
                if (count > 0) ...[
                  const SizedBox(height: 7),
                  Text(L10n.text('Up Next · %@', ['$count']), style: TegnalType.style(12, color: over ? tint.withValues(alpha: 0.8) : secondary)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DashedBorder extends CustomPainter {
  _DashedBorder({required this.color, required this.dashed});
  final Color color;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = RRect.fromRectAndRadius((Offset.zero & size).deflate(1), const Radius.circular(26));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final path = Path()..addRRect(rect);
    if (!dashed) {
      canvas.drawPath(path, paint);
      return;
    }
    for (final metric in path.computeMetrics()) {
      for (var distance = 0.0; distance < metric.length; distance += 14) {
        canvas.drawPath(metric.extractPath(distance, distance + 8), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder oldDelegate) => oldDelegate.color != color || oldDelegate.dashed != dashed;
}

/// The cover a list row or the bar shows, from the queue's stored covers.
class ReadingQueueCover extends StatelessWidget {
  const ReadingQueueCover({super.key, required this.queue, required this.id, required this.width, required this.height, this.radius});
  final ReadingQueue queue;
  final int id;
  final double width;
  final double height;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final data = queue.cover(id);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius ?? (width / 7).clamp(4, 20)),
      child: SizedBox(
        width: width,
        height: height,
        child: data != null
            // Covers are tall; a shorter frame keeps their top, where titles and faces are.
            ? Image.memory(data, fit: BoxFit.cover, alignment: Alignment.topCenter, gaplessPlayback: true)
            : ColoredBox(
                color: TegnalColors.coverPlaceholder.resolveFrom(context),
                child: Center(child: Icon(Symbols.book, size: 14, color: TegnalColors.secondaryLabel.resolveFrom(context))),
              ),
      ),
    );
  }
}

/// `ReadingQueueBar`: the bar above the tabs, like a music app's mini player: the next work to
/// read and a button that starts reading.
class ReadingQueueBar extends StatefulWidget {
  const ReadingQueueBar({super.key, required this.queue, required this.next, required this.read, required this.showList, this.dark = false});
  final ReadingQueue queue;
  final ReadingQueueItem next;
  final ValueChanged<int> read;
  final VoidCallback showList;

  /// Over the reader, the bar is always dark.
  final bool dark;

  @override
  State<ReadingQueueBar> createState() => _ReadingQueueBarState();
}

class _ReadingQueueBarState extends State<ReadingQueueBar> {
  late int _arrivals = widget.queue.arrivals;
  bool _bounce = false;

  @override
  void didUpdateWidget(ReadingQueueBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.queue.arrivals != _arrivals) {
      _arrivals = widget.queue.arrivals;
      setState(() => _bounce = true);
      Future<void>.delayed(const Duration(milliseconds: 180), () {
        if (mounted) setState(() => _bounce = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final next = widget.next;
    final label = widget.dark ? const Color(0xFFFFFFFF) : TegnalColors.label.resolveFrom(context);
    final secondary = widget.dark ? const Color(0x99FFFFFF) : TegnalColors.secondaryLabel.resolveFrom(context);
    return Glass.capsule(
      child: SizedBox(
        height: readingQueueBarHeight,
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                button: true,
                label: L10n.text('Up Next'),
                value: L10n.text('%@ works', ['${widget.queue.items.length}']),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.showList,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 11),
                    child: Row(
                      children: [
                        AnimatedScale(
                          scale: _bounce ? 1.18 : 1,
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOut,
                          child: ReadingQueueCover(queue: widget.queue, id: next.id, width: 50, height: 50, radius: 13),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                next.displayTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TegnalType.style(17, weight: FontWeight.w600, color: label),
                              ),
                              const SizedBox(height: 1),
                              Text(L10n.text('Up Next · %@', ['${widget.queue.items.length}']), maxLines: 1, style: TegnalType.style(15, color: secondary)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Semantics(
              button: true,
              label: L10n.text('Read Next'),
              excludeSemantics: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => widget.read(next.id),
                child: SizedBox(
                  width: 56,
                  height: readingQueueBarHeight,
                  child: Center(child: Icon(Symbols.bookFill, size: 22, color: label)),
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}

/// `ReadingQueueView`: the whole list. Reorder, swipe away, or tap a work to read from there on.
class ReadingQueueView extends StatelessWidget {
  const ReadingQueueView({super.key, required this.queue, required this.read, this.scrollController});
  final ReadingQueue queue;
  final ValueChanged<int> read;
  final ScrollController? scrollController;

  Future<void> _confirmClear(BuildContext context) async {
    final clear = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        actions: [CupertinoActionSheetAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Delete All')))],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (clear == true) queue.clear();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: queue,
    builder: (context, _) {
      final items = queue.items;
      final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
      return ScrollEdgeSheet(
        bar: SheetNavigationBar(
          title: L10n.text('Up Next'),
          leading: GlassTextButton(label: L10n.text('Done'), onPressed: () => Navigator.of(context).pop()),
          trailing: items.isEmpty
              ? null
              : GlassTextButton(label: L10n.text('Delete All'), tint: CupertinoColors.systemRed.resolveFrom(context), onPressed: () => _confirmClear(context)),
        ),
        child: items.isEmpty
            ? Padding(
                padding: const EdgeInsets.fromLTRB(32, 120, 32, 32),
                child: Column(
                  children: [
                    Icon(CupertinoIcons.text_badge_plus, size: 44, color: secondary),
                    const SizedBox(height: 12),
                    Text(L10n.text('Nothing Up Next'), style: TegnalType.style(22, weight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Text(
                      L10n.text('Hold a work in Explore and drag it down to the panel that appears.'),
                      textAlign: TextAlign.center,
                      style: TegnalType.style(15, color: secondary),
                    ),
                  ],
                ),
              )
            : CustomScrollView(
                controller: scrollController,
                slivers: [
                  const SliverToBoxAdapter(child: SizedBox(height: 76 + 20)),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverReorderableList(
                      itemCount: items.length,
                      onReorderItem: queue.move,
                      itemBuilder: (context, index) {
                        final item = items[index];
                        return ReorderableDelayedDragStartListener(
                          key: ValueKey(item.id),
                          index: index,
                          child: Dismissible(
                            key: ValueKey('dismiss:${item.id}'),
                            direction: DismissDirection.endToStart,
                            onDismissed: (_) => queue.remove(item.id),
                            background: Container(
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 24),
                              color: CupertinoColors.systemRed.resolveFrom(context),
                              child: const Icon(CupertinoIcons.trash, color: Color(0xFFFFFFFF)),
                            ),
                            child: _QueueRow(queue: queue, item: item, first: index == 0, last: index == items.length - 1, onTap: () => read(item.id)),
                          ),
                        );
                      },
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(36, 8, 36, 40),
                      child: Text(L10n.text('A work leaves the list once you read it to the last page.'), style: TegnalType.style(13, color: secondary)),
                    ),
                  ),
                ],
              ),
      );
    },
  );
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({required this.queue, required this.item, required this.first, required this.last, required this.onTap});
  final ReadingQueue queue;
  final ReadingQueueItem item;
  final bool first;
  final bool last;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final byline = [item.artists, item.details].where((part) => part.isNotEmpty).join(' · ');
    const radius = Radius.circular(26);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        decoration: ShapeDecoration(
          color: _cardFill.resolveFrom(context),
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.vertical(top: first ? radius : Radius.zero, bottom: last ? radius : Radius.zero),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          children: [
            ReadingQueueCover(queue: queue, id: item.id, width: 46, height: 64),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.displayTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TegnalType.style(17, weight: FontWeight.w500),
                  ),
                  if (byline.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      byline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TegnalType.style(15, color: secondary),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Up Next one row above the reader's quick menu: the work after the open one, which the reader
/// switches to. Swiped like a music app's player, it moves to the next or previous work in the list.
class ReaderQueueRow extends StatefulWidget {
  const ReaderQueueRow({super.key, required this.queue, required this.currentID, required this.open, required this.showList});
  final ReadingQueue queue;
  final int currentID;
  final ValueChanged<int> open;
  final VoidCallback showList;

  @override
  State<ReaderQueueRow> createState() => _ReaderQueueRowState();
}

class _ReaderQueueRowState extends State<ReaderQueueRow> with SingleTickerProviderStateMixin {
  double _drag = 0;
  late final _settle = AnimationController(vsync: this, duration: const Duration(milliseconds: 220))..addListener(_settled);
  double _from = 0;
  double _to = 0;

  void _settled() => setState(() => _drag = _from + (_to - _from) * Curves.easeOutCubic.transform(_settle.value));

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  /// The works around the open one in Up Next. A work opened from elsewhere goes before the list.
  (ReadingQueueItem?, ReadingQueueItem?) get _neighbors {
    final items = widget.queue.items;
    final index = items.indexWhere((item) => item.id == widget.currentID);
    if (index < 0) return (null, items.firstOrNull);
    return (index > 0 ? items[index - 1] : null, index + 1 < items.length ? items[index + 1] : null);
  }

  void _animate(double to, {VoidCallback? then}) {
    _from = _drag;
    _to = to;
    _settle.forward(from: 0).whenCompleteOrCancel(() {
      then?.call();
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.queue,
    builder: (context, _) {
      final (previous, next) = _neighbors;
      final shown = next ?? previous;
      if (shown == null) return const SizedBox.shrink();
      return Semantics(
        customSemanticsActions: {
          if (next != null) CustomSemanticsAction(label: L10n.text('Next')): () => widget.open(next.id),
          if (previous != null) CustomSemanticsAction(label: L10n.text('Previous')): () => widget.open(previous.id),
        },
        child: GestureDetector(
          onHorizontalDragStart: (_) => _settle.stop(),
          onHorizontalDragUpdate: (details) {
            final allowed = (_drag + details.delta.dx) < 0 ? next != null : previous != null;
            // Resists past the ends, where there is no work to move to.
            setState(() => _drag += allowed ? details.delta.dx : details.delta.dx / 4);
          },
          onHorizontalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            final target = _drag < -60 || velocity < -700
                ? next
                : _drag > 60 || velocity > 700
                ? previous
                : null;
            if (target == null) {
              _animate(0);
              return;
            }
            HapticFeedback.lightImpact();
            final width = MediaQuery.sizeOf(context).width;
            _animate(
              _drag < 0 ? -width : width,
              then: () {
                if (!mounted) return;
                setState(() => _drag = 0);
                widget.open(target.id);
              },
            );
          },
          child: Transform.translate(
            offset: Offset(_drag, 0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: CupertinoTheme(
                data: CupertinoTheme.of(context).copyWith(brightness: Brightness.dark),
                child: ReadingQueueBar(queue: widget.queue, next: shown, read: widget.open, showList: widget.showList, dark: true),
              ),
            ),
          ),
        ),
      );
    },
  );
}
