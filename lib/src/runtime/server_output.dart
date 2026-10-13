// Reading what the OpenCode process prints.
//
// Stdout is the source of the port the server actually bound, so its words
// are parsed rather than guessed. The password is deliberately NOT here: with
// `--service` the server never prints it and only writes it to the service
// file, which the handle polls instead. All of it is pure so it can be tested
// against recorded output.

/// `server listening on http://127.0.0.1:4196`
///
/// The URL the process reports is more trustworthy than the one that was asked
/// for: it reflects the port that was really taken.
final _listening = RegExp(r'server listening on (\S+)');

/// `server password CmvwUMBIeLIQG4xkYDK3AX8zgWYbs1GEcQqCrCSVPQc`
final _password = RegExp(r'server password (\S+)');

/// The pairing link `opencode pair` prints, e.g.
/// `http://127.0.0.1:4196/auth/connect/5QZtEVT3rp8pn68rM-IigQ`
///
/// Pairing goes through a path that only that command produces, so an arbitrary
/// URL in the output cannot be mistaken for one.
final _pairingLink = RegExp(r'https?://\S+/auth/connect/\S+');

/// The address the server says it bound, or null if the line is not that.
String? parseListeningUrl(String line) => _listening.firstMatch(line)?.group(1);

/// The password the server generated, or null.
String? parseServerPassword(String line) => _password.firstMatch(line)?.group(1);

/// The pairing link in a `pair` run, or null.
///
/// An error is reported by printing a reason; when `pair` fails there is no
/// link, and the caller shows the output instead of inventing one.
String? parsePairingLink(String output) => _pairingLink.firstMatch(output)?.group(0);

/// The first sentence of a failure, for a message that has to fit in a snackbar.
///
/// The command's errors are multi-line stack traces. The first line carries the
/// reason — which is what the user can act on — and the rest is noise from a
/// bundled runtime they cannot fix.
String? parseFailure(String output) {
  for (final line in output.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.startsWith('at ') || trimmed.startsWith(r'$')) continue;
    return trimmed;
  }
  return null;
}