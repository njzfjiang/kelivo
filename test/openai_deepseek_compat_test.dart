import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/api/chat_api_service.dart';

ProviderConfig _deepSeekConfig(String baseUrl, {String apiKey = ''}) {
  return ProviderConfig(
    id: 'DeepSeek',
    enabled: true,
    name: 'DeepSeek',
    apiKey: apiKey,
    baseUrl: baseUrl,
    providerType: ProviderKind.openai,
  );
}

String _deepSeekBaseUrl(HttpServer server) {
  return 'http://${server.address.address}:${server.port}/v1';
}

Future<Map<String, dynamic>> _readJsonBody(HttpRequest request) async {
  return jsonDecode(await utf8.decoder.bind(request).join())
      as Map<String, dynamic>;
}

void main() {
  group('DeepSeek compatibility', () {
    test(
      'thinking mode uses thinking.type and keeps effort semantics',
      () async {
        final requests = <Map<String, dynamic>>[];

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async {
          await server.close(force: true);
        });

        server.listen((request) async {
          requests.add(await _readJsonBody(request));
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.write(
            'data: ${jsonEncode({
              'id': 'cmpl-ds',
              'object': 'chat.completion.chunk',
              'created': 0,
              'model': 'deepseek-v4-pro',
              'choices': [
                {
                  'index': 0,
                  'delta': {'role': 'assistant', 'content': 'ok'},
                  'finish_reason': 'stop',
                },
              ],
            })}\n\n',
          );
          request.response.write('data: [DONE]\n\n');
          await request.response.close();
        });

        final baseUrl = _deepSeekBaseUrl(server);
        await ChatApiService.sendMessageStream(
          config: _deepSeekConfig(baseUrl),
          modelId: 'deepseek-v4-pro',
          messages: const [
            {'role': 'user', 'content': 'hello'},
          ],
        ).toList();

        await ChatApiService.sendMessageStream(
          config: _deepSeekConfig(baseUrl),
          modelId: 'deepseek-v4-pro',
          messages: const [
            {'role': 'user', 'content': 'hello again'},
          ],
          thinkingBudget: 0,
        ).toList();

        expect(requests, hasLength(2));

        final enabledBody = requests[0];
        expect(enabledBody['thinking'], {'type': 'enabled'});
        expect(enabledBody.containsKey('reasoning_content'), isFalse);
        expect(enabledBody.containsKey('reasoning_budget'), isFalse);
        expect(enabledBody.containsKey('reasoning_effort'), isFalse);

        final disabledBody = requests[1];
        expect(disabledBody['thinking'], {'type': 'disabled'});
        expect(disabledBody.containsKey('reasoning_content'), isFalse);
        expect(disabledBody.containsKey('reasoning_budget'), isFalse);
        expect(disabledBody.containsKey('reasoning_effort'), isFalse);
      },
    );

    test('streaming tool continuation keeps reasoning_content echo', () async {
      final requestBodies = <Map<String, dynamic>>[];
      var requestCount = 0;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requestCount += 1;
        requestBodies.add(await _readJsonBody(request));

        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );

        if (requestCount == 1) {
          request.response.write(
            'data: ${jsonEncode({
              'id': 'cmpl-1',
              'object': 'chat.completion.chunk',
              'created': 0,
              'model': 'deepseek-v4-pro',
              'choices': [
                {
                  'index': 0,
                  'delta': {
                    'role': 'assistant',
                    'reasoning_content': '先判断今天日期',
                    'content': '我去调用工具',
                    'tool_calls': [
                      {
                        'index': 0,
                        'id': 'call_1',
                        'type': 'function',
                        'function': {'name': 'date', 'arguments': '{}'},
                      },
                    ],
                  },
                  'finish_reason': 'tool_calls',
                },
              ],
            })}\n\n',
          );
        } else {
          request.response.write(
            'data: ${jsonEncode({
              'id': 'cmpl-2',
              'object': 'chat.completion.chunk',
              'created': 0,
              'model': 'deepseek-v4-pro',
              'choices': [
                {
                  'index': 0,
                  'delta': {'role': 'assistant', 'content': '今天是 2026-04-24'},
                  'finish_reason': 'stop',
                },
              ],
            })}\n\n',
          );
        }

        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _deepSeekConfig(_deepSeekBaseUrl(server)),
        modelId: 'deepseek-v4-pro',
        messages: const [
          {'role': 'user', 'content': '今天几号？'},
        ],
        tools: const [
          {
            'type': 'function',
            'function': {
              'name': 'date',
              'description': 'Get current date',
              'parameters': {
                'type': 'object',
                'properties': <String, dynamic>{},
              },
            },
          },
        ],
        onToolCall: (_, __) async => '2026-04-24',
      ).toList();

      expect(requestBodies, hasLength(2));
      expect(requestBodies[0]['thinking'], {'type': 'enabled'});
      expect(requestBodies[1]['thinking'], {'type': 'enabled'});

      final secondMessages = (requestBodies[1]['messages'] as List)
          .cast<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      final assistantToolMessage = secondMessages.firstWhere(
        (m) => m['role'] == 'assistant' && m['tool_calls'] is List,
      );
      expect(assistantToolMessage['reasoning_content'], '先判断今天日期');
      expect(assistantToolMessage['content'], '我去调用工具');
      expect(
        chunks.map((chunk) => chunk.content).join(),
        contains('今天是 2026-04-24'),
      );
    });

    test('follow-up reasoning from message object is preserved', () async {
      final chunks = <dynamic>[];
      var requestCount = 0;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requestCount += 1;
        await _readJsonBody(request);

        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );

        if (requestCount == 1) {
          request.response.write(
            'data: ${jsonEncode({
              'id': 'cmpl-1',
              'object': 'chat.completion.chunk',
              'created': 0,
              'model': 'deepseek-v4-pro',
              'choices': [
                {
                  'index': 0,
                  'delta': {
                    'role': 'assistant',
                    'reasoning_content': '先判断今天日期',
                    'content': '我去调用工具',
                    'tool_calls': [
                      {
                        'index': 0,
                        'id': 'call_1',
                        'type': 'function',
                        'function': {'name': 'date', 'arguments': '{}'},
                      },
                    ],
                  },
                  'finish_reason': 'tool_calls',
                },
              ],
            })}\n\n',
          );
        } else {
          request.response.write(
            'data: ${jsonEncode({
              'id': 'cmpl-2',
              'object': 'chat.completion.chunk',
              'created': 0,
              'model': 'deepseek-v4-pro',
              'choices': [
                {
                  'index': 0,
                  'delta': {'role': 'assistant'},
                  'message': {'role': 'assistant', 'reasoning_content': '根据工具结果整理回答', 'content': '今天是 2026-04-24'},
                  'finish_reason': 'stop',
                },
              ],
            })}\n\n',
          );
        }

        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      });

      final stream = ChatApiService.sendMessageStream(
        config: _deepSeekConfig(_deepSeekBaseUrl(server)),
        modelId: 'deepseek-v4-pro',
        messages: const [
          {'role': 'user', 'content': '今天几号？'},
        ],
        tools: const [
          {
            'type': 'function',
            'function': {
              'name': 'date',
              'description': 'Get current date',
              'parameters': {
                'type': 'object',
                'properties': <String, dynamic>{},
              },
            },
          },
        ],
        onToolCall: (_, __) async => '2026-04-24',
      );

      await for (final chunk in stream) {
        chunks.add(chunk);
      }

      final reasoningTexts = chunks
          .where((chunk) => (chunk.reasoning ?? '').isNotEmpty)
          .map((chunk) => chunk.reasoning as String)
          .toList(growable: false);
      final contentTexts = chunks
          .where((chunk) => (chunk.content ?? '').isNotEmpty)
          .map((chunk) => chunk.content as String)
          .join();

      expect(reasoningTexts, contains('根据工具结果整理回答'));
      expect(contentTexts, contains('今天是 2026-04-24'));
    });
  });
}
