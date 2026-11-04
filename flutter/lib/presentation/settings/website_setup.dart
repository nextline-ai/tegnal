import 'dart:async';
import 'dart:convert';

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/booru/booru_browser.dart';
import '../../core/booru/booru_models.dart';
import '../../core/booru/booru_store.dart';
import '../../core/content/content_environment.dart';
import '../../core/content/fixture_content_source.dart';
import '../../core/content/manga_urls.dart';
import '../../core/support/l10n.dart';
import '../design/app_sheet.dart';
import '../design/grouped_form.dart';
import '../design/symbols.dart';
import '../design/system_colors.dart';
import 'settings_page.dart';
import 'settings_rows.dart';
import '../design/tegnal_theme.dart';
import '../navigation/app_state.dart';
import '../../core/content/content_transport.dart';
import '../../core/content/content_errors.dart';
import '../../core/support/perf_trace.dart';

/// What an address turned out to be: a comics site or an image board engine.
sealed class ServerType {
  const ServerType();
  static const comics = ComicsServer();

  String get title;
  IconData get icon;

  /// Recognition by page structure only. Image boards name their engine in the page.
  static ServerType? recognizing(String html) {
    if (MangaUrls.isDocumentPage(html) || MangaUrls.isIndexedPage(html)) return comics;
    if (RegExp(r'''Danbooru\.|content=["']Danbooru''').hasMatch(html)) return const BooruServerType(BooruEngine.danbooru);
    if (RegExp(r'Gelbooru\s+Beta\s+0\.1\.11', caseSensitive: false).hasMatch(html)) return const BooruServerType(BooruEngine.oldGelbooru);
    if (html.toLowerCase().contains('moebooru')) return const BooruServerType(BooruEngine.moebooru);
    if (html.toLowerCase().contains('gelbooru')) return const BooruServerType(BooruEngine.gelbooru);
    return null;
  }

  /// Loads the home page once and recognizes it. The offline run reads the fixture pages.
  static Future<ServerType?> detect(Uri url) async {
    if (ContentPreferences.isIsolated) return recognizing(await FixtureWebsites.html(url));
    final html = await PerfTrace.span('website inspect', () => inspectWebsite(url), detail: url.host);
    return recognizing(html);
  }

  /// A plain, bounded GET of a website's home page.
  static Future<String> inspectWebsite(Uri url, {int limit = 2 * 1024 * 1024}) async {
    // The app's own connection, so a site whose name the network filters is reached with ECH.
    final fetcher = ContentTransport.defaultFetcher();
    var current = url;
    for (var redirects = 0; ; redirects++) {
      final reply = await fetcher.send(
        HttpExchange(method: 'GET', url: current, headers: const {'accept': 'text/html,application/xhtml+xml'}, timeout: const Duration(seconds: 20)),
      );
      final location = reply.headers.entries.where((entry) => entry.key.toLowerCase() == 'location').firstOrNull?.value.firstOrNull;
      if (reply.statusCode >= 300 && reply.statusCode < 400 && location != null && redirects < 5) {
        reply.abort?.call();
        final next = current.resolve(location);
        if (next.scheme != 'https') throw const NetworkError(NetworkErrorCode.unsupportedURL);
        current = next;
        continue;
      }
      final bytes = <int>[];
      await for (final chunk in reply.body.timeout(const Duration(seconds: 20))) {
        bytes.addAll(chunk);
        if (bytes.length > limit) break;
      }
      return utf8.decode(bytes, allowMalformed: true);
    }
  }
}

class ComicsServer extends ServerType {
  const ComicsServer();
  @override
  String get title => L10n.text('Comics Mode');
  @override
  IconData get icon => Symbols.book;
  @override
  bool operator ==(Object other) => other is ComicsServer;
  @override
  int get hashCode => 0;
}

class BooruServerType extends ServerType {
  const BooruServerType(this.engine);
  final BooruEngine engine;
  @override
  String get title => engine.title;
  @override
  IconData get icon => CupertinoIcons.checkmark_circle;
  @override
  bool operator ==(Object other) => other is BooruServerType && other.engine == engine;
  @override
  int get hashCode => engine.hashCode;
}

