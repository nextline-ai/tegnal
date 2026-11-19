import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../../core/generation/generation_air.dart' show GenerationKind;
import '../../core/generation/generation_client.dart';
import '../../core/generation/generation_store.dart';
import '../../core/study/study_awards.dart';
import '../../core/study/study_store.dart';
import '../../core/support/l10n.dart';
import '../booru/booru_common.dart';
import '../design/grouped_form.dart';
import '../design/ios_controls.dart';
import '../design/pull_down_menu.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import '../navigation/app_header.dart';
import '../settings/settings_page.dart';
import '../settings/settings_rows.dart';
import '../study/study_widgets.dart' show StudyActionRow, StudyStyle, StudyDigits;
import 'generator_account_view.dart';
import 'generator_gallery.dart';
import 'generator_model_picker.dart';
import 'generator_sheet.dart';

/// Writes a prompt and has Civitai draw it, with the user's own API key and models named by AIR (`GeneratorView`).
class GeneratorView extends StatefulWidget {
  const GeneratorView({super.key, required this.store, required this.safeMode, this.prompt = '', this.study});

  /// The generator over the app's own store, as the study screens open it.
  factory GeneratorView.forBooru(BooruContext booru, {Key? key, String prompt = ''}) => GeneratorView(
    key: key,
    store: GenerationStore.shared(booru.booruDefaults),
    safeMode: () => booru.safeMode,
    prompt: prompt,
    study: booru.store.studyStore,
  );

  final GenerationStore store;
  final bool Function() safeMode;
  final String prompt;

  /// The study store that counts every picture ever made; without one the count is the gallery's size.
  final StudyStore? study;

  /// `GeneratorView.advancedKey`.
  static const advancedKey = 'generation.showsAdvanced';

  @override
  State<GeneratorView> createState() => _GeneratorViewState();
}

class _GeneratorViewState extends State<GeneratorView> {
  final _run = GenerationRun();
  late final TextEditingController _prompt = TextEditingController(text: widget.prompt);
  late final TextEditingController _negative = TextEditingController(text: _store.settings.negative);
  final _seed = TextEditingController();
  final _scroll = ScrollController();
  final _resultsKey = GlobalKey();
  final _errorKey = GlobalKey();
  Timer? _scrollTimer;
  int _madeCount = 0;

  /// Pictures generated so far, ever: the advanced settings open after the first few.
  int _made = 0;
  late bool _showsAdvanced = _store.defaults.boolean(GeneratorView.advancedKey) ?? true;
  GenerationError? _shownError;
  Timer? _estimateTimer;
  int _estimateToken = 0;
  double? _estimate;
  String? _priced;

  GenerationStore get _store => widget.store;
  GenerationSettings get _settings => _store.settings;
  GeneratorEnvironment get _environment => GeneratorEnvironment(store: _store, safeMode: widget.safeMode);

  /// A beginner sees a prompt, a model and a button. Size, steps, LoRAs and the rest open once a few pictures are made.
  bool get _unlocked => _made >= StudyAward.advancedPictures;
  bool get _advanced => _unlocked && _showsAdvanced;
  String get _trimmed => _prompt.text.trim();

  /// Safe Mode never asks for mature results, whatever the switch says.
  GenerationSettings get _sent => widget.safeMode() ? _settings.copyWith(mature: false) : _settings;

  String get _cost => L10n.text('About %@ Buzz', ['${(_estimate ?? _settings.roughCost.toDouble()).ceil()}']);

  @override
  void initState() {
    super.initState();
    _store.addListener(_changed);
    _run.addListener(_changed);
    _prompt.addListener(_changed);
    _seed.text = _settings.seed?.toString() ?? '';
    _store.load();
    _count();
    _changed();
  }

  @override
  void dispose() {
    _estimateTimer?.cancel();
    _scrollTimer?.cancel();
    _scroll.dispose();
    _store.removeListener(_changed);
    _run.removeListener(_changed);
    _prompt.dispose();
    _negative.dispose();
    _seed.dispose();
    _run.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (_negative.text != _settings.negative) _negative.text = _settings.negative;
    if (_settings.seed case final seed? when int.tryParse(_seed.text) != seed) _seed.text = '$seed';
    _refreshEstimate();
    if (_run.made.length > _madeCount) {
      _count();
      _scrollTo(_resultsKey);
    }
    if (_run.error != null && _run.error != _shownError) _scrollTo(_errorKey);
    _madeCount = _run.made.length;
    _shownError = _run.error;
    setState(() {});
  }

