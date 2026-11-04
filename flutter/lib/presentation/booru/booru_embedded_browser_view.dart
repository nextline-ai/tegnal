import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/booru/booru_browser.dart';
import '../../core/booru/booru_models.dart';
import '../../core/support/l10n.dart';
import '../browser/in_app_manga_browser_view.dart' show BrowserIconButton, shareBrowserAddress;
import '../content/explore_view.dart' show ContentUnavailable;
import '../content/gallery_detail_view.dart' show ContentFailure;
import '../design/context_menu.dart';
import '../design/pull_down_menu.dart' show anchorRectOf;
import '../design/symbols.dart';
import '../design/tegnal_theme.dart';
import '../settings/site_account_section.dart' show WebCookies;
import 'booru_common.dart';
import 'booru_settings_views.dart' show booruWebNetworkError;

/// `BooruEmbeddedBrowserView`: a full website fallback. Android web views share one cookie
/// store, so it browses with the same cookies as Validate Client.
class BooruEmbeddedBrowserView extends StatefulWidget {
  const BooruEmbeddedBrowserView({
    super.key,
    required this.booru,
    required this.servers,
    required this.query,
    required this.sort,
    this.poolID,
    this.preferredServerID,
    this.isActive = true,
    this.bottomInset = 0,
  });

  final BooruContext booru;
  final List<BooruServer> servers;

  /// The feed's search, before its sort is applied.
  final String query;
  final BooruSort sort;
  final int? poolID;
  final String? preferredServerID;

  /// Loads only while the feed is on screen, as the native view waits for its tab and mode.
  final bool isActive;

  /// Space under the bottom bar, such as the floating tab bar.
  final double bottomInset;

  @override
  State<BooruEmbeddedBrowserView> createState() => _BooruEmbeddedBrowserViewState();
}

class _BooruEmbeddedBrowserViewState extends State<BooruEmbeddedBrowserView> {
  String? _selectedID;

  BooruServer? get _server {
    final id = _selectedID ?? widget.preferredServerID;
    return widget.servers.where((server) => server.id == id).firstOrNull ?? widget.servers.firstOrNull;
  }

  void _chooseServer(BuildContext buttonContext, BooruServer current) => showActionMenu(
    buttonContext,
    anchor: anchorRectOf(buttonContext),
    actions: [
      for (final value in widget.servers)
        ContextMenuAction(title: value.name, icon: Symbols.globe, checked: value.id == current.id, onSelected: () => setState(() => _selectedID = value.id)),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final server = _server;
    if (server == null) {
      return Center(
        child: ContentUnavailable(icon: Symbols.globe, title: L10n.text('No Servers')),
      );
    }
    final tint = TegnalColors.tint.resolveFrom(context);
    final url = Uri.parse(server.browsingURL(widget.sort.query(widget.query, server.engine), poolID: widget.poolID));
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                // Loose, so the server name takes its own width and the spacer pushes the grid button to the edge.
                Flexible(
                  fit: FlexFit.loose,
                  flex: 0,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width - 40 - 52),
                    child: Builder(
                      builder: (buttonContext) => Semantics(
                        button: true,
                        label: server.displayName,
                        excludeSemantics: true,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _chooseServer(buttonContext, server),
                          child: SizedBox(
                            height: 44,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Symbols.globe, size: 17, color: tint),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    server.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TegnalType.style(TegnalType.subheadline, color: tint),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                BrowserIconButton(
                  icon: CupertinoIcons.square_grid_2x2,
                  label: L10n.text('Show Image Grid'),
                  size: 19,
                  onPressed: () => widget.booru.useEmbeddedBrowser = false,
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: _BooruWebsiteView(key: ValueKey(server.id), server: server, url: url, active: widget.isActive, fixture: widget.booru.fixture),
        ),
        SizedBox(height: widget.bottomInset),
      ],
    );
  }
}

/// `BooruWebsiteView`: the server's website with Back, Forward, its host, Reload and Share.
class _BooruWebsiteView extends StatefulWidget {
  const _BooruWebsiteView({super.key, required this.server, required this.url, required this.active, required this.fixture});
  final BooruServer server;
  final Uri url;
  final bool active;
  final bool fixture;

  @override
  State<_BooruWebsiteView> createState() => _BooruWebsiteViewState();
}

class _BooruWebsiteViewState extends State<_BooruWebsiteView> {
  late final _state = BooruValidationState(widget.server);
  late final WebViewController _controller;
  Uri? _loadedURL;

