import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

/// What the app needs from the tunnel service.
///
/// [TunnelApi] is the real one. The interface exists so the controller can be
/// exercised without a service on the other end - the HTTP client's own rules
/// are tested there, and repeating them here would only test the test.
abstract class TunnelService {
  /// Claims a tunnel, keeping the token, which is shown exactly once.
  Future<ClaimedTunnel> claim();

  /// Asks for the certificate request to be signed.
  Future<CertificateInfo> requestCertificate(
    String id,
    String token,
    String csr,
  );

  /// Waits for a certificate and returns it ready to serve.
  Future<Certificate> awaitCertificate(String id, String token);

  /// Releases the tunnel and everything issued against it.
  Future<void> delete(String id, String token);
}

/// The OpenTunnel HTTP API, as published in `docs/protocol.md`.
///
/// Everything the app needs from the service goes through here: claiming a
/// tunnel, and asking it to sign a certificate request. The transport is a
/// [Dio] so the client can be handed a fake one in tests, and so that the retry
/// rules - which are part of the contract rather than a detail of it - sit next
/// to the calls they apply to.
class TunnelApi implements TunnelService {
  TunnelApi(this._dio);

  final Dio _dio;

  static const baseUrl = 'https://opentunnel.xyz';

  /// The statuses a request that may already have arrived must not be retried
  /// on.
  ///
  /// `POST /api/tunnel` that times out after the service created the tunnel
  /// leaves an orphaned record nobody holds the token for. Repeating it would
  /// spend a second hostname and lose the first, so these fail at once.
  static const _noSideEffect = {429, 503, 521, 522, 523, 525};

  /// Safe to repeat whatever the service says: nothing is created or consumed.
  static const _idempotent = {429, 500, 501, 502, 503, 504};

  /// Cloudflare answers with HTML and a number in this range when it never
  /// reached the service. Reporting the bare number tells the reader nothing.
  static const _cloudflare = {
    520: 'the origin server returned an unknown error',
    521: 'the origin server refused the connection',
    522: 'the origin server did not answer in time',
    523: 'the origin server is unreachable',
    524: 'the request took too long',
    525: 'the TLS handshake with the server failed',
    526: 'the server presented an invalid certificate',
    527: 'the origin server failed the TLS handshake',
  };

  @override
  Future<ClaimedTunnel> claim() async {
    final json = _map(
      await _send(
        // The service rejects a request with no body at all, and says nothing
        // useful when it does. The documented body is an empty object, so that
        // is what is sent.
        () => _dio.post<dynamic>('/api/tunnel', data: const <String, Object?>{}),
        retryable: _noSideEffect,
        what: 'claim a tunnel',
      ),
    );
    final tunnel = json['tunnel'];
    if (tunnel is! Map) {
      throw const TunnelApiException(
        'The tunnel service did not return a tunnel.',
      );
    }
    final token = json['token'];
    if (token is! String || token.isEmpty) {
      throw const TunnelApiException(
        'The tunnel service did not return a token, so the tunnel cannot be '
        'used. It has to be claimed again.',
      );
    }
    return ClaimedTunnel(_tunnel(tunnel.cast<String, dynamic>()), token);
  }

  Future<TunnelInfo> info(String id, String token) async => _tunnel(
        _map(
          await _send(
            () => _dio.get<dynamic>('/api/tunnel/$id', options: _auth(token)),
            retryable: _idempotent,
            what: 'read the tunnel',
          ),
        ),
      );

  /// Asks the service to sign the certificate request in [csr].
  ///
  /// Safe to repeat: if the tunnel is already bound to this request the service
  /// answers with the certificate it already holds.
  @override
  Future<CertificateInfo> requestCertificate(
    String id,
    String token,
    String csr,
  ) async =>
      _certificate(
        _map(
          await _send(
            () => _dio.post<dynamic>(
              '/api/tunnel/$id/certificate',
              data: {'csr': csr},
              options: _auth(token),
            ),
            retryable: _idempotent,
            what: 'request a certificate',
          ),
        ),
      );

  Future<CertificateInfo> certificate(String id, String token) async =>
      _certificate(
        _map(
          await _send(
            () => _dio.get<dynamic>(
              '/api/tunnel/$id/certificate',
              options: _auth(token),
            ),
            retryable: _idempotent,
            what: 'read the certificate',
          ),
        ),
      );

  /// Releases the tunnel and everything issued against it.
  ///
  /// Used when the user stops publishing: the hostname is not coming back, and
  /// a live certificate pointing at a device nobody is publishing from is not
  /// something to leave lying around.
  @override
  @override
  Future<void> delete(String id, String token) async {
    await _send<dynamic>(
      () => _dio.delete<dynamic>('/api/tunnel/$id', options: _auth(token)),
      retryable: _noSideEffect,
      what: 'delete the tunnel',
    );
  }

