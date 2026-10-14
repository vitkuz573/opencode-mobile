import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/runtime/tunnel/tunnel_bridge.dart';
import 'package:opencode_mobile/src/runtime/tunnel/tunnel_protocol.dart';

void main() {
  const host = 'abc123.opentunnel.xyz';

  late List<_FakeSocket> sockets;
  late _FakePipes pipes;

  TunnelBridge build({
    int maxConnections = 16,
    Duration attachTimeout = const Duration(seconds: 2),
    Duration reconnectFloor = const Duration(milliseconds: 1),
    Duration reconnectCeiling = const Duration(milliseconds: 2),
  }) =>
      TunnelBridge(
        tunnelId: 'abc123',
        token: 'tok',
        hostname: host,
        pipes: pipes,
        openSocket: (uri, protocols) async {
          final socket = _FakeSocket(protocols);
          sockets.add(socket);
          return socket;
        },
        maxConnections: maxConnections,
        attachTimeout: attachTimeout,
        reconnectFloor: reconnectFloor,
        reconnectCeiling: reconnectCeiling,
      );

  setUp(() {
    sockets = [];
    pipes = _FakePipes();
  });

  /// A bridge that has attached, with its heartbeat slow enough not to fire.
  Future<TunnelBridge> attached([
    Map<String, Object?> extra = const {},
  ]) async {
    final bridge = build();
    final started = bridge.start();
    await pump();
    sockets.single.accept({
      'type': 'attached',
      'session': 's1',
      'routes': ['@'],
      'heartbeat_ms': 600000,
      'idle_timeout_ms': 600000,
      ...extra,
    });
    await started;
    return bridge;
  }

  group('attaching', () {
    test('says who it is and what it is claiming', () async {
      await attached();
      final sent = sockets.single.sent.map(jsonDecode).toList();
      expect(sent.first['type'], 'attach');
      expect(sent.first['token'], 'tok');
      expect(sent.first['routes'], ['@']);
      expect((sent.first['client']! as Map)['max_conns'], 16);
    });

    test('offers the subprotocol the service negotiates on', () async {
      final bridge = build();
      final started = bridge.start();
      await pump();
      expect(sockets.single.protocols, ['opentunnel']);
      sockets.single.accept(const {'type': 'attached', 'session': 's'});
      await started;
      await bridge.stop();
    });

    test('reports a refusal instead of retrying for ever', () async {
      final bridge = build();
      final started = bridge.start();
      await pump();
      final refusal =
          expectLater(started, throwsA(isA<BridgeFailure>()));
      sockets.single.accept(const {'type': 'attach_error', 'code': 'bad_token'});
      await refusal;
      await pump(const Duration(milliseconds: 40));
      // One socket, not a stream of them: a rejected token cannot become valid.
      expect(sockets, hasLength(1));
      await bridge.stop();
    });

    test('gives up on a service that never answers', () async {
      final bridge = build(attachTimeout: const Duration(milliseconds: 20));
      await expectLater(bridge.start(), throwsA(isA<BridgeFailure>()));
      await bridge.stop();
    });
  });

  group('routes', () {
    test('admits the tunnel host', () async {
      final bridge = await attached();
      sockets.single.open(conn: 1, sni: host);
      await pump();
      expect(pipes.opened.single.connection, 1);
      await bridge.stop();
    });

    test('admits one label in front of it', () async {
      final bridge = await attached();
      sockets.single.open(conn: 1, sni: 'api.$host');
      await pump();
      expect(pipes.opened, hasLength(1));
      await bridge.stop();
    });

    test('refuses a deeper name, which is somebody else\'s host', () async {
      final bridge = await attached();
      sockets.single.open(conn: 1, sni: 'a.b.$host');
      await pump();
      expect(pipes.opened, isEmpty);
      expect(
        _resetsOf(sockets.single).map((r) => r['code']),
        contains(ResetCode.unknownRoute),
      );
      await bridge.stop();
    });

    test('refuses a host that is not ours at all', () async {
      final bridge = await attached();
      sockets.single.open(conn: 1, sni: 'example.com');
      await pump();
      expect(pipes.opened, isEmpty);
      await bridge.stop();
    });

    test('refuses a visitor with no name at all', () async {
      final bridge = await attached();
      sockets.single.open(conn: 1, sni: '');
      await pump();
      expect(pipes.opened, isEmpty);
      await bridge.stop();
    });
  });

  group('connections', () {
    test('carries a frame to the connection it belongs to', () async {
      final bridge = await attached();
      sockets.single.open(conn: 7, sni: host);
      await pump();
      sockets.single.binary(7, [1, 2, 3]);
      await pump();
      expect(pipes.pipeFor(7)!.toVisitorBytes, [
        [1, 2, 3],
      ]);
      await bridge.stop();
    });

    test('does not carry one connection\'s bytes to another', () async {
      final bridge = await attached();
      sockets.single.open(conn: 1, sni: host);
      sockets.single.open(conn: 2, sni: host);
      await pump();
      sockets.single.binary(2, [9]);
      await pump();
      expect(pipes.pipeFor(1)!.toVisitorBytes, isEmpty);
      expect(pipes.pipeFor(2)!.toVisitorBytes, [
        [9],
      ]);
      await bridge.stop();
    });

    test('ignores a frame that is not one', () async {
      final bridge = await attached();
      sockets.single.open(conn: 1, sni: host);
      await pump();
      sockets.single.binaryBytes([1, 2]);
      await pump();
      expect(pipes.pipeFor(1)!.toVisitorBytes, isEmpty);
      await bridge.stop();
    });

    test('sends what the server says back to the visitor, encrypted', () async {
      final bridge = await attached();
      sockets.single.open(conn: 3, sni: host);
      await pump();
      pipes.pipeFor(3)!.emitFromApp([4, 5]);
      await pump();
      expect(pipes.pipeFor(3)!.toVisitorBytes, [
        [4, 5],
      ]);
      await bridge.stop();
    });

    test('passes the visitor\'s bytes to the server in the clear', () async {
      final bridge = await attached();
      sockets.single.open(conn: 3, sni: host);
      await pump();
      pipes.pipeFor(3)!.emitFromVisitor([6]);
      await pump();
      expect(pipes.pipeFor(3)!.toAppBytes, [
        [6],
      ]);
      await bridge.stop();
    });

    test('turns away one more visitor than it advertised', () async {
      final bridge = await attached();
      for (var i = 0; i < 16; i++) {
        sockets.single.open(conn: i, sni: host);
      }
      await pump();
      sockets.single.open(conn: 99, sni: host);
      await pump();
      expect(pipes.opened, hasLength(16));
      expect(
        _resetsOf(sockets.single).map((r) => r['code']),
        contains(ResetCode.tooManyConnections),
      );
      await bridge.stop();
    });

    test('closes the pipe when the service ends the connection', () async {
      final bridge = await attached();
      sockets.single.open(conn: 4, sni: host);
      await pump();
      sockets.single.accept({'type': 'end', 'conn': 4});
      await pump();
      expect(pipes.pipeFor(4)!.closed, isTrue);
      expect(bridge.openConnections, 0);
      await bridge.stop();
    });

    test('closes the pipe when the service resets the connection', () async {
      final bridge = await attached();
      sockets.single.open(conn: 5, sni: host);
      await pump();
      sockets.single.accept({'type': 'reset', 'conn': 5, 'code': 1006});
      await pump();
      expect(pipes.pipeFor(5)!.closed, isTrue);
      await bridge.stop();
    });

    test('refuses a visitor it cannot open a pipe for', () async {
      final bridge = await attached();
      pipes.failNext = true;
      sockets.single.open(conn: 6, sni: host);
      await pump();
      expect(
        _resetsOf(sockets.single).map((r) => r['code']),
        contains(ResetCode.unknownRoute),
      );
      await bridge.stop();
    });
  });

  group('staying connected', () {
    test('answers a ping with a pong carrying the same time', () async {
      final bridge = await attached();
      sockets.single.accept({'type': 'ping', 'time_sent': 4242});
      await pump();
      final pong = sockets.single.sent
          .map(jsonDecode)
          .firstWhere((m) => m['type'] == 'pong');
      expect(pong['time_sent'], 4242);
      await bridge.stop();
    });

    test('comes back when the socket drops', () async {
      final bridge = build();
      final started = bridge.start();
      await pump();
      sockets.single.accept(const {'type': 'attached', 'session': 's1'});
      await started;

      sockets.single.drop();
      await pump(const Duration(milliseconds: 60));

      expect(sockets.length, greaterThan(1));
      await bridge.stop();
    });

    test('closes every visitor when it stops', () async {
      final bridge = await attached();
      sockets.single.open(conn: 1, sni: host);
      sockets.single.open(conn: 2, sni: host);
      await pump();
      await bridge.stop();
      expect(pipes.pipes.every((p) => p.closed), isTrue);
    });
  });
}

