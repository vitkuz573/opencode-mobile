import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'runtime_installer.dart';
import 'runtime_paths.dart';
import 'server_output.dart';

/// Where the phone-hosted server is in its life cycle.
enum LocalServerPhase {
  /// No runtime installed yet. Nothing has been downloaded, by design.
  runtimeMissing,

  /// Installed, not running.
  stopped,

  /// Launched, still waiting for it to report its address and password.
  starting,

  /// Up and answering.
  running,

  /// It exited or refused to start.
  failed,
}

/// A snapshot of the phone-hosted server, safe to hand to widgets.
class LocalServerStatus {
  const LocalServerStatus({
    this.phase = LocalServerPhase.runtimeMissing,
    this.runtimeVersion,
    this.port,
    this.password,
    this.address,
    this.startedAt,
    this.output = '',
    this.pinned = false,
  });

  final LocalServerPhase phase;

  /// Version of the OpenCode binary installed on the device.
  final String? runtimeVersion;

  final int? port;
  final String? password;

  /// The URL the process reported it bound.
  final String? address;

  final DateTime? startedAt;

  /// Everything the process printed, kept for when it will not start.
  final String output;

  /// Whether a foreground service is holding the process alive.
  final bool pinned;

  bool get isRunning => phase == LocalServerPhase.running;

  /// The address the app itself connects to.
  ///
  /// Always loopback: the app is on the same device as the server, and reaching
  /// it from the network is a separate, deliberate act.
  String? get localBaseUrl => port == null ? null : 'http://127.0.0.1:$port';

  LocalServerStatus copyWith({
    LocalServerPhase? phase,
    String? runtimeVersion,
    int? port,
    String? password,
    String? address,
    DateTime? startedAt,
    String? output,
    bool? pinned,
  }) => LocalServerStatus(
    phase: phase ?? this.phase,
    runtimeVersion: runtimeVersion ?? this.runtimeVersion,
    port: port ?? this.port,
    password: password ?? this.password,
    address: address ?? this.address,
    startedAt: startedAt ?? this.startedAt,
    output: output ?? this.output,
    pinned: pinned ?? this.pinned,
  );
}

/// The runtime is installed but will not run on this device.
///
/// Its own type, because the cause is different from a download problem and the
/// fix is different too: reinstalling will not help, and the message says what
/// actually went wrong.
class RuntimeLaunchFailure implements Exception {
  const RuntimeLaunchFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Owns the OpenCode process running on the device.
///
/// Not a Riverpod type: this is the part that can fail, and keeping it separate
/// means a failure has somewhere honest to be reported.
class LocalServerHandle {
  LocalServerHandle({
    required this.paths,
    required this.installer,
    ServerKeepAlive? keepAlive,
    this.onStatus,
  }) : keepAlive = keepAlive ?? ServerKeepAlive();

  final RuntimePaths paths;
  final RuntimeInstaller installer;
  final ServerKeepAlive keepAlive;

  /// Called whenever the observable state changes.
  final void Function(LocalServerStatus)? onStatus;

  Process? _process;
  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;
  Timer? _startupTimer;

  final _lines = StringBuffer();
  LocalServerStatus _status = const LocalServerStatus();

  LocalServerStatus get status => _status;

  bool get isRunning => _process != null;

  /// Where the loader that came with the APK was extracted to.
  ///
  /// Asked once and remembered: the answer cannot change while the app runs,
  /// and the lookup is a trip over the platform channel.
  String? _loaderDir;
  bool _loaderDirAsked = false;

  /// Works out where the loader lives before anything is started.
  ///
  /// The path comes from the platform because it contains a per-install hash,
  /// so it can only be asked for, never computed.
  Future<void> _prepareLauncher() async {
    if (_loaderDirAsked) return;
    _loaderDirAsked = true;
    _loaderDir = await keepAlive.nativeLibraryDir();
  }

  /// The loader to execute.
  String get _loader => paths.loader(_loaderDir);

