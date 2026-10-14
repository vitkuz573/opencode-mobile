import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/runtime/tunnel/local_visitor_pipes.dart';
import 'package:opencode_mobile/src/runtime/tunnel/tls_terminator.dart';
import 'package:opencode_mobile/src/runtime/tunnel/tunnel_bridge.dart';
import 'package:opencode_mobile/src/runtime/tunnel/tunnel_protocol.dart';

void main() {
  late _FakeTerminator terminator;
  late LocalVisitorPipes pipes;
  late List<String> problems;
  late ServerSocket server;

  /// Swallows a stream's outcome at the end of a test so an expected error is
  /// not reported again as a failure of whatever ran next.
  void drain(Future<Object?> pending) => addTearDown(
        () => pending.then<void>((_) {}, onError: (Object _) {}),
      );

  setUp(() async {
    terminator = _FakeTerminator();
    problems = [];
    // Stands in for the server running on this phone: the one thing a pipe has
    // to reach once a handshake is out of the way.
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    pipes = LocalVisitorPipes(
      terminator: terminator,
      targetHost: '127.0.0.1',
      targetPort: server.port,
      handshakeTimeout: const Duration(milliseconds: 200),
      onProblem: problems.add,
    );
  });

  tearDown(() async {
    await pipes.dispose();
    await terminator.dispose();
    await server.close();
  });

  Future<VisitorPipe> openOne({int id = 7}) => pipes.open(
        OpenConnection(connection: id, peer: '203.0.113.9:51000', sni: 'abc123'),
      );

  /// Wires a pipe the way the bridge wires one.
  (StreamSubscription<List<int>>, StreamSubscription<List<int>>) wired(
    VisitorPipe pipe,
  ) =>
      (
        pipe.toVisitor.listen((_) {}),
        pipe.toApp.listen(pipe.fromApp),
      );

  group('what the visitor says', () {
    test('reaches the TLS session that is serving it', () async {
      final pipe = await openOne();

      pipe.fromVisitor([1, 2, 3]);
      await pumpEventQueue();

      expect(terminator.fromVisitorFor(7), [
        [1, 2, 3],
      ]);
    });

    test('does not reach another visitor', () async {
      // Two visitors' ClientHellos are indistinguishable on the bridge. If one
      // ever reached the other's session it would be served a certificate, and a
      // handshake, that belong to a different visitor entirely.
      final mine = await openOne(id: 7);
      final other = await openOne(id: 8);
      final subscriptions = wired(mine);
      final others = wired(other);
      addTearDown(() async {
        await subscriptions.$1.cancel();
        await subscriptions.$2.cancel();
        await others.$1.cancel();
        await others.$2.cancel();
      });

      mine.fromVisitor([9]);
      await pumpEventQueue();

      expect(terminator.fromVisitorFor(7), hasLength(1));
      expect(terminator.fromVisitorFor(8), isEmpty);
    });
  });

  group('what the TLS layer says', () {
    test('is offered to the visitor', () async {
      final pipe = await openOne();
      final seen = pipe.toVisitor.first;
      drain(seen);

      terminator.toVisitor(7, [4, 5]);

      expect(await seen, [4, 5]);
    });

    test('is given to the server once the handshake is done', () async {
      await openOne();
      final atServer = server.first.timeout(const Duration(seconds: 2));

      terminator.say(7, const TlsReady(7));
      terminator.say(
        7,
        TlsToApp(7, Uint8List.fromList('GET / HTTP/1.1'.codeUnits)),
      );

      expect(await _read(await atServer), 'GET / HTTP/1.1');
    });

    test('is held, not lost, when it arrives before the server is open', () async {
      await openOne();
      final atServer = server.first.timeout(const Duration(seconds: 2));

      terminator.say(7, TlsToApp(7, Uint8List.fromList('GET / HTTP/1.1'.codeUnits)));
      terminator.say(7, const TlsReady(7));

      expect(await _read(await atServer), 'GET / HTTP/1.1');
    });

    test('is not sent back to the visitor it came from', () async {
      // Both directions are in the clear once TLS is done with them, and they
      // are opposite: a visitor's request that went back out here would be
      // handed to the visitor that sent it instead of to the server.
      final pipe = await openOne();
      final seen = pipe.toVisitor.first;
      drain(seen);

      terminator.say(7, TlsToApp(7, Uint8List.fromList([1, 2, 3])));
      await pumpEventQueue();

      expect(terminator.fromAppFor(7), isEmpty);
    });

    test('opens the phone-hosted server once the handshake is done', () async {
      await openOne();
      final arriving = server.first.timeout(const Duration(seconds: 2));

      terminator.say(7, const TlsReady(7));

      expect(await arriving, isNotNull);
    });
  });

  test('wired as the bridge wires it, a request gets an answer', () async {
    // The whole shape of a visit, end to end through the pipe: encrypted bytes
    // in, clear text to the server, the server's answer encrypted on the way
    // back.
    final pipe = await openOne();
    final subscriptions = wired(pipe);
    addTearDown(() async {
      await subscriptions.$1.cancel();
      await subscriptions.$2.cancel();
    });
    final atServer = server.first.timeout(const Duration(seconds: 2));

    terminator.say(7, const TlsReady(7));
    terminator.say(7, TlsToApp(7, Uint8List.fromList('GET / HTTP/1.1'.codeUnits)));

    final request = await atServer;
    expect(await _read(request), 'GET / HTTP/1.1');

    request.write('HTTP/1.1 200 OK');
    await pumpEventQueue();

    expect(terminator.fromAppFor(7), [
      'HTTP/1.1 200 OK'.codeUnits,
    ]);
  });

  group('a visitor that cannot be served', () {
    test('is given up on, and the reason is reported', () async {
      // Otherwise the tunnel owes the service a slot for ever, and enough of
      // those stop it answering anyone.
      final pipe = await openOne();
      final refused = pipe.toVisitor.first;

      await expectLater(
        refused,
        throwsA(
          predicate<Object>((error) => error.toString().contains('handshake')),
        ),
      );
      expect(problems.join(), contains('handshake'));
    });

    test('says why when the TLS layer refuses', () async {
      final pipe = await openOne();
      final refused = pipe.toVisitor.first;

      terminator.say(7, const TlsFailed(7, 'certificate rejected'));

      await expectLater(
        refused,
        throwsA(
          predicate<Object>(
            (error) => error.toString().contains('certificate rejected'),
          ),
        ),
      );
      expect(problems.join(), contains('certificate rejected'));
    });

    test('is dropped when the tunnel closes the session', () async {
      final pipe = await openOne();
      var closed = false;
      unawaited(pipe.close().then((_) => closed = true));

      terminator.say(7, const TlsClosed(7));
      await pumpEventQueue();

      expect(closed, isTrue);
    });
  });

  group('closing', () {
    test('tells the TLS layer to end that session', () async {
      final pipe = await openOne();

      await pipe.close();

      expect(terminator.closed, [7]);
    });

    test('ends every session the factory opened', () async {
      await openOne(id: 7);
      await openOne(id: 8);

      await pipes.dispose();

      expect(terminator.closed, containsAllInOrder([7, 8]));
    });

    test('finishes even when nothing was ever listening', () async {
      // A single-subscription controller holds its done event back until a
      // listener takes it. Waiting on one that will never come is how stopping a
      // published tunnel used to hang for good.
      await openOne();

      await pipes.dispose().timeout(const Duration(seconds: 2));
    });

    test('says nothing more to a visitor that has gone', () async {
      final pipe = await openOne();
      await pipe.close();

      pipe.fromVisitor([1]);

      expect(terminator.fromVisitorFor(7), isEmpty);
    });
  });
}

