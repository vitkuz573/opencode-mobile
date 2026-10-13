// End-to-end check of the client's data layer against a real server.
//
// Run it with the same transport the app uses, so auth, parsing and event
// framing are exercised without a device:
//
//   OPENCODE_URL=http://127.0.0.1:4096 \
//   OPENCODE_PASSWORD=... \
//   dart run tool/smoke.dart
//
// The password is read from the environment on purpose: this file is committed.
import 'dart:async';
import 'dart:io';

import 'package:opencode_mobile/src/data/api.dart';
import 'package:opencode_mobile/src/data/events.dart';
import 'package:opencode_mobile/src/data/models.dart';
import 'package:opencode_mobile/src/state/timeline.dart';

Future<void> main() async {
  final url = Platform.environment['OPENCODE_URL'] ?? 'http://127.0.0.1:4096';
  final password = Platform.environment['OPENCODE_PASSWORD'];
  if (password == null) {
    stderr.writeln('OPENCODE_PASSWORD is not set');
    exitCode = 2;
    return;
  }

  final profile = ServerProfile.basic(baseUrl: url, password: password);
  final api = OpenCodeApi.forProfile(profile);
  final out = stdout;

  try {
    final info = await api.info();
    out.writeln('server      : ${info.version} (pid ${info.pid})');

    final projects = await api.projects();
    out.writeln('projects    : ${projects.length}');
    for (final project in projects.take(5)) {
      out.writeln('  - ${project.displayName} -> ${project.scopeDirectory}');
    }

    final directory = projects.isEmpty ? null : projects.first.scopeDirectory;
    final page = await api.sessions(directory: directory, limit: 5);
    out.writeln('sessions    : ${page.items.length} (more: ${page.hasMore})');
    for (final session in page.items.take(5)) {
      out.writeln(
        '  - ${session.displayTitle} '
        '[${session.modelId ?? '?'}] ${formatUsage(session)}',
      );
    }

    // Live events for one session: start a session, prompt it, and fold the
    // stream exactly like the chat screen does.
    final session = await api.createSession(directory: directory);
    out.writeln('created     : ${session.id}');

    final messages = await api.messages(session.id, directory: directory);
    out.writeln('history     : ${messages.length} messages');

    final events = EventStream(dio: api.raw);
    final timeline = <ServerEvent>[];
    final subscription = events.events.listen((event) {
      if (event.sessionId != session.id) return;
      timeline.add(event);
      out.writeln('  event ${event.type}');
    });

    unawaited(events.start());
    await Future<void>.delayed(const Duration(seconds: 1));
    await api.sendPrompt(
      session.id,
      'Reply with exactly: SMOKE-OK',
      directory: directory,
    );

    var folded = Timeline();
    var settled = false;
    for (var i = 0; i < 120; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      for (final event in timeline) {
        folded = applyEvent(folded, event, sessionId: session.id);
      }
      timeline.clear();
      if (folded.messages.isNotEmpty && !folded.running) {
        settled = true;
        break;
      }
    }
    await subscription.cancel();
    await events.dispose();

    final assistant = folded.messages.whereType<AssistantMessage>().toList();
    out.writeln('---');
    out.writeln('assistant   : ${assistant.length} message(s)');
    for (final message in assistant) {
      out.writeln('text        : ${message.text}');
      for (final part in message.parts.whereType<ToolPart>()) {
        out.writeln('tool        : ${part.name} ${part.status.name}');
      }
    }
    out.writeln('cost        : ${folded.cost}');
    out.writeln('tokens      : ${folded.tokens?.input ?? 0} in / '
        '${folded.tokens?.output ?? 0} out');
    out.writeln(settled ? 'RESULT      : ok' : 'RESULT      : timed out');

    await api.interrupt(session.id, directory: directory);
  } on ApiException catch (error) {
    stderr.writeln('API error: ${error.message} (${error.statusCode})');
    exitCode = 1;
  } finally {
    exit(0);
  }
}

String formatUsage(SessionSummary session) =>
    '${session.tokens.total} tok, ${session.cost}';