/// Let queued microtasks and timers run.
Future<void> pump([Duration wait = const Duration(milliseconds: 5)]) =>
    Future<void>.delayed(wait);

List<Map<String, dynamic>> _resetsOf(_FakeSocket socket) => socket.sent
    .map(jsonDecode)
    .where((m) => m['type'] == 'reset')
    .cast<Map<String, dynamic>>()
    .toList();

class _FakeSocket implements BridgeSocket {
  _FakeSocket(this.protocols);

  final _controller = StreamController<Object>();
  final sent = <String>[];
  final List<String> protocols;
  var closed = false;

  void accept(Map<String, Object?> json) {
    if (_controller.isClosed) return;
    _controller.add(jsonEncode(json));
  }

  void open({required int conn, required String sni}) => _controller.add(
        jsonEncode({'type': 'open', 'conn': conn, 'peer': '1.2.3.4:9', 'sni': sni}),
      );

  void binary(int conn, List<int> payload) =>
      _controller.add(BridgeProtocol.encodeFrame(conn, payload));

  void binaryBytes(List<int> bytes) => _controller.add(bytes);

  void drop() => _controller.close();

  @override
  Stream<Object> get events => _controller.stream;

  @override
  void send(String text) => sent.add(text);

  @override
  Future<void> close() async {
    closed = true;
    if (!_controller.isClosed) await _controller.close();
  }
}

