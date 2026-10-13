import 'dart:async';
import 'dart:io';

/// An HTTP CONNECT proxy on loopback, for the phone-hosted server.
///
/// The musl resolver is blind on Android (no /etc/resolv.conf, no root to
/// create one), so the server cannot resolve any external host — every model
/// call dies with ETIMEOUT. The server binary cannot be taught new DNS, but
/// it honors the standard proxy variables, and a proxy address that is an IP
/// literal needs no resolution at all. So the app runs this tiny relay next
/// to the server: the server tunnels TLS through it, and this side resolves
/// with the platform resolver, which works.
///
/// Only CONNECT is implemented. Model APIs are all HTTPS, and anything else
/// gets an honest 405 rather than a hang. Only loopback clients are accepted,
/// which is the authentication: nothing off the device can reach it.
class ConnectProxy {
  ServerSocket? _server;

  /// The port it listens on, or null when stopped.
  int? get port => _server?.port;

  bool get isRunning => _server != null;

  /// Starts listening. Idempotent: a running proxy just reports its port.
  Future<int> start() async {
    final existing = _server;
    if (existing != null) return existing.port;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handle, onError: (_) {});
    return server.port;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close();
  }

  static const _maxHeaderBytes = 65536;

  Future<void> _handle(Socket client) async {
    // One subscription per socket for its whole life: single-subscription
    // streams throw on a second listen, even after a cancel. Headers are read
    // with the subscription paused afterwards, then the same subscription is
    // retargeted at the upstream socket for the relay.
    final buffer = <int>[];
    final ready = Completer<bool>();
    late final StreamSubscription<List<int>> sub;
    sub = client.listen(
      (chunk) {
        buffer.addAll(chunk);
        if (buffer.length > _maxHeaderBytes || _endsHeaders(buffer)) {
          if (!ready.isCompleted) ready.complete(true);
        }
      },
      onError: (Object _, [StackTrace? _]) {
        if (!ready.isCompleted) ready.complete(false);
      },
      onDone: () {
        if (!ready.isCompleted) ready.complete(false);
      },
      cancelOnError: true,
    );
    final timer = Timer(const Duration(seconds: 15), () {
      if (!ready.isCompleted) ready.complete(false);
    });
    final headersOk = await ready.future;
    timer.cancel();
    if (!headersOk || buffer.isEmpty || !_endsHeaders(buffer)) {
      await sub.cancel();
      client.destroy();
      return;
    }
    sub.pause();

    String request;
    try {
      request = String.fromCharCodes(buffer);
    } catch (_) {
      await sub.cancel();
      client.destroy();
      return;
    }
    final target = _connectTarget(request);
    if (target == null) {
      client.add(_response(405, 'use CONNECT'));
      await client.flush();
      await sub.cancel();
      client.destroy();
      return;
    }
    final (host, port) = target;
    Socket upstream;
    try {
      upstream = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 15),
      );
    } catch (_) {
      client.add(_response(502, 'cannot reach $host:$port'));
      await client.flush();
      await sub.cancel();
      client.destroy();
      return;
    }
    client.add(_response(200, 'ok'));
    await client.flush();

    void closeBoth() {
      try {
        client.destroy();
      } catch (_) {}
      try {
        upstream.destroy();
      } catch (_) {}
    }

    sub.onData(upstream.add);
    sub.onError((Object _, [StackTrace? _]) => closeBoth());
    sub.onDone(closeBoth);
    upstream.listen(
      client.add,
      onError: (Object _, [StackTrace? _]) => closeBoth(),
      onDone: closeBoth,
      cancelOnError: true,
    );
    // Bytes that arrived with the headers were already consumed by the header
    // reader; pause() cannot unread them, so they go upstream explicitly.
    // (A CONNECT client normally waits for the 200 first, but pipelining is
    // legal and dropping it would corrupt the tunnel.)
    final bodyStart = _headerEnd(buffer)!;
    if (bodyStart < buffer.length) {
      upstream.add(buffer.sublist(bodyStart));
    }
    sub.resume();
  }

  bool _endsHeaders(List<int> buffer) => _headerEnd(buffer) != null;

  /// Index just past the blank line ending the headers, or null.
  int? _headerEnd(List<int> buffer) {
    if (buffer.length < 4) return null;
    for (var i = 0; i + 3 < buffer.length; i++) {
      if (buffer[i] == 13 &&
          buffer[i + 1] == 10 &&
          buffer[i + 2] == 13 &&
          buffer[i + 3] == 10) {
        return i + 4;
      }
    }
    return null;
  }

  /// The CONNECT target, or null for anything that is not one.
  (String, int)? _connectTarget(String request) {
    final firstLine = request.split('\r\n').firstOrNull?.trim() ?? '';
    final parts = firstLine.split(' ');
    if (parts.length < 2 || parts[0] != 'CONNECT') return null;
    final hostPort = parts[1];
    if (hostPort.isEmpty) return null;
    // Strip a scheme if someone sends an absolute URI; the host:port tail is
    // what matters.
    final authority = hostPort.contains('://')
        ? hostPort.split('://').last
        : hostPort;
    final host = authority.split(':').first;
    if (host.isEmpty) return null;
    final port = authority.contains(':')
        ? int.tryParse(authority.split(':').last)
        : 443;
    if (port == null || port < 1 || port > 65535) return null;
    return (host, port);
  }

  List<int> _response(int status, String message) =>
      'HTTP/1.1 $status $message\r\n\r\n'.codeUnits;
}
