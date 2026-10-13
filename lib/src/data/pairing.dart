/// A pairing link printed by `opencode pair`.
///
/// The link is the credential: single use, five minute lifetime.
///
/// `opencode pair` prints **more than one** link when remote access is on:
///
/// ```text
///   http://127.0.0.1:49374/auth/connect/tb1xGTfJAcNHRuNDwq8DWw
///   https://t7xq2m4k9b1n3vd8.opentunnel.example/auth/connect/tb1xGTfJAcNHRuNDwq8DWw
/// ```
///
/// and the loopback one comes first. On a phone `127.0.0.1` is the phone, so
/// picking the first match connects to nothing. Selection therefore prefers a
/// host the device can actually reach.
abstract final class PairingLink {
  /// Returns the best pairing link found in [raw], or `null` if there is none.
  static String? tryParse(String raw) {
    final candidates = all(raw);
    if (candidates.isEmpty) return null;
    return candidates.firstWhere(
      (url) => !isLoopback(url),
      orElse: () => candidates.first,
    );
  }

  /// Every pairing link in [raw], in the order they appear.
  ///
  /// `opencode pair` prints one link per reachable address and encodes only the
  /// first into its QR code, so a scan can hand back a loopback link that means
  /// nothing on a phone. Offering the list lets the user pick.
  static List<String> all(String raw) => _candidates(raw);

  /// True when [link] points at the device itself rather than at the machine
  /// running the server.
  static bool isLoopback(String link) {
    final host = Uri.tryParse(link)?.host.toLowerCase() ?? '';
    return host == '127.0.0.1' ||
        host == 'localhost' ||
        host == '::1' ||
        host == '[::1]' ||
        // The Android emulator's alias for the host machine: reachable from an
        // emulator, never from a physical device.
        host == '10.0.2.2';
  }

  /// The host of [link], for error messages that name the target.
  static String? hostOf(String link) => Uri.tryParse(link)?.host;

  /// The single-use code carried in the link's path.
  static String? codeOf(String link) {
    const marker = '/auth/connect/';
    final path = Uri.tryParse(link)?.path ?? '';
    final index = path.indexOf(marker);
    if (index < 0) return null;
    final code = path.substring(index + marker.length).split('/').first;
    return code.isEmpty ? null : code;
  }

  /// Rebuilds [link] against [host], keeping the code.
  ///
  /// A pairing code is not bound to an address: `opencode pair` prints the same
  /// code behind several hosts. So a link printed for loopback can be retargeted
  /// at a tunnel the phone already reaches.
  static String? retarget(String link, String host) {
    final uri = Uri.tryParse(link);
    final code = codeOf(link);
    if (uri == null || code == null || host.trim().isEmpty) return null;
    final origin = Uri.tryParse(
      host.contains('://') ? host : 'https://$host',
    );
    if (origin == null || origin.host.isEmpty) return null;
    return Uri(
      scheme: origin.scheme.isEmpty ? uri.scheme : origin.scheme,
      host: origin.host,
      // Never inherit the old port. A loopback link carries the server's own
      // port, 49374; a tunnel serves on 443 and inheriting would send the
      // request to a port nothing is listening on.
      port: origin.hasPort ? origin.port : null,
      path: uri.path,
    ).toString();
  }

  static final _urlPattern = RegExp(r'https?://[^\s"<>]+');

  static List<String> _candidates(String raw) {
    final found = <String>[];
    for (final match in _urlPattern.allMatches(raw)) {
      final value = match.group(0)!;
      // A query or fragment is not part of a pairing link.
      final cleaned = value.split(RegExp(r'[?#]')).first;
      if (_isPairingPath(cleaned)) found.add(cleaned);
    }
    return found;
  }

  static bool _isPairingPath(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.path.isEmpty) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;

    const marker = '/auth/connect/';
    final index = uri.path.indexOf(marker);
    if (index < 0) return false;
    return uri.path.substring(index + marker.length).split('/').first
        .isNotEmpty;
  }
}