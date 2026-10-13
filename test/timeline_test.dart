import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/data/events.dart';
import 'package:opencode_mobile/src/data/models.dart';
import 'package:opencode_mobile/src/state/timeline.dart';

/// The fixtures under `fixtures/events` are real captures from a live server
/// (recorded 2026-10-13 against opencode 2.0.18). They are the reason the
/// reducer can be trusted: the payloads are not invented.
List<ServerEvent> loadFixture(String name) {
  final file = File('test/fixtures/events/$name.ndjson');
  return file
      .readAsLinesSync()
      .where((line) => line.trim().isNotEmpty)
      .map(
        (line) => ServerEvent.fromJson(
          (jsonDecode(line) as Map).cast<String, Object?>(),
        ),
      )
      .toList(growable: false);
}

Timeline fold(Iterable<ServerEvent> events, String sessionId) {
  var timeline = const Timeline();
  for (final event in events) {
    timeline = applyEvent(timeline, event, sessionId: sessionId);
  }
  return timeline;
}

void main() {
  group('envelope parsing', () {
    test('reads id, type, location and durable sequence', () {
      final events = loadFixture('text_stream');
      final created = events.firstWhere(
        (e) => e.type == Ev.sessionCreated,
      );

      expect(created.sessionId, 'ses_eccb90265ffemMl7j42e4F7tVC');
      expect(created.directory, r'C:\Users\vitaly\dev\_demo');
      expect(created.seq, 0);
      expect(created.id, startsWith('evt_'));
    });

    test('tolerates an event with no data or location', () {
      final event = ServerEvent.fromJson({
        'type': 'server.connected',
        'created': 1,
      });
      expect(event.type, Ev.serverConnected);
      expect(event.sessionId, isEmpty);
      expect(event.seq, isNull);
    });
  });

  group('text stream folding', () {
    final timeline = fold(
      loadFixture('text_stream'),
      'ses_eccb90265ffemMl7j42e4F7tVC',
    );

    test('assembles streamed deltas into one assistant message', () {
      final assistant = timeline.messages
          .whereType<AssistantMessage>()
          .toList(growable: false);

      expect(assistant, hasLength(1));
      expect(assistant.single.text, 'PING-OK');
    });

    test('ends in an idle state', () {
      expect(timeline.running, isFalse);
    });

    test('records usage and cost', () {
      expect(timeline.cost, greaterThan(0));
      expect(timeline.tokens, isNotNull);
      expect(timeline.tokens!.input, greaterThan(0));
      expect(timeline.tokens!.cacheRead, greaterThan(0));
    });
  });

  group('tool call folding', () {
    final timeline = fold(
      loadFixture('tool_calls'),
      'ses_eccb81465ffeE09p0L9uZxp2D5',
    );

    test('creates one tool part per call, in order', () {
      final tools = timeline.messages
          .whereType<AssistantMessage>()
          .expand((m) => m.parts)
          .whereType<ToolPart>()
          .toList(growable: false);

      expect(tools.map((t) => t.name), ['read', 'shell']);
      expect(tools.every((t) => t.status == ToolStatus.completed), isTrue);
    });

    test('keeps the decoded tool input', () {
      final read = timeline.messages
          .whereType<AssistantMessage>()
          .expand((m) => m.parts)
          .whereType<ToolPart>()
          .first;

      expect(read.input['path'], endsWith('notes.txt'));
    });

    test('keeps tool output text', () {
      final outputs = timeline.messages
          .whereType<AssistantMessage>()
          .expand((m) => m.parts)
          .whereType<ToolPart>()
          .map((t) => t.output)
          .toList(growable: false);

      expect(outputs.first, contains('hello from demo'));
      expect(outputs.last, contains('shell-ran'));
    });
  });

  group('permission flow folding', () {
    final timeline = fold(
      loadFixture('permission_flow'),
      'ses_eccb7a5ceffecCBb8Lpojo1aar',
    );

    test('marks the declined tool as errored', () {
      final tools = timeline.messages
          .whereType<AssistantMessage>()
          .expand((m) => m.parts)
          .whereType<ToolPart>()
          .toList(growable: false);

      expect(tools, hasLength(1));
      expect(tools.single.status, ToolStatus.error);
      expect(tools.single.error, contains('declined'));
    });

    test('permission events do not create chat messages', () {
      expect(timeline.messages, hasLength(1));
    });

    test('interrupted execution clears the running flag', () {
      expect(timeline.running, isFalse);
    });
  });

  group('permission requests', () {
    test('are extracted with action, resources and tool id', () {
      final asked = loadFixture(
        'permission_flow',
      ).map((e) => e.asPermissionRequest).whereType<PermissionRequest>().single;

      expect(asked.action, 'external_directory');
      expect(asked.resources, [r'C:/Users/vitaly/dev/*']);
      expect(asked.toolId, startsWith('toolu_'));
      expect(asked.headline, isNotEmpty);
    });
  });

  group('retry folding', () {
    ServerEvent retry({Object? error, int attempt = 2}) => ServerEvent.fromJson({
      'type': Ev.retryScheduled,
      'created': 3,
      'data': {
        'sessionID': 'ses_x',
        'assistantMessageID': 'msg_x',
        'attempt': attempt,
        'at': 1791913357612,
        'error': ?error,
      },
    });

    test('records the attempt and the reason, and stays running', () {
      final timeline = fold([
        ServerEvent.fromJson({
          'type': Ev.executionStarted,
          'created': 1,
          'data': {'sessionID': 'ses_x'},
        }),
        retry(
          error: {
            'type': 'provider.transport',
            'message': 'getaddrinfo ETIMEOUT opencode.ai',
          },
        ),
      ], 'ses_x');

      expect(timeline.running, isTrue);
      expect(timeline.retryAttempt, 2);
      expect(timeline.retryError, 'getaddrinfo ETIMEOUT opencode.ai');
    });

    test('real progress retires the notice', () {
      var timeline = fold([
        ServerEvent.fromJson({
          'type': Ev.executionStarted,
          'created': 1,
          'data': {'sessionID': 'ses_x'},
        }),
        retry(error: 'boom'),
      ], 'ses_x');
      expect(timeline.isRetrying, isTrue);

      timeline = applyEvent(
        timeline,
        ServerEvent.fromJson({
          'type': Ev.textStarted,
          'created': 4,
          'data': {'sessionID': 'ses_x', 'assistantMessageID': 'msg_x'},
        }),
        sessionId: 'ses_x',
      );

      expect(timeline.isRetrying, isFalse);
      expect(timeline.running, isTrue);
    });

    test('a terminal event clears both running and the notice', () {
      final timeline = fold([
        ServerEvent.fromJson({
          'type': Ev.executionStarted,
          'created': 1,
          'data': {'sessionID': 'ses_x'},
        }),
        retry(error: 'boom'),
        ServerEvent.fromJson({
          'type': Ev.executionSucceeded,
          'created': 5,
          'data': {'sessionID': 'ses_x'},
        }),
      ], 'ses_x');

      expect(timeline.running, isFalse);
      expect(timeline.isRetrying, isFalse);
    });

    test('a new execution starts without the old failure', () {
      final timeline = fold([
        ServerEvent.fromJson({
          'type': Ev.executionStarted,
          'created': 1,
          'data': {'sessionID': 'ses_x'},
        }),
        retry(error: 'boom'),
        ServerEvent.fromJson({
          'type': Ev.executionStarted,
          'created': 6,
          'data': {'sessionID': 'ses_x'},
        }),
      ], 'ses_x');

      expect(timeline.running, isTrue);
      expect(timeline.isRetrying, isFalse);
    });

    test('error text degrades gracefully', () {
      Timeline withError(Object? error) => fold(
        [
          ServerEvent.fromJson({
            'type': Ev.executionStarted,
            'created': 1,
            'data': {'sessionID': 'ses_x'},
          }),
          retry(error: error),
        ],
        'ses_x',
      );

      expect(
        withError({'type': 'provider.transport'}).retryError,
        'provider.transport',
      );
      expect(withError('plain failure').retryError, 'plain failure');
      expect(
        withError(null).retryError,
        'The request failed and will be retried',
      );
    });
  });

  group('robustness', () {
    test('ignores events belonging to other sessions', () {
      final events = loadFixture('tool_calls');
      final other = fold(events, 'ses_does_not_exist');
      expect(other.messages, isEmpty);
    });

    test('ignores unknown event types instead of throwing', () {
      var timeline = const Timeline();
      timeline = applyEvent(
        timeline,
        const ServerEvent(
          id: 'evt_x',
          created: 0,
          type: 'session.something.new',
          data: {},
        ),
        sessionId: 'ses_x',
      );
      expect(timeline.messages, isEmpty);
    });

    test('a delta before its text.started does not crash', () {
      final delta = ServerEvent.fromJson({
        'type': Ev.textDelta,
        'created': 1,
        'data': {
          'sessionID': 'ses_x',
          'assistantMessageID': 'msg_x',
          'ordinal': 0,
          'delta': 'hi',
        },
      });
      final timeline = applyEvent(
        const Timeline(),
        delta,
        sessionId: 'ses_x',
      );
      expect(timeline.messages, isEmpty);
    });

    test('text blocks keep their ordinal position', () {
      final timeline = fold([
        ServerEvent.fromJson({
          'type': Ev.textStarted,
          'created': 1,
          'data': {
            'sessionID': 'ses_x',
            'assistantMessageID': 'msg_x',
            'ordinal': 0,
          },
        }),
        ServerEvent.fromJson({
          'type': Ev.reasoningStarted,
          'created': 2,
          'data': {
            'sessionID': 'ses_x',
            'assistantMessageID': 'msg_x',
            'ordinal': 1,
          },
        }),
        ServerEvent.fromJson({
          'type': Ev.reasoningDelta,
          'created': 3,
          'data': {
            'sessionID': 'ses_x',
            'assistantMessageID': 'msg_x',
            'ordinal': 1,
            'delta': 'thinking',
          },
        }),
        ServerEvent.fromJson({
          'type': Ev.textDelta,
          'created': 4,
          'data': {
            'sessionID': 'ses_x',
            'assistantMessageID': 'msg_x',
            'ordinal': 0,
            'delta': 'answer',
          },
        }),
      ], 'ses_x');

      final message = timeline.messages.whereType<AssistantMessage>().single;
      expect(message.parts[0], isA<TextPart>());
      expect((message.parts[0] as TextPart).text, 'answer');
      expect((message.parts[1] as ReasoningPart).text, 'thinking');
    });
  });

  group('message parsing', () {
    test('keeps assistant text and reasoning parts', () {
      final message = messageFromJson({
        'id': 'msg_1',
        'type': 'assistant',
        'time': {'created': 5},
        'agent': 'build',
        'model': {'id': 'kimi', 'providerID': 'opencode'},
        'content': [
          {'type': 'reasoning', 'text': 'because'},
          {'type': 'text', 'text': 'so'},
        ],
      })! as AssistantMessage;

      expect(message.agent, 'build');
      expect(message.modelId, 'kimi');
      expect(message.text, 'so');
      expect(message.parts, hasLength(2));
    });

    test('unmodelled message types survive as UnknownMessage', () {
      final message = messageFromJson({
        'id': 'msg_2',
        'type': 'compaction',
        'time': {'created': 6},
      })!;

      expect(message, isA<UnknownMessage>());
      expect((message as UnknownMessage).kind, 'compaction');
    });

    test('tool state variants map onto ToolStatus', () {
      ToolPart parse(String status) {
        final message = messageFromJson({
          'id': 'msg_3',
          'type': 'assistant',
          'time': {'created': 7},
          'agent': 'build',
          'model': {'id': 'm', 'providerID': 'p'},
          'content': [
            {
              'type': 'tool',
              'id': 'toolu_1',
              'name': 'bash',
              'time': {'created': 1},
              'state': {
                'status': status,
                'input': {'command': 'ls'},
                if (status == 'completed')
                  'content': [
                    {'type': 'text', 'text': 'ok'},
                  ],
              },
            },
          ],
        })! as AssistantMessage;
        return message.parts.whereType<ToolPart>().single;
      }

      expect(parse('completed').status, ToolStatus.completed);
      expect(parse('completed').output, 'ok');
      expect(parse('running').status, ToolStatus.running);
      expect(parse('error').status, ToolStatus.error);
    });
  });
}