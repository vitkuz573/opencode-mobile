import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'models.dart';

/// One frame from `GET /api/event`.
///
/// The published OpenAPI document types this payload as an opaque string and
/// enumerates no event types, so the envelope is parsed leniently and the
/// per-type payloads are read through [data].
class ServerEvent {
  const ServerEvent({
    required this.id,
    required this.created,
    required this.type,
    required this.data,
    this.directory,
    this.seq,
  });

  factory ServerEvent.fromJson(Map<String, Object?> json) {
    final durable = json['durable'];
    final durableMap = durable is Map ? durable.cast<String, Object?>() : null;
    final location = json['location'];
    final locationMap = location is Map
        ? location.cast<String, Object?>()
        : null;
    final data = json['data'];
    final created = json['created'];
    return ServerEvent(
      id: json['id'] is String ? json['id']! as String : '',
      created: created is num ? created.toInt() : 0,
      type: json['type'] is String ? json['type']! as String : '',
      data: data is Map ? data.cast<String, Object?>() : const {},
      directory: locationMap?['directory'] as String?,
      seq: durableMap?['seq'] is num
          ? (durableMap!['seq']! as num).toInt()
          : null,
    );
  }

  final String id;
  final int created;
  final String type;
  final Map<String, Object?> data;
  final String? directory;
  final int? seq;

  String get sessionId =>
      data['sessionID'] is String ? data['sessionID']! as String : '';

  String get messageId => data['assistantMessageID'] is String
      ? data['assistantMessageID']! as String
      : '';

  String get toolId => data['id'] is String ? data['id']! as String : '';
}

/// Event type strings, grouped by the concern they drive in the UI.
abstract final class Ev {
  static const serverConnected = 'server.connected';
  static const projectUpdated = 'project.updated';

  // Note: there is no `session.updated` or `session.error` event on the wire
  // (verified against the 2.0.28 schema). Rename and delete have their own
  // types; failures arrive as `session.retry.scheduled` and the terminal
  // `session.execution.failed`.
  static const sessionCreated = 'session.created';
  static const sessionRenamed = 'session.renamed';
  static const sessionDeleted = 'session.deleted';

  static const executionStarted = 'session.execution.started';
  static const executionSucceeded = 'session.execution.succeeded';
  static const executionInterrupted = 'session.execution.interrupted';

  /// A terminal failure. Unlike a retry, nothing follows it: the spinner must
  /// stop and the error must show. Payload: `{sessionID, error{type, message,
  /// status?, response?}}`.
  static const executionFailed = 'session.execution.failed';

  static const textStarted = 'session.text.started';
  static const textDelta = 'session.text.delta';
  static const textEnded = 'session.text.ended';

  static const reasoningStarted = 'session.reasoning.started';
  static const reasoningDelta = 'session.reasoning.delta';
  static const reasoningEnded = 'session.reasoning.ended';

  static const toolInputStarted = 'session.tool.input.started';
  static const toolInputDelta = 'session.tool.input.delta';
  static const toolInputEnded = 'session.tool.input.ended';
  static const toolCalled = 'session.tool.called';
  static const toolProgress = 'session.tool.progress';
  static const toolSuccess = 'session.tool.success';
  static const toolFailed = 'session.tool.failed';

  /// Emitted when an attempt fails and the server schedules another one. The
  /// execution is still alive — this is the difference between "working" and
  /// "stuck", and the client must show it instead of spinning silently.
  static const retryScheduled = 'session.retry.scheduled';

  /// A finished compaction. History on the server was replaced, so anything
  /// rendered from before it is stale. Payload carries the summary, not the
  /// messages; the client refetches.
  static const compactionEnded = 'session.compaction.ended';

  static const usageUpdated = 'session.usage.updated';
  static const permissionAsked = 'permission.asked';
  static const permissionReplied = 'permission.replied';

  static const formCreated = 'form.created';
  static const formReplied = 'form.replied';
  static const formCancelled = 'form.cancelled';
}

enum StreamStatus { idle, connecting, live, retrying, failed }

class EventStreamStatus {
  const EventStreamStatus(this.status, {this.message, this.attempt = 0});

  final StreamStatus status;
  final String? message;
  final int attempt;

  bool get isLive => status == StreamStatus.live;
}

class StreamException implements Exception {
  const StreamException(this.message);

  final String message;

  @override
  String toString() => 'EventStream: $message';
}

/// Collects decoded text from [Utf8Decoder] into the parser's buffer.
class _StringSink implements Sink<String> {
  _StringSink(this.buffer);

  final StringBuffer buffer;

  @override
  void add(String data) => buffer.write(data);

  @override
  void close() {}
}

