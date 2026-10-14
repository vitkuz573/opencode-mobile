import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../state/providers.dart';
import 'local_visitor_pipes.dart';
import 'tunnel_api.dart';
import 'tunnel_bridge.dart';
import 'tunnel_identity.dart';
import 'tunnel_store.dart';

/// How far along publishing is.
enum TunnelPhase {
  /// Not published.
  idle,

  /// Asking the service for a hostname.
  claiming,

  /// Waiting for the certificate that lets TLS be terminated here.
  provisioning,

  /// The tunnel exists; the bridge to the service is being established.
  connecting,

  /// Published and answering.
  live,

  /// Something went wrong, said so in [TunnelState.message].
  failed,
}

class TunnelState {
  const TunnelState({
    this.phase = TunnelPhase.idle,
    this.url,
    this.message,
  });

  final TunnelPhase phase;

  /// Where a visitor reaches this tunnel, once there is one.
  final Uri? url;

  /// What went wrong, or why it is waiting.
  final String? message;

  bool get isLive => phase == TunnelPhase.live;

  /// Whether something is happening that the user is waiting for.
  bool get isBusy =>
      phase == TunnelPhase.claiming ||
      phase == TunnelPhase.provisioning ||
      phase == TunnelPhase.connecting;

  TunnelState copyWith({
    TunnelPhase? phase,
    Uri? url,
    String? message,
    bool clearMessage = false,
  }) =>
      TunnelState(
        phase: phase ?? this.phase,
        url: url ?? this.url,
        message: clearMessage ? null : (message ?? this.message),
      );
}

/// Publishes this phone's server to the internet, and owns everything that
/// takes: the hostname, the certificate, and the bridge carrying visitors to the
/// server.
///
/// The tunnel is kept between runs. A hostname is something a person may have
/// bookmarked and a token is shown exactly once, so re-claiming on every launch
/// would quietly change the address of a server other people are already pointed
/// at.
///
/// Everything it needs comes from `ref`, which is what lets a test replace the
/// service, the storage or the bridge without a network or a phone.
class TunnelController extends Notifier<TunnelState> {
  TunnelBridgeHandle? _bridge;

  @override
  TunnelState build() {
    ref.onDispose(() => unawaited(_bridge?.stop()));
    return const TunnelState();
  }

  TunnelService get _api => ref.read(tunnelServiceProvider);

  /// The store resolves asynchronously, because the directory it lives in is
  /// asked of the platform. Reading it as a value would fail on the very first
  /// call, which is the only call that matters.
  Future<TunnelStore> _store() async => await ref.read(tunnelStoreProvider.future);

  /// Publishes, or returns the tunnel that is already published.
  ///
  /// Safe to call twice: a tunnel that already has its certificate goes
  /// straight to connecting, and only the first run ever claims a hostname.
  Future<Uri> publish({
    required String targetHost,
    required int targetPort,
  }) async {
    if (state.isLive) return state.url!;

    state = const TunnelState(phase: TunnelPhase.claiming);
    try {
      final saved = await _provisioned();
      final log = ref.read(appLogProvider);
      final pipes = LocalVisitorPipes(
        // Leaf first, then the chain: that is the order BoringSSL reads a
        // certificate in, and a chain left out leaves the visitor with an
        // anchor it cannot get to.
        certificateChainPem: utf8.encode('${saved.certificate!}\n${saved.chain!}'),
        privateKeyPem: utf8.encode(saved.privateKeyPem!),
        targetHost: targetHost,
        targetPort: targetPort,
        onProblem: (message) => log.warn('tunnel', message),
      );
      final bridge = ref.read(tunnelBridgeBuilderProvider)(
        tunnelId: saved.id,
        token: saved.token,
        hostname: saved.hostname,
        pipes: pipes,
      );
      _bridge = bridge;
      bridge.states.listen((next) {
        if (!ref.mounted || next != BridgeState.attached) return;
        state = state.copyWith(phase: TunnelPhase.live, clearMessage: true);
      });

      state = state.copyWith(phase: TunnelPhase.connecting, url: saved.url);
      await bridge.start();
      state = state.copyWith(phase: TunnelPhase.live, clearMessage: true);
      return saved.url;
    } on BridgeFailure catch (failure) {
      _fail(failure.message);
      rethrow;
    } on TunnelApiException catch (failure) {
      _fail(failure.message);
      rethrow;
    }
  }

  /// Stops answering, and keeps the tunnel so publishing again is immediate.
  ///
  /// The tunnel is not deleted: doing that without being asked would change the
  /// address of a server other people are pointed at, over a tap that only said
  /// to stop.
  Future<void> stop() async {
    await _bridge?.stop();
    _bridge = null;
    state = const TunnelState();
  }

