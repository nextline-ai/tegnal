import 'dart:convert';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/addons/addon_market.dart';
import '../core/lab/lab_course.dart';
import '../core/lab/lab_shop.dart';
import '../core/support/l10n.dart';

/// A notice TEGNAL can publish to ask older copies of the app to update (`v1/app/notice.json`, signed with the add-on key).
/// It applies to builds below the number given for this platform. Ported from `AppNotice.swift`; format in
/// `docs/features/live-shop.md` §3.
class AppNotice {
  const AppNotice({required this.id, required this.level, required this.title, required this.message, this.ios, this.android});

  static const format = 'tegnal-app-notice';
  static const schemaVersion = 1;
  static const maximumBytes = 64 * 1024;
  static final url = AddonMarket.liveBase.resolve('app/notice.json');

  /// Where the app is sold, for a notice that names no address.
  static const storeURL = 'https://play.google.com/store/apps/details?id=work.nextline.tegnal';

  final String id;

  /// `required`: cannot be closed. `recommended`: can be put off; the same notice is not shown again once put off.
  final AppNoticeLevel level;
  final LabText title;
  final LabText message;
  final AppNoticePlatform? ios;
  final AppNoticePlatform? android;

  /// True when this build is old enough for the notice.
  bool appliesTo(int build) => build < (android?.below ?? 0);
  String get store {
    final url = android?.url;
    return url != null && url.startsWith('https://') ? url : storeURL;
  }

  AppNotice copyWith({String? id, AppNoticeLevel? level, AppNoticePlatform? android, bool noAndroid = false}) => AppNotice(
    id: id ?? this.id,
    level: level ?? this.level,
    title: title,
    message: message,
    ios: ios,
    android: noAndroid ? null : android ?? this.android,
  );

  static AppNotice decode(List<int> data) {
    try {
      final top = jsonDecode(utf8.decode(data));
      if (top is! Map || top['format'] != format || top['schemaVersion'] is! int) throw LabShopError.invalid;
      final schema = top['schemaVersion'] as int;
      final id = top['id'];
      final level = AppNoticeLevel.values.where((level) => level.name == top['level']).firstOrNull;
      if (schema < 1 || schema > schemaVersion || id is! String || id.isEmpty || id.length > 64 || level == null) throw LabShopError.invalid;
      return AppNotice(
        id: id,
        level: level,
        title: LabText.parse(top['title']),
        message: LabText.parse(top['message']),
        ios: AppNoticePlatform.parse(top['ios']),
        android: AppNoticePlatform.parse(top['android']),
      );
    } on LabShopError {
      rethrow;
    } on Object {
      throw LabShopError.invalid;
    }
  }

  @override
  bool operator ==(Object other) => other is AppNotice && other.id == id && other.level == level && other.android?.below == android?.below;
  @override
  int get hashCode => Object.hash(id, level, android?.below);
}

enum AppNoticeLevel { required, recommended }

class AppNoticePlatform {
  const AppNoticePlatform({required this.below, this.url});

  /// Builds below this number see the notice.
  final int below;
  final String? url;

  static AppNoticePlatform? parse(Object? json) {
    if (json is! Map || json['below'] is! int) return null;
    return AppNoticePlatform(below: json['below'] as int, url: json['url'] is String ? json['url'] as String : null);
  }
}

/// Reads TEGNAL's update notice when the app opens or comes back, at most once an hour, and holds the one to show.
class AppNotices extends ChangeNotifier {
  AppNotices({this.build = 0, Future<List<int>> Function()? fetch, this.putOffStore})
    : _fetch = fetch ?? (() => AddonMarket.live.fetch(AppNotice.url, AppNotice.maximumBytes * 2));

  static final AppNotices shared = AppNotices();

  /// Fixture runs never reach the network; `TEGNAL_APP_NOTICE=required|recommended` shows a sample notice.
  static const _fixture = String.fromEnvironment('TEGNAL_FIXTURE');
  static const _sample = String.fromEnvironment('TEGNAL_APP_NOTICE');

  /// The installed build number (Android's `versionCode`), set when the app starts.
  int build;
  final Future<List<int>> Function() _fetch;

  /// Remembers which notice was put off. Set when the app starts; kept in memory without it.
  ({String? Function() read, void Function(String) write})? putOffStore;
  String? _putOff;

  /// The notice to show now, if any.
  AppNotice? current;

  /// The last notice read, shown or not. The shop's "update the app" button uses its store address.
  AppNotice? latest;
  DateTime? _checked;

  String get storeURL => latest?.store ?? AppNotice.storeURL;

