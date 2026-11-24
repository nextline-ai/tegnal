import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../app/app_notice.dart';
import '../../core/addons/addon_market.dart';
import '../../core/lab/lab_course_file.dart';
import '../../core/lab/lab_goods.dart';
import '../../core/lab/lab_shop.dart';
import '../../core/lab/lab_store.dart';
import '../../core/lab/learning_courses.dart';
import '../../core/support/l10n.dart';
import '../design/app_sheet.dart';
import '../study_mode/study_kit.dart';
import 'lab_kit.dart';
import 'lab_pages.dart' show LabMarkdown, labDockClearance;
import 'lab_root.dart' show LabTab;

// The shop: the wallet, one item set apart, each section's cards, and an item's own page where it is bought.
// Ported from `LabShopViews.swift`.

// MARK: - Style

/// The shop's goods each have a colour ([LabShopItem.color], else their kind's) and a symbol, from which their art is drawn.
abstract final class LabShopStyle {
  static const kindColors = {'course': '6B4EFF', 'feature': '0A84FF', 'addon': '2F9E62', 'home': 'E8743B', 'ticket': 'C9971C'};

  static String hex(LabShopItem item) => item.color ?? kindColors[item.kind] ?? '636366';
  static Color color(LabShopItem item) => Color(0xFF000000 | (int.tryParse(hex(item), radix: 16) ?? 0x636366));

  /// The colour moved toward white (`amount` > 0) or black (< 0).
  static Color shade(String hex, double amount) {
    final value = int.tryParse(hex, radix: 16) ?? 0x636366;
    final target = amount > 0 ? 255.0 : 0.0, t = amount.abs();
    int channel(int shift) {
      final c = ((value >> shift) & 0xFF).toDouble();
      return (c + (target - c) * t).round();
    }

    return Color.fromARGB(255, channel(16), channel(8), channel(0));
  }

  /// The item's symbol, or a bag for a name this app does not draw.
  static String symbol(LabShopItem item) => StudyGlyph.knows(item.symbol ?? '') ? item.symbol! : 'bag';

  static String kind(LabShopItem item) => LabShopItem.kinds.contains(item.kind) ? L10n.text('lab.shop.kind.${item.kind}') : '';
}

const _gold = Color(0xFFFFD36B), _amber = Color(0xFFFFB02E), _deepAmber = Color(0xFFE08A00);

/// An item's art: its picture filling the frame when it has one ([LabShopItem.image]), else its colour as a deep gradient
/// under a soft light with its symbol large and glowing and a faint echo of it. Its size is the frame it is given.
class LabShopArt extends StatelessWidget {
  const LabShopArt({super.key, required this.item, this.symbolSize = 40, this.symbolShown = true});
  final LabShopItem item;
  final double symbolSize;

  /// Hidden while something stands in its place, such as the seal of a purchase.
  final bool symbolShown;

