import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main(List<String> args) {
  final options = _parseArgs(args);
  final help = options.containsKey('help') || options.containsKey('h');
  if (help) {
    _printUsage();
    return;
  }

  final dbPath = _resolveDbPath(options);
  final file = File(dbPath);
  if (!file.existsSync()) {
    stderr.writeln('Database not found: $dbPath');
    exitCode = 2;
    return;
  }

  final db = sqlite3.open(dbPath);
  try {
    final turnId = options['turn-id'];
    final sessionId = options['session-id'];
    final recent = int.tryParse(options['recent'] ?? '10') ?? 10;
    final showStats =
        options.containsKey('stats') || options['mode']?.trim() == 'stats';
    final showRolling = options.containsKey('rolling');
    final showSummaryVersions = options.containsKey('summary-versions');
    final showMemorySuggestions = options.containsKey('memory-suggestions');

    if (turnId != null && turnId.trim().isNotEmpty) {
      _printTurnDetails(
        db,
        turnId.trim(),
        excerptLength: int.tryParse(options['excerpt'] ?? '220') ?? 220,
      );
      return;
    }

    if (showStats) {
      _printStats(
        db,
        recent: recent,
        sessionId: sessionId?.trim().isEmpty == true ? null : sessionId?.trim(),
      );
      return;
    }

    if (showRolling) {
      final normalizedSessionId = sessionId?.trim();
      if (normalizedSessionId == null || normalizedSessionId.isEmpty) {
        stderr.writeln('--rolling requires --session-id=<session_id>');
        exitCode = 2;
        return;
      }
      _printRollingSummary(
        db,
        normalizedSessionId,
        excerptLength: int.tryParse(options['excerpt'] ?? '400') ?? 400,
      );
      return;
    }

    if (showSummaryVersions) {
      _printSummaryVersions(
        db,
        recent: recent,
        sessionId: sessionId?.trim().isEmpty == true ? null : sessionId?.trim(),
        excerptLength: int.tryParse(options['excerpt'] ?? '220') ?? 220,
      );
      return;
    }

    if (showMemorySuggestions) {
      _printMemorySuggestions(
        db,
        recent: recent,
        sessionId: sessionId?.trim().isEmpty == true ? null : sessionId?.trim(),
        excerptLength: int.tryParse(options['excerpt'] ?? '220') ?? 220,
      );
      return;
    }

    _printRecentTurns(
      db,
      recent: recent,
      sessionId: sessionId?.trim().isEmpty == true ? null : sessionId?.trim(),
      excerptLength: int.tryParse(options['excerpt'] ?? '90') ?? 90,
    );
  } finally {
    db.dispose();
  }
}

void _printUsage() {
  stdout.writeln('Kelivo Analysis Inspect');
  stdout.writeln('');
  stdout.writeln('Usage:');
  stdout.writeln(
    '  dart run bin/analysis_inspect.dart --db-path=proxy_analysis_v1.db --recent=10',
  );
  stdout.writeln(
    '  dart run bin/analysis_inspect.dart --db-path=proxy_analysis_v1.db --turn-id=<turn_id>',
  );
  stdout.writeln(
    '  dart run bin/analysis_inspect.dart --db-path=proxy_analysis_v1.db --session-id=<session_id> --recent=20',
  );
  stdout.writeln(
    '  dart run bin/analysis_inspect.dart --db-path=proxy_analysis_v1.db --stats --recent=100',
  );
  stdout.writeln(
    '  dart run bin/analysis_inspect.dart --db-path=proxy_analysis_v1.db --rolling --session-id=<session_id>',
  );
  stdout.writeln(
    '  dart run bin/analysis_inspect.dart --app-db --rolling --session-id=<session_id>',
  );
  stdout.writeln(
    '  dart run bin/analysis_inspect.dart --app-db --summary-versions --session-id=<session_id>',
  );
  stdout.writeln(
    '  dart run bin/analysis_inspect.dart --app-db --memory-suggestions --session-id=<session_id>',
  );
  stdout.writeln('');
  stdout.writeln('Options:');
  stdout.writeln('  --db-path=PATH      SQLite file path');
  stdout.writeln(
    '  --app-db           Use app analysis DB (%APPDATA%/com.psyche/kelivo/analysis_v1.db on Windows)',
  );
  stdout.writeln('  --recent=N          Show latest N turns, default 10');
  stdout.writeln('  --turn-id=ID        Show one turn in detail');
  stdout.writeln('  --session-id=ID     Filter recent turns by session');
  stdout.writeln(
    '  --stats             Show aggregate stats for latest N turns',
  );
  stdout.writeln('  --mode=stats        Same as --stats');
  stdout.writeln(
    '  --rolling           Show latest rolling summary for one session',
  );
  stdout.writeln('  --summary-versions  Show rolling summary version history');
  stdout.writeln('  --memory-suggestions Show memory suggestion rows');
  stdout.writeln('  --excerpt=N         Excerpt length, default 90/220');
  stdout.writeln('  --help              Show this message');
}

