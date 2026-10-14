import 'dart:convert';
import 'dart:io';

/// What a published tunnel needs to come back after the app is closed.
///
/// A tunnel is a hostname somebody may have bookmarked, and its token is shown
/// exactly once - so losing the record of it means losing the only way back to
/// it. Everything here is written before it is needed rather than after, and
/// each file is written whole or not at all: a half-written key is a key that
/// cannot be read, which is worse than no key, because the record of it exists.
///
/// The private key is the one file here that would be a real problem in the
/// wrong hands. It stays in the app's own private directory, never leaves the
/// device, and is only ever handed to BoringSSL to serve TLS.
class TunnelStore {
  TunnelStore(this.directory);

  /// Where the files live, created on demand.
  final Directory directory;

  static const _tokenFile = 'token';
  static const _tunnelFile = 'tunnel.json';
  static const _pendingFile = 'pending.json';
  static const _keyFile = 'private-key.pem';
  static const _certificateFile = 'certificate.pem';
  static const _chainFile = 'chain.pem';

  File get _token => File('${directory.path}/$_tokenFile');
  File get _tunnel => File('${directory.path}/$_tunnelFile');
  File get _pending => File('${directory.path}/$_pendingFile');
  File get _key => File('${directory.path}/$_keyFile');
  File get _certificate => File('${directory.path}/$_certificateFile');
  File get _chain => File('${directory.path}/$_chainFile');

  /// What is on disk, if anything.
  Future<SavedTunnel?> read() async {
    final id = _id();
    final token = _token.existsSync() ? _token.readAsStringSync().trim() : null;
    if (id == null || token == null || token.isEmpty) return null;
    return SavedTunnel(
      id: id,
      hostname: _hostname(id),
      token: token,
      certificate: _readIfPresent(_certificate),
      chain: _readIfPresent(_chain),
      privateKeyPem: _readIfPresent(_key),
    );
  }

  /// Writes the identity, before the request for a certificate is sent.
  ///
  /// The order matters and is the reason this is one call: an interrupted
  /// provisioning resumes from what is here, and a request whose key was never
  /// written cannot be resumed by anyone.
  Future<void> writeIdentity({
    required String id,
    required String token,
    required String privateKeyPem,
  }) async {
    await directory.create(recursive: true);
    await _atomic(_key, privateKeyPem);
    await _atomic(_token, token);
    await _atomic(
      _tunnel,
      const JsonEncoder.withIndent('  ').convert({'id': id}),
    );
  }

  Future<void> writeCertificate(String certificate, String chain) async {
    await directory.create(recursive: true);
    await _atomic(_certificate, certificate);
    await _atomic(_chain, chain);
  }

  /// Forgets the tunnel completely, so publishing again starts from scratch.
  Future<void> clear() async {
    for (final file in [_token, _tunnel, _pending, _key, _certificate, _chain]) {
      if (file.existsSync()) {
        try {
          await file.delete();
        } catch (_) {
          // A file that will not go is reported by the next claim, which will
          // simply overwrite it. Failing here would leave nothing working.
        }
      }
    }
  }

  String? _id() {
    if (!_tunnel.existsSync()) return null;
    try {
      final json = jsonDecode(_tunnel.readAsStringSync());
      if (json is! Map) return null;
      final id = json['id'];
      return id is String && id.isNotEmpty ? id : null;
    } catch (_) {
      // Unreadable is treated as absent: the alternative is refusing to publish
      // over something that may well be a torn write.
      return null;
    }
  }

  /// The host the service gave the tunnel, which is a naming rule rather than
  /// something worth storing separately.
  String _hostname(String id) => '$id.opentunnel.xyz';

  String? _readIfPresent(File file) =>
      file.existsSync() ? file.readAsStringSync() : null;

  /// Write to a sibling and rename, so a reader never sees half a file.
  Future<void> _atomic(File file, String contents) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(contents, flush: true);
    await temporary.rename(file.path);
  }
}

/// The tunnel this device owns, as far as it can tell.
class SavedTunnel {
  const SavedTunnel({
    required this.id,
    required this.hostname,
    required this.token,
    this.certificate,
    this.chain,
    this.privateKeyPem,
  });

  final String id;
  final String hostname;
  final String token;

  /// The issued certificate, once one has arrived.
  final String? certificate;

  /// The chain it is served with.
  final String? chain;

  /// The key, which the certificate is only good for.
  final String? privateKeyPem;

  /// Whether there is enough here to serve TLS without asking again.
  bool get hasCertificate =>
      certificate != null && chain != null && privateKeyPem != null;

  /// Where a visitor reaches this tunnel.
  Uri get url => Uri.parse('https://$hostname/');
}