import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Where the phone-hosted server keeps its things.
///
/// Everything lives inside the app's own directory. That is not a style choice:
/// Android marks shared storage `noexec`, so a runtime unpacked under `/sdcard`
/// cannot be executed at all. The app's data directory is the one place on the
/// device that is both writable and executable.
class RuntimePaths {
  const RuntimePaths({
    required this.support,
    required this.runtime,
    required this.home,
    required this.workspace,
    required this.temp,
  });

  /// Resolves the layout from the platform's app-support directory.
  static Future<RuntimePaths> resolve() async {
    final support = (await getApplicationSupportDirectory()).path;
    return RuntimePaths(
      support: support,
      runtime: '$support/runtime',
      home: '$support/opencode-home',
      workspace: '$support/workspace',
      temp: '$support/opencode-home/tmp',
    );
  }

  /// The directory the server calls `$HOME`.
  ///
  /// Without it the server tries to create `/.local`, which fails because `/` is
  /// read-only, and it exits before printing anything useful.
  final String support;

  /// Root of the installed runtime: `bin/opencode` plus the loader and the two
  /// musl libraries it needs.
  final String runtime;

  /// Where OpenCode keeps its own configuration, sessions and credentials.
  final String home;

  /// The project directory the server is started in.
  ///
  /// OpenCode treats its working directory as a project, and that project is
  /// what shows up in the app's project list. Subdirectories of here are
  /// addressed with the `directory` query parameter, so one server serves all of
  /// them.
  final String workspace;

  /// Scratch space.
  ///
  /// Android has no `/tmp`, and the runtime falls back to it when `TMPDIR` is
  /// unset, then gives up on the very first file it writes.
  final String temp;

  /// The musl loader, as it shipped in the APK.
  ///
  /// It is not a download: Android refuses to execute anything in the app's
  /// private directory, so the one file that has to be *started* rather than
  /// read has to arrive inside the package. 723 KB, extracted by the installer
  /// into a directory where execution is allowed.
  ///
  /// Falls back to the runtime directory, which is where it used to live and
  /// where it still works on any platform without the restriction.
  String loader([String? nativeLibraryDir]) =>
      nativeLibraryDir == null
      ? '$runtime/lib/ld-musl-aarch64.so.1'
      : '$nativeLibraryDir/libldmusl.so';

  String get binary => '$runtime/bin/opencode';

  String get libraryPath => '$runtime/lib';

  /// Creates the directories the server expects to exist.
  void ensureDirectories() {
    for (final path in [runtime, home, workspace, temp]) {
      final directory = Directory(path);
      if (!directory.existsSync()) directory.createSync(recursive: true);
    }
  }
}