import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'tunnel_protocol.dart';

/// One visitor, from the moment the service says it is connecting to the moment
/// it is gone.
///
/// The names say which way bytes travel, because getting that wrong produces a
/// tunnel that accepts every connection and silently carries nonsense, which is
/// much harder to notice than one that refuses them.
///
/// Everything crossing the bridge in binary is the visitor's TLS, untouched.
/// Everything on the far side of [toApp] and [fromApp] is in the clear, and is
/// the only part of the conversation the service never sees.
abstract class VisitorPipe {
  /// Bytes arriving from the visitor, still encrypted. Fed into TLS here.
  void fromVisitor(List<int> bytes);

  /// Bytes on their way to the visitor, already encrypted for it.
  Stream<List<int>> get toVisitor;

  /// Bytes arriving from the server on this phone, in the clear.
  void fromApp(List<int> bytes);

  /// Bytes on their way to the visitor once encrypted, in the clear until then.
  Stream<List<int>> get toApp;

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

  /// A binary frame: connection id and payload, already framed by the caller.
  void sendFrame(List<int> bytes);

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
  void sendFrame(List<int> bytes) => _socket.add(bytes);

  @override
  Future<void> close() async => _socket.close();
}

/// What the bridge is doing, for whoever is watching.
enum BridgeState { idle, connecting, attached, reconnecting, stopped }

/// The part of a bridge the controller drives.
///
/// Narrower than [TunnelBridge] on purpose: what the controller needs to start
/// and stop a tunnel should not also be the thing that a test has to reimplement
/// to stand in for one.
abstract class TunnelBridgeHandle {
  Stream<BridgeState> get states;

  Future<void> start();

  Future<void> stop();
}

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
class TunnelBridge implements TunnelBridgeHandle {
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
    this.onProblem,
    this.onNotice,
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

  /// Told about anything that goes wrong below.
  ///
  /// A visitor refused is not an error the person holding the phone can do
  /// anything about, but it is the only clue when a tunnel is published and
  /// nothing can reach it - and "nothing arrives" is otherwise indistinguishable
  /// from "the address is wrong".
  final void Function(String message)? onProblem;

  /// Told about the ordinary course of a bridge: connected, attached, a visitor
  /// arriving.
  ///
  /// A tunnel that is published and unreachable looks identical from the
  /// outside whether the bridge never connected or the service never routed to
  /// it, and telling those apart is the whole diagnosis.
  final void Function(String message)? onNotice;

  final Random _random;
  final String _host;

  final _live = <int, _Live>{};

  /// Frames for a connection whose pipe is still being opened.
  final _held = <int, List<List<int>>>{};

  /// How many frames are held for a connection that never opens.
  static const _maxHeldFrames = 8;
  final _controller = StreamController<BridgeState>.broadcast();

  BridgeSocket? _socket;
  Completer<void>? _closed;
  Timer? _heartbeat;
  Timer? _idle;
  Duration _backoff = const Duration(milliseconds: 250);
  BridgeState _state = BridgeState.idle;
  bool _stopping = false;

  BridgeState get state => _state;

  @override
  Stream<BridgeState> get states => _controller.stream;

  /// Visitors connected right now, for a status line.
  int get openConnections => _live.length;

  /// The bridge is a WebSocket, and the address has to say so.
  ///
  /// `WebSocket.connect` will not take an `https` URL at all - not as an error,
  /// just as an address it cannot dial - so the scheme is swapped rather than
  /// assumed, and a plain `http` base (used in tests, and by anyone pointing
  /// this at a service of their own) becomes `ws`.
  Uri get _endpoint {
    final base = Uri.parse(apiBaseUrl);
    final scheme = switch (base.scheme) {
      'https' || 'wss' => 'wss',
      _ => 'ws',
    };
    return base.replace(scheme: scheme, path: '/api/tunnel/$tunnelId/connect');
  }

  /// Connects and stays connected until [stop].
  ///
  /// Returns once the service has accepted the bridge, so a caller can say the
  /// tunnel is live rather than that it is being attempted.
  @override
  Future<void> start() async {
    _stopping = false;
    final ready = Completer<void>();
    unawaited(_loop(ready));
    await ready.future;
  }

  /// Closes the socket and every visitor, and does not come back.
  @override
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

