import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/analysis/analysis_capture_service.dart';
import 'package:Kelivo/core/services/api/chat_api_service.dart';

ProviderConfig _openAiConfig(String baseUrl) {
  return ProviderConfig(
    id: 'OpenAITest',
    enabled: true,
    name: 'OpenAITest',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.openai,
  );
}

void main() {
  test(
    'OpenAI local proxy requests include kelivo analysis metadata',
    () async {
      Map<String, dynamic>? requestBody;
      HttpHeaders? requestHeaders;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requestHeaders = request.headers;
        requestBody =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'id': 'chatcmpl-1',
            'object': 'chat.completion',
            'choices': [
              {
                'index': 0,
                'message': {'role': 'assistant', 'content': 'ok'},
                'finish_reason': 'stop',
              },
            ],
            'usage': {
              'prompt_tokens': 1,
              'completion_tokens': 1,
              'total_tokens': 2,
            },
          }),
        );
        await request.response.close();
      });

      await ChatApiService.sendMessageStream(
        config: _openAiConfig(
          'http://${server.address.address}:${server.port}/v1',
        ),
        modelId: 'gpt-4.1',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        extraHeaders: const {
          kelivoAnalysisTurnHeaderName: 'turn-1',
          kelivoAnalysisConversationHeaderName: 'conversation-1',
          kelivoAnalysisVersionHeaderName: '1',
        },
        extraBody: const {
          kelivoAnalysisMetaBodyKey: {
            'turn_id': 'turn-1',
            'session_id': 'conversation-1',
            'seq': 1,
          },
        },
        stream: false,
      ).toList();

      expect(requestHeaders!.value(kelivoAnalysisTurnHeaderName), 'turn-1');
      expect(
        requestHeaders!.value(kelivoAnalysisConversationHeaderName),
        'conversation-1',
      );
      expect(requestBody![kelivoAnalysisMetaBodyKey], isA<Map>());
      expect(
        (requestBody![kelivoAnalysisMetaBodyKey] as Map)['turn_id'],
        'turn-1',
      );
    },
  );
}
