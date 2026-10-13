import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/data/api.dart';
import 'package:opencode_mobile/src/data/events.dart';

void main() {
  group('SSE framing', () {
    test('extracts one payload per blank-line separated frame', () {
      final parser = SseParser();
      final frames = parser
          .add(utf8.encode('data: {"a":1}\n\ndata: {"b":2}\n\n'))
          .toList();

      expect(frames, ['{"a":1}', '{"b":2}']);
    });

    test('buffers a frame split across chunks', () {
      final parser = SseParser();
      expect(parser.add(utf8.encode('data: {"a"')), isEmpty);
      expect(parser.add(utf8.encode(':1}')), isEmpty);
      expect(parser.add(utf8.encode('\n\n')), ['{"a":1}']);
    });

    test('handles CRLF frames', () {
      final parser = SseParser();
      expect(parser.add(utf8.encode('data: x\r\n\r\n')), ['x']);
    });

    test('joins multi-line data payloads', () {
      final parser = SseParser();
      expect(parser.add(utf8.encode('data: one\ndata: two\n\n')), [
        'one\ntwo',
      ]);
    });

    test('ignores comments and fields without data', () {
      final parser = SseParser();
      expect(parser.add(utf8.encode(': keepalive\nevent: ping\n\n')), isEmpty);
    });

    test('decodes UTF-8 split across a chunk boundary', () {
      final parser = SseParser();
      final bytes = utf8.encode('data: {"t":"Привет"}\n\n');
      final split = bytes.length ~/ 2;
      // Find a boundary that lands inside a multi-byte sequence.
      final cut = bytes.indexOf(0xD0) + 1;

      expect(parser.add(bytes.sublist(0, cut)), isEmpty);
      final frames = parser.add(bytes.sublist(cut)).toList();
      expect(frames, hasLength(1));
      expect(frames.single, contains('Привет'));
      expect(split, greaterThan(0));
    });
  });

  group('server address normalisation', () {
    test('adds a scheme and strips trailing slashes', () {
      expect(
        ServerProfile.normalizeBaseUrl('10.0.2.2:4096/'),
        'http://10.0.2.2:4096',
      );
      expect(
        ServerProfile.normalizeBaseUrl('https://box.local:4096///'),
        'https://box.local:4096',
      );
    });

    test('keeps an explicit scheme and trims whitespace', () {
      expect(
        ServerProfile.normalizeBaseUrl('  http://127.0.0.1:4096  '),
        'http://127.0.0.1:4096',
      );
    });

    test('reports a readable host', () {
      final profile = ServerProfile.basic(
        baseUrl: 'http://10.0.2.2:4096',
        password: 'x',
      );
      expect(profile.displayHost, '10.0.2.2:4096');
    });
  });

  group('profile serialisation', () {
    test('round-trips through JSON', () {
      final profile = ServerProfile.cookie(
        baseUrl: 'http://host:4096',
        cookie: 'session=abc',
        label: 'work',
      );
      final restored = ServerProfile.fromJson(profile.toJson());

      expect(restored.baseUrl, profile.baseUrl);
      expect(restored.authMode, AuthMode.cookie);
      expect(restored.secret, profile.secret);
      expect(restored.label, 'work');
    });

    test('falls back to basic auth for an unknown mode', () {
      final restored = ServerProfile.fromJson({
        'baseUrl': 'http://host:4096',
        'authMode': 'martian',
        'secret': 'x',
      });
      expect(restored.authMode, AuthMode.basic);
    });
  });

  group('pairing links', () {
    test('rejects a link without the connect path', () {
      expect(
        () => OpenCodeApi.redeemPairingLink('http://host:4096/dashboard'),
        throwsA(isA<ApiException>()),
      );
    });

    test('rejects rubbish', () {
      expect(
        () => OpenCodeApi.redeemPairingLink('not a url at all'),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('event status', () {
    test('reports live only for the live status', () {
      expect(
        const EventStreamStatus(StreamStatus.live).isLive,
        isTrue,
      );
      expect(
        const EventStreamStatus(StreamStatus.retrying).isLive,
        isFalse,
      );
    });
  });
}