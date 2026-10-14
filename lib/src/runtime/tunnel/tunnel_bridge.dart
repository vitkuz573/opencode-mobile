import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'tunnel_protocol.dart';

/// One visitor, from the moment the service says it is connecting to the moment
/// it is gone.
///
/// Two conversations sit behind it. [fromVisitor] and [toVisitor] carry the TLS
/// the visitor negotiated - exactly what crosses the bridge untouched.
/// [fromApp] and [toApp] carry the same conversation after this device
/// terminated TLS with the tunnel certificate, and are the only part of it the
/// service never sees.
abstract class VisitorPipe {
  /// Bytes arriving from the visitor, still encrypted.
  Stream<List<int>> get fromVisitor;

  /// Bytes going to the visitor, encrypted with the tunnel certificate.
  void toVisitor(List<int> bytes);

  /// Bytes arriving from the phone's server, decrypted.
  Stream<List<int>> get fromApp;

  /// Bytes going to the phone's server, in the clear.
  void toApp(List<int> bytes);

  Future<void> close();
}

/// Opens a [VisitorPipe] for a connection the service announced.
///
/// Behind an interface because the bridge's own rules - who may connect, what
/// happens to their bytes, what happens when the socket drops - are worth
/// testing without a certificate, a socket or a phone, and this is the only
/// part that needs all three.
abstract class VisitorPipeFactory {
  Future<VisitorPipe> open(OpenConnection connection);
}

/// The socket to the service, behind an interface for the same reason.
abstract class BridgeSocket {
  /// Text frames carry control messages; binary frames carry connection data.
  Stream<Object> get events;

  void send(String text);

  Future<void> close();
}

/// Opens the socket to the service.
typedef BridgeSocketOpener = Future<BridgeSocket> Function(
  Uri uri,
  List<String> protocols,
);

/// Connects over `dart:io`, which already speaks subprotocols - the service
/// selects a version by name, so offering only `opentunnel` is the whole of
/// version negotiation for version 1.
Future<BridgeSocket> openTunnelSocket(Uri uri, List<String> protocols) async {
  final socket = await WebSocket.connect(
    uri.toString(),
    protocols: protocols,
  ).timeout(const Duration(seconds: 20));
  return _WebSocketSocket(socket);
}

class _WebSocketSocket implements BridgeSocket {
  _WebSocketSocket(this._socket);

  final WebSocket _socket;

  @override
  Stream<Object> get events => _socket.cast<Object>();

  @override
  void send(String text) => _socket.add(text);

  @override
  Future<void> close() async => _socket.close();
}

/// What the bridge is doing, for whoever is watching.
enum BridgeState { idle, connecting, attached, reconnecting, stopped }

/// A live bridge to a tunnel.
///
/// The service hands out an opaque hostname and forwards whatever a visitor
/// sends to whichever client claims the route. This claims it, terminates the
/// visitor's TLS here, and passes the decrypted conversation to the server on
/// this phone.
///
/// It survives what it can: a dropped socket is retried with backoff, because a
/// tunnel that blinks is worse than one that waits. It does not retry what
/// cannot fix itself - a token the service rejects, a certificate it has not
/// issued - and says so instead of reconnecting to the same failure.
class TunnelBridge {
  TunnelBridge({
    required this.tunnelId,
    required this.token,
    required this.hostname,
    required this.pipes,
    BridgeSocketOpener? openSocket,
    this.apiBaseUrl = 'https://opentunnel.xyz',
    this.maxConnections = 16,
    this.idleTimeoutFallback = const Duration(minutes: 1),
    this.attachTimeout = const Duration(seconds: 10),
    this.reconnectFloor = const Duration(milliseconds: 250),
    this.reconnectCeiling = const Duration(seconds: 30),
    Random? random,
  })  : _openSocket = openSocket ?? openTunnelSocket,
        _random = random ?? Random(),
        _host = _bareHost(hostname);

  final String tunnelId;
  final String token;

  /// The name the service issued, and the only one this bridge answers for.
  final String hostname;

  final VisitorPipeFactory pipes;
  final BridgeSocketOpener _openSocket;
  final String apiBaseUrl;

  /// How many visitors may be connected at once. Advertised on attach, so the
  /// service turns away the ones that would exceed it instead of being told
  /// afterwards.
  final int maxConnections;

  final Duration idleTimeoutFallback;
  final Duration attachTimeout;
  final Duration reconnectFloor;
  final Duration reconnectCeiling;

  final Random _random;
  final String _host;

  final _live = <int, _Live>{};
  final _controller = StreamController<BridgeState>.broadcast();

  BridgeSocket? _socket;
  Completer<void>? _closed;
  Timer? _heartbeat;
  Timer? _idle;
  Duration _backoff = const Duration(milliseconds: 250);
  BridgeState _state = BridgeState.idle;
  bool _stopping = false;

  BridgeState get state => _state;

  Stream<BridgeState> get states => _controller.stream;