/// SSE transport with bounded exponential backoff.
///
/// The server sends every event to every connected client and there is no
/// replay for live-only subscribers, so exactly one subscription is opened for
/// the whole app and fanned out above it.
class EventStream {
  EventStream({required Dio dio, this.maxAttempts = 6})
    // A private field cannot be a named parameter of a public constructor, so
    // the argument stays public and is assigned in the initialiser list.
    // ignore: prefer_initializing_formals
    : _dio = dio,
      _controller = StreamController<ServerEvent>.broadcast(),
      _statusController = StreamController<EventStreamStatus>.broadcast();

  final Dio _dio;
  final int maxAttempts;
  final StreamController<ServerEvent> _controller;
  final StreamController<EventStreamStatus> _statusController;

  Stream<ServerEvent> get events => _controller.stream;
  Stream<EventStreamStatus> get status => _statusController.stream;

  Future<void>? _running;
  bool _stopped = false;

  Future<void> start() {
    _stopped = false;
    return _running ??= _run();
  }

  Future<void> stop() async {
    _stopped = true;
    await _running;
    _running = null;
  }

  Future<void> _run() async {
    var attempt = 0;
    while (!_stopped) {
      _statusController.add(
        EventStreamStatus(
          attempt == 0 ? StreamStatus.connecting : StreamStatus.retrying,
          attempt: attempt,
        ),
      );
      try {
        final response = await _dio.get<ResponseBody>(
          '/api/event',
          options: Options(
            responseType: ResponseType.stream,
            headers: const {'Accept': 'text/event-stream'},
            // The stream is long lived: never let dio time it out.
            receiveTimeout: null,
            sendTimeout: null,
          ),
        );
        final body = response.data;
        if (body == null) throw const StreamException('empty response');
        attempt = 0;
        _statusController.add(
          const EventStreamStatus(StreamStatus.live),
        );
        await _consume(body.stream);
      } catch (error) {
        if (_stopped) break;
        attempt++;
        _statusController.add(
          EventStreamStatus(
            attempt >= maxAttempts ? StreamStatus.failed : StreamStatus.retrying,
            message: '$error',
            attempt: attempt,
          ),
        );
        if (attempt >= maxAttempts) break;
        await Future<void>.delayed(_backoff(attempt));
      }
    }
  }

  Duration _backoff(int attempt) {
    const base = 500;
    final millis = base * (1 << (attempt - 1).clamp(0, 5));
    return Duration(milliseconds: millis.clamp(base, 15000));
  }

  Future<void> _consume(Stream<Uint8List> stream) async {
    final frames = SseParser();
    await for (final chunk in stream) {
      for (final payload in frames.add(chunk)) {
        final decoded = _tryDecode(payload);
        if (decoded != null) _controller.add(decoded);
      }
    }
  }

  ServerEvent? _tryDecode(String payload) {
    try {
      final json = jsonDecode(payload);
      if (json is! Map) return null;
      return ServerEvent.fromJson(json.cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
    await _statusController.close();
  }
}

/// Incremental SSE frame parser. Frames are separated by a blank line; each may
/// carry several `data:` lines that concatenate with newlines, per the spec.
class SseParser {
  final StringBuffer _buffer = StringBuffer();

  /// Chunked conversion keeps a multi-byte character intact when a TCP read
  /// splits it across two chunks, which decoding per chunk would corrupt.
  late final ByteConversionSink _decoder =
      const Utf8Decoder().startChunkedConversion(_StringSink(_buffer));

  Iterable<String> add(List<int> chunk) sync* {
    _decoder.add(chunk);
    final frames = <String>[];

    var text = _buffer.toString();
    int index;
    while ((index = _indexOfFrameBreak(text)) >= 0) {
      final raw = text.substring(0, index);
      text = text.substring(index + _frameBreakLength(text, index));
      final payload = _dataOf(raw);
      if (payload != null && payload.isNotEmpty) frames.add(payload);
    }

    _buffer
      ..clear()
      ..write(text);
    yield* frames;
  }

  static int _frameBreakLength(String text, int index) {
    // Handles \n\n and \r\n\r\n.
    return index + 1 < text.length && text[index + 1] == '\r' ? 4 : 2;
  }

  static int _indexOfFrameBreak(String text) {
    final lf = text.indexOf('\n\n');
    final crlf = text.indexOf('\r\n\r\n');
    if (lf < 0) return crlf;
    if (crlf < 0) return lf;
    return lf < crlf ? lf : crlf;
  }

  static String? _dataOf(String rawFrame) {
    final lines = const LineSplitter().convert(rawFrame);
    final data = <String>[];
    for (final line in lines) {
      if (line.startsWith('data:')) {
        data.add(line.substring(5).trimLeft());
      }
    }
    return data.isEmpty ? null : data.join('\n');
  }
}

/// Permission requests are the one thing the client must never miss, so they
/// get their own typed view over the same stream.
extension PermissionEvents on ServerEvent {
  PermissionRequest? get asPermissionRequest {
    if (type != Ev.permissionAsked) return null;
    return PermissionRequest.fromEventData(data);
  }
}