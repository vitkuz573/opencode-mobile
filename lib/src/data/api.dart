import 'package:flutter/foundation.dart';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'models.dart';
import 'pairing.dart';
import 'stats.dart';

/// Raised when the server rejects a request or cannot be reached. [message] is
/// safe to show to a user; the underlying [cause] stays in the log.
class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode, this.cause});

  final String message;
  final int? statusCode;
  final Object? cause;

  bool get isAuthFailure => statusCode == 401 || statusCode == 403;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

Map<String, Object?> _map(Object? v) =>
    v is Map ? v.cast<String, Object?>() : const <String, Object?>{};

List<Object?> _list(Object? v) => v is List ? v : const <Object?>[];

String? _str(Object? v) => v is String ? v : null;

/// How the client authenticates against a server.
///
/// [basic] is the password printed by `opencode serve`. [cookie] is a session
/// obtained by redeeming a pairing link (`opencode pair`), which is what the
/// official web and mobile clients use.
enum AuthMode { basic, cookie }

class ServerProfile {
  const ServerProfile({
    required this.baseUrl,
    required this.authMode,
    required this.secret,
    this.label = '',
    this.lastUsedAt = 0,
    this.version = '',
  });

  factory ServerProfile.basic({
    required String baseUrl,
    required String password,
    String label = '',
  }) => ServerProfile(
    baseUrl: normalizeBaseUrl(baseUrl),
    authMode: AuthMode.basic,
    secret: password,
    label: label,
  );

  factory ServerProfile.cookie({
    required String baseUrl,
    required String cookie,
    String label = '',
  }) => ServerProfile(
    baseUrl: normalizeBaseUrl(baseUrl),
    authMode: AuthMode.cookie,
    secret: cookie,
    label: label,
  );

  final String baseUrl;
  final AuthMode authMode;
  final String secret;

  /// A name the user gave this server. Free text, never shown to the server.
  final String label;

  /// Epoch millis of the last successful connection, or 0 if never.
  final int lastUsedAt;

  /// Server version seen on the last successful connection.
  final String version;

  /// What to put in a list: the name if there is one, otherwise the host.
  String get displayName => label.trim().isEmpty ? displayHost : label.trim();

  bool get isNamed => label.trim().isNotEmpty;

  Map<String, Object?> toJson() => {
    'baseUrl': baseUrl,
    'authMode': authMode.name,
    'secret': secret,
    'label': label,
    'lastUsedAt': lastUsedAt,
    'version': version,
  };

  factory ServerProfile.fromJson(Map<String, Object?> json) => ServerProfile(
    baseUrl: normalizeBaseUrl(_str(json['baseUrl']) ?? ''),
    authMode: AuthMode.values.firstWhere(
      (m) => m.name == _str(json['authMode']),
      orElse: () => AuthMode.basic,
    ),
    secret: _str(json['secret']) ?? '',
    label: _str(json['label']) ?? '',
    lastUsedAt: (json['lastUsedAt'] as num?)?.toInt() ?? 0,
    version: _str(json['version']) ?? '',
  );

  ServerProfile copyWith({
    String? label,
    int? lastUsedAt,
    String? version,
  }) => ServerProfile(
    baseUrl: baseUrl,
    authMode: authMode,
    secret: secret,
    label: label ?? this.label,
    lastUsedAt: lastUsedAt ?? this.lastUsedAt,
    version: version ?? this.version,
  );

  /// Accepts what a human actually types: `192.168.1.5:4096`,
  /// `http://host:4096/`, `https://tunnel.example`.
  static String normalizeBaseUrl(String input) {
    var value = input.trim();
    if (value.isEmpty) return value;
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'http://$value';
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  String get displayHost {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null) return baseUrl;
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  @override
  String toString() => 'ServerProfile($displayHost, ${authMode.name})';
}

class Page<T> {
  const Page(this.items, {this.nextCursor});

