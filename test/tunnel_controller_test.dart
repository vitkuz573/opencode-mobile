import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/runtime/tunnel/tunnel_api.dart';
import 'package:opencode_mobile/src/runtime/tunnel/tunnel_bridge.dart';
import 'package:opencode_mobile/src/runtime/tunnel/tunnel_controller.dart';
import 'package:opencode_mobile/src/runtime/tunnel/tunnel_identity.dart';
import 'package:opencode_mobile/src/runtime/tunnel/tunnel_store.dart';

void main() {
  late Directory temporary;
  late TunnelStore store;
  late _FakeService service;
  late int bridgesBuilt;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('tunnel-controller');
    store = TunnelStore(Directory('${temporary.path}/opentunnel'));
    service = _FakeService();
    bridgesBuilt = 0;
  });

  tearDown(() async {
    if (temporary.existsSync()) await temporary.delete(recursive: true);
  });

  ProviderContainer open() {
    final container = ProviderContainer(
      overrides: [
        tunnelStoreProvider.overrideWith((ref) async => store),
        tunnelServiceProvider.overrideWithValue(service),
        tunnelIdentityFactoryProvider.overrideWithValue(
          (hostname) => TunnelIdentity(
            hostname: hostname,
            privateKeyPem: 'KEY',
            certificationRequest: 'CSR',
          ),
        ),
        tunnelBridgeBuilderProvider.overrideWithValue(
          ({
            required String tunnelId,
            required String token,
            required String hostname,
            required VisitorPipeFactory pipes,
          }) {
            bridgesBuilt++;
            return service.bridge;
          },
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<Uri> publish(ProviderContainer container) => container
          .read(tunnelControllerProvider.notifier)
          .publish(targetHost: '127.0.0.1', targetPort: 4096);

  group('first publish', () {
    test('claims, certifies and comes up', () async {
      final container = open();
      final url = await publish(container);

      expect(url.toString(), 'https://abc123.opentunnel.xyz/');
      expect(service.claims, 1);
      expect(service.certificateRequests, ['CSR']);
      expect(container.read(tunnelControllerProvider).isLive, isTrue);
    });

    test('keeps what it will need to come back', () async {
      final container = open();
      await publish(container);

      final saved = await store.read();
      expect(saved!.id, 'abc123');
      expect(saved.token, 'tok');
      expect(saved.privateKeyPem, 'KEY');
      expect(saved.hasCertificate, isTrue);
    });
  });

  group('publishing again', () {
    test('does not claim a second hostname', () async {
      // A hostname somebody has bookmarked must not change because the app was
      // closed and opened again.
      final container = open();
      await publish(container);
      await container.read(tunnelControllerProvider.notifier).stop();
      await publish(container);

      expect(service.claims, 1);
      expect(bridgesBuilt, 2);
    });

    test('does not ask for a second certificate', () async {
      final container = open();
      await publish(container);
      await container.read(tunnelControllerProvider.notifier).stop();
      await publish(container);

      expect(service.certificateRequests, hasLength(1));
    });

    test('finishes a provisioning that was interrupted after the key', () async {
      // The key is on disk and the certificate never arrived: the next run has
      // to resume, not claim a hostname it has already been given.
      await store.writeIdentity(
        id: 'abc123',
        token: 'tok',
        privateKeyPem: 'KEY',
        certificationRequest: 'CSR',
      );
      final container = open();
      await publish(container);

      expect(service.claims, 0);
      expect(service.certificateRequests, hasLength(1));
    });
  });

  group('stopping', () {
    test('keeps the tunnel, because the address is somebody else\'s', () async {
      final container = open();
      await publish(container);
      await container.read(tunnelControllerProvider.notifier).stop();

      expect(await store.read(), isNotNull);
      expect(service.deleted, isEmpty);
      expect(container.read(tunnelControllerProvider).isLive, isFalse);
    });

    test('forget gives the hostname back', () async {
      final container = open();
      await publish(container);
      await container.read(tunnelControllerProvider.notifier).forget();

      expect(service.deleted, ['abc123']);
      expect(await store.read(), isNull);
    });
  });

  group('when things go wrong', () {
    test('reports a service that will not issue a certificate', () async {
      service.certificateFails = 'validation went wrong';
      final container = open();

      await expectLater(publish(container), throwsA(isA<TunnelApiException>()));
      final state = container.read(tunnelControllerProvider);
      expect(state.phase, TunnelPhase.failed);
      expect(state.message, contains('validation went wrong'));
    });

    test('reports a bridge that cannot attach', () async {
      service.attachFails = true;
      final container = open();

      await expectLater(publish(container), throwsA(isA<BridgeFailure>()));
      expect(container.read(tunnelControllerProvider).phase, TunnelPhase.failed);
    });

    test('says so rather than leaving the button spinning', () async {
      final container = open();
      final started = publish(container);
      // Claimed, then waiting on the certificate.
      await Future<void>.delayed(Duration.zero);
      expect(container.read(tunnelControllerProvider).isBusy, isTrue);
      await started;
    });
  });
}

/// A service that answers instantly and counts what it was asked, so the tests
/// are about this app's behaviour rather than the service's mood.
class _FakeService implements TunnelService {
  var claims = 0;
  final certificateRequests = <String>[];
  final deleted = <String>[];
  String? certificateFails;
  bool attachFails = false;

  late final bridge = _FakeBridge(() => attachFails);

  @override
  Future<ClaimedTunnel> claim() async {
    claims++;
    return const ClaimedTunnel(
      TunnelInfo(
        id: 'abc123',
        hostname: 'abc123.opentunnel.xyz',
        reachability: TunnelReachability.offline,
      ),
      'tok',
    );
  }

  @override
  Future<CertificateInfo> requestCertificate(
    String id,
    String token,
    String csr,
  ) async {
    certificateRequests.add(csr);
    return const CertificateInfo.issuing();
  }

  @override
  Future<Certificate> awaitCertificate(String id, String token) async {
    final failure = certificateFails;
    if (failure != null) {
      throw TunnelApiException(
        'The tunnel certificate could not be issued: $failure',
      );
    }
    return Certificate(
      pem: '-----BEGIN CERTIFICATE-----\nleaf\n-----END CERTIFICATE-----\n',
      chainPem: '-----BEGIN CERTIFICATE-----\nissuer\n-----END CERTIFICATE-----\n',
      expiry: 'soon',
    );
  }

  @override
  Future<void> delete(String id, String token) async => deleted.add(id);
}

/// A bridge whose only job is to say it attached, or to refuse.
class _FakeBridge implements TunnelBridgeHandle {
  _FakeBridge(this._attachFails);

  final bool Function() _attachFails;
  final _controller = StreamController<BridgeState>.broadcast();
  var stopCalled = false;

  @override
  Stream<BridgeState> get states => _controller.stream;

  @override
  Future<void> start() async {
    if (_attachFails()) {
      throw const BridgeFailure(
        'The tunnel service refused this device: bad_token.',
        isFinal: true,
      );
    }
    _controller.add(BridgeState.attached);
  }

  @override
  Future<void> stop() async => stopCalled = true;
}