import 'dart:convert';
import 'dart:typed_data';

import 'package:tegnal/core/generation/generation_client.dart';

/// A stand-in for the service that remembers what it was asked.
class FakeService {
  FakeService(this.handler);
  final Future<GenerationResponse> Function(GenerationRequest request) handler;
  final requests = <GenerationRequest>[];

  GenerationTransport get transport => (request) {
    requests.add(request);
    return handler(request);
  };

  /// The JSON body of request number [index].
  Map<String, dynamic> body(int index) => jsonDecode(requests[index].body!) as Map<String, dynamic>;
}

GenerationResponse json(Object? object, {int status = 200, Map<String, String> headers = const {}}) =>
    GenerationResponse(status, Uint8List.fromList(utf8.encode(jsonEncode(object))), headers);

const checkpoint = GenerationModel(air: 'urn:air:sdxl:checkpoint:civitai:827184@2514310', name: 'Fixture Model · v1', base: 'Illustrious', versionID: 2514310);
const lora = GenerationModel(air: 'urn:air:sdxl:lora:civitai:123456@789012', name: 'Style LoRA');

Map<String, Object?> succeeded({String id = 'wf_1', Object? cost = const {'total': 10}, List<Map<String, Object?>>? images}) => {
  'id': id,
  'status': 'succeeded',
  'cost': cost,
  'steps': [
    {
      'output': {
        'images':
            images ??
            [
              {'id': 'a.png', 'url': 'https://images.example/a.png', 'available': true, 'width': 832, 'height': 1216},
            ],
      },
    },
  ],
};
