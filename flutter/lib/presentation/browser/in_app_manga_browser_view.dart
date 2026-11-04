import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/content/gallery_content.dart';
import '../../core/content/manga_urls.dart';
import '../../core/support/l10n.dart';
import '../content/gallery_detail_view.dart' show ContentFailure;
import '../design/app_sheet.dart';
import '../design/context_menu.dart';
import '../design/glass.dart';
import '../design/pull_down_menu.dart' show anchorRectOf;
import '../design/tegnal_theme.dart';
import '../navigation/app_header.dart';
import '../navigation/app_state.dart';
import '../navigation/root_tab_view.dart';

/// Which addresses the website fallback opens (`EmbeddedBrowserModel.allows`).
abstract final class EmbeddedBrowserPolicy {
  /// Web pages only, never an address that carries credentials.
  static bool allows(Uri url) {
    final scheme = url.scheme.toLowerCase();
    return (scheme == 'https' || scheme == 'http') && url.host.isNotEmpty && url.userInfo.isEmpty;
  }

  /// `decidePolicyFor`: allowed pages, and blank frames inside the page.
  static bool permits(String address, {required bool isMainFrame}) {
    final url = Uri.tryParse(address);
    if (url == null) return false;
    return allows(url) || (address == 'about:blank' && !isMainFrame);
  }
}

/// Shares an address through the system share sheet, or copies it when sharing is unavailable.
Future<void> shareBrowserAddress(String address) async {
  try {
    await const MethodChannel('work.nextline.tegnal/screen').invokeMethod<void>('share', {'text': address});
  } on Object {
    await Clipboard.setData(ClipboardData(text: address));
  }
}

/// An icon-only borderless button of the browser's bars: tinted, dimmed while disabled.
class BrowserIconButton extends StatelessWidget {
  const BrowserIconButton({super.key, required this.icon, required this.label, required this.onPressed, this.size = 22});
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = onPressed == null ? TegnalColors.tertiaryLabel.resolveFrom(context) : TegnalColors.tint.resolveFrom(context);
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Center(
            child: Icon(icon, size: size, color: color),
          ),
        ),
      ),
    );
  }
}

/// Opens the website fallback from a library link: over everything, as `appFullScreenCover`
/// does, or in a sheet with a grabber where the native app shows work information.
Future<void> openInAppMangaBrowser(BuildContext context, String initialUrl, {bool sheet = false}) => sheet
    ? showAppSheet<void>(context, grabber: true, builder: (context, controller) => InAppMangaBrowserView(initialUrl: initialUrl))
    : Navigator.of(
        context,
        rootNavigator: true,
      ).push<void>(CupertinoPageRoute<void>(fullscreenDialog: true, builder: (context) => InAppMangaBrowserView(initialUrl: initialUrl)));

/// `InAppMangaBrowserView`: emergency website access, independent of the native metadata and
/// image adapters. Embedded, it is the Explore tab under the root header; otherwise it shows
/// its own close button.
class InAppMangaBrowserView extends StatefulWidget {
  const InAppMangaBrowserView({super.key, this.initialUrl, this.embedded = false, this.state, this.onClose})
    : assert(!embedded || state != null, 'The embedded browser sits under the root header.');

  /// Defaults to the connected website's home page.
  final String? initialUrl;
  final bool embedded;

  /// The root header's mode switch, when [embedded].
  final AppState? state;

  /// Replaces popping the route when the close button is tapped.
  final VoidCallback? onClose;

  @override
  State<InAppMangaBrowserView> createState() => _InAppMangaBrowserViewState();
}

