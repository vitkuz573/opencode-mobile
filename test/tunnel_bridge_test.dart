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
      // What arrives on the bridge is what the visitor sent, so it goes into
      // this device's TLS - not back out towards the visitor.
      expect(pipes.pipeFor(7)!.fromVisitorBytes, [
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
      expect(pipes.pipeFor(1)!.fromVisitorBytes, isEmpty);
      expect(pipes.pipeFor(2)!.fromVisitorBytes, [
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
      expect(pipes.pipeFor(1)!.fromVisitorBytes, isEmpty);
      await bridge.stop();
    });

    test('sends what the server says back out over the bridge', () async {
      final bridge = await attached();
      sockets.single.open(conn: 3, sni: host);
      await pump();
      pipes.pipeFor(3)!.emitToVisitor([4, 5]);
      await pump();
      final frame = BridgeProtocol.decodeFrame(sockets.single.frames.single)!;
      expect(frame.connection, 3);
      expect(frame.payload, [4, 5]);
      await bridge.stop();
    });

    test('feeds the server what the visitor said, in the clear', () async {
      final bridge = await attached();
      sockets.single.open(conn: 3, sni: host);
      await pump();
      pipes.pipeFor(3)!.emitToApp([6]);
      await pump();
      expect(pipes.pipeFor(3)!.fromAppBytes, [
        [6],
      ]);
      await bridge.stop();
    });

    test('holds the first frames until the pipe is open', () async {
      // The service sends the ClientHello in the very next frame after
      // announcing the connection, and both can arrive in the same turn while
      // opening the pipe is still waiting on the platform. Dropping it produces
      // a handshake that simply never completes.
      final bridge = build();
      final started = bridge.start();
      await pump();
      sockets.single.accept(const {
        'type': 'attached',
        'session': 's1',
        'routes': ['@'],
      });
      await started;

      sockets.single.open(conn: 8, sni: host);
      sockets.single.binary(8, [1, 1]);
      sockets.single.binary(8, [2, 2]);
      await pump();

      expect(pipes.pipeFor(8)!.fromVisitorBytes, [
        [1, 1],
        [2, 2],
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

  group('the address', () {
    test('is a WebSocket even though the service is named over https', () async {
      // `WebSocket.connect` will not dial an https URL at all, and says nothing
      // useful when asked to. The address has to say what it is.
      Uri? opened;
      final bridge = TunnelBridge(
        tunnelId: 'abc123',
        token: 'tok',
        hostname: host,
        pipes: pipes,
        openSocket: (uri, protocols) async {
          opened = uri;
          return _FakeSocket(protocols);
        },
        attachTimeout: const Duration(milliseconds: 30),
      );
      await expectLater(bridge.start(), throwsA(isA<BridgeFailure>()));
      expect(opened!.scheme, 'wss');
      expect(opened!.path, '/api/tunnel/abc123/connect');
      await bridge.stop();
    });

    test('speaks plain ws when pointed at a plain service', () async {
      Uri? opened;
      final bridge = TunnelBridge(
        tunnelId: 'abc123',
        token: 'tok',
        hostname: host,
        pipes: pipes,
        apiBaseUrl: 'http://localhost:8080',
        openSocket: (uri, protocols) async {
          opened = uri;
          return _FakeSocket(protocols);
        },
        attachTimeout: const Duration(milliseconds: 30),
      );
      await expectLater(bridge.start(), throwsA(isA<BridgeFailure>()));
      expect(opened!.scheme, 'ws');
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

  /// Binary frames this bridge sent, kept whole so a test can decode one.
  final frames = <List<int>>[];

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
  void sendFrame(List<int> bytes) => frames.add(bytes);

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

  /// Raw bytes handed in from the bridge, as the visitor sent them.
  final fromVisitorBytes = <List<int>>[];

  /// Plain bytes handed in towards the server on this phone.
  final fromAppBytes = <List<int>>[];

  var closed = false;

  final _visitorOut = StreamController<List<int>>();
  final _appOut = StreamController<List<int>>();

  /// Encrypted bytes heading out to the visitor.
  void emitToVisitor(List<int> bytes) => _visitorOut.add(bytes);

  /// Plain bytes heading towards the visitor, before encryption.
  void emitToApp(List<int> bytes) => _appOut.add(bytes);

  @override
  void fromVisitor(List<int> bytes) => fromVisitorBytes.add(bytes);

  @override
  Stream<List<int>> get toVisitor => _visitorOut.stream;

  @override
  void fromApp(List<int> bytes) => fromAppBytes.add(bytes);

  @override
  Stream<List<int>> get toApp => _appOut.stream;

  @override
  Future<void> close() async {
    closed = true;
    if (!_visitorOut.isClosed) await _visitorOut.close();
    if (!_appOut.isClosed) await _appOut.close();
  }
}