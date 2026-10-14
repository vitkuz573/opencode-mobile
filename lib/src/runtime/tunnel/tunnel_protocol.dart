import 'dart:convert';
import 'dart:typed_data';

/// The wire format of a tunnel bridge, as published in `docs/protocol.md`.
///
/// Pure on purpose. Everything here turns bytes into meaning and back, and
/// nothing here opens a socket, so the part of this feature most likely to be
/// subtly wrong can be tested without a network, a service, or a phone.
///
/// Two kinds of frame share one socket. Text carries JSON control messages.
/// Binary carries connection data: a big-endian `u32` connection id followed by
/// the payload, which is the bytes read from a visitor before TLS was
/// terminated.
class BridgeProtocol {
  const BridgeProtocol._();

  /// The WebSocket subprotocol version 1 speaks.
  static const subprotocol = 'opentunnel';

  /// The largest payload the service says it will send, and the reason a frame
  /// this size can be assumed rather than accumulated across reads: a payload
  /// over this is a protocol violation, not a large request.
  static const maxPayloadBytes = 32 * 1024;

  /// Splits a binary frame into its connection and its payload.
  ///
  /// Returns null for a frame too short to hold an id, which is the one way a
  /// peer can send something that is not a frame at all.
  static BridgeFrame? decodeFrame(List<int> bytes) {
    if (bytes.length < _idBytes) return null;
    final view = ByteData.sublistView(Uint8List.fromList(bytes));
    final connection = view.getUint32(0, Endian.big);
    return BridgeFrame(connection, Uint8List.sublistView(
      Uint8List.fromList(bytes),
      _idBytes,
      bytes.length,
    ));
  }

  static Uint8List encodeFrame(int connection, List<int> payload) {
    final out = Uint8List(_idBytes + payload.length);
    ByteData.sublistView(out).setUint32(0, connection, Endian.big);
    out.setRange(_idBytes, out.length, payload);
    return out;
  }

  static const _idBytes = 4;
}

/// One connection's worth of bytes.
class BridgeFrame {
  const BridgeFrame(this.connection, this.payload);

  /// Which visitor connection these bytes belong to.
  final int connection;

  /// The bytes as they arrived, before any decryption.
  final Uint8List payload;
}

/// A control message.
///
/// Every field the service might add is ignored rather than rejected: the
/// protocol says additive changes need no version bump precisely because a
/// client that meets an unfamiliar field carries on. An unknown *type* is a
/// different matter and is refused, since there is nothing to do with it.
sealed class BridgeMessage {
  const BridgeMessage();

  Map<String, Object?> toJson();

  /// Parses [text], or returns null for a type this app does not speak.
  static BridgeMessage? parse(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map) return null;
    final json = decoded.cast<String, Object?>();
    return switch (json['type']) {
      'attached' => Attached(
          session: _string(json, 'session') ?? '',
          routes: _strings(json['routes']),
          heartbeatMs: Duration(milliseconds: _int(json['heartbeat_ms']) ?? 15000),
          idleTimeoutMs:
              Duration(milliseconds: _int(json['idle_timeout_ms']) ?? 60000),
        ),
      'attach_error' => AttachFailure(code: _string(json, 'code') ?? 'unknown'),
      'open' => OpenConnection(
          connection: _int(json['conn']) ?? -1,
          peer: _string(json, 'peer') ?? '',
          sni: _string(json, 'sni') ?? '',
          alpn: _string(json, 'alpn'),
        ),
      'ping' => Ping(timeSent: _int(json['time_sent']) ?? 0),
      'pong' => Pong(timeSent: _int(json['time_sent']) ?? 0),
      'drain' => Drain(reason: _string(json, 'reason') ?? ''),
      'end' => End(conn: _int(json['conn']) ?? -1),
      'reset' => Reset(conn: _int(json['conn']) ?? -1, code: _int(json['code']) ?? 0),
      _ => null,
    };
  }

  static String? _string(Map<String, Object?> json, String key) {
    final value = json[key];
    return value is String ? value : null;
  }

  static int? _int(Object? value) =>
      value is int ? value : (value is num ? value.toInt() : null);

  static List<String> _strings(Object? value) => value is List
      ? value.whereType<String>().toList(growable: false)
      : const <String>[];
}

