import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/generation/generation_air.dart';

GenerationAIR air(String text) => GenerationAIR.parse(text)!;

void main() {
  group('parsing', () {
    test('reads the full form', () {
      final value = air('urn:air:sdxl:checkpoint:civitai:827184@2514310');
      expect(value.ecosystem, 'sdxl');
      expect(value.type, 'checkpoint');
      expect(value.source, 'civitai');
      expect(value.id, '827184');
      expect(value.version, '2514310');
      expect(value.file, isNull);
      expect(value.format, isNull);
      expect(value.text, 'urn:air:sdxl:checkpoint:civitai:827184@2514310');
    });

    test('reads it without the urn and air prefixes, in any case', () {
      expect(air('sdxl:checkpoint:civitai:827184@2514310'), air('urn:air:sdxl:checkpoint:civitai:827184@2514310'));
      expect(air('air:sdxl:lora:civitai:1@2').type, 'lora');
      expect(air('URN:AIR:SDXL:Checkpoint:civitai:1').ecosystem, 'sdxl');
      expect(air('URN:AIR:SDXL:Checkpoint:civitai:1').type, 'checkpoint');
      expect(air('  urn:air:sd1:checkpoint:civitai:4384  ').text, 'urn:air:sd1:checkpoint:civitai:4384');
    });

    test('reads three parts as ecosystem, source and id', () {
      final value = air('sdxl:civitai:123@456');
      expect(value.ecosystem, 'sdxl');
      expect(value.type, isNull);
      expect(value.source, 'civitai');
      expect(value.id, '123');
      expect(value.text, 'urn:air:sdxl:civitai:123@456');
    });

    test('reads two parts as source and id', () {
      final value = air('civitai:123@456');
      expect(value.ecosystem, isNull);
      expect(value.type, isNull);
      expect(value.source, 'civitai');
      expect(value.id, '123');
      expect(value.version, '456');
      expect(value.text, 'urn:air:civitai:123@456');
    });

    test('reads a version, a file and a format', () {
      final value = air('urn:air:sdxl:lora:civitai:1@2+file_a.safetensors');
      expect(value.version, '2');
      expect(value.file, 'file_a');
      expect(value.format, 'safetensors');
      expect(value.text, 'urn:air:sdxl:lora:civitai:1@2+file_a.safetensors');
      expect(air('urn:air:sdxl:lora:civitai:1@2.safetensors').format, 'safetensors');
      expect(air('urn:air:sdxl:lora:civitai:1@2.safetensors').file, isNull);
    });

    test('keeps a dotted version and a dotted id', () {
      expect(air('sdxl:checkpoint:civitai:1@2.5').version, '2.5');
      expect(air('sdxl:checkpoint:civitai:1@2.5').format, isNull);
      expect(air('sdxl:checkpoint:huggingface:org/name.v2').id, 'org/name.v2');
    });

    test('round trips', () {
      for (final text in [
        'urn:air:sdxl:checkpoint:civitai:827184@2514310',
        'urn:air:sd1:lora:civitai:12@34+name.safetensors',
        'urn:air:illustrious:checkpoint:civitai:99',
        'urn:air:civitai:5@6',
      ]) {
        expect(air(air(text).text), air(text));
        expect(air(text).text, text);
      }
    });

    test('rejects what is not an identifier', () {
      for (final text in ['', 'hello', 'civitai:', ':123', 'a:b:c:d:e:f', 'civitai:12 3', 'civitai:1@', 'civitai:1@2+', 'civitai:1@a b', 'sdxl:chéckpoint:civitai:1']) {
        expect(GenerationAIR.parse(text), isNull, reason: text);
      }
    });
  });

  test('reads a page address as a source and an id without an ecosystem, which the picker tells apart', () {
    final value = air('https://civitai.com/models/1');
    expect(value.ecosystem, isNull);
    expect(value.source, 'https');
  });

  group('kind and family', () {
    test('maps the type to a kind', () {
      expect(air('sdxl:checkpoint:civitai:1').kind, GenerationKind.checkpoint);
      expect(air('sdxl:model:civitai:1').kind, GenerationKind.checkpoint);
      expect(air('sdxl:lora:civitai:1').kind, GenerationKind.lora);
      expect(air('sdxl:locon:civitai:1').kind, GenerationKind.lora);
      expect(air('sdxl:embedding:civitai:1').kind, GenerationKind.embedding);
      expect(air('sdxl:vae:civitai:1').kind, GenerationKind.vae);
      expect(air('sdxl:controlnet:civitai:1').kind, GenerationKind.other);
      expect(air('sdxl:civitai:1').kind, GenerationKind.other);
    });

    test('puts Illustrious, Pony and NoobAI in the SDXL family, and Flux in none', () {
      expect(air('sd1:checkpoint:civitai:1').family, GenerationFamily.sd1);
      expect(air('sd15:checkpoint:civitai:1').family, GenerationFamily.sd1);
      expect(air('sdxl:checkpoint:civitai:1').family, GenerationFamily.sdxl);
      expect(air('illustrious:checkpoint:civitai:1').family, GenerationFamily.sdxl);
      expect(air('pony:checkpoint:civitai:1').family, GenerationFamily.sdxl);
      expect(air('noobai:checkpoint:civitai:1').family, GenerationFamily.sdxl);
      expect(air('flux1:checkpoint:civitai:1').family, isNull);
      expect(air('civitai:1').family, isNull);
    });
  });

  group('version ids', () {
    test('reads a bare number', () => expect(GenerationAIR.versionID(' 2514310 '), 2514310));

    test('reads a model page address with modelVersionId', () {
      expect(GenerationAIR.versionID('https://civitai.com/models/827184/some-name?modelVersionId=2514310'), 2514310);
    });

    test('reads an API path', () => expect(GenerationAIR.versionID('https://civitai.com/api/v1/model-versions/2514310'), 2514310));

    test('reads nothing from other text', () {
      for (final text in ['', '0', '-5', 'hello', 'https://civitai.com/models/827184', 'https://civitai.com/api/v1/model-versions/abc', 'urn:air:sdxl:checkpoint:civitai:1']) {
        expect(GenerationAIR.versionID(text), isNull, reason: text);
      }
    });
  });
}
