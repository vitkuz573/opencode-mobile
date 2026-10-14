import 'dart:async';
import 'dart:io';

import 'tunnel_bridge.dart';
import 'tunnel_protocol.dart';

/// Terminates a visitor's TLS on this phone and hands the conversation to the
/// server running here.
///
/// This is the part that makes the tunnel worth having. The visitor negotiates
/// TLS with the service, which forwards only the encrypted bytes; the handshake
/// is finished here, against the certificate issued for the tunnel. Nothing
/// readable crosses the network, and the private key that reads it never left
/// this device.
///
/// The handshake is served by a listener opened per connection rather than one
/// shared by all of them. That sounds wasteful and is not: with a single
/// listener there is no way to tell which accepted connection belongs to which
/// visitor, because the ClientHello arrives on the bridge and is not
/// distinguishable from another visitor's. One listener per connection makes the
/// pairing unambiguous by construction.
class LocalVisitorPipes implements VisitorPipeFactory {
  LocalVisitorPipes({
    required this.certificateChainPem,
    required this.privateKeyPem,
    required this.targetHost,
    required this.targetPort,
    this.handshakeTimeout = const Duration(seconds: 20),
  });

  /// The tunnel certificate and its chain, leaf first.
  final List<int> certificateChainPem;

  /// The key it was issued against.
  final List<int> privateKeyPem;

  /// Where the decrypted conversation goes: the phone-hosted server.
  final String targetHost;
  final int targetPort;

  /// How long a visitor gets to finish a handshake before it is given up on.
  ///
  /// Without this a visitor that opens a connection and says nothing would hold
  /// a slot for ever, and enough of those would stop the tunnel answering.
  final Duration handshakeTimeout;

  SecurityContext? _context;

  /// Built once and reused: parsing the same certificate per visitor would be
  /// pure waste, and the context is immutable once loaded.
  Future<SecurityContext> _securityContext() async {
    final existing = _context;
    if (existing != null) return existing;
    final context = SecurityContext()
      ..useCertificateChainBytes(certificateChainPem)
      ..usePrivateKeyBytes(privateKeyPem);
    return _context = context;
  }

  @override
  Future<VisitorPipe> open(OpenConnection connection) async => _LocalPipe.open(
        connection: connection,
        context: await _securityContext(),
        targetHost: targetHost,
        targetPort: targetPort,
        handshakeTimeout: handshakeTimeout,
      );
}

class _LocalPipe implements VisitorPipe {
  _LocalPipe._({
    required this.toTls,
    required this.decrypted,
    required this.app,
    required this.visitorBytes,
    required this.appBytes,
  });

  static Future<_LocalPipe> open({
    required OpenConnection connection,
    required SecurityContext context,
    required String targetHost,
    required int targetPort,
    required Duration handshakeTimeout,
  }) async {
    final listener = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );

    SecureSocket? decrypted;
    Socket? toTls;
    try {
      // The handshake starts the moment something connects, and the one thing
      // that will connect is this device - so the socket the listener hands back
      // is this visitor's and no other.
      final handshake = listener.first;
      toTls = await Socket.connect(InternetAddress.loopbackIPv4, listener.port);
      decrypted = await handshake.timeout(
        handshakeTimeout,
        onTimeout: () => throw const _HandshakeFailed(),
      );
    } finally {
      await listener.close();
    }

    final app = await Socket.connect(targetHost, targetPort);

    final fromVisitor = StreamController<List<int>>();
    final fromApp = StreamController<List<int>>();
    final pipe = _LocalPipe._(
      toTls: toTls,
      decrypted: decrypted,
      app: app,
      visitorBytes: fromVisitor,
      appBytes: fromApp,
    );
    pipe._start();
    return pipe;
  }

  final Socket toTls;
  final SecureSocket decrypted;
  final Socket app;
  final StreamController<List<int>> visitorBytes;
  final StreamController<List<int>> appBytes;

  StreamSubscription<List<int>>? _visitorIn;
  StreamSubscription<List<int>>? _appIn;
  var closed = false;

  void _start() {
    _visitorIn = toTls.listen(
      visitorBytes.add,
      onError: (Object _) => visitorBytes.addError(const TunnelClosed()),
      onDone: visitorBytes.close,
      cancelOnError: false,
    );
    _appIn = app.listen(
      appBytes.add,
      onError: (Object _) => appBytes.addError(const TunnelClosed()),
      onDone: appBytes.close,
      cancelOnError: false,
    );
  }

  @override
  Stream<List<int>> get fromVisitor => visitorBytes.stream;

  @override
  Stream<List<int>> get fromApp => appBytes.stream;

  @override
  void toVisitor(List<int> bytes) {
    if (closed) return;
    toTls.add(bytes);
  }

  @override
  void toApp(List<int> bytes) {
    if (closed) return;
    app.add(bytes);
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _visitorIn?.cancel();
    await _appIn?.cancel();
    for (final controller in [visitorBytes, appBytes]) {
      if (!controller.isClosed) await controller.close();
    }
    // Shutting down for writing first gives the server a clean end of stream
    // rather than a socket that simply stopped talking.
    await _safe(destroy: () async {
      decrypted.destroy();
      app.destroy();
      toTls.destroy();
    });
  }

  static Future<void> _safe({required Future<void> Function() destroy}) async {
    try {
      await destroy();
    } catch (_) {
      // A socket that is already gone is the state this was aiming at.
    }
  }
}

/// The visitor did not complete a handshake in time.
class _HandshakeFailed implements Exception {
  const _HandshakeFailed();
}

/// The connection went away underneath us.
class TunnelClosed implements Exception {
  const TunnelClosed();
}