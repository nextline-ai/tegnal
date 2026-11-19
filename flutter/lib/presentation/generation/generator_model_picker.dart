import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/generation/generation_air.dart';
import '../../core/generation/generation_client.dart';
import '../../core/generation/generation_store.dart';
import '../../core/support/l10n.dart';
import '../design/grouped_form.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import '../library/folders_view.dart' show LibrarySearchField;
import '../settings/settings_page.dart';
import '../study/study_widgets.dart' show StudyStyle;
import 'generator_sheet.dart';

/// Chooses a model: by its AIR, by its page address, or by searching the models Civitai can generate with
/// (`GeneratorModelPicker`).
class GeneratorModelPicker extends StatefulWidget {
  const GeneratorModelPicker({super.key, required this.environment, required this.kind, required this.choose});
  final GeneratorEnvironment environment;
  final GenerationKind kind;
  final void Function(GenerationModel model) choose;

  @override
  State<GeneratorModelPicker> createState() => _GeneratorModelPickerState();
}

class _GeneratorModelPickerState extends State<GeneratorModelPicker> {
  final _pasted = TextEditingController();
  final _search = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  int _searchToken = 0;
  String _searched = '';
  List<GenerationModel> _results = [];
  bool _searching = false;
  bool _working = false;
  String? _message;

  GenerationStore get _store => widget.environment.store;
  GenerationKind get _kind => widget.kind;
  String get _example => _kind == GenerationKind.lora ? 'urn:air:sdxl:lora:civitai:123456@789012' : 'urn:air:sdxl:checkpoint:civitai:827184@2514310';
  List<GenerationModel> get _recent => _store.recentModels.where((model) => GenerationAIR.parse(model.air)?.kind == _kind).toList();

  @override
  void initState() {
    super.initState();
    _pasted.addListener(_changed);
    _search.addListener(_searchChanged);
    _store.load().then((_) => _runSearch());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _pasted.dispose();
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _searchChanged() {
    final text = _search.text;
    if (text == _searched) return;
    _debounce?.cancel();
    _debounce = Timer(text.isEmpty ? Duration.zero : const Duration(milliseconds: 500), _runSearch);
    setState(() {});
  }

  Future<void> _runSearch() async {
    if (!mounted) return;
    final text = _search.text;
    _searched = text;
    final token = ++_searchToken;
    setState(() => _searching = true);
    List<GenerationModel> found;
    try {
      found = await _store.client().search(text, kind: _kind, mature: !widget.environment.safeMode() && _store.settings.mature);
    } on Object {
      found = [];
    }
    if (!mounted || token != _searchToken) return;
    setState(() {
      _results = found;
      _searching = false;
    });
  }

  void _pick(GenerationModel model) {
    final air = GenerationAIR.parse(model.air);
    if (air == null) {
      setState(() => _message = const GenerationError.notFound().message);
      return;
    }
    if (_kind == GenerationKind.checkpoint && air.family == null) {
      setState(() => _message = const GenerationError.unsupportedModel().message);
      return;
    }
    if (air.type != null && air.kind != _kind) {
      setState(() => _message = L10n.text(_kind == GenerationKind.lora ? 'This is not a LoRA.' : 'This is not a checkpoint.'));
      return;
    }
    _store.remember(model);
    widget.choose(model);
    Navigator.of(context).pop();
  }

  Future<void> _lookUp(GenerationModel model) async {
    final id = model.versionID;
    if (id == null) return;
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      final found = await _store.client().version(id);
      if (mounted) _pick(found);
    } on GenerationError catch (error) {
      if (mounted) setState(() => _message = error.message);
    } on Object catch (error) {
      if (mounted) setState(() => _message = '$error');
    }
    if (mounted) setState(() => _working = false);
  }

