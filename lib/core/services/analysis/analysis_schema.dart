import 'package:sqlite3/sqlite3.dart';

void createAnalysisSchema(Database db) {
  db.execute('''
CREATE TABLE IF NOT EXISTS sessions (
  session_id TEXT PRIMARY KEY,
  source_conversation_id TEXT NOT NULL,
  assistant_id TEXT,
  created_at TEXT NOT NULL,
  last_seen TEXT NOT NULL,
  notes TEXT
);
''');
  db.execute('''
CREATE TABLE IF NOT EXISTS turns (
  turn_id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  ts TEXT NOT NULL,
  provider_key TEXT,
  model_id TEXT,
  stream INTEGER NOT NULL DEFAULT 1,
  status TEXT NOT NULL,
  http_status INTEGER,
  error_text TEXT,
  latency_ms INTEGER,
  prompt_tokens INTEGER,
  completion_tokens INTEGER,
  cached_tokens INTEGER,
  total_tokens INTEGER,
  request_headers_json TEXT,
  response_headers_json TEXT,
  request_json TEXT NOT NULL,
  response_json TEXT,
  user_text TEXT,
  assistant_text TEXT,
  reasoning_text TEXT,
  tool_calls_json TEXT,
  tool_results_json TEXT,
  rolling_short_before TEXT,
  rolling_short_after TEXT,
  inject_snapshot_json TEXT,
  version_group_id TEXT,
  version_index INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY(session_id) REFERENCES sessions(session_id)
);
''');
  db.execute('''
CREATE TABLE IF NOT EXISTS inject_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  turn_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  source_id TEXT,
  title TEXT,
  score REAL,
  reason TEXT,
  content_excerpt TEXT,
  position INTEGER,
  payload_json TEXT,
  FOREIGN KEY(turn_id) REFERENCES turns(turn_id)
);
''');
  db.execute('''
CREATE TABLE IF NOT EXISTS turn_events (
  event_id INTEGER PRIMARY KEY AUTOINCREMENT,
  turn_id TEXT NOT NULL,
  ts TEXT NOT NULL,
  kind TEXT NOT NULL,
  payload_json TEXT,
  FOREIGN KEY(turn_id) REFERENCES turns(turn_id)
);
''');
  db.execute('''
CREATE TABLE IF NOT EXISTS rolling_summaries (
  session_id TEXT PRIMARY KEY,
  assistant_id TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  source_last_message_count INTEGER NOT NULL,
  summary_text TEXT NOT NULL
);
''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_turns_session_seq ON turns(session_id, seq);',
  );
  db.execute('CREATE INDEX IF NOT EXISTS idx_turns_ts ON turns(ts);');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_turns_provider_model ON turns(provider_key, model_id);',
  );
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_inject_log_turn ON inject_log(turn_id);',
  );
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_turn_events_turn_ts ON turn_events(turn_id, ts);',
  );
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_rolling_summaries_updated_at ON rolling_summaries(updated_at);',
  );
}