class _InAppMangaBrowserViewState extends State<InAppMangaBrowserView> {
  late final String _initialUrl = widget.initialUrl ?? MangaUrls.home;
  late final WebViewController _controller;
  String _title = '';
  Uri? _address;
  bool _loading = false;
  bool _canGoBack = false;
  bool _canGoForward = false;
  String? _error;
  bool _hasLoaded = false;
  int _opening = 0;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      // Links that ask for a new window load in this view: Android opens them in place
      // while multiple windows are off, as the native view loads user-tapped ones.
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) =>
              EmbeddedBrowserPolicy.permits(request.url, isMainFrame: request.isMainFrame) ? NavigationDecision.navigate : NavigationDecision.prevent,
          onPageStarted: (_) {
            _hasLoaded = true;
            if (mounted) {
              setState(() {
                _loading = true;
                _error = null;
              });
            }
          },
          onUrlChange: (_) => _update(),
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
            _update();
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == false || !mounted) return;
            setState(() {
              _loading = false;
              _error = L10n.text('Unable to load. Check your connection and try again.');
            });
            _update();
          },
        ),
      );
    _start();
  }

  @override
  void dispose() {
    _opening++;
    super.dispose();
  }

  /// `start()`: native links wait for the connected website's protocol before loading.
  Future<void> _start() async {
    final opening = ++_opening;
    final url = Uri.tryParse(_initialUrl);
    if (url == null || !EmbeddedBrowserPolicy.allows(url)) {
      setState(() => _error = L10n.text('Invalid Address'));
      return;
    }
    // Fixture runs browse a local page instead of the network, as the native UI tests do.
    if (ContentPreferences.isIsolated) {
      _hasLoaded = true;
      await _controller.loadHtmlString(_fixturePage, baseUrl: url.toString());
      return;
    }
    if (ContentRoute.initial(_initialUrl) == null) {
      _hasLoaded = true;
      await _controller.loadRequest(url);
      return;
    }
    final site = MangaUrls.home;
    setState(() => _loading = true);
    await MangaUrls.resolveBackend();
    if (!mounted || opening != _opening || MangaUrls.home != site) return;
    _hasLoaded = true;
    await _controller.loadRequest(ContentRoute.configuredURL(url));
  }

  void _reload() {
    setState(() => _error = null);
    if (!_hasLoaded) {
      _start();
    } else {
      _controller.reload();
    }
  }

  Future<void> _update() async {
    final title = await _controller.getTitle();
    final address = await _controller.currentUrl();
    final back = await _controller.canGoBack();
    final forward = await _controller.canGoForward();
    if (!mounted) return;
    setState(() {
      _title = title ?? '';
      _address = address == null || address == 'about:blank' ? null : Uri.tryParse(address);
      _canGoBack = back;
      _canGoForward = forward;
    });
  }

  String get _displayTitle => _title.isEmpty ? L10n.text('Built-in Browser') : _title;
  String get _displayAddress => _address?.toString() ?? _initialUrl;
  String get _host => _address?.host ?? MangaUrls.configuredHost;

  void _showInformation(BuildContext buttonContext) {
    final address = _address;
    showActionMenu(
      buttonContext,
      anchor: anchorRectOf(buttonContext),
      actions: [
        ContextMenuAction(title: _displayTitle),
        ContextMenuAction(title: _displayAddress),
        if (address != null)
          ContextMenuAction(title: L10n.text('Share'), icon: CupertinoIcons.square_arrow_up, onSelected: () => shareBrowserAddress(address.toString())),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final background = TegnalColors.background.resolveFrom(context);
    final media = MediaQuery.of(context);
    final body = Column(
      children: [
        if (!widget.embedded) _closeHeader(context, media.padding.top),
        if (_loading) const Padding(padding: EdgeInsets.all(4), child: CupertinoActivityIndicator()),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: WebViewWidget(controller: _controller)),
              if (_error case final error?)
                Positioned.fill(
                  child: ColoredBox(
                    color: background,
                    child: Center(
                      child: ContentFailure(message: error, retry: _reload),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Container(height: 0.5, color: TegnalColors.separator.resolveFrom(context)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Row(
            children: [
              BrowserIconButton(icon: CupertinoIcons.chevron_back, label: L10n.text('Back'), onPressed: _canGoBack ? _controller.goBack : null),
              const Spacer(),
              BrowserIconButton(icon: CupertinoIcons.chevron_forward, label: L10n.text('Forward'), onPressed: _canGoForward ? _controller.goForward : null),
              const Spacer(),
              BrowserIconButton(icon: CupertinoIcons.arrow_clockwise, label: L10n.text('Reload'), onPressed: _reload),
            ],
          ),
        ),
        // Embedded, the bar sits above the floating tab bar; full screen, above the home indicator.
        SizedBox(height: widget.embedded ? tabBarClearance(context) - 16 : media.padding.bottom),
      ],
    );
    if (!widget.embedded) return ColoredBox(color: background, child: body);
    return ColoredBox(
      color: background,
      child: Stack(
        children: [
          Positioned.fill(top: rootContentTop(context), child: body),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: RootHeader(
              title: L10n.text('Explore'),
              state: widget.state!,
              trailing: Builder(
                builder: (buttonContext) => Semantics(
                  value: _displayAddress,
                  child: Glass.capsule(
                    child: SizedBox(
                      width: 48,
                      height: 44,
                      child: Center(
                        child: ToolbarIconButton(label: _host, icon: CupertinoIcons.info_circle, onPressed: () => _showInformation(buttonContext)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The full-screen header: close, then the page's title and host.
  Widget _closeHeader(BuildContext context, double top) => Padding(
    padding: EdgeInsets.fromLTRB(12, top + 12, 12, 12),
    child: Row(
      children: [
        BrowserIconButton(icon: CupertinoIcons.xmark, label: L10n.text('Close'), onPressed: widget.onClose ?? () => Navigator.of(context).maybePop()),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TegnalType.style(TegnalType.subheadline, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
              ),
              const SizedBox(height: 2),
              Semantics(
                value: _displayAddress,
                child: Text(
                  _host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TegnalType.style(TegnalType.caption, color: TegnalColors.secondaryLabel.resolveFrom(context)),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Local HTML that exercises real navigation without browsing content or using the network.
const _fixturePage =
    '<!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">'
    '<title>Browser fixture</title><body style="font:24px sans-serif;padding:24px">'
    '<h1>Browser ready</h1><a href="/second">Next test page</a><p><a target="_blank" href="/third">New-window test page</a></p>'
    '<p id="script">JavaScript pending</p><script>document.getElementById(\'script\').textContent=\'JavaScript ready\';</script>'
    '</body>';
