import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:material_ui/material_ui.dart';

import '../core/app_controller.dart';
import '../core/challenges.dart';
import '../core/content.dart';
import '../data/backup_files.dart';
import '../ui/common.dart';
import '../ui/content_tile.dart';
import '../ui/l10n.dart';

class ChallengesScreen extends StatefulWidget {
  const ChallengesScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<ChallengesScreen> createState() => _ChallengesScreenState();
}

class _ChallengesScreenState extends State<ChallengesScreen> {
  late final _repository = ChallengeRepository(widget.controller.store);
  String? _error;
  bool _busy = false;
  @override
  Widget build(BuildContext context) {
    List<ChallengeDefinition> games = [];
    try {
      games = _repository.definitions();
    } catch (error) {
      _error = AppController.errorMessage(error);
    }
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: SafeArea(
        child: ListView(
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(20),
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        ListTile(
                          leading: Icon(
                            Icons.draw_outlined,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          title: Text(L10n.tr(context, 'Croquis Challenge')),
                          subtitle: Text(
                            L10n.tr(
                              context,
                              'Choose a reference and practice a quick sketch.',
                            ),
                            maxLines: 2,
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: _busy
                              ? null
                              : () => _run(
                                  () async => _play(_repository.example()),
                                ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Text(L10n.tr(context, 'My Challenges')),
                  ),
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (final game in games)
                          ListTile(
                            leading: Icon(
                              Icons.sports_esports_outlined,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            title: Text(game.title, maxLines: 2),
                            subtitle: game.detail.isEmpty
                                ? null
                                : Text(
                                    game.detail,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                            onTap: _busy ? null : () => _play(game),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  L10n.tr(
                                    context,
                                    _repository.hasSession(game.id)
                                        ? 'Continue'
                                        : 'Play',
                                  ),
                                ),
                                IconButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _actions(game),
                                  style: IconButton.styleFrom(
                                    padding: const EdgeInsets.all(8),
                                  ),
                                  icon: Icon(
                                    Icons.more_horiz,
                                    semanticLabel: L10n.tr(
                                      context,
                                      'Challenge Settings',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ListTile(
                          leading: const Icon(Icons.add),
                          title: Text(L10n.tr(context, 'New Challenge')),
                          onTap: _busy
                              ? null
                              : () => _edit(
                                  ChallengeDefinition.croquis(
                                    id: newChallengeId(),
                                  ).withChanges({'title': 'New Challenge'}),
                                ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Text(
                      L10n.tr(
                        context,
                        'Challenge definitions are included in backups. Progress and image sources stay on this device.',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.ios_share),
                          title: Text(
                            L10n.tr(context, 'Export Challenge Backup'),
                          ),
                          onTap: _busy
                              ? null
                              : () => _run(() async {
                                  await BackupFiles.export(
                                    _repository.exportJson(),
                                  );
                                }),
                        ),
                        ListTile(
                          leading: const Icon(Icons.download),
                          title: Text(
                            L10n.tr(context, 'Import Challenge Backup'),
                          ),
                          onTap: _busy
                              ? null
                              : () => _run(() async {
                                  final text = await BackupFiles.pick();
                                  if (text != null) {
                                    _repository.importJson(text);
                                    widget.controller.changed();
                                  }
                                }),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      appBar: AppBar(
        title: Text(L10n.tr(context, 'Challenge Roulette')),
        actions: [
          IconButton(
            onPressed: _busy
                ? null
                : () => _edit(
                    ChallengeDefinition.croquis(id: newChallengeId())
                        .withChanges({'title': 'New Challenge'}),
                  ),
            style: IconButton.styleFrom(padding: const EdgeInsets.all(8)),
            icon: Icon(
              Icons.add,
              semanticLabel: L10n.tr(context, 'New Challenge'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _play(ChallengeDefinition game) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ChallengePlay(
          controller: widget.controller,
          repository: _repository,
          definition: game,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _edit(ChallengeDefinition game) async {
    final value = await Navigator.of(context).push<ChallengeDefinition>(
      MaterialPageRoute(builder: (_) => _ChallengeEditor(definition: game)),
    );
    if (value != null && mounted) {
      await _run(() async {
        _repository.save(value);
        widget.controller.changed();
      });
    }
  }

  Future<void> _actions(ChallengeDefinition game) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: DefaultTextStyle(
                  style: Theme.of(context).textTheme.titleLarge!,
                  child: Text(game.title),
                ),
              ),
              ...[
                for (final entry in {
                  'edit': 'Edit',
                  'duplicate': 'Duplicate',
                  'export': 'Export Challenge Backup',
                  'delete': 'Delete',
                }.entries)
                  ListTile(
                    title: Text(L10n.tr(context, entry.value)),
                    onTap: () => Navigator.pop(context, entry.key),
                  ),
              ],
              const Divider(),
              ListTile(
                title: Text(L10n.tr(context, 'Cancel')),
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'edit') await _edit(game);
    if (action == 'duplicate') {
      await _edit(
        game.withChanges({
          'id': newChallengeId(),
          'title':
              '${game.title.substring(0, min(195, game.title.length))} Copy',
        }),
      );
    }
    if (action == 'export') {
      await _run(() async {
        await BackupFiles.export(_repository.exportJson(definition: game));
      });
    }
    if (action == 'delete' &&
        mounted &&
        await confirmAction(
          context,
          'Delete Challenge?',
          'This removes the definition and progress.',
        )) {
      await _run(() async {
        _repository.delete(game.id);
        widget.controller.changed();
      });
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = AppController.errorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _ChallengeEditor extends StatefulWidget {
  const _ChallengeEditor({required this.definition});
  final ChallengeDefinition definition;
  @override
  State<_ChallengeEditor> createState() => _ChallengeEditorState();
}

class _ChallengeEditorState extends State<_ChallengeEditor> {
  late ChallengeDefinition _definition = widget.definition;
  final _fields = <String, TextEditingController>{};
  late String _mode;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final json = _definition.toJson();
    final goal = _definition.goal;
    final values = <String, String>{
      'title': _definition.title,
      'detail': _definition.detail,
      'template': _definition.template,
      'target': '${_definition.target}',
      for (var index = 0; index < 2; index++)
        'reel$index': _optionsText(_definition.reels[index]),
      for (final kind in ['time', 'count'])
        for (final field in ['minimum', 'maximum', 'step'])
          '$kind.$field': '${(goal[kind] as Map)[field]}',
    };
    for (final entry in values.entries) {
      (_fields[entry.key] ??= TextEditingController()).text = entry.value;
    }
    _mode = (json['goal'] as Map)['mode'] as String;
  }

  String _optionsText(Map<String, dynamic> reel) => (reel['options'] as List)
      .cast<Map>()
      .map(
        (option) =>
            '${option['text']}${(option['tags'] as List).isEmpty ? '' : ' | ${(option['tags'] as List).join(' ')}'}',
      )
      .join('\n');
  ChallengeDefinition _draft() {
    final json = _definition.toJson();
    json['title'] = _fields['title']!.text.trim();
    json['detail'] = _fields['detail']!.text;
    json['template'] = _fields['template']!.text;
    final target = int.tryParse(_fields['target']!.text);
    if (target == null) throw const ContentException('Enter a target score.');
    json['target'] = target;
    final goal = Map<String, dynamic>.from(json['goal'] as Map)
      ..['mode'] = _mode;
    for (final kind in ['time', 'count']) {
      goal[kind] = {
        for (final field in ['minimum', 'maximum', 'step'])
          field: int.tryParse(_fields['$kind.$field']!.text),
      };
    }
    json['goal'] = goal;
    final bands = (json['bands'] as List).cast<Map>();
    if ((bands.last['through'] as int) < target) bands.last['through'] = target;
    final reels = (json['reels'] as List).cast<Map>();
    for (var index = 0; index < 2; index++) {
      if (_fields['reel$index']!.text ==
          _optionsText(_definition.reels[index])) {
        continue;
      }
      final old = (reels[index]['options'] as List).cast<Map>();
      final lines = _fields['reel$index']!.text
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .toList();
      reels[index]['options'] = [
        for (var line = 0; line < lines.length; line++)
          {
            if (line < old.length) ...Map<String, dynamic>.from(old[line]),
            'id': line < old.length ? old[line]['id'] : newChallengeId(),
            'text': lines[line].split('|').first.trim(),
            'tags': lines[line].contains('|')
                ? lines[line]
                      .substring(lines[line].indexOf('|') + 1)
                      .trim()
                      .split(RegExp(r'\s+'))
                      .where((tag) => tag.isNotEmpty)
                      .toList()
                : <String>[],
            'group': line < old.length ? old[line]['group'] : '',
            'enabled': line < old.length ? old[line]['enabled'] : true,
            'weight': line < old.length ? old[line]['weight'] : 1,
          },
      ];
    }
    return ChallengeDefinition.fromJson(json);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Theme.of(context).colorScheme.surface,
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          _field(context, 'Title', 'title'),
          _field(context, 'Game Instructions', 'detail', lines: 4),
          for (var index = 0; index < 2; index++)
            _field(
              context,
              _definition.reels[index]['title'] as String,
              'reel$index',
              lines: 6,
            ),
          Text(
            L10n.tr(
              context,
              'One option per line. Add reference tags after |, for example: Person | solo',
            ),
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 22),
          Text(
            L10n.tr(context, 'Goal Type'),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          SegmentedButton<String>(
            segments: [
              for (final kind in ChallengeGoalKind.values)
                ButtonSegment<String>(
                  value: kind.name,
                  label: Text(
                    L10n.tr(
                      context,
                      kind.name == 'time'
                          ? 'Time'
                          : kind.name == 'count'
                          ? 'Count'
                          : 'Mixed',
                    ),
                  ),
                ),
            ],
            selected: {_mode},
            onSelectionChanged: (values) {
              setState(() => _mode = values.first);
            },
          ),
          const SizedBox(height: 18),
          for (final kind in ['time', 'count'])
            if (_mode == kind || _mode == 'mixed') ...[
              Text(
                L10n.tr(
                  context,
                  kind == 'time' ? 'Time Range (Seconds)' : 'Count Range',
                ),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  for (final field in ['minimum', 'maximum', 'step'])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _field(
                          context,
                          field,
                          '$kind.$field',
                          numeric: true,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          _field(context, 'Target Score', 'target', numeric: true),
          _field(context, 'Mission Text', 'template', lines: 3),
          Text(
            '{reel1} · {reel2} · {goal}${_definition.groups.isEmpty ? '' : ' · {extra1}…'}',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 22),
          FilledButton(
            onPressed: () async {
              try {
                final value = await Navigator.of(context)
                    .push<ChallengeDefinition>(
                      MaterialPageRoute(
                        builder: (_) =>
                            _ChallengeJsonEditor(definition: _draft()),
                      ),
                    );
                if (value != null && mounted) {
                  setState(() {
                    _definition = value;
                    _load();
                    _error = null;
                  });
                }
              } catch (error) {
                if (mounted) {
                  setState(() => _error = AppController.errorMessage(error));
                }
              }
            },
            child: Text(L10n.tr(context, 'Advanced Rules (JSON)')),
          ),
          const SizedBox(height: 12),
          Text(
            L10n.tr(
              context,
              'Edit weights, filters, supporting groups, help tabs, scoring bands and endings in the native-compatible JSON editor.',
            ),
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
    appBar: AppBar(
      title: Text(L10n.tr(context, 'Edit Challenge')),
      actions: [
        TextButton(
          onPressed: () {
            try {
              Navigator.pop(context, _draft());
            } catch (error) {
              setState(() => _error = AppController.errorMessage(error));
            }
          },
          style: TextButton.styleFrom(padding: const EdgeInsets.all(8)),
          child: Text(L10n.tr(context, 'Save')),
        ),
      ],
    ),
  );
  Widget _field(
    BuildContext context,
    String label,
    String key, {
    int lines = 1,
    bool numeric = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          L10n.tr(context, label),
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 7),
        TextField(
          controller: _fields[key],
          minLines: 1,
          maxLines: lines,
          keyboardType: numeric
              ? TextInputType.number
              : lines > 1
              ? TextInputType.multiline
              : TextInputType.text,
          decoration: InputDecoration(contentPadding: const EdgeInsets.all(12)),
        ),
      ],
    ),
  );
  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }
}

class _ChallengeJsonEditor extends StatefulWidget {
  const _ChallengeJsonEditor({required this.definition});
  final ChallengeDefinition definition;
  @override
  State<_ChallengeJsonEditor> createState() => _ChallengeJsonEditorState();
}

class _ChallengeJsonEditorState extends State<_ChallengeJsonEditor> {
  late final _text = TextEditingController(
    text: const JsonEncoder.withIndent('  ')
        .convert(widget.definition.toJson()),
  );
  String? _error;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _text,
                expands: true,
                minLines: null,
                maxLines: null,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontSize: 13),
                keyboardType: TextInputType.multiline,
              ),
            ),
          ),
        ],
      ),
    ),
    appBar: AppBar(
      title: Text(L10n.tr(context, 'Advanced Rules')),
      actions: [
        TextButton(
          onPressed: () {
            try {
              if (utf8.encode(_text.text).length >
                  ChallengeRepository.maximumBytes) {
                throw const ContentException('This challenge is too large.');
              }
              final object = jsonDecode(_text.text);
              if (object is! Map<String, dynamic>) {
                throw const ContentException(
                  'Enter one challenge JSON object.',
                );
              }
              Navigator.pop(context, ChallengeDefinition.fromJson(object));
            } catch (error) {
              setState(
                () => _error = error is FormatException
                    ? 'Check the JSON syntax.'
                    : AppController.errorMessage(error),
              );
            }
          },
          style: TextButton.styleFrom(padding: const EdgeInsets.all(8)),
          child: Text(L10n.tr(context, 'Apply')),
        ),
      ],
    ),
  );
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }
}

class _ChallengePlay extends StatefulWidget {
  const _ChallengePlay({
    required this.controller,
    required this.repository,
    required this.definition,
  });
  final AppController controller;
  final ChallengeRepository repository;
  final ChallengeDefinition definition;
  @override
  State<_ChallengePlay> createState() => _ChallengePlayState();
}

class _ChallengePlayState extends State<_ChallengePlay>
    with WidgetsBindingObserver {
  final _engine = ChallengeEngine();
  late ChallengeSession _session;
  Timer? _timer;
  String? _error;
  bool _stale = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    try {
      _session = widget.repository.session(widget.definition);
      final next = ChallengeSession.fromJson(_session.toJson());
      _engine.reconcile(next, DateTime.now(), restore: true);
      if (jsonEncode(next.toJson()) != jsonEncode(_session.toJson())) {
        _session = widget.repository.commit(next, expected: _session.revision);
      }
      if (_session.serverIds.isEmpty) {
        final source = widget.controller.selectedSource(AppMode.booru);
        if (source != null) _session.serverIds = [source.id];
      }
    } catch (error) {
      _session = ChallengeSession(widget.definition);
      _error = AppController.errorMessage(error);
      _stale = true;
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    if (!mounted ||
        _stale ||
        _session.phase != ChallengePhase.active ||
        _session.deadline == null) {
      return;
    }
    if (_engine.seconds(_session, DateTime.now()) == 0) {
      _change((value) => _engine.reconcile(value, DateTime.now()));
    } else {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _tick();
  }

  void _change(void Function(ChallengeSession) mutation) {
    if (_stale) return;
    try {
      final next = ChallengeSession.fromJson(_session.toJson());
      mutation(next);
      if (jsonEncode(next.toJson()) == jsonEncode(_session.toJson())) return;
      final result = widget.repository.commit(
        next,
        expected: _session.revision,
      );
      setState(() {
        _session = result;
        _error = null;
      });
    } catch (error) {
      setState(() {
        _error = AppController.errorMessage(error);
        if (_error!.contains('Reopen')) _stale = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mission = _session.mission;
    final selected = _session.selectedItem;
    final reference = selected?.mediaUrl ?? selected?.thumbnailUrl;
    final definition = _session.definition;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Row(
              children: [
                Text(
                  L10n.tr(context, 'Score'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '${_session.score} / ${definition.target}',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) => Container(
                height: 7,
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary
                      .withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Container(
                  width:
                      constraints.maxWidth *
                      (_session.score / definition.target).clamp(0, 1),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),
            if (_session.phase == ChallengePhase.ended) ...[
              Text(
                _session.ending?['badge'] as String? ?? '★',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 72),
              ),
              Text(
                _session.ending?['title'] as String? ??
                    L10n.tr(context, 'Complete'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _session.ending?['detail'] as String? ?? '',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _stale ? null : _restart,
                child: Text(L10n.tr(context, 'Play Again')),
              ),
            ] else if (mission == null) ...[
              Icon(
                Icons.sports_esports_outlined,
                size: 64,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 22),
              Text(
                L10n.tr(context, 'Ready for your next mission?'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                definition.detail,
                style: TextStyle(
                  height: 1.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _stale ? null : () => _change(_engine.draw),
                child: Text(L10n.tr(context, 'Draw a Mission')),
              ),
            ] else if (_session.phase == ChallengePhase.spinning) ...[
              const SizedBox(
                width: 20 * 2,
                height: 20 * 2,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(height: 24),
              Text(
                L10n.tr(context, 'Your choices are ready.'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _stale ? null : () => _change(_engine.reveal),
                child: Text(L10n.tr(context, 'Reveal Mission')),
              ),
            ] else ...[
              Text(
                mission.text,
                style: const TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final choice in mission.selections)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary
                            .withValues(alpha: .1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: Text(
                          choice['text'] as String,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 26),
              if (reference != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: SizedBox(
                    height: 300,
                    child: InteractiveViewer(
                      maxScale: 5,
                      child: Image.network(
                        reference.toString(),
                        fit: BoxFit.contain,
                        headers: selected?.pageUrl == null
                            ? null
                            : {'Referer': selected!.pageUrl.toString()},
                        errorBuilder: (_, _, _) => Center(
                          child: Text(
                            L10n.tr(
                              context,
                              'Unable to load reference. Choose another image.',
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: _stale ? null : _references,
                      child: Text(L10n.tr(context, 'Reference Images')),
                    ),
                  ),
                  IconButton(
                    onPressed: _stale ? null : _chooseSource,
                    icon: Icon(
                      Icons.tune,
                      semanticLabel: L10n.tr(context, 'Image Source'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (mission.kind == ChallengeGoalKind.time) ...[
                Text(
                  _clock(_engine.seconds(_session, DateTime.now())),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 60,
                    fontWeight: FontWeight.w300,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton(
                      onPressed:
                          _stale || _session.phase == ChallengePhase.ready
                          ? null
                          : () => _change(
                              (value) =>
                                  _engine.toggleTimer(value, DateTime.now()),
                            ),
                      child: Text(
                        L10n.tr(
                          context,
                          _session.deadline == null ? 'Start Timer' : 'Pause',
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _stale
                          ? null
                          : () => _change(_engine.resetTimer),
                      child: Text(L10n.tr(context, 'Reset')),
                    ),
                  ],
                ),
              ] else
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      onPressed: _stale
                          ? null
                          : () => _change((value) => _engine.adjust(value, -1)),
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                    Text(
                      '${_session.count} / ${mission.goal}',
                      style: const TextStyle(
                        fontSize: 42,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                    IconButton(
                      onPressed: _stale
                          ? null
                          : () => _change((value) => _engine.adjust(value, 1)),
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: _stale || _session.phase != ChallengePhase.ready
                    ? null
                    : () => _change(
                        (value) => _engine.complete(value, DateTime.now()),
                      ),
                child: Text(L10n.tr(context, 'Complete Mission')),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _stale ? null : () => _change(_engine.skip),
                child: Text(L10n.tr(context, 'Skip Mission')),
              ),
            ],
            const SizedBox(height: 24),
            Text(
              L10n.tr(
                context,
                'Progress is saved on this device. Running timers continue while you leave this screen.',
              ),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      appBar: AppBar(
        title: Text(definition.title),
        actions: [
          IconButton(
            onPressed: () => _instructions(context),
            style: IconButton.styleFrom(padding: const EdgeInsets.all(8)),
            icon: Icon(
              Icons.info_outline,
              semanticLabel: L10n.tr(context, 'How to Play'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _instructions(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(L10n.tr(context, 'How to Play')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_session.definition.detail),
          for (final page in _session.definition.helpPages) ...[
            const SizedBox(height: 16),
            Text(
              page['title'] as String,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(page['body'] as String),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(L10n.tr(context, 'Done')),
        ),
      ],
      scrollable: true,
    ),
  );
  void _restart() => _change((value) {
    final latest =
        widget.repository
            .definitions()
            .where((game) => game.id == widget.definition.id)
            .firstOrNull ??
        widget.definition;
    value
      ..definition = latest
      ..phase = ChallengePhase.idle
      ..score = 0
      ..mission = null
      ..deadline = null
      ..remaining = 0
      ..count = 0
      ..ending = null
      ..selectedItem = null;
  });
  Future<void> _chooseSource() async {
    final sources = widget.controller.sources(AppMode.booru);
    final folders = widget.controller.folders(AppMode.booru);
    final choice = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: DefaultTextStyle(
                  style: Theme.of(context).textTheme.titleLarge!,
                  child: Text(L10n.tr(context, 'Image Source')),
                ),
              ),
              ...[
                for (final source in sources)
                  ListTile(
                    title: Text(source.name),
                    onTap: () => Navigator.pop(context, 'server:${source.id}'),
                  ),
                ListTile(
                  title: Text(L10n.tr(context, 'All Saved Images')),
                  onTap: () => Navigator.pop(context, 'folder:'),
                ),
                for (final folder in folders)
                  ListTile(
                    title: Text(folder.name),
                    onTap: () => Navigator.pop(context, 'folder:${folder.id}'),
                  ),
              ],
              const Divider(),
              ListTile(
                title: Text(L10n.tr(context, 'Cancel')),
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final colon = choice.indexOf(':');
    _change((value) {
      value
        ..sourceKind = choice.startsWith('server:') ? 'servers' : 'folder'
        ..selectedItem = null;
      if (value.sourceKind == 'servers') {
        value
          ..serverIds = [choice.substring(colon + 1)]
          ..folderId = null;
      } else {
        value.folderId = choice.substring(colon + 1).isEmpty
            ? null
            : choice.substring(colon + 1);
      }
    });
  }

  Future<void> _references() async {
    final item = await Navigator.of(context).push<ContentItem>(
      MaterialPageRoute(
        builder: (_) => _ChallengeReferences(
          controller: widget.controller,
          session: _session,
        ),
      ),
    );
    if (item != null && mounted) _change((value) => value.selectedItem = item);
  }

  String _clock(int seconds) =>
      '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class _ChallengeReferences extends StatefulWidget {
  const _ChallengeReferences({required this.controller, required this.session});
  final AppController controller;
  final ChallengeSession session;
  @override
  State<_ChallengeReferences> createState() => _ChallengeReferencesState();
}

class _ChallengeReferencesState extends State<_ChallengeReferences> {
  List<ContentItem> _items = [];
  String? _error;
  bool _loading = true;
  bool _more = false;
  int _page = 0;
  final _finished = <String>{};
  @override
  void initState() {
    super.initState();
    _load();
  }

  bool _matches(ContentItem item) {
    if (item.mediaType == 'video') return false;
    final tags = item.tags.map((tag) => tag.toLowerCase()).toSet();
    final blacklist = (widget.controller.store.setting(
      'blacklist.${item.sourceId}',
      '',
    ) as String).split(RegExp(r'[\s,]+')).where((tag) => tag.isNotEmpty);
    return !blacklist.any(tags.contains) &&
        widget.session.mission!.tags.every(
          (tag) => tags.contains(tag.toLowerCase()),
        );
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final List<ContentItem> items;
      final finished = <String>{};
      var more = false;
      if (widget.session.sourceKind == 'folder') {
        items = widget.controller
            .savedItems(mode: AppMode.booru, folderId: widget.session.folderId)
            .map((entry) => entry.item)
            .where(_matches)
            .toList();
      } else {
        final sources = widget.controller
            .sources(AppMode.booru)
            .where(
              (source) =>
                  widget.session.serverIds.contains(source.id) &&
                  !_finished.contains(source.id),
            )
            .toList();
        if (sources.isEmpty && _items.isEmpty) {
          throw const ContentException(
            'Choose a registered image server or a saved folder.',
          );
        }
        items = [];
        for (final source in sources) {
          final page = await widget.controller
              .client(source)
              .search(widget.session.mission!.tags.join(' '), page: _page + 1);
          items.addAll(page.items.where(_matches));
          if (!page.hasMore) finished.add(source.id);
          more = more || page.hasMore;
        }
      }
      if (!mounted) return;
      _finished.addAll(finished);
      final seen = _items.map((item) => item.key).toSet();
      setState(() {
        _items = [..._items, ...items.where((item) => seen.add(item.key))];
        _page++;
        _more = more;
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = AppController.errorMessage(error);
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(widget.session.mission!.tags.join(' · ')),
            ),
          ),
          if (_error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Text(_error!),
                    TextButton(
                      onPressed: _load,
                      child: Text(L10n.tr(context, 'Try Again')),
                    ),
                  ],
                ),
              ),
            ),
          if (!_loading && _error == null && _items.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.image_outlined,
                title: 'No Results',
                message: 'No matching reference images. Choose another source or skip this mission.',
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.all(20),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) => SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: (constraints.crossAxisExtent / 175)
                      .floor()
                      .clamp(2, 6),
                  crossAxisSpacing: 14,
                  mainAxisSpacing: 20,
                  childAspectRatio: .65,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => ContentTile(
                    item: _items[index],
                    onTap: () => Navigator.pop(context, _items[index]),
                  ),
                  childCount: _items.length,
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: _loading
                    ? const CircularProgressIndicator(strokeWidth: 3)
                    : _more
                    ? TextButton(
                        onPressed: _load,
                        child: Text(L10n.tr(context, 'Load More')),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        ],
      ),
    ),
    appBar: AppBar(title: Text(L10n.tr(context, 'Reference Images'))),
  );
}
