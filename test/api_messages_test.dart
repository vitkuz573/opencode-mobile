import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/data/api.dart';
import 'package:opencode_mobile/src/data/models.dart';

void main() {
  late _FakeTransport transport;
  late OpenCodeApi api;

  setUp(() {
    transport = _FakeTransport();
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:4096'))
      ..httpClientAdapter = transport;
    api = OpenCodeApi(dio);
  });

  Map<String, Object?> user(String id, int at) => {
        'id': id,
        'type': 'user',
        'time': {'created': at},
        'text': 'question $id',
      };

  Map<String, Object?> assistant(String id, int at) => {
        'id': id,
        'type': 'assistant',
        'time': {'created': at},
        'agent': 'build',
        'model': {'id': 'mimo-v2.5-free', 'providerID': 'opencode'},
        'finish': 'stop',
        'cost': 0,
        'tokens': {
          'input': 1,
          'output': 1,
          'reasoning': 0,
          'cache': {'read': 0, 'write': 0},
        },
        'content': [
          {'type': 'text', 'text': 'answer $id'},
        ],
      };

  test('reads a conversation in the order it happened', () async {
    // Shape and ordering taken from a live GET /api/session/<id>/message on
    // 2026-10-15: the server answers newest first.
    transport.reply({
      'data': [
        assistant('msg_3', 300),
        user('msg_2', 200),
        assistant('msg_1', 100),
      ],
    });

    final messages = await api.messages('ses_1');

    expect(
      messages.map((m) => m.id).toList(),
      ['msg_1', 'msg_2', 'msg_3'],
      reason: 'a conversation that reads bottom to top is worse than none',
    );
  });

  test('leaves the order alone when the server already sends it oldest first',
      () async {
    transport.reply({
      'data': [
        user('msg_1', 100),
        assistant('msg_2', 200),
      ],
    });

    final messages = await api.messages('ses_1');

    expect(messages.map((m) => m.id).toList(), ['msg_1', 'msg_2']);
  });

  test('keeps a question and its answer in the right order', () async {
    transport.reply({
      'data': [
        assistant('msg_answer', 400),
        user('msg_question', 300),
      ],
    });

    final messages = await api.messages('ses_1');

    expect((messages.first as UserMessage).text, 'question msg_question');
    expect((messages.last as AssistantMessage).text, 'answer msg_answer');
  });
}

class _FakeTransport implements HttpClientAdapter {
  final List<Object> _answers = [];

  void reply(Map<String, Object?> body) => _answers.add(body);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_answers.isEmpty) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      );
    }
    return ResponseBody.fromString(
      jsonEncode(_answers.removeAt(0)),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}