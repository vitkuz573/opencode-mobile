import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api.dart';
import '../runtime/connect_proxy.dart';
import '../runtime/local_server.dart';
import '../runtime/runtime_installer.dart';
import '../runtime/runtime_manifest.dart';
import '../runtime/runtime_paths.dart';
import 'providers.dart';

/// Where everything lives on the device.
///
/// Resolved once: the paths do not change while the app runs, and the rest of
/// the local server hangs off them.
final runtimePathsProvider = FutureProvider<RuntimePaths>((ref) async {
  final paths = await RuntimePaths.resolve();
  paths.ensureDirectories();
  return paths;
});

/// What this build can install, bundled so the app can tell the user an update
/// exists — and start an install — with no network at all.
final runtimeManifestProvider = FutureProvider<RuntimeManifest>((ref) async {
  final raw = await rootBundle.loadString('assets/runtime.json');
  final decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw const FormatException('assets/runtime.json is not an object');
  }
  return RuntimeManifest.fromJson(decoded.cast<String, Object?>());
});

final runtimeInstallerProvider = FutureProvider<RuntimeInstaller>((ref) async {
  final paths = await ref.watch(runtimePathsProvider.future);
  return RuntimeInstaller(root: paths.runtime);
});

/// How far along a download is.
class InstallProgress {
  const InstallProgress({
    this.running = false,
    this.received = 0,
    this.total = 0,
    this.error,
    this.replacing = false,
  });

  final bool running;
  final int received;
  final int total;

  /// True when a working runtime is being replaced.
  final bool replacing;

  final String? error;

  double get fraction => total <= 0 ? 0 : (received / total).clamp(0.0, 1.0);

  bool get hasError => error != null;
}

/// Everything about the phone-hosted server that a widget needs.
class LocalServerState {
  const LocalServerState({
    this.installedVersion,
    this.latestVersion,
    this.updateAvailable = false,
    this.loading = true,
    this.install = const InstallProgress(),
    this.status = const LocalServerStatus(),
  });

  /// Version on the device, or null when nothing is installed.
  final String? installedVersion;

  /// Version this build knows how to install.
  final String? latestVersion;

  /// True when the installed version is not the latest one.
  final bool updateAvailable;

  /// True until the device has been checked.
  final bool loading;

  final InstallProgress install;

  final LocalServerStatus status;

  bool get isInstalled => installedVersion != null;

  bool get canUpdate => isInstalled && updateAvailable;

  /// True while something is happening that should hold the screen still.
  bool get isBusy =>
      install.running || status.phase == LocalServerPhase.starting;

  LocalServerState copyWith({
    String? installedVersion,
    String? latestVersion,
    bool? updateAvailable,
    bool? loading,
    InstallProgress? install,
    LocalServerStatus? status,
  }) => LocalServerState(
    installedVersion: installedVersion ?? this.installedVersion,
    latestVersion: latestVersion ?? this.latestVersion,
    updateAvailable: updateAvailable ?? this.updateAvailable,
    loading: loading ?? this.loading,
    install: install ?? this.install,
    status: status ?? this.status,
  );
}

/// The phone-hosted server as one observable thing.
///
/// Installing, running and publishing are all answers to the same question —
/// "can I talk to OpenCode on this phone" — so they share one state instead of
/// three that can disagree.
class LocalServerController extends Notifier<LocalServerState> {
  LocalServerHandle? _handle;
  final _keepAlive = ServerKeepAlive();

  /// The CONNECT relay the server's outbound HTTPS goes through. Owned here,
  /// next to the server: it starts before the server and stops after it, so
  /// no request ever leaves without a way out and no relay idles without a
  /// server to serve.
  final _proxy = ConnectProxy();

  /// The folder the phone's server works in.
  ///
  /// The server picks a default project of its own when a request names no
  /// directory, and on a phone that default is the state directory, where the
  /// agent has no business writing. The app says which directory it means, so
  /// sessions and files land in the workspace instead.
  String? _workspace;

  String? get workspace => _workspace;

  @override
  LocalServerState build() {
    // Check the device after the first frame so a widget can render "checking"
    // instead of waiting on a disk read inside build().
    Future.microtask(refreshRuntime);
    return const LocalServerState();
  }

  /// The process handle, created the first time something needs it.
  ///
  /// It lives here rather than in a provider because it owns the one thing that
  /// cannot be rebuilt from state: a live child process.
  Future<LocalServerHandle> _handleOf() async {
    final existing = _handle;
    if (existing != null) return existing;
    final paths = await ref.read(runtimePathsProvider.future);
    final installer = await ref.read(runtimeInstallerProvider.future);
    final handle = LocalServerHandle(
      paths: paths,
      installer: installer,
      onStatus: _reportStatus,
    );
    _handle = handle;
    _workspace = paths.workspace;
    return handle;
  }

  void _reportStatus(LocalServerStatus status) {
    if (!ref.mounted) return;
    state = state.copyWith(status: status);
  }

  /// Re-reads what is installed on the device.
  Future<void> refreshRuntime() async {
    try {
      final installer = await ref.read(runtimeInstallerProvider.future);
      final installed = await installer.installedVersion();
      final latest = (await ref.read(runtimeManifestProvider.future)).version;
      if (!ref.mounted) return;
      state = state.copyWith(
        installedVersion: installed,
        latestVersion: latest,
        updateAvailable: installed != null && installed != latest,
        loading: false,
      );
    } catch (error, stack) {
      if (!ref.mounted) return;
      ref.read(appLogProvider).error('runtime', 'could not read runtime: $error');
      state = state.copyWith(loading: false);
      Error.throwWithStackTrace(
        StateError('runtime check failed: $error'),
        stack,
      );
    }
  }

