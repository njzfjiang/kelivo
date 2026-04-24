import 'dart:convert';
import '../../models/chat_message.dart';
import '../../models/token_usage.dart';
import '../../providers/settings_provider.dart';
import '../chat/chat_service.dart';
import 'analysis_protocol.dart';
import 'analysis_store.dart';

class AnalysisTurnContext {
  const AnalysisTurnContext({
    required this.turnId,
    required this.sessionId,
    required this.seq,
    required this.extraHeaders,
    required this.extraBody,
  });

  final String turnId;
  final String sessionId;
  final int seq;
  final Map<String, String> extraHeaders;
  final Map<String, dynamic>? extraBody;
}

class AnalysisCaptureService {
  AnalysisCaptureService({AnalysisStore? store})
    : _store = store ?? AnalysisStore.instance;

  final AnalysisStore _store;

  Future<AnalysisTurnContext> prepareTurn({
    required ChatMessage assistantMessage,
    required String? assistantId,
    required String providerKey,
    required String modelId,
    required bool stream,
    required List<Map<String, dynamic>> apiMessages,
    required List<Map<String, dynamic>> toolDefs,
    required Map<String, dynamic> injectSnapshot,
    required List<Map<String, dynamic>> injectLog,
    required String? rollingShortBefore,
    required String? rollingShortAfter,
    required Map<String, String>? requestHeaders,
    required Map<String, dynamic>? existingBody,
  }) async {
    final now = DateTime.now().toIso8601String();
    final sessionId = assistantMessage.conversationId;
    final turnId = assistantMessage.id;
    final seq = await _store.nextTurnSeq(sessionId);

    final headers = <String, String>{
      kelivoAnalysisTurnHeaderName: turnId,
      kelivoAnalysisConversationHeaderName: sessionId,
      kelivoAnalysisVersionHeaderName: '$kelivoAnalysisVersion',
      if (requestHeaders != null) ...requestHeaders,
    };
    final sanitizedHeaders = sanitizeAnalysisHeaders(headers);
    final requestJson = jsonEncode({
      'provider_key': providerKey,
      'model_id': modelId,
      'messages': apiMessages,
      'tools': toolDefs,
      'stream': stream,
      if (existingBody != null && existingBody.isNotEmpty)
        'extra_body': existingBody,
    });

    await _store.upsertSession(
      sessionId: sessionId,
      sourceConversationId: sessionId,
      assistantId: assistantId,
      createdAt: assistantMessage.timestamp.toIso8601String(),
      lastSeen: now,
    );
    await _store.insertTurn(
      turnId: turnId,
      sessionId: sessionId,
      seq: seq,
      ts: now,
      providerKey: providerKey,
      modelId: modelId,
      stream: stream ? 1 : 0,
      status: 'pending',
      requestHeadersJson: sanitizedHeaders == null
          ? null
          : jsonEncode(sanitizedHeaders),
      requestJson: requestJson,
      userText: _lastUserText(apiMessages),
      rollingShortBefore: rollingShortBefore,
      rollingShortAfter: rollingShortAfter,
      injectSnapshotJson: jsonEncode(injectSnapshot),
      versionGroupId: assistantMessage.groupId,
      versionIndex: assistantMessage.version,
    );
    await _store.replaceInjectLog(turnId, injectLog);
    await _store.insertTurnEvent(
      turnId: turnId,
      ts: now,
      kind: 'prepared',
      payload: {'seq': seq, 'session_id': sessionId},
    );

    final metadata = <String, dynamic>{
      'turn_id': turnId,
      'session_id': sessionId,
      'seq': seq,
      'assistant_id': assistantId,
      'provider_key': providerKey,
      'model_id': modelId,
      'stream': stream,
      'rolling_short_before': rollingShortBefore,
      'rolling_short_after': rollingShortAfter,
      'inject_snapshot': injectSnapshot,
      'inject_log': injectLog,
    };
    Map<String, dynamic>? extraBody;
    if (_shouldAttachBodyMetadata(providerKey)) {
      extraBody = <String, dynamic>{
        if (existingBody != null) ...existingBody,
        kelivoAnalysisMetaBodyKey: metadata,
      };
    }
    return AnalysisTurnContext(
      turnId: turnId,
      sessionId: sessionId,
      seq: seq,
      extraHeaders: headers,
      extraBody: extraBody,
    );
  }

  Future<void> markRequestSent(AnalysisTurnContext ctx) async {
    await _store.insertTurnEvent(
      turnId: ctx.turnId,
      ts: DateTime.now().toIso8601String(),
      kind: 'request_sent',
      payload: {'session_id': ctx.sessionId, 'seq': ctx.seq},
    );
  }

