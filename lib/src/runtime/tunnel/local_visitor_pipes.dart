import 'dart:async';
import 'dart:io';

import 'tls_terminator.dart';
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
/// Each connection gets a session of its own, because the ClientHello arrives
/// on the bridge and cannot be told apart from another visitor's. A session
/// shared between connections would have no way to be matched to the visitor it
/// belongs to.
class LocalVisitorPipes implements VisitorPipeFactory {
  LocalVisitorPipes({
    required this.terminator,
    required this.targetHost,
    required this.targetPort,
    this.handshakeTimeout = const Duration(seconds: 20),
    this.onProblem,
  });

  /// Where the decrypted conversation goes: the phone-hosted server.
  final String targetHost;
  final int targetPort;

  /// Who finishes the handshake, and with what.
  final TlsTerminator terminator;

  /// How long a visitor gets to finish a handshake before it is given up on.
  ///
  /// Without this a visitor that opens a connection and says nothing holds a
  /// slot for ever, and enough of those stop the tunnel answering anyone.
  final Duration handshakeTimeout;

  /// Told when a visitor cannot be taken.
  ///
  /// A handshake that fails here is indistinguishable from a tunnel nobody is
  /// reaching, from the outside and from the log screen, so the reason has to
  /// travel.
  final void Function(String message)? onProblem;

  final Map<int, _LocalPipe> _live = {};

  StreamSubscription<TlsEvent>? _fromTerminator;

  var _watching = false;

  /// Routes the terminator's events to the session they belong to.
  void _watch() {
    if (_watching) return;
    _watching = true;
    _fromTerminator = terminator.events.listen((event) {
      switch (event) {
        case TlsToVisitor(:final connection, :final bytes):
          _live[connection]?._toVisitor.add(bytes);
        case TlsToApp(:final connection, :final bytes):
          _live[connection]?._toServer(bytes);
        case TlsReady(:final connection):
          _live[connection]?._handshakeComplete();
        case TlsFailed(:final connection, :final reason):
          _live[connection]?._handshakeFailed(reason);
        case TlsClosed(:final connection):
          unawaited(_live[connection]?.close());
      }
    });
  }

  @override
  Future<VisitorPipe> open(OpenConnection connection) async {
    _watch();
    final pipe = _LocalPipe(
      id: connection.connection,
      terminator: terminator,
      targetHost: targetHost,
      targetPort: targetPort,
      handshakeTimeout: handshakeTimeout,
      onProblem: onProblem,
      onClosed: () => _live.remove(connection.connection),
    );
    _live[connection.connection] = pipe;
    try {
      // Awaited so the session exists on the platform before the bridge can
      // hand this pipe a byte: without that, the visitor's ClientHello would
      // arrive at a session that has not been opened yet.
      await terminator.start(connection.connection);
    } catch (error) {
      onProblem?.call('could not open a TLS session: $error');
    }
    return pipe;
  }

  /// Ends every session this factory opened.
  Future<void> dispose() async {
    await _fromTerminator?.cancel();
    _fromTerminator = null;
    _watching = false;
    for (final pipe in _live.values.toList(growable: false)) {
      await pipe.close();
    }
  }
}

class _LocalPipe implements VisitorPipe {
  _LocalPipe({
    required this.id,
    required this.terminator,
    required this.targetHost,
    required this.targetPort,
    required this.handshakeTimeout,
    required this.onProblem,
    required this.onClosed,
  })  : _toVisitor = StreamController<List<int>>(),
        _toApp = StreamController<List<int>>() {
    // A visitor that says nothing is not a visitor that is slow: without this
    // the tunnel owes the service a slot for ever.
    _stalled = Timer(handshakeTimeout, _handshakeFailed);
  }

  final int id;
  final TlsTerminator terminator;
  final String targetHost;
  final int targetPort;
  final Duration handshakeTimeout;
  final void Function(String message)? onProblem;
  final void Function() onClosed;

  /// Encrypted, on its way back to the visitor.
  final StreamController<List<int>> _toVisitor;