/// `WebsiteSetupContent`: the neutral first step when no website is connected.
class WebsiteSetupView extends StatelessWidget {
  const WebsiteSetupView({super.key, required this.content, required this.state, this.booru, this.importLinks, this.topInset = 0, this.bottomInset = 0});
  final ContentEnvironment content;
  final AppState state;
  final BooruStore? booru;

  /// `WebsiteImportLinks`, below the mode guide.
  final Widget? importLinks;
  final double topInset;
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    return ColoredBox(
      color: TegnalColors.background.resolveFrom(context),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(24, topInset + 24, 24, bottomInset + 24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(CupertinoIcons.link, size: 58, color: tint),
                const SizedBox(height: 24),
                Text(
                  L10n.text('Connect a Website'),
                  style: TegnalType.style(34, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
                ),
                const SizedBox(height: 24),
                Text(
                  L10n.text('Enter a comics or image website. We’ll detect its type and switch to the right mode.'),
                  style: TegnalType.style(17, color: secondary).copyWith(height: 1.3),
                ),
                const SizedBox(height: 24),
                _ProminentButton(
                  icon: CupertinoIcons.link,
                  label: L10n.text('Enter Website Address'),
                  onPressed: () => showWebsiteConnectionEditor(context, content: content, state: state, booru: booru),
                ),
                const SizedBox(height: 24),
                const WebsiteModeGuide(),
                if (importLinks != null) ...[const SizedBox(height: 24), importLinks!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `.borderedProminent` with `.controlSize(.large)`: a filled tint capsule.
class _ProminentButton extends StatelessWidget {
  const _ProminentButton({required this.icon, required this.label, required this.onPressed});
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    child: CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      child: Container(
        height: 66,
        alignment: Alignment.center,
        decoration: ShapeDecoration(color: TegnalColors.tint.resolveFrom(context), shape: const StadiumBorder()),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 21, color: const Color(0xFFFFFFFF)),
            const SizedBox(width: 8),
            Text(
              label,
              style: TegnalType.style(17, weight: FontWeight.w500, color: const Color(0xFFFFFFFF)),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The two modes, explained before a website is connected.
class WebsiteModeGuide extends StatelessWidget {
  const WebsiteModeGuide({super.key});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _mode(context, L10n.text('Comics Mode'), 'Read multi-page works by their work number.', Symbols.book),
      const SizedBox(height: 12),
      _mode(context, L10n.text('Image Mode'), 'Browse individual images using tags.', Symbols.photo),
    ],
  );

  Widget _mode(BuildContext context, String title, String description, IconData icon) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(width: 24, child: Icon(icon, size: 20, color: TegnalColors.tint.resolveFrom(context))),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TegnalType.style(15, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
            ),
            const SizedBox(height: 3),
            Text(L10n.text(description), style: TegnalType.style(13, color: TegnalColors.secondaryLabel.resolveFrom(context))),
          ],
        ),
      ),
    ],
  );
}

Future<void> showWebsiteConnectionEditor(
  BuildContext context, {
  required ContentEnvironment content,
  required AppState state,
  BooruStore? booru,
  BooruServer? server,
  String initialAddress = '',
  void Function(BuildContext context, BooruServer server)? validate,
  void Function(BuildContext context, BooruServer server)? cookies,
}) => showAppSheet<void>(
  context,
  builder: (context, controller) => WebsiteConnectionEditor(
    content: content,
    state: state,
    booru: booru,
    server: server,
    initialAddress: initialAddress,
    validate: validate,
    cookies: cookies,
    scrollController: controller,
  ),
);

/// `WebsiteConnectionEditor`: a new website's address and detected mode, or an image
/// server's name and account, with Save.
class WebsiteConnectionEditor extends StatefulWidget {
  const WebsiteConnectionEditor({
    super.key,
    required this.content,
    required this.state,
    this.booru,
    this.server,
    this.initialAddress = '',
    this.validate,
    this.cookies,
    this.scrollController,
  });
  final ContentEnvironment content;
  final AppState state;

  /// Where image servers are saved; without it only comics websites can be connected.
  final BooruStore? booru;

  /// The image server being edited. Its address and mode stay fixed.
  final BooruServer? server;
  final String initialAddress;

  /// Opens the server's validation browser and its cookies while editing.
  final void Function(BuildContext context, BooruServer server)? validate;
  final void Function(BuildContext context, BooruServer server)? cookies;
  final ScrollController? scrollController;