class _FakePipes extends VisitorPipeFactory {
  final pipes = <_FakePipe>[];
  final opened = <OpenConnection>[];
  var failNext = false;

  _FakePipe? pipeFor(int conn) {
    for (final pipe in pipes) {
      if (pipe.conn == conn) return pipe;
    }
    return null;
  }

  @override
  Future<VisitorPipe> open(OpenConnection connection) async {
    if (failNext) {
      failNext = false;
      throw StateError('no pipe');
    }
    opened.add(connection);
    final pipe = _FakePipe(connection.connection);
    pipes.add(pipe);
    return pipe;
  }
}

class _FakePipe implements VisitorPipe {
  _FakePipe(this.conn);

  final int conn;
  final toVisitorBytes = <List<int>>[];
  final toAppBytes = <List<int>>[];
  var closed = false;

  final _fromVisitor = StreamController<List<int>>();
  final _fromApp = StreamController<List<int>>();

  @override
  Stream<List<int>> get fromVisitor => _fromVisitor.stream;

  @override
  Stream<List<int>> get fromApp => _fromApp.stream;

  void emitFromVisitor(List<int> bytes) => _fromVisitor.add(bytes);

  void emitFromApp(List<int> bytes) => _fromApp.add(bytes);

  @override
  void toVisitor(List<int> bytes) => toVisitorBytes.add(bytes);

  @override
  void toApp(List<int> bytes) => toAppBytes.add(bytes);

  @override
  Future<void> close() async {
    closed = true;
    if (!_fromVisitor.isClosed) await _fromVisitor.close();
    if (!_fromApp.isClosed) await _fromApp.close();
  }
}