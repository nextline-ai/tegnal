import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/support/mode_settings.dart';
import '../core/support/preferences.dart';

/// Tells the Android window cover (the native app's launch screen and app switcher privacy
/// cover: the home scene's blurred still) whether returning animates, and when the home
/// scene's first picture is on screen so the launch cover can leave.
abstract final class PrivacyCover {
  static const _channel = MethodChannel('work.nextline.tegnal/privacy');
  static bool? _sent;

  static void configure({required bool resumeAnimation}) {
    if (_sent == resumeAnimation) return;
    _sent = resumeAnimation;
    _channel.invokeMethod<void>('configure', {'resumeAnimation': resumeAnimation}).catchError((Object _) {});
  }

  /// Screen comparison runs start without the launch cover, as the native UI tests do.
  static void skipLaunchSplash() => _channel.invokeMethod<void>('skipLaunchSplash').catchError((Object _) {});

  /// The home scene's still is on screen: the launch cover fades out (call once).
  static void launchReady() => _channel.invokeMethod<void>('launchReady').catchError((Object _) {});
}

/// Keeps [PrivacyCover] in step with the app: after every build, and whenever the app is
/// about to leave, when the returning-animation setting is read afresh.
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
    PrivacyCover.configure(resumeAnimation: ResumeAnimationSetting.stored(widget.preferences));
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _send());
    return widget.child;
  }
}
