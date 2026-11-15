import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/content/combined_catalog.dart';
import '../../core/content/content_environment.dart';
import '../../core/content/content_errors.dart';
import '../../core/content/content_transport.dart';
import '../../core/content/keyed_catalog_source.dart';
import '../../core/content/keyed_work_extras.dart';
import '../../core/content/manga_content_source.dart';
import '../../core/content/manga_urls.dart';
import '../../core/content/site_account.dart';
import '../../core/content/site_account_actions.dart';
import '../../core/storage/app_database.dart';
import '../../core/support/l10n.dart';
import '../design/alert_dialog.dart';
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

/// What a bot check's page shows while it is still checking.
const _challengeScript =
    "(function(){return !!document.querySelector('#challenge-form, #challenge-running, #challenge-stage, .cf-turnstile')"
    " || /^(just a moment|checking your browser|attention required)/i.test(document.title);})()";

bool _scriptTrue(Object? result) => result == true || result == 'true';

/// `SiteAccountSection`: one connected website's account, in that website's own settings. The
/// person signs in on the website itself or pastes the cookies of a browser where they are signed
/// in; the app keeps only the sign-in cookies it is handed, for this website alone.
class SiteAccountSection extends StatefulWidget {
  const SiteAccountSection({super.key, required this.site, required this.content, required this.database, this.startCoverQueue});

  /// The connected website, as the list of websites names it.
  final String site;
  final ContentEnvironment content;
  final AppDatabase database;
  final VoidCallback? startCoverQueue;

  @override
  State<SiteAccountSection> createState() => _SiteAccountSectionState();
}

class _SiteAccountSectionState extends State<SiteAccountSection> {
  bool _importing = false;
  List<FavoriteCategory> _categories = [];
  List<SiteSettingsProfile> _profiles = [];
  (int, int)? _allowance;

  ContentEnvironment get _content => widget.content;

  /// What was learned about this website, read in its own scope.
  T _scoped<T>(T Function() body) => SiteScope.run(widget.site, body);
  String get _host => _scoped(() => MangaUrls.configuredHost);
  bool get _isChecked => widget.site == _content.mangaSiteAddress;
  bool get _signedIn => SiteAccount.isSignedInAt(_host);
  bool get _refused => SiteAccount.refusesAccess(_host);
  bool get _usesSiteSession => _scoped(() => MangaUrls.usesSiteSession);

  @override
  void initState() {
    super.initState();
    SiteClearance.listeners.add(_changed);
    SiteAccount.listeners.add(_changed);
    _loadAccountDetails();
    _resolveSite();
  }

