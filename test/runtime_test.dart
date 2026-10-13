import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/runtime/runtime_installer.dart';
import 'package:opencode_mobile/src/runtime/runtime_manifest.dart';

/// A runtime with real digests, so the installer's own verification is
/// genuinely exercised rather than stubbed out.
///
/// The shape mirrors production: archives are what gets downloaded, files are
/// what gets taken out of them, and the two have different sizes and digests.
/// Conflating them is exactly the bug that shipped once.
class _Fake {
  const _Fake(this.archives, this.files);

  final Map<String, String> archives;
  final Map<String, Map<String, String>> files;

  Map<String, Object?> toJson({String version = '9.9.9'}) {
    final archiveJson = <String, Object?>{};
    for (final entry in archives.entries) {
      archiveJson[entry.key] = {
        'url': 'https://example.invalid/${entry.key}.archive',
        'sha256': sha256.convert(utf8.encode(entry.value)).toString(),
        'size': utf8.encode(entry.value).length,
      };
    }
    final fileJson = <String, Object?>{};
    for (final entry in files.entries) {
      final contents = entry.value.entries.first.value;
      fileJson[entry.key] = {
        'archive': entry.value.entries.first.key,
        'entry': '${entry.value.entries.first.key}/inner',
        'sha256': sha256.convert(utf8.encode(contents)).toString(),
        'size': utf8.encode(contents).length,
      };
    }
    return {
      'version': version,
      'launcher': 'lib/loader',
      'archives': archiveJson,
      'files': fileJson,
    };
  }

  /// The fetcher the installer will call: writes the archive verbatim.
  RuntimeFetcher fetcher() => (archive, target, onProgress) async {
    final contents = archives[archive.name]!;
    await target.writeAsString(contents);
    onProgress(utf8.encode(contents).length, archive.size);
  };

  /// The extractor: finds the entry in whichever archive was downloaded.
  ///
  /// The archive is named after its key, which is how the real one is staged,
  /// so the two agree without the fake needing to be told out of band.
  RuntimeExtractor extractor() => (archive, entry, directory) async {
    final key = archive.uri.pathSegments.last.replaceAll('.archive', '');
    final contents = files.entries
        .firstWhere((f) => f.value.containsKey(key))
        .value[key]!;
    final target = File('${directory.path}/$entry');
    target.parent.createSync(recursive: true);
    await target.writeAsString(contents);
    return target;
  };
}

/// A runtime with real digests, so the installer's own verification is
/// genuinely exercised rather than stubbed out.
///
/// The shape mirrors production: archives are what gets downloaded, files are
/// what gets taken out of them, and the two have different sizes and digests.
/// Conflating them is exactly the bug that shipped once.
///
/// The archives here are deliberately much smaller than what they contain, as
/// gzip makes them in reality: the npm tarball is 96 MB and the binary inside
/// it is 205 MB. A fake where the archive is the larger of the two would hide
/// any code that confused the totals.
_Fake _runtime({
  String opencode = 'the opencode binary',
  String loader = 'the musl loader',
}) => _Fake(
  {
    'opencode': 'ARCHIVE-opencode',
    'musl': 'ARCHIVE-musl',
  },
  {
    'bin/opencode': {'opencode': opencode},
    'lib/loader': {'musl': loader},
  },
);