  Future<void> markCompleted({
    required String turnId,
    required ChatService chatService,
    required ChatMessage finalMessage,
    required String assistantText,
    required String? reasoningText,
    required TokenUsage? usage,
    required int totalTokens,
    required int? latencyMs,
  }) async {
    final toolEvents = chatService.getToolEvents(finalMessage.id);
    await _store.updateTurn(
      turnId: turnId,
      status: 'completed',
      latencyMs: latencyMs,
      promptTokens: usage?.promptTokens,
      completionTokens: usage?.completionTokens,
      cachedTokens: usage?.cachedTokens,
      totalTokens: totalTokens > 0 ? totalTokens : usage?.totalTokens,
      assistantText: assistantText,
      reasoningText: reasoningText,
      toolCallsJson: toolEvents.isEmpty
          ? null
          : jsonEncode(_toolCallsPayload(toolEvents)),
      toolResultsJson: toolEvents.isEmpty
          ? null
          : jsonEncode(_toolResultsPayload(toolEvents)),
      responseJson: jsonEncode({
        'assistant_text': assistantText,
        'reasoning_text': reasoningText,
        'usage': usage == null
            ? null
            : {
                'prompt_tokens': usage.promptTokens,
                'completion_tokens': usage.completionTokens,
                'cached_tokens': usage.cachedTokens,
                'total_tokens': usage.totalTokens,
              },
        'tool_events': toolEvents,
      }),
      rollingShortAfter: chatService
          .getConversation(finalMessage.conversationId)
          ?.summary,
    );
    await _store.insertTurnEvent(
      turnId: turnId,
      ts: DateTime.now().toIso8601String(),
      kind: 'completed',
      payload: {'latency_ms': latencyMs, 'total_tokens': totalTokens},
    );
  }

  Future<void> markError({
    required String turnId,
    required String errorText,
    required String displayContent,
    required int totalTokens,
    required int? latencyMs,
  }) async {
    await _store.updateTurn(
      turnId: turnId,
      status: 'error',
      errorText: errorText,
      latencyMs: latencyMs,
      totalTokens: totalTokens > 0 ? totalTokens : null,
      assistantText: displayContent,
      responseJson: jsonEncode({
        'error': errorText,
        'assistant_text': displayContent,
      }),
    );
    await _store.insertTurnEvent(
      turnId: turnId,
      ts: DateTime.now().toIso8601String(),
      kind: 'error',
      payload: {'message': errorText},
    );
  }

  Future<void> markCancelled({
    required String turnId,
    required String? assistantText,
    required int? totalTokens,
    required int? latencyMs,
  }) async {
    await _store.updateTurn(
      turnId: turnId,
      status: 'cancelled',
      latencyMs: latencyMs,
      totalTokens: totalTokens,
      assistantText: assistantText,
      responseJson: jsonEncode({
        'assistant_text': assistantText,
        'cancelled': true,
      }),
    );
    await _store.insertTurnEvent(
      turnId: turnId,
      ts: DateTime.now().toIso8601String(),
      kind: 'cancelled',
      payload: {'latency_ms': latencyMs},
    );
  }

  static Map<String, String>? sanitizeHeaders(Map<String, String>? headers) {
    return sanitizeAnalysisHeaders(headers);
  }

  static String excerpt(String value, {int maxLength = 240}) {
    final normalized = value.trim();
    if (normalized.length <= maxLength) return normalized;
    return '${normalized.substring(0, maxLength)}...';
  }

  static bool _shouldAttachBodyMetadata(String providerKey) {
    final kind = ProviderConfig.classify(providerKey);
    return kind == ProviderKind.openai;
  }

  static String? _lastUserText(List<Map<String, dynamic>> apiMessages) {
    for (int i = apiMessages.length - 1; i >= 0; i--) {
      if ((apiMessages[i]['role'] ?? '').toString() == 'user') {
        return (apiMessages[i]['content'] ?? '').toString();
      }
    }
    return null;
  }

  static List<Map<String, dynamic>> _toolCallsPayload(
    List<Map<String, dynamic>> events,
  ) {
    return events
        .map(
          (event) => <String, dynamic>{
            'id': event['id'],
            'name': event['name'],
            'arguments': event['arguments'],
          },
        )
        .toList(growable: false);
  }

  static List<Map<String, dynamic>> _toolResultsPayload(
    List<Map<String, dynamic>> events,
  ) {
    return events
        .where((event) => event['content'] != null)
        .map(
          (event) => <String, dynamic>{
            'id': event['id'],
            'name': event['name'],
            'content': event['content'],
          },
        )
        .toList(growable: false);
  }
}
