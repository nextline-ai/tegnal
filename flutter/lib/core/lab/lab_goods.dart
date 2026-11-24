import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../addons/addon_market.dart';
import '../addons/addon_models.dart';
import '../addons/addon_store.dart';
import '../booru/booru_store.dart';
import '../support/l10n.dart';
import 'lab_course_file.dart';
import 'lab_shop.dart';
import 'learning_courses.dart';

/// Brings what was bought in the shop onto this device: course files, add-ons and home scenes, each downloaded from TEGNAL's
/// server and checked against the size and SHA-256 the signed shop list gives. Purchases travel between devices in the lab's
/// records; the files do not, so a device that has the purchase but not the files offers to download them again, for free.
/// Ported from `LabGoods.swift`.
class LabGoods extends ChangeNotifier {
  // ignore: prefer_initializing_formals
  LabGoods({AddonMarket? market, LearningCourses? courses}) : market = market ?? AddonMarket.live, _courses = courses;

  static final LabGoods shared = LabGoods();

  AddonMarket market;
  final LearningCourses? _courses;
  LearningCourses get courses => _courses ?? LearningCourses.shared;
  BooruStore? _booru;

  /// Items being downloaded now.
  final Set<String> working = {};

  /// The last failure for an item, to show on its card.
  final Map<String, String> failures = {};

  /// Installed add-ons, by id: version and whether the copy is the official one.
  Map<String, ({String version, bool official})> addons = {};

  /// Called when the app starts, so add-ons can be installed into the image database.
  void attach(BooruStore booru) {
    _booru = booru;
    readAddons();
  }

  void readAddons() {
    final booru = _booru;
    if (booru == null) return;
    try {
      addons = {for (final installed in AddonStore(booru.database).installed()) installed.addon.id: (version: installed.addon.version, official: installed.official)};
    } on Object {
      // Left as it was.
    }
  }

  // MARK: State

  /// True when an owned item needs nothing more on this device.
  bool delivered(LabShopItem item) {
    if (item.file != null) return courses.has(item.id);
    final addon = item.addon;
    if (addon != null) {
      final installed = addons[addon.id];
      return installed != null && installed.official && AddonCheck.compare(installed.version, addon.version) >= 0;
    }
    final home = item.home;
    if (home != null) return HomeScenes.has(item.id, home);
    return true;
  }

  /// True when an older copy of an owned add-on or home scene is here and a newer one is for sale.
  bool outdated(LabShopItem item) {
    final addon = item.addon;
    if (addon != null) {
      final installed = addons[addon.id];
      return installed != null && installed.official && AddonCheck.compare(installed.version, addon.version) < 0;
    }
    final home = item.home;
    if (home != null) return HomeScenes.kept(item.id) && !HomeScenes.has(item.id, home);
    return false;
  }

  // MARK: Delivering

  /// Downloads and installs what an owned item brings. Safe to call again: it only redoes what is missing.
  Future<void> deliver(LabShopItem item) async {
    if (working.contains(item.id) || !item.supported) return;
    working.add(item.id);
    failures.remove(item.id);
    notifyListeners();
    try {
      final file = item.file, listing = item.addon, home = item.home;
      if (file != null) {
        courses.addOfficial(await download(file), item.id);
      } else if (listing != null) {
        final booru = _booru;
        if (booru == null) throw const AddonMarketError.offline();
        final read = Addon.decode(await download(listing.file));
        if (read.addon.id != listing.id || read.addon.version != listing.version || read.addon.mode != listing.mode) {
          throw const AddonMarketError.damaged();
        }
        AddonStore(booru.database).install(read.addon, digest: read.digest, official: true);
        AddonRuntime.applyChanges(booru);
        readAddons();
      } else if (home != null) {
        final files = <String, List<int>>{};
        for (final (role, file) in home.files) {
          files[role] = await download(file);
        }
        HomeScenes.keep(item.id, home, files);
      }
    } on AddonMarketError catch (error) {
      // A file that is not the published one says so; anything else (offline, server) asks to try again.
      failures[item.id] = error == const AddonMarketError.damaged() ? error.errorDescription : L10n.text('lab.shop.downloadFailed');
    } on Object {
      failures[item.id] = L10n.text('lab.shop.downloadFailed');
    } finally {
      working.remove(item.id);
      notifyListeners();
    }
  }

  /// One file from TEGNAL's server, refused unless it is exactly the one the signed list names.
  Future<List<int>> download(LabShopFile file) async {
    if (!file.valid) throw const AddonMarketError.damaged();
    final data = await market.fetch(market.base.resolve(file.path), file.size);
    if (data.length != file.size || LabCourseFile.digest(data) != file.sha256) throw const AddonMarketError.damaged();
    return data;
  }
}

