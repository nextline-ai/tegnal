/// An AI Resource identifier: `urn:air:{ecosystem}:{type}:{source}:{id}[@{version}][+{file}][.{format}]`
/// (`GenerationAIR`). The `urn:` and `air:` prefixes, the ecosystem and the type may be left out; a
/// source and an id are always there.
enum GenerationKind { checkpoint, lora, embedding, vae, other }

/// The engine family a checkpoint runs on.
enum GenerationFamily {
  sd1,
  sdxl;

  String get rawValue => name;
}

class GenerationAIR {
  const GenerationAIR._({this.ecosystem, this.type, required this.source, required this.id, this.version, this.file, this.format});

  final String? ecosystem;
  final String? type;
  final String source;
  final String id;
  final String? version;
  final String? file;
  final String? format;

  static final _allowed = RegExp(r'^[a-zA-Z0-9_\-/]+$');
  static bool _valid(String text, [String extra = '']) {
    if (text.isEmpty) return false;
    for (final unit in text.runes) {
      final char = String.fromCharCode(unit);
      if (!_allowed.hasMatch(char) && !extra.contains(char)) return false;
    }
    return true;
  }

  static final _letters = RegExp(r'^\p{L}+$', unicode: true);

  /// Reads [text], or returns null when it is not an identifier.
  static GenerationAIR? parse(String text) {
    var rest = text.trim();
    for (final prefix in const ['urn:', 'air:']) {
      if (rest.toLowerCase().startsWith(prefix)) rest = rest.substring(prefix.length);
    }
    final parts = rest.split(':');
    if (parts.length < 2 || parts.length > 4) return null;
    var last = parts.removeLast();
    String? version, file, format;
    final at = last.indexOf('@');
    if (at >= 0) {
      var tail = last.substring(at + 1);
      last = last.substring(0, at);
      final dot = tail.lastIndexOf('.');
      if (dot >= 0 && dot + 1 < tail.length && _letters.hasMatch(tail.substring(dot + 1))) {
        format = tail.substring(dot + 1);
        tail = tail.substring(0, dot);
      }
      final plus = tail.indexOf('+');
      if (plus >= 0) {
        file = tail.substring(plus + 1);
        tail = tail.substring(0, plus);
      }
      if (!_valid(tail, '.=,%') || (file != null && !_valid(file))) return null;
      version = tail;
    }
    if (!_valid(last, '.') || !parts.every(_valid)) return null;
    final source = parts.removeLast();
    // With one part left it is the ecosystem; with two, the ecosystem and the type.
    final type = parts.length == 2 ? parts[1].toLowerCase() : null;
    final ecosystem = parts.isEmpty ? null : parts.first.toLowerCase();
    return GenerationAIR._(ecosystem: ecosystem, type: type, source: source, id: last, version: version, file: file, format: format);
  }

  /// The identifier in its full form.
  String get text {
    final head = [ecosystem, type].whereType<String>().followedBy([source, id]).join(':');
    var result = 'urn:air:$head';
    if (version != null) result += '@$version';
    if (file != null) result += '+$file';
    if (format != null) result += '.$format';
    return result;
  }

  GenerationKind get kind => switch (type) {
    'checkpoint' || 'model' || 'diffusionmodel' || 'unet' => GenerationKind.checkpoint,
    'lora' || 'locon' || 'dora' || 'lycoris' => GenerationKind.lora,
    'embedding' || 'textualinversion' => GenerationKind.embedding,
    'vae' => GenerationKind.vae,
    _ => GenerationKind.other,
  };

  /// Stable Diffusion 1.5 and the SDXL family, which Illustrious, NoobAI, Pony and Animagine belong to.
  GenerationFamily? get family => switch (ecosystem) {
    'sd1' || 'sd15' || 'sd1.5' => GenerationFamily.sd1,
    'sdxl' || 'illustrious' || 'noobai' || 'pony' || 'sdxlturbo' || 'sdxllightning' || 'sdxlhyper' => GenerationFamily.sdxl,
    _ => null,
  };

  /// The model version a pasted web address or a bare number points at, to be looked up for its identifier.
  static int? versionID(String text) {
    final trimmed = text.trim();
    final number = int.tryParse(trimmed);
    if (number != null && number > 0) return number;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    try {
      final value = uri.queryParameters['modelVersionId'];
      final parsed = value == null ? null : int.tryParse(value);
      if (parsed != null) return parsed;
    } on FormatException {
      // A malformed query has no version in it.
    }
    final path = uri.path.split('/').where((part) => part.isNotEmpty).toList();
    final index = path.indexOf('model-versions');
    if (index >= 0 && index + 1 < path.length) return int.tryParse(path[index + 1]);
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is GenerationAIR &&
      other.ecosystem == ecosystem &&
      other.type == type &&
      other.source == source &&
      other.id == id &&
      other.version == version &&
      other.file == file &&
      other.format == format;

  @override
  int get hashCode => Object.hash(ecosystem, type, source, id, version, file, format);
}
