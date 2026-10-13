// Assembles the OpenCode runtime needed to run a real OpenCode server on an
// Android phone, and writes the manifest the app installs from.
//
// Why this exists
// ---------------
// OpenCode publishes no `android-arm64` build. Its closest match is the
// `linux-arm64-musl` build, which is a dynamically linked ELF that wants
// `/lib/ld-musl-aarch64.so.1`. Android has no such loader, so the binary dies
// with ENOENT before it reaches `main`.
//
// The fix is to ship the loader next to the binary and hand it the program as
// an argument. `ld-musl-aarch64.so.1 <program> [args...]` is how the musl
// loader behaves when it is executed directly, so nothing about the OpenCode
// binary has to be modified.
//
// The one extra dependency is `libstdc++.so.6`, which Bun binaries link against.
// Alpine publishes a musl build of it, along with the `libgcc_s.so.1` unwinder
// that libstdc++ in turn needs.
//
// The manifest lists *archives* and what to take out of them, never a URL that
// claims to be a file it is not. An earlier version pointed `bin/opencode` at
// the npm tarball while recording the unpacked file's size, and every install
// on a real device failed with "expected 205655248, got 95975965". The app
// verifies both the archive and the file taken out of it.
//
// Usage:
//   dart run tool/fetch_android_runtime.dart [--version 2.0.28] [--out DIR]
//
// Assembled layout:
//   <out>/bin/opencode
//   <out>/lib/ld-musl-aarch64.so.1
//   <out>/lib/libstdc++.so.6
//   <out>/lib/libgcc_s.so.1
//   <out>/runtime.json

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Where the pieces come from. Pinned rather than "latest" so a rebuild is
/// reproducible and a checksum means the same thing tomorrow.
const _alpine = 'https://dl-cdn.alpinelinux.org/alpine/v3.21/main/aarch64';
const _npm = 'https://registry.npmjs.org/@opencode/cli-linux-arm64-musl';

const _muslApk = '$_alpine/musl-1.2.5-r11.apk';
const _libstdcxxApk = '$_alpine/libstdc++-14.2.0-r4.apk';
const _libgccApk = '$_alpine/libgcc-14.2.0-r4.apk';

/// A downloaded archive, still on disk, plus the tree it was unpacked into.
class _Downloaded {
  const _Downloaded({
    required this.key,
    required this.url,
    required this.archive,
    required this.root,
  });

  final String key;
  final String url;
  final File archive;
  final Directory root;
}

/// One file in the assembled runtime: which archive holds it, and where inside.
class _Output {
  const _Output(this.name, this.key, this.entry);

  final String name;
  final String key;
  final String entry;
}

Future<int> main(List<String> args) async {
  final version = _flag(args, '--version') ?? '2.0.28';
  final out = Directory(_flag(args, '--out') ?? 'build/android-runtime');
  final temp = Directory.systemTemp.createTempSync('oc-runtime');

  try {
    final tarball = '$_npm/-/cli-linux-arm64-musl-$version.tgz';
    stdout.writeln('opencode   $version');

    final sources = <String, _Downloaded>{
      'opencode': await _fetch('opencode', tarball, temp),
      'musl': await _fetch('musl', _muslApk, temp),
      'libstdcxx': await _fetch('libstdcxx', _libstdcxxApk, temp),
      'libgcc': await _fetch('libgcc', _libgccApk, temp),
    };

    // Alpine ships `libstdc++.so.6` as a symlink to a versioned file. Tar
    // extracts the symlink as an empty file on Windows, so the versioned name
    // is spelled out and the loader is handed the real bytes.
    final outputs = [
      const _Output('bin/opencode', 'opencode', 'package/bin/opencode'),
      const _Output(
        'lib/ld-musl-aarch64.so.1',
        'musl',
        'lib/ld-musl-aarch64.so.1',
      ),
      const _Output(
        'lib/libstdc++.so.6',
        'libstdcxx',
        'usr/lib/libstdc++.so.6.0.33',
      ),
      const _Output('lib/libgcc_s.so.1', 'libgcc', 'usr/lib/libgcc_s.so.1'),
    ];

    final archives = <String, Object?>{};
    for (final source in sources.values) {
      archives[source.key] = {
        'url': source.url,
        'sha256': await _sha256(source.archive),
        'size': source.archive.lengthSync(),
      };
    }

    final files = <String, Object?>{};
    var unpackedTotal = 0;
    for (final output in outputs) {
      final target = File('${out.path}/${output.name}');
      // Only the file itself. Clearing the parent directory would take the
      // previously extracted siblings with it.
      if (target.existsSync()) target.deleteSync();
      target.parent.createSync(recursive: true);
      await _extract(sources[output.key]!, output.entry, target);
      final size = target.lengthSync();
      unpackedTotal += size;
      files[output.name] = {
        'archive': output.key,
        'entry': output.entry,
        'sha256': await _sha256(target),
        'size': size,
      };
      stdout.writeln('  ${output.name.padRight(24)} $size');
    }

    final manifest = const JsonEncoder.withIndent('  ').convert({
      'version': version,
      'launcher': 'lib/ld-musl-aarch64.so.1',
      'archives': archives,
      'files': files,
    });
    File('${out.path}/runtime.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('$manifest\n');

    final downloadTotal = sources.values.fold<int>(
      0,
      (sum, source) => sum + source.archive.lengthSync(),
    );
    stdout.writeln(
      '\ndownload ${_mb(downloadTotal)}, unpacked ${_mb(unpackedTotal)}',
    );
    stdout.writeln('runtime assembled in ${out.path}');
  } finally {
    temp.deleteSync(recursive: true);
  }
  return 0;
}

String _mb(int bytes) => '${(bytes / 1000000).toStringAsFixed(1)} MB';

String? _flag(List<String> args, String name) {
  final index = args.indexOf(name);
  return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
}

/// Fetches and unpacks an archive into its own directory, so several archives
/// can share one temporary folder without colliding.
Future<_Downloaded> _fetch(String key, String url, Directory temp) async {
  final archive = File('${temp.path}/$key.archive');
  final root = Directory('${temp.path}/$key.d');

  if (!archive.existsSync()) {
    stdout.write('  downloading ${url.split('/').last} ... ');
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('$url -> HTTP ${response.statusCode}');
      }
      await response.pipe(archive.openWrite());
    } finally {
      client.close();
    }
    stdout.writeln('${archive.lengthSync()} bytes');
  }

  root.createSync(recursive: true);
  final result = await Process.run('tar', [
    '-xf',
    archive.path,
    '-C',
    root.path,
  ]);
  if (result.exitCode != 0) {
    throw StateError('tar -xf ${archive.path} failed: ${result.stderr}');
  }
  return _Downloaded(key: key, url: url, archive: archive, root: root);
}

