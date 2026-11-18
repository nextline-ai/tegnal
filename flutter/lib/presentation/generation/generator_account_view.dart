import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/generation/generation_client.dart';
import '../../core/generation/generation_store.dart';
import '../../core/support/l10n.dart';
import '../design/grouped_form.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import '../settings/settings_page.dart';
import '../settings/settings_rows.dart';
import '../study/study_widgets.dart' show StudyStyle;
import 'generator_sheet.dart';

/// The API key: what it is for, saving it after Civitai accepts it, and removing it (`GeneratorAccountView`).
/// The key is only ever held in this field, in the Keystore and in requests to Civitai.
class GeneratorAccountView extends StatefulWidget {
  const GeneratorAccountView({super.key, required this.store});
  final GenerationStore store;

  @override
  State<GeneratorAccountView> createState() => _GeneratorAccountViewState();
}

class _GeneratorAccountViewState extends State<GeneratorAccountView> {
  final _key = TextEditingController();
  bool _checking = false;
  String? _message;
  GenerationAccount? _account;

  GenerationStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    _key.addListener(_changed);
    _store.addListener(_changed);
    _lookUp();
  }

  @override
  void dispose() {
    _store.removeListener(_changed);
    _key.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _lookUp() async {
    await _store.load();
    if (!mounted || !_store.hasKey || _account != null) return;
    try {
      final account = await _store.client().account();
      if (mounted) setState(() => _account = account);
    } on Object {
      // The name is a nicety; the key is saved either way.
    }
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _message = null;
    });
    final candidate = _key.text;
    String? message;
    GenerationAccount? account = _account;
    try {
      final found = await _store.clientFor(candidate).account();
      if (found.status == 'banned' || found.status == 'muted') message = L10n.text('This Civitai account is restricted (%@).', [found.status]);
      if (await _store.save(candidate)) {
        account = found;
        _key.clear();
      } else {
        message = L10n.text('The key could not be saved on this device.');
      }
    } on GenerationError catch (error) {
      message = error.message;
    } on Object catch (error) {
      message = '$error';
    }
    if (!mounted) return;
    setState(() {
      _checking = false;
      _message = message;
      _account = account;
    });
  }

  Future<void> _remove() async {
    if (!await _store.save('')) return;
    if (!mounted) return;
    _key.clear();
    setState(() => _account = null);
  }

  @override
  Widget build(BuildContext context) {
    final rowColor = FormColors.row.resolveFrom(context);
    final green = SystemColors.green.resolveFrom(context);
    final red = SystemColors.red.resolveFrom(context);
    final canCheck = !_checking && _key.text.trim().isNotEmpty;
    return GeneratorSheetPage(
      title: L10n.text('Civitai API Key'),
      trailing: GlassTextButton(key: const Key('generator.done'), label: L10n.text('Done'), prominent: true, onPressed: () => Navigator.of(context).pop()),
      children: [
        FormSection(
          rowColor: rowColor,
          footer: Text(L10n.text("Create a key on civitai.com under Account Settings, API Keys. It is kept in this device's keychain and sent only to Civitai.")),
          children: [
            FormRow(
              child: CupertinoTextField.borderless(
                key: const Key('generator.key'),
                controller: _key,
                padding: EdgeInsets.zero,
                placeholder: L10n.text('API Key'),
                placeholderStyle: TegnalType.style(17, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
                style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context)),
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.none,
                autofillHints: const [AutofillHints.password],
              ),
            ),
            FormRow(
              key: const Key('generator.saveKey'),
              onTap: canCheck ? _check : null,
              child: Opacity(
                opacity: canCheck || _checking ? 1 : 0.4,
                child: Row(
                  children: [
                    Expanded(child: Text(L10n.text('Check and Save'), style: TegnalType.style(17, color: StudyStyle.accent(context)))),
                    if (_checking) const CupertinoActivityIndicator(),
                  ],
                ),
              ),
            ),
            if (_account case final account?)
              FormRow(
                child: Row(
                  children: [
                    Icon(CupertinoIcons.checkmark_circle_fill, size: 20, color: green),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(L10n.text('Signed in as %@', [account.name]), key: const Key('generator.signedIn'), style: TegnalType.style(17, color: green)),
                    ),
                  ],
                ),
              ),
            if (_message case final message?)
              FormRow(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(CupertinoIcons.exclamationmark_triangle, size: 15, color: red),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(message, key: const Key('generator.keyMessage'), style: TegnalType.style(13, color: red)),
                    ),
                  ],
                ),
              ),
          ],
        ),
        settingsSectionGap,
        FormSection(
          rowColor: rowColor,
          footer: Text(
            L10n.text(
              "Each picture is paid for with Buzz from your Civitai account, and Civitai's rules apply to what you ask for. A key gives full access to the account, so remove it here and revoke it on Civitai if this device is lost.",
            ),
          ),
          children: [
            SettingsLinkRow(
              title: L10n.text('Open Civitai Account Settings'),
              icon: CupertinoIcons.compass,
              tinted: true,
              color: StudyStyle.accent(context),
              chevron: false,
              onTap: () => launchUrl(Uri.parse('https://civitai.com/user/account'), mode: LaunchMode.externalApplication),
            ),
          ],
        ),
        if (_store.hasKey) ...[
          settingsSectionGap,
          FormSection(
            rowColor: rowColor,
            children: [SettingsLinkRow(key: const Key('generator.removeKey'), title: L10n.text('Remove API Key'), destructive: true, chevron: false, onTap: _remove)],
          ),
        ],
      ],
    );
  }
}