  @override
  Widget build(BuildContext context) {
    final hex = LabShopStyle.hex(item), symbol = LabShopStyle.symbol(item);
    final image = item.image;
    if (image != null) LabShopImages.shared.load(image);
    return ExcludeSemantics(
      child: ClipRect(
        child: ListenableBuilder(
          listenable: LabShopImages.shared,
          builder: (context, _) {
            final picture = image == null ? null : LabShopImages.shared.picture(image);
            return Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [LabShopStyle.shade(hex, 0.22), LabShopStyle.shade(hex, 0), LabShopStyle.shade(hex, -0.45)],
                    ),
                  ),
                ),
                if (picture != null)
                  Image.memory(picture, fit: BoxFit.cover, gaplessPlayback: true)
                else ...[
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(center: Alignment(-0.7, -0.9), radius: 1.1, colors: [Color(0x52FFFFFF), Color(0x00FFFFFF)]),
                    ),
                  ),
                  OverflowBox(
                    maxWidth: double.infinity,
                    maxHeight: double.infinity,
                    alignment: const Alignment(0.75, 0.6),
                    child: Transform.rotate(
                      angle: -14 * math.pi / 180,
                      child: StudyIcon(symbol, size: symbolSize * 2.6, color: const Color(0x17FFFFFF)),
                    ),
                  ),
                  Center(
                    child: AnimatedScale(
                      scale: symbolShown ? 1 : 0.6,
                      duration: const Duration(milliseconds: 350),
                      curve: Curves.easeOutBack,
                      child: AnimatedOpacity(
                        opacity: symbolShown ? 1 : 0,
                        duration: const Duration(milliseconds: 250),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [BoxShadow(color: const Color(0x1FFFFFFF), blurRadius: symbolSize, spreadRadius: -symbolSize * 0.15)],
                          ),
                          child: StudyIcon(symbol, size: symbolSize, color: const Color(0xFFFFFFFF)),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Pictures of shop items: downloaded once from TEGNAL's server, refused unless they match the list's size and SHA-256, and
/// kept in the cache folder by digest. Ported from `LabShopImages` in `LabShopViews.swift`.
class LabShopImages extends ChangeNotifier {
  LabShopImages({AddonMarket? market}) : market = market ?? AddonMarket.live;
  static final LabShopImages shared = LabShopImages();

  AddonMarket market;
  final Map<String, Uint8List> _pictures = {};
  final Set<String> _loading = {};

  /// `TEGNAL_LAB_GOODS`: a local folder laid out as the server is, for tests and screenshots.
  static const _local = String.fromEnvironment('TEGNAL_LAB_GOODS');

  Uint8List? picture(LabShopFile file) => _pictures[file.sha256];

  Future<void> load(LabShopFile file) async {
    if (_pictures.containsKey(file.sha256) || _loading.contains(file.sha256) || !file.valid) return;
    _loading.add(file.sha256);
    try {
      File? kept;
      try {
        kept = File('${(await getTemporaryDirectory()).path}/ShopImages/${file.sha256}');
        if (kept.existsSync()) {
          final data = await kept.readAsBytes();
          if (LabCourseFile.digest(data) == file.sha256) {
            _pictures[file.sha256] = data;
            notifyListeners();
            return;
          }
        }
      } on Object {
        kept = null;
      }
      final data = _local.isNotEmpty ? await File('$_local/${file.path}').readAsBytes() : await market.fetch(market.base.resolve(file.path), file.size);
      if (data.length != file.size || LabCourseFile.digest(data) != file.sha256) return;
      final bytes = Uint8List.fromList(data);
      try {
        await kept?.parent.create(recursive: true);
        await kept?.writeAsBytes(bytes, flush: true);
      } on Object {
        // Downloaded again next time.
      }
      _pictures[file.sha256] = bytes;
      notifyListeners();
    } on Object {
      // The colour and symbol stay.
    } finally {
      _loading.remove(file.sha256);
    }
  }
}

/// A price with the gem before it.
class LabPriceTag extends StatelessWidget {
  const LabPriceTag({super.key, required this.price, this.size = 15, this.color});
  final int price;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(CupertinoIcons.suit_diamond_fill, size: size * 0.8, color: LabPalette.gauge.resolveFrom(context)),
      const SizedBox(width: 4),
      Text('$price', style: LabFont.number(size, color: color ?? labLabel(context))),
    ],
  );
}

// MARK: - The shop

/// What the shop holds: the wallet, one item set apart, then each section's cards. Its own page in the lab; the foot of
/// the 연습 tab in the 2D AI course ([embedded]). The list comes from TEGNAL's server each time the shop is shown
/// (`LabShopSource`); until it does, the goods the app carries are for sale ([LabShop.builtIn]). A card opens the item's
/// page, where it is bought.
class LabShopView extends StatefulWidget {
  const LabShopView({super.key, required this.open, this.mode, this.embedded = false});

  /// Opens a course bought here, by its id (`StudyMode.open`).
  final void Function(String course) open;

  /// The mode that says which course is on screen; null is [StudyMode.shared].
  final StudyMode? mode;

  /// Only what the shop holds, without a page or scrolling of its own: the foot of the 2D AI course's Practice tab.
  final bool embedded;

  @override
  State<LabShopView> createState() => _LabShopViewState();
}

class _LabShopViewState extends State<LabShopView> with TickerProviderStateMixin {
  LabStore get store => LabStore.shared;
  LabGoods get goods => LabGoods.shared;
  late final _appear = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  late final _sheen = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void initState() {
    super.initState();
    _appear.forward();
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _sheen.forward();
    });
    store.refreshShop();
  }

  @override
  void dispose() {
    _appear.dispose();
    _sheen.dispose();
    super.dispose();
  }

