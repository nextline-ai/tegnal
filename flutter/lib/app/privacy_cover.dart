import 'package:flutter/services.dart';

/// Tells the Android window cover (the native app's launch screen and app switcher privacy
/// cover: the home scene's blurred still) when the home scene's first picture is on screen,
/// so the launch cover can leave. Returning from the app switcher always fades, as on iOS.
abstract final class PrivacyCover {
  static const _channel = MethodChannel('work.nextline.tegnal/privacy');

  /// Screen comparison runs start without the launch cover, as the native UI tests do.
  static void skipLaunchSplash() => _channel.invokeMethod<void>('skipLaunchSplash').catchError((Object _) {});

  /// The home scene's still is on screen: the launch cover fades out (call once).
  static void launchReady() => _channel.invokeMethod<void>('launchReady').catchError((Object _) {});
}