  final List<T> items;
  final String? nextCursor;

  bool get hasMore => nextCursor != null && nextCursor!.isNotEmpty;
}

/// Thin typed client over the OpenCode server HTTP API.
///
/// Only the endpoints the app actually calls are wrapped; the full contract is
/// in `tool/openapi.json`.
class OpenCodeApi {
  OpenCodeApi(Dio dio) : _dio = dio;

  factory OpenCodeApi.forProfile(ServerProfile profile) {
    final dio = Dio(
      BaseOptions(
        baseUrl: profile.baseUrl,
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 30),
        responseType: ResponseType.json,
        headers: {'Accept': 'application/json'},
        // Non-2xx is handled in one place below.
        validateStatus: (status) => status != null && status < 600,
      ),
    );
    dio.interceptors.add(_AuthInterceptor(profile));
    return OpenCodeApi(dio);
  }

  final Dio _dio;

  Dio get raw => _dio;

  Future<Response<dynamic>> _guard(Future<Response<dynamic>> Function() send) async {
    try {
      final response = await send();
      final status = response.statusCode ?? 0;
      if (status >= 400) {
        throw ApiException(
          _errorMessage(response, status),
          statusCode: status,
        );
      }
      return response;
    } on ApiException {
      rethrow;
    } catch (error) {
      throw ApiException(_transportMessage(error), cause: error);
    }
  }

  static String _errorMessage(Response<dynamic> response, int status) {
    final body = response.data;
    if (body is Map) {
      final tag = body['_tag'] ?? body['message'] ?? body['error'];
      if (tag is String && tag.isNotEmpty) return tag;
    }
    if (status == 401) return 'Authentication failed — check the password';
    if (status == 404) return 'Not found on this server';
    return 'Server returned HTTP $status';
  }