  /// Reads how many pictures have ever been generated. Deleting pictures later does not lock the settings again.
  void _count() {
    final study = widget.study;
    var made = _store.pictures.length;
    if (study != null) {
      try {
        study.raise(StudyCounter.pictures, _store.pictures.length);
        made = study.stats()[StudyCounter.pictures] ?? made;
      } on Object {
        // The count stays what the gallery shows.
      }
    }
    _made = made;
  }

  /// Brings a part of the list into view a moment after it appears, with its bottom edge at the bottom of the screen.
  void _scrollTo(GlobalKey target) {
    _scrollTimer?.cancel();
    _scrollTimer = Timer(const Duration(milliseconds: 150), () async {
      if (!mounted) return;
      // A list builds only what is near the screen; go to the end first when the target is not built yet.
      if (target.currentContext == null && _scroll.hasClients) {
        await _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        await WidgetsBinding.instance.endOfFrame;
      }
      final context = target.currentContext;
      if (!mounted || context == null || !context.mounted) return;
      await Scrollable.ensureVisible(context, alignment: 1, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }

  /// What a cost estimate depends on, so that typing a prompt does not ask for a new one.
  void _refreshEstimate() {
    final settings = _settings;
    final signature = [
      settings.model?.air ?? '',
      '${settings.width}x${settings.height}',
      '${settings.steps}',
      '${settings.quantity}',
      '${_sent.mature}',
      '${_store.hasKey}',
      '${_trimmed.isEmpty}',
      ...settings.loras.map((lora) => lora.model.air),
    ].join('|');
    if (signature == _priced) return;
    _priced = signature;
    _estimate = null;
    _estimateTimer?.cancel();
    if (!_store.hasKey || settings.model == null || _trimmed.isEmpty) return;
    final token = ++_estimateToken;
    _estimateTimer = Timer(const Duration(milliseconds: 900), () async {
      double? value;
      try {
        value = await _store.client().estimate(prompt: _trimmed, settings: _sent);
      } on Object {
        value = null;
      }
      if (mounted && token == _estimateToken) setState(() => _estimate = value);
    });
  }

  void _set(GenerationSettings settings) => _store.settings = settings;

  Future<void> _openAccount() async {
    await showGeneratorSheet(context, (context) => GeneratorAccountView(store: _store));
    if (mounted) setState(() {});
  }

  Future<void> _openPicture(GeneratedPicture picture) async {
    await showGeneratorSheet(context, (context) => GeneratedPictureView(environment: _environment, picture: picture, removed: () => _run.forget(picture)));
    if (mounted) setState(() {});
  }

  void _generate() {
    if (!_store.hasKey) {
      _openAccount();
      return;
    }
    _run.start(prompt: _trimmed, settings: _sent, store: _store);
  }

  Future<void> _applyPreset(GenerationPreset preset) async {
    _prompt.text = preset.applied(_prompt.text);
    _negative.text = preset.negative;
    _set(_settings.copyWith(negative: preset.negative, steps: preset.steps, guidance: preset.guidance));
  }

  String get _status => switch (_run.phase) {
    GenerationPhase.queued => L10n.text('Waiting in Line…'),
    GenerationPhase.drawing => L10n.text('Drawing…'),
    GenerationPhase.saving => L10n.text('Saving…'),
    _ => L10n.text('Sending…'),
  };

  static String samplerName(String value) =>
      const {'euler_a': 'Euler a', 'euler': 'Euler', 'dpm++2m': 'DPM++ 2M', 'dpm++2s_a': 'DPM++ 2S a', 'lcm': 'LCM'}[value] ?? value;

  static String scheduleName(String value) => switch (value) {
    'simple' => 'Simple',
    'discrete' => 'Discrete',
    'karras' => 'Karras',
    _ => 'SGM Uniform',
  };

  @override
  Widget build(BuildContext context) {
    final rowColor = FormColors.listRow.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final settings = _settings;
    return SettingsPage(
      controller: _scroll,
      title: L10n.text('Generate a Picture'),
      trailing: ToolbarGroup(
        children: [
          ToolbarIconButton(
            key: const Key('generator.account'),
            label: L10n.text('Civitai API Key'),
            icon: _store.hasKey ? CupertinoIcons.lock_fill : CupertinoIcons.lock,
            onPressed: _openAccount,
          ),
        ],
      ),
      children: [
        const SizedBox(height: 25),
        if (!_store.hasKey) ...[
          FormSection(
            rowColor: rowColor,
            footer: Text(L10n.text("Pictures are drawn by Civitai on your own account and paid for with your Buzz. The key stays in this device's keychain.")),
            children: [
              StudyActionRow(key: const Key('generator.addKey'), title: L10n.text('Add Your Civitai API Key'), icon: CupertinoIcons.lock, onTap: _openAccount),
            ],
          ),
          settingsSectionGap,
        ],
        FormSection(
          prominentHeader: true,
          rowColor: rowColor,
          header: Text(L10n.text('Prompt')),
          footer: _advanced
              ? Text(L10n.text('Round brackets are read as emphasis, as in (rain:1.3). Brackets that belong to a tag are written \\( and \\).'))
              : null,
          children: [
            FormRow(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: _field(key: const Key('generator.prompt'), controller: _prompt, minLines: 5),
              ),
            ),
            Builder(
              builder: (menuContext) => StudyActionRow(
                key: const Key('generator.preset'),
                title: L10n.text("Apply a Model's Recommended Tags"),
                icon: CupertinoIcons.sparkles,
                onTap: () async {
                  final preset = await showPullDownMenu<GenerationPreset>(
                    menuContext,
                    anchor: anchorRectOf(menuContext),
                    items: [for (final preset in GenerationPreset.all) PullDownMenuItem(value: preset, title: preset.name)],
                  );
                  if (preset != null) _applyPreset(preset);
                },
              ),
            ),
          ],
        ),
        if (_advanced) ...[
          settingsSectionGap,
          FormSection(
            prominentHeader: true,
            rowColor: rowColor,
            header: Text(L10n.text('Things to Avoid')),
            children: [
              FormRow(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: _field(
                    key: const Key('generator.negative'),
                    controller: _negative,
                    minLines: 3,
                    onChanged: (value) => _set(_settings.copyWith(negative: value)),
                  ),
                ),
              ),
            ],
          ),
        ],
        settingsSectionGap,
        FormSection(
          prominentHeader: true,
          rowColor: rowColor,
          header: Text(L10n.text('Model')),
          children: [
            FormRow(
              key: const Key('generator.model'),
              onTap: () => pushGenerator<void>(
                context,
                (context) => GeneratorModelPicker(environment: _environment, kind: GenerationKind.checkpoint, choose: (model) => _set(_settings.use(model))),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            settings.model?.name ?? L10n.text('Choose a Model'),
                            style: TegnalType.style(
                              17,
                              weight: FontWeight.w500,
                              color: settings.model == null ? StudyStyle.accent(context) : TegnalColors.label.resolveFrom(context),
                            ),
                          ),
                          if (settings.model case final model?) ...[
                            const SizedBox(height: 3),
                            Text(
                              [?model.base, model.air].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TegnalType.style(12, color: secondary),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Icon(CupertinoIcons.chevron_right, size: 15, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
                  ],
                ),
              ),
            ),
            if (_advanced) ...[
              for (final (index, lora) in settings.loras.indexed) _loraRow(context, index, lora),
              SettingsLinkRow(
                color: StudyStyle.accent(context),
                key: const Key('generator.addLora'),
                title: L10n.text('Add a LoRA'),
                icon: CupertinoIcons.plus,
                onTap: () => pushGenerator<void>(
                  context,
                  (context) => GeneratorModelPicker(
                    environment: _environment,
                    kind: GenerationKind.lora,
                    choose: (model) {
                      if (!_settings.loras.any((lora) => lora.model.air == model.air)) {
                        _set(
                          _settings.copyWith(
                            loras: [
                              ..._settings.loras,
                              GenerationLora(model: model),
                            ],
                          ),
                        );
                      }
                    },
                  ),
                ),
              ),
            ],
          ],
        ),
        settingsSectionGap,
        if (_advanced) ...[..._options(context, rowColor), settingsSectionGap],
        if (_unlocked)
          FormSection(
            rowColor: rowColor,
            children: [
              SettingsToggleRow(
                tint: StudyStyle.accent(context),
                key: const Key('generator.advancedToggle'),
                title: L10n.text('Show Advanced Settings'),
                value: _showsAdvanced,
                onChanged: (shown) {
                  setState(() => _showsAdvanced = shown);
                  _store.defaults.set(GeneratorView.advancedKey, shown);
                },
              ),
            ],
          )
        else
          FormSection(
            key: const Key('generator.advancedLocked'),
            rowColor: rowColor,
            children: [FormRow(child: _lockedCard(context))],
          ),
        settingsSectionGap,
        FormSection(
          rowColor: rowColor,
          footer: _run.lastCost != null && !_run.isRunning ? Text(L10n.text('The last request cost %@ Buzz.', ['${_run.lastCost!.ceil()}'])) : null,
          children: [
            FormRow(
              child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: _generateButton(context)),
            ),
            if (_run.isRunning)
              FormRow(
                key: const Key('generator.cancel'),
                onTap: () => _run.cancel(_store),
                child: Center(
                  child: Text(L10n.text('Cancel'), style: TegnalType.style(17, color: CupertinoColors.systemRed.resolveFrom(context))),
                ),
              ),
            if (_run.error case final error?)
              FormRow(
                key: _errorKey,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(CupertinoIcons.exclamationmark_triangle, size: 15, color: SystemColors.red.resolveFrom(context)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          error.message,
                          key: const Key('generator.error'),
                          style: TegnalType.style(13, color: SystemColors.red.resolveFrom(context)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        if (_run.made.isNotEmpty) ...[
          settingsSectionGap,
          FormSection(
            prominentHeader: true,
            rowColor: rowColor,
            header: Text(L10n.text('Results')),
            children: [
              FormRow(
                key: _resultsKey,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: GeneratedGrid(pictures: _run.made, store: _store, open: _openPicture),
                ),
              ),
            ],
          ),
        ],
        if (_store.pictures.isNotEmpty) ...[
          settingsSectionGap,
          FormSection(
            rowColor: rowColor,
            children: [
              SettingsLinkRow(
                color: StudyStyle.accent(context),
                key: const Key('generator.gallery'),
                title: L10n.text('Generated Pictures'),
                icon: CupertinoIcons.photo_on_rectangle,
                value: '${_store.pictures.length}',
                onTap: () => pushGenerator<void>(context, (context) => GeneratedGalleryView(environment: _environment)).then((_) {
                  if (mounted) setState(() {});
                }),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _lockedCard(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final goal = StudyAward.advancedPictures;
    final shown = _made < goal ? _made : goal;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(CupertinoIcons.lock_fill, size: 15, color: TegnalColors.label.resolveFrom(context)),
              const SizedBox(width: 6),
              Text(
                L10n.text('Advanced Settings'),
                style: TegnalType.style(15, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            L10n.text('Size, steps, LoRAs and things to avoid open once you have generated %@ pictures. Until then the recommended settings are used.', [
              '$goal',
            ]),
            style: TegnalType.style(13, color: secondary),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              height: 4,
              child: Stack(
                children: [
                  ColoredBox(color: TegnalColors.tertiaryLabel.resolveFrom(context), child: const SizedBox.expand()),
                  FractionallySizedBox(
                    widthFactor: shown / goal,
                    child: ColoredBox(color: StudyStyle.accent(context), child: const SizedBox.expand()),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$shown / $goal',
            style: TegnalType.style(12, weight: FontWeight.w600, color: secondary).digits,
          ),
        ],
      ),
    );
  }

  Widget _field({required Key key, required TextEditingController controller, required int minLines, ValueChanged<String>? onChanged}) =>
      CupertinoTextField.borderless(
        key: key,
        controller: controller,
        padding: EdgeInsets.zero,
        minLines: minLines,
        maxLines: null,
        keyboardType: TextInputType.multiline,
        textCapitalization: TextCapitalization.none,
        autocorrect: false,
        enableSuggestions: false,
        style: generatorMonospace(context),
        onChanged: onChanged,
      );

  Widget _loraRow(BuildContext context, int index, GenerationLora lora) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return FormRow(
      key: ValueKey('generator.lora.${lora.model.id}'),
      child: Dismissible(
        key: ValueKey('generator.loraDismiss.${lora.model.id}'),
        direction: DismissDirection.endToStart,
        onDismissed: (_) => _set(_settings.copyWith(loras: [..._settings.loras]..removeWhere((item) => item.model.id == lora.model.id))),
        background: Container(
          color: CupertinoColors.systemRed.resolveFrom(context),
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 16),
          child: const Icon(CupertinoIcons.trash, color: Color(0xFFFFFFFF)),
        ),
        child: ColoredBox(
          color: FormColors.listRow.resolveFrom(context),
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        lora.model.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TegnalType.style(15, color: TegnalColors.label.resolveFrom(context)),
                      ),
                    ),
                    Text(lora.strength.toStringAsFixed(2), style: TegnalType.style(15, color: secondary).digits),
                  ],
                ),
                GeneratorSlider(
                  key: ValueKey('generator.loraStrength.${lora.model.id}'),
                  label: lora.model.name,
                  value: lora.strength,
                  min: 0,
                  max: 1.5,
                  step: 0.05,
                  digits: 2,
                  onChanged: (next) => _set(
                    _settings.copyWith(loras: [for (final item in _settings.loras) item.model.id == lora.model.id ? item.copyWith(strength: next) : item]),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _options(BuildContext context, Color rowColor) {
    final settings = _settings;
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    Widget valueRow(String title, String value, {Widget? trailing, Widget? below}) => FormRow(
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title, style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context))),
              ),
              Text(value, style: TegnalType.style(17, color: secondary).digits),
              if (trailing != null) ...[const SizedBox(width: 12), trailing],
            ],
          ),
          ?below,
        ],
      ),
    );
    final (minSteps, maxSteps) = GenerationSettings.stepRange;
    final (minPictures, maxPictures) = GenerationSettings.quantityRange;
    return [
      FormSection(
        prominentHeader: true,
        rowColor: rowColor,
        header: Text(L10n.text('Settings')),
        children: [
          SettingsPickerRow<String>(
            color: StudyStyle.accent(context),
            key: const Key('generator.size'),
            title: L10n.text('Size'),
            options: [for (final (width, height) in GenerationSettings.sizes) ('${width}x$height', '$width × $height')],
            selected: '${settings.width}x${settings.height}',
            onSelected: (value) {
              final size = GenerationSettings.sizes.where((item) => '${item.$1}x${item.$2}' == value).firstOrNull;
              if (size != null) _set(_settings.copyWith(width: size.$1, height: size.$2));
            },
          ),
          valueRow(
            L10n.text('Steps'),
            '${settings.steps}',
            trailing: GeneratorStepper(
              key: const Key('generator.steps'),
              label: L10n.text('Steps'),
              value: settings.steps,
              decrement: settings.steps > minSteps ? () => _set(_settings.copyWith(steps: settings.steps - 1)) : null,
              increment: settings.steps < maxSteps ? () => _set(_settings.copyWith(steps: settings.steps + 1)) : null,
            ),
          ),
          valueRow(
            L10n.text('Guidance (CFG)'),
            settings.guidance.toStringAsFixed(1),
            below: GeneratorSlider(
              key: const Key('generator.guidance'),
              label: L10n.text('Guidance (CFG)'),
              value: settings.guidance,
              min: 1,
              max: 12,
              step: 0.5,
              digits: 1,
              onChanged: (value) => _set(_settings.copyWith(guidance: value)),
            ),
          ),
          SettingsPickerRow<String>(
            color: StudyStyle.accent(context),
            key: const Key('generator.sampler'),
            title: L10n.text('Sampler'),
            options: [for (final name in GenerationSettings.samplers) (name, samplerName(name))],
            selected: settings.sampler,
            onSelected: (value) => _set(_settings.copyWith(sampler: value)),
          ),
          SettingsPickerRow<String>(
            color: StudyStyle.accent(context),
            key: const Key('generator.schedule'),
            title: L10n.text('Schedule'),
            options: [for (final name in GenerationSettings.schedules) (name, scheduleName(name))],
            selected: settings.schedule,
            onSelected: (value) => _set(_settings.copyWith(schedule: value)),
          ),
          valueRow(
            L10n.text('Pictures'),
            '${settings.quantity}',
            trailing: GeneratorStepper(
              key: const Key('generator.quantity'),
              label: L10n.text('Pictures'),
              value: settings.quantity,
              decrement: settings.quantity > minPictures ? () => _set(_settings.copyWith(quantity: settings.quantity - 1)) : null,
              increment: settings.quantity < maxPictures ? () => _set(_settings.copyWith(quantity: settings.quantity + 1)) : null,
            ),
          ),
          SettingsToggleRow(
            tint: StudyStyle.accent(context),
            key: const Key('generator.randomSeed'),
            title: L10n.text('Random Seed'),
            value: settings.seed == null,
            onChanged: (random) {
              if (random) {
                _set(_settings.copyWith(clearSeed: true));
              } else {
                final seed = DateTime.now().microsecondsSinceEpoch % 4294967296;
                _seed.text = '$seed';
                _set(_settings.copyWith(seed: seed));
              }
            },
          ),
          if (settings.seed != null)
            FormRow(
              child: CupertinoTextField.borderless(
                key: const Key('generator.seed'),
                controller: _seed,
                padding: EdgeInsets.zero,
                placeholder: L10n.text('Seed'),
                placeholderStyle: TegnalType.style(17, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: generatorMonospace(context, size: 17),
                onChanged: (value) => _set(_settings.copyWith(seed: int.tryParse(value) ?? 0)),
              ),
            ),
          if (!widget.safeMode())
            SettingsToggleRow(
              key: const Key('generator.mature'),
              title: L10n.text('Allow Mature Results'),
              value: settings.mature,
              onChanged: (value) => _set(_settings.copyWith(mature: value)),
            ),
        ],
      ),
    ];
  }

  Widget _generateButton(BuildContext context) {
    final accent = StudyStyle.accent(context);
    const white = Color(0xFFFFFFFF);
    final enabled = !_run.isRunning && _trimmed.isNotEmpty;
    return Semantics(
      button: true,
      enabled: enabled,
      child: GestureDetector(
        key: const Key('generator.generate'),
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? _generate : null,
        child: Opacity(
          opacity: enabled || _run.isRunning ? 1 : 0.4,
          child: Container(
            height: 50,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: ShapeDecoration(color: accent, shape: const StadiumBorder()),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_run.isRunning) const CupertinoActivityIndicator(color: white) else const Icon(CupertinoIcons.wand_stars, size: 19, color: white),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    _run.isRunning ? _status : L10n.text('Generate'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TegnalType.style(17, weight: FontWeight.w600, color: white),
                  ),
                ),
                if (!_run.isRunning && _store.hasKey && _settings.model != null) ...[
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '· $_cost',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TegnalType.style(15, color: white.withValues(alpha: 0.85)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `Stepper`: a minus and a plus in one capsule.
class GeneratorStepper extends StatelessWidget {
  const GeneratorStepper({super.key, required this.label, required this.value, required this.decrement, required this.increment});
  final String label;

  /// The number it steps, read out by assistive technologies.
  final int value;
  final VoidCallback? decrement;
  final VoidCallback? increment;

  static const _background = CupertinoDynamicColor.withBrightness(color: Color(0xFFEEEEEF), darkColor: Color(0xFF3B3B3D));

  @override
  Widget build(BuildContext context) {
    final ink = TegnalColors.label.resolveFrom(context);
    Widget bar({bool vertical = false}) => Container(
      width: vertical ? 2.4 : 13,
      height: vertical ? 13 : 2.4,
      decoration: ShapeDecoration(color: ink, shape: const StadiumBorder()),
    );
    Widget half(Key key, Widget glyph, VoidCallback? onTap) => GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onTap: onTap == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              onTap();
            },
      child: SizedBox(
        width: 46,
        height: 32,
        child: Opacity(
          opacity: onTap == null ? 0.3 : 1,
          child: Center(child: glyph),
        ),
      ),
    );
    return Semantics(
      label: label,
      value: '$value',
      increasedValue: '${value + 1}',
      decreasedValue: '${value - 1}',
      onIncrease: increment,
      onDecrease: decrement,
      child: ExcludeSemantics(
        child: Container(
          decoration: ShapeDecoration(color: _background.resolveFrom(context), shape: const StadiumBorder()),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              half(const Key('decrement'), bar(), decrement),
              Container(width: 0.7, height: 24, color: TegnalColors.secondaryLabel.resolveFrom(context).withValues(alpha: 0.5)),
              half(const Key('increment'), Stack(alignment: Alignment.center, children: [bar(), bar(vertical: true)]), increment),
            ],
          ),
        ),
      ),
    );
  }
}

/// `Slider(value:in:step:)`: the iOS slider snapping to a step, read out with its own value.
class GeneratorSlider extends StatelessWidget {
  const GeneratorSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.digits,
    required this.onChanged,
  });
  final String label;
  final double value;
  final double min;
  final double max;
  final double step;

  /// Decimals shown and kept.
  final int digits;
  final ValueChanged<double> onChanged;

  double _snap(double raw) {
    final stepped = min + ((raw - min) / step).round() * step;
    return double.parse(stepped.clamp(min, max).toStringAsFixed(digits));
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    slider: true,
    value: value.toStringAsFixed(digits),
    increasedValue: _snap(value + step).toStringAsFixed(digits),
    decreasedValue: _snap(value - step).toStringAsFixed(digits),
    onIncrease: () => onChanged(_snap(value + step)),
    onDecrease: () => onChanged(_snap(value - step)),
    child: ExcludeSemantics(
      child: TegnalSlider(tint: StudyStyle.accent(context), value: value, min: min, max: max, onChanged: (raw) => onChanged(_snap(raw))),
    ),
  );
}
