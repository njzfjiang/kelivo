import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../../utils/app_directories.dart';
import 'analysis_protocol.dart';
import 'analysis_schema.dart';

class AnalysisStore {
  AnalysisStore._();

  static final AnalysisStore instance = AnalysisStore._();

  Database? _db;
  String? _overrideDbPath;
  Future<void> _queue = Future<void>.value();

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

  Future<String> _resolveDbPath() async {
    if (_overrideDbPath != null && _overrideDbPath!.trim().isNotEmpty) {
      return _overrideDbPath!;
    }
    final dir = await AppDirectories.getAppDataDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return p.join(dir.path, 'analysis_v1.db');
  }

  Future<Database> _ensureDb() async {
    if (_db != null) return _db!;
    final path = await _resolveDbPath();
    final file = File(path);
    final dir = file.parent;
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA foreign_keys = ON;');
    createAnalysisSchema(db);
    _db = db;
    return db;
  }

  Future<void> close() {
    return _enqueue(() async {
      try {
        _db?.dispose();
      } finally {
        _db = null;
      }
    });
  }

  @visibleForTesting
  Future<void> useTestDatabasePath(String path) async {
    await close();
    _overrideDbPath = path;
  }

  Future<int> nextTurnSeq(String sessionId) {
    return _enqueue(() async {
      final db = await _ensureDb();
      final rs = db.select(
        'SELECT COALESCE(MAX(seq), 0) AS max_seq FROM turns WHERE session_id = ?',
        [sessionId],
      );
      final value = rs.isEmpty ? 0 : (rs.first['max_seq'] as int? ?? 0);
      return value + 1;
    });
  }

  Future<void> upsertSession({
    required String sessionId,
    required String sourceConversationId,
    required String createdAt,
    required String lastSeen,
    String? assistantId,
    String? notes,
  }) {
    return _enqueue(() async {
      final db = await _ensureDb();
      db.execute(
        '''
INSERT INTO sessions(session_id, source_conversation_id, assistant_id, created_at, last_seen, notes)
VALUES(?, ?, ?, ?, ?, ?)
ON CONFLICT(session_id) DO UPDATE SET
  source_conversation_id = excluded.source_conversation_id,
  assistant_id = excluded.assistant_id,
  last_seen = excluded.last_seen,
  notes = excluded.notes
''',
        [
          sessionId,
          sourceConversationId,
          assistantId,
          createdAt,
          lastSeen,
          notes,
        ],
      );
    });
  }

  Future<void> insertTurn({
    required String turnId,
    required String sessionId,
    required int seq,
    required String ts,
    required String status,
    required String requestJson,
    required String injectSnapshotJson,
    required int stream,
    String? providerKey,
    String? modelId,
    String? requestHeadersJson,
    String? userText,
    String? rollingShortBefore,
    String? rollingShortAfter,
    String? versionGroupId,
    int versionIndex = 0,
  }) {
    return _enqueue(() async {
      final db = await _ensureDb();
      db.execute(
        '''
INSERT OR REPLACE INTO turns(
  turn_id, session_id, seq, ts, provider_key, model_id, stream, status,
  request_headers_json, request_json, user_text, rolling_short_before,
  rolling_short_after, inject_snapshot_json, version_group_id, version_index
)
VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
''',
        [
          turnId,
          sessionId,
          seq,
          ts,
          providerKey,
          modelId,
          stream,
          status,
          requestHeadersJson,
          requestJson,
          userText,
          rollingShortBefore,
          rollingShortAfter,
          injectSnapshotJson,
          versionGroupId,
          versionIndex,
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

  Future<void> updateTurn({
    required String turnId,
    required String status,
    int? httpStatus,
    String? errorText,
    int? latencyMs,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    int? totalTokens,
    String? responseHeadersJson,
    String? responseJson,
    String? assistantText,
    String? reasoningText,
    String? toolCallsJson,
    String? toolResultsJson,
    String? rollingShortAfter,
  }) {
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
          status,
          httpStatus,
          errorText,
          latencyMs,
          promptTokens,
          completionTokens,
          cachedTokens,
          totalTokens,
          responseHeadersJson,
          responseJson,
          assistantText,
          reasoningText,
          toolCallsJson,
          toolResultsJson,
          rollingShortAfter,
          turnId,
        ],
      );
    });
  }

  Future<void> upsertRollingSummary({
    required String sessionId,
    required String assistantId,
    required String summaryText,
    required int sourceLastMessageCount,
    required String now,
  }) {
    return _enqueue(() async {
      final db = await _ensureDb();
      db.execute(
        '''
INSERT INTO rolling_summaries(
  session_id,
  assistant_id,
  created_at,
  updated_at,
  source_last_message_count,
  summary_text
)
VALUES(?, ?, ?, ?, ?, ?)
ON CONFLICT(session_id) DO UPDATE SET
  assistant_id = excluded.assistant_id,
  updated_at = excluded.updated_at,
  source_last_message_count = excluded.source_last_message_count,
  summary_text = excluded.summary_text
''',
        [sessionId, assistantId, now, now, sourceLastMessageCount, summaryText],
      );
    });
  }

  Future<Map<String, dynamic>?> getRollingSummary(String sessionId) {
    return _enqueue(() async {
      final db = await _ensureDb();
      final rs = db.select(
        'SELECT * FROM rolling_summaries WHERE session_id = ?',
        [sessionId],
      );
      if (rs.isEmpty) return null;
      return _rowToMap(rs.first);
    });
  }

  @visibleForTesting
  Future<Map<String, dynamic>?> getTurn(String turnId) {
    return _enqueue(() async {
      final db = await _ensureDb();
      final rs = db.select('SELECT * FROM turns WHERE turn_id = ?', [turnId]);
      if (rs.isEmpty) return null;
      return _rowToMap(rs.first);
    });
  }

  @visibleForTesting
  Future<List<Map<String, dynamic>>> getInjectLog(String turnId) {
    return _enqueue(() async {
      final db = await _ensureDb();
      final rs = db.select(
        'SELECT * FROM inject_log WHERE turn_id = ? ORDER BY id',
        [turnId],
      );
      return rs.map(_rowToMap).toList(growable: false);
    });
  }

  static Map<String, dynamic> _rowToMap(Row row) {
    return Map<String, dynamic>.from(row);
  }
}