  /// Visitors connected right now, for a status line.
  int get openConnections => _live.length;

  Uri get _endpoint => Uri.parse('$apiBaseUrl/api/tunnel/$tunnelId/connect');

  /// Connects and stays connected until [stop].
  ///
  /// Returns once the service has accepted the bridge, so a caller can say the
  /// tunnel is live rather than that it is being attempted.
  Future<void> start() async {
    _stopping = false;
    final ready = Completer<void>();
    unawaited(_loop(ready));
    await ready.future;
  }

  /// Closes the socket and every visitor, and does not come back.
  Future<void> stop() async {
    _stopping = true;
    _heartbeat?.cancel();
    _idle?.cancel();
    final closing = _closed;
    await _socket?.close();
    // A socket whose close does not complete the stream would leave the loop
    // waiting for ever, so stopping says so directly.
    if (closing != null && !closing.isCompleted) closing.complete();
    _socket = null;
    await _closeAll();
    _emit(BridgeState.stopped);
    await _controller.close();
  }

  /// One iteration of connect, serve, and on failure wait before trying again.
  Future<void> _loop(Completer<void> firstAttach) async {
    final Attached attached;
    try {
      attached = await _attach();
    } catch (error) {
      _emit(BridgeState.reconnecting);
      await _retry(firstAttach, error);
      return;
    }

    _backoff = reconnectFloor;
    _heartbeat = Timer.periodic(attached.heartbeatMs, (_) => _send(
          Ping(timeSent: DateTime.now().millisecondsSinceEpoch).toJson(),
        ));
    _emit(BridgeState.attached);
    if (!firstAttach.isCompleted) firstAttach.complete();

    // Stay on the socket until it ends, which is the only signal available
    // that the connection is gone: no close frame, and no keepalive of our own
    // that the service is obliged to answer.
    await _closed?.future;
    _heartbeat?.cancel();
    _idle?.cancel();
    if (_stopping) return;
    _emit(BridgeState.reconnecting);
    await _retry(
      firstAttach,
      const BridgeFailure('The tunnel connection dropped.'),
    );
  }

  Future<void> _retry(Completer<void> firstAttach, Object error) {
    if (_stopping) return Future<void>.value();
    if (error is BridgeFailure && error.isFinal) {
      // Retrying would only arrive at the same refusal.
      if (!firstAttach.isCompleted) firstAttach.completeError(error);
      return Future<void>.value();
    }
    if (!firstAttach.isCompleted) {
      firstAttach.completeError(
        const BridgeFailure('The tunnel could not be reached.'),
      );
    }
    final wait = _jittered(_backoff);
    _backoff = Duration(
      milliseconds: min(
        _backoff.inMilliseconds * 2,
        reconnectCeiling.inMilliseconds,
      ),
    );
    return Future<void>.delayed(wait, () {
      if (!_stopping) unawaited(_loop(firstAttach));
    });
  }

  /// Half to all of [base], so a service that drops everyone at once does not
  /// get everyone back at the same instant.
  Duration _jittered(Duration base) {
    final half = base.inMilliseconds ~/ 2;
    return Duration(milliseconds: half + _random.nextInt(half + 1));
  }

  /// Connects, attaches, and installs the handlers. Returns the heartbeat the
  /// service asked for.
  Future<Attached> _attach() async {
    _emit(_state == BridgeState.idle ? BridgeState.connecting : _state);
    final socket = await _openSocket(_endpoint, const [BridgeProtocol.subprotocol]);
    _socket = socket;

    final attached = Completer<Attached>();
    var idle = idleTimeoutFallback;
    // One subscription for the socket's whole life: it is a single-subscription
    // stream, and the wait for it to end reads this rather than listening a
    // second time.
    final closed = Completer<void>();
    _closed = closed;

    socket.events.listen(
      (event) {
        _idle?.cancel();
        _idle = Timer(idle, socket.close);
        if (event is String) {
          _onControl(event, attached);
        } else if (event is List<int>) {
          _onFrame(event);
        }
      },
      onError: (Object _) {},
      onDone: () {
        if (!closed.isCompleted) closed.complete();
        if (!attached.isCompleted) {
          attached.completeError(
            const BridgeFailure('The tunnel connection closed before it was ready.'),
          );
        }
      },
      cancelOnError: false,
    );

    socket.send(
      jsonEncode(
        Attach(
          token: token,
          routes: routesFor(hostname),
          maxConnections: maxConnections,
        ).toJson(),
      ),
    );

    try {
      final value = await attached.future.timeout(attachTimeout);
      idle = value.idleTimeoutMs;
      return value;
    } on TimeoutException {
      await socket.close();
      throw const BridgeFailure('The tunnel service did not answer in time.');
    }
  }