  Future<void> check({bool force = false}) async {
    final level = AppNoticeLevel.values.where((level) => level.name == _sample).firstOrNull;
    if (level != null) {
      return show(
        AppNotice(
          id: 'test',
          level: level,
          title: const LabText({'ko': '업데이트가 필요합니다', 'en': 'Update Required'}),
          message: const LabText({'ko': '테스트 알림입니다.', 'en': 'This is a test notice.'}),
          android: const AppNoticePlatform(below: 1 << 31),
        ),
      );
    }
    if (_fixture.isNotEmpty) return;
    final checked = _checked;
    if (!force && checked != null && DateTime.now().difference(checked) < const Duration(hours: 1)) return;
    _checked = DateTime.now();
    try {
      final payload = LabSigned.payload(await _fetch(), AddonMarket.live.publicKey, AppNotice.maximumBytes);
      show(AppNotice.decode(payload));
    } on Object {
      // No notice, or one that is not TEGNAL's: nothing to show.
    }
  }

  /// Takes a notice read and decides whether it is shown.
  void show(AppNotice notice) {
    latest = notice;
    final putOff = putOffStore?.read() ?? _putOff;
    if (!notice.appliesTo(build) || (notice.level == AppNoticeLevel.recommended && putOff == notice.id)) {
      current = null;
    } else {
      current = notice;
    }
    notifyListeners();
  }

  /// "Later" on a recommended notice: that notice is not shown again.
  void putOff() {
    final current = this.current;
    if (current == null || current.level != AppNoticeLevel.recommended) return;
    _putOff = current.id;
    putOffStore?.write(current.id);
    this.current = null;
    notifyListeners();
  }
}

/// Opens the app's page in the store: the address TEGNAL's last notice gave, else Google Play.
void openAppStore() => launchUrl(Uri.parse(AppNotices.shared.storeURL), mode: LaunchMode.externalApplication);

/// Shows TEGNAL's update notice over the whole app: a recommended one as an alert, a required one as a screen that stays.
class AppNoticeGate extends StatefulWidget {
  // ignore: prefer_initializing_formals
  const AppNoticeGate({super.key, required this.child, AppNotices? notices}) : _notices = notices;
  final Widget child;
  final AppNotices? _notices;

  @override
  State<AppNoticeGate> createState() => _AppNoticeGateState();
}

class _AppNoticeGateState extends State<AppNoticeGate> with WidgetsBindingObserver {
  AppNotices get notices => widget._notices ?? AppNotices.shared;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    notices.addListener(_changed);
    notices.check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    notices.removeListener(_changed);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) notices.check();
  }

  void _changed() => setState(() {});

  void _update() => launchUrl(Uri.parse(notices.storeURL), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final notice = notices.current;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (notice != null && notice.level == AppNoticeLevel.required)
          PopScope(canPop: false, child: AppNoticeScreen(notice: notice, update: _update))
        else if (notice != null)
          ColoredBox(
            color: const Color(0x66000000),
            child: Center(
              child: CupertinoAlertDialog(
                key: const Key('notice.alert'),
                title: Text(notice.title.text),
                content: Text(notice.message.text),
                actions: [
                  CupertinoDialogAction(onPressed: notices.putOff, child: Text(L10n.text('notice.later'))),
                  CupertinoDialogAction(
                    isDefaultAction: true,
                    onPressed: () {
                      _update();
                      notices.putOff();
                    },
                    child: Text(L10n.text('notice.update')),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// The screen a required update leaves: what happened, and the one way on.
class AppNoticeScreen extends StatelessWidget {
  const AppNoticeScreen({super.key, required this.notice, required this.update});
  final AppNotice notice;
  final VoidCallback update;

  @override
  Widget build(BuildContext context) {
    final tint = CupertinoTheme.of(context).primaryColor;
    return ColoredBox(
      color: CupertinoColors.systemBackground.resolveFrom(context),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
          child: Column(
            children: [
              const Spacer(),
              Icon(CupertinoIcons.arrow_down_circle_fill, size: 64, color: tint),
              const SizedBox(height: 18),
              Text(
                notice.title.text,
                key: const Key('notice.title'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700).copyWith(color: CupertinoColors.label.resolveFrom(context)),
              ),
              const SizedBox(height: 12),
              Text(
                notice.message.text,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 17, color: CupertinoColors.secondaryLabel.resolveFrom(context)),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: CupertinoButton.filled(
                  key: const Key('notice.update'),
                  borderRadius: BorderRadius.circular(28),
                  onPressed: update,
                  child: Text(L10n.text('notice.update'), style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