  static String _transportMessage(Object error) {
    if (error is DioException) {
      return switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => 'Server did not answer in time',
        DioExceptionType.connectionError =>
          'Cannot reach the server — check the address and network',
        _ => error.message ?? 'Network error',
      };
    }
    return '$error';
  }

  // --- server ---------------------------------------------------------------

  Future<ServerInfo> info() async {
    final response = await _guard(
      () => _dio.get<dynamic>('/api/info'),
    );
    final body = response.data;
    return ServerInfo.fromJson(
      body is Map ? body.cast<String, Object?>() : const {},
    );
  }

  Future<List<Project>> projects() async {
    final response = await _guard(
      () => _dio.get<dynamic>('/api/project'),
    );
    final data = _list(response.data);
    return data
        .map((e) => Project.fromJson(_map(e)))
        .where((p) => p.id.isNotEmpty)
        .toList(growable: false);
  }

  /// Creates a short-lived pairing code, the first half of the `opencode pair`
  /// flow that phones use.
  Future<PairingCode> createPairingCode() async {
    final response = await _guard(
      () => _dio.post<dynamic>('/api/pair'),
    );
    final body = _map(response.data);
    return PairingCode(
      code: _str(body['code']) ?? '',
      expiresInSeconds: (body['expires_in'] as num?)?.toInt() ?? 300,
    );
  }

  // --- sessions -------------------------------------------------------------

  Future<Page<SessionSummary>> sessions({
    String? directory,
    int limit = 50,
    String? search,
    String? cursor,
  }) async {
    final response = await _guard(
      () => _dio.get<dynamic>(
        '/api/session',
        queryParameters: {
          if (directory != null && directory.isNotEmpty)
            'directory': directory,
          'limit': limit,
          if (search != null && search.isNotEmpty) 'search': search,
          if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
        },
      ),
    );
    final body = _map(response.data);
    final data = _list(body['data'])
        .map((e) => SessionSummary.fromJson(_map(e)))
        .toList(growable: false);
    final cursorNode = _map(body['cursor']);
    return Page(data, nextCursor: _str(cursorNode['next']));
  }

  Future<SessionSummary> createSession({
    String? directory,
    String? parentId,
    String? title,
  }) async {
    final response = await _guard(
      () => _dio.post<dynamic>(
        '/api/session',
        queryParameters: {
          if (directory != null && directory.isNotEmpty)
            'directory': directory,
        },
        data: {
          'parentID': ?parentId,
          'title': ?title,
        },
      ),
    );
    final body = _map(response.data);
    // The endpoint answers with { ...session fields } directly.
    return SessionSummary.fromJson(body['data'] is Map ? _map(body['data']) : body);
  }

  Future<List<ChatMessage>> messages(
    String sessionId, {
    String? directory,
    int limit = 200,
  }) async {
    final response = await _guard(
      () => _dio.get<dynamic>(
        '/api/session/$sessionId/message',
        queryParameters: {
          if (directory != null && directory.isNotEmpty)
            'directory': directory,
          'limit': limit,
        },
      ),
    );
    final body = _map(response.data);
    final messages = <ChatMessage>[];
    for (final raw in _list(body['data'])) {
      final message = messageFromJson(_map(raw));
      if (message != null) messages.add(message);
    }
    return messages;
  }

  Future<void> sendPrompt(
    String sessionId,
    String text, {
    String? directory,
  }) async {
    await _guard(
      () => _dio.post<dynamic>(
        '/api/session/$sessionId/prompt',
        queryParameters: {
          if (directory != null && directory.isNotEmpty)
            'directory': directory,
        },
        data: {'text': text},
      ),
    );
  }

  Future<bool> interrupt(String sessionId, {String? directory}) async {
    final response = await _guard(
      () => _dio.post<dynamic>(
        '/api/session/$sessionId/interrupt',
        queryParameters: {
          if (directory != null && directory.isNotEmpty)
            'directory': directory,
        },
      ),
    );
    final body = _map(response.data);
    return body['interrupted'] == true;
  }

  Future<void> replyToPermission(
    String sessionId,
    String requestId,
    String reply, {
    String? directory,
  }) async {
    await _guard(
      () => _dio.post<dynamic>(
        '/api/session/$sessionId/permission/$requestId/reply',
        queryParameters: {
          if (directory != null && directory.isNotEmpty)
            'directory': directory,
        },
        data: {'reply': reply},
      ),
    );
  }

  /// Exchanges a pairing link (`…/auth/connect/<code>`) for a session cookie.
  ///
  /// Must be called against an unauthenticated client: the link itself is the
  /// credential, and it is single use.
  ///
  /// The endpoint content-negotiates: with `Accept: text/html`, which is what
  /// a browser sends, it answers `302` plus Set-Cookie - the flow the official
  /// clients use. The cookie name embeds the port (`opencode_session_49374`
  /// locally, `opencode_session` through a tunnel), so it is never assembled
  /// here: whatever the server sends is what gets stored.
  static Future<({String baseUrl, String cookie})> redeemPairingLink(
    String link, {
    List<String> fallbackHosts = const [],
  }) async {
    final uri = Uri.tryParse(link.trim());
    if (uri == null || uri.path.isEmpty) {
      throw const ApiException('That does not look like a pairing link');
    }
    if (!uri.path.contains('/auth/connect/')) {
      throw const ApiException('Link is missing the /auth/connect/ part');
    }

    // A pairing code is not bound to a host: opencode pair prints one code
    // with several URLs. So when the link names a loopback address - which on a
    // phone is the phone - the same code can still be redeemed on a host the
    // device has already reached.
    final hosts = <String>[
      ServerProfile.normalizeBaseUrl('${uri.scheme}://${uri.authority}'),
      ...fallbackHosts.map(ServerProfile.normalizeBaseUrl),
    ];

    ApiException? lastError;
    for (final host in hosts) {
      try {
        final cookie = await _redeem(host, uri.path);
        return (baseUrl: host, cookie: cookie);
      } on ApiException catch (error) {
        lastError = error;
      }
    }

    if (PairingLink.isLoopback(hosts.first)) {
      throw ApiException(
        'This link points at a loopback address, which on a phone is the '
        'phone itself, and this server has no other known address.',
      );
    }
    // Which hosts were tried, and what the last one answered. A pairing code is
    // single use, so "rejected" almost always means this one was already spent.
    debugPrint('redeem failed: tried=${hosts.join(",")} last=$lastError');
    throw lastError ??
        const ApiException('The pairing link could not be redeemed');
  }

  static Future<String> _redeem(String base, String path) async {
    final probe = Dio(
      BaseOptions(
        baseUrl: base,
        connectTimeout: const Duration(seconds: 15),
        validateStatus: (status) => status != null && status < 600,
      ),
    );
    try {
      final response = await probe.get<dynamic>(
        path,
        options: Options(
          // The session cookie rides on the redirect, not on the final page.
          followRedirects: false,
          headers: const {
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          },
        ),
      );
      final status = response.statusCode ?? 0;
      final cookie = _cookieFrom(response);
      if (cookie == null) {
        throw ApiException(
          redeemFailureMessage(response.data, status),
          statusCode: status,
        );
      }
      return cookie;
    } on ApiException {
      rethrow;
    } catch (error) {
      throw ApiException(_transportMessage(error), cause: error);
    }
  }


  // --- models ---------------------------------------------------------------

  /// Models this server can run right now, with their reasoning variants.
  Future<List<ModelInfo>> models({String? directory}) async {
    final response = await _guard(
      () => _dio.get<dynamic>(
        '/api/model',
        queryParameters: {
          if (directory != null && directory.isNotEmpty)
            'directory': directory,
        },
      ),
    );
    final body = response.data;
    final list = body is Map ? _list(body['data']) : _list(body);
    final models = list
        .map((e) => ModelInfo.fromJson(_map(e)))
        .where((m) => m.id.isNotEmpty && m.enabled)
        .toList(growable: false);
    models.sort((a, b) {
      final byProvider = a.providerID.compareTo(b.providerID);
      return byProvider != 0 ? byProvider : a.name.compareTo(b.name);
    });
    return models;
  }

    /// One session, including the model and reasoning level it is set to.
  ///
  /// Takes no `directory`: unlike the list endpoint, this one rejects unknown
  /// query parameters outright and answers `400`.
  Future<SessionSummary> session(String sessionId) async {
    final response = await _guard(
      () => _dio.get<dynamic>('/api/session/$sessionId'),
    );
    final body = _map(response.data);
    return SessionSummary.fromJson(
      body['data'] is Map ? _map(body['data']) : body,
    );
  }
  /// Switches the session to [model], including its reasoning effort.
  Future<void> setModel(
    String sessionId,
    ModelRef model, {
    String? directory,
  }) async {
    await _guard(
      () => _dio.post<dynamic>(
        '/api/session/$sessionId/model',
        queryParameters: {
          if (directory != null && directory.isNotEmpty)
            'directory': directory,
        },
        data: {'model': model.toJson()},
      ),
    );
  }
  // --- usage ----------------------------------------------------------------

  /// What this server actually did: tokens, steps, days active, cost.
  ///
  /// Bounds the report with [range]. This is the machine's own accounting, not
  /// the opencode.ai account balance - the Console API has no usage or credit
  /// endpoint, so account-side money stays in the web console.
  Future<ServerStats> stats({
    StatsRange range = StatsRange.all,
    String? project,
  }) async {
    final from = range.fromMillis();
    final response = await _guard(
      () => _dio.get<dynamic>(
        '/api/experimental/session/stats',
        queryParameters: {
          'from': ?from,
          // A bounded window needs both ends; an open one needs neither.
          if (from != null) 'to': DateTime.now().millisecondsSinceEpoch,
          if (project != null && project.isNotEmpty) 'project': project,
        },
      ),
    );
    final body = _map(response.data);
    // `data` is a single aggregate object, not a list. Older captures show it
    // wrapped in a one-element array, so both shapes are accepted rather than
    // trusting one and rendering zeroes when the server tidies up.
    final data = body['data'];
    if (data is List) {
      if (data.isEmpty) return ServerStats.empty;
      return ServerStats.fromJson(_map(data.first));
    }
    if (data is Map) return ServerStats.fromJson(data.cast<String, Object?>());
    return ServerStats.empty;
  }

