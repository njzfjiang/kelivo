import 'dart:async';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'analysis_protocol.dart';
import 'analysis_schema.dart';

class ProxyTurnInsert {
  const ProxyTurnInsert({
    required this.turnId,
    required this.sessionId,
    required this.seq,
    required this.ts,
    required this.status,
    required this.stream,
    required this.requestJson,
    this.providerKey,
    this.modelId,
    this.assistantId,
    this.requestHeadersJson,
    this.userText,
    this.rollingShortBefore,
    this.rollingShortAfter,
    this.injectSnapshotJson,
  });

  final String turnId;
  final String sessionId;
  final int seq;
  final String ts;
  final String status;
  final int stream;
  final String requestJson;
  final String? providerKey;
  final String? modelId;
  final String? assistantId;
  final String? requestHeadersJson;
  final String? userText;
  final String? rollingShortBefore;
  final String? rollingShortAfter;
  final String? injectSnapshotJson;
}

class ProxyTurnUpdate {
  const ProxyTurnUpdate({
    required this.turnId,
    required this.status,
    this.httpStatus,
    this.errorText,
    this.latencyMs,
    this.promptTokens,
    this.completionTokens,
    this.cachedTokens,
    this.totalTokens,
    this.responseHeadersJson,
    this.responseJson,
    this.assistantText,
    this.reasoningText,
    this.toolCallsJson,
    this.toolResultsJson,
    this.rollingShortAfter,
  });

  final String turnId;
  final String status;
  final int? httpStatus;
  final String? errorText;
  final int? latencyMs;
  final int? promptTokens;
  final int? completionTokens;
  final int? cachedTokens;
  final int? totalTokens;
  final String? responseHeadersJson;
  final String? responseJson;
  final String? assistantText;
  final String? reasoningText;
  final String? toolCallsJson;
  final String? toolResultsJson;
  final String? rollingShortAfter;
}

class ProxyAnalysisStore {
  ProxyAnalysisStore({required String dbPath}) : _dbPath = dbPath;

  final String _dbPath;
  Database? _db;
  Future<void> _queue = Future<void>.value();

  String get dbPath => _dbPath;

  Future<T> _enqueue<T>(FutureOr<T> Function() action) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<Database> _ensureDb() async {
    if (_db != null) return _db!;
    final file = File(_dbPath);
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }
    final db = sqlite3.open(_dbPath);
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA foreign_keys = ON;');
    createAnalysisSchema(db);
    _db = db;
    return db;
  }

  Future<void> close() async {
    await _enqueue(() async {
      _db?.dispose();
      _db = null;
    });
  }

  Future<void> upsertSession({
    required String sessionId,
    required String sourceConversationId,
    required String createdAt,
    required String lastSeen,
    String? assistantId,
  }) {
    return _enqueue(() async {
      final db = await _ensureDb();
      db.execute(
        '''
INSERT INTO sessions(session_id, source_conversation_id, assistant_id, created_at, last_seen)
VALUES(?, ?, ?, ?, ?)
ON CONFLICT(session_id) DO UPDATE SET
  source_conversation_id = excluded.source_conversation_id,
  assistant_id = COALESCE(excluded.assistant_id, sessions.assistant_id),
  last_seen = excluded.last_seen
''',
        [sessionId, sourceConversationId, assistantId, createdAt, lastSeen],
      );
    });
  }

  Future<void> insertTurn(ProxyTurnInsert turn) {
    return _enqueue(() async {
      final db = await _ensureDb();
      db.execute(
        '''
INSERT OR REPLACE INTO turns(
  turn_id, session_id, seq, ts, provider_key, model_id, stream, status,
  request_headers_json, request_json, user_text, rolling_short_before,
  rolling_short_after, inject_snapshot_json
)
VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
''',
        [
          turn.turnId,
          turn.sessionId,
          turn.seq,
          turn.ts,
          turn.providerKey,
          turn.modelId,
          turn.stream,
          turn.status,
          turn.requestHeadersJson,
          turn.requestJson,
          turn.userText,
          turn.rollingShortBefore,
          turn.rollingShortAfter,
          turn.injectSnapshotJson,
        ],
      );
    });
  }

  Future<void> replaceInjectLog(
    String turnId,
    List<Map<String, dynamic>> entries,
  ) {
    return _enqueue(() async {
      final db = await _ensureDb();
      db.execute('DELETE FROM inject_log WHERE turn_id = ?', [turnId]);
      for (final entry in entries) {
        db.execute(
          '''
INSERT INTO inject_log(
  turn_id, kind, source_id, title, score, reason, content_excerpt, position, payload_json
)
VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
''',
          [
            turnId,
            entry['kind'],
            entry['source_id'],
            entry['title'],
            entry['score'],
            entry['reason'],
            entry['content_excerpt'],
            entry['position'],
            encodeAnalysisJson(entry['payload_json']),
          ],
        );
      }
    });
  }

  Future<void> insertTurnEvent({
    required String turnId,
    required String ts,
    required String kind,
    Object? payload,
  }) {
    return _enqueue(() async {
      final db = await _ensureDb();
      db.execute(
        'INSERT INTO turn_events(turn_id, ts, kind, payload_json) VALUES(?, ?, ?, ?)',
        [turnId, ts, kind, encodeAnalysisJson(payload)],
      );
    });
  }

  Future<void> updateTurn(ProxyTurnUpdate update) {
    return _enqueue(() async {
      final db = await _ensureDb();
      db.execute(
        '''
UPDATE turns SET
  status = ?,
  http_status = COALESCE(?, http_status),
  error_text = COALESCE(?, error_text),
  latency_ms = COALESCE(?, latency_ms),
  prompt_tokens = COALESCE(?, prompt_tokens),
  completion_tokens = COALESCE(?, completion_tokens),
  cached_tokens = COALESCE(?, cached_tokens),
  total_tokens = COALESCE(?, total_tokens),
  response_headers_json = COALESCE(?, response_headers_json),
  response_json = COALESCE(?, response_json),
  assistant_text = COALESCE(?, assistant_text),
  reasoning_text = COALESCE(?, reasoning_text),
  tool_calls_json = COALESCE(?, tool_calls_json),
  tool_results_json = COALESCE(?, tool_results_json),
  rolling_short_after = COALESCE(?, rolling_short_after)
WHERE turn_id = ?
''',
        [
          update.status,
          update.httpStatus,
          update.errorText,
          update.latencyMs,
          update.promptTokens,
          update.completionTokens,
          update.cachedTokens,
          update.totalTokens,
          update.responseHeadersJson,
          update.responseJson,
          update.assistantText,
          update.reasoningText,
          update.toolCallsJson,
          update.toolResultsJson,
          update.rollingShortAfter,
          update.turnId,
        ],
      );
    });
  }

  Future<Map<String, dynamic>?> getTurn(String turnId) async {
    return _enqueue(() async {
      final db = await _ensureDb();
      final rows = db.select('SELECT * FROM turns WHERE turn_id = ?', [turnId]);
      if (rows.isEmpty) return null;
      return Map<String, dynamic>.from(rows.first);
    });
  }

  Future<List<Map<String, dynamic>>> getInjectLog(String turnId) async {
    return _enqueue(() async {
      final db = await _ensureDb();
      final rows = db.select(
        'SELECT * FROM inject_log WHERE turn_id = ? ORDER BY id',
        [turnId],
      );
      return rows
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
    });
  }
}