String _resolveDbPath(Map<String, String> options) {
  if (options.containsKey('app-db')) {
    return _defaultAppDbPath();
  }
  return options['db-path'] ??
      options['db'] ??
      options['path'] ??
      'proxy_analysis_v1.db';
}

String _defaultAppDbPath() {
  final appData = Platform.environment['APPDATA'];
  if (appData == null || appData.trim().isEmpty) {
    return 'analysis_v1.db';
  }
  return p.join(appData, 'com.psyche', 'kelivo', 'analysis_v1.db');
}

void _printRollingSummary(
  Database db,
  String sessionId, {
  required int excerptLength,
}) {
  if (!_tableExists(db, 'rolling_summaries')) {
    stdout.writeln('Table not found: rolling_summaries');
    stdout.writeln(
      'This database file does not contain rolling summary data yet.',
    );
    stdout.writeln(
      'Check that --db-path points to the app analysis DB that has been migrated, not an older proxy-only DB file.',
    );
    return;
  }

  final rows = db.select(
    '''
SELECT session_id, assistant_id, created_at, updated_at, source_last_message_count, summary_text
FROM rolling_summaries
WHERE session_id = ?
''',
    [sessionId],
  );
  if (rows.isEmpty) {
    stdout.writeln('No rolling summary found for session: $sessionId');
    return;
  }

  final row = rows.first;
  stdout.writeln('Rolling summary');
  stdout.writeln('');
  stdout.writeln(_formatKeyValueLine('session_id', row['session_id']));
  stdout.writeln(_formatKeyValueLine('assistant_id', row['assistant_id']));
  stdout.writeln(_formatKeyValueLine('created_at', row['created_at']));
  stdout.writeln(_formatKeyValueLine('updated_at', row['updated_at']));
  stdout.writeln(
    _formatKeyValueLine(
      'source_last_message_count',
      row['source_last_message_count'],
    ),
  );
  stdout.writeln('');
  stdout.writeln('Summary');
  stdout.writeln(
    _block(_excerpt((row['summary_text'] ?? '').toString(), excerptLength)),
  );
}

void _printSummaryVersions(
  Database db, {
  required int recent,
  required String? sessionId,
  required int excerptLength,
}) {
  if (!_tableExists(db, 'summary_versions')) {
    stdout.writeln('Table not found: summary_versions');
    return;
  }

  final params = <Object?>[];
  final whereClause = sessionId == null ? '' : 'WHERE session_id = ?';
  if (sessionId != null) params.add(sessionId);
  params.add(recent);

  final rows = db.select('''
SELECT id, session_id, assistant_id, created_at, source_from_message_count,
  source_to_message_count, provider_key, model_id, summary_text, input_excerpt
FROM summary_versions
$whereClause
ORDER BY created_at DESC, id DESC
LIMIT ?
''', params);

  if (rows.isEmpty) {
    stdout.writeln(
      sessionId == null
          ? 'No summary versions found.'
          : 'No summary versions found for session: $sessionId',
    );
    return;
  }

  stdout.writeln(
    sessionId == null
        ? 'Summary versions ($recent)'
        : 'Summary versions ($recent) for session $sessionId',
  );
  stdout.writeln('');
  for (final row in rows) {
    stdout.writeln(
      '#${row['id']} ts=${row['created_at']} messages=${row['source_from_message_count']}..${row['source_to_message_count']}',
    );
    stdout.writeln(
      'session_id=${row['session_id']} assistant_id=${row['assistant_id'] ?? '-'} provider=${row['provider_key'] ?? '-'} model=${row['model_id'] ?? '-'}',
    );
    stdout.writeln(
      'summary: ${_excerpt((row['summary_text'] ?? '').toString(), excerptLength)}',
    );
    final inputExcerpt = (row['input_excerpt'] ?? '').toString().trim();
    if (inputExcerpt.isNotEmpty) {
      stdout.writeln('input: ${_excerpt(inputExcerpt, excerptLength)}');
    }
    stdout.writeln('');
  }
}

