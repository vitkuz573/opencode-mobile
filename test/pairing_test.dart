import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/data/pairing.dart';

void main() {
  group('the address printed in the QR', () {
    // What actually happens: `opencode pair` prints a link per reachable
    // address but encodes only the first into the QR, which is loopback. On a
    // phone that address is the phone.
    const printed = '''
  http://127.0.0.1:49374/auth/connect/Q4WSc1PjtEB7tDAVzy7TzA
  https://t7xq2m4k9b1n3vd8.opentunnel.example/auth/connect/Q4WSc1PjtEB7tDAVzy7TzA
''';
    const scanned = 'http://127.0.0.1:49374/auth/connect/Q4WSc1PjtEB7tDAVzy7TzA';

    test('the QR alone carries only the loopback link', () {
      expect(PairingLink.all(scanned), hasLength(1));
      expect(PairingLink.isLoopback(PairingLink.tryParse(scanned)!), isTrue);
    });

    test('both addresses come out of the printed output', () {
      expect(PairingLink.all(printed), hasLength(2));
    });

    test('the code is the same behind both addresses', () {
      final code = PairingLink.codeOf(scanned);
      expect(code, 'Q4WSc1PjtEB7tDAVzy7TzA');
      for (final link in PairingLink.all(printed)) {
        expect(PairingLink.codeOf(link), code);
      }
    });

    test('a loopback link can be retargeted at a reachable host', () {
      expect(
        PairingLink.retarget(
          scanned,
          'https://t7xq2m4k9b1n3vd8.opentunnel.example',
        ),
        'https://t7xq2m4k9b1n3vd8.opentunnel.example'
            '/auth/connect/Q4WSc1PjtEB7tDAVzy7TzA',
      );
    });

    test('retargeting keeps the scheme when only a host is given', () {
      // No scheme in, https out: a bare host would otherwise resolve to http.
      expect(
        PairingLink.retarget(scanned, 'tunnel.example'),
        'https://tunnel.example/auth/connect/Q4WSc1PjtEB7tDAVzy7TzA',
      );
    });

    test('retargeting drops a port that is not on the new address', () {
      final retargeted = PairingLink.retarget(
        scanned,
        'https://tunnel.example',
      );
      expect(retargeted, isNot(contains('49374')));
    });

    test('retargeting keeps a port the new address does carry', () {
      expect(
        PairingLink.retarget(scanned, 'https://box.test:8443'),
        'https://box.test:8443/auth/connect/Q4WSc1PjtEB7tDAVzy7TzA',
      );
    });

    test('nothing to retarget without a code', () {
      expect(
        PairingLink.retarget('https://example.test/', 'box.test'),
        isNull,
      );
      expect(PairingLink.retarget(scanned, ''), isNull);
    });

    test('retargeting a link onto itself changes nothing meaningful', () {
      expect(
        PairingLink.retarget(scanned, 'http://127.0.0.1:49374'),
        'http://127.0.0.1:49374/auth/connect/Q4WSc1PjtEB7tDAVzy7TzA',
      );
    });

    test('a code-less URL reports no code', () {
      expect(PairingLink.codeOf('https://example.test/auth/connect/'), isNull);
      expect(PairingLink.codeOf('https://example.test/other/x'), isNull);
    });
  });

  group('pairing link parsing', () {
    test('accepts what `opencode pair` prints', () {
      expect(
        PairingLink.tryParse('http://127.0.0.1:49374/auth/connect/deYdLkgiiI'),
        'http://127.0.0.1:49374/auth/connect/deYdLkgiiI',
      );
    });

    test('accepts a tunnel link', () {
      expect(
        PairingLink.tryParse(
          'https://t7xq2m4k9b1n3vd8.opentunnel.example'
          '/auth/connect/Iuw63Fwv-_MGheKCTlZERw',
        ),
        'https://t7xq2m4k9b1n3vd8.opentunnel.example'
            '/auth/connect/Iuw63Fwv-_MGheKCTlZERw',
      );
    });

    test('drops a query string the link carries', () {
      expect(
        PairingLink.tryParse('http://1.2.3.4:4096/auth/connect/abc123?x=1'),
        'http://1.2.3.4:4096/auth/connect/abc123',
      );
    });

    test('prefers the reachable link when pair printed two', () {
      // This is exactly what opencode pair prints with remote access on, and
      // the loopback one comes first.
      const printed = '''
  http://127.0.0.1:49374/auth/connect/tb1xGTfJAcNHRuNDwq8DWw
  https://t7xq2m4k9b1n3vd8.opentunnel.example/auth/connect/tb1xGTfJAcNHRuNDwq8DWw

  [QR CODE HERE]
''';
      expect(
        PairingLink.tryParse(printed),
        'https://t7xq2m4k9b1n3vd8.opentunnel.example'
            '/auth/connect/tb1xGTfJAcNHRuNDwq8DWw',
      );
    });

    test('falls back to loopback when it is the only link', () {
      expect(
        PairingLink.tryParse(
          'http://127.0.0.1:49374/auth/connect/onlyone000',
        ),
        'http://127.0.0.1:49374/auth/connect/onlyone000',
      );
    });

    test('recognises hosts a phone cannot reach', () {
      expect(
        PairingLink.isLoopback('http://127.0.0.1:49374/auth/connect/x'),
        isTrue,
      );
      expect(PairingLink.isLoopback('http://localhost:4096/x'), isTrue);
      expect(PairingLink.isLoopback('http://[::1]:4096/x'), isTrue);
      expect(PairingLink.isLoopback('http://10.0.2.2:4096/x'), isTrue);
      expect(
        PairingLink.isLoopback('https://tunnel.opentunnel.xyz/x'),
        isFalse,
      );
      expect(PairingLink.isLoopback('http://192.168.1.20:4096/x'), isFalse);
    });

    test('names the host for error messages', () {
      expect(
        PairingLink.hostOf('https://tunnel.opentunnel.xyz/auth/connect/x'),
        'tunnel.opentunnel.xyz',
      );
    });

    test('pulls a link out of surrounding terminal noise', () {
      const noisy = '''
  Open a link to connect. Links work once and expire in 5 minutes.

  https://box.local:4096/auth/connect/ZZ_topsecret99

  ███ ▄▄▄ ███
''';
      expect(
        PairingLink.tryParse(noisy),
        'https://box.local:4096/auth/connect/ZZ_topsecret99',
      );
    });

    test('trims whitespace', () {
      expect(
        PairingLink.tryParse('  http://h:4096/auth/connect/c1  \n'),
        'http://h:4096/auth/connect/c1',
      );
    });

    test('rejects a URL without the connect marker', () {
      expect(PairingLink.tryParse('http://127.0.0.1:4096/api/info'), isNull);
      expect(PairingLink.tryParse('http://127.0.0.1:4096/'), isNull);
    });

    test('rejects an empty code', () {
      expect(PairingLink.tryParse('http://h:4096/auth/connect/'), isNull);
      expect(PairingLink.tryParse('http://h:4096/auth/connect'), isNull);
    });

    test('rejects non-http schemes and junk', () {
      expect(PairingLink.tryParse('ftp://h/auth/connect/x'), isNull);
      expect(PairingLink.tryParse('not a link'), isNull);
      expect(PairingLink.tryParse(''), isNull);
      expect(PairingLink.tryParse('WIFI:S:open;P:secret;;'), isNull);
    });

    test('rejects a QR code holding something unrelated', () {
      expect(PairingLink.tryParse('https://example.com/'), isNull);
      expect(PairingLink.tryParse('{"type":"session.created"}'), isNull);
    });
  });
}