  void _onControl(String text, Completer<Attached> attached) {
    final message = BridgeMessage.parse(text);
    switch (message) {
      case Attached():
        if (!attached.isCompleted) attached.complete(message);
      case AttachFailure():
        if (!attached.isCompleted) {
          attached.completeError(
            BridgeFailure(
              message.isFatal
                  ? 'The tunnel service refused this device: ${message.code}.'
                  : 'The tunnel service could not take the route: ${message.code}.',
              isFinal: message.isFatal,
            ),
          );
        }
      case OpenConnection():
        unawaited(_open(message));
      case Ping():
        _send(Pong(timeSent: message.timeSent).toJson());
      case End():
        unawaited(_close(message.conn, sendEnd: false));
      case Reset():
        unawaited(_close(message.conn, code: message.code));
      case Attach():
      case Drain():
      case Pong():
      case null:
        break;
    }
  }

  void _onFrame(List<int> bytes) {
    final frame = BridgeProtocol.decodeFrame(bytes);
    if (frame == null) return;
    _live[frame.connection]?.pipe.toVisitor(frame.payload);
  }

  /// Brings one visitor in: refused with a reason if it should not be here,
  /// wired both ways if it should.
  Future<void> _open(OpenConnection open) async {
    if (_live.length >= maxConnections) {
      _refuse(open.connection, ResetCode.tooManyConnections);
      return;
    }
    if (!_serves(open.sni)) {
      _refuse(open.connection, ResetCode.unknownRoute);
      return;
    }

    final VisitorPipe pipe;
    try {
      pipe = await pipes.open(open);
    } catch (_) {
      _refuse(open.connection, ResetCode.unknownRoute);
      return;
    }

    final live = _Live(pipe);
    _live[open.connection] = live;

    // From the phone's server, decrypted, encrypted towards the visitor.
    live.toVisitor = pipe.fromApp.listen(
      pipe.toVisitor,
      onDone: () => _send(End(conn: open.connection).toJson()),
      onError: (Object _) =>
          _refuse(open.connection, ResetCode.unknownRoute),
      cancelOnError: false,
    );

    // From the visitor, encrypted, decrypted towards the phone's server. An
    // empty write is how a half-close is expressed: the service ends a
    // connection the same way, and both sides have to be told.
    live.fromVisitor = pipe.fromVisitor.listen(
      pipe.toApp,
      onDone: () => pipe.toApp(const <int>[]),
      onError: (Object _) => unawaited(_close(open.connection)),
      cancelOnError: false,
    );
  }

  Future<void> _close(int conn, {int? code, bool sendEnd = true}) async {
    final live = _live.remove(conn);
    if (live == null) return;
    await live.cancel();
    await live.pipe.close();
    if (code != null) {
      _send({'type': 'reset', 'conn': conn, 'code': code});
    } else if (sendEnd) {
      _send(End(conn: conn).toJson());
    }
  }

  Future<void> _closeAll() async {
    final open = _live.values.toList(growable: false);
    _live.clear();
    for (final live in open) {
      await live.cancel();
      await live.pipe.close();
    }
  }

  /// Whether a name the visitor asked for is one this tunnel serves.
  ///
  /// The host itself, or exactly one label in front of it - never deeper.
  /// Answering a deeper name would mean serving a host this device has no
  /// business serving.
  bool _serves(String sni) {
    if (sni.isEmpty) return false;
    final host = _bareHost(sni);
    if (host == _host) return true;
    if (!host.endsWith('.$_host')) return false;
    final label = host.substring(0, host.length - _host.length - 1);
    return label.isNotEmpty && !label.contains('.');
  }

  static String _bareHost(String name) => Uri.tryParse('https://$name')?.host ?? name;

  void _send(Map<String, Object?> json) {
    try {
      _socket?.send(jsonEncode(json));
    } catch (_) {
      // The socket is on its way out; the reconnect loop deals with it.
    }
  }

  /// Refusing a visitor. The reason is a name, not a number: it is what the
  /// service logs, and what makes a refusal explainable afterwards.
  void _refuse(int conn, String code) =>
      _send({'type': 'reset', 'conn': conn, 'code': code});

  void _emit(BridgeState next) {
    if (_state == next) return;
    _state = next;
    if (!_controller.isClosed) _controller.add(next);
  }
}

/// A pipe and the subscriptions draining it, so closing one connection is one
/// call and cannot leave half of it running.
class _Live {
  _Live(this.pipe);

  final VisitorPipe pipe;
  StreamSubscription<List<int>>? toVisitor;
  StreamSubscription<List<int>>? fromVisitor;

  Future<void> cancel() async {
    await toVisitor?.cancel();
    await fromVisitor?.cancel();
  }
}

/// Something about the tunnel stopped working, said so a person can act on.
class BridgeFailure implements Exception {
  const BridgeFailure(this.message, {this.isFinal = false});

  final String message;

  /// Whether trying again could ever work. A rejected token or an unissued
  /// certificate will not fix itself, and reconnecting to it is a loop.
  final bool isFinal;

  @override
  String toString() => message;
}