  @override
  void initState() {
    super.initState();
    _state.addListener(_changed);
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(
        NavigationDelegate(
          // HTTPS pages only. A link that asks for a new window already opens in place,
          // since Android web views keep multiple windows off.
          onNavigationRequest: (request) {
            final url = Uri.tryParse(request.url);
            if (url == null) return NavigationDecision.prevent;
            return BooruValidationState.navigation(url, newWindow: false) == BooruNavigationDecision.allow
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onPageStarted: (_) => _state.didStart(),
          onPageFinished: (url) async {
            _state.didFinish(Uri.tryParse(url), canGoBack: await _controller.canGoBack(), canGoForward: await _controller.canGoForward());
            _inspect();
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == false) return;
            final delay = _state.failed(booruWebNetworkError(error));
            final retry = _state.retryURL;
            if (delay != null && retry != null) Timer(delay, () => mounted ? _controller.loadRequest(retry) : null);
          },
        ),
      );
    _state.setActive(widget.active);
    if (widget.active) _loadCurrent();
  }

  @override
  void didUpdateWidget(_BooruWebsiteView old) {
    super.didUpdateWidget(old);
    if (widget.active != old.active) {
      _state.setActive(widget.active);
      if (!widget.active) _adopt();
    }
    if (widget.active && _loadedURL != widget.url) _loadCurrent();
  }

  @override
  void dispose() {
    _state.setActive(false);
    _adopt();
    _state.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _loadCurrent() {
    _loadedURL = widget.url;
    _load(widget.url);
  }

  void _load(Uri url) {
    final target = _state.load(url);
    if (widget.fixture) {
      _controller.loadHtmlString(
        "<html><meta name='viewport' content='width=device-width'><body><h2>Website</h2><p>Embedded browser is ready.</p></body></html>",
        baseUrl: widget.server.baseURL,
      );
      return;
    }
    _controller.loadRequest(target);
  }

  Future<void> _inspect() async {
    try {
      final url = await _controller.currentUrl();
      if (url == null) return;
      final result = await _controller.runJavaScriptReturningResult('(function(){${BooruBrowserScripts.challenge}})()');
      _state.inspected(Uri.parse(url), result == true || result == 'true' ? true : (result == false || result == 'false' ? false : null));
    } on Object {
      // A page still loading has nothing to inspect yet.
    }
  }

  /// A page past the server's check keeps serving the app's requests, as on leaving Validate Client.
  Future<void> _adopt() async {
    if (!_state.canAdoptSession) return;
    final server = widget.server;
    final address = _state.address;
    if (address != null) {
      try {
        BooruBrowserSession.shared.importCookieHeader(await WebCookies.header(address), address.toString(), server);
      } on Object {
        // Without the cookie bridge the shared web view store still holds them.
      }
    }
    BooruBrowserSession.shared.clearChallenge(server);
  }

  @override
  Widget build(BuildContext context) {
    final background = TegnalColors.background.resolveFrom(context);
    final address = _state.address ?? widget.url;
    final host = _state.address?.host ?? Uri.tryParse(widget.server.baseURL)?.host ?? '';
    return Column(
      children: [
        // A spinner in a 4 pt slot, overlapping the bars around it as the native one does.
        SizedBox(height: 4, child: _state.loading ? const OverflowBox(maxHeight: 20, child: CupertinoActivityIndicator()) : null),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: WebViewWidget(controller: _controller)),
              if (_state.error case final error?)
                Positioned.fill(
                  child: ColoredBox(
                    color: background,
                    child: Center(
                      child: ContentFailure(message: error, retry: () => _load(widget.url)),
                    ),
                  ),
                ),
            ],
          ),
        ),
        SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                BrowserIconButton(icon: CupertinoIcons.chevron_left, label: L10n.text('Back'), onPressed: _state.canGoBack ? _controller.goBack : null),
                const SizedBox(width: 24),
                BrowserIconButton(
                  icon: CupertinoIcons.chevron_right,
                  label: L10n.text('Forward'),
                  onPressed: _state.canGoForward ? _controller.goForward : null,
                ),
                const SizedBox(width: 32),
                Expanded(
                  child: Text(
                    host,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TegnalType.style(TegnalType.caption, color: TegnalColors.secondaryLabel.resolveFrom(context)),
                  ),
                ),
                const SizedBox(width: 32),
                BrowserIconButton(icon: CupertinoIcons.arrow_clockwise, label: L10n.text('Reload'), onPressed: () => _load(address)),
                const SizedBox(width: 24),
                BrowserIconButton(icon: CupertinoIcons.square_arrow_up, label: L10n.text('Share'), onPressed: () => shareBrowserAddress(address.toString())),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
