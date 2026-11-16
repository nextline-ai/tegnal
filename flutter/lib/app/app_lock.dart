import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../core/support/app_platform.dart';
import '../core/support/l10n.dart';
import '../core/support/privacy_settings.dart';
import '../presentation/design/grouped_form.dart';
import '../presentation/design/tegnal_theme.dart';

/// `AppLock`: the device's own unlock (fingerprint, face or screen lock) in front of the app.
/// Android only: on iPhone the system's per-app "Require Face ID" does this.
abstract final class AppLock {
  static const _channel = MethodChannel('work.nextline.tegnal/privacy');

  static bool get isAvailable => !AppPlatform.isDesktop;

  static Future<bool> canAuthenticate() async {
    if (!isAvailable) return false;
    try {
      return await _channel.invokeMethod<bool>('canAuthenticate') ?? false;
    } on Object {
      return false;
    }
  }

  static Future<bool> authenticate() async {
    try {
      return await _channel.invokeMethod<bool>('authenticate', {
            'title': L10n.text('Unlock TEGNAL'),
            'subtitle': L10n.text('Use your fingerprint, face or screen lock.'),
          }) ??
          false;
    } on Object {
      return false;
    }
  }

  /// Applies "Block Screenshots and Recording".
  static void applyScreenProtection() {
    if (!isAvailable) return;
    _channel.invokeMethod<void>('secure', PrivacySettings.protectsScreen).catchError((Object _) {});
  }
}

/// `AppLockGate`: covers the app until the device's unlock passes, at launch and whenever the
/// app comes back after staying away longer than the chosen time.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.child});
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> {
  late bool _locked = AppLock.isAvailable && PrivacySettings.locksApp;
  bool _authenticating = false;
  DateTime? _leftAt;
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(onHide: _left, onResume: _returned);

  @override
  void initState() {
    super.initState();
    _lifecycle;
    AppLock.applyScreenProtection();
    unawaited(SystemProxy.refresh());
    if (_locked) WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _left() {
    if (_authenticating || AppAway.isOnPurpose) return;
    _leftAt ??= DateTime.now();
  }

  void _returned() {
    unawaited(SystemProxy.refresh());
    final left = _leftAt;
    _leftAt = null;
    if (_locked || _authenticating || left == null || !AppLock.isAvailable || !PrivacySettings.locksApp) return;
    if (DateTime.now().difference(left).inSeconds < PrivacySettings.lockAfter) return;
    setState(() => _locked = true);
    _unlock();
  }

  Future<void> _unlock() async {
    if (_authenticating || !mounted) return;
    _authenticating = true;
    final passed = await AppLock.authenticate();
    _authenticating = false;
    if (passed && mounted) setState(() => _locked = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_locked) return widget.child;
    final label = TegnalColors.label.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Kept alive underneath so unlocking returns to the same place.
        Offstage(child: widget.child),
        ColoredBox(
          color: TegnalColors.background.resolveFrom(context),
          child: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(CupertinoIcons.lock_fill, size: 44, color: label),
                    const SizedBox(height: 16),
                    Text(L10n.text('TEGNAL Is Locked'), style: TegnalType.style(22, weight: FontWeight.w700, color: label), textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    Text(L10n.text('Use your fingerprint, face or screen lock.'), style: TegnalType.style(15, color: secondary), textAlign: TextAlign.center),
                    const SizedBox(height: 24),
                    GlassTextButton(label: L10n.text('Unlock'), prominent: true, onPressed: _unlock),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
