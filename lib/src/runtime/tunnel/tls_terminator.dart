import 'dart:async';

import 'package:flutter/services.dart';

/// Something the tunnel's TLS layer said about one connection.
///
/// A single stream carries every connection's events, tagged with the connection
/// they belong to: one channel rather than one per visitor means a visitor that
/// cannot be served does not take a channel with it.
sealed class TlsEvent {
  const TlsEvent(this.connection);

  /// Which visitor this is about, as the tunnel service numbers them.
  final int connection;
}

/// Encrypted bytes travelling back to the visitor.
class TlsToVisitor extends TlsEvent {
  const TlsToVisitor(super.connection, this.bytes);

  final Uint8List bytes;
}

/// Decrypted bytes travelling to the server on this phone.
class TlsToApp extends TlsEvent {
  const TlsToApp(super.connection, this.bytes);

  final Uint8List bytes;
}

/// The handshake finished and application data may flow.
class TlsReady extends TlsEvent {
  const TlsReady(super.connection);
}

/// Nothing more will be said about this connection.
class TlsClosed extends TlsEvent {
  const TlsClosed(super.connection);
}

/// The connection could not be served.
class TlsFailed extends TlsEvent {
  const TlsFailed(super.connection, this.reason);

  final String reason;
}

/// Terminates the tunnel's TLS.
///
/// An interface with a single production implementation, because the tests need
/// to stand in for the platform. The only honest way to test a byte relay is
/// against a relay that is not the one under suspicion.
abstract class TlsTerminator {
  /// Everything the terminator says, about every connection.
  Stream<TlsEvent> get events;

  /// Loads the certificate the tunnel is reached through.
  Future<void> prepare({
    required String certificateChainPem,
    required String privateKeyPem,
  });

  /// Opens a session for a connection the service has just announced.
  Future<void> start(int connection);

  /// The visitor's bytes, encrypted, on their way into the handshake.
  Future<void> fromVisitor(int connection, List<int> bytes);

  /// Bytes on their way out to the visitor, which this layer encrypts.
  Future<void> fromApp(int connection, List<int> bytes);

  /// Gives up on a connection.
  Future<void> close(int connection);
}

/// The terminator the phone runs.
///
/// TLS is finished by the platform's own engine, reached over a method channel.
/// Not a preference: `dart:io` can only complete a handshake end to end, and a
/// visitor has to be answered during one.
class PlatformTlsTerminator implements TlsTerminator {
  PlatformTlsTerminator({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_name) {
    _listen();
  }

  static const _name = 'dev.vitkuz573.opencodemobile/tunnel_tls';

  final MethodChannel _channel;
  final StreamController<TlsEvent> _events =
      StreamController<TlsEvent>.broadcast();

  var _wired = false;

  @override
  Stream<TlsEvent> get events => _events.stream;

  void _listen() {
    if (_wired) return;
    _wired = true;
    _channel.setMethodCallHandler((call) async {
      final arguments = call.arguments as Map?;
      final connection = arguments?['connection'];
      if (connection is! int) return null;
      switch (call.method) {
        case 'toVisitor':
          _events.add(TlsToVisitor(connection, arguments!['bytes'] as Uint8List));
        case 'toApp':
          _events.add(TlsToApp(connection, arguments!['bytes'] as Uint8List));
        case 'ready':
          _events.add(TlsReady(connection));
        case 'closed':
          _events.add(TlsClosed(connection));
        case 'failed':
          _events.add(TlsFailed(connection, '${arguments?['reason']}'));
      }
      return null;
    });
  }

  @override
  Future<void> prepare({
    required String certificateChainPem,
    required String privateKeyPem,
  }) =>
      _channel.invokeMethod<void>('prepare', {
        'certificateChain': certificateChainPem,
        'privateKey': privateKeyPem,
      });

  @override
  Future<void> start(int connection) =>
      _channel.invokeMethod<void>('start', {'connection': connection});

  @override
  Future<void> fromVisitor(int connection, List<int> bytes) => _channel
      .invokeMethod<void>('fromVisitor', {
        'connection': connection,
        'bytes': Uint8List.fromList(bytes),
      });

  @override
  Future<void> fromApp(int connection, List<int> bytes) => _channel
      .invokeMethod<void>('fromApp', {
        'connection': connection,
        'bytes': Uint8List.fromList(bytes),
      });

  @override
  Future<void> close(int connection) =>
      _channel.invokeMethod<void>('close', {'connection': connection});

  Future<void> dispose() async {
    _wired = false;
    _channel.setMethodCallHandler(null);
    await _events.close();
  }
}