// --- agents ----------------------------------------------------------------

  /// The agents this server offers, for this project.
  ///
  /// The `location` parameter is an object, not a plain string, so `directory`
  /// travels as a deep query key rather than `?directory=`.
  Future<List<AgentInfo>> agents({String? directory}) async {
    final response = await _guard(
      () => _dio.get<dynamic>(
        '/api/agent',
        queryParameters: {
          if (directory != null && directory.isNotEmpty)
            'location[directory]': directory,
        },
      ),
    );
    final body = _map(response.data);
    return _list(body['data'])
        .map((e) => AgentInfo.fromJson(_map(e)))
        .where((a) => a.id.isNotEmpty)
        .toList(growable: false);
  }

  /// Switches the agent the session talks to from now on.
  ///
  /// The server answers `204` for any id whatsoever, including ones that do not
  /// exist, so this does not verify anything: callers must pass an id that came
  /// from [agents].
  Future<void> setAgent(
    String sessionId,
    String agentId, {
    String? directory,
  }) async {
    await _guard(
      () => _dio.post<dynamic>(
        '/api/session/$sessionId/agent',
        queryParameters: {
          if (directory != null && directory.isNotEmpty)
            'directory': directory,
        },
        data: {'agent': agentId},
      ),
    );
  }

  /// Why a pairing code was refused.
  ///
  /// The server answers this endpoint with plain prose that already names the
  /// fix - "This pairing link expired or was already used. Run `opencode pair`
  /// to get a new one." Replacing that with "the server rejected this pairing
  /// link" threw away the only useful sentence in the exchange, and is what
  /// made a spent code look like a broken app.
  ///
  /// A used code answers `401`, not `400`, so the status alone cannot identify
  /// it: guessing from the status would have been wrong half the time. The body
  /// is read first, and the status only decides the wording when the server
  /// said nothing useful.
  static String redeemFailureMessage(Object? body, int status) {
    if (body is String) {
      final text = body.trim();
      if (text.isNotEmpty && text.length < 400) return text;
    }
    if (body is Map) {
      final tag = body['_tag'];
      if (tag is String && tag.isNotEmpty) return tag;
    }
    return switch (status) {
      401 || 404 || 410 =>
        'This pairing code has already been used, or has expired. Run '
            '`opencode pair` for a new one.',
      _ => 'The server refused this pairing link',
    };
  }

  static String? _cookieFrom(Response<dynamic> response) {
    final headers = response.headers;
    for (final entry in headers.map.entries) {
      if (entry.key.toLowerCase() != 'set-cookie') continue;
      final raw = entry.value.join(', ');
      final pair = raw.split(';').first.trim();
      if (pair.contains('=')) return pair;
    }
    return null;
  }
}

class PairingCode {
  const PairingCode({required this.code, required this.expiresInSeconds});

  final String code;
  final int expiresInSeconds;
}

class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this.profile);

  final ServerProfile profile;

  String? get _authorization => switch (profile.authMode) {
    AuthMode.basic => 'Basic ${base64Encode(utf8.encode('opencode:${profile.secret}'))}',
    AuthMode.cookie => null,
  };

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    switch (profile.authMode) {
      case AuthMode.basic:
        final token = _authorization;
        if (token != null) options.headers['Authorization'] = token;
      case AuthMode.cookie:
        options.headers['Cookie'] = profile.secret;
    }
    handler.next(options);
  }
}
