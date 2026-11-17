import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/booru/booru_account.dart';
import '../../core/booru/booru_browser.dart';
import '../../core/booru/booru_html.dart' show booruSameOrigin;
import '../../core/booru/booru_models.dart';
import '../../core/content/keyed_work_extras.dart';
import '../../core/content/site_account.dart';
import '../../core/support/l10n.dart';
import '../content/work_extras_views.dart';
import '../design/alert_dialog.dart';
import '../design/app_sheet.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';
import '../library/folders_view.dart' show ContentUnavailable;
import '../settings/settings_rows.dart';
import '../settings/site_account_section.dart' show WebCookies;
import 'booru_common.dart';

/// `BooruAccountSection`: one image server's account, in its settings. The person signs in on the
/// server's own page or saves the API key the server's account settings show; the app keeps only
/// that sign-in. In image mode's settings the server's connection and filter rows follow at the
/// bottom of the same section.
class BooruAccountSection extends StatefulWidget {
  const BooruAccountSection({super.key, required this.booru, required this.server, this.header, this.rows = const [], this.rowColor});
  final BooruContext booru;
  final BooruServer server;

  /// The section's title: the server's name where the section stands for the whole server.
  final String? header;
  final List<Widget> rows;

  /// The rows' color; null takes the form's own, as inside a sheet.
  final Color? rowColor;

  @override
  State<BooruAccountSection> createState() => _BooruAccountSectionState();
}

class _BooruAccountSectionState extends State<BooruAccountSection> {
  bool _syncing = false;

  BooruAccountSync? get _sync => BooruAccountSync.shared;
  BooruServer get _server => widget.server;

  @override
  void initState() {
    super.initState();
    _sync?.addListener(_changed);
    // An API key saved in the server's settings, or a sign-in kept from the website, counts too.
    unawaited(_sync?.discover(_server));
  }

