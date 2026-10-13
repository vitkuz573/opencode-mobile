import 'package:dio/dio.dart';

import 'account_usage.dart';

/// Console API for opencode.ai: sign-in by device flow, then read the
/// workspace catalogue.
///
/// What a signed-in user can and cannot reach was verified against the live
/// service on 2026-10-13:
///
/// * `GET /api/v2/config` — workspace providers and models with their context
///   and output limits and their pricing. Available to any signed-in role.
/// * `GET /api/v1/budgets/members` — answers `403 Forbidden` for a user token.
///   Member budgets are behind service-account keys, so this client does not
///   pretend otherwise and never asks for one.
/// * Credit balance and invoices have no API at all; they live in the web
///   console only.
class ConsoleApi {
  ConsoleApi({Dio? dio, this.baseUrl = defaultBaseUrl})
    : _dio = dio ??
          Dio(
            BaseOptions(
              baseUrl: baseUrl,
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 45),
              validateStatus: (status) => status != null && status < 600,
            ),
          );

  static const defaultBaseUrl = 'https://opencode.ai/console';

  /// The Console accepts any client id; the device flow binds a workspace into
  /// the token when `supports_org_scope` is set.
  static const clientId = 'opencode-mobile';

  final Dio _dio;
  final String baseUrl;

  static const _deviceGrant =
      'urn:ietf:params:oauth:grant-type:device_code';
  static const _refreshGrant = 'refresh_token';

  /// Starts a sign-in. The user opens [DeviceCode.verificationUrl] and approves.
  Future<DeviceCode> startSignIn() async {
    final response = await _dio.post<dynamic>(
      '/auth/device/code',
      data: {
        'client_id': clientId,
        'supports_org_scope': 'true',
      },
      options: Options(
        contentType: 'application/x-www-form-urlencoded',
      ),
    );
    final body = _map(response.data);
    final url = resolveVerificationUrl(
      _str(body['verification_uri_complete']) ?? _str(body['verification_uri']),
    );
    if (url == null) {
      throw const ConsoleException('The server did not return a sign-in link');
    }
    return DeviceCode(
      deviceCode: _str(body['device_code']) ?? '',
      userCode: _str(body['user_code']) ?? '',
      verificationUrl: url,
      expiresInSeconds: _int(body['expires_in'], 600),
      intervalSeconds: _int(body['interval'], 5),
    );
  }

  /// One poll of the sign-in. Returns `null` while the user has not approved
  /// yet, which is the normal case, not an error.
  Future<ConsoleSession?> pollSignIn(DeviceCode code) async {
    try {
      final response = await _dio.post<dynamic>(
        '/auth/device/token',
        data: {
          'grant_type': _deviceGrant,
          'device_code': code.deviceCode,
          'client_id': clientId,
        },
        options: Options(contentType: 'application/x-www-form-urlencoded'),
      );
      return _session(response.data);
    } on DioException catch (error) {
      final tag = _errorTag(error);
      if (tag == 'authorization_pending' || tag == 'slow_down') return null;
      if (error.response?.statusCode == 400) return null;
      throw ConsoleException(_describe(error), statusCode: error.response?.statusCode);
    }
  }

  /// Exchanges a refresh token. Refresh tokens are single use: reusing an old
  /// one revokes the whole session, so the result must be stored immediately.
  Future<ConsoleSession> refresh(ConsoleSession current) async {
    final response = await _dio.post<dynamic>(
      '/auth/device/token',
      data: {
        'grant_type': _refreshGrant,
        'refresh_token': current.refreshToken,
        'client_id': clientId,
      },
      options: Options(contentType: 'application/x-www-form-urlencoded'),
    );
    final session = _session(response.data);
    if (session == null) {
      throw const ConsoleException('The session could not be renewed');
    }
    return session;
  }

  ConsoleSession? _session(Object? data) {
    final body = _map(data);
    final access = _str(body['access_token']);
    if (access == null) return null;
    final now = DateTime.now();
    return ConsoleSession(
      accessToken: access,
      refreshToken: _str(body['refresh_token']) ?? '',
      orgId: _str(body['org_id']) ?? '',
      expiresAt: now.add(Duration(seconds: _int(body['expires_in'], 3600))),
    );
  }

  /// Account spending, straight from the Console.
  ///
  /// `GET /api/v2/usage/export` is the endpoint the Console's own web app calls
  /// to draw its usage page. It is not part of the documented public API, but
  /// it answers a signed-in user token: verified on 2026-10-13 with `range`
  /// of `7d`, `30d` and `90d` all returning CSV. The documented
  /// `/api/v1/usage/export` is the deprecated shape and answers `403` here.
  ///
  /// The body is CSV, newest day first, one row per day x account x model.
  Future<AccountUsage> accountUsage(
    ConsoleSession session,
    AccountUsageRange range,
  ) async {
    final token = await _accessToken(session);
    final response = await _dio.get<String>(
      '/api/v2/usage/export',
      queryParameters: {'range': range.wire},
      options: Options(
        responseType: ResponseType.plain,
        headers: {
          'Authorization': 'Bearer $token',
          // A streaming CSV body; ask for CSV and accept whatever comes back.
          'Accept': 'text/csv, application/json;q=0.5, */*;q=0.1',
        },
      ),
    );
    final usage = AccountUsage.parseCsv(response.data ?? '');
    return AccountUsage(usage.rows, fetchedAt: DateTime.now());
  }

  /// The signed-in account, as the Console knows it.
  ///
  /// `/api/account/profile` is the Console's own endpoint and, unlike the
  /// documented API, it answers a user token. The documented surface has no
  /// identity endpoint at all, so this is where an email address comes from -
  /// the usage export carries it per row too.
  Future<String> accountEmail(ConsoleSession session) async {
    final token = await _accessToken(session);
    try {
      final response = await _dio.get<dynamic>(
        '/api/account/profile',
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
          },
        ),
      );
      final body = _map(response.data);
      return _str(body['email']) ?? '';
    } on DioException {
      return '';
    }
  }

  Future<String> _accessToken(ConsoleSession session) async =>
      (await _validSession(session)).accessToken;

  /// The workspace: every model it can run, with limits and pricing.
  ///
  /// Returns the session it actually used, which may be a renewed one. Refresh
  /// tokens are single use, so the caller must store whatever comes back.
  Future<(ConsoleSession, Workspace)> workspace(ConsoleSession session) async {
    final current = await _validSession(session);
    final response = await _dio.get<dynamic>(
      '/api/v2/config',
      options: Options(
        headers: {
          'Authorization': 'Bearer ${current.accessToken}',
          if (current.orgId.isNotEmpty) 'x-org-id': current.orgId,
        },
      ),
    );
    final body = _map(response.data);
    final providers = _map(body['providers']);
    final models = <WorkspaceModel>[];
    for (final provider in providers.entries) {
      final entry = _map(provider.value);
      for (final model in _map(entry['models']).entries) {
        models.add(
          WorkspaceModel.fromJson(provider.key, model.key, _map(model.value)),
        );
      }
    }
    return (current, Workspace(models: models));
  }

  /// Renews the session when it is about to run out, so a read never goes to
  /// the wire with a token that dies mid-flight.
  Future<ConsoleSession> _validSession(ConsoleSession session) async {
    final aliveForAWhile = session.expiresAt.isAfter(
      DateTime.now().add(const Duration(minutes: 2)),
    );
    if (aliveForAWhile || session.refreshToken.isEmpty) return session;
    return refresh(session);
  }

  /// Turns a verification address into something a browser can open.
  ///
  /// The Console answers with a path such as `/console/device?user_code=...`,
  /// not a full URL, so it has to be resolved against the console origin.
  /// Handing that path to Android yields ACTIVITY_NOT_FOUND, because no app
  /// claims a scheme-less address.
  String? resolveVerificationUrl(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final parsed = Uri.tryParse(value.trim());
    if (parsed == null) return null;
    if (parsed.hasScheme) return parsed.toString();
    final origin = Uri.parse(baseUrl);
    return origin.resolveUri(parsed).toString();
  }

  static String? _errorTag(DioException error) {
    final body = error.response?.data;
    if (body is Map && body['_tag'] is String) return body['_tag'] as String;
    return null;
  }

  static String _describe(DioException error) => switch (error.type) {
    DioExceptionType.connectionError =>
      'Cannot reach opencode.ai — check the network',
    DioExceptionType.connectionTimeout ||
    DioExceptionType.receiveTimeout => 'opencode.ai did not answer in time',
    _ => error.message ?? 'Request failed',
  };

  static Map<String, Object?> _map(Object? v) =>
      v is Map ? v.cast<String, Object?>() : const <String, Object?>{};

  static String? _str(Object? v) => v is String ? v : null;

  static int _int(Object? v, int fallback) => v is num ? v.toInt() : fallback;
}