  /// Reads what was pasted: an AIR as it is, or a page address or version number looked up for its AIR.
  Future<void> _resolve(String text) async {
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      final air = GenerationAIR.parse(text);
      if (air != null && (air.ecosystem != null || text.toLowerCase().contains('air:'))) {
        var model = GenerationModel(air: air.text, name: air.text);
        // The name is a nicety; the identifier works without it.
        final version = air.version == null ? null : int.tryParse(air.version!);
        if (air.source == 'civitai' && version != null) {
          try {
            final found = await _store.client().version(version);
            if (found.air == air.text) model = found;
          } on Object {
            // The identifier works without a name.
          }
        }
        if (mounted) _pick(model);
      } else if (GenerationAIR.versionID(text) case final id?) {
        try {
          final found = await _store.client().version(id);
          if (mounted) _pick(found);
        } on GenerationError catch (error) {
          if (mounted) setState(() => _message = error.message);
        } on Object catch (error) {
          if (mounted) setState(() => _message = '$error');
        }
      } else {
        setState(() => _message = L10n.text('This is not an AIR, a model page address or a version number.'));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Widget _line(BuildContext context, String key, GenerationModel model, VoidCallback onTap) => FormRow(
    key: Key(key),
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(model.name, style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context))),
            if (model.base != null) Text(model.base!, style: TegnalType.style(12, color: TegnalColors.secondaryLabel.resolveFrom(context))),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final rowColor = FormColors.listRow.resolveFrom(context);
    final canUse = !_working && _pasted.text.trim().isNotEmpty;
    final recent = _recent;
    return SettingsPage(
      title: L10n.text(_kind == GenerationKind.lora ? 'Add a LoRA' : 'Choose a Model'),
      children: [
        LibrarySearchField(controller: _search, focusNode: _focus, prompt: L10n.text('Search Civitai'), onSubmitted: (_) => _runSearch()),
        const SizedBox(height: 16),
        FormSection(
          prominentHeader: true,
          rowColor: rowColor,
          header: Text(L10n.text('AIR or Model Page')),
          footer: Text(
            L10n.text('An AIR names a model exactly: urn:air:ecosystem:type:source:id@version. A Civitai model page address or version number works too.'),
          ),
          children: [
            FormRow(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: CupertinoTextField.borderless(
                  key: const Key('generator.air'),
                  controller: _pasted,
                  padding: EdgeInsets.zero,
                  placeholder: _example,
                  placeholderStyle: generatorMonospace(context).copyWith(color: TegnalColors.tertiaryLabel.resolveFrom(context)),
                  minLines: 1,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.none,
                  style: generatorMonospace(context),
                ),
              ),
            ),
            FormRow(
              key: const Key('generator.useAIR'),
              onTap: canUse ? () => _resolve(_pasted.text) : null,
              child: Opacity(
                opacity: canUse || _working ? 1 : 0.4,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(L10n.text('Use This Model'), style: TegnalType.style(17, color: StudyStyle.accent(context))),
                    ),
                    if (_working) const CupertinoActivityIndicator(),
                  ],
                ),
              ),
            ),
            if (_message case final message?)
              FormRow(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(CupertinoIcons.exclamationmark_triangle, size: 15, color: SystemColors.red.resolveFrom(context)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        message,
                        key: const Key('generator.pickerMessage'),
                        style: TegnalType.style(13, color: SystemColors.red.resolveFrom(context)),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        if (_kind == GenerationKind.checkpoint) ...[
          FormSection(
            rowColor: rowColor,
            children: [
              FormRow(
                key: const Key('generator.recommendedModel'),
                onTap: () => _pick(GenerationModel.recommended),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(GenerationModel.recommended.name, style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context))),
                            Text(
                              L10n.text('The best-rated model for 2D illustration, and the one this generator starts with.'),
                              style: TegnalType.style(12, color: TegnalColors.secondaryLabel.resolveFrom(context)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: ShapeDecoration(color: StudyStyle.accent(context), shape: const StadiumBorder()),
                        child: Text(
                          L10n.text('Suggested'),
                          style: TegnalType.style(12, color: const Color(0xFFFFFFFF)).copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          settingsSectionGap,
        ],
        if (recent.isNotEmpty) ...[
          settingsSectionGap,
          FormSection(
            prominentHeader: true,
            rowColor: rowColor,
            header: Text(L10n.text('Recent')),
            children: [for (final (index, model) in recent.indexed) _line(context, 'generator.recentRow.$index', model, () => _pick(model))],
          ),
        ],
        settingsSectionGap,
        FormSection(
          prominentHeader: true,
          rowColor: rowColor,
          header: Text(L10n.text(_search.text.isEmpty ? 'Most Downloaded on Civitai' : 'Search Results')),
          children: [
            if (_searching) const FormRow(child: Center(child: CupertinoActivityIndicator())),
            for (final (index, model) in _results.indexed) _line(context, 'generator.modelRow.$index', model, () => _lookUp(model)),
          ],
        ),
      ],
    );
  }
}