  /// The version installed on the device, or null when nothing is.
  Future<String?> installedVersion() => installer.installedVersion();

  /// Starts the server, or reports the one already running.
  Future<LocalServerStatus> start() async {
    if (_process != null) return _status;

    await _prepareLauncher();
    paths.ensureDirectories();
    final port = await _pickPort();
    _lines.clear();

    // Whatever is in the registry belongs to a server that is no longer ours.
    // Clearing it means whatever appears next was written by the process about
    // to start, which is what makes it safe to believe.
    await _clearServiceRegistry();

    _emit(
      LocalServerStatus(
        phase: LocalServerPhase.starting,
        runtimeVersion: await installedVersion(),
        port: port,
      ),
    );

    // The musl loader is the executable and OpenCode is its first argument.
    // Running the binary on its own is what fails on Android: it wants a loader
    // at a path that does not exist on this platform.
    final process = await _spawn([
      paths.loader(_loaderDir),
      paths.binary,
      'serve',
      // `--service` is what lets `opencode pair` find this server later instead
      // of trying to spawn a copy of itself.
      '--service',
      // Loopback, deliberately.
      //
      // `opencode pair` finds a running service through the address the server
      // registered. Registering 0.0.0.0 makes that address unreachable, so pair
      // decides the service is dead and tries to spawn its own - which cannot
      // work here, because the binary may be read but never executed. On
      // 127.0.0.1 pair finds the server and mints a code.
      //
      // A pairing code is not bound to an address, so a link printed for
      // loopback is retargeted at whatever address the other device can reach.
      // Being reachable on the network is therefore an explicit step, not a
      // default that quietly exposes a server holding the user's files.
      '--hostname',
      '127.0.0.1',
      '--port',
      '$port',
    ]);
    _process = process;

    _stdout = _linesOf(process.stdout).listen(_onLine);
    _stderr = _linesOf(process.stderr).listen(_onLine);
    unawaited(process.exitCode.then(_onExit));

    // The registry is watched as well as the output, because one of the two
    // lines the server prints on startup can be written before the reader is
    // attached and simply never arrive.
    unawaited(_pollRegistry(port));

    // A server that never reports an address is worse than no server: the UI
    // would sit on "starting" for ever.
    _startupTimer = Timer(const Duration(seconds: 30), () {
      if (_status.phase == LocalServerPhase.starting) {
        _fail('The server did not report an address within 30 seconds.');
      }
    });

    return _status;
  }

