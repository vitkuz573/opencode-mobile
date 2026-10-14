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
///
/// `pair` prints a framed notice before it does anything, so the first line is
/// often a box-drawing character and saying so would be no explanation at all.
/// Those are passed over, and a line that actually names the error wins over
/// one that merely precedes it.
String? parseFailure(String output) {
  String? firstSubstantive;
  for (final line in output.split('\n')) {
    final trimmed = line.trim();
    if (_isDecoration(trimmed)) continue;
    if (trimmed.startsWith('at ') || trimmed.startsWith(r'$')) continue;
    if (trimmed.startsWith('Error:') || trimmed.startsWith('error:')) {
      return trimmed;
    }
    firstSubstantive ??= trimmed;
  }
  return firstSubstantive;
}

/// Whether [line] is part of a framed notice rather than a sentence.
bool _isDecoration(String line) {
  if (line.isEmpty) return true;
  for (final unit in line.runes) {
    final c = String.fromCharCode(unit);
    // Box drawing, block elements, geometric shapes, and the glyphs the CLI
    // uses for prompts and bullets.
    const drawing = '─-═│┃┌┐└┘├┤┬┴┼╭╮╰╯▲▼◀▶✔✖•□■◆●○';
    if (!drawing.contains(c)) return false;
  }
  return true;
}