// MARK: - Home scenes

/// Home scenes bought in the shop, each kept in its own folder, and the one chosen to open the app with.
/// The home scene (`home_media.dart`) asks here for its films, still, music and colours, and falls back to the app's own.
abstract final class HomeScenes {
  static Directory? root;

  /// The chosen scene, or null for the app's own. The home scene listens to swap its loop.
  static final chosenScene = ValueNotifier<String?>(null);

  /// Finds the folder and the choice. Called before the home scene first draws.
  static Future<void> prepare() async {
    if (root != null) return;
    try {
      use(Directory('${(await getApplicationSupportDirectory()).path}/HomeScenes'));
    } on Object {
      // No scenes then: the app's own plays.
    }
  }

  /// Uses another folder, as in tests.
  static void use(Directory folder) {
    root = folder;
    String? chosen;
    try {
      final file = File('${folder.path}/chosen.txt');
      chosen = file.existsSync() ? file.readAsStringSync().trim() : null;
    } on Object {
      chosen = null;
    }
    chosenScene.value = chosen != null && chosen.isNotEmpty && _kept(chosen) != null ? chosen : null;
  }

  static Directory? _folder(String item) => root == null ? null : Directory('${root!.path}/$item');

  /// File name and SHA-256 by role (`intro`, `loop`, `still`, `theme`), and the palette.
  static ({Map<String, List<String>> files, Map<String, String>? palette})? _kept(String item) {
    final folder = _folder(item);
    if (folder == null) return null;
    try {
      final json = jsonDecode(File('${folder.path}/scene.json').readAsStringSync()) as Map;
      return (
        files: {for (final entry in (json['files'] as Map).entries) '${entry.key}': [for (final value in entry.value as List) '$value']},
        palette: (json['palette'] as Map?)?.map((key, value) => MapEntry('$key', '$value')),
      );
    } on Object {
      return null;
    }
  }

  /// True when a home scene's files are here, whatever their version.
  static bool kept(String item) => _kept(item) != null;

  /// True when exactly these files are here.
  static bool has(String item, LabShopHome home) {
    final kept = _kept(item);
    return kept != null && home.files.every((entry) => kept.files[entry.$1]?.last == entry.$2.sha256);
  }

  static void keep(String item, LabShopHome home, Map<String, List<int>> files) {
    final root = HomeScenes.root, folder = _folder(item);
    if (root == null || folder == null) throw const FileSystemException('No folder for home scenes');
    final staging = Directory('${root.path}/.$item-${DateTime.now().microsecondsSinceEpoch}')..createSync(recursive: true);
    final names = <String, List<String>>{};
    for (final (role, file) in home.files) {
      final data = files[role];
      if (data == null) continue;
      final dot = file.name.lastIndexOf('.');
      final name = '$role.${dot < 0 ? 'bin' : file.name.substring(dot + 1).toLowerCase()}';
      File('${staging.path}/$name').writeAsBytesSync(data, flush: true);
      names[role] = [name, file.sha256];
    }
    File('${staging.path}/scene.json').writeAsStringSync(jsonEncode({'files': names, 'palette': ?home.palette}));
    if (folder.existsSync()) folder.deleteSync(recursive: true);
    staging.renameSync(folder.path);
    // The scene in use was replaced: the home scene plays the new files.
    if (chosenScene.value == item) {
      chosenScene.value = null;
      chosenScene.value = item;
    }
  }

  static String? get chosen => chosenScene.value;

  static void choose(String? item) {
    if (item == chosenScene.value) return;
    final root = HomeScenes.root;
    if (root != null) {
      try {
        root.createSync(recursive: true);
        File('${root.path}/chosen.txt').writeAsStringSync(item ?? '');
      } on Object {
        // Chosen for this run only.
      }
    }
    chosenScene.value = item != null && kept(item) ? item : null;
  }

  /// A file of the chosen scene: `intro`, `loop`, `still` or `theme`.
  static File? file(String role) {
    final item = chosen, folder = item == null ? null : _folder(item);
    final name = item == null ? null : _kept(item)?.files[role]?.first;
    if (folder == null || name == null) return null;
    final file = File('${folder.path}/$name');
    return file.existsSync() ? file : null;
  }

  /// A colour of the chosen scene (`sky`, `ground`, `dusk`) as 0xRRGGBB.
  static int? color(String name) {
    final item = chosen;
    final value = item == null ? null : _kept(item)?.palette?[name];
    return value == null ? null : LabShopHome.hex(value);
  }
}
