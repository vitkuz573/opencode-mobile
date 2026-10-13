import 'dart:convert';

/// What an Android runtime is made of, and where each piece comes from.
///
/// OpenCode publishes no `android-arm64` build. The closest thing is the
/// `linux-arm64-musl` npm package, which wants `/lib/ld-musl-aarch64.so.1` — a
/// path Android does not have, so the binary cannot start on its own. Shipping
/// the loader next to the binary and letting it launch the program fixes that
/// without modifying a byte of OpenCode. See `docs/ANDROID_RUNTIME.md`.
///
/// The manifest therefore describes *archives* and what to take out of them,
/// rather than pretending a URL produces a file. Every URL here returns exactly
/// what it says it returns, which is the property that makes it usable at all:
/// an earlier version listed the npm tarball as the source of a 205 MB binary
/// and every install failed with "expected 205655248, got 95975965".
///
/// Both the archive and the file taken out of it are checked against a digest,
/// so neither a corrupted download nor a substituted upstream file gets as far
/// as being executed.
class RuntimeManifest {
  const RuntimeManifest({
    required this.version,
    required this.launcher,
    required this.archives,
    required this.files,
  });

  /// The OpenCode version these files came from, e.g. `2.0.28`.
  final String version;

  /// Path of the loader, relative to the runtime root.
  ///
  /// It is run as `launcher <opencode> <args...>`, which is how the musl loader
  /// behaves when executed directly rather than by the kernel.
  final String launcher;

  final Map<String, RuntimeArchive> archives;
  final Map<String, RuntimeFile> files;

  /// Relative path of the server binary.
  static const binary = 'bin/opencode';

  /// Bytes that cross the network. Only the archives something is taken out of
  /// are counted, so the number shown to a user is the real download.
  int get downloadBytes {
    final used = {
      for (final file in files.values) file.archive: archives[file.archive],
    };
    return used.values.fold(0, (sum, archive) => sum + (archive?.size ?? 0));
  }

  /// Bytes the runtime occupies once unpacked.
  int get installedBytes =>
      files.values.fold(0, (sum, file) => sum + file.size);

  factory RuntimeManifest.fromJson(Map<String, Object?> json) {
    final version = json['version'];
    final launcher = json['launcher'];
    if (version is! String || version.isEmpty) {
      throw const FormatException('runtime manifest has no version');
    }
    if (launcher is! String || launcher.isEmpty) {
      throw const FormatException('runtime manifest has no launcher');
    }

    final rawArchives = json['archives'];
    if (rawArchives is! Map) {
      throw const FormatException('runtime manifest has no archives');
    }
    final archives = <String, RuntimeArchive>{};
    rawArchives.forEach((name, value) {
      if (value is! Map) return;
      final archive = RuntimeArchive.fromJson(
        name,
        value.cast<String, Object?>(),
      );
      if (archive != null) archives[name] = archive;
    });

    final rawFiles = json['files'];
    if (rawFiles is! Map) {
      throw const FormatException('runtime manifest has no files');
    }
    final files = <String, RuntimeFile>{};
    rawFiles.forEach((name, value) {
      if (value is! Map) return;
      final file = RuntimeFile.fromJson(name, value.cast<String, Object?>());
      if (file != null) files[name] = file;
    });

    if (files.isEmpty) {
      throw const FormatException('runtime manifest lists no usable files');
    }
    // A runtime that cannot be started is not a runtime, so the manifest is
    // refused rather than installed into something that fails at first launch.
    if (!files.containsKey(launcher)) {
      throw FormatException('launcher $launcher is not in the manifest');
    }
    if (!files.containsKey(RuntimeManifest.binary)) {
      throw const FormatException('manifest has no bin/opencode');
    }
    for (final file in files.values) {
      if (!archives.containsKey(file.archive)) {
        throw FormatException(
          '${file.name} comes from "${file.archive}", which is not listed',
        );
      }
    }

    return RuntimeManifest(
      version: version,
      launcher: launcher,
      archives: Map.unmodifiable(archives),
      files: Map.unmodifiable(files),
    );
  }

  String encode() => const JsonEncoder.withIndent('  ').convert({
    'version': version,
    'launcher': launcher,
    'archives': {
      for (final entry in archives.entries) entry.key: entry.value.toJson(),
    },
    'files': {
      for (final entry in files.entries) entry.key: entry.value.toJson(),
    },
  });
}

/// A downloadable archive, verified before anything is taken out of it.
class RuntimeArchive {
  const RuntimeArchive({
    required this.name,
    required this.url,
    required this.sha256,
    required this.size,
  });

  final String name;
  final String url;
  final String sha256;
  final int size;

  static RuntimeArchive? fromJson(String name, Map<String, Object?> json) {
    final url = json['url'];
    final sha256 = json['sha256'];
    final size = json['size'];
    if (url is! String || url.isEmpty) return null;
    if (sha256 is! String || sha256.length != 64) return null;
    if (size is! int || size <= 0) return null;
    return RuntimeArchive(name: name, url: url, sha256: sha256, size: size);
  }

  Map<String, Object?> toJson() => {
    'url': url,
    'sha256': sha256,
    'size': size,
  };
}

/// One file in the runtime, and how to get it out of an archive.
class RuntimeFile {
  const RuntimeFile({
    required this.name,
    required this.archive,
    required this.entry,
    required this.sha256,
    required this.size,
  });

  final String name;

  /// Key of the archive in [RuntimeManifest.archives].
  final String archive;

  /// Path of the file inside that archive.
  final String entry;

  /// Digest of the extracted file, which is what actually gets run.
  final String sha256;

  /// Size of the extracted file.
  final int size;

  static RuntimeFile? fromJson(String name, Map<String, Object?> json) {
    final archive = json['archive'];
    final entry = json['entry'];
    final sha256 = json['sha256'];
    final size = json['size'];
    if (archive is! String || archive.isEmpty) return null;
    if (entry is! String || entry.isEmpty) return null;
    if (sha256 is! String || sha256.length != 64) return null;
    if (size is! int || size <= 0) return null;
    return RuntimeFile(
      name: name,
      archive: archive,
      entry: entry,
      sha256: sha256,
      size: size,
    );
  }

  Map<String, Object?> toJson() => {
    'archive': archive,
    'entry': entry,
    'sha256': sha256,
    'size': size,
  };
}