  /// Watches the registry until the server has written its credentials.
  Future<void> _pollRegistry(int port) async {
    final deadline = DateTime.now().add(const Duration(seconds: 28));
    while (DateTime.now().isBefore(deadline)) {
      if (_status.phase != LocalServerPhase.starting) return;
      final registry = await _readServiceRegistry();
      final password = registry?['password'];
      final url = registry?['url'];
      final registryPort = url is String ? Uri.tryParse(url)?.port : null;
      if (password is String &&
          password.isNotEmpty &&
          (registryPort == null || registryPort == port)) {
        _startupTimer?.cancel();
        _startupTimer = null;
        _emit(
          _status.copyWith(
            phase: LocalServerPhase.running,
            address: url is String ? url : _status.address,
            password: password,
            startedAt: _status.startedAt ?? DateTime.now(),
          ),
        );
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  /// Stops the server. Safe to call when nothing is running.
  Future<void> stop() async {
    final process = _process;
    if (process == null) return;
    _process = null;
    _startupTimer?.cancel();
    _startupTimer = null;
    await _stdout?.cancel();
    await _stderr?.cancel();
    _stdout = null;
    _stderr = null;
    process.kill();
    await _clearServiceRegistry();
    _emit(
      LocalServerStatus(
        phase: LocalServerPhase.stopped,
        runtimeVersion: await installedVersion(),
      ),
    );
  }

  /// Runs a short OpenCode command and returns everything it printed.
  ///
  /// `pair` is how the phone publishes itself: the binary already knows how to
  /// reach the relay, so the app does not have to learn any of that.
  Future<String> runCommand(List<String> args, {Duration? timeout}) async {
    await _prepareLauncher();
    paths.ensureDirectories();
    final command = [_loader, paths.binary, ...args];
    final result = await _run(command, timeout ?? const Duration(minutes: 3));
    final output = '${result.stdout}${result.stderr}';
    if (result.exitCode != 0) {
      throw ProcessException(
        paths.binary,
        args,
        parseFailure(output) ?? 'exited with ${result.exitCode}',
        result.exitCode,
      );
    }
    return output;
  }

  /// Generates a pairing link for this server.
  ///
  /// `--remote` asks OpenTunnel to expose the server to the internet. `--yes`
  /// is required: with no terminal there is nobody to answer the prompt, and
  /// without it the command exits instead of pairing.
  Future<String> pairingLink({required bool remote}) async {
    final output = await runCommand([
      'pair',
      if (remote) ...['--remote', '--yes'],
    ]);
    final link = parsePairingLink(output);
    if (link == null) {
      throw ProcessException(
        paths.binary,
        ['pair'],
        parseFailure(output) ?? 'no pairing link in the output',
        1,
      );
    }
    return link;
  }

  /// Everything the server needs to find its own files.
  ///
  /// `HOME` is the one that is not optional: without it the server tries to
  /// create `/.local`, fails because `/` is read-only, and exits before saying
  /// anything useful. `TMPDIR` matters just as much — Bun falls back to `/tmp`,
  /// which does not exist on Android, and gives up with a bare
  /// "read-only file system, mkdir '/tmp'".
  Map<String, String> get _environment => {
    'HOME': paths.home,
    'TMPDIR': paths.temp,
    'TMP': paths.temp,
    'TEMP': paths.temp,
    'LD_LIBRARY_PATH': paths.libraryPath,
    'XDG_CACHE_HOME': '${paths.home}/.cache',
    'XDG_DATA_HOME': '${paths.home}/.local/share',
    'XDG_CONFIG_HOME': '${paths.home}/.config',
  };

  /// Runs the runtime once and checks it answers.
  ///
  /// Called the moment the files land. Installing something that cannot start
  /// is worse than failing here: the user watches 97 MB go by and is then told
  /// "installed", and only finds out it does not work when they press Start.
  Future<void> verifyRuntime() async {
    await _prepareLauncher();
    paths.ensureDirectories();
    late final ProcessResult result;
    try {
      result = await _run(
        [_loader, paths.binary, '--version'],
        const Duration(seconds: 90),
      );
    } on ProcessException catch (error) {
      throw RuntimeLaunchFailure(
        'OpenCode could not be started (${_errnoText(error.errorCode)}).',
      );
    }
    final output = '${result.stdout}${result.stderr}'.trim();
    if (result.exitCode != 0 || !output.contains('opencode v')) {
      throw RuntimeLaunchFailure(
        output.isEmpty
            ? 'OpenCode did not start on this device.'
            : output.split('\n').first,
      );
    }
  }

  /// `Permission denied` alone does not say what was refused, so the number goes
  /// in the message: the difference between errno 1 and errno 13 is the whole
  /// diagnosis.
  static String _errnoText(int? code) {
    final known = switch (code) {
      1 => 'not permitted',
      2 => 'no such file or directory',
      8 => 'exec format error',
      13 => 'permission denied',
      26 => 'text file busy',
      _ => null,
    };
    return known == null ? 'errno $code' : 'errno $code, $known';
  }

  /// The file `opencode serve --service` records itself in.
  String get _registryPath =>
      '${paths.home}/.local/state/opencode/service.json';

  Future<void> _clearServiceRegistry() async {
    final file = File(_registryPath);
    if (file.existsSync()) {
      try {
        await file.delete();
      } catch (_) {
        // A registry we cannot clear is not a reason to refuse to start; the
        // port check below is what actually keeps the credentials honest.
      }
    }
  }

  /// What the server wrote about itself.
  Future<Map<String, Object?>?> _readServiceRegistry() async {
    final file = File(_registryPath);
    if (!file.existsSync()) return null;
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) return decoded.cast<String, Object?>();
        return null;
      } catch (_) {
        // Written in two steps, so a half-written file is normal for a moment.
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    return null;
  }

  /// Runs [command] to completion, going through the shell if that is the only
  /// way this device will execute it.
  ///
  /// One place decides how to launch, so `pair` and `serve` behave the same way
  /// on a device that needs the shell as on one that does not.
  Future<ProcessResult> _run(List<String> command, Duration timeout) async {
    if (_useShell) {
      return _complete(
        Process.run(
          _shell,
          ['-c', _quote(command)],
          environment: _environment,
          workingDirectory: paths.workspace,
        ),
        timeout,
      );
    }
    try {
      return await _complete(
        Process.run(
          command.first,
          command.sublist(1),
          environment: _environment,
          workingDirectory: paths.workspace,
        ),
        timeout,
      );
    } on ProcessException catch (error) {
      if (error.errorCode != 13) rethrow;
      // Remember it: the refusal is a property of the device, not of this
      // command, and repeating the known-bad attempt hides the real error.
      _useShell = true;
      return _complete(
        Process.run(
          _shell,
          ['-c', _quote(command)],
          environment: _environment,
          workingDirectory: paths.workspace,
        ),
        timeout,
      );
    }
  }

  /// A command that outlives its timeout has left the phone holding a server the
  /// user cannot see, so the wait ends and the process is killed.
  Future<ProcessResult> _complete(Future<ProcessResult> run, Duration timeout) {
    return run.timeout(
      timeout,
      onTimeout: () => throw TimeoutException('OpenCode timed out'),
    );
  }

  /// Runs the runtime, using the shell when a direct exec is refused.
  ///
  /// Some Android builds refuse `execve` of a file in the app's own data
  /// directory, even with the execute bit set and even for the file's owner.
  /// The refusal is EACCES from the kernel and nothing in the app can talk it
  /// round — but `/system/bin/sh` is always executable, and handing it the same
  /// argv gets the same process running. The first refusal is remembered so the
  /// slower path is not retried on every start.
  Future<Process> _spawn(List<String> command) async {
    if (!_useShell) {
      try {
        return await Process.start(
          command.first,
          command.sublist(1),
          environment: _environment,
          workingDirectory: paths.workspace,
        );
      } on ProcessException catch (error) {
        // Anything other than EACCES is a real problem and retrying it through
        // a shell would only hide it.
        if (error.errorCode != 13) rethrow;
        _useShell = true;
      }
    }
    return Process.start(
      _shell,
      ['-c', _quote(command)],
      environment: _environment,
      workingDirectory: paths.workspace,
    );
  }

  /// Quotes an argv the way a POSIX shell expects it.
  ///
  /// Single quotes, with the only escape being the quote itself. Everything the
  /// paths can contain is safe inside them.
  static String _quote(List<String> command) =>
      command.map((part) => "'${part.replaceAll("'", "'\\''")}'").join(' ');

  static const _shell = '/system/bin/sh';

  bool _useShell = false;

  Stream<String> _linesOf(Stream<List<int>> stream) =>
      stream
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter());

  void _onLine(String line) {
    if (line.isEmpty) return;
    _lines.writeln(line);
    // Keep the tail. A stack trace out of a bundled runtime is long, and the
    // part worth reading is at the end.
    final text = _lines.toString();
    if (text.length > 16000) {
      _lines
        ..clear()
        ..write(text.substring(text.length - 8000));
    }

    final url = parseListeningUrl(line);
    final password = parseServerPassword(line);
    if (url == null && password == null) return;

    _startupTimer?.cancel();
    _startupTimer = null;
    _emit(
      _status.copyWith(
        phase: LocalServerPhase.running,
        address: url,
        password: password,
        startedAt: _status.startedAt ?? DateTime.now(),
      ),
    );
  }

  void _onExit(int code) {
    final wasStarting = _status.phase == LocalServerPhase.starting;
    final wasRunning = _status.phase == LocalServerPhase.running;
    _process = null;
    _startupTimer?.cancel();
    _startupTimer = null;

    // A server that came up and then died is worth reporting; one that was asked
    // to stop is not. 143 is SIGTERM, 15 is SIGTERM on some runtimes.
    if (wasStarting) {
      _fail('The server stopped before it finished starting (exit $code).');
    } else if (wasRunning && code != 0 && code != 143 && code != 15) {
      _fail('The server stopped unexpectedly (exit $code).');
    }
  }

  void _fail(String message) {
    _lines.writeln(message);
    _emit(
      _status.copyWith(
        phase: LocalServerPhase.failed,
        output: _lines.toString(),
      ),
    );
  }

  void _emit(LocalServerStatus status) {
    _status = status;
    onStatus?.call(status);
  }

  /// The port the phone's own server uses.
  ///
  /// OpenCode's own default, chosen here because a server that changed its
  /// address on every start would be unusable as a saved profile: the stored
  /// address would be stale the next time the app opened, and the connection
  /// would fail against a server that was running perfectly well. A stable
  /// address is what lets the app reconnect on launch without being told to.
  static const preferredPort = 4096;

  /// [preferredPort] when it is free, and anything else when it is not.
  ///
  /// The fallback is rare but real: a previous instance that has not finished
  /// exiting still holds the port, and the server would simply exit on a busy
  /// one.
  static Future<int> _pickPort() async {
    if (await _isFree(preferredPort)) return preferredPort;
    for (var attempt = 0; attempt < 20; attempt++) {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      if (port > 1024) return port;
    }
    throw StateError('Could not find a free port');
  }

  static Future<bool> _isFree(int port) async {
    try {
      final socket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
      );
      await socket.close();
      return true;
    } on SocketException {
      return false;
    }
  }
}

/// Keeps the Android process alive while the server runs, and answers the one
/// question Dart cannot answer on its own.
///
/// Without the service the system reclaims the app in the background and takes
/// the server with it, which is the entire point of running one here.
class ServerKeepAlive {
  ServerKeepAlive({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('dev.vitkuz573.opencodemobile/keepalive');

  final MethodChannel _channel;

  /// True where there is a foreground service to talk to.
  bool get isSupported => Platform.isAndroid;

  /// The one directory on the device where this app may execute a file.
  ///
  /// Android labels every file in an app's private directory `app_data_file`
  /// and denies `execute_no_trans` on it, so a binary downloaded at runtime can
  /// be read but never started - the kernel grants `execute` and refuses
  /// `execute_no_trans` for the very same file. Files that arrived inside the
  /// APK are labelled `apk_data_file`, where executing them is allowed. The
  /// path also carries a per-install hash, so it is an ask and not a
  /// computation.
  ///
  /// Null where there is no such directory, which is also what happens if the
  /// loader is missing from the APK.
  Future<String?> nativeLibraryDir() async {
    if (!isSupported) return null;
    try {
      final path = await _channel.invokeMethod<String>('nativeLibraryDir');
      if (path == null || path.isEmpty) return null;
      return path;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Brings the service up, or does nothing where there is none.
  ///
  /// Failing to start it is not fatal: the server still runs, it just does not
  /// survive the screen turning off. That is better than refusing to start.
  Future<bool> start({String? address}) async {
    if (!isSupported) return false;
    try {
      await _channel.invokeMethod<void>('start', {'address': address});
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Takes the service down. Safe when it was never up.
  Future<void> stop() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Nothing to stop.
    } on PlatformException {
      // Already gone.
    }
  }
}