  /// Stops answering and gives the hostname back, so the next publish claims a
  /// fresh one. This is what stopping for good means.
  Future<void> forget() async {
    final saved = await (await _store()).read();
    await stop();
    if (saved != null) {
      try {
        await _api.delete(saved.id, saved.token);
      } on TunnelApiException {
        // The tunnel is being abandoned either way; a service that will not
        // take the deletion is a service that will expire it.
      }
    }
    await (await _store()).clear();
  }

  /// Whether a tunnel already exists, so publishing again has nothing to claim.
  Future<Uri?> publishedUrl() async => (await (await _store()).read())?.url;

  Future<SavedTunnel> _provisioned() async {
    final existing = await (await _store()).read();
    final log = ref.read(appLogProvider);
    if (existing != null && existing.hasCertificate) {
      log.info('tunnel', 'reusing ${existing.hostname}');
      return existing;
    }

    state = state.copyWith(phase: TunnelPhase.provisioning);
    final claimed = existing ?? await _claim();
    log.info('tunnel', 'tunnel ${claimed.id} at ${claimed.hostname}');

    if (!claimed.hasCertificate) {
      // The key and the request are written before the request is sent, so an
      // interrupted run resumes rather than stranding a hostname nobody can
      // certify. A request already on disk is reused: the service binds a tunnel
      // to the first request it sees, and asking again with a new key would
      // simply be refused.
      final stored = claimed.certificationRequest;
      final String certificationRequest;
      final String privateKeyPem;
      if (stored != null && claimed.privateKeyPem != null) {
        certificationRequest = stored;
        privateKeyPem = claimed.privateKeyPem!;
      } else {
        final identity = ref.read(tunnelIdentityFactoryProvider)(claimed.hostname);
        certificationRequest = identity.certificationRequest;
        privateKeyPem = identity.privateKeyPem;
      }
      await (await _store()).writeIdentity(
        id: claimed.id,
        token: claimed.token,
        privateKeyPem: privateKeyPem,
        certificationRequest: certificationRequest,
      );
      await _api.requestCertificate(claimed.id, claimed.token, certificationRequest);
      final certificate = await _api.awaitCertificate(claimed.id, claimed.token);
      log.info('tunnel', 'certificate issued');
      await (await _store()).writeCertificate(certificate.pem, certificate.chainPem);
    }

    final updated = await (await _store()).read();
    if (updated == null || !updated.hasCertificate) {
      throw const TunnelApiException(
        'The tunnel certificate could not be saved, so the tunnel cannot serve '
        'traffic.',
      );
    }
    return updated;
  }

  Future<SavedTunnel> _claim() async {
    final claimed = await _api.claim();
    return SavedTunnel(
      id: claimed.info.id,
      hostname: claimed.info.hostname,
      token: claimed.token,
    );
  }

  void _fail(String message) {
    if (!ref.mounted) return;
    state = state.copyWith(phase: TunnelPhase.failed, message: message);
  }
}

typedef BridgeBuilder = TunnelBridgeHandle Function({
  required String tunnelId,
  required String token,
  required String hostname,
  required VisitorPipeFactory pipes,
});

final tunnelControllerProvider =
    NotifierProvider<TunnelController, TunnelState>(TunnelController.new);

final tunnelServiceProvider = Provider<TunnelService>((ref) {
  return TunnelApi(
    Dio(
      BaseOptions(
        baseUrl: TunnelApi.baseUrl,
        // The service is a plain HTTP API, and a phone on a slow connection is
        // the ordinary case rather than the exception.
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
      ),
    ),
  );
});

/// Where the tunnel's files live, under the app's own support directory.
final tunnelStoreProvider = FutureProvider<TunnelStore>((ref) async {
  final support = (await getApplicationSupportDirectory()).path;
  return TunnelStore(Directory('$support/opentunnel'));
});

/// Builds the real bridge. Replaced in tests, where there is no service to
/// connect to and no certificate to serve.
final tunnelBridgeBuilderProvider = Provider<BridgeBuilder>((ref) {
  final log = ref.read(appLogProvider);
  return ({
    required String tunnelId,
    required String token,
    required String hostname,
    required VisitorPipeFactory pipes,
  }) =>
      TunnelBridge(
        tunnelId: tunnelId,
        token: token,
        hostname: hostname,
        pipes: pipes,
        onProblem: (message) => log.warn('tunnel', message),
        onNotice: (message) => log.info('tunnel', message),
      );
});

/// Mints the key and the request. Replaced in tests so a run is comparable with
/// the last one.
final tunnelIdentityFactoryProvider = Provider<TunnelIdentity Function(String)>(
  (ref) => TunnelIdentity.create,
);