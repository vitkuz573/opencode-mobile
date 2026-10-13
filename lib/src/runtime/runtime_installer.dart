import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'runtime_manifest.dart';

/// How far along a single download is, in bytes.
typedef FileProgress = void Function(int received, int total);

/// Fetches one archive to [target].
///
/// Injected so the installer's own logic — ordering, verification, extraction,
/// cleanup — can be tested without a network, a device, or a real 96 MB file.
typedef RuntimeFetcher =
    Future<void> Function(
      RuntimeArchive archive,
      File target,
      FileProgress onProgress,
    );

/// Unpacks one entry out of an archive into [directory].
///
/// Android ships `tar` in toybox, which the app shells out to for the same
/// reason it shells out to the loader: doing it this way keeps 96 MB of
/// compressed input and 205 MB of output out of the app's heap.
typedef RuntimeExtractor =
    Future<File> Function(
      File archive,
      String entry,
      Directory directory,
    );

/// Thrown when a download or an extracted file is not what the manifest
/// promised. The message is meant to be shown to a person as it is.
class RuntimeVerificationError implements Exception {
  const RuntimeVerificationError(this.name, this.reason);

  final String name;
  final String reason;

  @override
  String toString() => reason;
}

/// Installs the Android runtime and says whether it is already there.
///
/// An archive is downloaded once, however many files are taken out of it, and
/// every file is checked against its own digest before it is made executable.
/// A download that is cut short or tampered with leaves nothing runnable.
class RuntimeInstaller {
  RuntimeInstaller({
    required this.root,
    Dio? dio,
    RuntimeFetcher? fetcher,
    RuntimeExtractor? extractor,
  }) : _fetcher = fetcher ?? _dioFetcher(dio ?? Dio()),
       _extractor = extractor ?? _tarExtractor;

  /// Directory the runtime lives in, e.g. `<app files>/runtime`.
  final String root;

  final RuntimeFetcher _fetcher;
  final RuntimeExtractor _extractor;

  /// Where archives are kept between the files taken out of them.
  String get _stagingRoot => '$root/.staging';

  String pathOf(String relative) => '$root/$relative';

  String get launcherPath => pathOf('lib/ld-musl-aarch64.so.1');

  String get binaryPath => pathOf('bin/opencode');

  /// True when every file is present at the size the manifest recorded.
  ///
  /// Size is enough for this check: the digest is read on install, and re-hashing
  /// 205 MB every time a screen opens would be rude.
  Future<bool> isInstalled(RuntimeManifest manifest) async {
    for (final file in manifest.files.values) {
      final target = File(pathOf(file.name));
      if (!target.existsSync()) return false;
      if (target.lengthSync() != file.size) return false;
    }
    return true;
  }

  /// The version currently installed, by reading the manifest written at install.
  Future<String?> installedVersion() async {
    final stored = File('$root/runtime.json');
    if (!stored.existsSync()) return null;
    try {
      final decoded = jsonDecode(await stored.readAsString());
      if (decoded is Map) {
        final version = decoded['version'];
        if (version is String) return version;
      }
    } catch (_) {
      // A corrupt marker just means "unknown"; the files are what matter.
    }
    return null;
  }

  /// Downloads and installs everything the manifest lists.
  ///
  /// [onProgress] receives the running total across all archives, because a bar
  /// that restarts per file reads as several separate downloads.
  Future<void> install(
    RuntimeManifest manifest, {
    void Function(int received, int total)? onProgress,
  }) async {
    Directory(root).createSync(recursive: true);
    final staging = Directory(_stagingRoot);
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);

    // Group by archive so a 96 MB download happens once, not once per file.
    final byArchive = <String, List<RuntimeFile>>{};
    for (final file in manifest.files.values) {
      byArchive.putIfAbsent(file.archive, () => <RuntimeFile>[]).add(file);
    }

    final total = manifest.downloadBytes;
    var done = 0;
    final extracted = <String, File>{};

