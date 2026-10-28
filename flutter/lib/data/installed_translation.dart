import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum InstalledTranslationAvailability {
  direct,
  manualImport,
  missing,
  unsupported,
}

class InstalledTranslationException implements Exception {
  const InstalledTranslationException(this.message);
  final String message;
}

/// An installed Google Translate handoff, never an OCR/model/network client.
class InstalledTranslation {
  static const _channel = MethodChannel(
    'work.nextline.tegnal/installed_translation',
  );
  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<InstalledTranslationAvailability> availability() async {
    if (!_supported) return InstalledTranslationAvailability.unsupported;
    try {
      return switch (await _channel.invokeMethod<String>('capability')) {
        'direct' => InstalledTranslationAvailability.direct,
        'manual' => InstalledTranslationAvailability.manualImport,
        'missing' => InstalledTranslationAvailability.missing,
        _ => InstalledTranslationAvailability.unsupported,
      };
    } on MissingPluginException {
      return InstalledTranslationAvailability.unsupported;
    } on PlatformException {
      return InstalledTranslationAvailability.unsupported;
    }
  }

  /// [manualImport] is true only after the user explicitly chooses the gallery
  /// save fallback; image sharing never silently creates a public image.
  static Future<void> sendImage(
    Uint8List png, {
    bool manualImport = false,
  }) async {
    if (!_supported) {
      throw const InstalledTranslationException(
        'Google Translate image handoff is available in the Android app.',
      );
    }
    if (png.isEmpty || png.length > 32 * 1024 * 1024) {
      throw const InstalledTranslationException(
        'Unable to prepare the visible image.',
      );
    }
    try {
      await _channel.invokeMethod<void>(
        manualImport ? 'saveImageAndOpen' : 'shareImage',
        {'png': png},
      );
    } on MissingPluginException {
      throw const InstalledTranslationException(
        'Google Translate image handoff is available in the Android app.',
      );
    } on PlatformException {
      throw const InstalledTranslationException(
        'Google Translate could not open this image.',
      );
    }
  }
}