  /// Downloads the runtime, or replaces the one already installed.
  ///
  /// Nothing calls this by itself. The runtime is not fetched until the user
  /// asks for a server on the phone, which is the whole reason this feature
  /// does not cost 199 MB on install.
  Future<void> install({bool updating = false}) async {
    if (state.install.running) return;
    final log = ref.read(appLogProvider);
    final replacing = updating || state.isInstalled;
    final manifest = await ref.read(runtimeManifestProvider.future);
    final installer = await ref.read(runtimeInstallerProvider.future);

    state = state.copyWith(
      install: InstallProgress(
        running: true,
        replacing: replacing,
        total: manifest.downloadBytes,
      ),
    );

    try {
      await installer.install(
        manifest,
        onProgress: (received, total) {
          if (!ref.mounted) return;
          state = state.copyWith(
            install: InstallProgress(
              running: true,
              replacing: replacing,
              received: received,
              total: total,
            ),
          );
        },
      );
      log.info('runtime', 'installed OpenCode ${manifest.version} on device');

      // Prove it runs before telling the user it is installed. A 97 MB
      // download that cannot start is the worst possible outcome: the user has
      // paid for it in time and data and is told it worked.
      try {
        await (await _handleOf()).verifyRuntime();
      } on RuntimeLaunchFailure catch (error) {
        log.error('runtime', 'installed runtime will not start: ${error.message}');
        await refreshRuntime();
        if (!ref.mounted) return;
        state = state.copyWith(
          install: InstallProgress(error: error.message),
        );
        return;
      }

      await refreshRuntime();
      if (!ref.mounted) return;
      state = state.copyWith(
        install: const InstallProgress(),
        status: const LocalServerStatus(phase: LocalServerPhase.stopped),
      );
    } catch (error) {
      final reason = error is RuntimeVerificationError
          ? error.reason
          : '$error';
      log.error('runtime', 'install failed: $reason');
      if (!ref.mounted) return;
      state = state.copyWith(install: InstallProgress(error: reason));
    }
  }

  /// Clears a failed install so the button comes back.
  void dismissInstallError() =>
      state = state.copyWith(install: const InstallProgress());

  /// Deletes the runtime from the device.
  Future<void> uninstall() async {
    final handle = _handle;
    if (handle != null) await handle.stop();
    await _proxy.stop();
    final installer = await ref.read(runtimeInstallerProvider.future);
    installer.remove();
    ref.read(appLogProvider).info('runtime', 'removed the runtime');
    state = const LocalServerState(loading: false);
    await refreshRuntime();
  }

  /// Starts the server and waits until it reports an address.
  Future<bool> start() async {
    if (!state.isInstalled) return false;
    final handle = await _handleOf();
    final store = ref.read(profileStoreProvider);
    final proxyPort = await _proxy.start();

    state = state.copyWith(
      status: state.status.copyWith(phase: LocalServerPhase.starting),
    );
    try {
      await handle.start(
        preferredPort: await store.loadLocalPort(),
        proxyPort: proxyPort,
      );
    } catch (error) {
      await _proxy.stop();
      _reportStatus(
        LocalServerStatus(
          phase: LocalServerPhase.failed,
          runtimeVersion: state.installedVersion,
          output: '$error',
        ),
      );
      return false;
    }

    final deadline = DateTime.now().add(const Duration(seconds: 35));
    while (state.status.phase == LocalServerPhase.starting) {
      if (DateTime.now().isAfter(deadline)) {
        await _proxy.stop();
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (!state.status.isRunning) {
      await _proxy.stop();
      return false;
    }

    // Remember the port while it is ours: the next start prefers it when it
    // is free, so the address survives restarts instead of going stale.
    final port = state.status.port;
    if (port != null) await store.saveLocalPort(port);

    // Hold the process in a foreground service so Android does not reclaim the
    // app the moment the screen goes off.
    final pinned = await _keepAlive.start(
      address: state.status.address ?? 'this phone',
    );
    _reportStatus(state.status.copyWith(pinned: pinned));
    return true;
  }

  /// Stops the server and lets the screen go back to the foreground.
  Future<void> stop() async {
    final handle = _handle;
    if (handle != null) await handle.stop();
    await _proxy.stop();
    await _keepAlive.stop();
    _reportStatus(
      LocalServerStatus(
        phase: LocalServerPhase.stopped,
        runtimeVersion: state.installedVersion,
      ),
    );
  }

  /// The profile pointing at the phone's own server.
  ///
  /// The password is regenerated on every start, so this only means anything
  /// while the server is up — which is exactly when it is offered.
  ServerProfile? get localProfile {
    final status = state.status;

    final baseUrl = status.localBaseUrl;
    final password = status.password;
    if (!status.isRunning || baseUrl == null || password == null) return null;
    return ServerProfile.basic(
      baseUrl: baseUrl,
      password: password,
      label: 'This phone',
    );
  }

  /// Generates a pairing link so another device can reach this phone.
  Future<String> pairingLink({required bool remote}) async {
    final handle = await _handleOf();
    return handle.pairingLink(remote: remote);
  }
}

final localServerProvider =
    NotifierProvider<LocalServerController, LocalServerState>(
      LocalServerController.new,
    );