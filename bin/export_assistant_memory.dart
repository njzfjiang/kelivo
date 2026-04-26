import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:Kelivo/core/services/memory/memory_export_service.dart';

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  if (options.containsKey('help') || options.containsKey('h')) {
    _printUsage();
    return;
  }

  final assistantId = options['assistant-id']?.trim() ?? '';
  if (assistantId.isEmpty) {
    stderr.writeln('--assistant-id is required.');
    _printUsage();
    exitCode = 64;
    return;
  }

  final prefsPath = _resolvePrefsPath(options);
  final prefsFile = File(prefsPath);
  if (!await prefsFile.exists()) {
    stderr.writeln('Shared preferences file not found: $prefsPath');
    exitCode = 2;
    return;
  }

  late final AssistantMemoryExport export;
  try {
    export = MemoryExportService.exportFromPrefsJson(
      await prefsFile.readAsString(),
      assistantId: assistantId,
    );
  } on FormatException catch (e) {
    stderr.writeln('Failed to read preferences JSON: ${e.message}');
    stderr.writeln('Input file: $prefsPath');
    stderr.writeln(
      'Tip: use the app shared_preferences.json file, or omit --prefs-json to use the default app path.',
    );
    exitCode = 65;
    return;
  }
  final format = (options['format'] ?? 'json').trim().toLowerCase();
  final rendered = switch (format) {
    'json' => const JsonEncoder.withIndent('  ').convert(export.toJson()),
    'txt' || 'text' => _renderText(export),
    _ => throw FormatException('Unsupported format: $format'),
  };

  final outPath = options['out']?.trim();
  if (outPath != null && outPath.isNotEmpty) {
    await File(outPath).writeAsString(rendered);
    stdout.writeln('Exported ${export.memories.length} memories to $outPath');
    return;
  }

  stdout.writeln(rendered);
}

void _printUsage() {
  stdout.writeln('Export assistant memories');
  stdout.writeln('');
  stdout.writeln('Usage:');
  stdout.writeln(
    '  dart run bin/export_assistant_memory.dart --assistant-id=<id> [--prefs-json=<path>] [--out=<path>] [--format=json|txt]',
  );
  stdout.writeln(
    '  dart run bin/export_assistant_memory.dart --assistant-id=<id> --app-prefs',
  );
  stdout.writeln('');
  stdout.writeln('Options:');
  stdout.writeln('  --assistant-id=ID   Assistant id to export');
  stdout.writeln(
    '  --prefs-json=PATH   Shared preferences JSON path (defaults to app prefs path on Windows)',
  );
  stdout.writeln(
    '  --app-prefs         Alias for using the default app shared preferences path',
  );
  stdout.writeln(
    '  --out=PATH          Write output to file instead of stdout',
  );
  stdout.writeln('  --format=json|txt   Output format, default json');
  stdout.writeln('  --help              Show this message');
}

String _resolvePrefsPath(Map<String, String> options) {
  final explicit = options['prefs-json']?.trim();
  if (explicit != null && explicit.isNotEmpty) return explicit;
  return defaultPrefsJsonPath();
}

String defaultPrefsJsonPath() {
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.trim().isNotEmpty) {
      return p.join(appData, 'com.psyche', 'kelivo', 'shared_preferences.json');
    }
  }
  return 'shared_preferences.json';
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

String _renderText(AssistantMemoryExport export) {
  final lines = <String>[
    'assistant_id: ${export.assistantId}',
    'assistant_name: ${export.assistantName ?? '-'}',
    'memory_count: ${export.memories.length}',
    '',
  ];
  for (final memory in export.memories) {
    lines.add('#${memory.id}');
    lines.add(memory.content);
    lines.add('');
  }
  return lines.join('\n');
}