  /// Waits for a certificate, polling as the protocol prescribes.
  ///
  /// Gives up after [timeout] rather than polling forever. Issuance is seconds
  /// when it is working, and the service says so plainly when it is not; a
  /// publish button that hangs is worse than one that reports a failure.
  @override
  Future<Certificate> awaitCertificate(
    String id,
    String token, {
    Duration timeout = const Duration(minutes: 3),
    Duration interval = const Duration(seconds: 2),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final info = await certificate(id, token);
      switch (info.state) {
        case CertificateState.ready:
          return Certificate(
            pem: info.certificate!,
            chainPem: info.chain!,
            expiry: info.expiry!,
          );
        case CertificateState.failed:
          throw TunnelApiException(
            'The tunnel certificate could not be issued: ${info.reason}',
          );
        case CertificateState.challenge:
        case CertificateState.issuing:
          if (DateTime.now().isAfter(deadline)) {
            throw TunnelApiException(
              'The tunnel certificate was still being issued after '
              '${timeout.inMinutes} minutes.',
            );
          }
          await Future<void>.delayed(interval);
      }
    }
  }

  static Options _auth(String token) =>
      Options(headers: {'authorization': 'Bearer $token'});

  // --- Transport -----------------------------------------------------------

  /// Runs [request], retrying what the protocol says may be repeated.
  ///
  /// The wait is half to all of `min(250 ms * 2^n, 8 s)`, or `Retry-After`
  /// capped at the same ceiling. The jitter is the point: a service answering
  /// 429 to everyone at once should not have them all return at once.
  Future<T> _send<T>(
    Future<Response<T>> Function() request, {
    required Set<int> retryable,
    required String what,
  }) async {
    final random = Random();
    for (var attempt = 0;; attempt++) {
      try {
        return (await request()).data as T;
      } on DioException catch (error) {
        final status = error.response?.statusCode;
        final mayRepeat = status == null
            ? _neverArrived(error)
            : retryable.contains(status);
        if (attempt >= _maxAttempts - 1 || !mayRepeat) {
          throw _describe(what, error);
        }
        await Future<void>.delayed(_backoff(attempt, error.response, random));
      }
    }
  }

  static const _maxAttempts = 6;

  /// Whether the request certainly never reached the service.
  static bool _neverArrived(DioException error) =>
      error.type == DioExceptionType.connectionError ||
      error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.sendTimeout;

  static Duration _backoff(
    int attempt,
    Response<dynamic>? response,
    Random random,
  ) {
    final asked = _retryAfter(response);
    if (asked != null) return asked;
    final ceiling = min(250 * (1 << attempt), 8000);
    return Duration(milliseconds: ceiling ~/ 2 + random.nextInt(ceiling ~/ 2 + 1));
  }

  static Duration? _retryAfter(Response<dynamic>? response) {
    final header = response?.headers.value('retry-after');
    final seconds = header == null ? null : int.tryParse(header.trim());
    if (seconds == null || seconds < 0) return null;
    return Duration(seconds: min(seconds, 8));
  }

  /// A message a person can act on, rather than a status number.
  TunnelApiException _describe(String what, DioException error) {
    final status = error.response?.statusCode;
    if (status == null) {
      final cause = switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout =>
          'it did not answer in time',
        DioExceptionType.connectionError => 'it could not be reached',
        _ => error.message ?? 'the connection failed',
      };
      return TunnelApiException(
        'The tunnel service could not be reached while trying to $what: $cause.',
      );
    }

    final body = error.response?.data;
    if (body is Map) {
      final message = body['message'];
      if (message is String && message.isNotEmpty) {
        return TunnelApiException('Could not $what: $message');
      }
    }

