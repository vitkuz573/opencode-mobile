import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/runtime/connect_proxy.dart';

/// ATCP server that echoes every chunk straight back.
class _Echo {
  ServerSocket? server;

  Future<int> start() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server!.listen((client) {
      client.listen(
        client.add,
        onError: (_, [_]) => client.destroy(),
        onDone: () => client.destroy(),
      );
    });
    return server!.port;
  }

  Future<void> stop() async => server?.close();
}

/// Reads until [marker] shows up, with a deadline. The relay holds both ends
/// open, so waiting for the stream to close would wait forever.
Future<String> _readUntil(
  Socket client,
  String marker, {
  Duration limit = const Duration(seconds: 10),
}) async {
  final buffer = <int>[];
  final done = Completer<void>();
  late final StreamSubscription<List<int>> sub;
  sub = client.listen(
    (chunk) {
      buffer.addAll(chunk);
      if (String.fromCharCodes(buffer).contains(marker) &&
          !done.isCompleted) {
        done.complete();
      }
    },
    onError: (Object _, [StackTrace? _]) {
      if (!done.isCompleted) done.complete();
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
  );
  await done.future.timeout(limit);
  await sub.cancel();
  return String.fromCharCodes(buffer);
}

Future<String> _request(int proxyPort, String request) async {
  final client = await Socket.connect(
    InternetAddress.loopbackIPv4,
    proxyPort,
  );
  client.add(request.codeUnits);
  await client.flush();
  final reply = await _readUntil(client, '\r\n\r\n');
  client.destroy();
  return reply;
}

void main() {
  late ConnectProxy proxy;

  setUp(() async {
    proxy = ConnectProxy();
    await proxy.start();
  });

  tearDown(() => proxy.stop());

  test('relays a CONNECT tunnel byte for byte', () async {
    final echo = _Echo();
    addTearDown(echo.stop);
    final echoPort = await echo.start();

    // One subscription for the whole check: the headers and the relayed
    // payload arrive on the same stream.
    const payload = 'hello-through-tunnel';
    final client = await Socket.connect(
      InternetAddress.loopbackIPv4,
      proxy.port!,
    );
    client.add(
      'CONNECT 127.0.0.1:$echoPort HTTP/1.1\r\n'
      'Host: 127.0.0.1:$echoPort\r\n\r\n'
      '$payload'
      .codeUnits,
    );
    await client.flush();
    final all = await _readUntil(client, payload);
    client.destroy();
    expect(all, startsWith('HTTP/1.1 200'));
    expect(all, contains(payload));
  });

  test('answers 405 to anything that is not CONNECT', () async {
    final reply = await _request(
      proxy.port!,
      'GET http://example.test/ HTTP/1.1\r\nHost: example.test\r\n\r\n',
    );

    expect(reply, startsWith('HTTP/1.1 405'));
  });

  test('answers 502 for an unreachable target', () async {
    // Port 1 is privileged: nothing answers there.
    final reply = await _request(
      proxy.port!,
      'CONNECT 127.0.0.1:1 HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n',
    );

    expect(reply, startsWith('HTTP/1.1 502'));
  });

  test('start is idempotent and stop releases the port', () async {
    final first = await proxy.start();
    final second = await proxy.start();
    expect(second, first);

    await proxy.stop();
    expect(proxy.port, isNull);

    final restarted = await proxy.start();
    expect(restarted, isNotNull);
  });
}