void _printMemorySuggestions(
  Database db, {
  required int recent,
  required String? sessionId,
  required int excerptLength,
}) {
  if (!_tableExists(db, 'memory_suggestions')) {
    stdout.writeln('Table not found: memory_suggestions');
    return;
  }

  final params = <Object?>[];
  final whereClause = sessionId == null ? '' : 'WHERE session_id = ?';
  if (sessionId != null) params.add(sessionId);
  params.add(recent);

  final rows = db.select('''
SELECT id, session_id, assistant_id, created_at, source_summary_version_id,
  source_turn_id, candidate_text, reason, confidence, status, review_note,
  accepted_memory_id
FROM memory_suggestions
$whereClause
ORDER BY created_at DESC, id DESC
LIMIT ?
''', params);

  if (rows.isEmpty) {
    stdout.writeln(
      sessionId == null
          ? 'No memory suggestions found.'
          : 'No memory suggestions found for session: $sessionId',
    );
    return;
  }

  stdout.writeln(
    sessionId == null
        ? 'Memory suggestions ($recent)'
        : 'Memory suggestions ($recent) for session $sessionId',
  );
  stdout.writeln('');
  for (final row in rows) {
    stdout.writeln(
      '#${row['id']} [${row['status']}] ts=${row['created_at']} confidence=${row['confidence'] ?? '-'}',
    );
    stdout.writeln(
      'session_id=${row['session_id']} assistant_id=${row['assistant_id'] ?? '-'} summary_version=${row['source_summary_version_id'] ?? '-'} turn=${row['source_turn_id'] ?? '-'}',
    );
    stdout.writeln(
      'candidate: ${_excerpt((row['candidate_text'] ?? '').toString(), excerptLength)}',
    );
    final reason = (row['reason'] ?? '').toString().trim();
    if (reason.isNotEmpty) {
      stdout.writeln('reason: ${_excerpt(reason, excerptLength)}');
    }
    final reviewNote = (row['review_note'] ?? '').toString().trim();
    if (reviewNote.isNotEmpty) {
      stdout.writeln('review: ${_excerpt(reviewNote, excerptLength)}');
    }
    if (row['accepted_memory_id'] != null) {
      stdout.writeln('accepted_memory_id=${row['accepted_memory_id']}');
    }
    stdout.writeln('');
  }
}

Map<String, String> _parseArgs(List<String> args) {
  final out = <String, String>{};
  for (final arg in args) {
    if (!arg.startsWith('--')) continue;
    final body = arg.substring(2);
    final index = body.indexOf('=');
    if (index == -1) {
      out[body] = 'true';
      continue;
    }
    out[body.substring(0, index)] = body.substring(index + 1);
  }
  return out;
}