  @override
  void dispose() {
    _sync?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _signIn() async {
    await showAppSheet<void>(context, builder: (context, controller) => BooruSignInPage(server: _server));
    // A sign-in page closed by hand may still have signed the account in.
    await _sync?.discover(_server, force: true);
    if (mounted) setState(() {});
  }

  Future<void> _confirmSignOut() async {
    final sync = _sync;
    if (sync == null) return;
    final signOut = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(L10n.text('Sign out of this website?')),
        message: Text(L10n.text('Saved images stay in the app. Folders made for favorite groups stay as plain folders.')),
        actions: [CupertinoActionSheetAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Sign Out')))],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (signOut == true) await sync.signOut(_server);
  }

  Future<void> _run(Future<void> Function() body) async {
    setState(() => _syncing = true);
    try {
      await body();
    } on Object catch (error) {
      if (mounted) {
        await showCupertinoDialog<void>(
          context: context,
          builder: (context) => TegnalAlertDialog(
            title: Text(L10n.text('Sync Favorites with Folders')),
            content: Text(BooruConnectionMessage.describe(error)),
            actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('OK')))],
          ),
        );
      }
    }
    if (mounted) setState(() => _syncing = false);
  }

  /// `BooruFavoritesSyncRows`: whether the account's favorites and the folders are kept the same,
  /// which folder each list has, where images saved in other folders go, and a sync on demand.
  List<Widget> _syncRows(BooruAccountSync sync) {
    final state = sync.state(_server);
    final names = sync.listNames[_server.id] ?? const <int, String>{};
    String name(int list) => list == BooruAccounts.favoritesList ? L10n.text('Favorites') : names[list] ?? '#$list';
    final folderNames = {for (final folder in widget.booru.store.folders()) folder.id: folder.displayName};
    final free = <int>{
      for (final list in [BooruAccounts.favoritesList, ...names.keys.toList()..sort()])
        if (state != null && !state.folders.containsKey(list)) list,
    }.toList();
    final tint = TegnalColors.tint.resolveFrom(context);
    return [
      SettingsToggleRow(
        title: L10n.text('Sync Favorites with Folders'),
        help: L10n.text(
          _server.engine.keepsFavoriteLists
              ? "Images you save in the app are kept in your favorites on the website, and favorites you add there come to the app. Each favorite group that holds images becomes a folder of the same name, and the two hold the same images. You can't delete such a folder yourself while you're signed in. Images saved before signing in stay in the app only."
              : 'Images you save in the app are kept in your favorites on the website, and favorites you add there come to the app. Images saved before signing in stay in the app only.',
        ),
        value: state != null,
        onChanged: _syncing
            ? null
            : (on) {
                if (on) {
                  _run(() => sync.setUp(_server, requested: true));
                } else {
                  sync.stop(_server);
                }
              },
      ),
      if (state != null) ...[
        for (final list in state.folders.keys.toList()..sort())
          if (folderNames[state.folders[list]] case final folder?) SettingsValueRow(title: name(list), value: folder),
        // -1 stands for keeping them in the app only; lists count from 0.
        SettingsPickerRow<int>(
          title: L10n.text('List for Other Folders'),
          help: L10n.text(
            "Images you save in folders that don't stand for a favorite group are added to this list on the website. Keep in App Only leaves them off the website; the website's favorites then come to a folder of their own.",
          ),
          options: [(-1, L10n.text('Keep in App Only')), for (final list in free) (list, name(list))],
          selected: free.contains(state.unassigned) ? state.unassigned! : -1,
          onSelected: (value) => sync.setOtherFoldersList(value < 0 ? null : value, _server),
        ),
        FormRow(
          separatorInset: settingsIconInset,
          onTap: _syncing ? null : () => _run(() async => sync.sync(_server)),
          child: Row(
            children: [
              SizedBox(width: 24, child: Icon(CupertinoIcons.arrow_2_circlepath, size: 22, color: tint)),
              const SizedBox(width: 16),
              Expanded(
                child: Text(L10n.text('Sync Now'), style: TegnalType.style(17, color: tint)),
              ),
              if (_syncing) const CupertinoActivityIndicator(),
            ],
          ),
        ),
      ] else if (_syncing)
        FormRow(
          child: Row(
            children: [
              const CupertinoActivityIndicator(),
              const SizedBox(width: 12),
              Text(L10n.text('Reading Favorites…'), style: TegnalType.style(17, color: TegnalColors.secondaryLabel.resolveFrom(context))),
            ],
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final sync = _sync;
    if (sync == null) return const SizedBox.shrink();
    final identity = sync.identity(_server);
    final canChange = identity != null && sync.client.canChange(_server);
    return FormSection(
      prominentHeader: true,
      rowColor: widget.rowColor,
      header: Text(widget.header ?? L10n.text('Website Account')),
      footer: identity == null && sync.refusedKeys.contains(_server.id)
          ? Text(
              L10n.text(
                _server.engine == BooruEngine.gelbooru
                    ? "The website didn't accept the saved account details. In the server's settings, enter the numeric User ID and the API key shown together in your account options on the website."
                    : "The website didn't accept the saved account details. Check the username and API key in the server's settings.",
              ),
              style: TegnalType.style(13, color: CupertinoColors.systemRed.resolveFrom(context)),
            )
          : Text(
              L10n.text(
                identity != null && !canChange
                    ? 'Your API key lets the app read your favorites and comments. To change favorites, vote or comment from the app, also sign in on the website.'
                    : _server.engine.keepsFavoriteLists
                    ? "Sign in on the website itself, or save your API key in the server's settings, to keep favorites, favorite groups, votes and comments there. The app keeps only the sign-in, on this device, never your password."
                    : "Sign in on the website itself, or save your API key in the server's settings, to keep favorites, votes and comments there. The app keeps only the sign-in, on this device, never your password.",
              ),
            ),
      children: [
        if (identity != null) ...[
          SettingsValueRow(title: L10n.text('Website Account'), value: identity.displayName.isEmpty ? L10n.text('Signed In') : identity.displayName),
          // An API key that only reads, or a sign-in the website stopped accepting.
          if (sync.expired.contains(_server.id) || !canChange)
            SettingsLinkRow(
              title: L10n.text(canChange ? 'Sign In Again' : 'Sign In to Website'),
              icon: canChange ? CupertinoIcons.exclamationmark_circle : CupertinoIcons.person_crop_circle,
              tinted: true,
              chevron: false,
              onTap: _signIn,
            ),
          ..._syncRows(sync),
        ] else
          SettingsLinkRow(title: L10n.text('Sign In to Website'), icon: CupertinoIcons.person_crop_circle, tinted: true, chevron: false, onTap: _signIn),
        ...widget.rows,
        if (identity != null) SettingsLinkRow(title: L10n.text('Sign Out'), destructive: true, chevron: false, onTap: _confirmSignOut),
      ],
    );
  }
}

/// `BooruSignInView`: the server's own sign-in page. The sign-in counts once the page shows the
/// account; its cookies then join the server's profile.
class BooruSignInPage extends StatefulWidget {
  const BooruSignInPage({super.key, required this.server});
  final BooruServer server;

  @override
  State<BooruSignInPage> createState() => _BooruSignInPageState();
}

class _BooruSignInPageState extends State<BooruSignInPage> {
  WebViewController? _controller;
  Timer? _watcher;
  double _progress = 0;
  bool _loading = true;
  bool _done = false;
  bool _checking = false;
  String? _failure;

  BooruServer get _server => widget.server;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _watcher?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    late final WebViewController controller;
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) =>
              _allows(Uri.tryParse(request.url), mainFrame: request.isMainFrame) ? NavigationDecision.navigate : NavigationDecision.prevent,
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onProgress: (value) {
            if (mounted) setState(() => _progress = value / 100);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
            _look(controller);
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
      );
    final agent = await controller.getUserAgent();
    if (agent != null) BooruBrowserSession.shared.userAgent = agent;
    await controller.loadRequest(_server.engine.signInURL(_server.baseURL));
    _watcher?.cancel();
    // Sign-in cookies can arrive without a finished page load, so the page is looked at every second.
    _watcher = Timer.periodic(const Duration(seconds: 1), (_) => _look(controller));
    if (mounted) setState(() => _controller = controller);
  }

  /// The server's own pages, and any secure frame a sign-in check shows inside them.
  bool _allows(Uri? url, {required bool mainFrame}) {
    if (url == null || url.scheme != 'https' && url.toString() != 'about:blank') return false;
    if (!mainFrame) return true;
    final site = SiteAccount.registrableDomain(Uri.tryParse(_server.baseURL)?.host.toLowerCase() ?? '');
    final host = url.host.toLowerCase();
    return host == site || host.endsWith('.$site');
  }

  Future<void> _look(WebViewController controller) async {
    if (_done || _checking || !mounted) return;
    final page = await controller.currentUrl();
    final url = page == null ? null : Uri.tryParse(page);
    if (url == null || !booruSameOrigin(url.toString(), _server.baseURL)) return;
    final header = await WebCookies.header(url);
    if (_server.engine == BooruEngine.danbooru) {
      // Danbooru names the signed-in account on every page; only then is it asked.
      final Object? user;
      try {
        user = await controller.runJavaScriptReturningResult("document.body ? (document.body.dataset.currentUserId || '') : ''");
      } on Object {
        return;
      }
      if ((int.tryParse('$user'.replaceAll('"', '')) ?? 0) <= 0) return;
    } else {
      final names = {for (final part in (header ?? '').split(';')) part.split('=').first.trim()};
      if (!(names.contains('pass_hash') && (names.contains('user_id') || names.contains('login')))) return;
    }
    _checking = true;
    try {
      BooruBrowserSession.shared.importCookieHeader(header, url.toString(), _server);
      final sync = BooruAccountSync.shared;
      final identity = await sync?.check(_server);
      if (sync == null || identity == null || _done) return;
      _done = true;
      _watcher?.cancel();
      unawaited(sync.signedIn(_server, identity));
      if (mounted) Navigator.of(context).pop();
    } finally {
      _checking = false;
    }
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
    } else {
      body = Column(
        children: [
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

/// `BooruScoreRow`: the image's score with the account's vote, opening the vote choices when the
/// account can vote.
class BooruScoreRow extends StatefulWidget {
  const BooruScoreRow({super.key, required this.server, required this.post});
  final BooruServer server;
  final BooruPost post;

  @override
  State<BooruScoreRow> createState() => _BooruScoreRowState();
}

class _BooruScoreRowState extends State<BooruScoreRow> {
  int? _score;
  BooruVote _vote = const BooruVote();
  bool _voting = false;

  BooruServer get _server => widget.server;
  BooruAccountIdentity? get _identity => BooruAccountSync.shared?.identity(_server);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(BooruScoreRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.post.id != widget.post.id) {
      _score = null;
      _vote = const BooruVote();
      _load();
    }
  }

  Future<void> _load() async {
    final identity = _identity;
    if (identity == null || !_server.engine.showsOwnVote) return;
    try {
      final vote = await BooruAccountClient.shared.vote(_server, widget.post.postID, identity);
      if (mounted) setState(() => _vote = vote);
    } on Object {
      // The score shows without the account's vote.
    }
  }

  Future<void> _choose() async {
    final engine = _server.engine;
    final current = _vote.score;
    final voted = engine.showsOwnVote && current != 0;
    final choice = await showCupertinoModalPopup<int>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        actions: [
          if (!voted || current < 0) CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, 1), child: Text(L10n.text('Vote Up'))),
          if (engine.votesDown && (!voted || current > 0))
            CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, -1), child: Text(L10n.text('Vote Down'))),
          if (voted) CupertinoActionSheetAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, 0), child: Text(L10n.text('Withdraw Vote'))),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (choice != null) await _cast(choice);
  }

  Future<void> _cast(int value) async {
    final identity = _identity;
    if (identity == null) return;
    setState(() => _voting = true);
    try {
      final current = _vote;
      final updated = await BooruAccountClient.shared.castVote(_server, widget.post.postID, value, current);
      BooruVote vote = BooruVote(score: value);
      if (_server.engine.showsOwnVote) {
        try {
          vote = await BooruAccountClient.shared.vote(_server, widget.post.postID, identity);
        } on Object {
          vote = BooruVote(score: value);
        }
      }
      if (mounted) {
        setState(() {
          _vote = vote;
          _score = updated ?? (_score ?? widget.post.score) + (value - current.score);
        });
      }
    } on Object catch (error) {
      if (mounted) {
        await showCupertinoDialog<void>(
          context: context,
          builder: (context) => TegnalAlertDialog(
            title: Text(L10n.text('Unable to Vote')),
            content: Text(error is SiteMessage ? error.text : BooruConnectionMessage.describe(error)),
            actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('OK')))],
          ),
        );
      }
    }
    if (mounted) setState(() => _voting = false);
  }

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final canVote = _identity != null && _server.engine.votesUp && BooruAccountClient.shared.canChange(_server);
    return FormRow(
      onTap: canVote && !_voting ? _choose : null,
      child: Semantics(
        button: canVote,
        label: L10n.text('Score'),
        child: Row(
          children: [
            Text(L10n.text('Score')),
            const Spacer(),
            if (_voting) ...[const CupertinoActivityIndicator(), const SizedBox(width: 6)],
            if (_vote.score > 0) ...[const Icon(CupertinoIcons.hand_thumbsup_fill, size: 18, color: CupertinoColors.systemGreen), const SizedBox(width: 6)],
            if (_vote.score < 0) ...[const Icon(CupertinoIcons.hand_thumbsdown_fill, size: 18, color: CupertinoColors.systemRed), const SizedBox(width: 6)],
            Text('${_score ?? widget.post.score}', style: TegnalType.style(17, color: secondary)),
            if (canVote) ...[const SizedBox(width: 6), Icon(CupertinoIcons.chevron_up_chevron_down, size: 13, color: secondary)],
          ],
        ),
      ),
    );
  }
}

