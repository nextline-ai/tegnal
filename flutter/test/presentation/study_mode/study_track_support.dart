import 'dart:convert';
import 'dart:io';

import 'package:tegnal/core/addons/addon_models.dart';
import 'package:tegnal/core/addons/addon_store.dart';

/// An add-on file with a learning track of [lessons] concept lessons (one card each) and, with [tags], a tags lesson
/// teaching a tag of its own (`lighthouse`).
List<int> trackAddonFile({String id = 'maker.track', int lessons = 2, bool tags = true, String color = '2F9E6E', String? symbol = 'tree'}) => utf8.encode(
  jsonEncode({
    'format': 'tegnal-addon',
    'schemaVersion': 1,
    'id': id,
    'version': '1.0.0',
    'name': {'en': 'Track Pack'},
    'author': 'Maker',
    'contents': {
      'learningTrack': {
        'title': {'en': 'Lighthouse Track', 'ko': '등대 트랙'},
        'summary': {'en': 'Places by the sea'},
        'color': color,
        'symbol': ?symbol,
        if (tags)
          'groups': [
            {
              'id': 'sea',
              'title': {'en': 'Sea'},
              'tags': [
                {
                  'name': 'lighthouse',
                  'note': {'en': 'A tower with a light by the sea'},
                },
              ],
            },
          ],
        'sections': [
          {
            'id': 'coast',
            'title': {'en': 'The Coast'},
            'summary': {'en': 'Where land meets sea'},
            'color': color,
            'lessons': [
              for (var index = 0; index < lessons; index++)
                {
                  'id': 'idea-$index',
                  'kind': 'concept',
                  'symbol': 'book',
                  'title': {'en': 'Idea $index'},
                  'steps': [
                    {
                      'card': {
                        'title': {'en': 'Card $index'},
                        'body': {'en': 'Something to read'},
                      },
                    },
                  ],
                },
              if (tags)
                {
                  'id': 'sea-tags',
                  'kind': 'tags',
                  'symbol': 'tag',
                  'title': {'en': 'Sea Tags'},
                  'tags': ['lighthouse'],
                },
            ],
          },
        ],
      },
    },
  }),
);

Addon trackAddon({String id = 'maker.track', int lessons = 2, bool tags = true, String color = '2F9E6E', String? symbol = 'tree'}) =>
    Addon.decode(trackAddonFile(id: id, lessons: lessons, tags: tags, color: color, symbol: symbol)).addon;

InstalledAddon installedAddon(Addon addon, {bool enabled = true, int at = 0}) =>
    InstalledAddon(addon: addon, enabled: enabled, installed: DateTime.fromMillisecondsSinceEpoch(at * 1000), digest: '');

/// Turns these add-ons on everywhere, as the app does after one is added. Undo with `AddonRuntime.shared.apply(AddonEffects())`.
void turnOn(List<Addon> addons) => AddonRuntime.shared.apply(AddonEffects([for (final (index, addon) in addons.indexed) installedAddon(addon, at: index)]));

/// The sample add-on files in the local, git-ignored `docs/addons` folder; empty where they are not present.
List<File> sampleAddonFiles() {
  final folder = Directory('../docs/addons');
  if (!folder.existsSync()) return const [];
  return folder.listSync().whereType<File>().where((file) => file.path.endsWith('.${Addon.fileExtension}')).toList();
}