  @override
  State<WebsiteConnectionEditor> createState() => _WebsiteConnectionEditorState();
}

enum _DetectionPhase { idle, checking, recognized, unrecognized, failed }

class _WebsiteConnectionEditorState extends State<WebsiteConnectionEditor> {
  late final _address = TextEditingController(text: widget.server?.baseURL ?? widget.initialAddress);
  late final _name = TextEditingController(text: widget.server?.displayName ?? '');
  late final _account = TextEditingController();
  late final _apiKey = TextEditingController();
  late ServerType? _choice = widget.server == null ? null : BooruServerType(widget.server!.engine);
  late bool _automatic = widget.server == null;
  late bool _showOptions = widget.server != null;
  bool get _allowsComics => widget.server == null;
  _DetectionPhase _phase = _DetectionPhase.idle;
  ServerType? _detected;
  String? _detectedFor;
  String? _error;
  Timer? _debounce;
  int _generation = 0;

  Uri? get _addressURL {
    try {
      return Uri.parse(BooruServer.validatedURL(_address.text));
    } on Object {
      return null;
    }
  }

  ServerType? get _effective => _automatic ? (_detectedFor == _addressURL?.toString() ? _detected : null) : _choice;

  @override
  void initState() {
    super.initState();
    final server = widget.server;
    if (server != null) {
      try {
        final credentials = widget.booru!.credentials.read(server.id);
        _account.text = credentials.account;
        _apiKey.text = credentials.apiKey;
      } on Object catch (error) {
        _error = '$error';
      }
    }
    _address.addListener(_addressChanged);
    _addressChanged();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _address.dispose();
    _name.dispose();
    _account.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  void _addressChanged() {
    _debounce?.cancel();
    if (widget.server != null) return setState(() {});
    final url = _addressURL;
    final generation = ++_generation;
    setState(() {
      _phase = _DetectionPhase.idle;
      _detected = null;
      _detectedFor = null;
    });
    if (url == null) return;
    setState(() => _phase = _DetectionPhase.checking);
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      try {
        final type = await ServerType.detect(url);
        if (!mounted || generation != _generation) return;
        setState(() {
          _detected = type;
          _detectedFor = url.toString();
          _phase = type == null ? _DetectionPhase.unrecognized : _DetectionPhase.recognized;
        });
      } on Object {
        if (mounted && generation == _generation) setState(() => _phase = _DetectionPhase.failed);
      }
    });
  }

  void _save() {
    switch (_effective) {
      case ComicsServer():
        if (widget.content.verifySite(_address.text)) {
          Navigator.of(context).pop();
          widget.state.mode = AppMode.manga;
        } else {
          setState(() => _error = L10n.text('This address is not supported. Check the website address and try again.'));
        }
      case BooruServerType(:final engine):
        final store = widget.booru;
        if (store == null) return setState(() => _error = L10n.text('This server does not expose this feature.'));
        try {
          final url = BooruServer.validatedURL(_address.text);
          final name = _name.text.trim();
          final value = BooruServer(
            id: widget.server?.id,
            name: name.isEmpty ? (Uri.parse(url).host.isEmpty ? url : Uri.parse(url).host) : name,
            baseURL: url,
            engine: engine,
          );
          if (store.servers.any((server) => server.id != value.id && server.baseURL == url)) throw const BooruError(BooruErrorKind.duplicateServer);
          final credentials = BooruCredentials(account: _account.text.trim(), apiKey: _apiKey.text.trim());
          if (credentials.account.isEmpty != credentials.apiKey.isEmpty) throw const BooruError(BooruErrorKind.authentication);
          store.credentials.save(credentials, value.id);
          store.saveServer(value);
          if (widget.server == null) store.setSelectedServers([...store.selectedServerIDs, value.id]);
          Navigator.of(context).pop();
          widget.state.mode = AppMode.booru;
        } on Object catch (error) {
          setState(() => _error = BooruConnectionMessage.describe(error));
        }
      case null:
        break;
    }
  }

  Future<void> _pickMode() async {
    final options = <(ServerType?, String)>[
      (null, L10n.text('Automatic')),
      if (_allowsComics) (ServerType.comics, L10n.text('Comics Mode')),
      for (final engine in BooruEngine.values) (BooruServerType(engine), '${L10n.text('Image Mode')} · ${engine.title}'),
    ];
    final picked = await showCupertinoModalPopup<(ServerType?, String)>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(L10n.text('Mode')),
        actions: [for (final option in options) CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, option), child: Text(option.$2))],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (picked == null) return;
    setState(() {
      _automatic = picked.$1 == null;
      _choice = picked.$1;
    });
  }

  Widget _field(TextEditingController controller, String placeholder, {bool secure = false}) => FormRow(
    child: CupertinoTextField.borderless(
      controller: controller,
      padding: EdgeInsets.zero,
      placeholder: placeholder,
      obscureText: secure,
      autocorrect: false,
      enableSuggestions: false,
      style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context)),
      placeholderStyle: TegnalType.style(17, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final effective = _effective;
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    final canSave = _address.text.trim().isNotEmpty && effective != null;
    return CupertinoPageScaffold(
      backgroundColor: FormColors.background.resolveFrom(context),
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            SheetNavigationBar(
              title: L10n.text(widget.server == null ? 'Connect a Website' : 'Edit Server'),
              leading: GlassTextButton(label: L10n.text('Cancel'), onPressed: () => Navigator.of(context).pop()),
              trailing: GlassTextButton(label: L10n.text('Save'), prominent: true, onPressed: canSave ? _save : null),
            ),
            Expanded(
              child: ListView(
                controller: widget.scrollController,
                padding: const EdgeInsets.only(top: 8, bottom: 32),
                children: [
                  FormSection(
                    header: Row(
                      children: [
                        Text(L10n.text('Website Address')),
                        const SizedBox(width: 4),
                        FormHelpButton(
                          title: L10n.text('Website Address'),
                          message: L10n.text('Enter the website’s home address. Automatic identifies the website and opens the matching Comics or Image mode.'),
                        ),
                      ],
                    ),
                    children: [
                      FormRow(
                        child: CupertinoTextField.borderless(
                          controller: _address,
                          enabled: widget.server == null,
                          padding: EdgeInsets.zero,
                          placeholder: 'https://example.com',
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          enableSuggestions: false,
                          style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context)),
                          placeholderStyle: TegnalType.style(17, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 26),
                  FormSection(
                    header: Text(L10n.text('Connection')),
                    children: [
                      FormRow(
                        onTap: _pickMode,
                        child: Row(
                          children: [
                            Expanded(child: Text(L10n.text('Mode'))),
                            Text(_automatic ? L10n.text('Automatic') : _choice!.title, style: TegnalType.style(17, color: secondary)),
                            const SizedBox(width: 4),
                            Icon(CupertinoIcons.chevron_up_chevron_down, size: 15, color: secondary),
                          ],
                        ),
                      ),
                      if (_automatic && _phase == _DetectionPhase.checking)
                        FormRow(
                          child: Row(
                            children: [
                              const CupertinoActivityIndicator(),
                              const SizedBox(width: 10),
                              Text(L10n.text('Identifying website…'), style: TegnalType.style(17, color: secondary)),
                            ],
                          ),
                        )
                      else if (effective != null)
                        FormRow(
                          child: Row(
                            children: [
                              Icon(effective.icon, size: 22, color: tint),
                              const SizedBox(width: 12),
                              Text(effective is ComicsServer ? L10n.text('Comics Mode') : L10n.text('Image Mode'), style: TegnalType.style(17, color: tint)),
                            ],
                          ),
                        )
                      else if (_address.text.trim().isNotEmpty)
                        FormRow(
                          child: Text(
                            L10n.text('Couldn’t identify this website. Check the connection or select its mode manually.'),
                            style: TegnalType.style(13, color: secondary),
                          ),
                        ),
                    ],
                  ),
                  if (_automatic && (_phase == _DetectionPhase.failed || _phase == _DetectionPhase.unrecognized)) ...[
                    const SizedBox(height: 26),
                    FormSection(
                      children: [
                        FormRow(
                          onTap: _addressChanged,
                          child: Text(L10n.text('Try Again'), style: TegnalType.style(17, color: tint)),
                        ),
                      ],
                    ),
                  ],
                  if (effective case BooruServerType(:final engine)) ...[
                    const SizedBox(height: 26),
                    FormSection(
                      children: [
                        FormRow(
                          onTap: () => setState(() => _showOptions = !_showOptions),
                          child: Row(
                            children: [
                              Text(L10n.text('Additional Options')),
                              const SizedBox(width: 4),
                              FormHelpButton(
                                title: L10n.text('Additional Options'),
                                message: L10n.text(
                                  'Optional account details can improve access on some websites. Copy them from that website’s account settings; they are stored securely in Keychain.',
                                ),
                              ),
                              const Spacer(),
                              AnimatedRotation(
                                turns: _showOptions ? 0.25 : 0,
                                duration: const Duration(milliseconds: 200),
                                child: Icon(CupertinoIcons.chevron_right, size: 15, color: tint),
                              ),
                            ],
                          ),
                        ),
                        if (_showOptions) ...[
                          _field(_name, L10n.text('Name (Optional)')),
                          if (engine != BooruEngine.oldGelbooru) ...[
                            _field(_account, L10n.text(engine == BooruEngine.gelbooru ? 'User ID' : 'Username')),
                            _field(_apiKey, L10n.text(engine == BooruEngine.moebooru ? 'Password Hash' : 'API Key'), secure: true),
                          ],
                        ],
                      ],
                    ),
                  ],
                  if (widget.server case final server?) ...[
                    const SizedBox(height: 26),
                    FormSection(
                      children: [
                        FormRow(
                          onTap: widget.validate == null ? null : () => widget.validate!(context, server),
                          child: Row(
                            children: [
                              Icon(CupertinoIcons.checkmark_shield, size: 22, color: tint),
                              const SizedBox(width: 12),
                              Text(L10n.text('Validate Client'), style: TegnalType.style(17, color: tint)),
                            ],
                          ),
                        ),
                        FormRow(
                          onTap: widget.cookies == null ? null : () => widget.cookies!(context, server),
                          child: Row(
                            children: [
                              Icon(CupertinoIcons.shield_lefthalf_fill, size: 22, color: tint),
                              const SizedBox(width: 12),
                              Expanded(child: Text(L10n.text('Cookies'))),
                              Icon(CupertinoIcons.chevron_right, size: 14, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 26),
                    FormSection(
                      children: [
                        FormRow(
                          child: Text(_error!, style: TegnalType.style(17, color: CupertinoColors.systemRed.resolveFrom(context))),
                        ),
                      ],
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

/// `ComicSitesView`: the connected comics websites. Tap one to use it, swipe to remove it, or
/// add another.
class ComicSitesPage extends StatefulWidget {
  const ComicSitesPage({super.key, required this.content, required this.state});
  final ContentEnvironment content;
  final AppState state;

  @override
  State<ComicSitesPage> createState() => _ComicSitesPageState();
}

class _ComicSitesPageState extends State<ComicSitesPage> {
  ContentEnvironment get _content => widget.content;

  @override
  void initState() {
    super.initState();
    _content.addListener(_changed);
  }

  @override
  void dispose() {
    _content.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    final row = FormColors.listRow.resolveFrom(context);
    return SettingsPage(
      title: L10n.text('Website Connection'),
      children: [
        FormSection(
          rowColor: row,
          footer: Text(
            L10n.text(
              'Lists, searches and new saves use the checked website. Saved works remember where they were saved, and a website that numbers its works the same way can open them too.',
            ),
          ),
          children: [
            for (final site in _content.comicSites)
              Dismissible(
                key: ValueKey(site),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: SystemColors.red.resolveFrom(context),
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  child: Text(L10n.text('Delete'), style: TegnalType.style(17, color: const Color(0xFFFFFFFF))),
                ),
                onDismissed: (_) => _content.removeComicsSite(site),
                child: FormRow(
                  onTap: () => _content.switchComicsSite(site),
                  child: Row(
                    children: [
                      Expanded(child: Text(site, maxLines: 1, overflow: TextOverflow.ellipsis)),
                      if (site == _content.mangaSiteAddress) Icon(CupertinoIcons.checkmark_alt, size: 20, color: tint),
                    ],
                  ),
                ),
              ),
          ],
        ),
        settingsSectionGap,
        FormSection(
          rowColor: row,
          children: [
            SettingsLinkRow(
              title: L10n.text('Add Website'),
              icon: CupertinoIcons.plus,
              tinted: true,
              chevron: false,
              onTap: () => showWebsiteConnectionEditor(context, content: _content, state: widget.state),
            ),
          ],
        ),
      ],
    );
  }
}
