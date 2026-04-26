import 'dart:convert';
import '../../models/assistant.dart';
import '../../models/assistant_memory.dart';

class AssistantMemoryExport {
  const AssistantMemoryExport({
    required this.assistantId,
    required this.memories,
    this.assistantName,
  });

  final String assistantId;
  final String? assistantName;
  final List<AssistantMemory> memories;

  Map<String, dynamic> toJson() => {
    'assistant_id': assistantId,
    'assistant_name': assistantName,
    'memory_count': memories.length,
    'memories': memories.map((e) => e.toJson()).toList(growable: false),
  };
}

class MemoryExportService {
  static const String memoriesKey = 'assistant_memories_v1';
  static const String assistantsKey = 'assistants_v1';
  static const String flutterPrefix = 'flutter.';

  static AssistantMemoryExport exportFromPrefsJson(
    String prefsJson, {
    required String assistantId,
  }) {
    if (prefsJson.trim().isEmpty) {
      throw const FormatException(
        'Preferences JSON is empty. Pass the app shared_preferences.json file, not an empty export file.',
      );
    }
    final decoded = jsonDecode(prefsJson);
    if (decoded is! Map) {
      throw const FormatException(
        'Shared preferences JSON must be a top-level object.',
      );
    }
    return exportFromPrefsMap(
      decoded.cast<String, dynamic>(),
      assistantId: assistantId,
    );
  }

  static AssistantMemoryExport exportFromPrefsMap(
    Map<String, dynamic> prefs, {
    required String assistantId,
  }) {
    final normalizedAssistantId = assistantId.trim();
    if (normalizedAssistantId.isEmpty) {
      throw const FormatException('assistantId cannot be empty.');
    }
    final assistants = _decodeAssistants(
      _readJsonStringValue(prefs, assistantsKey),
    );
    final assistantName = _assistantNameForId(
      assistants,
      normalizedAssistantId,
    );
    final memories = _decodeMemories(_readJsonStringValue(prefs, memoriesKey))
        .where((m) => m.assistantId == normalizedAssistantId)
        .toList(growable: false);
    return AssistantMemoryExport(
      assistantId: normalizedAssistantId,
      assistantName: assistantName,
      memories: memories,
    );
  }

  static String? _readJsonStringValue(Map<String, dynamic> prefs, String key) {
    final direct = prefs[key];
    if (direct is String) return direct;
    final prefixed = prefs['$flutterPrefix$key'];
    if (prefixed is String) return prefixed;
    return null;
  }

  static List<AssistantMemory> _decodeMemories(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const <AssistantMemory>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <AssistantMemory>[];
      return decoded
          .map((entry) {
            if (entry is Map<String, dynamic>) {
              return AssistantMemory.fromJson(entry);
            }
            return AssistantMemory.fromJson(
              (entry as Map).cast<String, dynamic>(),
            );
          })
          .toList(growable: false);
    } catch (_) {
      return const <AssistantMemory>[];
    }
  }

  static List<Assistant> _decodeAssistants(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const <Assistant>[];
    try {
      return Assistant.decodeList(raw);
    } catch (_) {
      return const <Assistant>[];
    }
  }

  static String? _assistantNameForId(
    List<Assistant> assistants,
    String assistantId,
  ) {
    for (final assistant in assistants) {
      if (assistant.id == assistantId) return assistant.name;
    }
    return null;
  }
}