  /// A website added a moment ago names its sign-in page on its own pages; read one so signing in works right away.
  Future<void> _resolveSite() async {
    if (_scoped(() => MangaUrls.hasResolvedBackend)) return;
    await _scoped(() => MangaUrls.resolveBackend());
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    SiteClearance.listeners.remove(_changed);
    SiteAccount.listeners.remove(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  bool get _keyed => _scoped(() => MangaUrls.hasResolvedBackend && MangaUrls.backend == MangaBackend.keyed);

  /// Whether accounts matter here: a website that uses them, or one not recognized yet that may be members-only.
  bool get _showsAccount => _signedIn || _scoped(() => MangaUrls.usesAccount || !MangaUrls.hasResolvedBackend || MangaUrls.backend == MangaBackend.keyed);

  Future<void> _loadAccountDetails() async {
    // The image allowance and favorites belong to the checked website's reader.
    if (!_isChecked || !_content.siteAccountSignedIn || !_keyed) return;
    try {
      final allowance = await MangaContentSource.shared.imageAllowance();
      if (mounted) setState(() => _allowance = allowance);
    } on Object {
      // The allowance is a hint; a page that does not show it leaves the row out.
    }
    try {
      final profiles = await MangaContentSource.shared.settingsProfiles();
      if (mounted) setState(() => _profiles = profiles);
    } on Object {
      // Without the settings page the app reads with the account's own profile.
    }
    if (!_content.syncsAccountFavorites || _categories.isNotEmpty) return;
    try {
      final categories = await MangaContentSource.shared.favoriteCategories();
      if (mounted) setState(() => _categories = categories);
    } on Object {
      // Category numbers stand in for names the page did not give.
    }
  }

  Future<void> _signIn() async {
    await showAppSheet<void>(
      context,
      builder: (context, controller) => SiteSignInView(content: _content, site: widget.site),
    );
    if (mounted) setState(() {});
    _loadAccountDetails();
  }

  Future<void> _pasteCookies() async {
    await showAppSheet<void>(
      context,
      builder: (context, controller) => SiteCookieSignInView(content: _content, site: widget.site),
    );
    if (mounted) setState(() {});
    _loadAccountDetails();
  }

  Future<void> _verify() async {
    await showAppSheet<void>(context, builder: (context, controller) => SiteVerificationView(host: _host));
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
    if (signOut == true) {
      setState(() {
        SiteAccountActions.signOut(_content, site: widget.site);
        _allowance = null;
        _categories = [];
        _profiles = [];
      });
    }
  }

  Future<void> _useProfile(int id) async {
    setState(() => _profiles = [for (final profile in _profiles) SiteSettingsProfile(profile.id, profile.name, selected: profile.id == id)]);
    try {
      await MangaContentSource.shared.useSettingsProfile(id);
      final profiles = await MangaContentSource.shared.settingsProfiles();
      if (mounted) setState(() => _profiles = profiles);
    } on Object {
      // The choice stays as picked; the next page read shows whether the website took it.
    }
  }

  Future<void> _chooseImport() async {
    final byCategory = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(L10n.text('Import Account Favorites')),
        actions: [
          CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Into the Default Folder'))),
          CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Into a Folder for Each Category'))),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (byCategory != null) await _import(byCategory: byCategory);
  }

  Future<void> _import({required bool byCategory}) async {
    setState(() => _importing = true);
    String message;
    try {
      final added = await SiteAccountActions.importAccountFavorites(
        database: widget.database,
        favorites: MangaContentSource.shared.accountFavorites,
        preview: MangaContentSource.shared.cachedPreview,
        startCoverQueue: widget.startCoverQueue,
        categories: byCategory ? MangaContentSource.shared.favoriteCategories : null,
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
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('Import Account Favorites')),
        content: Text(message),
        actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('OK')))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = _signedIn, refused = _refused, showsAccount = _showsAccount, checked = _isChecked;
    final tint = TegnalColors.tint.resolveFrom(context);
    final allowance = checked ? _allowance : null;
    final sources = signedIn || _usesSiteSession ? const <String>[] : SiteAccount.accountSources(excluding: _host);
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: FormSection(
        prominentHeader: true,
        rowColor: FormColors.listRow.resolveFrom(context),
        header: Text(L10n.text(showsAccount ? 'Website Account' : 'Website')),
        footer: !showsAccount
            ? null
            : Text(
                refused
                    // Why the website keeps a signed-in account out, and when that may change.
                    ? ContentError.accessDenied.errorDescription
                    : '${L10n.text("Some websites show more works, or keep favorites, for signed-in accounts. Create an account on the website itself. The app keeps only the sign-in in this device's keychain, never your password. If a website keeps asking you to check you’re not a bot, use Validate Client.")}\n\n${L10n.text('Each website keeps its own account. Two websites of one forum can share one: sign in on either, then use its account on the other.')}',
              ),
        children: [
          if (showsAccount && signedIn) ...[
            SettingsValueRow(title: L10n.text('Website Account'), value: L10n.text(refused ? 'Signed In, No Access Yet' : 'Signed In')),
            if (allowance != null) SettingsValueRow(title: L10n.text('Image Allowance'), value: '${allowance.$1} / ${allowance.$2}'),
            if (_scoped(() => MangaUrls.requiresSignIn) || refused || SiteAccount.savedCookieNames(_host).contains(SiteAccount.accessCookie))
              SettingsLinkRow(
                title: L10n.text('Refresh Website Access'),
                icon: CupertinoIcons.arrow_2_circlepath,
                tinted: true,
                chevron: false,
                onTap: () => setState(() {
                  SiteAccount.forget(SiteAccount.accessCookie, host: _host);
                  SiteAccountActions.signInChanged(_content, site: widget.site);
                }),
              ),
            if (checked && _keyed) ...[
              SettingsToggleRow(
                title: L10n.text('Load Original Images'),
                help: L10n.text(
                  'Loads each page’s original file instead of the resized one. The website may charge GP for originals; a page it won’t send is shown resized.',
                ),
                value: KeyedCatalogSource.loadsOriginals(_host),
                onChanged: (value) => setState(() => KeyedCatalogSource.setLoadsOriginals(value, host: _host)),
              ),
              if (_profiles.length > 1)
                SettingsPickerRow<int>(
                  title: L10n.text('Settings Profile'),
                  help: L10n.text(
                    'Which of your website settings profiles the app reads with, such as one made for the app. Create profiles in the website’s settings.',
                  ),
                  options: [for (final profile in _profiles) (profile.id, profile.name)],
                  selected: (_profiles.where((profile) => profile.selected).firstOrNull ?? _profiles.first).id,
                  onSelected: _useProfile,
                ),
              SettingsToggleRow(
                title: L10n.text('Sync Bookmarks with Account Favorites'),
                help: L10n.text('Bookmarking a work also adds it to your favorites on the website, and removing the bookmark removes it there.'),
                value: _content.syncsAccountFavorites,
                onChanged: (value) {
                  setState(() => _content.syncsAccountFavorites = value);
                  if (value) _loadAccountDetails();
                },
              ),
              if (_content.syncsAccountFavorites)
                SettingsPickerRow<int>(
                  title: L10n.text('Favorites Category'),
                  options: [
                    for (var number = 0; number < 10; number++)
                      (number, _categories.where((category) => category.id == number).firstOrNull?.name ?? L10n.text('Category %@', ['${number + 1}'])),
                  ],
                  selected: _content.accountFavoriteCategory,
                  onSelected: (value) => setState(() => _content.accountFavoriteCategory = value),
                ),
              FormRow(
                separatorInset: settingsIconInset,
                onTap: _importing ? null : _chooseImport,
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
            ],
            SettingsLinkRow(title: L10n.text('Sign Out'), destructive: true, chevron: false, onTap: _confirmSignOut),
          ] else if (showsAccount) ...[
            SettingsLinkRow(
              title: L10n.text('Sign In to Website'),
              icon: CupertinoIcons.person_crop_circle,
              tinted: true,
              chevron: false,
              onTap: _scoped(() => MangaUrls.signInURL) == null ? null : _signIn,
            ),
            for (final source in sources)
              SettingsLinkRow(
                title: L10n.text('Use the Account from %@', [source]),
                icon: CupertinoIcons.person_crop_circle_badge_checkmark,
                tinted: true,
                chevron: false,
                onTap: () => setState(() => SiteAccountActions.useAccount(source, _content, site: widget.site)),
              ),
            if (!_usesSiteSession)
              SettingsLinkRow(
                title: L10n.text('Sign In with Cookies'),
                icon: CupertinoIcons.doc_on_clipboard,
                tinted: true,
                chevron: false,
                onTap: _pasteCookies,
              ),
          ],
          SettingsLinkRow(
            title: L10n.text('Validate Client'),
            icon: CupertinoIcons.checkmark_shield,
            tinted: true,
            chevron: false,
            value: SiteClearance.hasClearance(_host) ? L10n.text('Done') : null,
            onTap: _verify,
          ),
        ],
      ),
    );
  }
}

/// `SiteCookieSignInView`: signs in with the cookies of a browser where the person is already signed in.
class SiteCookieSignInView extends StatefulWidget {
  const SiteCookieSignInView({super.key, required this.content, this.site, this.finished});
  final ContentEnvironment content;

  /// The connected website signing in; null is the checked one.
  final String? site;
  final VoidCallback? finished;

  @override
  State<SiteCookieSignInView> createState() => _SiteCookieSignInViewState();
}

class _SiteCookieSignInViewState extends State<SiteCookieSignInView> {
  final _member = TextEditingController();
  final _hash = TextEditingController();
  final _access = TextEditingController();
  Map<String, String> _extras = {};
  bool _checking = false;
  String? _result;
  bool _succeeded = false;

  @override
  void initState() {
    super.initState();
    for (final controller in [_member, _hash, _access]) {
      controller.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    _member.dispose();
    _hash.dispose();
    _access.dispose();
    super.dispose();
  }

  bool get _isValid => (int.tryParse(_member.text.trim()) ?? 0) > 0 && RegExp(r'^[0-9a-fA-F]{16,64}$').hasMatch(_hash.text.trim());

  PastedCookies get _pasted {
    final cookies = PastedCookies();
    if (_member.text.trim().isNotEmpty) cookies.identity['ipb_member_id'] = _member.text.trim();
    if (_hash.text.trim().isNotEmpty) cookies.identity['ipb_pass_hash'] = _hash.text.trim();
    cookies.site.addAll(_extras);
    final access = _access.text.trim();
    if (access.isNotEmpty && !SiteAccount.isPlaceholder(SiteAccount.accessCookie, access)) cookies.site[SiteAccount.accessCookie] = access;
    return cookies;
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final found = SiteAccount.parseCookies(data?.text ?? '');
    if (!mounted) return;
    setState(() {
      final id = found.identity.entries.where((entry) => entry.key.endsWith('_member_id')).firstOrNull?.value;
      final hash = found.identity.entries.where((entry) => entry.key.endsWith('_pass_hash')).firstOrNull?.value;
      if (id != null) _member.text = id;
      if (hash != null) _hash.text = hash;
      final access = found.site[SiteAccount.accessCookie];
      if (access != null) _access.text = access;
      _extras = {...found.site}..remove(SiteAccount.accessCookie);
      _result = found.isComplete ? null : L10n.text('No sign-in cookies were found in what you pasted.');
      _succeeded = false;
    });
  }

  Future<void> _signIn() async {
    setState(() => _checking = true);
    final site = widget.site;
    if (!SiteAccountActions.signInPasted(_pasted, widget.content, site: site)) {
      setState(() => _checking = false);
      return;
    }
    final other = site != null && site != widget.content.mangaSiteAddress;
    final succeeded = await SiteAccountActions.checkSiteAccount(
      other ? SiteContent.of(site).accountFavorites : MangaContentSource.shared.accountFavorites,
      site: site,
    );
    if (!mounted) return;
    widget.content.refreshSiteAccount();
    if (succeeded) {
      widget.finished?.call();
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _checking = false;
      _succeeded = false;
      _result = L10n.text('Signed in, but the website still didn’t show your account. Check the cookies, including the access cookie, or try again later.');
    });
  }

  Widget _field(TextEditingController controller, String placeholder, {bool secure = false, TextInputType? keyboard}) => FormRow(
    child: CupertinoTextField.borderless(
      controller: controller,
      padding: EdgeInsets.zero,
      placeholder: placeholder,
      obscureText: secure,
      keyboardType: keyboard,
      autocorrect: false,
      enableSuggestions: false,
      style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context)),
      placeholderStyle: TegnalType.style(17, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final row = FormColors.listRow.resolveFrom(context);
    final result = _result;
    return ColoredBox(
      color: FormColors.background.resolveFrom(context),
      child: Column(
        children: [
          SheetNavigationBar(
            title: L10n.text('Sign In with Cookies'),
            leading: GlassTextButton(label: L10n.text('Cancel'), onPressed: () => Navigator.of(context).pop()),
            trailing: _checking
                ? const CupertinoActivityIndicator()
                : GlassTextButton(label: L10n.text('Sign In'), prominent: true, onPressed: _isValid ? _signIn : null),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 8, bottom: 32),
              children: [
                FormSection(
                  rowColor: row,
                  footer: Text(
                    L10n.text(
                      'Copy the cookies from a browser where you’re signed in to the website, such as a cookie list or a shortcut’s output, then paste them here.',
                    ),
                  ),
                  children: [SettingsLinkRow(title: L10n.text('Paste'), icon: CupertinoIcons.doc_on_clipboard, tinted: true, chevron: false, onTap: _paste)],
                ),
                const SizedBox(height: 28),
                FormSection(
                  prominentHeader: true,
                  rowColor: row,
                  header: Text(L10n.text('Cookies')),
                  footer: Text(
                    L10n.text(
                      'The values of the cookies named “ipb_member_id”, “ipb_pass_hash” and, for members-only websites, “igneous”. They’re kept only in this device’s keychain and sent only to the connected website.',
                    ),
                  ),
                  children: [
                    _field(_member, L10n.text('Member ID'), keyboard: TextInputType.number),
                    _field(_hash, L10n.text('Pass Hash'), secure: true),
                    _field(_access, L10n.text('Access Cookie (Optional)'), secure: true),
                  ],
                ),
                if (_extras.isNotEmpty) ...[
                  const SizedBox(height: 28),
                  FormSection(
                    prominentHeader: true,
                    rowColor: row,
                    header: Text(L10n.text('Other Cookies')),
                    children: [for (final name in _extras.keys.toList()..sort()) SettingsValueRow(title: name, value: L10n.text('Included'))],
                  ),
                ],
                if (result != null) ...[
                  const SizedBox(height: 28),
                  FormSection(
                    rowColor: row,
                    children: [
                      FormRow(
                        child: Row(
                          children: [
                            Icon(
                              _succeeded ? CupertinoIcons.checkmark_circle : CupertinoIcons.exclamationmark_triangle,
                              color: (_succeeded ? CupertinoColors.systemGreen : CupertinoColors.systemOrange).resolveFrom(context),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                result,
                                style: TegnalType.style(
                                  15,
                                  color: (_succeeded ? CupertinoColors.systemGreen : CupertinoColors.systemOrange).resolveFrom(context),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
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

/// `SiteSignInView`: the website's own sign-in page in a fresh browser session. The cookies are
/// checked every half second, since a bot check can redirect many times before the page settles.
/// A site that signs in on its own pages counts as signed in once its sign-in form has been left.
class SiteSignInView extends StatefulWidget {
  const SiteSignInView({super.key, required this.content, this.site, this.finished});
  final ContentEnvironment content;

  /// The connected website signing in; null is the checked one.
  final String? site;
  final VoidCallback? finished;

  @override
  State<SiteSignInView> createState() => _SiteSignInViewState();
}

class _SiteSignInViewState extends State<SiteSignInView> {
  WebViewController? _controller;
  Timer? _watcher;
  double _progress = 0;
  bool _loading = true;
  bool _done = false;
  bool _sawSignInForm = false;
  String? _failure;

  /// For a site that signs in on its own pages: its host. Null for the forum identity.
  late final String? _session = SiteAccountActions.scoped(widget.site, () => MangaUrls.usesSiteSession ? MangaUrls.configuredHost : null);

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _watcher?.cancel();
    WebCookies.clear();
    super.dispose();
  }

  Future<void> _start() async {
    final url = SiteAccountActions.scoped(widget.site, () => MangaUrls.signInURL);
    if (url == null) return;
    await WebCookies.clear();
    late final WebViewController controller;
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) => SiteAccountActions.allowsSignInNavigation(Uri.parse(request.url), mainFrame: request.isMainFrame)
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onProgress: (value) {
            if (mounted) setState(() => _progress = value / 100);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
            _check(controller);
          },
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
    _watcher?.cancel();
    _watcher = Timer.periodic(const Duration(milliseconds: 500), (_) => _check(controller));
    if (mounted) setState(() => _controller = controller);
  }

  Future<void> _check(WebViewController controller) async {
    if (_done || !mounted) return;
    final page = await controller.currentUrl();
    final url = page == null ? null : Uri.tryParse(page);
    if (url == null || url.host.isEmpty) return;
    final cookies = SiteAccountActions.parseCookieHeader(await WebCookies.header(url));
    if (!mounted || _done) return;
    // A bot check passed on the way is kept for the app's own requests to this website.
    if (cookies.any((cookie) => cookie.name == 'cf_clearance')) {
      final agent = await controller.getUserAgent();
      if (agent != null) SiteClearance.save(cookies, userAgent: agent, host: url.host);
    }
    final session = _session;
    if (session != null) {
      if (SiteClearance.domain(url.host) != SiteClearance.domain(session)) return;
      final Object? asks;
      try {
        asks = await controller.runJavaScriptReturningResult("!!document.querySelector('input[type=password]')");
      } on Object {
        return;
      }
      if (_scriptTrue(asks)) {
        _sawSignInForm = true;
        return;
      }
      if (!_sawSignInForm || _done || !SiteAccountActions.finishSessionSignIn(cookies, widget.content, site: widget.site)) return;
    } else if (!SiteAccountActions.finishSignIn(cookies, widget.content, site: widget.site)) {
      return;
    }
    _done = true;
    _watcher?.cancel();
    widget.finished?.call();
    if (mounted) Navigator.of(context).pop();
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
      body = Column(
        children: [
          // A bar that never covers the page, so a bot check stays usable while it loads.
          if (_loading) CupertinoLinearActivityIndicator(progress: _progress.clamp(0.05, 1)),
          Expanded(child: _controller == null ? const SizedBox.shrink() : WebViewWidget(controller: _controller!)),
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

/// `SiteVerificationView`: a comics website's bot check, passed in the app's browser. The cookies
/// it hands out are kept with this browser's identity, and the app's requests to the website use both.
class SiteVerificationView extends StatefulWidget {
  const SiteVerificationView({super.key, required this.host, this.finished});
  final String host;
  final VoidCallback? finished;

  @override
  State<SiteVerificationView> createState() => _SiteVerificationViewState();
}

class _SiteVerificationViewState extends State<SiteVerificationView> {
  WebViewController? _controller;
  Timer? _monitor;
  DateTime _begun = DateTime.now();
  double _progress = 0;
  bool _loading = true;
  bool _verified = false;
  bool _stalled = false;
  String? _failure;
  String? _address;

  Uri get _start => ContentTransport.challengedPage(widget.host) ?? Uri.parse('https://${widget.host}/');

  @override
  void initState() {
    super.initState();
    _begin();
  }

  @override
  void dispose() {
    _monitor?.cancel();
    if (_verified) {
      ContentTransport.clearChallenge(widget.host);
      if (!MangaUrls.hasResolvedBackend) MangaUrls.resetResolvedBackend();
    }
    widget.finished?.call();
    super.dispose();
  }

  void _begin() {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) => SiteAccountActions.allowsSignInNavigation(Uri.parse(request.url), mainFrame: request.isMainFrame)
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onProgress: (value) {
            if (mounted) setState(() => _progress = value / 100);
          },
          onPageFinished: (url) {
            if (mounted) {
              setState(() {
                _loading = false;
                _address = Uri.tryParse(url)?.host;
              });
            }
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == false || error.errorType == WebResourceErrorType.unknown && error.errorCode == -3) return;
            if (mounted) {
              setState(() {
                _loading = false;
                _failure = error.description;
              });
            }
          },
        ),
      );
    _controller = controller;
    _reload(_start);
  }

  void _reload([Uri? url]) {
    final controller = _controller;
    if (controller == null) return;
    setState(() {
      _failure = null;
      _stalled = false;
      _loading = true;
      _begun = DateTime.now();
    });
    if (url != null) {
      controller.loadRequest(url);
    } else {
      controller.reload();
    }
    _monitor?.cancel();
    // Neither page loads nor cookie changes are dependable signals that the check let the
    // browser through, so the page and its cookies are looked at every second.
    _monitor = Timer.periodic(const Duration(seconds: 1), (_) => _watch());
  }

  Future<void> _watch() async {
    final controller = _controller;
    if (controller == null || !mounted) return;
    bool checking;
    try {
      checking = _scriptTrue(await controller.runJavaScriptReturningResult(_challengeScript));
    } on Object {
      return;
    }
    if (!checking && await _capture(controller) && mounted) {
      setState(() {
        _verified = true;
        _stalled = false;
      });
    }
    if (checking && DateTime.now().difference(_begun) > const Duration(seconds: 25) && mounted) setState(() => _stalled = true);
  }

  Future<bool> _capture(WebViewController controller) async {
    final page = await controller.currentUrl();
    final url = page == null ? null : Uri.tryParse(page);
    if (url == null || url.host.isEmpty) return false;
    final cookies = SiteAccountActions.parseCookieHeader(await WebCookies.header(url));
    if (!cookies.any((cookie) => cookie.name == 'cf_clearance')) return false;
    final agent = await controller.getUserAgent();
    return agent != null && SiteClearance.save(cookies, userAgent: agent, host: widget.host);
  }

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final status = _verified ? CupertinoColors.systemGreen.resolveFrom(context) : TegnalColors.label.resolveFrom(context);
    return ColoredBox(
      color: TegnalColors.background.resolveFrom(context),
      child: Column(
        children: [
          SheetNavigationBar(
            title: L10n.text('Validate Client'),
            leading: GlassTextButton(label: L10n.text('Reload'), onPressed: () => _reload()),
            trailing: GlassTextButton(label: L10n.text('Done'), prominent: true, onPressed: () => Navigator.of(context).pop()),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(_verified ? CupertinoIcons.checkmark_shield : CupertinoIcons.lock_shield, size: 20, color: status),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _address ?? widget.host,
                        style: TegnalType.style(15, weight: FontWeight.w600, color: status),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        L10n.text(
                          _verified
                              ? 'The check is done. The app uses it for this website until the website asks again.'
                              : 'Finish any check the website shows. The app keeps the result for this website.',
                        ),
                        style: TegnalType.style(12, color: secondary),
                      ),
                      if (_stalled) ...[
                        const SizedBox(height: 8),
                        Text(
                          L10n.text('Verification is taking longer than expected. Reload, or reset this website’s cookies and try again.'),
                          style: TegnalType.style(13, color: TegnalColors.label.resolveFrom(context)),
                        ),
                        CupertinoButton(
                          padding: EdgeInsets.zero,
                          onPressed: () {
                            SiteClearance.remove(widget.host);
                            _reload(_start);
                          },
                          child: Text(L10n.text('Reset Cookies'), style: TegnalType.style(13, color: CupertinoColors.systemRed.resolveFrom(context))),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_loading) CupertinoLinearActivityIndicator(progress: _progress.clamp(0.05, 1)),
          Expanded(
            child: _failure != null
                ? Center(
                    child: ContentUnavailable(
                      icon: CupertinoIcons.wifi_exclamationmark,
                      title: L10n.text('Unable to Load'),
                      description: _failure,
                      action: CupertinoButton.filled(onPressed: () => _reload(_start), child: Text(L10n.text('Try Again'))),
                    ),
                  )
                : _controller == null
                ? const SizedBox.shrink()
                : WebViewWidget(controller: _controller!),
          ),
        ],
      ),
    );
  }
}
