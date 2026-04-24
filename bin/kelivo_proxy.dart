import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:Kelivo/core/services/analysis/kelivo_proxy_server.dart';

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  final upstream = options['upstream'];
  if (upstream == null || upstream.trim().isEmpty) {
    stderr.writeln(
      'Usage: dart run bin/kelivo_proxy.dart --upstream=http://127.0.0.1:4000 [--host=127.0.0.1] [--port=8787] [--db-path=proxy_analysis_v1.db]',
    );
    exitCode = 64;
    return;
  }

  final server = KelivoProxyServer(
    upstreamBaseUri: Uri.parse(upstream),
    host: InternetAddress(
      options['host'] ?? InternetAddress.loopbackIPv4.address,
    ),
    port: int.tryParse(options['port'] ?? '') ?? 8787,
    dbPath:
        options['db-path'] ??
        p.join(Directory.current.path, 'proxy_analysis_v1.db'),
  );

  final httpServer = await server.start();
  stdout.writeln(
    'Kelivo proxy listening on http://${httpServer.address.address}:${httpServer.port} -> $upstream',
  );
  stdout.writeln('Kelivo proxy database: ${server.dbPath}');

  ProcessSignal.sigint.watch().listen((_) async {
    await server.close();
    exit(0);
  });
}

Map<String, String> _parseArgs(List<String> args) {
  final result = <String, String>{};
  for (final arg in args) {
    if (!arg.startsWith('--')) continue;
    final idx = arg.indexOf('=');
    if (idx <= 2) continue;
    result[arg.substring(2, idx)] = arg.substring(idx + 1);
  }
  return result;
}
