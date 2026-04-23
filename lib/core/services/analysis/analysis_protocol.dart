import 'dart:convert';

const String kelivoAnalysisTurnHeaderName = 'X-Kelivo-Turn-Id';
const String kelivoAnalysisConversationHeaderName = 'X-Kelivo-Conversation-Id';
const String kelivoAnalysisVersionHeaderName = 'X-Kelivo-Analysis-Version';
const int kelivoAnalysisVersion = 1;
const String kelivoAnalysisMetaBodyKey = '_kelivo_analysis_meta';

Map<String, String>? sanitizeAnalysisHeaders(Map<String, String>? headers) {
  if (headers == null || headers.isEmpty) return null;
  final sanitized = <String, String>{};
  for (final entry in headers.entries) {
    sanitized[entry.key] = sanitizeAnalysisHeaderValue(entry.key, entry.value);
  }
  return sanitized;
}

String sanitizeAnalysisHeaderValue(String key, String value) {
  final lower = key.toLowerCase();
  if (lower == 'authorization' ||
      lower == 'x-api-key' ||
      lower == 'x-goog-api-key' ||
      lower.contains('token') ||
      lower.contains('secret') ||
      lower.contains('key')) {
    return '[REDACTED]';
  }
  return value;
}

String? encodeAnalysisJson(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  return jsonEncode(value);
}
