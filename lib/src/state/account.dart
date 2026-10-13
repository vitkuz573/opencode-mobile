import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/account_usage.dart';
import '../data/console.dart';
import 'providers.dart' show profileStoreProvider;

/// Account state for opencode.ai. Only one thing can happen at a time: either
/// signed out, waiting for the user to approve a device code, or signed in.
sealed class AccountState {
  const AccountState();
}

class AccountSignedOut extends AccountState {
  const AccountSignedOut();
}

class AccountAwaitingApproval extends AccountState {
  const AccountAwaitingApproval({
    required this.code,
    required this.poll,
  });

  final DeviceCode code;
  final Future<AccountSignedIn?> poll;
}

class AccountSignedIn extends AccountState {
  const AccountSignedIn({required this.session, required this.workspace});

  final ConsoleSession session;
  final Workspace workspace;
}

class AccountError extends AccountState {
  const AccountError(this.message, {this.previous});

  final String message;
  final AccountState? previous;
}

final consoleApiProvider = Provider<ConsoleApi>((ref) => ConsoleApi());

final accountProvider =
    AsyncNotifierProvider<AccountController, AccountState>(
      AccountController.new,
    );

/// Holds the signed-in session and the workspace catalogue.
/// Window the account usage screen reports on.
///
/// Defaults to 90 days because that is what the Console's own usage page
/// shows. A narrower default reads as a bug against it: the account spent on
/// free models in early September, so a 30-day window reports fewer requests
/// and fewer tokens for exactly the same money.
class AccountUsageWindow extends Notifier<AccountUsageRange> {
  @override
  AccountUsageRange build() => AccountUsageRange.quarter;

  void select(AccountUsageRange range) => state = range;
}

final accountUsageRangeProvider =
    NotifierProvider<AccountUsageWindow, AccountUsageRange>(
      AccountUsageWindow.new,
    );

/// What the opencode.ai account spent, read from the Console.
final accountUsageProvider = FutureProvider<AccountUsage>((ref) async {
  final account = ref.watch(accountProvider).value;
  if (account is! AccountSignedIn) return AccountUsage.empty;
  return ref
      .read(consoleApiProvider)
      .accountUsage(account.session, ref.watch(accountUsageRangeProvider));
});

/// The signed-in account's address, when the Console reports one.
///
/// The documented API has no identity endpoint; this is the Console's own
/// `/api/account/profile`. Failure is not worth surfacing - the name is a
/// label, not a feature.
final accountEmailProvider = FutureProvider<String>((ref) async {
  final account = ref.watch(accountProvider).value;
  if (account is! AccountSignedIn) return '';
  return ref.read(consoleApiProvider).accountEmail(account.session);
});

class AccountController extends AsyncNotifier<AccountState> {
  @override
  Future<AccountState> build() async {
    final session = await ref.read(profileStoreProvider).loadConsoleSession();
    if (session == null) return const AccountSignedOut();
    return _signedIn(session);
  }

  /// Reads the workspace, renewing and storing the session if it needed it.
  Future<AccountState> _signedIn(ConsoleSession session) async {
    try {
      final result = await ref
          .read(consoleApiProvider)
          .workspace(session);
      await ref.read(profileStoreProvider).saveConsoleSession(result.$1);
      return AccountSignedIn(session: result.$1, workspace: result.$2);
    } on ConsoleException catch (error) {
      // An expired or revoked session is not an error worth shouting about;
      // it just means signed out.
      if (error.statusCode == 401 || error.statusCode == 403) {
        await ref.read(profileStoreProvider).clearConsoleSession();
        return const AccountSignedOut();
      }
      return AccountError(error.message, previous: null);
    }
  }

  /// Starts the device flow. The returned state polls in the background until
  /// the user approves or the code expires.
  Future<void> signIn() async {
    final api = ref.read(consoleApiProvider);

    DeviceCode code;
    try {
      code = await api.startSignIn();
    } on ConsoleException catch (error) {
      state = AsyncData(AccountError(error.message));
      return;
    }

    state = AsyncData(AccountAwaitingApproval(code: code, poll: _poll(code)));
  }

  Future<AccountSignedIn?> _poll(DeviceCode code) async {
    final api = ref.read(consoleApiProvider);
    final store = ref.read(profileStoreProvider);
    final deadline = code.expiresAt;

    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(
        Duration(seconds: code.intervalSeconds.clamp(3, 15)),
      );
      try {
        final session = await api.pollSignIn(code);
        if (session == null) continue;
        await store.saveConsoleSession(session);
        final signedIn = await _signedIn(session);
        state = AsyncData(signedIn);
        return signedIn is AccountSignedIn ? signedIn : null;
      } on ConsoleException catch (error) {
        state = AsyncData(AccountError(error.message));
        return null;
      }
    }

    state = AsyncData(
      const AccountError('That sign-in code expired. Try again.'),
    );
    return null;
  }

  Future<void> signOut() async {
    await ref.read(profileStoreProvider).clearConsoleSession();
    state = AsyncData(const AccountSignedOut());
  }

  /// Renews the session in place, keeping the workspace.
  Future<void> refresh() async {
    final current = state.value;
    if (current is! AccountSignedIn) return;
    final session = current.session;
    if (session.refreshToken.isEmpty) return;
    try {
      final renewed = await ref.read(consoleApiProvider).refresh(session);
      await ref.read(profileStoreProvider).saveConsoleSession(renewed);
      state = AsyncData(await _signedIn(renewed));
    } on ConsoleException catch (error) {
      if (error.statusCode == 401) {
        await signOut();
        return;
      }
      state = AsyncData(AccountError(error.message, previous: current));
    }
  }
}