/// Pulls one file out of an unpacked archive and makes it executable. The file
/// is moved rather than copied so a 205 MB binary is not duplicated on disk.
Future<void> _extract(_Downloaded source, String entry, File target) async {
  final from = File('${source.root.path}/$entry');
  if (!from.existsSync()) {
    throw StateError('$entry missing from ${source.url}');
  }
  await from.rename(target.path);
  if (!Platform.isWindows) {
    await Process.run('chmod', ['755', target.path]);
  }
}

/// Minimal SHA-256 so the tool needs no dependencies. The opencode binary is
/// 205 MB, so the digest is computed over a sliding 64-byte block instead of
/// materialising the file.
class _Sha256 {
  static const _k = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, //
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  final _h = List<int>.filled(8, 0);
  final _block = Uint8List(64);
  int _blockLength = 0;
  int _messageLength = 0;

  _Sha256() {
    _h.setAll(0, const [
      0x6a09e667,
      0xbb67ae85,
      0x3c6ef372,
      0xa54ff53a,
      0x510e527f,
      0x9b05688c,
      0x1f83d9ab,
      0x5be0cd19,
    ]);
  }

  void update(List<int> data) {
    _messageLength += data.length;
    var offset = 0;

    if (_blockLength > 0) {
      final need = 64 - _blockLength;
      final take = need < data.length ? need : data.length;
      _block.setRange(_blockLength, _blockLength + take, data);
      _blockLength += take;
      offset = take;
      if (_blockLength == 64) {
        _compress(_block);
        _blockLength = 0;
      }
    }

    while (data.length - offset >= 64) {
      final chunk = Uint8List(64);
      chunk.setRange(0, 64, data, offset);
      _compress(chunk);
      offset += 64;
    }

    if (offset < data.length) {
      final rest = data.length - offset;
      _block.setRange(0, rest, data, offset);
      _blockLength = rest;
    }
  }

  String hexDigest() {
    final bitLength = _messageLength * 8;
    _block[_blockLength++] = 0x80;
    if (_blockLength > 56) {
      while (_blockLength < 64) {
        _block[_blockLength++] = 0;
      }
      _compress(_block);
      _blockLength = 0;
    }
    while (_blockLength < 56) {
      _block[_blockLength++] = 0;
    }
    for (var i = 7; i >= 0; i--) {
      _block[_blockLength++] = (bitLength >> (8 * i)) & 0xff;
    }
    _compress(_block);
    return _h.map((w) => w.toRadixString(16).padLeft(8, '0')).join();
  }

  static int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

  void _compress(Uint8List block) {
    final w = List<int>.filled(64, 0);
    for (var i = 0; i < 16; i++) {
      final o = i * 4;
      w[i] = (block[o] << 24) |
          (block[o + 1] << 16) |
          (block[o + 2] << 8) |
          block[o + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }

    var a = _h[0], b = _h[1], c = _h[2], d = _h[3];
    var e = _h[4], f = _h[5], g = _h[6], h = _h[7];

    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ (~e & g);
      final temp1 = (h + s1 + ch + _k[i] + w[i]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & 0xffffffff;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }

    _h[0] = (_h[0] + a) & 0xffffffff;
    _h[1] = (_h[1] + b) & 0xffffffff;
    _h[2] = (_h[2] + c) & 0xffffffff;
    _h[3] = (_h[3] + d) & 0xffffffff;
    _h[4] = (_h[4] + e) & 0xffffffff;
    _h[5] = (_h[5] + f) & 0xffffffff;
    _h[6] = (_h[6] + g) & 0xffffffff;
    _h[7] = (_h[7] + h) & 0xffffffff;
  }
}

Future<String> _sha256(File file) async {
  final hasher = _Sha256();
  await for (final chunk in file.openRead()) {
    hasher.update(chunk);
  }
  return hasher.hexDigest();
}