  Future<void> _retry(Completer<void> firstAttach, Object error) async {
    if (_stopping) return;
    final failure = error is BridgeFailure
        ? error
        : BridgeFailure('The tunnel could not be reached: $error');
    if (failure.isFinal) {
      // Retrying would only arrive at the same refusal.
      if (!firstAttach.isCompleted) firstAttach.completeError(failure);
      return;
    }
    if (!firstAttach.isCompleted) firstAttach.completeError(failure);
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
    onNotice?.call('bridge connected to $_endpoint');

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
      onNotice?.call(
        'bridge attached as ${value.session}, holding ${value.routes}',
      );
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
    final pipe = _live[frame.connection]?.pipe;
    if (pipe == null) {
      // The service sends the ClientHello in the very next frame after
      // announcing the connection, and both can arrive in the same turn - while
      // opening the pipe is still waiting on the platform. Held until then,
      // because a handshake that never receives its first bytes looks exactly
      // like one that is being refused.
      final held = _held.putIfAbsent(frame.connection, () => <List<int>>[]);
      // Bounded: a visitor that announces and says nothing must not be able
      // to fill this device's memory.
      if (held.length < _maxHeldFrames) held.add(frame.payload);
      onNotice?.call(
        'holding ${frame.payload.length} bytes for connection '
        '${frame.connection} until its pipe opens',
      );
      return;
    }
    pipe.fromVisitor(frame.payload);
  }

  /// Brings one visitor in: refused with a reason if it should not be here,
  /// wired both ways if it should.
  Future<void> _open(OpenConnection open) async {
    if (_live.length >= maxConnections) {
      onProblem?.call(
        'turned away a visitor on ${open.sni}: already holding '
        '$maxConnections connections',
      );
      _refuse(open.connection, ResetCode.tooManyConnections);
      return;
    }
    if (!_serves(open.sni)) {
      onProblem?.call('turned away ${open.sni}: not a name this tunnel serves');
      _refuse(open.connection, ResetCode.unknownRoute);
      return;
    }

    final VisitorPipe pipe;
    try {
      pipe = await pipes.open(open);
      onNotice?.call(
        'visitor on ${open.sni} (connection ${open.connection}) is through',
      );
    } catch (error) {
      onProblem?.call(
        'could not take a visitor on ${open.sni} (connection ${open.connection}): '
        '$error',
      );
      _refuse(open.connection, ResetCode.unknownRoute);
      return;
    }

    final live = _Live(pipe);
    _live[open.connection] = live;

    // Whatever arrived while the pipe was being opened goes in first, in the
    // order it arrived. The handshake cannot start without it.
    final held = _held.remove(open.connection);
    if (held != null) {
      for (final bytes in held) {
        pipe.fromVisitor(bytes);
      }
      onNotice?.call(
        'fed ${held.length} held frames (${held.fold<int>(0, (n, f) => n + f.length)} '
        'bytes) into connection ${open.connection}',
      );
    }

    // What this device hands back after encrypting for the visitor: straight
    // out over the bridge, tagged with the connection it belongs to.
    live.outbound = pipe.toVisitor.listen(
      (bytes) => _sendFrame(open.connection, bytes),
      onDone: () => _send(End(conn: open.connection).toJson()),
      onError: (Object _) =>
          _refuse(open.connection, ResetCode.unknownRoute),
      cancelOnError: false,
    );

    // What the server on this phone says, in the clear, on its way to be
    // encrypted. An empty write is how a half-close is expressed: the service
    // ends a connection the same way, and both sides have to be told.
    live.inbound = pipe.toApp.listen(
      pipe.fromApp,
      onDone: () => pipe.fromApp(const <int>[]),
      onError: (Object _) => unawaited(_close(open.connection)),
      cancelOnError: false,
    );
  }

  void _sendFrame(int conn, List<int> bytes) {
    try {
      _socket?.sendFrame(BridgeProtocol.encodeFrame(conn, bytes));
    } catch (_) {
      // The socket is on its way out; the reconnect loop deals with it.
    }
  }

  Future<void> _close(int conn, {int? code, bool sendEnd = true}) async {
    final live = _live.remove(conn);
    _held.remove(conn);
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
    _held.clear();
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

  /// Carrying bytes out to the visitor.
  StreamSubscription<List<int>>? outbound;

  /// Carrying bytes in from the server on this phone.
  StreamSubscription<List<int>>? inbound;

  Future<void> cancel() async {
    await outbound?.cancel();
    await inbound?.cancel();
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