class ConsoleException implements Exception {
  const ConsoleException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class DeviceCode {
  const DeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.expiresInSeconds,
    required this.intervalSeconds,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUrl;
  final int expiresInSeconds;
  final int intervalSeconds;

  DateTime get expiresAt =>
      DateTime.now().add(Duration(seconds: expiresInSeconds));
}

class ConsoleSession {
  const ConsoleSession({
    required this.accessToken,
    required this.refreshToken,
    required this.orgId,
    required this.expiresAt,
  });

  factory ConsoleSession.fromJson(Map<String, Object?> json) => ConsoleSession(
    accessToken: json['accessToken'] as String? ?? '',
    refreshToken: json['refreshToken'] as String? ?? '',
    orgId: json['orgId'] as String? ?? '',
    // A record with no readable expiry is treated as expired, so a corrupt
    // store cannot look like a live session.
    expiresAt:
        DateTime.tryParse(json['expiresAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );

  final String accessToken;
  final String refreshToken;
  final String orgId;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  Map<String, Object?> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'orgId': orgId,
    'expiresAt': expiresAt.toIso8601String(),
  };

  @override
  String toString() => 'ConsoleSession(org=$orgId, expires=$expiresAt)';
}

/// One model the workspace can run, as the Console describes it.
class WorkspaceModel {
  const WorkspaceModel({
    required this.providerID,
    required this.id,
    required this.key,
    required this.name,
    required this.family,
    required this.contextLimit,
    required this.inputLimit,
    required this.outputLimit,
    required this.costIn,
    required this.costOut,
    required this.costCacheRead,
  });

  /// The workspace config nests models under their provider, so the provider is
  /// passed in separately; [key] is the model id on its own.
  factory WorkspaceModel.fromJson(
    String providerID,
    String key,
    Map<String, Object?> json,
  ) {
    final limit = _map(json['limit']);
    final costEntries = json['cost'];
    // `cost` arrives either as one object or as a list of tiers; the workspace
    // quote always uses the first tier.
    final cost = _map(
      costEntries is List ? costEntries.firstOrNull : costEntries,
    );
    final cache = _map(cost['cache']);

    double? price(Object? v) => v is num ? v.toDouble() : null;

    return WorkspaceModel(
      providerID: providerID,
      id: key,
      // `key` is the identity used for sorting and display; a model id may
      // itself contain a slash, so it is not split.
      key: '$providerID/$key',
      name: (json['name'] as String?) ?? key,
      family: (json['family'] as String?) ?? '',
      contextLimit: _int(limit['context']),
      inputLimit: _int(limit['input']),
      outputLimit: _int(limit['output']),
      costIn: price(cost['input']),
      costOut: price(cost['output']),
      costCacheRead: price(cache['read']),
    );
  }

  /// Provider the model belongs to, e.g. `opencode` or `opencode-go`.
  final String providerID;

  /// Model id on its own, e.g. `claude-haiku-5-5`.
  final String id;

  /// `providerID/id`, the form the server's own APIs use.
  final String key;

  final String name;
  final String family;
  final int contextLimit;
  final int inputLimit;
  final int outputLimit;
  final double? costIn;
  final double? costOut;
  final double? costCacheRead;

  bool get isFree => (costIn ?? 0) == 0 && (costOut ?? 0) == 0;

  static Map<String, Object?> _map(Object? v) =>
      v is Map ? v.cast<String, Object?>() : const <String, Object?>{};

  static int _int(Object? v) => v is num ? v.toInt() : 0;
}

extension _FirstOrNull<E> on List<E> {
  E? get firstOrNull => isEmpty ? null : first;
}

class Workspace {
  const Workspace({required this.models});

  final List<WorkspaceModel> models;

  int get providerCount =>
      models.map((m) => m.providerID).toSet().length;

  int get freeCount => models.where((m) => m.isFree).length;
}