String _fakeDigest = List.filled(64, 'x').join();

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('oc-runtime-test'));
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  RuntimeInstaller installerFor(_Fake fake) => RuntimeInstaller(
    root: '${temp.path}/runtime',
    fetcher: fake.fetcher(),
    extractor: fake.extractor(),
  );

  group('manifest', () {
    test('reads the version, launcher and files', () {
      final manifest = RuntimeManifest.fromJson(_runtime().toJson());
      expect(manifest.version, '9.9.9');
      expect(manifest.launcher, 'lib/loader');
      expect(RuntimeManifest.binary, 'bin/opencode');
      expect(manifest.files.keys, containsAll(['bin/opencode', 'lib/loader']));
    });

    test('counts the download and the unpacked size separately', () {
      final manifest = RuntimeManifest.fromJson(_runtime().toJson());
      // The two totals are computed from different things. The download is the
      // sum of the archives; the unpacked size is the sum of the files inside
      // them. Adding them together is the mistake that broke the first version
      // of this manifest, so they are checked separately.
      final archiveBytes = _runtime()
          .archives
          .values
          .fold(0, (sum, a) => sum + a.length);
      final fileBytes = 'the opencode binary'.length + 'the musl loader'.length;
      expect(manifest.downloadBytes, archiveBytes);
      expect(manifest.installedBytes, fileBytes);
      expect(manifest.downloadBytes, lessThan(manifest.installedBytes));
    });

    test('an archive nothing is taken from is not downloaded', () {
      final json = _runtime().toJson();
      (json['archives'] as Map)['unused'] = {
        'url': 'https://example.invalid/unused',
        'sha256': _fakeDigest,
        'size': 999,
      };
      final manifest = RuntimeManifest.fromJson(json);
      expect(
        manifest.downloadBytes,
        _runtime().archives.values.fold(0, (sum, a) => sum + a.length),
      );
    });

    test('rejects a manifest with no launcher', () {
      expect(
        () => RuntimeManifest.fromJson({
          'version': '1.0.0',
          'archives': {
            'a': {'url': 'u', 'sha256': _fakeDigest, 'size': 1},
          },
          'files': {
            'bin/opencode': {
              'archive': 'a',
              'entry': 'e',
              'sha256': _fakeDigest,
              'size': 1,
            },
          },
        }),
        throwsFormatException,
      );
    });

    test('rejects a file whose archive is not listed', () {
      final json = _runtime().toJson();
      ((json['files'] as Map)['bin/opencode']
              as Map)['archive'] = 'nowhere';
      expect(
        () => RuntimeManifest.fromJson(json),
        throwsFormatException,
      );
    });

    test('a loader with an unusable digest makes the manifest unusable', () {
      final json = _runtime().toJson();
      ((json['files'] as Map)['lib/loader'] as Map)['sha256'] = 'short';
      // The entry is skipped, which leaves a manifest describing a runtime
      // nobody could start. Refusing it beats installing one that fails at
      // first launch with "No such file or directory".
      expect(() => RuntimeManifest.fromJson(json), throwsFormatException);
    });
  });

  group('installer', () {
    test('writes every file and records the version', () async {
      final fake = _runtime();
      final manifest = RuntimeManifest.fromJson(fake.toJson());
      final installer = installerFor(fake);

      await installer.install(manifest);

      expect(
        File('${temp.path}/runtime/bin/opencode').readAsStringSync(),
        'the opencode binary',
      );
      expect(
        File('${temp.path}/runtime/lib/loader').readAsStringSync(),
        'the musl loader',
      );
      expect(await installer.installedVersion(), '9.9.9');
      expect(await installer.isInstalled(manifest), isTrue);
    });

    test('downloads each archive once even for several files', () async {
      final fake = _runtime();
      final manifest = RuntimeManifest.fromJson(fake.toJson());
      var downloads = 0;
      final installer = RuntimeInstaller(
        root: '${temp.path}/runtime',
        fetcher: (archive, target, onProgress) async {
          downloads++;
          await fake.fetcher()(archive, target, onProgress);
        },
        extractor: fake.extractor(),
      );

      await installer.install(manifest);

      expect(downloads, manifest.archives.length);
    });

    test('progress ends at the download size, not the unpacked size', () async {
      final fake = _runtime();
      final manifest = RuntimeManifest.fromJson(fake.toJson());
      final seen = <int>[];
      final installer = installerFor(fake);

      await installer.install(manifest, onProgress: (received, total) {
        seen.add(received);
        expect(total, manifest.downloadBytes);
      });

      expect(seen.last, manifest.downloadBytes);
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
      }
    });

    test('refuses a download that is not the archive it promised', () async {
      final fake = _runtime();
      final manifest = RuntimeManifest.fromJson(fake.toJson());
      final installer = RuntimeInstaller(
        root: '${temp.path}/runtime',
        fetcher: (archive, target, onProgress) =>
            target.writeAsString('something else'),
        extractor: fake.extractor(),
      );

      await expectLater(
        installer.install(manifest),
        throwsA(isA<RuntimeVerificationError>()),
      );
      // Nothing runnable is left behind.
      expect(File('${temp.path}/runtime/bin/opencode').existsSync(), isFalse);
    });

    test('refuses an unpacked file that is not what was promised', () async {
      final manifest = RuntimeManifest.fromJson(_runtime().toJson());
      final installer = RuntimeInstaller(
        root: '${temp.path}/runtime',
        fetcher: _runtime().fetcher(),
        extractor: (archive, entry, directory) async {
          final target = File('${directory.path}/$entry');
          target.parent.createSync(recursive: true);
          await target.writeAsString('tampered');
          return target;
        },
      );

      await expectLater(
        installer.install(manifest),
        throwsA(isA<RuntimeVerificationError>()),
      );
      expect(File('${temp.path}/runtime/bin/opencode').existsSync(), isFalse);
    });

    test('refuses a download of the wrong length', () async {
      final manifest = RuntimeManifest.fromJson(_runtime().toJson());
      final installer = RuntimeInstaller(
        root: '${temp.path}/runtime',
        fetcher: (archive, target, onProgress) => target.writeAsString('short'),
        extractor: _runtime().extractor(),
      );

      await expectLater(
        installer.install(manifest),
        throwsA(
          isA<RuntimeVerificationError>().having(
            (e) => e.reason,
            'reason',
            contains('expected ${manifest.archives['opencode']!.size}'),
          ),
        ),
      );
    });

    test('leaves no staging directory behind', () async {
      final fake = _runtime();
      final installer = installerFor(fake);

      await installer.install(RuntimeManifest.fromJson(fake.toJson()));

      expect(Directory('${temp.path}/runtime/.staging').existsSync(), isFalse);
    });

    test('a short file is not an install', () async {
      final fake = _runtime();
      final manifest = RuntimeManifest.fromJson(fake.toJson());
      final installer = installerFor(fake);
      await installer.install(manifest);

      final file = File('${temp.path}/runtime/bin/opencode')
        ..writeAsStringSync('the openc');
      expect(await installer.isInstalled(manifest), isFalse);

      file.writeAsStringSync('the opencode binary');
      expect(await installer.isInstalled(manifest), isTrue);
    });

    test('remove deletes everything', () async {
      final fake = _runtime();
      final installer = installerFor(fake);
      await installer.install(RuntimeManifest.fromJson(fake.toJson()));

      installer.remove();

      expect(Directory('${temp.path}/runtime').existsSync(), isFalse);
      expect(await installer.installedVersion(), isNull);
    });
  });
}