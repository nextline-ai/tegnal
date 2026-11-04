import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../core/support/mode_settings.dart';
import '../core/support/preferences.dart';

/// Tells the Android window cover (the native app's launch splash and app switcher privacy
/// cover) which artwork matches the app's appearance and whether returning animates.
abstract final class PrivacyCover {
  static const _channel = MethodChannel('work.nextline.tegnal/privacy');
  static (bool, bool)? _sent;

  static void configure({required bool dark, required bool resumeAnimation}) {
    if (_sent == (dark, resumeAnimation)) return;
    _sent = (dark, resumeAnimation);
    _channel.invokeMethod<void>('configure', {'dark': dark, 'resumeAnimation': resumeAnimation}).catchError((Object _) {});
  }

  /// Screen comparison runs start without the splash, as the native UI tests do.
  static void skipLaunchSplash() => _channel.invokeMethod<void>('skipLaunchSplash').catchError((Object _) {});
}

/// Keeps [PrivacyCover] in step with the app: on every appearance change, and whenever the
/// app is about to leave, when the returning-animation setting is read afresh.
class PrivacyCoverSync extends StatefulWidget {
  const PrivacyCoverSync({super.key, required this.preferences, required this.child});
  final Preferences preferences;
  final Widget child;

  @override
  State<PrivacyCoverSync> createState() => _PrivacyCoverSyncState();
}

class _PrivacyCoverSyncState extends State<PrivacyCoverSync> {
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(onInactive: _send, onHide: _send);

  @override
  void initState() {
    super.initState();
    _lifecycle;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _send() {
    if (!mounted) return;
    PrivacyCover.configure(dark: CupertinoTheme.brightnessOf(context) == Brightness.dark, resumeAnimation: ResumeAnimationSetting.stored(widget.preferences));
  }

  @override
  Widget build(BuildContext context) {
    // Sent after the frame, so the appearance is the one now on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) => _send());
    return widget.child;
  }
}
