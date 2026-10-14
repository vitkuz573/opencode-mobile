import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/runtime/tunnel/der.dart';
import 'package:opencode_mobile/src/runtime/tunnel/tunnel_identity.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/ecc_fp.dart' as fp;


/// The DER inside a PEM document, for decoders that read bytes, not armor.
Uint8List _derOf(String pem) {
  final body = pem
      .split('\n')
      .where((line) => line.isNotEmpty && !line.startsWith('-----'))
      .join();
  return base64.decode(body);
}

void main() {
  group('Der', () {
    test('encodes an object identifier with its first two arcs fused', () {
      // 1.2.840.10045.4.3.2 is ecdsa-with-SHA256, and encodes as 2a 86 48
      // ce 3d 04 03 02 - the 1.2 pair is a single first byte, which is the
      // whole reason an OID is not "one byte per arc".
      final der = Der.objectIdentifier('1.2.840.10045.4.3.2');
      expect(der.sublist(0, 10), [0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02]);
    });

    test('round-trips an object identifier', () {
      for (final oid in [
        '1.2.840.10045.2.1',
        '1.2.840.10045.3.1.7',
        '2.5.29.17',
        '2.5.4.3',
      ]) {
        expect(DerNode.read(Der.objectIdentifier(oid)).single.asObjectIdentifier, oid);
      }
    });

    test('pads an integer whose top bit would read as a sign', () {
      // 0x80 is negative as a signed byte, so DER has to say 00 80.
      expect(Der.integer(BigInt.from(0x80)), [0x02, 0x02, 0x00, 0x80]);
      expect(Der.integer(BigInt.from(0x7f)), [0x02, 0x01, 0x7f]);
      expect(Der.integer(BigInt.zero), [0x02, 0x01, 0x00]);
    });

    test('refuses a negative integer rather than encoding nonsense', () {
      expect(() => Der.integer(BigInt.from(-1)), throwsArgumentError);
    });

    test('uses the short length form only where it is legal', () {
      final short = Der.octetString(Uint8List(127));
      expect(short[1], 127);
      final long = Der.octetString(Uint8List(128));
      expect(long[1], 0x81);
      expect(long[2], 128);
    });

    test('reads a nested sequence back', () {
      final inner = Der.sequence([Der.integer(BigInt.from(7)), Der.utf8String('ab')]);
      final outer = Der.sequence([inner]);
      final node = DerNode.read(outer).single;
      expect(node.tag, 0x30);
      final innerChildren = node.children.single.children;
      expect(innerChildren[0].asInteger, BigInt.from(7));
      expect(String.fromCharCodes(innerChildren[1].value), 'ab');
    });
  });

  group('TunnelIdentity', () {
    const host = 'abcdefghijkl.opentunnel.xyz';

    test('asks for the host and one label in front of it', () {
      final identity = TunnelIdentity.create(host);
      final request =
          DerNode.read(_derOf(identity.certificationRequest)).single;
      final info = request.children.first;

      // attributes [0] is tagged implicitly, so what sits inside it is the
      // Attribute itself, not a SET of them: extensionRequest carrying one
      // SAN extension, like opencode's own requests.
      final attribute = info.children[3].children.single;
      expect(
        attribute.children.first.asObjectIdentifier,
        '1.2.840.113549.1.9.14',
      );
      final extensions = attribute.children[1].children.single.children;
      final extension = extensions.single.children;
      expect(extension.first.asObjectIdentifier, '2.5.29.17');
      final generalNames = DerNode.read(
        extension[1].value,
      ).single.children;
      final covered = generalNames.map((n) => String.fromCharCodes(n.value)).toList();

      // A wildcard is not decoration: routes are `<route>.<hostname>`, and a
      // certificate without it is refused by every client that visits one.
      expect(covered, [host, '*.$host']);
    });

    test('signs the exact bytes it sends', () {
      final identity = TunnelIdentity.create(host);
      final csr = DerNode.read(_derOf(identity.certificationRequest)).single;
      expect(csr.children.length, 3);

      final info = csr.children[0];
      final algorithm = csr.children[1].children.single.asObjectIdentifier;
      expect(algorithm, '1.2.840.10045.4.3.2');

      final signature = csr.children[2].asBitString;
      final pair = DerNode.read(signature).single.children;
      final r = pair[0].asInteger;
      final s = pair[1].asInteger;

      // The request is verified against the public key it carries, rebuilt
      // from the request itself: nothing here trusts the generator.
      final key = _publicKeyFrom(info.children[2]);
      final verifier = Signer('SHA-256/ECDSA')
        ..init(false, PublicKeyParameter<ECPublicKey>(key));
      // The signature covers the request as it appears in the blob, tag and
      // length included, not just its contents.
      expect(
        verifier.verifySignature(info.encode(), ECSignature(r, s)),
        isTrue,
        reason: 'the request must verify against the key it carries',
      );
    });

    test('produces a private key the platform can load', () {
      final identity = TunnelIdentity.create(host);
      // This is the step that decides whether the tunnel can work at all: the
      // certificate arrives as PEM and BoringSSL will only serve it with a key
      // it can actually read, so a key only this project can parse is a tunnel
      // that never completes a handshake. Note the bytes, not the path: the
      // file form of this call takes a filename, and the key never needs one.
      expect(
        () => SecurityContext().usePrivateKeyBytes(
          utf8.encode(identity.privateKeyPem),
        ),
        returnsNormally,
      );
    });

    test('rejects a key that is not one', () {
      // A PEM that decodes to nothing throws rather than being ignored: a
      // tunnel serving with no key at all would fail every handshake, and
      // silently continuing to the first visitor is the worse way to find out.
      expect(
        () => SecurityContext().usePrivateKeyBytes(
          utf8.encode(
            '-----BEGIN PRIVATE KEY-----\nbm90IGEga2V5\n-----END PRIVATE KEY-----\n',
          ),
        ),
        throwsA(anyOf(isA<TlsException>(), isA<ArgumentError>())),
      );
    });

    test('never writes the private key into the request', () {
      final identity = TunnelIdentity.create(host);
      final request = identity.certificationRequest;
      final key = identity.privateKeyPem
          .split('\n')
          .where((l) => !l.startsWith('---'))
          .join();
      expect(request, isNot(contains(key)));
    });

    test('parses with an independent decoder', () {
      // The strictness gate. Every structural assertion above goes through
      // DerNode, which is ours and shares our assumptions, so a systematic
      // encoding mistake would pass them all. This parses the same bytes with
      // pointycastle's own decoder instead: two implementations have to agree
      // on framing, tags and structure, or the CSR never reaches a CA.
      // openssl verified the same shape by hand once (`req -verify`);
      // this keeps it verified on every run.
      final identity = TunnelIdentity.create(host);
      final bytes = _derOf(identity.certificationRequest);
      final parser = ASN1Parser(bytes);
      final root = parser.nextObject();
      // Exactly one object consuming everything: no trailing garbage that a
      // lenient reader would swallow, no truncation a strict one would pad.
      expect(parser.hasNext(), isFalse);
      expect(root, isA<ASN1Sequence>());
      final top = (root as ASN1Sequence).elements!;
      expect(top, hasLength(3));

      final info = (top[0] as ASN1Sequence).elements!;
      expect(info, hasLength(4));
      expect((info[0] as ASN1Integer).integer, BigInt.zero);

      final algorithm = (top[1] as ASN1Sequence).elements!;
      expect(
        (algorithm[0] as ASN1ObjectIdentifier).objectIdentifierAsString,
        '1.2.840.10045.4.3.2',
      );

      // The [0] attributes block is implicit, so their parser - like ours -
      // must find the Attribute itself, not a SET of them: extensionRequest
      // carrying one SAN extension, like opencode's own requests.
      final attributes = ASN1Parser(info[3].valueBytes!).nextObject();
      expect(attributes, isA<ASN1Sequence>());
      final attribute = (attributes as ASN1Sequence).elements!;
      expect(
        (attribute[0] as ASN1ObjectIdentifier).objectIdentifierAsString,
        '1.2.840.113549.1.9.14',
      );
      final extensions =
          ((attribute[1] as ASN1Set).elements!.single as ASN1Sequence)
              .elements!;
      final extension =
          (extensions.single as ASN1Sequence).elements!;
      expect(
        (extension[0] as ASN1ObjectIdentifier).objectIdentifierAsString,
        '2.5.29.17',
      );
      final names = ASN1Parser(
        (extension[1] as ASN1OctetString).valueBytes!,
      ).nextObject();
      expect(names, isA<ASN1Sequence>());
      expect(
        ((names as ASN1Sequence).elements!).map(
          (n) => String.fromCharCodes(n.valueBytes!),
        ),
        [host, '*.$host'],
      );
    });
  });
}

