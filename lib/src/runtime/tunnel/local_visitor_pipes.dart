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
    this.onProblem,
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

  /// Told when a visitor cannot be taken.
  ///
  /// A handshake that fails here is indistinguishable from a tunnel nobody is
  /// reaching, from the outside and from the log screen, so the reason has to
  /// travel.
  final void Function(String message)? onProblem;

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
        onProblem: onProblem,
      );
}

class _LocalPipe implements VisitorPipe {
  _LocalPipe._({
    required this.tlsInput,
    required StreamController<List<int>> visitorOut,
    required StreamController<List<int>> appOut,
    required this.targetHost,
    required this.targetPort,
    required this.onProblem,
  })  : _visitorBytes = visitorOut,
        _appBytes = appOut;

  static Future<_LocalPipe> open({
    required OpenConnection connection,
    required SecurityContext context,
    required String targetHost,
    required int targetPort,
    required Duration handshakeTimeout,
    required void Function(String message)? onProblem,
  }) async {
    final listener = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );

    // The handshake starts the moment something connects, and the one thing
    // that will connect is this device - so the socket the listener hands back
    // is this visitor's and no other.
    final handshake = listener.first;
    final tlsInput = await Socket.connect(
      InternetAddress.loopbackIPv4,
      listener.port,
    );
    onProblem?.call('tls terminator listening on ${listener.port}');

    final pipe = _LocalPipe._(
      tlsInput: tlsInput,
      visitorOut: StreamController<List<int>>(),
      appOut: StreamController<List<int>>(),
      targetHost: targetHost,
      targetPort: targetPort,
      onProblem: onProblem,
    );
    unawaited(pipe._completeHandshake(handshake, listener, handshakeTimeout));
    return pipe;
  }

  /// Raw bytes written here go into the TLS handshake this device performs.
  ///
  /// Writing to this starts the handshake, so this pipe has to exist - and be
  /// wired into the bridge - before the handshake finishes. Waiting for the
  /// handshake before handing the pipe back would wait for bytes nobody is
  /// forwarding yet, and the connection would simply time out.
  final Socket tlsInput;

  /// What the TLS layer produces, still encrypted, on its way to the visitor.
  SecureSocket? _tlsOutput;

  /// Bytes from the server on this phone, in the clear.
  Socket? _app;

  final String targetHost;
  final int targetPort;
  final void Function(String message)? onProblem;

  final StreamController<List<int>> _visitorBytes;
  final StreamController<List<int>> _appBytes;

  StreamSubscription<List<int>>? _visitorOut;
  StreamSubscription<List<int>>? _appIn;
  var closed = false;

  Future<void> _completeHandshake(
    Future<SecureSocket> handshake,
    SecureServerSocket listener,
    Duration timeout,
  ) async {
    try {
      final tls = await handshake.timeout(timeout);
      if (closed) {
        tls.destroy();
        return;
      }
      final app = await Socket.connect(targetHost, targetPort);
      if (closed) {
        app.destroy();
        tls.destroy();
        return;
      }
      _tlsOutput = tls;
      _app = app;

      // Encrypted, leaving this device for the visitor.
      _visitorOut = tls.listen(
        _visitorBytes.add,
        onError: (Object _) => _visitorBytes.addError(const TunnelClosed()),
        onDone: _visitorBytes.close,
        cancelOnError: false,
      );
      // Clear, from the server on this phone towards the visitor.
      _appIn = app.listen(
        _appBytes.add,
        onError: (Object _) => _appBytes.addError(const TunnelClosed()),
        onDone: _appBytes.close,
        cancelOnError: false,
      );
    } catch (error) {
      // The bridge is waiting to hear why a visitor could not be taken, and a
      // handshake that timed out is the single most common reason.
      onProblem?.call('the visitor did not complete the handshake: $error');
      if (!_visitorBytes.isClosed) _visitorBytes.addError(_HandshakeFailed(error));
      if (!_appBytes.isClosed) _appBytes.addError(_HandshakeFailed(error));
    } finally {
      await listener.close();
    }
  }

  @override
  void fromVisitor(List<int> bytes) {
    if (closed) return;
    tlsInput.add(bytes);
  }

  @override
  Stream<List<int>> get toVisitor => _visitorBytes.stream;

  @override
  void fromApp(List<int> bytes) {
    final tls = _tlsOutput;
    // Dropped rather than queued: before the handshake there is nowhere to put
    // a plaintext byte, and holding it until then would mean holding it for ever
    // if the handshake never completes.
    if (closed || tls == null) return;
    tls.add(bytes);
  }

  @override
  Stream<List<int>> get toApp => _appBytes.stream;

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _visitorOut?.cancel();
    await _appIn?.cancel();
    for (final controller in [_visitorBytes, _appBytes]) {
      if (!controller.isClosed) await controller.close();
    }
    // Shutting down for writing first gives the server a clean end of stream
    // rather than a socket that simply stopped talking.
    await _safe(destroy: () async {
      _tlsOutput?.destroy();
      _app?.destroy();
      tlsInput.destroy();
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

/// The visitor did not complete a handshake.
///
/// Carries the reason because "no handshake" on its own is the one failure
/// worth being able to tell apart from every other.
class _HandshakeFailed implements Exception {
  const _HandshakeFailed([this.reason]);

  final Object? reason;

  @override
  String toString() =>
      reason == null ? 'the visitor did not finish the handshake' : '$reason';
}

/// The connection went away underneath us.
class TunnelClosed implements Exception {
  const TunnelClosed();
}