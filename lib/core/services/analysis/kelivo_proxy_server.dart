import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' as typed_data;

import 'analysis_protocol.dart';
import 'proxy_analysis_store.dart';

class KelivoProxyServer {
  KelivoProxyServer({
    required Uri upstreamBaseUri,
    required String dbPath,
    InternetAddress? host,
    this.port = 8787,
  }) : _upstreamBaseUri = upstreamBaseUri,
       host = host ?? InternetAddress.loopbackIPv4,
       _store = ProxyAnalysisStore(dbPath: dbPath);

  final Uri _upstreamBaseUri;
  final ProxyAnalysisStore _store;
  final InternetAddress host;
  final int port;
  final HttpClient _client = HttpClient();
  HttpServer? _server;

  String get dbPath => _store.dbPath;

  Future<HttpServer> start() async {
    final server = await HttpServer.bind(host, port);
    _server = server;
    unawaited(server.forEach(_handleRequest));
    return server;
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _client.close(force: true);
    await _store.close();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.method == 'GET' && request.uri.path == '/healthz') {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.text;
      request.response.write('ok');
      await request.response.close();
      return;
    }

    final startedAt = DateTime.now();
    final requestBodyBytes = await _readRequestBytes(request);
    final incomingHeaders = _flattenHeaders(request.headers);
    final upstreamHeaders = Map<String, String>.from(incomingHeaders)
      ..remove(kelivoAnalysisTurnHeaderName)
      ..remove(kelivoAnalysisConversationHeaderName)
      ..remove(kelivoAnalysisVersionHeaderName)
      ..remove(HttpHeaders.hostHeader)
      ..remove(HttpHeaders.contentLengthHeader)
      ..remove(HttpHeaders.acceptEncodingHeader);

    final parsed = _parseRequestPayload(
      headers: incomingHeaders,
      requestBodyBytes: requestBodyBytes,
    );

    final turnId = parsed.metadata?.turnId;
    stdout.writeln(
      '[KelivoProxy] ${request.method} ${request.uri.path} meta=${parsed.metadata != null ? 'yes' : 'no'}',
    );
    if (parsed.metadata != null) {
      final now = startedAt.toIso8601String();
      stdout.writeln(
        '[KelivoProxy] capture turn_id=${parsed.metadata!.turnId} session_id=${parsed.metadata!.sessionId} seq=${parsed.metadata!.seq} db=$dbPath',
      );
      await _store.upsertSession(
        sessionId: parsed.metadata!.sessionId,
        sourceConversationId: parsed.metadata!.sessionId,
        assistantId: parsed.metadata!.assistantId,
        createdAt: now,
        lastSeen: now,
      );
      await _store.insertTurn(
        ProxyTurnInsert(
          turnId: parsed.metadata!.turnId,
          sessionId: parsed.metadata!.sessionId,
          seq: parsed.metadata!.seq,
          ts: now,
          status: 'pending',
          stream: parsed.metadata!.stream ? 1 : 0,
          providerKey: parsed.metadata!.providerKey,
          modelId: parsed.metadata!.modelId,
          assistantId: parsed.metadata!.assistantId,
          requestHeadersJson: encodeAnalysisJson(
            sanitizeAnalysisHeaders(incomingHeaders),
          ),
          requestJson: parsed.forwardBodyText,
          userText: _lastUserText(parsed.forwardJson),
          rollingShortBefore: parsed.metadata!.rollingShortBefore,
          rollingShortAfter: parsed.metadata!.rollingShortAfter,
          injectSnapshotJson: encodeAnalysisJson(
            parsed.metadata!.injectSnapshot,
          ),
        ),
      );
      await _store.replaceInjectLog(turnId!, parsed.metadata!.injectLog);
      await _store.insertTurnEvent(
        turnId: turnId,
        ts: now,
        kind: 'proxy_received',
        payload: {'path': request.uri.path, 'method': request.method},
      );
    }

