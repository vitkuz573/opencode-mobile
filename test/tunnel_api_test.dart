import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/runtime/tunnel/tunnel_api.dart';

void main() {
  late _FakeTransport transport;
  late TunnelApi api;

  setUp(() {
    transport = _FakeTransport();
    api = TunnelApi(Dio(BaseOptions(baseUrl: TunnelApi.baseUrl))
      ..httpClientAdapter = transport);
  });

  group('claiming', () {
    test('keeps the token, which is shown once', () async {
      transport.reply(_tunnelJson(token: 'tok-1'));
      final claimed = await api.claim();
      expect(claimed.token, 'tok-1');
      expect(claimed.info.id, 'abc123');
      expect(claimed.info.hostname, 'abc123.opentunnel.xyz');
      // The link a visitor is given has to be the tunnel's own address, or
      // there is nothing to retarget a pairing code to.
      expect(claimed.url.toString(), 'https://abc123.opentunnel.xyz/');
    });

    test('refuses a tunnel it cannot authenticate with', () async {
      transport.reply({'tunnel': _tunnelJson()});
      await expectLater(
        api.claim(),
        throwsA(
          isA<TunnelApiException>().having(
            (e) => e.message,
            'message',
            contains('token'),
          ),
        ),
      );
    });

    test('sends the empty object the service insists on', () async {
      // Verified against the live service: a claim with no body at all is
      // refused with a 400 and no explanation, which is the worst possible way
      // to find out what it wanted.
      transport.reply(_tunnelJson(token: 't'));
      await api.claim();
      expect(transport.requests.single.method, 'POST');
      expect(transport.requests.single.path, '/api/tunnel');
      expect(transport.requests.single.body, <String, Object?>{});
    });
  });

  group('certificates', () {
    test('asks for a certificate with the request in the body', () async {
      transport.reply({'state': {'type': 'issuing'}});
      await api.requestCertificate('abc', 'tok', 'Y3Ny');
      final request = transport.requests.single;
      expect(request.path, '/api/tunnel/abc/certificate');
      expect(request.body, {'csr': 'Y3Ny'});
      expect(request.headers['authorization'], 'Bearer tok');
    });

    test('reads a ready certificate', () async {
      transport.reply({
        'state': {
          'type': 'ready',
          'certificate': _pem('leaf'),
          'chain': _pem('issuer'),
          'expiry': '2027-01-01T00:00:00Z',
        },
      });
      final info = await api.certificate('abc', 'tok');
      expect(info.state, CertificateState.ready);
      expect(info.certificate, _pem('leaf'));
      expect(info.chain, _pem('issuer'));
    });

    test('refuses a state it has never heard of', () async {
      transport.reply({'state': {'type': 'quantum'}});
      await expectLater(
        api.certificate('abc', 'tok'),
        throwsA(isA<TunnelApiException>()),
      );
    });

    test('waits through issuing and returns what arrives', () async {
      transport
        ..reply({'state': {'type': 'issuing'}})
        ..reply({'state': {'type': 'issuing'}})
        ..reply({
          'state': {
            'type': 'ready',
            'certificate': _pem('leaf'),
            'chain': _pem('issuer'),
            'expiry': 'soon',
          },
        });
      final certificate = await api.awaitCertificate(
        'abc',
        'tok',
        interval: Duration.zero,
      );
      expect(certificate.pem, _pem('leaf'));
      expect(transport.requests, hasLength(3));
    });

    test('stops when the service says it failed', () async {
      transport.reply({
        'state': {'type': 'failed', 'reason': 'validation went wrong'},
      });
      await expectLater(
        api.awaitCertificate('abc', 'tok', interval: Duration.zero),
        throwsA(
          isA<TunnelApiException>().having(
            (e) => e.message,
            'message',
            contains('validation went wrong'),
          ),
        ),
      );
    });

    test('gives up rather than polling for ever', () async {
      transport.reply({'state': {'type': 'issuing'}});
      await expectLater(
        api.awaitCertificate(
          'abc',
          'tok',
          timeout: Duration.zero,
          interval: Duration.zero,
        ),
        throwsA(
          isA<TunnelApiException>().having(
            (e) => e.message,
            'message',
            contains('still being issued'),
          ),
        ),
      );
    });
  });

  group('retries', () {
    test('repeats a read the service rate limited', () async {
      transport
        ..replyError(status: 429)
        ..reply({'state': {'type': 'issuing'}});
      await api.certificate('abc', 'tok');
      expect(transport.requests, hasLength(2));
    });

    test('does not repeat a claim that may already have been served', () async {
      // A second POST would claim a second hostname and orphan the first, so
      // this has to fail on the first answer however temporary it looks.
      transport.replyError(status: 500);
      await expectLater(api.claim(), throwsA(isA<TunnelApiException>()));
      expect(transport.requests, hasLength(1));
    });

    test('repeats a read on any server error', () async {
      transport
        ..replyError(status: 502)
        ..reply({'state': {'type': 'issuing'}});
      await api.certificate('abc', 'tok');
      expect(transport.requests, hasLength(2));
    });

    test('repeats a read that never arrived', () async {
      transport
        ..replyError(type: DioExceptionType.connectionError)
        ..reply({'state': {'type': 'issuing'}});
      await api.certificate('abc', 'tok');
      expect(transport.requests, hasLength(2));
    });

    test('gives up after the attempts the protocol allows', () async {
      for (var i = 0; i < 10; i++) {
        transport.replyError(status: 503);
      }
      await expectLater(api.certificate('abc', 'tok'), throwsA(isA<TunnelApiException>()));
      expect(transport.requests.length, lessThanOrEqualTo(6));
    });
  });

  group('what the user is told', () {
    test('uses the reason the service gave', () async {
      transport.replyError(status: 400, body: {'_tag': 'x', 'message': 'bad host'});
      await expectLater(
        api.claim(),
        throwsA(isA<TunnelApiException>().having((e) => e.message, 'message', contains('bad host'))),
      );
    });

    test('explains a Cloudflare status instead of printing the number', () async {
      // A read, so this fails on the first answer rather than being retried:
      // what is under test is the wording, not the patience.
      transport.replyError(status: 525, body: '<html>');
      await expectLater(
        api.certificate('abc', 'tok'),
        throwsA(
          isA<TunnelApiException>().having(
            (e) => e.message,
            'message',
            allOf(contains('TLS handshake'), contains('525')),
          ),
        ),
      );
    });

    test('says the service refused it, rather than printing a number', () async {
      transport.replyError(status: 400);
      await expectLater(
        api.claim(),
        throwsA(
          isA<TunnelApiException>().having(
            (e) => e.message,
            'message',
            allOf(contains('rejected the request'), contains('400')),
          ),
        ),
      );
    });

    test('says the service was unreachable when it was', () async {
      // Six, because that is the whole retry budget and the message under test
      // is the one reported after it is spent.
      for (var i = 0; i < 6; i++) {
        transport.replyError(type: DioExceptionType.connectionError);
      }
      await expectLater(
        api.claim(),
        throwsA(
          isA<TunnelApiException>().having(
            (e) => e.message,
            'message',
            allOf(contains('could not be reached'), contains('claim a tunnel')),
          ),
        ),
      );
    });
  });

  test('deleting sends the token and expects nothing back', () async {
    transport.reply(null);
    await api.delete('abc', 'tok');
    expect(transport.requests.single.method, 'DELETE');
    expect(transport.requests.single.path, '/api/tunnel/abc');
    expect(transport.requests.single.headers['authorization'], 'Bearer tok');
  });
}

