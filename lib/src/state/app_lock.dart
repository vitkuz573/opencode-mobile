import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';

import 'providers.dart';

/// What the device can offer as an app lock, strongest first.
///
/// `deviceCredential` means a secure lock screen (PIN, pattern, password)
/// with no biometrics enrolled. It is claimed on the strength of
/// `isDeviceSupported`, which does not verify that a lock screen is actually
/// set — a device with neither then simply fails authentication, and the lock
/// screen says so instead of hanging.
enum AppLockCapability { none, deviceCredential, biometrics }

/// Test seam over `local_auth`, in the established style: the real plugin by
/// default, a stub by subclassing in tests. Every platform failure degrades to
/// "no" rather than throwing, because a missing sensor must never crash the
/// gate that guards the whole app.
class BiometricGate {
  BiometricGate({LocalAuthentication? auth})
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  Future<AppLockCapability> capability() async {
    try {
      if (await _auth.canCheckBiometrics) {
        final available = await _auth.getAvailableBiometrics();
        if (available.isNotEmpty) return AppLockCapability.biometrics;
      }
      if (await _auth.isDeviceSupported()) {
        return AppLockCapability.deviceCredential;
      }
      return AppLockCapability.none;
    } on PlatformException {
      return AppLockCapability.none;
    }
  }

  /// One authentication ceremony. `biometricOnly` stays false on purpose: the
  /// device PIN is the fallback, so removing every enrolled fingerprint does
  /// not brick the app — it just demotes the lock to the PIN.
  Future<bool> authenticate({required String reason}) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        // Kept across backgrounding: confirming the device PIN pauses our
        // activity, and without this the ceremony would die there.
        persistAcrossBackgrounding: true,
        authMessages: const <AuthMessages>[
          AndroidAuthMessages(
            signInTitle: 'Unlock OpenCode',
            cancelButton: 'Cancel',
          ),
        ],
      );
    } on PlatformException {
      return false;
    }
  }
}

final biometricGateProvider = Provider<BiometricGate>(
  (ref) => BiometricGate(),
);

/// What this device offers, resolved once per session. Re-enrolling a finger
/// mid-session does not refresh it; the lock screen only needs it to pick its
/// wording, and the ceremony itself always asks the OS for the truth.
final appLockCapabilityProvider = FutureProvider<AppLockCapability>(
  (ref) => ref.watch(biometricGateProvider).capability(),
);

class AppLockState {
  const AppLockState({
    this.enabled = false,
    this.unlocked = false,
    this.busy = false,
    this.authenticating = false,
  });

  /// Whether the gate is on at all.
  final bool enabled;

  /// Whether this session already passed it. Never persisted: every launch
  /// starts locked.
  final bool unlocked;

  /// An enable/disable round-trip is in flight; the settings switch waits.
  final bool busy;

  /// An authentication ceremony is in flight; backgrounding must not relock.
  final bool authenticating;

  AppLockState copyWith({
    bool? enabled,
    bool? unlocked,
    bool? busy,
    bool? authenticating,
  }) => AppLockState(
    enabled: enabled ?? this.enabled,
    unlocked: unlocked ?? this.unlocked,
    busy: busy ?? this.busy,
    authenticating: authenticating ?? this.authenticating,
  );
}

/// Owns the app lock: the persisted switch, the session unlock, and the
/// relock on backgrounding.
class AppLockController extends AsyncNotifier<AppLockState> {
  @override
  Future<AppLockState> build() async {
    final enabled = await ref.read(profileStoreProvider).loadAppLockEnabled();
    return AppLockState(enabled: enabled);
  }

  BiometricGate get _gate => ref.read(biometricGateProvider);

  /// Runs one ceremony and records the success. A failure leaves `unlocked`
  /// untouched: declining to disable the lock must not lock out a session
  /// that is already open.
  Future<bool> authenticateNow({required String reason}) async {
    final before = state.value ?? const AppLockState();
    state = AsyncData(before.copyWith(authenticating: true));
    final ok = await _gate.authenticate(reason: reason);
    final after = state.value ?? before;
    state = AsyncData(
      after.copyWith(
        authenticating: false,
        unlocked: ok ? true : after.unlocked,
      ),
    );
    return ok;
  }

  /// Flips the switch, proving it is the owner both ways: enabling without a
  /// ceremony would let anyone with the unlocked phone turn the lock on and
  /// the owner out, and disabling without one would let them turn it off.
  /// Returns whether the switch moved.
  Future<bool> setEnabled(bool value) async {
    final before = state.value ?? const AppLockState();
    state = AsyncData(before.copyWith(busy: true));
    try {
      if (value) {
        final capability = await _gate.capability();
        if (capability == AppLockCapability.none) {
          state = AsyncData(before.copyWith(busy: false));
          return false;
        }
      }
      final ok = await authenticateNow(
        reason: value
            ? 'Confirm it is you to turn on the app lock'
            : 'Confirm it is you to turn off the app lock',
      );
      if (!ok) {
        final after = state.value ?? before;
        state = AsyncData(after.copyWith(busy: false));
        return false;
      }
      await ref.read(profileStoreProvider).saveAppLockEnabled(value);
      final after = state.value ?? before;
      state = AsyncData(after.copyWith(enabled: value, busy: false));
      return true;
    } catch (_) {
      state = AsyncData((state.value ?? before).copyWith(busy: false));
      return false;
    }
  }

  /// Relocks on backgrounding. A no-op while a ceremony is in flight:
  /// confirming the device PIN pauses the activity, and relocking there would
  /// discard the success that is about to arrive.
  void lock() {
    final current = state.value;
    if (current == null || current.authenticating) return;
    state = AsyncData(current.copyWith(unlocked: false));
  }
}

final appLockProvider = AsyncNotifierProvider<AppLockController, AppLockState>(
  AppLockController.new,
);
