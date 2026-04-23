import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/token_usage.dart';
import 'package:Kelivo/core/services/analysis/analysis_capture_service.dart';
import 'package:Kelivo/core/services/analysis/analysis_store.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late AnalysisStore store;
  late AnalysisCaptureService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('kelivo_analysis_test_');
    store = AnalysisStore.instance;
    await store.useTestDatabasePath('${tempDir.path}/analysis_v1.db');
    service = AnalysisCaptureService(store: store);
  });

  tearDown(() async {
    await store.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('prepareTurn stores snapshot and redacts sensitive headers', () async {
    final assistantMessage = ChatMessage(
      id: 'assistant-turn-1',
      role: 'assistant',
      content: '',
      conversationId: 'conversation-1',
    );

    final ctx = await service.prepareTurn(
      assistantMessage: assistantMessage,
      assistantId: 'assistant-a',
      providerKey: 'OpenAI',
      modelId: 'gpt-4.1',
      stream: true,
      apiMessages: const [
        {'role': 'system', 'content': 'system prompt'},
        {'role': 'user', 'content': 'hello world'},
      ],
      toolDefs: const [],
      injectSnapshot: const {
        'system_messages': ['system prompt'],
        'memory_records': [
          {'id': 1, 'content': 'user likes tea'},
        ],
      },
      injectLog: const [
        {
          'kind': 'memory',
          'source_id': '1',
          'title': 'memory_1',
          'reason': 'assistant_memory',
          'content_excerpt': 'user likes tea',
          'position': null,
          'payload_json': {'id': 1, 'content': 'user likes tea'},
        },
        {
          'kind': 'world_book',
          'source_id': 'wb-1',
          'title': 'world lore',
          'reason': 'world_book_trigger',
          'content_excerpt': 'important lore',
          'position': null,
          'payload_json': {'entry_id': 'wb-1'},
        },
      ],
      rollingShortBefore: 'older summary',
      rollingShortAfter: 'older summary',
      requestHeaders: const {'Authorization': 'Bearer super-secret'},
      existingBody: const {'temperature': 0.5},
    );

    final turn = await store.getTurn('assistant-turn-1');
    expect(turn, isNotNull);
    expect(turn!['status'], 'pending');
    expect(turn['session_id'], 'conversation-1');
    expect(turn['seq'], 1);

    final headers =
        jsonDecode(turn['request_headers_json'] as String)
            as Map<String, dynamic>;
    expect(headers['Authorization'], '[REDACTED]');
    expect(headers[kelivoAnalysisTurnHeaderName], 'assistant-turn-1');

    final injectLog = await store.getInjectLog('assistant-turn-1');
    expect(injectLog.map((e) => e['kind']), ['memory', 'world_book']);

    expect(ctx.extraHeaders[kelivoAnalysisTurnHeaderName], 'assistant-turn-1');
    expect(
      ctx.extraHeaders[kelivoAnalysisConversationHeaderName],
      'conversation-1',
    );
    expect(ctx.extraBody, isNotNull);
    expect(
      ctx.extraBody![kelivoAnalysisMetaBodyKey],
      isA<Map<String, dynamic>>(),
    );
  });

  test('turn status updates cover completed, error and cancelled', () async {
    final assistantMessage = ChatMessage(
      id: 'assistant-turn-2',
      role: 'assistant',
      content: '',
      conversationId: 'conversation-2',
    );

    await service.prepareTurn(
      assistantMessage: assistantMessage,
      assistantId: null,
      providerKey: 'OpenAI',
      modelId: 'gpt-4.1',
      stream: true,
      apiMessages: const [
        {'role': 'user', 'content': 'hello again'},
      ],
      toolDefs: const [],
      injectSnapshot: const {'system_messages': []},
      injectLog: const [],
      rollingShortBefore: null,
      rollingShortAfter: null,
      requestHeaders: const {},
      existingBody: const {},
    );

    await service.markCompleted(
      turnId: 'assistant-turn-2',
      chatService: ChatService(),
      finalMessage: assistantMessage,
      assistantText: 'done',
      reasoningText: 'reasoned',
      usage: const TokenUsage(
        promptTokens: 11,
        completionTokens: 7,
        cachedTokens: 3,
        totalTokens: 18,
      ),
      totalTokens: 18,
      latencyMs: 123,
    );

    var turn = await store.getTurn('assistant-turn-2');
    expect(turn!['status'], 'completed');
    expect(turn['assistant_text'], 'done');
    expect(turn['latency_ms'], 123);
    expect(turn['total_tokens'], 18);

    await service.markError(
      turnId: 'assistant-turn-2',
      errorText: 'boom',
      displayContent: 'boom',
      totalTokens: 4,
      latencyMs: 45,
    );
    turn = await store.getTurn('assistant-turn-2');
    expect(turn!['status'], 'error');
    expect(turn['error_text'], 'boom');

    await service.markCancelled(
      turnId: 'assistant-turn-2',
      assistantText: 'partial',
      totalTokens: 2,
      latencyMs: 67,
    );
    turn = await store.getTurn('assistant-turn-2');
    expect(turn!['status'], 'cancelled');
    expect(turn['assistant_text'], 'partial');
  });
}