void _printRecentTurns(
  Database db, {
  required int recent,
  required String? sessionId,
  required int excerptLength,
}) {
  final params = <Object?>[];
  final whereClause = sessionId == null ? '' : 'WHERE session_id = ?';
  if (sessionId != null) params.add(sessionId);
  params.add(recent);

  final turns = db.select('''
SELECT
  turn_id,
  session_id,
  seq,
  ts,
  status,
  provider_key,
  model_id,
  latency_ms,
  total_tokens,
  user_text,
  assistant_text
FROM turns
$whereClause
ORDER BY ts DESC
LIMIT ?
''', params);

  if (turns.isEmpty) {
    stdout.writeln(
      sessionId == null
          ? 'No turns found.'
          : 'No turns found for session: $sessionId',
    );
    return;
  }

  stdout.writeln(
    sessionId == null
        ? 'Recent turns ($recent)'
        : 'Recent turns ($recent) for session $sessionId',
  );
  stdout.writeln('');

  final turnIds = turns.map((row) => row['turn_id'] as String).toList();
  final injectCounts = _loadInjectCounts(db, turnIds);
  final statusCounts = <String, int>{};
  final kindTotals = <String, int>{};

  for (final row in turns) {
    final turnId = row['turn_id'] as String;
    final perTurnCounts = injectCounts[turnId] ?? const <String, int>{};
    statusCounts.update(
      (row['status'] ?? 'unknown').toString(),
      (value) => value + 1,
      ifAbsent: () => 1,
    );
    perTurnCounts.forEach((key, value) {
      kindTotals.update(key, (old) => old + value, ifAbsent: () => value);
    });
  }

  stdout.writeln(
    _formatKeyValueLine('Status counts', _formatMap(statusCounts)),
  );
  stdout.writeln(_formatKeyValueLine('Inject totals', _formatMap(kindTotals)));
  stdout.writeln('');

  for (final row in turns) {
    final turnId = row['turn_id'] as String;
    final perTurnCounts = injectCounts[turnId] ?? const <String, int>{};
    stdout.writeln(
      '[${row['status']}] seq=${row['seq']} ts=${row['ts']} tokens=${row['total_tokens'] ?? '-'} latency=${row['latency_ms'] ?? '-'}ms',
    );
    stdout.writeln(
      'turn_id=$turnId session_id=${row['session_id']} provider=${row['provider_key'] ?? '-'} model=${row['model_id'] ?? '-'}',
    );
    stdout.writeln(
      'inject=${perTurnCounts.isEmpty ? '-' : _formatMap(perTurnCounts)}',
    );
    stdout.writeln(
      'user: ${_excerpt((row['user_text'] ?? '').toString(), excerptLength)}',
    );
    stdout.writeln(
      'assistant: ${_excerpt((row['assistant_text'] ?? '').toString(), excerptLength)}',
    );
    stdout.writeln('');
  }
}

