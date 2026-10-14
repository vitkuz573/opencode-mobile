import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/runtime/tunnel/tunnel_protocol.dart';

void main() {
  group('frames', () {
    test('carry the connection id big-endian ahead of the payload', () {
      final encoded = BridgeProtocol.encodeFrame(0x01020304, [0xaa, 0xbb]);
      expect(encoded.take(4), [1, 2, 3, 4]);
      expect(encoded.sublist(4), [0xaa, 0xbb]);
    });

    test('round-trip a connection and its bytes', () {
      final payload = List<int>.generate(1000, (i) => i % 256);
      final frame = BridgeProtocol.decodeFrame(
        BridgeProtocol.encodeFrame(42, payload),
      )!;
      expect(frame.connection, 42);
      expect(frame.payload, payload);
    });

    test('refuse a frame with no room for an id', () {
      expect(BridgeProtocol.decodeFrame([1, 2, 3]), isNull);
      expect(BridgeProtocol.decodeFrame([]), isNull);
    });

    test('keep an empty payload, which is a legitimate half-close', () {
      final frame = BridgeProtocol.decodeFrame(BridgeProtocol.encodeFrame(7, []))!;
      expect(frame.connection, 7);
      expect(frame.payload, isEmpty);
    });
  });

  group('control messages', () {
    test('read what the service sends', () {
      final attached = BridgeMessage.parse(
        jsonEncode({
          'type': 'attached',
          'session': 's-1',
          'routes': ['@'],
          'heartbeat_ms': 15000,
          'idle_timeout_ms': 60000,
        }),
      );
      expect(attached, isA<Attached>());
      final value = attached! as Attached;
      expect(value.session, 's-1');
      expect(value.routes, ['@']);
      expect(value.heartbeatMs, const Duration(seconds: 15));
      expect(value.idleTimeoutMs, const Duration(minutes: 1));
    });

    test('read an open frame', () {
      final open = BridgeMessage.parse(
        jsonEncode({
          'type': 'open',
          'conn': 9,
          'peer': '203.0.113.9:51234',
          'sni': 'abc.opentunnel.xyz',
          'alpn': 'http/1.1',
        }),
      )! as OpenConnection;
      expect(open.connection, 9);
      expect(open.sni, 'abc.opentunnel.xyz');
      expect(open.peer, '203.0.113.9:51234');
    });

    test('ignore fields they have never heard of', () {
      // The protocol is additive on purpose; refusing an unfamiliar field would
      // break every client the day the service ships one.
      final open = BridgeMessage.parse(
        jsonEncode({
          'type': 'open',
          'conn': 1,
          'peer': '1.2.3.4:1',
          'sni': 'a.b',
          'something_new': {'nested': true},
        }),
      );
      expect(open, isA<OpenConnection>());
    });

    test('ignore a message type they do not speak', () {
      expect(BridgeMessage.parse(jsonEncode({'type': 'teleport'})), isNull);
    });

    test('survive a message that is not an object', () {
      expect(BridgeMessage.parse('[1,2,3]'), isNull);
    });

    test('treat a bad token and a missing certificate as final', () {
      // Both are things that cannot fix themselves, so retrying them would be
      // reconnecting to the same failure in a loop.
      expect(
        (BridgeMessage.parse(jsonEncode({'type': 'attach_error', 'code': 'bad_token'}))!
                as AttachFailure)
            .isFatal,
        isTrue,
      );
      expect(
        (BridgeMessage.parse(
          jsonEncode({'type': 'attach_error', 'code': 'cert_not_ready'}),
        )! as AttachFailure)
            .isFatal,
        isTrue,
      );
      expect(
        (BridgeMessage.parse(
          jsonEncode({'type': 'attach_error', 'code': 'route_conflict'}),
        )! as AttachFailure)
            .isFatal,
        isFalse,
      );
    });
  });

  group('attach', () {
    test('says what the service needs to hear', () {
      final json = Attach(token: 'tok', routes: const ['@'], maxConnections: 8).toJson();
      expect(json['type'], 'attach');
      expect(json['token'], 'tok');
      expect(json['transport'], 'ws');
      expect(json['routes'], ['@']);
      final client = json['client']! as Map<String, Object?>;
      expect(client['max_conns'], 8);
    });
  });

  group('routes', () {
    test('claims only the tunnel host itself', () {
      expect(routesFor('abc.opentunnel.xyz'), {'@'});
    });
  });
}