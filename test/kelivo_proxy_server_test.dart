import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:Kelivo/core/services/analysis/analysis_protocol.dart';
import 'package:Kelivo/core/services/analysis/kelivo_proxy_server.dart';
import 'package:Kelivo/core/services/analysis/proxy_analysis_store.dart';

void main() {
  test(
    'proxy strips kelivo metadata before forwarding and stores turn',
    () async {
      Map<String, dynamic>? upstreamBody;
      HttpHeaders? upstreamHeaders;
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await upstream.close(force: true);
      });
      upstream.listen((request) async {
        upstreamHeaders = request.headers;
        upstreamBody =
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
                'message': {'role': 'assistant', 'content': 'proxy-ok'},
                'finish_reason': 'stop',
              },
            ],
            'usage': {
              'prompt_tokens': 3,
              'completion_tokens': 2,
              'total_tokens': 5,
            },
          }),
        );
        await request.response.close();
      });

      final tempDir = await Directory.systemTemp.createTemp(
        'kelivo_proxy_test',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final dbPath = p.join(tempDir.path, 'proxy_analysis_v1.db');
      final proxy = KelivoProxyServer(
        upstreamBaseUri: Uri.parse(
          'http://${upstream.address.address}:${upstream.port}',
        ),
        host: InternetAddress.loopbackIPv4,
        port: 0,
        dbPath: dbPath,
      );
      final proxyServer = await proxy.start();
      addTearDown(() async {
        await proxy.close();
      });

      final client = HttpClient();
      addTearDown(client.close);
      final req = await client.post(
        proxyServer.address.address,
        proxyServer.port,
        '/v1/chat/completions',
      );
      req.headers.contentType = ContentType.json;
      req.headers.set(kelivoAnalysisTurnHeaderName, 'turn-123');
      req.headers.set(kelivoAnalysisConversationHeaderName, 'session-456');
      req.headers.set(kelivoAnalysisVersionHeaderName, '1');
      req.write(
        jsonEncode({
          'model': 'gpt-4.1',
          'stream': false,
          'messages': [
            {'role': 'user', 'content': 'hello proxy'},
          ],
          kelivoAnalysisMetaBodyKey: {
            'turn_id': 'turn-123',
            'session_id': 'session-456',
            'seq': 7,
            'assistant_id': 'assistant-a',
            'provider_key': 'OpenAI',
            'model_id': 'gpt-4.1',
            'stream': false,
            'rolling_short_before': 'before',
            'rolling_short_after': 'after',
            'inject_snapshot': {
              'system_messages': ['sys'],
            },
            'inject_log': [
              {'kind': 'system_prompt', 'title': 'sys', 'position': 0},
            ],
          },
        }),
      );
      final resp = await req.close();
      final body = await utf8.decoder.bind(resp).join();

      expect(resp.statusCode, HttpStatus.ok);
      expect(body, contains('proxy-ok'));
      expect(upstreamHeaders!.value(kelivoAnalysisTurnHeaderName), isNull);
      expect(upstreamBody![kelivoAnalysisMetaBodyKey], isNull);
      expect(upstreamBody!['messages'], isA<List>());

      final store = ProxyAnalysisStore(dbPath: dbPath);
      addTearDown(() async {
        await store.close();
      });
      final turn = await store.getTurn('turn-123');
      expect(turn, isNotNull);
      expect(turn!['status'], 'completed');
      expect(turn['assistant_text'], 'proxy-ok');
      expect(turn['prompt_tokens'], 3);
      expect(turn['completion_tokens'], 2);
      expect(turn['total_tokens'], 5);
      expect(turn['inject_snapshot_json'], contains('system_messages'));
      expect(turn['request_json'], isNot(contains(kelivoAnalysisMetaBodyKey)));

      final injectLog = await store.getInjectLog('turn-123');
      expect(injectLog, hasLength(1));
      expect(injectLog.first['kind'], 'system_prompt');
    },
  );

  test('proxy accumulates streaming assistant text and stores it', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await upstream.close(force: true);
    });
    upstream.listen((request) async {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      request.response.write(
        'data: {"choices":[{"delta":{"content":"hel"}}]}\n\n',
      );
      request.response.write(
        'data: {"choices":[{"delta":{"content":"lo"}}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}\n\n',
      );
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });

    final tempDir = await Directory.systemTemp.createTemp(
      'kelivo_proxy_stream',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    final dbPath = p.join(tempDir.path, 'proxy_analysis_v1.db');
    final proxy = KelivoProxyServer(
      upstreamBaseUri: Uri.parse(
        'http://${upstream.address.address}:${upstream.port}',
      ),
      host: InternetAddress.loopbackIPv4,
      port: 0,
      dbPath: dbPath,
    );
    final proxyServer = await proxy.start();
    addTearDown(() async {
      await proxy.close();
    });

    final client = HttpClient();
    addTearDown(client.close);
    final req = await client.post(
      proxyServer.address.address,
      proxyServer.port,
      '/v1/chat/completions',
    );
    req.headers.contentType = ContentType.json;
    req.headers.set(kelivoAnalysisTurnHeaderName, 'turn-stream');
    req.headers.set(kelivoAnalysisConversationHeaderName, 'session-stream');
    req.write(
      jsonEncode({
        'model': 'gpt-4.1',
        'stream': true,
        'messages': [
          {'role': 'user', 'content': 'hello stream'},
        ],
        kelivoAnalysisMetaBodyKey: {
          'turn_id': 'turn-stream',
          'session_id': 'session-stream',
          'seq': 1,
          'provider_key': 'OpenAI',
          'model_id': 'gpt-4.1',
          'stream': true,
          'inject_log': const [],
        },
      }),
    );
    final resp = await req.close();
    final rawSse = await utf8.decoder.bind(resp).join();
    expect(rawSse, contains('"content":"hel"'));
    expect(rawSse, contains('"content":"lo"'));

    final store = ProxyAnalysisStore(dbPath: dbPath);
    addTearDown(() async {
      await store.close();
    });
    final turn = await store.getTurn('turn-stream');
    expect(turn, isNotNull);
    expect(turn!['status'], 'completed');
    expect(turn['assistant_text'], 'hello');
    expect(turn['total_tokens'], 3);
    expect(turn['response_json'], contains('[DONE]'));
  });

  test('proxy routes upstream by provider_key with default fallback', () async {
    Map<String, dynamic>? deepSeekBody;
    Map<String, dynamic>? openAiBody;

    final deepSeek = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await deepSeek.close(force: true);
    });
    deepSeek.listen((request) async {
      deepSeekBody =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'deepseek-ok'},
              'finish_reason': 'stop',
            },
          ],
        }),
      );
      await request.response.close();
    });

    final openAi = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await openAi.close(force: true);
    });
    openAi.listen((request) async {
      openAiBody =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'openai-ok'},
              'finish_reason': 'stop',
            },
          ],
        }),
      );
      await request.response.close();
    });

    final tempDir = await Directory.systemTemp.createTemp('kelivo_proxy_route');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final proxy = KelivoProxyServer(
      upstreamBaseUri: Uri.parse(
        'http://${openAi.address.address}:${openAi.port}',
      ),
      providerUpstreamBaseUris: {
        'DeepSeek': Uri.parse(
          'http://${deepSeek.address.address}:${deepSeek.port}',
        ),
      },
      host: InternetAddress.loopbackIPv4,
      port: 0,
      dbPath: p.join(tempDir.path, 'proxy_analysis_v1.db'),
    );
    final proxyServer = await proxy.start();
    addTearDown(() async {
      await proxy.close();
    });

    final client = HttpClient();
    addTearDown(client.close);

    Future<String> sendWithProvider(String turnId, String providerKey) async {
      final req = await client.post(
        proxyServer.address.address,
        proxyServer.port,
        '/v1/chat/completions',
      );
      req.headers.contentType = ContentType.json;
      req.headers.set(kelivoAnalysisTurnHeaderName, turnId);
      req.headers.set(kelivoAnalysisConversationHeaderName, 'session-route');
      req.write(
        jsonEncode({
          'model': 'test-model',
          'messages': [
            {'role': 'user', 'content': 'hello'},
          ],
          kelivoAnalysisMetaBodyKey: {
            'turn_id': turnId,
            'session_id': 'session-route',
            'seq': 1,
            'provider_key': providerKey,
            'model_id': 'test-model',
            'stream': false,
            'inject_log': const [],
          },
        }),
      );
      final resp = await req.close();
      return await utf8.decoder.bind(resp).join();
    }

    final deepSeekResp = await sendWithProvider('turn-deepseek', 'DeepSeek');
    final openAiResp = await sendWithProvider('turn-openai', 'OpenAI');

    expect(deepSeekResp, contains('deepseek-ok'));
    expect(openAiResp, contains('openai-ok'));
    expect(deepSeekBody?['messages'], isA<List>());
    expect(openAiBody?['messages'], isA<List>());
  });
}
