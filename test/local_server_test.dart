import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/runtime/local_server.dart';
import 'package:opencode_mobile/src/runtime/runtime_installer.dart';
import 'package:opencode_mobile/src/runtime/runtime_paths.dart';
import 'package:opencode_mobile/src/state/profile_store.dart';

/// A stand-in for the real server that behaves the way OpenCode 2.0.28 does
/// with `--service`: the listening line on stdout right away, the password
/// only ever in the service file, a beat later. Theproduction bug was a
/// restart that showed a running server with no password; this fake replays
/// exactly that ordering so the regression test means something.
const _loaderScript = '#!/bin/sh\nexec "\$@"\n';

const _serverScript = r'''#!/bin/sh
# argv from the handle: serve --service --hostname 127.0.0.1 --port <port>
PORT="$6"
echo "server listening on http://127.0.0.1:$PORT"
mkdir -p "$HOME/.config/opencode"
sleep 1
echo "{\"password\": \"pw-$(date +%s%N)\"}" > "$HOME/.config/opencode/service.json"
exec python3 -c "import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $PORT))
s.listen(1)
time.sleep(60)"
''';

String? _readPassword(String home) {
  final file = File('$home/.config/opencode/service.json');
  if (!file.existsSync()) return null;
  final match = RegExp(
    r'"password":\s*"([^"]+)"',
  ).firstMatch(file.readAsStringSync());
  return match?.group(1);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late RuntimePaths paths;
  late RuntimeInstaller installer;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('oc-server-test');
    paths = RuntimePaths(
      support: '${temp.path}/support',
      runtime: '${temp.path}/support/runtime',
      home: '${temp.path}/support/home',
      workspace: '${temp.path}/support/workspace',
      temp: '${temp.path}/support/home/tmp',
    );
    paths.ensureDirectories();
    File('${paths.runtime}/lib/ld-musl-aarch64.so.1')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(_loaderScript);
    File('${paths.runtime}/bin/opencode')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(_serverScript);
    await Process.run('chmod', [
      '+x',
      '${paths.runtime}/lib/ld-musl-aarch64.so.1',
      '${paths.runtime}/bin/opencode',
    ]);
    File('${paths.runtime}/runtime.json').writeAsStringSync(
      '{"version": "9.9.9"}',
    );
    installer = RuntimeInstaller(root: paths.runtime);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<LocalServerStatus> waitFor(
    LocalServerHandle handle,
    bool Function(LocalServerStatus) ready,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(deadline)) {
      final status = handle.status;
      if (ready(status)) return status;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    fail('timed out waiting; last status: ${handle.status}');
  }

  Future<LocalServerStatus> waitRunningWithPassword(
    LocalServerHandle handle,
  ) => waitFor(
    handle,
    (s) => s.phase == LocalServerPhase.running && s.password != null,
  );

  test(
    'a restart reads the new password from the service file',
    () async {
      final handle = LocalServerHandle(
        paths: paths,
        installer: installer,
        onStatus: (_) {},
      );
      addTearDown(handle.stop);

      await handle.start();
      final first = await waitRunningWithPassword(handle);
      expect(first.address, isNotNull);
      expect(first.password, _readPassword(paths.home));

      await handle.stop();
      await waitFor(
        handle,
        (s) => s.phase == LocalServerPhase.stopped,
      );

      await handle.start();
      final second = await waitRunningWithPassword(handle);
      // The file is cleared before every start, so this password belongs to
      // the new process rather than the one just stopped.
      expect(second.password, isNot(first.password));
      expect(second.password, _readPassword(paths.home));
    },
    skip: !Platform.isLinux && !Platform.isMacOS
        ? 'needs a POSIX shell and python3'
        : false,
  );

  test(
    'a restart keeps the address when the port is still free',
    () async {
      final handle = LocalServerHandle(
        paths: paths,
        installer: installer,
        onStatus: (_) {},
      );
      addTearDown(handle.stop);

      // A free port discovered the same way the handle does: bound briefly to
      // prove nobody holds it, then released.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final preferred = probe.port;
      await probe.close();

      await handle.start(preferredPort: preferred);
      final first = await waitRunningWithPassword(handle);
      expect(first.port, preferred);

      await handle.stop();
      await waitFor(
        handle,
        (s) => s.phase == LocalServerPhase.stopped,
      );

      await handle.start(preferredPort: preferred);
      final second = await waitRunningWithPassword(handle);
      // Same address, new password: saved profiles stay valid and the
      // credentials still rotate.
      expect(second.port, preferred);
      expect(second.password, isNot(first.password));
    },
    skip: !Platform.isLinux && !Platform.isMacOS
        ? 'needs a POSIX shell and python3'
        : false,
  );

  group('local port storage', () {
    late Map<String, String> values;

    setUp(() {
      values = {};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(
              'plugins.it_nomads.com/flutter_secure_storage',
            ),
            (call) async {
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
                default:
                  return null;
              }
            },
          );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(
              'plugins.it_nomads.com/flutter_secure_storage',
            ),
            null,
          );
    });

    test('round-trips the port', () async {
      final store = ProfileStore();
      expect(await store.loadLocalPort(), isNull);

      await store.saveLocalPort(37419);

      expect(await store.loadLocalPort(), 37419);
    });

    test('garbage is no port', () async {
      final store = ProfileStore();
      values['opencode.localPort.v1'] = 'not-a-port';

      expect(await store.loadLocalPort(), isNull);
    });
  });
}