/// The prime of the P-256 curve, which the field elements are built over.
///
/// It is a property of the curve, not something to configure, and it is the one
/// thing `ECFieldElement` needs in order to rebuild a point from raw bytes.
final _p256Prime = BigInt.parse(
  'FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF',
  radix: 16,
);

/// The P-256 curve, built from its parameters.
///
/// [fp.ECCurve] and [ECDomainParameters.curve] are different types that both
/// go by the name `ECCurve`, so the curve is constructed here rather than asked
/// for: a test that rebuilds a public key needs the concrete one.
fp.ECCurve get _p256Curve => fp.ECCurve(
      _p256Prime,
      _p256Prime - BigInt.from(3),
      BigInt.parse(
        '5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B',
        radix: 16,
      ),
    );

ECPublicKey _publicKeyFrom(DerNode subjectPublicKeyInfo) {
  final algorithm = subjectPublicKeyInfo.children[0].children;
  expect(algorithm.first.asObjectIdentifier, '1.2.840.10045.2.1');
  expect(algorithm[1].asObjectIdentifier, '1.2.840.10045.3.1.7');

  final point = subjectPublicKeyInfo.children[1].asBitString;
  expect(point.first, 0x04, reason: 'only the uncompressed form is allowed');

  final curve = _p256Curve;
  return ECPublicKey(
    fp.ECPoint(
      curve,
      fp.ECFieldElement(_p256Prime, _bigInt(point.sublist(1, 33))),
      fp.ECFieldElement(_p256Prime, _bigInt(point.sublist(33, 65))),
    ),
    ECDomainParameters(TunnelIdentity.curve),
  );
}

BigInt _bigInt(Uint8List bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value;
}