    try {
      for (final entry in byArchive.entries) {
        final archive = manifest.archives[entry.key];
        if (archive == null) {
          throw RuntimeVerificationError(
            entry.key,
            'The manifest asks for ${entry.key}, which it does not describe.',
          );
        }

        final downloaded = File('${staging.path}/${archive.name}.archive');
        await _fetcher(archive, downloaded, (received, _) {
          onProgress?.call(
            done + received.clamp(0, archive.size),
            total,
          );
        });
        done += archive.size;
        onProgress?.call(done, total);

        final size = downloaded.lengthSync();
        if (size != archive.size) {
          throw RuntimeVerificationError(
            archive.name,
            'Downloaded $size bytes, expected ${archive.size}.',
          );
        }
        final digest = await sha256.bind(downloaded.openRead()).first;
        if (digest.toString() != archive.sha256) {
          throw RuntimeVerificationError(
            archive.name,
            'Checksum mismatch: the download is not the archive OpenCode '
                'published.',
          );
        }

        for (final file in entry.value) {
          final unpacked = await _extractor(downloaded, file.entry, staging);
          extracted[file.name] = unpacked;

          final unpackedSize = unpacked.lengthSync();
          if (unpackedSize != file.size) {
            throw RuntimeVerificationError(
              file.name,
              'Unpacked $unpackedSize bytes, expected ${file.size}.',
            );
          }
          final fileDigest = await sha256.bind(unpacked.openRead()).first;
          if (fileDigest.toString() != file.sha256) {
            throw RuntimeVerificationError(
              file.name,
              'Checksum mismatch: the unpacked file is not the one OpenCode '
                  'published.',
            );
          }
        }
        // The archive has given up everything it was asked for.
        await downloaded.delete();
      }

      // Nothing is put in place until everything has been verified: a partial
      // runtime that half-starts is worse than none.
      for (final file in manifest.files.values) {
        final source = extracted[file.name];
        if (source == null) continue;
        final target = File(pathOf(file.name));
        target.parent.createSync(recursive: true);
        if (target.existsSync()) target.deleteSync();
        await source.rename(target.path);
      }
    } finally {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
    }

    // The loader has to be executable, and so does the binary it starts.
    for (final relative in [manifest.launcher, RuntimeManifest.binary]) {
      await _makeExecutable(pathOf(relative));
    }

    File('$root/runtime.json').writeAsStringSync('${manifest.encode()}\n');
  }

  /// Deletes the runtime. The server has to be stopped first; the caller owns
  /// that ordering because only it knows whether the server is running.
  void remove() {
    final directory = Directory(root);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }

  Future<void> _makeExecutable(String path) async {
    if (Platform.isWindows) return;
    final result = await Process.run('chmod', ['755', path]);
    if (result.exitCode != 0) {
      throw RuntimeVerificationError(
        path,
        'Could not make the runtime executable: ${result.stderr}',
      );
    }
  }

  /// Default fetcher: streams to disk and reports progress as it goes.
  ///
  /// Dio writes to a file rather than buffering, because the archive is ~96 MB
  /// and a phone should not have to hold it twice.
  static RuntimeFetcher _dioFetcher(Dio dio) {
    return (archive, target, onProgress) async {
      await dio.download(
        archive.url,
        target.path,
        onReceiveProgress: onProgress,
        options: Options(
          followRedirects: true,
          // A runtime download takes minutes. Letting dio time it out throws
          // away progress the user can already see.
          receiveTimeout: const Duration(minutes: 30),
        ),
      );
    };
  }

  /// Default extractor: toybox `tar`, which every Android image ships.
  static Future<File> _tarExtractor(
    File archive,
    String entry,
    Directory directory,
  ) async {
    final result = await Process.run('tar', [
      '-xzf',
      archive.path,
      '-C',
      directory.path,
      entry,
    ]);
    if (result.exitCode != 0) {
      throw RuntimeVerificationError(
        entry,
        'Could not unpack $entry: ${result.stderr}',
      );
    }
    final unpacked = File('${directory.path}/$entry');
    if (!unpacked.existsSync()) {
      throw RuntimeVerificationError(
        entry,
        'The archive did not contain $entry.',
      );
    }
    return unpacked;
  }
}