  /// In the clear, on its way to the visitor once encrypted by [fromApp].
  ///
  /// This carries what the phone-hosted server says. What the *visitor* says,
  /// also in the clear once the TLS layer is finished with it, goes straight
  /// into the socket to that server instead: the two are opposite directions,
  /// and sending a visitor's request back out here would hand it straight back
  /// to the visitor that sent it.
  final StreamController<List<int>> _toApp;

  /// The phone-hosted server, once a handshake has been out of the way.
  Socket? _server;

  /// Visitor bytes decrypted, waiting for that server to exist.
  ///
  /// Held rather than dropped: the TLS layer can finish a handshake and hand
  /// over a request in the same breath, and a request that arrived first would
  /// otherwise be the one thing this visitor never got answered.
  final List<List<int>> _waitingForServer = [];

  StreamSubscription<List<int>>? _fromServer;
  Timer? _stalled;
  var closed = false;

  /// Gives decrypted bytes to the phone-hosted server.
  void _toServer(List<int> bytes) {
    if (closed) return;
    final server = _server;
    if (server == null) {
      // Bounded for the same reason the bridge bounds held frames: a visitor
      // that sends a great deal before the handshake finishes must not be able
      // to fill this device's memory.
      if (_waitingForServer.length < _maxWaiting) _waitingForServer.add(bytes);
      return;
    }
    server.add(bytes);
  }

  @override
  void fromVisitor(List<int> bytes) {
    if (closed) return;
    unawaited(terminator.fromVisitor(id, bytes));
  }

  @override
  Stream<List<int>> get toVisitor => _toVisitor.stream;

  @override
  void fromApp(List<int> bytes) {
    if (closed) return;
    unawaited(terminator.fromApp(id, bytes));
  }

  @override
  Stream<List<int>> get toApp => _toApp.stream;

  /// Called by the factory once the platform says the handshake is done.
  Future<void> _handshakeComplete() async {
    if (closed) return;
    _stalled?.cancel();
    _stalled = null;
    try {
      final server = await Socket.connect(targetHost, targetPort);
      if (closed) {
        server.destroy();
        return;
      }
      _server = server;
      _fromServer = server.listen(
        _toApp.add,
        onError: (Object _) => _toApp.addError(const TunnelClosed()),
        onDone: _toApp.close,
        cancelOnError: false,
      );
      for (final waiting in _waitingForServer) {
        if (closed) return;
        server.add(waiting);
      }
      _waitingForServer.clear();
    } catch (error) {
      onProblem?.call('the phone-hosted server refused a visitor: $error');
      await close();
    }
  }

  void _handshakeFailed([Object? reason]) {
    if (closed) return;
    final why = reason ?? 'the visitor did not finish the handshake';
    onProblem?.call('the visitor did not complete the handshake: $why');
    _stalled = null;
    // Only where somebody is listening. An error handed to a stream with no
    // listener is stored, never delivered, and surfaces later as a failure of
    // whatever happened to be running by then - which is how a handshake that
    // timed out could take down an unrelated test.
    final failure = _HandshakeFailed(why);
    if (_toVisitor.hasListener) _toVisitor.addError(failure);
    if (_toApp.hasListener) _toApp.addError(failure);
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    _stalled?.cancel();
    _stalled = null;
    onClosed();
    unawaited(terminator.close(id));
    await _fromServer?.cancel();
    for (final controller in [_toVisitor, _toApp]) {
      if (controller.isClosed) continue;
      // A single-subscription controller holds its done event back until a
      // listener takes it, and one that has already gone will not come back.
      // Waiting on that is waiting for ever, which is how stopping a published
      // tunnel used to hang. Read it before closing, because closing is what
      // settles the question.
      final waited = controller.hasListener;
      final closing = controller.close();
      if (waited) await closing;
    }
    // Shut down for writing first, so the server gets a clean end of stream
    // rather than a socket that simply stopped talking.
    try {
      _server?.destroy();
    } catch (_) {
      // A socket that is already gone is the state this was aiming at.
    }
    _server = null;
  }
}

/// How much a visitor may say before the server on this phone is reachable.
///
/// Enough for any request a client sends immediately after a handshake and far
/// too little for one to matter.
const _maxWaiting = 64;

/// The visitor did not complete a handshake.
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