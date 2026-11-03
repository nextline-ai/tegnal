import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/content/content_environment.dart';
import '../../core/content/content_errors.dart';
import '../../core/content/manga_content_source.dart';
import '../../core/content/manga_urls.dart';
import '../../core/content/site_account_actions.dart';
import '../../core/storage/app_database.dart';
import '../../core/support/l10n.dart';
import '../design/app_sheet.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';
import '../library/folders_view.dart' show ContentUnavailable;
import 'settings_rows.dart';

/// Reads and clears the WebView's cookies, which webview_flutter cannot do on Android.
abstract final class WebCookies {
  static const _channel = MethodChannel('work.nextline.tegnal/screen');
  static Future<String?> header(Uri url) => _channel.invokeMethod<String>('cookies', {'url': url.toString()});
  static Future<void> clear() => _channel.invokeMethod<bool>('clearCookies');
}

/// `SiteAccountSection`: shown for websites that use accounts. The person signs in on the
/// website itself; the app keeps only the identity cookies it hands back.
class SiteAccountSection extends StatefulWidget {
  const SiteAccountSection({super.key, required this.content, required this.database, this.startCoverQueue});
  final ContentEnvironment content;
  final AppDatabase database;
  final VoidCallback? startCoverQueue;

  @override
  State<SiteAccountSection> createState() => _SiteAccountSectionState();
}

class _SiteAccountSectionState extends State<SiteAccountSection> {
  bool _importing = false;

  ContentEnvironment get _content => widget.content;

  Future<void> _signIn() async {
    await showAppSheet<void>(context, builder: (context, controller) => SiteSignInView(content: _content));
    if (mounted) setState(() {});
  }

  Future<void> _confirmSignOut() async {
    final signOut = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(L10n.text('Sign out of this website?')),
        actions: [CupertinoActionSheetAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Sign Out')))],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (signOut == true) setState(() => SiteAccountActions.signOut(_content));
  }

  Future<void> _import() async {
    setState(() => _importing = true);
    String message;
    try {
      final added = await SiteAccountActions.importAccountFavorites(
        database: widget.database,
        favorites: MangaContentSource.shared.accountFavorites,
        preview: MangaContentSource.shared.cachedPreview,
        startCoverQueue: widget.startCoverQueue,
      );
      message = added == 0
          ? L10n.text('Every account favorite is already bookmarked.')
          : L10n.text('Bookmarked %@ works from your account favorites.', ['$added']);
    } on Object catch (error) {
      message = ContentError.message(error);
    }
    if (!mounted) return;
    setState(() => _importing = false);
    await showCupertinoDialog<void>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(L10n.text('Import Account Favorites')),
        content: Text(message),
        actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('OK')))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = _content.siteAccountSignedIn;
    if (!signedIn && !MangaUrls.usesAccount) return const SizedBox.shrink();
    final tint = TegnalColors.tint.resolveFrom(context);
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: FormSection(
        prominentHeader: true,
        rowColor: FormColors.listRow.resolveFrom(context),
        header: Text(L10n.text('Website Account')),
        footer: Text(
          L10n.text(
            "Some websites show more works, or keep favorites, for signed-in accounts. Create an account on the website itself. The app keeps only the sign-in in this device's keychain, never your password.",
          ),
        ),
        children: [
          if (signedIn) ...[
            SettingsValueRow(title: L10n.text('Website Account'), value: L10n.text('Signed In')),
            SettingsToggleRow(
              title: L10n.text('Sync Bookmarks with Account Favorites'),
              help: L10n.text('Bookmarking a work also adds it to your favorites on the website, and removing the bookmark removes it there.'),
              value: _content.syncsAccountFavorites,
              onChanged: (value) => setState(() => _content.syncsAccountFavorites = value),
            ),
            FormRow(
              separatorInset: settingsIconInset,
              onTap: _importing ? null : _import,
              child: Row(
                children: [
                  SizedBox(width: 24, child: Icon(CupertinoIcons.arrow_down_doc, size: 22, color: tint)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(L10n.text('Import Account Favorites'), style: TegnalType.style(17, color: tint)),
                  ),
                  if (_importing) const CupertinoActivityIndicator(),
                ],
              ),
            ),
            SettingsLinkRow(title: L10n.text('Sign Out'), destructive: true, chevron: false, onTap: _confirmSignOut),
          ] else
            SettingsLinkRow(
              title: L10n.text('Sign In to Website'),
              icon: CupertinoIcons.person_crop_circle,
              tinted: true,
              chevron: false,
              onTap: MangaUrls.signInURL == null ? null : _signIn,
            ),
        ],
      ),
    );
  }
}

/// `SiteSignInView`: the website's own sign-in page in a fresh browser session. The page
/// closes once its cookies hold the identity; the session is cleared before and after.
class SiteSignInView extends StatefulWidget {
  const SiteSignInView({super.key, required this.content});
  final ContentEnvironment content;

  @override
  State<SiteSignInView> createState() => _SiteSignInViewState();
}

class _SiteSignInViewState extends State<SiteSignInView> {
  WebViewController? _controller;
  bool _loading = true;
  String? _failure;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    WebCookies.clear();
    super.dispose();
  }

  Future<void> _start() async {
    final url = MangaUrls.signInURL;
    if (url == null) return;
    await WebCookies.clear();
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) =>
              SiteAccountActions.allowsSignInNavigation(Uri.parse(request.url)) ? NavigationDecision.navigate : NavigationDecision.prevent,
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: _pageFinished,
          onWebResourceError: (error) {
            // A page left for another one is not a failure.
            if (error.isForMainFrame == false || error.errorType == WebResourceErrorType.unknown && error.errorCode == -3) return;
            if (mounted) {
              setState(() {
                _loading = false;
                _failure = error.description;
              });
            }
          },
        ),
      )
      ..loadRequest(url);
    if (mounted) setState(() => _controller = controller);
  }

  Future<void> _pageFinished(String page) async {
    if (!mounted) return;
    setState(() => _loading = false);
    final header = await WebCookies.header(Uri.parse(page));
    if (!mounted) return;
    if (SiteAccountActions.finishSignIn(SiteAccountActions.parseCookieHeader(header), widget.content)) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (_failure != null) {
      body = Center(
        child: ContentUnavailable(
          icon: CupertinoIcons.wifi_exclamationmark,
          title: L10n.text('Unable to Load'),
          description: _failure,
          action: CupertinoButton.filled(
            onPressed: () {
              setState(() {
                _failure = null;
                _loading = true;
              });
              _start();
            },
            child: Text(L10n.text('Try Again')),
          ),
        ),
      );
    } else if (MangaUrls.signInURL == null) {
      body = Center(
        child: ContentUnavailable(
          icon: CupertinoIcons.person_crop_circle_badge_exclam,
          title: L10n.text('Unable to Load'),
          description: L10n.text('Open a few works on the website first, then try signing in again.'),
        ),
      );
    } else {
      body = Stack(
        children: [
          if (_controller != null) Positioned.fill(child: WebViewWidget(controller: _controller!)),
          if (_loading) const Center(child: CupertinoActivityIndicator(radius: 14)),
        ],
      );
    }
    return ColoredBox(
      color: TegnalColors.background.resolveFrom(context),
      child: Column(
        children: [
          SheetNavigationBar(
            title: L10n.text('Sign In to Website'),
            leading: GlassTextButton(label: L10n.text('Cancel'), onPressed: () => Navigator.of(context).pop()),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}
