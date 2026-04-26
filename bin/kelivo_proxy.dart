import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:Kelivo/core/services/analysis/kelivo_proxy_server.dart';

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  final defaultUpstream = options.options['upstream']?.trim();
  final providerUpstreams = _parseProviderUpstreams(
    options.providerUpstreamSpecs,
  );
  if ((defaultUpstream == null || defaultUpstream.isEmpty) &&
      providerUpstreams.isEmpty) {
    stderr.writeln(
      'Usage: dart run bin/kelivo_proxy.dart --upstream=http://127.0.0.1:4000 [--provider-upstream=DeepSeek=https://api.deepseek.com] [--host=127.0.0.1] [--port=8787] [--db-path=proxy_analysis_v1.db]',
    );
    exitCode = 64;
    return;
  }

  final server = KelivoProxyServer(
    upstreamBaseUri: defaultUpstream == null || defaultUpstream.isEmpty
        ? null
        : Uri.parse(defaultUpstream),
    providerUpstreamBaseUris: providerUpstreams,
    host: InternetAddress(
      options.options['host'] ?? InternetAddress.loopbackIPv4.address,
    ),
    port: int.tryParse(options.options['port'] ?? '') ?? 8787,
    dbPath:
        options.options['db-path'] ??
        p.join(Directory.current.path, 'proxy_analysis_v1.db'),
  );

  final httpServer = await server.start();
  stdout.writeln(
    'Kelivo proxy listening on http://${httpServer.address.address}:${httpServer.port}',
  );
  if (defaultUpstream != null && defaultUpstream.isNotEmpty) {
    stdout.writeln('Kelivo proxy default upstream: $defaultUpstream');
  }
  if (providerUpstreams.isNotEmpty) {
    stdout.writeln('Kelivo proxy provider upstream routes:');
    final routeKeys = providerUpstreams.keys.toList()..sort();
    for (final key in routeKeys) {
      stdout.writeln('  $key -> ${providerUpstreams[key]}');
    }
  }
  stdout.writeln('Kelivo proxy database: ${server.dbPath}');

  ProcessSignal.sigint.watch().listen((_) async {
    await server.close();
    exit(0);
  });
}

class _CliOptions {
  const _CliOptions({
    required this.options,
    required this.providerUpstreamSpecs,
  });

  final Map<String, String> options;
  final List<String> providerUpstreamSpecs;
}

_CliOptions _parseArgs(List<String> args) {
  final result = <String, String>{};
  final providerUpstreamSpecs = <String>[];
  for (final arg in args) {
    if (!arg.startsWith('--')) continue;
    final idx = arg.indexOf('=');
    if (idx <= 2) continue;
    final key = arg.substring(2, idx);
    final value = arg.substring(idx + 1);
    if (key == 'provider-upstream') {
      providerUpstreamSpecs.add(value);
      continue;
    }
    if (key == 'provider-upstreams') {
      providerUpstreamSpecs.addAll(
        value.split(';').map((e) => e.trim()).where((e) => e.isNotEmpty),
      );
      continue;
    }
    result[key] = value;
  }
  return _CliOptions(
    options: result,
    providerUpstreamSpecs: providerUpstreamSpecs,
  );
}

Map<String, Uri> _parseProviderUpstreams(List<String> specs) {
  final result = <String, Uri>{};
  for (final spec in specs) {
    final separator = spec.indexOf('=');
    if (separator <= 0 || separator >= spec.length - 1) {
      throw FormatException(
        'Invalid provider upstream spec "$spec". Expected ProviderKey=https://host',
      );
    }
    final providerKey = spec.substring(0, separator).trim();
    final uriText = spec.substring(separator + 1).trim();
    if (providerKey.isEmpty || uriText.isEmpty) {
      throw FormatException(
        'Invalid provider upstream spec "$spec". Expected ProviderKey=https://host',
      );
    }
    result[providerKey] = Uri.parse(uriText);
  }
  return result;
}
