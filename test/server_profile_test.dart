import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/data/api.dart';

void main() {
  group('server profile naming', () {
    test('an unnamed server shows its host', () {
      final profile = ServerProfile.basic(
        baseUrl: 'example.test:4096',
        password: 'secret',
      );

      expect(profile.isNamed, isFalse);
      expect(profile.displayName, 'example.test:4096');
    });

    test('a name wins over the host', () {
      final profile = ServerProfile.basic(
        baseUrl: 'example.test:4096',
        password: 'secret',
        label: 'Work',
      );

      expect(profile.isNamed, isTrue);
      expect(profile.displayName, 'Work');
    });

    test('a blank or whitespace name is treated as no name', () {
      for (final label in ['', '   ', '\n']) {
        final profile = ServerProfile.basic(
          baseUrl: 'example.test:4096',
          password: 'secret',
          label: label,
        );
        expect(profile.isNamed, isFalse, reason: 'label "$label"');
        expect(profile.displayName, 'example.test:4096');
      }
    });

    test('a name is trimmed', () {
      final profile = ServerProfile.basic(
        baseUrl: 'example.test:4096',
        password: 'secret',
        label: '  Home  ',
      );

      expect(profile.displayName, 'Home');
    });
  });

  group('server profile storage', () {
    test('round-trips everything the list needs', () {
      final profile = ServerProfile(
        baseUrl: 'https://example.test',
        authMode: AuthMode.cookie,
        secret: 'cookie-value',
        label: 'Home',
        lastUsedAt: 1791874282944,
        version: '2.0.27',
      );

      final restored = ServerProfile.fromJson(profile.toJson());

      expect(restored.baseUrl, 'https://example.test');
      expect(restored.authMode, AuthMode.cookie);
      expect(restored.secret, 'cookie-value');
      expect(restored.label, 'Home');
      expect(restored.lastUsedAt, 1791874282944);
      expect(restored.version, '2.0.27');
    });

    test('an old record without the new fields still loads', () {
      // Profiles written by earlier builds have no label, lastUsedAt or
      // version; they must not vanish from the list.
      final restored = ServerProfile.fromJson(const {
        'baseUrl': '127.0.0.1:4096',
        'authMode': 'basic',
        'secret': 'old-password',
      });

      expect(restored.baseUrl, 'http://127.0.0.1:4096');
      expect(restored.secret, 'old-password');
      expect(restored.label, '');
      expect(restored.lastUsedAt, 0);
      expect(restored.version, '');
      expect(restored.isNamed, isFalse);
    });

    test('copyWith changes only what it is given', () {
      final profile = ServerProfile(
        baseUrl: 'https://example.test',
        authMode: AuthMode.cookie,
        secret: 'cookie',
        label: 'Work',
        lastUsedAt: 100,
        version: '2.0.27',
      );

      final renamed = profile.copyWith(label: 'Home');

      expect(renamed.label, 'Home');
      expect(renamed.lastUsedAt, 100);
      expect(renamed.version, '2.0.27');
      expect(renamed.secret, 'cookie');
      expect(renamed.baseUrl, 'https://example.test');
    });

    test('copyWith with a blank label clears the name', () {
      final profile = ServerProfile.basic(
        baseUrl: 'example.test',
        password: 'p',
        label: 'Work',
      );

      expect(profile.copyWith(label: '').isNamed, isFalse);
    });
  });

  group('address normalisation', () {
    test('adds a scheme when a bare address is typed', () {
      expect(
        ServerProfile.basic(baseUrl: '192.168.1.5:4096', password: 'p').baseUrl,
        'http://192.168.1.5:4096',
      );
    });

    test('strips trailing slashes', () {
      expect(
        ServerProfile.basic(
          baseUrl: 'https://tunnel.example/',
          password: 'p',
        ).baseUrl,
        'https://tunnel.example',
      );
    });

    test('keeps an explicit https scheme', () {
      expect(
        ServerProfile.basic(
          baseUrl: 'https://tunnel.example',
          password: 'p',
        ).baseUrl,
        'https://tunnel.example',
      );
    });
  });
}