  void _openItem(LabShopItem item) {
    LabHaptic.tick();
    showLabShopItem(context, item.id, open: widget.open, mode: widget.mode);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([store, goods, HomeScenes.chosenScene]),
    builder: (context, _) {
      final content = _content(context);
      if (widget.embedded) return Column(crossAxisAlignment: CrossAxisAlignment.start, children: content);
      return CustomScrollView(
        slivers: [
          SliverSafeArea(
            bottom: false,
            sliver: SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, labDockClearance),
              sliver: SliverList.list(
                children: [
                  LabHeader(
                    kicker: TextSpan(text: L10n.text('lab.shop.subtitle')),
                    title: L10n.text('lab.tab.shop'),
                  ),
                  const SizedBox(height: 22),
                  ...content,
                ],
              ),
            ),
          ),
        ],
      );
    },
  );

  List<Widget> _content(BuildContext context) {
    var index = 0;
    return [
      _wallet(context),
      ?_status(context),
      for (final section in store.shop.sections) ...[
        const SizedBox(height: 26),
        Semantics(
          header: true,
          child: Text(
            section.title.text,
            style: LabFont.text(22, weight: FontWeight.w700, color: labLabel(context)),
          ),
        ),
        const SizedBox(height: 12),
        // A grid of two, each row as tall as its taller card: a title on two lines makes room in its row rather than every
        // card keeping an empty second line.
        for (var row = 0; row < section.items.length; row += 2)
          Padding(
            padding: EdgeInsets.only(top: row == 0 ? 0 : 12),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _appearing(index++, _card(context, section.items[row]))),
                  const SizedBox(width: 12),
                  Expanded(child: row + 1 < section.items.length ? _appearing(index++, _card(context, section.items[row + 1])) : const SizedBox.shrink()),
                ],
              ),
            ),
          ),
      ],
    ];
  }

  /// Cards rise into place one after another the first time the shop is shown.
  Widget _appearing(int index, Widget child) {
    final start = math.min(0.6, index * 0.06);
    final curve = CurvedAnimation(
      parent: _appear,
      curve: Interval(start, math.min(1, start + 0.45), curve: Curves.easeOutCubic),
    );
    return AnimatedBuilder(
      animation: curve,
      child: child,
      builder: (context, child) => Opacity(
        opacity: curve.value,
        child: Transform.translate(offset: Offset(0, 16 * (1 - curve.value)), child: child),
      ),
    );
  }

  // MARK: Wallet

  /// The balance as the shop's front: a dark vault lit by its gem, with the next thing within reach.
  Widget _wallet(BuildContext context) {
    final goal = _goal;
    return Semantics(
      container: true,
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(26),
        child: Container(
          key: const Key('lab.shop.wallet'),
          decoration: const BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topRight, end: Alignment.bottomLeft, colors: [Color(0xFF2A2118), Color(0xFF141416)]),
          ),
          child: Stack(
            children: [
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(center: Alignment.topRight, radius: 1.2, colors: [Color(0x59FFB02E), Color(0x00FFB02E)]),
                  ),
                ),
              ),
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _sheen,
                  builder: (context, _) => LabSheen(progress: _sheen.value),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 54,
                          height: 54,
                          decoration: ShapeDecoration(
                            gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [_gold, _deepAmber]),
                            shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(16)),
                            shadows: const [BoxShadow(color: Color(0x73FFB02E), blurRadius: 14, offset: Offset(0, 4))],
                          ),
                          child: const Icon(CupertinoIcons.suit_diamond_fill, size: 28, color: Color(0xFFFFFFFF)),
                        ),
                        const SizedBox(width: 14),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              store.shop.currency.text,
                              style: LabFont.text(13, weight: FontWeight.w700, color: const Color(0xA6FFFFFF), tracking: 1.2),
                            ),
                            TweenAnimationBuilder<double>(
                              tween: Tween(end: store.balance.toDouble()),
                              duration: const Duration(milliseconds: 500),
                              builder: (context, value, _) => Text(
                                '${value.round()}',
                                key: const Key('lab.shop.balance'),
                                style: LabFont.number(40, color: const Color(0xFFFFFFFF)),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    if (goal != null) ...[const SizedBox(height: 16), _progress(context, goal)],
                    if (store.shop.note case final note?) ...[
                      const SizedBox(height: 16),
                      Text(note.text, style: LabFont.text(12, color: const Color(0x8CFFFFFF))),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The cheapest thing on sale that is not owned yet and needs nothing else first.
  LabShopItem? get _goal {
    final goods = store.shop.items.where(
      (item) =>
          item.supported &&
          !item.isRepeat &&
          !item.isSoon &&
          item.price != null &&
          !store.owns(item.id) &&
          (item.requires == null || store.owns(item.requires!)),
    );
    return goods.isEmpty ? null : goods.reduce((a, b) => (a.price ?? 0) <= (b.price ?? 0) ? a : b);
  }

  Widget _progress(BuildContext context, LabShopItem item) {
    final price = math.max(1, item.price ?? 1), ready = store.balance >= price;
    final pass = LabPalette.pass.darkColor;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openItem(item),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${L10n.text('lab.gems.next')}  ',
                        style: const TextStyle(color: Color(0xA6FFFFFF)),
                      ),
                      TextSpan(text: item.name.text),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: LabFont.text(13, weight: FontWeight.w600, color: const Color(0xFFFFFFFF)),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                ready ? L10n.text('lab.gems.ready') : L10n.text('lab.gems.left', ['${price - store.balance}']),
                maxLines: 1,
                style: LabFont.text(13, weight: FontWeight.w600, color: ready ? pass : const Color(0xA6FFFFFF)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) => Stack(
              children: [
                Container(
                  height: 7,
                  decoration: const ShapeDecoration(color: Color(0x1FFFFFFF), shape: StadiumBorder()),
                ),
                Container(
                  height: 7,
                  width: constraints.maxWidth * math.min(1, store.balance / price),
                  decoration: ShapeDecoration(
                    gradient: LinearGradient(colors: [_gold, ready ? pass : _amber]),
                    shape: const StadiumBorder(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // MARK: Status

  Widget? _status(BuildContext context) => switch (store.shopState) {
    LabShopState.ready => null,
    LabShopState.loading => Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Row(
        children: [
          const CupertinoActivityIndicator(radius: 8),
          const SizedBox(width: 8),
          Text(L10n.text('lab.shop.loading'), style: LabFont.text(13, color: labSecondary(context))),
        ],
      ),
    ),
    LabShopState.failed => _notice(
      context,
      'lab.shop.failed',
      CupertinoIcons.wifi_slash,
      L10n.text('lab.shop.offline'),
      L10n.text('Try Again'),
      store.refreshShop,
    ),
    LabShopState.newer => _notice(
      context,
      'lab.shop.newer',
      CupertinoIcons.arrow_down_circle,
      L10n.text('lab.shop.newer'),
      L10n.text('notice.update'),
      openAppStore,
    ),
  };

  Widget _notice(BuildContext context, String id, IconData icon, String text, String button, VoidCallback action) => Padding(
    key: Key(id),
    padding: const EdgeInsets.only(top: 16),
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: ShapeDecoration(
        color: LabPalette.surface(context),
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(18)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: labSecondary(context)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: LabFont.text(13, color: labSecondary(context))),
          ),
          const SizedBox(width: 8),
          _small(context, button, Key('$id.action'), action),
        ],
      ),
    ),
  );

  // MARK: Cards

  /// One thing for sale: its art with the price (or the thing to do with it) at its top right and a lock or a limited-sale tag
  /// at its top left, then its kind, name and one line of where it stands. A tap opens its page.
  Widget _card(BuildContext context, LabShopItem item) {
    final state = store.canBuy(item);
    final owned = store.owns(item.id) && !item.isRepeat;
    final dimmed = item.isSoon || state == LabBuyResult.update;
    final failure = goods.failures[item.id];
    return Opacity(
      key: Key('lab.shop.item.${item.id}'),
      opacity: dimmed ? 0.7 : 1,
      child: LabPress(
        label: item.name.text,
        onTap: () => _openItem(item),
        child: ClipRSuperellipse(
          borderRadius: BorderRadius.circular(22),
          child: ColoredBox(
            color: LabPalette.surface(context),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 112,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColorFiltered(
                        colorFilter: dimmed ? const ColorFilter.matrix(_desaturate) : const ColorFilter.mode(Color(0x00000000), BlendMode.dst),
                        child: LabShopArt(item: item, symbolSize: 34),
                      ),
                      Positioned(
                        left: 9,
                        top: 9,
                        child: Row(
                          children: [
                            // Something kept for good once bought, not bought yet.
                            if (!owned && !item.isRepeat)
                              Container(
                                key: Key('lab.shop.lock.${item.id}'),
                                width: 26,
                                height: 26,
                                margin: const EdgeInsets.only(right: 6),
                                decoration: const BoxDecoration(color: Color(0x59000000), shape: BoxShape.circle),
                                child: Semantics(
                                  label: L10n.text('lab.shop.locked'),
                                  child: const Icon(CupertinoIcons.lock_fill, size: 13, color: Color(0xFFFFFFFF)),
                                ),
                              ),
                            if (item.isLimited)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                decoration: const ShapeDecoration(color: LabPalette.paper, shape: StadiumBorder()),
                                child: Text(
                                  L10n.text('lab.shop.limited'),
                                  style: LabFont.text(10, weight: FontWeight.w800, color: LabPalette.paperInk),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Positioned(right: 9, top: 9, child: _corner(context, item, state, owned)),
                      if (_shortBar(context, item, state) case final bar?) Positioned(left: 0, right: 0, bottom: 0, child: bar),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        LabShopStyle.kind(item).toUpperCase(),
                        style: LabFont.text(10, weight: FontWeight.w800, color: LabShopStyle.color(item), tracking: 1),
                      ),
                      Text(
                        item.name.text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: LabFont.text(16, weight: FontWeight.w700, color: labLabel(context)),
                      ),
                      Text(
                        _note(item, state, owned),
                        key: Key('lab.shop.note.${item.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: LabFont.text(12, color: failure == null ? labSecondary(context) : CupertinoColors.systemRed.resolveFrom(context)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static const _desaturate = <double>[
    0.36, 0.57, 0.07, 0, 0, //
    0.17, 0.76, 0.07, 0, 0,
    0.17, 0.57, 0.26, 0, 0,
    0, 0, 0, 1, 0,
  ];

  String _note(LabShopItem item, LabBuyResult state, bool owned) {
    if (goods.failures[item.id] case final failure?) return failure;
    if (state == LabBuyResult.update) return L10n.text('lab.shop.update');
    if (owned) {
      if (goods.working.contains(item.id)) return L10n.text('lab.shop.downloading');
      if (item.downloads && !goods.delivered(item)) return L10n.text(goods.outdated(item) ? 'lab.shop.newVersion' : 'lab.shop.notHere');
      if (item.home != null && HomeScenes.chosen == item.id) return L10n.text('lab.shop.inUse');
      return L10n.text('lab.shop.owned');
    }
    if (item.isSoon) return L10n.text('lab.shop.soon');
    if (state.kind == 'needs') return L10n.text('lab.shop.needs', [store.shop.item(state.needed!)?.name.text ?? state.needed!]);
    if (item.kind == 'ticket' && store.tickets > 0) return L10n.text('lab.shop.tickets', ['${store.tickets}']);
    return item.summary?.text ?? '';
  }

  /// The art's top right: the price with its gem, or once owned the thing to do with it, or a check.
  Widget _corner(BuildContext context, LabShopItem item, LabBuyResult state, bool owned) {
    if (state == LabBuyResult.update) return _action(L10n.text('notice.update'), Key('lab.shop.update.${item.id}'), openAppStore);
    if (owned && goods.working.contains(item.id)) {
      return Container(
        width: 30,
        height: 30,
        decoration: const BoxDecoration(color: Color(0x59000000), shape: BoxShape.circle),
        child: const CupertinoActivityIndicator(color: Color(0xFFFFFFFF), radius: 8),
      );
    }
    if (owned && item.downloads && !goods.delivered(item)) {
      return _action(L10n.text(goods.outdated(item) ? 'lab.shop.getUpdate' : 'lab.shop.get'), Key('lab.shop.get.${item.id}'), () => goods.deliver(item));
    }
    if (owned && item.home != null) {
      final using = HomeScenes.chosen == item.id;
      return _action(
        L10n.text(using ? 'lab.shop.useDefault' : 'lab.shop.use'),
        Key('lab.shop.use.${item.id}'),
        () => HomeScenes.choose(using ? null : item.id),
      );
    }
    final course = LearningCourses.shared.all.where((course) => course.item == item.id).firstOrNull;
    if (owned && course != null && (widget.mode ?? StudyMode.shared).courseID != course.id) {
      return _action(L10n.text('lab.shop.open'), Key('lab.shop.open.${item.id}'), () => widget.open(course.id));
    }
    if (owned) {
      return Container(
        decoration: const BoxDecoration(color: Color(0xFFFFFFFF), shape: BoxShape.circle),
        child: Semantics(
          label: L10n.text('lab.shop.ownedShort'),
          child: Icon(CupertinoIcons.checkmark_circle_fill, size: 24, color: LabPalette.pass.resolveFrom(context)),
        ),
      );
    }
    final price = item.price;
    if (price == null) return const SizedBox.shrink();
    final ready = state.isBought;
    return Container(
      key: Key('lab.shop.price.${item.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: ShapeDecoration(color: ready ? const Color(0xFFFFFFFF) : const Color(0x61000000), shape: const StadiumBorder()),
      child: LabPriceTag(price: price, size: 14, color: ready ? const Color(0xFF000000) : const Color(0xFFFFFFFF)),
    );
  }

  /// How far the balance has come toward an item not affordable yet, as a thin line along the art's foot.
  Widget? _shortBar(BuildContext context, LabShopItem item, LabBuyResult state) {
    final price = item.price;
    if (state.kind != 'short' || item.isSoon || price == null) return null;
    return SizedBox(
      height: 4,
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Color(0x4D000000))),
            SizedBox(
              width: constraints.maxWidth * math.min(1, store.balance / math.max(price, 1)),
              child: ColoredBox(color: LabPalette.gauge.resolveFrom(context)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _small(BuildContext context, String title, Key key, VoidCallback onPressed) => LabButton(
    key: key,
    onPressed: onPressed,
    radius: null,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
    child: Text(
      title,
      style: LabFont.text(14, weight: FontWeight.w600, color: labLabel(context)),
    ),
  );

  Widget _action(String title, Key key, VoidCallback onPressed) => GestureDetector(
    key: key,
    onTap: onPressed,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const ShapeDecoration(color: Color(0xFFFFFFFF), shape: StadiumBorder()),
      child: Text(
        title,
        style: LabFont.text(13, weight: FontWeight.w700, color: const Color(0xFF000000)),
      ),
    ),
  );
}

// MARK: - An item's page

/// Opens an item's page as a sheet. Image mode opens the prompt analyzer's page by pushing [LabShopItemPage] instead.
Future<void> showLabShopItem(BuildContext context, String itemID, {void Function(String course)? open, StudyMode? mode}) => showAppSheet<void>(
  context,
  builder: (context, controller) => LabShopItemPage(itemID: itemID, controller: controller, open: open, mode: mode),
);

/// One item's page: its art large, what it is, and the one thing to do now — buy it, see what it needs first, or use it once
/// owned. Buying happens here, so the page is the confirmation; what is left afterwards is shown under the button. A purchase
/// is met with the art lighting up, gems bursting from a seal, and the next thing to do. Image mode pushes the prompt
/// analyzer's page from a picture ([outside], [pushed]), where what is missing leads to learning mode.
class LabShopItemPage extends StatefulWidget {
  const LabShopItemPage({super.key, required this.itemID, this.controller, this.outside = false, this.pushed = false, this.onOpen, this.open, this.mode});
  final String itemID;
  final ScrollController? controller;
  final bool outside;
  final bool pushed;

  /// What "open" does once a feature is bought, such as showing the prompt analyzer in place of this page.
  final VoidCallback? onOpen;
  final void Function(String course)? open;
  final StudyMode? mode;

  @override
  State<LabShopItemPage> createState() => _LabShopItemPageState();
}

class _LabShopItemPageState extends State<LabShopItemPage> with TickerProviderStateMixin {
  LabStore get store => LabStore.shared;
  LabGoods get goods => LabGoods.shared;
  late String _itemID = widget.itemID;
  bool _celebrated = false;
  late final _sheen = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  late final _burst = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    store.refreshShop();
  }

  @override
  void dispose() {
    _sheen.dispose();
    _burst.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).maybePop();

  void _buy(LabShopItem item) {
    if (!store.buy(item).isBought) return;
    LabHaptic.pass();
    setState(() => _celebrated = true);
    _sheen.forward(from: 0);
    _burst.forward(from: 0);
    if (item.downloads) goods.deliver(item);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([store, goods, HomeScenes.chosenScene]),
    builder: (context, _) {
      final item = store.shop.item(_itemID);
      final body = ColoredBox(
        color: CupertinoColors.systemGroupedBackground.resolveFrom(context),
        child: item == null
            ? Center(
                child: Text(L10n.text('lab.shop.failed'), style: LabFont.text(15, color: labSecondary(context))),
              )
            : Column(
                children: [
                  Expanded(child: _page(context, item)),
                  _actionBar(context, item),
                ],
              ),
      );
      if (widget.pushed) {
        return CupertinoPageScaffold(
          navigationBar: CupertinoNavigationBar(previousPageTitle: L10n.text('Details')),
          child: SafeArea(child: body),
        );
      }
      return body;
    },
  );

  Widget _page(BuildContext context, LabShopItem item) {
    final color = LabShopStyle.color(item);
    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      children: [
        if (!widget.pushed)
          Align(
            alignment: Alignment.centerLeft,
            child: CupertinoButton(padding: EdgeInsets.zero, onPressed: _close, child: Text(L10n.text('Close'))),
          ),
        AnimatedScale(
          scale: _celebrated ? 1.02 : 1,
          duration: const Duration(milliseconds: 500),
          curve: Curves.elasticOut,
          child: Container(
            height: 250,
            decoration: ShapeDecoration(
              shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(28)),
              shadows: [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 20, offset: const Offset(0, 10))],
            ),
            child: ClipRSuperellipse(
              borderRadius: BorderRadius.circular(28),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  LabShopArt(item: item, symbolSize: 80, symbolShown: !_celebrated),
                  if (_celebrated) _LabShopBurst(animation: _burst, color: color),
                  AnimatedBuilder(
                    animation: _sheen,
                    builder: (context, _) => LabSheen(progress: _sheen.value),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Text(
          LabShopStyle.kind(item).toUpperCase(),
          style: LabFont.text(12, weight: FontWeight.w800, color: color, tracking: 1.2),
        ),
        const SizedBox(height: 4),
        Text(
          item.name.text,
          key: Key('lab.shop.page.${item.id}'),
          style: LabFont.voice(30, color: labLabel(context)),
        ),
        if (item.summary case final summary?) ...[const SizedBox(height: 4), Text(summary.text, style: LabFont.text(17, color: labSecondary(context)))],
        const SizedBox(height: 14),
        Wrap(spacing: 8, runSpacing: 8, children: _chips(context, item)),
        if (item.detail case final detail? when !detail.isEmpty) ...[
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: ShapeDecoration(
              color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context),
              shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(20)),
            ),
            child: LabMarkdown(text: detail.text),
          ),
        ],
      ],
    );
  }

  List<Widget> _chips(BuildContext context, LabShopItem item) {
    final required = item.requires == null || store.owns(item.requires!) ? null : store.shop.item(item.requires!);
    final labels = <(IconData, String)>[
      if (item.isLimited) (CupertinoIcons.clock, L10n.text('lab.shop.limited')),
      if (item.isRepeat) (CupertinoIcons.arrow_2_circlepath, L10n.text('lab.shop.repeat')),
      if (required != null) (CupertinoIcons.lock, L10n.text('lab.shop.needsFirst', [required.name.text])),
    ];
    return [
      for (final (icon, text) in labels)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: ShapeDecoration(color: LabPalette.surface(context, 1), shape: const StadiumBorder()),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: labSecondary(context)),
              const SizedBox(width: 5),
              Text(
                text,
                style: LabFont.text(12, weight: FontWeight.w600, color: labSecondary(context)),
              ),
            ],
          ),
        ),
    ];
  }

  // MARK: The one thing to do

  Widget _actionBar(BuildContext context, LabShopItem item) => Container(
    width: double.infinity,
    padding: EdgeInsets.fromLTRB(20, 14, 20, 8 + (widget.pushed ? 0 : MediaQuery.paddingOf(context).bottom)),
    decoration: BoxDecoration(
      color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context).withValues(alpha: 0.94),
      border: Border(top: BorderSide(color: CupertinoColors.separator.resolveFrom(context), width: 0.5)),
    ),
    child: Column(mainAxisSize: MainAxisSize.min, children: _actions(context, item)),
  );

  Widget _caption(BuildContext context, String text, {Color? color}) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: LabFont.text(12, color: color ?? labSecondary(context)),
    ),
  );

  Widget _wide(BuildContext context, String title, Key key, VoidCallback? onPressed, {bool prominent = true}) => LabButton(
    key: key,
    expand: true,
    style: prominent ? LabButtonStyle.primary : LabButtonStyle.secondary,
    onPressed: onPressed,
    child: Text(
      title,
      style: LabFont.text(17, weight: FontWeight.w700, color: prominent ? LabPalette.onPrimary.resolveFrom(context) : labLabel(context)),
    ),
  );

  List<Widget> _actions(BuildContext context, LabShopItem item) {
    final state = store.canBuy(item);
    final owned = store.owns(item.id) && !item.isRepeat;
    if (_celebrated || owned) {
      return [
        if (_celebrated)
          Padding(
            key: const Key('lab.shop.bought'),
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(CupertinoIcons.checkmark_seal_fill, size: 18, color: LabPalette.pass.resolveFrom(context)),
                const SizedBox(width: 6),
                Text(
                  L10n.text('lab.shop.bought'),
                  style: LabFont.text(15, weight: FontWeight.w700, color: LabPalette.pass.resolveFrom(context)),
                ),
              ],
            ),
          ),
        ..._ownedActions(context, item),
      ];
    }
    switch (state.kind) {
      case 'bought':
        final price = item.price ?? 0;
        return [
          _wide(context, L10n.text('lab.shop.buy', ['$price']), Key('lab.shop.buy.${item.id}'), () => _buy(item)),
          _caption(context, L10n.text('lab.shop.after', ['${store.balance - price}'])),
        ];
      case 'short':
        final price = math.max(1, item.price ?? 1);
        return [
          Row(
            children: [
              LabPriceTag(price: price),
              const Spacer(),
              Text('${store.balance} / $price', style: LabFont.number(13, color: labSecondary(context))),
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) => Stack(
              children: [
                Container(
                  height: 5,
                  decoration: ShapeDecoration(color: LabPalette.surface(context, 2), shape: const StadiumBorder()),
                ),
                Container(
                  height: 5,
                  width: constraints.maxWidth * math.min(1, store.balance / price),
                  decoration: ShapeDecoration(color: LabPalette.gauge.resolveFrom(context), shape: const StadiumBorder()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (widget.outside) ...[
            _wide(context, L10n.text('prompt.offer.learn'), const Key('prompt.offer.learn'), () {
              _close();
              StudyMode.shared.enterLab(LabTab.deck);
            }, prominent: false),
            _caption(context, L10n.text('prompt.offer.short', ['${state.short}'])),
          ] else ...[
            _wide(context, L10n.text('lab.shop.shortButton', ['${state.short}']), Key('lab.shop.short.${item.id}'), null, prominent: false),
            _caption(context, L10n.text('lab.shop.earnMore')),
          ],
        ];
      case 'needs':
        final needed = store.shop.item(state.needed!);
        final name = needed?.name.text ?? state.needed!;
        return [
          _wide(
            context,
            L10n.text('lab.shop.see', [name]),
            Key('lab.shop.see.${state.needed}'),
            () => setState(() => _itemID = state.needed!),
            prominent: false,
          ),
          _caption(context, L10n.text('lab.shop.needsFirst', [name])),
        ];
      case 'update':
        return [_wide(context, L10n.text('notice.update'), Key('lab.shop.update.${item.id}'), openAppStore), _caption(context, L10n.text('lab.shop.update'))];
      default:
        return [_wide(context, L10n.text('lab.shop.soon'), Key('lab.shop.soon.${item.id}'), null, prominent: false)];
    }
  }

  List<Widget> _ownedActions(BuildContext context, LabShopItem item) {
    if (goods.working.contains(item.id)) return const [SizedBox(height: 50, child: Center(child: CupertinoActivityIndicator()))];
    if (item.downloads && !goods.delivered(item)) {
      return [
        if (goods.failures[item.id] case final failure?) _caption(context, failure, color: CupertinoColors.systemRed.resolveFrom(context)),
        _wide(context, L10n.text(goods.outdated(item) ? 'lab.shop.getUpdate' : 'lab.shop.get'), Key('lab.shop.get.${item.id}'), () => goods.deliver(item)),
      ];
    }
    if (item.home != null) {
      final using = HomeScenes.chosen == item.id;
      return [
        _wide(
          context,
          L10n.text(using ? 'lab.shop.useDefault' : 'lab.shop.use'),
          Key('lab.shop.use.${item.id}'),
          () => HomeScenes.choose(using ? null : item.id),
          prominent: !using,
        ),
      ];
    }
    final course = LearningCourses.shared.all.where((course) => course.item == item.id).firstOrNull;
    final mode = widget.mode ?? StudyMode.shared;
    if (course != null && (mode.courseID != course.id || widget.outside)) {
      return [
        _wide(context, L10n.text('lab.shop.open'), Key('lab.shop.open.${item.id}'), () {
          _close();
          if (widget.outside) StudyMode.shared.enterLab(LabTab.courses);
          (widget.open ?? mode.open)(course.id);
        }),
      ];
    }
    if (widget.onOpen case final onOpen?) return [_wide(context, L10n.text('lab.shop.open'), Key('lab.shop.open.${item.id}'), onOpen)];
    return [
      _wide(context, L10n.text('OK'), Key('lab.shop.done.${item.id}'), _close),
      _caption(context, L10n.text(item.feature == LabFeature.promptAnalyzer.id ? 'prompt.offer.bought' : 'lab.shop.owned')),
    ];
  }
}

/// Gems bursting from the middle of an item's art when it is bought, around a seal that springs in.
class _LabShopBurst extends StatelessWidget {
  const _LabShopBurst({required this.animation, required this.color});
  final Animation<double> animation;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, _) {
          final t = reduce ? 1.0 : Curves.easeOutCubic.transform(animation.value);
          final seal = reduce ? 1.0 : Curves.elasticOut.transform(math.min(1, animation.value * 1.4));
          return Stack(
            alignment: Alignment.center,
            children: [
              if (!reduce)
                for (var index = 0; index < 14; index++)
                  Builder(
                    builder: (context) {
                      final angle = index / 14 * 2 * math.pi + (index.isEven ? 0.2 : 0);
                      final distance = index % 3 == 0 ? 120.0 : 92.0;
                      return Transform.translate(
                        offset: Offset(math.cos(angle) * distance * t, math.sin(angle) * distance * t),
                        child: Opacity(
                          opacity: 1 - t,
                          child: Transform.scale(
                            scale: 0.3 + 0.9 * t,
                            child: Icon(
                              CupertinoIcons.suit_diamond_fill,
                              size: index.isEven ? 14 : 10,
                              color: index % 3 == 0 ? _gold : const Color(0xFFFFFFFF),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
              Transform.scale(
                scale: 0.3 + 0.7 * seal,
                child: Opacity(
                  opacity: math.min(1, t * 2),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      const Icon(CupertinoIcons.circle_fill, size: 40, color: Color(0xFFFFFFFF)),
                      Icon(CupertinoIcons.checkmark_seal_fill, size: 64, color: color),
                    ],
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
