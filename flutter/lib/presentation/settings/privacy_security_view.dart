import 'package:cupertino_ui/cupertino_ui.dart';

import '../../app/app_lock.dart';
import '../../core/content/manga_urls.dart';
import '../../core/support/l10n.dart';
import '../../core/support/privacy_settings.dart';
import '../design/grouped_form.dart';
import 'settings_page.dart';
import 'settings_rows.dart';

/// `PrivacySecurityView`.
class PrivacySecurityView extends StatefulWidget {
  const PrivacySecurityView({super.key});

  @override
  State<PrivacySecurityView> createState() => _PrivacySecurityViewState();
}

class _PrivacySecurityViewState extends State<PrivacySecurityView> {
  bool? _canLock;

  @override
  void initState() {
    super.initState();
    AppLock.canAuthenticate().then((value) {
      if (mounted) setState(() => _canLock = value);
    });
  }

  void _set(String key, Object value) {
    ContentPreferences.defaults.set(key, value);
    setState(() {});
  }

  Future<void> _setLock(bool on) async {
    // Turning the lock on proves the person can pass it first.
    if (on && !await AppLock.authenticate()) return;
    _set(PrivacySettings.appLockKey, on);
  }

  String _lockAfterTitle(int seconds) => switch (seconds) {
    0 => L10n.text('Immediately'),
    60 => L10n.text('After 1 Minute'),
    300 => L10n.text('After 5 Minutes'),
    _ => L10n.text('After 15 Minutes'),
  };

  @override
  Widget build(BuildContext context) {
    final row = FormColors.listRow.resolveFrom(context);
    final canLock = _canLock ?? false;
    return SettingsPage(
      title: L10n.text('Privacy & Security'),
      children: [
        FormSection(
          rowColor: row,
          footer: Text(
            L10n.text(
              'While on, works you open, searches and viewing time aren’t recorded, and nothing is learned for recommendations. Works you save still go to your library.',
            ),
          ),
          children: [
            SettingsToggleRow(
              title: L10n.text('Incognito Mode'),
              value: PrivacySettings.isIncognito,
              onChanged: (value) => setState(() => PrivacySettings.setIncognito(value)),
            ),
          ],
        ),
        if (AppLock.isAvailable) ...[
          settingsSectionGap,
          FormSection(
            rowColor: row,
            footer: Text(L10n.text('Screenshots and screen recordings show a blank screen. The app switcher always shows the cover instead of your library.')),
            children: [
              SettingsToggleRow(
                title: L10n.text('Block Screenshots and Recording'),
                value: PrivacySettings.protectsScreen,
                onChanged: (value) {
                  _set(PrivacySettings.screenProtectionKey, value);
                  AppLock.applyScreenProtection();
                },
              ),
            ],
          ),
          settingsSectionGap,
          FormSection(
            rowColor: row,
            header: Text(L10n.text('App Lock')),
            footer: Text(
              L10n.text(
                _canLock == false
                    ? 'Set up a screen lock on this device to use App Lock.'
                    : 'Asks for your fingerprint, face or screen lock when TEGNAL opens or comes back.',
              ),
            ),
            children: [
              SettingsToggleRow(
                title: L10n.text('Lock TEGNAL'),
                value: PrivacySettings.locksApp && canLock,
                onChanged: canLock ? _setLock : null,
              ),
              if (PrivacySettings.locksApp && canLock)
                SettingsPickerRow<int>(
                  title: L10n.text('Lock After'),
                  options: [for (final seconds in PrivacySettings.lockAfterChoices) (seconds, _lockAfterTitle(seconds))],
                  selected: PrivacySettings.lockAfter,
                  onSelected: (value) => _set(PrivacySettings.lockAfterKey, value),
                ),
            ],
          ),
        ],
        settingsSectionGap,
        FormSection(
          rowColor: row,
          header: Text(L10n.text('Network')),
          footer: Text(
            L10n.text(
              'Looks up website addresses over an encrypted connection, so the network can’t see or change them. Website checks and the in-app browser use the system’s DNS.',
            ),
          ),
          children: [
            SettingsPickerRow<EncryptedDNS>(
              title: L10n.text('Encrypted DNS'),
              options: [for (final choice in EncryptedDNS.values) (choice, choice.title)],
              selected: EncryptedDNS.current,
              onSelected: (value) => _set(PrivacySettings.encryptedDNSKey, value.name),
            ),
          ],
        ),
      ],
    );
  }
}