    try {
      final upstreamUri = _resolveUpstreamUri(request.uri);
      stdout.writeln('[KelivoProxy] upstream ${request.method} $upstreamUri');
      final upstreamRequest = await _client.openUrl(
        request.method,
        upstreamUri,
      );
      upstreamHeaders.forEach(upstreamRequest.headers.set);
      if (parsed.forwardBodyBytes.isNotEmpty) {
        upstreamRequest.add(parsed.forwardBodyBytes);
      }
      final upstreamResponse = await upstreamRequest.close();
      final responseHeaders = _flattenHeaders(upstreamResponse.headers);
      request.response.statusCode = upstreamResponse.statusCode;
      _copyResponseHeaders(upstreamResponse.headers, request.response.headers);

      if (_isStreamingResponse(upstreamResponse.headers)) {
        await _proxyStreamingResponse(
          request: request,
          upstreamResponse: upstreamResponse,
          turnId: turnId,
          responseHeaders: responseHeaders,
          startedAt: startedAt,
        );
        return;
      }

      final responseBytes = await _readResponseBytes(upstreamResponse);
      request.response.add(responseBytes);
      await request.response.close();

      if (turnId != null) {
        final bodyText = utf8.decode(responseBytes, allowMalformed: true);
        final parsedResponse = _parseCompletedResponse(bodyText);
        final now = DateTime.now().toIso8601String();
        final isError = upstreamResponse.statusCode >= 400;
        await _store.updateTurn(
          ProxyTurnUpdate(
            turnId: turnId,
            status: isError ? 'error' : 'completed',
            httpStatus: upstreamResponse.statusCode,
            errorText: isError ? bodyText : null,
            latencyMs: DateTime.now().difference(startedAt).inMilliseconds,
            promptTokens: parsedResponse.promptTokens,
            completionTokens: parsedResponse.completionTokens,
            cachedTokens: parsedResponse.cachedTokens,
            totalTokens: parsedResponse.totalTokens,
            responseHeadersJson: encodeAnalysisJson(
              sanitizeAnalysisHeaders(responseHeaders),
            ),
            responseJson: bodyText,
            assistantText: parsedResponse.assistantText,
            reasoningText: parsedResponse.reasoningText,
            toolCallsJson: encodeAnalysisJson(parsedResponse.toolCalls),
            toolResultsJson: encodeAnalysisJson(parsedResponse.toolResults),
          ),
        );
        await _store.insertTurnEvent(
          turnId: turnId,
          ts: now,
          kind: isError ? 'error' : 'completed',
          payload: {'http_status': upstreamResponse.statusCode},
        );
        stdout.writeln(
          '[KelivoProxy] turn_id=$turnId status=${isError ? 'error' : 'completed'} http=${upstreamResponse.statusCode}',
        );
      }
    } catch (e) {
      if (turnId != null) {
        final isCancelled =
            e is HttpException &&
            e.message.toLowerCase().contains('connection closed');
        await _store.updateTurn(
          ProxyTurnUpdate(
            turnId: turnId,
            status: isCancelled ? 'cancelled' : 'error',
            errorText: e.toString(),
            latencyMs: DateTime.now().difference(startedAt).inMilliseconds,
          ),
        );
        await _store.insertTurnEvent(
          turnId: turnId,
          ts: DateTime.now().toIso8601String(),
          kind: isCancelled ? 'cancelled' : 'error',
          payload: {'message': e.toString()},
        );
        stdout.writeln(
          '[KelivoProxy] turn_id=$turnId status=${isCancelled ? 'cancelled' : 'error'} error=$e',
        );
      }
      rethrow;
    }
  }

  Future<void> _proxyStreamingResponse({
    required HttpRequest request,
    required HttpClientResponse upstreamResponse,
    required String? turnId,
    required Map<String, String> responseHeaders,
    required DateTime startedAt,
  }) async {
    final rawBuffer = typed_data.BytesBuilder(copy: false);
    final parser = _SseAccumulator();
    try {
      await for (final chunk in upstreamResponse) {
        rawBuffer.add(chunk);
        parser.addChunk(chunk);
        request.response.add(chunk);
      }
      await request.response.close();
      if (turnId != null) {
        await _store.updateTurn(
          ProxyTurnUpdate(
            turnId: turnId,
            status: upstreamResponse.statusCode >= 400 ? 'error' : 'completed',
            httpStatus: upstreamResponse.statusCode,
            latencyMs: DateTime.now().difference(startedAt).inMilliseconds,
            promptTokens: parser.promptTokens,
            completionTokens: parser.completionTokens,
            cachedTokens: parser.cachedTokens,
            totalTokens: parser.totalTokens,
            responseHeadersJson: encodeAnalysisJson(
              sanitizeAnalysisHeaders(responseHeaders),
            ),
            responseJson: utf8.decode(
              rawBuffer.takeBytes(),
              allowMalformed: true,
            ),
            assistantText: parser.assistantText,
            reasoningText: parser.reasoningText,
            toolCallsJson: encodeAnalysisJson(parser.toolCalls),
          ),
        );
        await _store.insertTurnEvent(
          turnId: turnId,
          ts: DateTime.now().toIso8601String(),
          kind: 'completed',
          payload: {'http_status': upstreamResponse.statusCode, 'stream': true},
        );
        stdout.writeln(
          '[KelivoProxy] turn_id=$turnId status=completed http=${upstreamResponse.statusCode} stream=true',
        );
      }
    } catch (e) {
      if (turnId != null) {
        final isCancelled =
            e is HttpException || e is SocketException || e is StateError;
        await _store.updateTurn(
          ProxyTurnUpdate(
            turnId: turnId,
            status: isCancelled ? 'cancelled' : 'error',
            httpStatus: upstreamResponse.statusCode,
            errorText: e.toString(),
            latencyMs: DateTime.now().difference(startedAt).inMilliseconds,
            responseHeadersJson: encodeAnalysisJson(
              sanitizeAnalysisHeaders(responseHeaders),
            ),
            responseJson: utf8.decode(
              rawBuffer.takeBytes(),
              allowMalformed: true,
            ),
            assistantText: parser.assistantText,
            reasoningText: parser.reasoningText,
            toolCallsJson: encodeAnalysisJson(parser.toolCalls),
          ),
        );
        await _store.insertTurnEvent(
          turnId: turnId,
          ts: DateTime.now().toIso8601String(),
          kind: isCancelled ? 'cancelled' : 'error',
          payload: {'message': e.toString(), 'stream': true},
        );
        stdout.writeln(
          '[KelivoProxy] turn_id=$turnId status=${isCancelled ? 'cancelled' : 'error'} stream=true error=$e',
        );
      }
      rethrow;
    }
  }

  Uri _resolveUpstreamUri(Uri incoming) {
    final basePath = _upstreamBaseUri.path.endsWith('/')
        ? _upstreamBaseUri.path.substring(0, _upstreamBaseUri.path.length - 1)
        : _upstreamBaseUri.path;
    final incomingPath = incoming.path.startsWith('/')
        ? incoming.path
        : '/${incoming.path}';
    return _upstreamBaseUri.replace(
      path: '$basePath$incomingPath',
      query: incoming.hasQuery ? incoming.query : null,
    );
  }

  static Future<List<int>> _readRequestBytes(HttpRequest request) async {
    final builder = typed_data.BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static Future<List<int>> _readResponseBytes(
    HttpClientResponse response,
  ) async {
    final builder = typed_data.BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static Map<String, String> _flattenHeaders(HttpHeaders headers) {
    final result = <String, String>{};
    headers.forEach((name, values) {
      if (values.isNotEmpty) {
        result[name] = values.join(', ');
      }
    });
    return result;
  }

  static void _copyResponseHeaders(HttpHeaders from, HttpHeaders to) {
    from.forEach((name, values) {
      final lower = name.toLowerCase();
      if (lower == HttpHeaders.transferEncodingHeader ||
          lower == HttpHeaders.contentLengthHeader ||
          lower == HttpHeaders.contentEncodingHeader) {
        return;
      }
      for (final value in values) {
        to.add(name, value);
      }
    });
  }

  static bool _isStreamingResponse(HttpHeaders headers) {
    final contentType = headers.contentType;
    if (contentType == null) return false;
    return contentType.mimeType == 'text/event-stream';
  }

  static String? _lastUserText(Map<String, dynamic>? body) {
    final messages = body?['messages'];
    if (messages is! List) return null;
    for (int i = messages.length - 1; i >= 0; i--) {
      final message = messages[i];
      if (message is! Map) continue;
      if ((message['role'] ?? '').toString() != 'user') continue;
      final content = message['content'];
      if (content is String) return content;
      return jsonEncode(content);
    }
    return null;
  }

  static _ParsedProxyRequest _parseRequestPayload({
    required Map<String, String> headers,
    required List<int> requestBodyBytes,
  }) {
    if (requestBodyBytes.isEmpty) {
      return _ParsedProxyRequest(
        forwardBodyBytes: const <int>[],
        forwardBodyText: '',
        forwardJson: null,
        metadata: _ProxyMetadata.fromHeadersAndBody(headers, null),
      );
    }

    final bodyText = utf8.decode(requestBodyBytes, allowMalformed: true);
    final decoded = jsonDecode(bodyText);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Proxy request body must be a JSON object.');
    }

    final metadata = _ProxyMetadata.fromHeadersAndBody(headers, decoded);
    final forwardJson = Map<String, dynamic>.from(decoded)
      ..remove(kelivoAnalysisMetaBodyKey);
    final forwardBodyText = jsonEncode(forwardJson);
    return _ParsedProxyRequest(
      forwardBodyBytes: utf8.encode(forwardBodyText),
      forwardBodyText: forwardBodyText,
      forwardJson: forwardJson,
      metadata: metadata,
    );
  }

  static _CompletedResponse _parseCompletedResponse(String bodyText) {
    try {
      final decoded = jsonDecode(bodyText);
      if (decoded is! Map<String, dynamic>) {
        return const _CompletedResponse();
      }
      final usage = decoded['usage'];
      int? promptTokens;
      int? completionTokens;
      int? cachedTokens;
      int? totalTokens;
      if (usage is Map) {
        promptTokens = _asInt(usage['prompt_tokens']);
        completionTokens = _asInt(usage['completion_tokens']);
        cachedTokens = _asInt(usage['cached_tokens']);
        totalTokens = _asInt(usage['total_tokens']);
      }
      String? assistantText;
      String? reasoningText;
      final choices = decoded['choices'];
      if (choices is List && choices.isNotEmpty && choices.first is Map) {
        final first = Map<String, dynamic>.from(choices.first as Map);
        final message = first['message'];
        if (message is Map) {
          assistantText = message['content']?.toString();
          reasoningText = message['reasoning']?.toString();
        }
      }
      if (assistantText == null && decoded['output_text'] is String) {
        assistantText = decoded['output_text'] as String;
      }
      return _CompletedResponse(
        assistantText: assistantText,
        reasoningText: reasoningText,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        cachedTokens: cachedTokens,
        totalTokens: totalTokens,
      );
    } catch (_) {
      return const _CompletedResponse();
    }
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

class _ParsedProxyRequest {
  const _ParsedProxyRequest({
    required this.forwardBodyBytes,
    required this.forwardBodyText,
    required this.forwardJson,
    required this.metadata,
  });

  final List<int> forwardBodyBytes;
  final String forwardBodyText;
  final Map<String, dynamic>? forwardJson;
  final _ProxyMetadata? metadata;
}

class _ProxyMetadata {
  const _ProxyMetadata({
    required this.turnId,
    required this.sessionId,
    required this.seq,
    required this.stream,
    required this.injectSnapshot,
    required this.injectLog,
    this.assistantId,
    this.providerKey,
    this.modelId,
    this.rollingShortBefore,
    this.rollingShortAfter,
  });

  final String turnId;
  final String sessionId;
  final int seq;
  final bool stream;
  final String? assistantId;
  final String? providerKey;
  final String? modelId;
  final String? rollingShortBefore;
  final String? rollingShortAfter;
  final Map<String, dynamic>? injectSnapshot;
  final List<Map<String, dynamic>> injectLog;

  static _ProxyMetadata? fromHeadersAndBody(
    Map<String, String> headers,
    Map<String, dynamic>? body,
  ) {
    final meta = body?[kelivoAnalysisMetaBodyKey];
    if (meta is! Map) return null;
    final map = Map<String, dynamic>.from(meta);
    final turnId =
        headers[kelivoAnalysisTurnHeaderName] ??
        map['turn_id']?.toString() ??
        '';
    final sessionId =
        headers[kelivoAnalysisConversationHeaderName] ??
        map['session_id']?.toString() ??
        '';
    if (turnId.isEmpty || sessionId.isEmpty) {
      throw const FormatException(
        'Kelivo analysis metadata requires turn_id and session_id.',
      );
    }
    final injectLogRaw = map['inject_log'];
    final injectLog = <Map<String, dynamic>>[];
    if (injectLogRaw is List) {
      for (final entry in injectLogRaw) {
        if (entry is Map) {
          injectLog.add(Map<String, dynamic>.from(entry));
        }
      }
    }
    return _ProxyMetadata(
      turnId: turnId,
      sessionId: sessionId,
      seq: KelivoProxyServer._asInt(map['seq']) ?? 0,
      stream: map['stream'] == true || map['stream'] == 1,
      assistantId: map['assistant_id']?.toString(),
      providerKey: map['provider_key']?.toString(),
      modelId: map['model_id']?.toString(),
      rollingShortBefore: map['rolling_short_before']?.toString(),
      rollingShortAfter: map['rolling_short_after']?.toString(),
      injectSnapshot: map['inject_snapshot'] is Map
          ? Map<String, dynamic>.from(map['inject_snapshot'] as Map)
          : null,
      injectLog: injectLog,
    );
  }
}

class _CompletedResponse {
  const _CompletedResponse({
    this.assistantText,
    this.reasoningText,
    this.promptTokens,
    this.completionTokens,
    this.cachedTokens,
    this.totalTokens,
  });

  final String? assistantText;
  final String? reasoningText;
  final int? promptTokens;
  final int? completionTokens;
  final int? cachedTokens;
  final int? totalTokens;
  final Object? toolCalls = null;
  final Object? toolResults = null;
}

class _SseAccumulator {
  final StringBuffer _lineBuffer = StringBuffer();
  final StringBuffer _assistant = StringBuffer();
  final StringBuffer _reasoning = StringBuffer();
  final List<Map<String, dynamic>> _toolCalls = <Map<String, dynamic>>[];

  int? promptTokens;
  int? completionTokens;
  int? cachedTokens;
  int? totalTokens;

  String get assistantText => _assistant.toString();
  String? get reasoningText =>
      _reasoning.isEmpty ? null : _reasoning.toString();
  List<Map<String, dynamic>> get toolCalls => List.unmodifiable(_toolCalls);

  void addChunk(List<int> chunk) {
    final text = utf8.decode(chunk, allowMalformed: true);
    _lineBuffer.write(text);
    var current = _lineBuffer.toString();
    while (true) {
      final idx = current.indexOf('\n');
      if (idx < 0) break;
      final line = current.substring(0, idx).trimRight();
      current = current.substring(idx + 1);
      _consumeLine(line);
    }
    _lineBuffer
      ..clear()
      ..write(current);
  }

  void _consumeLine(String line) {
    if (!line.startsWith('data:')) return;
    final payload = line.substring(5).trimLeft();
    if (payload.isEmpty || payload == '[DONE]') return;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) return;
      final choices = decoded['choices'];
      if (choices is List && choices.isNotEmpty && choices.first is Map) {
        final first = Map<String, dynamic>.from(choices.first as Map);
        final delta = first['delta'];
        if (delta is Map) {
          final content = delta['content'];
          if (content is String) _assistant.write(content);
          final reasoning = delta['reasoning'] ?? delta['reasoning_content'];
          if (reasoning is String) _reasoning.write(reasoning);
          final toolCalls = delta['tool_calls'];
          if (toolCalls is List) {
            for (final toolCall in toolCalls) {
              if (toolCall is Map) {
                _toolCalls.add(Map<String, dynamic>.from(toolCall));
              }
            }
          }
        }
        final message = first['message'];
        if (message is Map && message['content'] is String) {
          _assistant.write(message['content'] as String);
        }
      }
      final usage = decoded['usage'];
      if (usage is Map) {
        promptTokens = KelivoProxyServer._asInt(usage['prompt_tokens']);
        completionTokens = KelivoProxyServer._asInt(usage['completion_tokens']);
        cachedTokens = KelivoProxyServer._asInt(usage['cached_tokens']);
        totalTokens = KelivoProxyServer._asInt(usage['total_tokens']);
      }
    } catch (_) {}
  }
}
