// Diagnostic: exercise the API client against a live server and print what it
// parses. Complements tool/smoke.dart, which drives a whole session.
//
//   OPENCODE_URL=http://127.0.0.1:49374 OPENCODE_PASSWORD=... \
//   dart run tool/probe.dart [sessionID]
import 'dart:io';

import 'package:opencode_mobile/src/data/api.dart';

Future<void> main(List<String> args) async {
  final url = Platform.environment['OPENCODE_URL'] ?? 'http://127.0.0.1:49374';
  final password = Platform.environment['OPENCODE_PASSWORD'];
  if (password == null) {
    stderr.writeln('OPENCODE_PASSWORD is not set');
    exitCode = 2;
    return;
  }

  final api = OpenCodeApi.forProfile(
    ServerProfile.basic(baseUrl: url, password: password),
  );
  final out = stdout;

  try {
    final models = await api.models();
    out.writeln('models: ${models.length}');
    for (final model in models.take(6)) {
      out.writeln(
        '  ${model.key}  variants=[${model.variants.join(',')}] '
        'ctx=${model.contextLimit} cost=\$${model.costIn}/M',
      );
    }

    if (args.isNotEmpty) {
      final session = await api.session(args.first);
      out.writeln('---');
      out.writeln('session   : ${session.id}');
      out.writeln('model id  : ${session.modelId}');
      out.writeln('provider  : ${session.modelProvider}');
      out.writeln('variant   : ${session.modelVariant}');
      out.writeln('agent     : ${session.agent}');
    }
  } on ApiException catch (error) {
    stderr.writeln('API error: ${error.message} (${error.statusCode})');
    exitCode = 1;
  }
  exit(0);
}