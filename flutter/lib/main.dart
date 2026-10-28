import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart'
    show LicenseRegistry, LicenseEntryWithLineBreaks;
import 'package:flutter/services.dart' show rootBundle;
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'app.dart';
import 'core/app_controller.dart';
import 'core/app_features.dart';
import 'core/drive_sync_controller.dart';
import 'ui/design_system.dart';
import 'data/download_manager.dart';
import 'data/library_store.dart';
import 'ui/l10n.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Pretendard',
      'Pretendard JP',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  try {
    await L10n.load();
    MediaKit.ensureInitialized();
    final support = await getApplicationSupportDirectory();
    await support.create(recursive: true);
    final store = LibraryStore(sqlite3.open('${support.path}/tegnal.sqlite'));
    final controller = AppController(store);
    final downloads = DownloadManager(
      store,
      Directory('${support.path}/downloads'),
      refreshPages: controller.pages,
    );
    DriveSyncController? driveSync;
    if (AppFeatures.googleDriveSyncEnabled) {
      driveSync = DriveSyncController(
        library: controller,
        stateDirectory: Directory('${support.path}/drive-sync'),
      );
      await driveSync.initialize();
    }
    runApp(
      TegnalApp(
        controller: controller,
        downloads: downloads,
        driveSync: driveSync,
      ),
    );
  } catch (error, stack) {
    // Opening errors must never silently reset the user's library.
    debugPrint('TEGNAL startup failed: $error\n$stack');
    runApp(
      MaterialApp(
        theme: tegnalTheme(Brightness.light),
        darkTheme: tegnalTheme(Brightness.dark),
        themeMode: ThemeMode.dark,
        home: const _StartupFailure(),
      ),
    );
  }
}

class _StartupFailure extends StatelessWidget {
  const _StartupFailure();
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.warning_amber_rounded, size: 42),
              const SizedBox(height: 20),
              Text(
                L10n.tr(context, 'Unable to open TEGNAL'),
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                L10n.tr(
                  context,
                  'Your library has been kept. Close the app and try again.',
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
