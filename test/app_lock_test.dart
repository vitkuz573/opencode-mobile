import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/state/app_lock.dart';
import 'package:opencode_mobile/src/ui/lock_screen.dart';

/// Secure storage backed by a map, behind the real MethodChannel name, so the
/// production `ProfileStore` runs unmodified.
class _MemorySecureStorage {
  _MemorySecureStorage() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, _handle);
  }

  static const _channel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  final values = <String, String>{};

  Future<Object?> _handle(MethodCall call) async {
    final args = call.arguments as Map;
    switch (call.method) {
      case 'read':
        return values[args['key']];
      case 'write':
        values[args['key'] as String] = args['value'] as String;
        return null;
      case 'delete':
        values.remove(args['key']);
        return null;
      case 'readAll':
        return Map<String, String>.from(values);
      case 'deleteAll':
        values.clear();
        return null;
      default:
        return null;
    }
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}

class _FakeGate extends BiometricGate {
  _FakeGate({
    this._preset = AppLockCapability.biometrics,
    List<bool> results = const [true],
  }) : _results = [...results];

  final AppLockCapability _preset;
  final List<bool> _results;

  /// When set, ceremonies wait on it instead of answering from the script.
  Completer<bool>? hold;

  int calls = 0;

  @override
  Future<AppLockCapability> capability() async => _preset;

  @override
  Future<bool> authenticate({required String reason}) async {
    calls++;
    final held = hold;
    if (held != null) return held.future;
    if (_results.isEmpty) return false;
    return _results.removeAt(0);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MemorySecureStorage storage;

  setUp(() {
    storage = _MemorySecureStorage();
  });

  tearDown(() {
    storage.dispose();
  });

  ProviderContainer makeContainer(_FakeGate gate) {
    final container = ProviderContainer(
      overrides: [biometricGateProvider.overrideWithValue(gate)],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('AppLockController', () {
    test('starts disabled and locked', () async {
      final container = makeContainer(_FakeGate());
      final state = await container.read(appLockProvider.future);

      expect(state.enabled, isFalse);
      expect(state.unlocked, isFalse);
    });

    test('enabling persists the switch and unlocks the session', () async {
      final container = makeContainer(_FakeGate());
      await container.read(appLockProvider.future);

      final ok = await container
          .read(appLockProvider.notifier)
          .setEnabled(true);

      expect(ok, isTrue);
      final state = container.read(appLockProvider).value!;
      expect(state.enabled, isTrue);
      expect(state.unlocked, isTrue);
      expect(state.busy, isFalse);
      expect(storage.values['opencode.appLock.v1'], '1');
    });

    test('enabling fails gracefully with nothing to authenticate with',
        () async {
      final container = makeContainer(
        _FakeGate(preset: AppLockCapability.none),
      );
      await container.read(appLockProvider.future);

      final ok = await container
          .read(appLockProvider.notifier)
          .setEnabled(true);

      expect(ok, isFalse);
      expect(container.read(appLockProvider).value!.enabled, isFalse);
    });

    test('a rejected ceremony keeps the switch off', () async {
      final container = makeContainer(_FakeGate(results: [false]));
      await container.read(appLockProvider.future);

      final ok = await container
          .read(appLockProvider.notifier)
          .setEnabled(true);

      expect(ok, isFalse);
      final state = container.read(appLockProvider).value!;
      expect(state.enabled, isFalse);
      expect(state.unlocked, isFalse);
      expect(state.busy, isFalse);
    });

    test('disabling needs a ceremony too', () async {
      final gate = _FakeGate(results: [true, false]);
      final container = makeContainer(gate);
      await container.read(appLockProvider.future);
      expect(
        await container.read(appLockProvider.notifier).setEnabled(true),
        isTrue,
      );

      final ok = await container
          .read(appLockProvider.notifier)
          .setEnabled(false);

      expect(ok, isFalse);
      expect(gate.calls, 2);
      expect(container.read(appLockProvider).value!.enabled, isTrue);
    });

    test('disabling with a ceremony turns the lock off', () async {
      final container = makeContainer(_FakeGate(results: [true, true]));
      await container.read(appLockProvider.future);
      await container.read(appLockProvider.notifier).setEnabled(true);

      final ok = await container
          .read(appLockProvider.notifier)
          .setEnabled(false);

      expect(ok, isTrue);
      final state = container.read(appLockProvider).value!;
      expect(state.enabled, isFalse);
      expect(storage.values['opencode.appLock.v1'], '0');
    });

    test('lock() closes an unlocked session but keeps the switch', () async {
      final container = makeContainer(_FakeGate());
      await container.read(appLockProvider.future);
      await container.read(appLockProvider.notifier).setEnabled(true);

      container.read(appLockProvider.notifier).lock();

      final state = container.read(appLockProvider).value!;
      expect(state.unlocked, isFalse);
      expect(state.enabled, isTrue);
    });

    test('lock() during a ceremony is a no-op', () async {
      final gate = _FakeGate();
      final container = makeContainer(gate);
      await container.read(appLockProvider.future);
      await container.read(appLockProvider.notifier).setEnabled(true);

      gate.hold = Completer<bool>();
      final pending = container
          .read(appLockProvider.notifier)
          .authenticateNow(reason: 'x');
      container.read(appLockProvider.notifier).lock();
      gate.hold!.complete(true);
      expect(await pending, isTrue);

      // The relock that fired mid-ceremony must not have discarded this.
      expect(container.read(appLockProvider).value!.unlocked, isTrue);
    });
  });

  group('LockScreen', () {
    testWidgets('unlocks through the button', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: LockScreen(
            capability: AppLockCapability.biometrics,
            autoPrompt: false,
            onUnlock: () async {
              calls++;
              return true;
            },
          ),
        ),
      );

      expect(
        find.text('Use your fingerprint to continue.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(find.text('Not recognized. Try again.'), findsNothing);
    });

    testWidgets('a rejection shows the error and allows a retry',
        (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: LockScreen(
            capability: AppLockCapability.biometrics,
            autoPrompt: false,
            onUnlock: () async {
              calls++;
              return false;
            },
          ),
        ),
      );

      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(find.text('Not recognized. Try again.'), findsOneWidget);
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(calls, 2);
    });

    testWidgets('names the PIN fallback when that is all there is',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: LockScreen(
            capability: AppLockCapability.deviceCredential,
            autoPrompt: false,
            onUnlock: () async => true,
          ),
        ),
      );

      expect(
        find.text('Enter your device PIN to continue.'),
        findsOneWidget,
      );
    });

    testWidgets('prompts once on its own', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: LockScreen(
            capability: AppLockCapability.biometrics,
            onUnlock: () async {
              calls++;
              return true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(calls, 1);
    });
  });
}