/// Sent once, immediately after the socket opens.
class Attach extends BridgeMessage {
  const Attach({
    required this.token,
    required this.routes,
    required this.maxConnections,
    this.version = 'opencode-mobile/1.0',
  });

  /// Authorises this bridge. Shown once when the tunnel was claimed.
  final String token;

  /// The route names this bridge is claiming. `@` is the tunnel host itself.
  final List<String> routes;

  /// How many visitor connections may be open at once.
  final int maxConnections;

  final String version;

  @override
  Map<String, Object?> toJson() => {
        'type': 'attach',
        'token': token,
        'transport': 'ws',
        'routes': routes,
        'client': {'version': version, 'max_conns': maxConnections},
      };
}

/// The service accepted the bridge.
class Attached extends BridgeMessage {
  const Attached({
    required this.session,
    required this.routes,
    required this.heartbeatMs,
    required this.idleTimeoutMs,
  });

  final String session;

  /// The routes this bridge ended up holding.
  final List<String> routes;

  /// How often to send a ping.
  final Duration heartbeatMs;

  /// How long the service may be silent before this session is considered gone.
  final Duration idleTimeoutMs;

  @override
  Map<String, Object?> toJson() => const {};
}

/// The service refused the bridge. Terminal.
class AttachFailure extends BridgeMessage {
  const AttachFailure({required this.code});

  final String code;

  /// Whether trying again could ever work.
  ///
  /// A bad token or an unissued certificate will not fix itself; everything
  /// else - a route held by another device, a service restart - might.
  bool get isFatal => const {'bad_token', 'cert_not_ready'}.contains(code);

  @override
  Map<String, Object?> toJson() => const {};
}

/// A visitor is connecting. Its TLS ClientHello is on the way.
class OpenConnection extends BridgeMessage {
  const OpenConnection({
    required this.connection,
    required this.peer,
    required this.sni,
    this.alpn,
  });

  final int connection;

  /// Where the visitor connected from, `ipv4:port` or `[ipv6]:port`.
  final String peer;

  /// The name in the ClientHello, and the only thing that picks the route.
  final String sni;

  final String? alpn;

  @override
  Map<String, Object?> toJson() => const {};
}

class Ping extends BridgeMessage {
  const Ping({required this.timeSent});

  final int timeSent;

  @override
  Map<String, Object?> toJson() => {'type': 'ping', 'time_sent': timeSent};
}

class Pong extends BridgeMessage {
  const Pong({required this.timeSent});

  final int timeSent;

  @override
  Map<String, Object?> toJson() => {'type': 'pong', 'time_sent': timeSent};
}

/// The service is shedding load and expects connections to end.
class Drain extends BridgeMessage {
  const Drain({required this.reason});

  final String reason;

  @override
  Map<String, Object?> toJson() => const {};
}

/// The other side half-closed. This is how a visitor finishing a request ends.
class End extends BridgeMessage {
  const End({required this.conn});

  final int conn;

  @override
  Map<String, Object?> toJson() => {'type': 'end', 'conn': conn};
}

/// The other side aborted. The connection is gone whatever it was carrying.
class Reset extends BridgeMessage {
  const Reset({required this.conn, required this.code});

  final int conn;
  final int code;

  @override
  Map<String, Object?> toJson() => const {};
}

/// Codes this app sends when refusing a connection.
abstract final class ResetCode {
  /// No route matches the name the visitor asked for.
  static const unknownRoute = 'unknown_route';

  /// The bridge is already holding as many connections as it advertised.
  static const tooManyConnections = 'too_many_connections';
}

/// The route a bridge claims for a tunnel: the tunnel host itself.
///
/// The service accepts `@` or one DNS label in front of the host; this bridge
/// has one destination, so it claims one name and answers that name and its
/// single-label forms.
List<String> routesFor(String hostname) => const ['@'];