/// The first thing a socket said, as text.
///
/// These conversations are HTTP, written in ASCII on purpose: a test that
/// compared bytes to a string would only pass by coincidence.
Future<String> _read(Socket socket) async =>
    String.fromCharCodes(await socket.first.timeout(const Duration(seconds: 2)));

/// A TLS layer that answers only what a test tells it to.
class _FakeTerminator implements TlsTerminator {
  final _events = StreamController<TlsEvent>.broadcast();
  final fromVisitorBy = <int, List<List<int>>>{};
  final fromAppBy = <int, List<List<int>>>{};
  final closed = <int>[];

  List<List<int>> fromVisitorFor(int connection) =>
      fromVisitorBy[connection] ?? const [];

  List<List<int>> fromAppFor(int connection) => fromAppBy[connection] ?? const [];

  void toVisitor(int connection, List<int> bytes) =>
      _events.add(TlsToVisitor(connection, Uint8List.fromList(bytes)));

  void say(int connection, TlsEvent event) => _events.add(event);

  @override
  Stream<TlsEvent> get events => _events.stream;

  @override
  Future<void> prepare({
    required String certificateChainPem,
    required String privateKeyPem,
  }) async {}

  @override
  Future<void> start(int connection) async {}

  @override
  Future<void> fromVisitor(int connection, List<int> bytes) async =>
      (fromVisitorBy[connection] ??= []).add(bytes);

  @override
  Future<void> fromApp(int connection, List<int> bytes) async =>
      (fromAppBy[connection] ??= []).add(bytes);

  @override
  Future<void> close(int connection) async => closed.add(connection);

  Future<void> dispose() => _events.close();
}