import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/services/memory/memory_export_service.dart';

void main() {
  test('exports assistant memories from flutter-prefixed shared prefs', () {
    final prefs = <String, dynamic>{
      'flutter.assistants_v1': jsonEncode([
        {'id': 'assistant-a', 'name': 'A', 'enableMemory': true},
        {'id': 'assistant-b', 'name': 'B', 'enableMemory': true},
      ]),
      'flutter.assistant_memories_v1': jsonEncode([
        {'id': 1, 'assistantId': 'assistant-a', 'content': '记忆 A1'},
        {'id': 2, 'assistantId': 'assistant-a', 'content': '记忆 A2'},
        {'id': 3, 'assistantId': 'assistant-b', 'content': '记忆 B1'},
      ]),
    };

    final export = MemoryExportService.exportFromPrefsMap(
      prefs,
      assistantId: 'assistant-a',
    );

    expect(export.assistantId, 'assistant-a');
    expect(export.assistantName, 'A');
    expect(export.memories, hasLength(2));
    expect(export.memories.map((m) => m.content), ['记忆 A1', '记忆 A2']);
  });

  test('supports unprefixed keys and missing assistant metadata', () {
    final prefs = <String, dynamic>{
      'assistant_memories_v1': jsonEncode([
        {'id': 7, 'assistantId': 'assistant-x', 'content': '孤立记忆'},
      ]),
    };

    final export = MemoryExportService.exportFromPrefsMap(
      prefs,
      assistantId: 'assistant-x',
    );

    expect(export.assistantName, isNull);
    expect(export.memories, hasLength(1));
    expect(export.memories.single.id, 7);
  });
}