void _printTurnDetails(
  Database db,
  String turnId, {
  required int excerptLength,
}) {
  final turns = db.select('SELECT * FROM turns WHERE turn_id = ?', [turnId]);
  if (turns.isEmpty) {
    stdout.writeln('Turn not found: $turnId');
    return;
  }

  final turn = Map<String, Object?>.from(turns.first);
  final injectLog = db.select(
    '''
SELECT kind, source_id, title, score, reason, content_excerpt, position, payload_json
FROM inject_log
WHERE turn_id = ?
ORDER BY position, id
''',
    [turnId],
  );
  final turnEvents = db.select(
    '''
SELECT ts, kind, payload_json
FROM turn_events
WHERE turn_id = ?
ORDER BY ts, event_id
''',
    [turnId],
  );

  stdout.writeln('Turn detail');
  stdout.writeln('');
  stdout.writeln(_formatKeyValueLine('turn_id', turnId));
  stdout.writeln(_formatKeyValueLine('session_id', turn['session_id']));
  stdout.writeln(_formatKeyValueLine('seq', turn['seq']));
  stdout.writeln(_formatKeyValueLine('ts', turn['ts']));
  stdout.writeln(_formatKeyValueLine('status', turn['status']));
  stdout.writeln(_formatKeyValueLine('provider', turn['provider_key']));
  stdout.writeln(_formatKeyValueLine('model', turn['model_id']));
  stdout.writeln(_formatKeyValueLine('http_status', turn['http_status']));
  stdout.writeln(_formatKeyValueLine('latency_ms', turn['latency_ms']));
  stdout.writeln(_formatKeyValueLine('total_tokens', turn['total_tokens']));
  stdout.writeln(_formatKeyValueLine('prompt_tokens', turn['prompt_tokens']));
  stdout.writeln(
    _formatKeyValueLine('completion_tokens', turn['completion_tokens']),
  );
  stdout.writeln(_formatKeyValueLine('cached_tokens', turn['cached_tokens']));
  stdout.writeln('');

  stdout.writeln('User');
  stdout.writeln(
    _block(_excerpt((turn['user_text'] ?? '').toString(), excerptLength)),
  );
  stdout.writeln('');

  stdout.writeln('Assistant');
  stdout.writeln(
    _block(
      _excerpt((turn['assistant_text'] ?? '').toString(), excerptLength * 2),
    ),
  );
  stdout.writeln('');

  final reasoningText = (turn['reasoning_text'] ?? '').toString();
  if (reasoningText.trim().isNotEmpty) {
    stdout.writeln('Reasoning');
    stdout.writeln(_block(_excerpt(reasoningText, excerptLength * 2)));
    stdout.writeln('');
  }

  final injectSnapshot = _decodeJsonMap(turn['inject_snapshot_json']);
  if (injectSnapshot != null) {
    stdout.writeln('Inject snapshot');
    stdout.writeln(
      _formatKeyValueLine(
        'system_messages',
        (injectSnapshot['system_messages'] as List?)?.length ?? 0,
      ),
    );
    stdout.writeln(
      _formatKeyValueLine(
        'memory_records',
        (injectSnapshot['memory_records'] as List?)?.length ?? 0,
      ),
    );
    stdout.writeln(
      _formatKeyValueLine(
        'recent_chat_summaries',
        (injectSnapshot['recent_chat_summaries'] as List?)?.length ?? 0,
      ),
    );
    stdout.writeln(
      _formatKeyValueLine(
        'instruction_prompts',
        (injectSnapshot['instruction_prompts'] as List?)?.length ?? 0,
      ),
    );
    stdout.writeln(
      _formatKeyValueLine(
        'world_book_entries',
        (injectSnapshot['world_book_entries'] as List?)?.length ?? 0,
      ),
    );
    stdout.writeln(
      _formatKeyValueLine(
        'search_prompt_enabled',
        injectSnapshot['search_prompt_enabled'],
      ),
    );
    final contextLimit = injectSnapshot['context_limit'];
    if (contextLimit != null) {
      stdout.writeln(_formatKeyValueLine('context_limit', contextLimit));
    }
    final toolDefinitions = injectSnapshot['tool_definitions'];
    if (toolDefinitions is List) {
      final toolNames = toolDefinitions
          .whereType<Map>()
          .map((tool) => (tool['name'] ?? '').toString())
          .where((name) => name.isNotEmpty)
          .toList(growable: false);
      stdout.writeln(
        _formatKeyValueLine('tool_definition_count', toolDefinitions.length),
      );
      if (toolNames.isNotEmpty) {
        stdout.writeln(_formatKeyValueLine('tool_names', toolNames.join(', ')));
      }
    }
    final mcpDiagnostics = _mapFromDynamic(injectSnapshot['mcp_diagnostics']);
    if (mcpDiagnostics != null && mcpDiagnostics.isNotEmpty) {
      stdout.writeln('');
      stdout.writeln('MCP diagnostics');
      stdout.writeln(_formatKeyValueLine('reason', mcpDiagnostics['reason']));
      stdout.writeln(
        _formatKeyValueLine('supports_tools', mcpDiagnostics['supports_tools']),
      );
      stdout.writeln(
        _formatKeyValueLine(
          'selected_assistant_mcp_server_ids',
          _joinDynamicList(mcpDiagnostics['selected_assistant_mcp_server_ids']),
        ),
      );
      stdout.writeln(
        _formatKeyValueLine(
          'connected_mcp_server_ids',
          _joinDynamicList(mcpDiagnostics['connected_mcp_server_ids']),
        ),
      );
      stdout.writeln(
        _formatKeyValueLine(
          'selected_connected_mcp_server_ids',
          _joinDynamicList(mcpDiagnostics['selected_connected_mcp_server_ids']),
        ),
      );
      stdout.writeln(
        _formatKeyValueLine(
          'enabled_mcp_tool_names',
          _joinDynamicList(mcpDiagnostics['enabled_mcp_tool_names']),
        ),
      );
      final selectedServers = mcpDiagnostics['selected_connected_mcp_servers'];
      if (selectedServers is List && selectedServers.isNotEmpty) {
        for (final server in selectedServers.whereType<Map>()) {
          stdout.writeln(
            '  server=${server['id'] ?? '-'} name=${server['name'] ?? '-'} status=${server['status'] ?? '-'} enabled_tools=${_joinDynamicList(server['enabled_tool_names'])}',
          );
        }
      }
    }
    stdout.writeln('');
  }

  stdout.writeln('Inject log');
  if (injectLog.isEmpty) {
    stdout.writeln('(empty)');
  } else {
    final counts = <String, int>{};
    for (final row in injectLog) {
      counts.update(
        (row['kind'] ?? 'unknown').toString(),
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    }
    stdout.writeln(_formatKeyValueLine('counts', _formatMap(counts)));
    stdout.writeln('');
    for (final row in injectLog) {
      stdout.writeln(
        '- kind=${row['kind']} source_id=${row['source_id'] ?? '-'} title=${row['title'] ?? '-'} score=${row['score'] ?? '-'}',
      );
      stdout.writeln('  reason=${row['reason'] ?? '-'}');
      final excerpt = (row['content_excerpt'] ?? '').toString();
      if (excerpt.trim().isNotEmpty) {
        stdout.writeln('  excerpt=${_excerpt(excerpt, excerptLength)}');
      }
    }
  }
  stdout.writeln('');

  stdout.writeln('Turn events');
  if (turnEvents.isEmpty) {
    stdout.writeln('(empty)');
  } else {
    for (final row in turnEvents) {
      stdout.writeln(
        '- ${row['ts']} kind=${row['kind']} payload=${_compactJson(row['payload_json'])}',
      );
    }
  }
  stdout.writeln('');

  final requestJson = _compactJson(turn['request_json']);
  if (requestJson != null) {
    stdout.writeln('Request json');
    stdout.writeln(_block(_excerpt(requestJson, excerptLength * 3)));
    stdout.writeln('');
  }

  final responseJson = _compactJson(turn['response_json']);
  if (responseJson != null) {
    stdout.writeln('Response json');
    stdout.writeln(_block(_excerpt(responseJson, excerptLength * 3)));
  }
}

void _printStats(
  Database db, {
  required int recent,
  required String? sessionId,
}) {
  final params = <Object?>[];
  final whereClause = sessionId == null ? '' : 'WHERE session_id = ?';
  if (sessionId != null) params.add(sessionId);
  params.add(recent);

  final turns = db.select('''
SELECT turn_id, session_id, status, latency_ms, total_tokens
FROM turns
$whereClause
ORDER BY ts DESC
LIMIT ?
''', params);

  if (turns.isEmpty) {
    stdout.writeln(
      sessionId == null
          ? 'No turns found for stats.'
          : 'No turns found for session stats: $sessionId',
    );
    return;
  }

  final turnIds = turns.map((row) => row['turn_id'] as String).toList();
  final placeholders = List.filled(turnIds.length, '?').join(', ');
  final injectRows = db.select('''
SELECT turn_id, kind, title, reason, content_excerpt
FROM inject_log
WHERE turn_id IN ($placeholders)
''', turnIds);

  final statusCounts = <String, int>{};
  final kindCounts = <String, int>{};
  final emptyExcerptByKind = <String, int>{};
  final totalByKind = <String, int>{};
  final uniqueSessions = <String>{};
  int completedCount = 0;
  int latencyTotal = 0;
  int latencyCount = 0;
  int tokenTotal = 0;
  int tokenCount = 0;

  for (final row in turns) {
    final status = (row['status'] ?? 'unknown').toString();
    statusCounts.update(status, (value) => value + 1, ifAbsent: () => 1);
    if (status == 'completed') completedCount++;
    uniqueSessions.add((row['session_id'] ?? '').toString());
    final latency = _asInt(row['latency_ms']);
    if (latency != null) {
      latencyTotal += latency;
      latencyCount++;
    }
    final tokens = _asInt(row['total_tokens']);
    if (tokens != null) {
      tokenTotal += tokens;
      tokenCount++;
    }
  }

  for (final row in injectRows) {
    final kind = (row['kind'] ?? 'unknown').toString();
    kindCounts.update(kind, (value) => value + 1, ifAbsent: () => 1);
    totalByKind.update(kind, (value) => value + 1, ifAbsent: () => 1);
    final excerpt = (row['content_excerpt'] ?? '').toString().trim();
    if (excerpt.isEmpty) {
      emptyExcerptByKind.update(kind, (value) => value + 1, ifAbsent: () => 1);
    }
  }

  stdout.writeln(
    sessionId == null
        ? 'Stats for latest $recent turns'
        : 'Stats for latest $recent turns in session $sessionId',
  );
  stdout.writeln('');
  stdout.writeln(_formatKeyValueLine('turn_count', turns.length));
  stdout.writeln(_formatKeyValueLine('session_count', uniqueSessions.length));
  stdout.writeln(_formatKeyValueLine('completed_count', completedCount));
  stdout.writeln(
    _formatKeyValueLine('status_counts', _formatMap(statusCounts)),
  );
  stdout.writeln(
    _formatKeyValueLine('inject_kind_counts', _formatMap(kindCounts)),
  );
  stdout.writeln(
    _formatKeyValueLine(
      'avg_latency_ms',
      latencyCount == 0
          ? '-'
          : (latencyTotal / latencyCount).toStringAsFixed(1),
    ),
  );
  stdout.writeln(
    _formatKeyValueLine(
      'avg_total_tokens',
      tokenCount == 0 ? '-' : (tokenTotal / tokenCount).toStringAsFixed(1),
    ),
  );
  stdout.writeln('');

  stdout.writeln('Empty content_excerpt by kind');
  if (totalByKind.isEmpty) {
    stdout.writeln('  (no inject_log rows)');
  } else {
    final kinds = totalByKind.keys.toList()..sort();
    for (final kind in kinds) {
      final total = totalByKind[kind] ?? 0;
      final empty = emptyExcerptByKind[kind] ?? 0;
      final rate = total == 0 ? 0 : (empty * 100 / total);
      stdout.writeln(
        '  $kind: empty=$empty total=$total rate=${rate.toStringAsFixed(1)}%',
      );
    }
  }
}

Map<String, Map<String, int>> _loadInjectCounts(
  Database db,
  List<String> turnIds,
) {
  if (turnIds.isEmpty) return const <String, Map<String, int>>{};
  final placeholders = List.filled(turnIds.length, '?').join(', ');
  final rows = db.select('''
SELECT turn_id, kind, COUNT(*) AS count
FROM inject_log
WHERE turn_id IN ($placeholders)
GROUP BY turn_id, kind
''', turnIds);
  final out = <String, Map<String, int>>{};
  for (final row in rows) {
    final turnId = row['turn_id'] as String;
    final kind = (row['kind'] ?? 'unknown').toString();
    final count = _asInt(row['count']) ?? 0;
    out.putIfAbsent(turnId, () => <String, int>{})[kind] = count;
  }
  return out;
}

Map<String, dynamic>? _decodeJsonMap(Object? raw) {
  if (raw == null) return null;
  if (raw is Map<String, dynamic>) return raw;
  if (raw is! String || raw.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
  } catch (_) {}
  return null;
}

String? _compactJson(Object? raw) {
  if (raw == null) return null;
  if (raw is String) {
    if (raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return jsonEncode(decoded);
    } catch (_) {
      return raw;
    }
  }
  try {
    return jsonEncode(raw);
  } catch (_) {
    return raw.toString();
  }
}

String _formatKeyValueLine(String key, Object? value) {
  return '$key: ${value ?? '-'}';
}

String _formatMap(Map<String, int> value) {
  if (value.isEmpty) return '-';
  final sorted = value.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return sorted.map((entry) => '${entry.key}=${entry.value}').join(', ');
}

String _excerpt(String text, int maxLength) {
  final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.isEmpty) return '-';
  if (normalized.length <= maxLength) return normalized;
  return '${normalized.substring(0, maxLength)}...';
}

String _block(String text) {
  return text.split('\n').map((line) => '  $line').join('\n');
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

bool _tableExists(Database db, String tableName) {
  final rows = db.select(
    '''
SELECT name
FROM sqlite_master
WHERE type = 'table' AND name = ?
LIMIT 1
''',
    [tableName],
  );
  return rows.isNotEmpty;
}

Map<String, dynamic>? _mapFromDynamic(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, val) => MapEntry(key.toString(), val));
  }
  return null;
}

String _joinDynamicList(Object? value) {
  if (value is! List) return '-';
  final items = value
      .map((item) => item?.toString() ?? '')
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
  return items.isEmpty ? '-' : items.join(', ');
}