/// `BooruCommentsSection`: the image's comments in its details: the newest few, all of them on
/// demand, and a comment of the account's own when it is signed in.
class BooruCommentsSection extends StatefulWidget {
  const BooruCommentsSection({super.key, required this.server, required this.postID, this.fixture = false});
  final BooruServer server;
  final int postID;

  /// Offline fixture runs show one comment without asking a website.
  final bool fixture;

  @override
  State<BooruCommentsSection> createState() => _BooruCommentsSectionState();
}

class _BooruCommentsSectionState extends State<BooruCommentsSection> {
  List<WorkComment>? _comments;
  String? _failure;

  BooruCommentProvider get _provider => BooruCommentProvider(widget.server);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(BooruCommentsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.postID != widget.postID || oldWidget.server.id != widget.server.id) _load();
  }

  Future<void> _load() async {
    setState(() {
      _comments = null;
      _failure = null;
    });
    final postID = widget.postID;
    if (widget.fixture) {
      setState(
        () => _comments = [
          WorkComment(id: 1, author: 'sample user', posted: DateTime.fromMillisecondsSinceEpoch(1790000000000, isUtc: true), score: 3, text: 'Lovely colors.'),
        ],
      );
      return;
    }
    try {
      final comments = await BooruAccountClient.shared.comments(widget.server, postID);
      if (mounted && postID == widget.postID) setState(() => _comments = comments);
    } on Object catch (error) {
      if (mounted && postID == widget.postID) setState(() => _failure = BooruConnectionMessage.describe(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    final comments = _comments;
    final signedIn = BooruAccountSync.shared?.identity(widget.server) != null && BooruAccountClient.shared.canChange(widget.server);
    Widget action(String title, IconData icon, VoidCallback onTap) => FormRow(
      separatorInset: settingsIconInset,
      onTap: onTap,
      child: Row(
        children: [
          SizedBox(width: 24, child: Icon(icon, size: 22, color: tint)),
          const SizedBox(width: 16),
          Expanded(
            child: Text(title, style: TegnalType.style(17, color: tint)),
          ),
        ],
      ),
    );
    return FormSection(
      rowColor: FormColors.row.resolveFrom(context),
      header: Text(L10n.text('Comments')),
      children: [
        if (comments != null) ...[
          if (comments.isEmpty)
            FormRow(
              child: Text(L10n.text('No Comments'), style: TegnalType.style(17, color: secondary)),
            ),
          for (final comment in comments.length > 3 ? comments.sublist(comments.length - 3) : comments)
            FormRow(child: WorkCommentRow(comment: comment, maxLines: 4)),
          if (comments.length > 3)
            action(
              '${L10n.text('All Comments')} (${comments.length})',
              CupertinoIcons.text_bubble,
              () => showAppSheet<void>(
                context,
                builder: (context, controller) => WorkCommentsPage(galleryID: widget.postID, initial: comments, loadsAll: false, provider: _provider),
              ),
            ),
        ] else if (_failure case final failure?) ...[
          FormRow(
            child: Text(failure, style: TegnalType.style(17, color: secondary)),
          ),
          FormRow(
            onTap: _load,
            child: Text(L10n.text('Try Again'), style: TegnalType.style(17, color: tint)),
          ),
        ] else
          FormRow(
            child: Row(
              children: [
                const CupertinoActivityIndicator(),
                const SizedBox(width: 12),
                Text(L10n.text('Loading Comments…'), style: TegnalType.style(17, color: secondary)),
              ],
            ),
          ),
        if (signedIn)
          action(
            L10n.text('Write Comment'),
            CupertinoIcons.square_pencil,
            () => showAppSheet<void>(
              context,
              builder: (context, controller) => WorkCommentComposerPage(
                galleryID: widget.postID,
                provider: _provider,
                posted: (comments) {
                  if (mounted) setState(() => _comments = comments);
                },
              ),
            ),
          ),
      ],
    );
  }
}
