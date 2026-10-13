import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/data/console.dart';

void main() {
  group('device code', () {
    test('reads what the Console returns', () {
      // Values as a real POST /auth/device/code returned them on 2026-10-13.
      const code = DeviceCode(
        deviceCode: 'dev_abc',
        userCode: 'HHMN-XMGJ',
        verificationUrl:
            'https://opencode.ai/console/device?user_code=HHMN-XMGJ',
        expiresInSeconds: 600,
        intervalSeconds: 5,
      );

      expect(code.userCode, 'HHMN-XMGJ');
      expect(code.expiresInSeconds, 600);
      expect(code.intervalSeconds, 5);
      expect(Uri.parse(code.verificationUrl).path, '/console/device');
      expect(code.expiresAt.isAfter(DateTime.now()), isTrue);
    });

    test('resolves the relative address the Console actually returns', () {
      // Live response on 2026-10-13: verification_uri_complete came back as a
      // path, not a URL. Opening that path as-is fails with ACTIVITY_NOT_FOUND.
      final api = ConsoleApi();
      final resolved = api.resolveVerificationUrl(
        '/console/device?user_code=FRJL-KPQR&client_id=opencode-mobile',
      );

      expect(
        resolved,
        'https://opencode.ai/console/device?user_code=FRJL-KPQR'
        '&client_id=opencode-mobile',
      );
      expect(Uri.parse(resolved!).scheme, 'https');
    });

    test('leaves an address that is already absolute alone', () {
      final api = ConsoleApi();

      expect(
        api.resolveVerificationUrl('https://example.test/device?code=1'),
        'https://example.test/device?code=1',
      );
    });

    test('falls back to verification_uri when the complete one is missing', () {
      final api = ConsoleApi();

      expect(api.resolveVerificationUrl('/console/device'),
          'https://opencode.ai/console/device');
      expect(api.resolveVerificationUrl(null), isNull);
      expect(api.resolveVerificationUrl('   '), isNull);
    });
  });

  group('workspace model parsing', () {
    test('reads limits and pricing', () {
      // One model as the workspace config returns it.
      final model = WorkspaceModel.fromJson('opencode-go', 'claude-haiku-5-5', {
        'name': 'Claude Haiku 5.5',
        'family': 'claude-haiku',
        'limit': {'context': 1000000, 'output': 128000},
        'cost': [
          {
            'input': 0.1,
            'output': 0.5,
            'cache': {'read': 0.01, 'write': 0.125},
          },
        ],
      });

      expect(model.name, 'Claude Haiku 5.5');
      expect(model.family, 'claude-haiku');
      expect(model.contextLimit, 1000000);
      expect(model.outputLimit, 128000);
      expect(model.costIn, 0.1);
      expect(model.costOut, 0.5);
      expect(model.costCacheRead, 0.01);
      expect(model.providerID, 'opencode-go');
      expect(model.id, 'claude-haiku-5-5');
      expect(model.isFree, isFalse);
    });

    test('treats a zero price as free', () {
      final model = WorkspaceModel.fromJson('opencode', 'big-pickle', {
        'name': 'Big Pickle',
        'limit': {'context': 200000, 'input': 160000, 'output': 32000},
        'cost': [
          {
            'input': 0,
            'output': 0,
            'cache': {'read': 0, 'write': 0},
          },
        ],
      });

      expect(model.isFree, isTrue);
      expect(model.inputLimit, 160000);
    });

    test('accepts a cost given as a single object', () {
      final model = WorkspaceModel.fromJson('opencode', 'x', {
        'name': 'X',
        'cost': {'input': 2, 'output': 8},
      });

      expect(model.costIn, 2);
      expect(model.costOut, 8);
    });

    test('survives a model with no limits and no price', () {
      final model = WorkspaceModel.fromJson('opencode', 'bare', {'name': 'Bare'});

      expect(model.name, 'Bare');
      expect(model.contextLimit, 0);
      expect(model.outputLimit, 0);
      expect(model.costIn, isNull);
      // Nothing to charge is still free.
      expect(model.isFree, isTrue);
    });

    test('falls back to the model id when no name is given', () {
      final model = WorkspaceModel.fromJson('opencode', 'anthropic/x', {});
      expect(model.name, 'anthropic/x');
      expect(model.providerID, 'opencode');
      // A model id may itself contain a slash and must not be split apart.
      expect(model.id, 'anthropic/x');
      expect(model.key, 'opencode/anthropic/x');
    });
  });

  group('session storage', () {
    test('round-trips through json', () {
      final session = ConsoleSession(
        accessToken: 'acc',
        refreshToken: 'ref',
        orgId: 'wrk_1',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      );

      final restored = ConsoleSession.fromJson(session.toJson());

      expect(restored.accessToken, 'acc');
      expect(restored.refreshToken, 'ref');
      expect(restored.orgId, 'wrk_1');
      expect(
        restored.expiresAt.difference(session.expiresAt).inSeconds.abs(),
        lessThanOrEqualTo(1),
      );
      expect(restored.isExpired, isFalse);
    });

    test('a past expiry reads as expired', () {
      final session = ConsoleSession(
        accessToken: 'a',
        refreshToken: 'r',
        orgId: '',
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );

      expect(session.isExpired, isTrue);
    });

    test('missing fields do not throw', () {
      final session = ConsoleSession.fromJson(const {});

      expect(session.accessToken, '');
      expect(session.refreshToken, '');
      expect(session.orgId, '');
      expect(session.isExpired, isTrue);
    });

    test('toString does not leak the tokens', () {
      final session = ConsoleSession(
        accessToken: 'secret-access',
        refreshToken: 'secret-refresh',
        orgId: 'wrk_1',
        expiresAt: DateTime(2030),
      );

      expect(session.toString(), isNot(contains('secret-access')));
      expect(session.toString(), isNot(contains('secret-refresh')));
    });
  });

  group('workspace summary', () {
    test('counts providers and free models', () {
      final workspace = Workspace(
        models: [
          WorkspaceModel.fromJson('opencode', 'a', {
            'name': 'A',
            'cost': [
              {'input': 0, 'output': 0},
            ],
          }),
          WorkspaceModel.fromJson('opencode', 'b', {
            'name': 'B',
            'cost': [
              {'input': 1, 'output': 2},
            ],
          }),
          WorkspaceModel.fromJson('opencode-go', 'c', {
            'name': 'C',
            'cost': [
              {'input': 0, 'output': 0},
            ],
          }),
        ],
      );

      expect(workspace.models.length, 3);
      expect(workspace.providerCount, 2);
      expect(workspace.freeCount, 2);
    });
  });
}