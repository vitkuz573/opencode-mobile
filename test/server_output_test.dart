import 'package:opencode_mobile/src/runtime/server_output.dart';
import 'package:flutter_test/flutter_test.dart';

/// Everything here is parsed from output recorded on a real device running
/// OpenCode 2.0.28 on Android. If upstream changes its wording these fail,
/// which is the point: the alternative is a server that starts and then shows
/// a blank password.
void main() {
  group('listening address', () {
    test('reads the address the server says it bound', () {
      expect(
        parseListeningUrl('server listening on http://127.0.0.1:4196'),
        'http://127.0.0.1:4196',
      );
    });

    test('ignores a line that is not it', () {
      expect(parseListeningUrl('some other output'), isNull);
      expect(parseListeningUrl(''), isNull);
    });
  });

  group('password', () {
    test('reads the generated password', () {
      expect(
        parseServerPassword(
          'server password CmvwUMBIeLIQG4xkYDK3AX8zgWYbs1GEcQqCrCSVPQc',
        ),
        'CmvwUMBIeLIQG4xkYDK3AX8zgWYbs1GEcQqCrCSVPQc',
      );
    });

    test('a hyphenated password is not truncated', () {
      expect(
        parseServerPassword(
          'server password e5o1oYflr86L-7Hep3yS8I6SVpvZul43FkTQVt7A-Tk',
        ),
        'e5o1oYflr86L-7Hep3yS8I6SVpvZul43FkTQVt7A-Tk',
      );
    });
  });

  group('pairing link', () {
    test('finds the link in the real `pair` output', () {
      const output = r'''

  Open a link to connect. Links work once and expire in 5 minutes.

  http://127.0.0.1:4196/auth/connect/5QZtEVT3rp8pn68rM-IigQ

  Over SSH? Forward the port, then open the link on your machine:
  ssh -L 4196:127.0.0.1:4196 <host>
''';
      expect(
        parsePairingLink(output),
        'http://127.0.0.1:4196/auth/connect/5QZtEVT3rp8pn68rM-IigQ',
      );
    });

    test('an ssh suggestion is not a pairing link', () {
      expect(
        parsePairingLink('  ssh -L 4196:127.0.0.1:4196 <host>'),
        isNull,
      );
    });

    test('a failed run offers no link', () {
      const output = r'''Setting up remote access; this can take a minute...
OpenTunnelClientError: Failed to create tunnel
    at b (/$bunfs/root/chunk-s16mmqqk.js:7:8345)
''';
      expect(parsePairingLink(output), isNull);
    });
  });

  group('failure', () {
    test('keeps the reason and drops the stack', () {
      const output = r'''Setting up remote access; this can take a minute...
OpenTunnelClientError: Failed to create tunnel
    at b (/$bunfs/root/chunk-s16mmqqk.js:7:8345)
    at <anonymous> (/$bunfs/root/chunk-w85x5pvh.js:18:6047)
''';
      expect(
        parseFailure(output),
        'Setting up remote access; this can take a minute...',
      );
    });

    test('does not return an empty first line', () {
      expect(
        parseFailure('\n\n  OpenTunnelClientError: Failed to create tunnel'),
        'OpenTunnelClientError: Failed to create tunnel',
      );
    });

    test('has nothing to say about nothing', () {
      expect(parseFailure('\n  \n'), isNull);
    });

    // Recorded from a real `pair --remote` run on the device. The framed notice
    // comes first, so taking the first line literally produced a single box
    // drawing character as the entire explanation.
    test('skips the framed notice pair prints before it fails', () {
      const output = '''│
▲  This will expose your OpenCode server to the internet.
│  Traffic is end-to-end encrypted, and access requires your server password.
│  To pair locally instead, run `opencode pair` without the --remote flag.
Setting up remote access; this can take a minute...
Error: Server process exited with code 1
    at map (native:1:11)
''';
      expect(
        parseFailure(output),
        'Error: Server process exited with code 1',
      );
    });

    test('still reports the first sentence when nothing is labelled', () {
      // A bullet in front of words makes the line a sentence, not a border.
      const output = '''│
│
▲  Heads up.
    at map (native:1:11)
''';
      expect(parseFailure(output), '▲  Heads up.');
    });
  });
}