    final cloudflare = _cloudflare[status];
    if (cloudflare != null) {
      return TunnelApiException(
        'Could not $what: the tunnel service could not be reached '
        '(Cloudflare $status, $cloudflare).',
      );
    }
    // A 4xx with no body is the service telling us it did not like the request
    // without saying why. Naming the range is more use than the bare number.
    if (status >= 400 && status < 500) {
      return TunnelApiException(
        'Could not $what: the tunnel service rejected the request without '
        'saying why (HTTP $status).',
      );
    }
    return TunnelApiException('Could not $what (HTTP $status).');
  }

  // --- Shapes --------------------------------------------------------------

  static Map<String, dynamic> _map(Object? value) {
    if (value is Map) return value.cast<String, dynamic>();
    throw const TunnelApiException(
      'The tunnel service returned something that is not a JSON object.',
    );
  }

  static TunnelInfo _tunnel(Map<String, dynamic> json) => TunnelInfo(
        id: _string(json, 'id'),
        hostname: _string(json, 'hostname'),
        reachability: json['state'] == 'online'
            ? TunnelReachability.online
            : TunnelReachability.offline,
        certificateID: json['certificateID'] as String?,
      );

  static CertificateInfo _certificate(Map<String, dynamic> json) {
    final state = _map(json['state']);
    return switch (state['type']) {
      'ready' => CertificateInfo.ready(
          _string(state, 'certificate'),
          _string(state, 'chain'),
          _string(state, 'expiry'),
        ),
      'challenge' => CertificateInfo.challenge(
          _string(state, 'token'),
          _string(state, 'key'),
        ),
      'issuing' => const CertificateInfo.issuing(),
      'failed' => CertificateInfo.failed(
          state['reason'] is String ? state['reason'] as String : 'no reason given',
        ),
      _ => throw const TunnelApiException(
          'The tunnel service reported a certificate state this app does not '
          'know about.',
        ),
    };
  }

  static String _string(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw TunnelApiException('The tunnel service returned no "$key".');
    }
    return value;
  }
}

/// A tunnel, and the token that is shown exactly once when it is claimed.
class ClaimedTunnel {
  const ClaimedTunnel(this.info, this.token);

  final TunnelInfo info;
  final String token;

  /// Where a visitor reaches it, and where the pairing link is aimed.
  Uri get url => Uri.parse('https://${info.hostname}/');
}

/// Whether the service currently sees a tunnel online.
enum TunnelReachability { offline, online }

class TunnelInfo {
  const TunnelInfo({
    required this.id,
    required this.hostname,
    required this.reachability,
    this.certificateID,
  });

  final String id;
  final String hostname;

  /// Whether the service currently sees this tunnel online.
  final TunnelReachability reachability;
  final String? certificateID;
}

enum CertificateState { challenge, issuing, ready, failed }

/// Where issuance has got to.
///
/// The fields that belong to a state are set only in that state, so reading
/// [certificate] outside [CertificateState.ready] is a type error the compiler
/// cannot catch and the tests do.
class CertificateInfo {
  const CertificateInfo.challenge(this.challengeToken, this.key)
      : certificate = null,
        chain = null,
        expiry = null,
        reason = null,
        state = CertificateState.challenge;

  const CertificateInfo.issuing()
      : certificate = null,
        chain = null,
        expiry = null,
        challengeToken = null,
        key = null,
        reason = null,
        state = CertificateState.issuing;

  const CertificateInfo.ready(this.certificate, this.chain, this.expiry)
      : challengeToken = null,
        key = null,
        reason = null,
        state = CertificateState.ready;

  const CertificateInfo.failed(this.reason)
      : certificate = null,
        chain = null,
        expiry = null,
        challengeToken = null,
        key = null,
        state = CertificateState.failed;

  final CertificateState state;

  /// Set when [state] is [CertificateState.ready].
  final String? certificate;

  /// Set when [state] is [CertificateState.ready].
  final String? chain;

  /// Set when [state] is [CertificateState.ready].
  final String? expiry;

  /// Set when [state] is [CertificateState.challenge]. The app has nothing to
  /// do with it: the service resolves the challenge itself, having never given
  /// out the key.
  final String? challengeToken;

  /// Set when [state] is [CertificateState.challenge], and never leaves this
  /// device. That it comes back at all is a reminder that the private key was
  /// never sent.
  final String? key;

  /// Set when [state] is [CertificateState.failed].
  final String? reason;
}

/// A certificate that arrived and can be served.
class Certificate {
  Certificate({
    required this.pem,
    required this.chainPem,
    required this.expiry,
  })  : assert(_hasCertificate(pem)),
        assert(_hasCertificate(chainPem));

  /// The certificate itself, PEM.
  final String pem;

  /// The chain it is served with, PEM.
  final String chainPem;

  /// When it stops being valid, as the service reports it.
  final String expiry;

  /// Certificate and chain together, which is what `SecurityContext` is given.
  ///
  /// BoringSSL wants the leaf first and reads down the chain from there, so
  /// this order is the one that works rather than a matter of taste.
  List<int> get chainPemBytes => utf8.encode('$pem\n$chainPem');

  static bool _hasCertificate(String pem) =>
      pem.contains('BEGIN CERTIFICATE');
}

/// Anything that went wrong talking to the tunnel service, said so a person can
/// act on.
class TunnelApiException implements Exception {
  const TunnelApiException(this.message);

  final String message;

  @override
  String toString() => message;
}