/// A certificate as PEM, which is the only shape the app accepts.
String _pem(String label) => '-----BEGIN CERTIFICATE-----\n$label\n-----END CERTIFICATE-----\n';

Map<String, dynamic> _tunnelJson({String? token}) => {
      'tunnel': {
        'id': 'abc123',
        'hostname': 'abc123.opentunnel.xyz',
        'state': 'offline',
      },
      'token': ?token,
    };

/// Stands in for the network, so the rules under test are the client's own and
/// not the service's mood today.
class _FakeTransport implements HttpClientAdapter {
  final List<_Request> requests = [];
  final List<Object> _answers = [];

  void reply(Object? body) => _answers.add(_Reply(body));

  void replyError({int? status, Object? body, DioExceptionType? type}) =>
      _answers.add(_Failure(status: status, body: body, type: type));

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(
      _Request(
        method: options.method,
        path: options.path,
        headers: options.headers,
        body: options.data,
      ),
    );
    final answer = _answers.isEmpty
        ? _Failure(status: 599, type: DioExceptionType.connectionError)
        : _answers.removeAt(0);
    if (answer is _Failure) {
      throw DioException(
        requestOptions: options,
        type: answer.type ?? DioExceptionType.badResponse,
        response: answer.status == null
            ? null
            : Response<dynamic>(
                requestOptions: options,
                statusCode: answer.status,
                data: answer.body,
              ),
      );
    }
    final body = (answer as _Reply).body;
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Reply {
  const _Reply(this.body);
  final Object? body;
}

class _Failure {
  const _Failure({this.status, this.body, this.type});
  final int? status;
  final Object? body;
  final DioExceptionType? type;
}

class _Request {
  const _Request({
    required this.method,
    required this.path,
    required this.headers,
    required this.body,
  });

  final String method;
  final String path;
  final Map<String, dynamic> headers;
  final Object? body;
}