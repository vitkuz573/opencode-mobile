import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/pointycastle.dart';
import 'package:pointycastle/key_generators/ec_key_generator.dart';
// Imported for what they do, not for what they declare: pointycastle 4
// registers an algorithm by the side effect of loading its library, and the
// analyzer cannot see that. Without these, `SecureRandom` has no implementation
// registered, and the curve is not registered under the name used below - both
// failures surface at the first key generation and nowhere earlier, which is
// the worst place to find them.
// ignore: unused_import
import 'package:pointycastle/block/aes.dart';
// ignore: unused_import
import 'package:pointycastle/ecc/curves/prime256v1.dart';
// ignore: unused_import
import 'package:pointycastle/random/auto_seed_block_ctr_random.dart';

import 'der.dart';

/// The key a tunnel is reached through, and the request that got it certified.
///
/// OpenTunnel terminates TLS here, on the phone, and the service never holds
/// the private key. That is the whole point of the design: a service that could
/// read the key could read every byte a visitor sends, including the pairing
/// code and the server password. So the key is generated locally and never
/// leaves; the only thing that does leave is a certificate request, which
/// proves possession of the key without carrying it.
///
/// The identity outlives a single run. A tunnel is a hostname somebody may
/// have bookmarked and a certificate takes minutes to arrive, so both are kept
/// on disk and reused rather than minted per session.
class TunnelIdentity {
  const TunnelIdentity({
    required this.hostname,
    required this.privateKeyPem,
    required this.certificationRequest,
  });

  /// The `<id>.opentunnel.xyz` host this identity certifies.
  final String hostname;

  /// PKCS#8, PEM. Written to disk, sent nowhere.
  final String privateKeyPem;

  /// The signed PKCS#10 request, PEM: what the service issues against.
  final String certificationRequest;

  /// Generates a fresh key and asks for a certificate covering [hostname].
  ///
  /// The host is whatever the service issued, never one chosen here: it signs
  /// what it is willing to sign, and a request naming anything else comes back
  /// as a challenge this side has no way to answer.
  static TunnelIdentity create(String hostname) {
    final random = _random();
    final generator = ECKeyGenerator()
      ..init(ParametersWithRandom(
        ECKeyGeneratorParameters(ECDomainParameters(curve)),
        random,
      ));
    final pair = generator.generateKeyPair();
    final private = pair.privateKey;
    final public = pair.publicKey;
    return TunnelIdentity(
      hostname: hostname,
      privateKeyPem: Der.pem(
        'PRIVATE KEY',
        _pkcs8(private, public),
        base64.encode,
      ),
      // PEM armor, not bare base64: the service parses a document, and bare
      // base64 fails its parser before the ASN.1 is ever looked at.
      certificationRequest: Der.pem(
        'CERTIFICATE REQUEST',
        _certificationRequest(private, public, hostname, random),
        base64.encode,
      ),
    );
  }

  /// The DER the service receives: exactly the bytes the signature covers.
  static Uint8List _certificationRequest(
    ECPrivateKey private,
    ECPublicKey public,
    String hostname,
    SecureRandom random,
  ) {
    final info = _certificationRequestInfo(private, public, hostname);
    // The signer makes its own random when it is not given one, and this
    // package has no default for it - so it is handed the same generator the
    // key came from rather than left to fail on the first signature.
    final signer = Signer('SHA-256/ECDSA')
      ..init(true, ParametersWithRandom(PrivateKeyParameter<ECPrivateKey>(private), random));
    final signature = signer.generateSignature(info) as ECSignature;

    return Der.sequence([
      info,
      // ecdsa-with-SHA256, parameters omitted: RFC 5758 says absent is the same
      // as present, and a strict decoder can object to the other form.
      Der.sequence([Der.objectIdentifier(_ecdsaWithSha256)]),
      // ECDSA signatures travel as the DER SEQUENCE a verifier expects, not as
      // a raw (r, s) pair.
      Der.bitString(
        Der.sequence([
          Der.integer(signature.r),
          Der.integer(signature.s),
        ]),
      ),
    ]);
  }

  static Uint8List _certificationRequestInfo(
    ECPrivateKey private,
    ECPublicKey public,
    String hostname,
  ) =>
      Der.sequence([
        Der.integer(BigInt.zero),
        _subject(hostname),
        Der.sequence([
          Der.sequence([
            Der.objectIdentifier(_idEcPublicKey),
            Der.objectIdentifier(_prime256v1),
          ]),
          Der.bitString(_uncompressedPoint(public)),
        ]),
        Der.contextConstructed(0, _subjectAltName(hostname)),
      ]);

  /// `CN=<hostname>`. One field: a request for a host has nothing else to say.
  static Uint8List _subject(String hostname) => Der.sequence([
        Der.set([
          Der.sequence([
            Der.objectIdentifier('2.5.4.3'),
            Der.utf8String(hostname),
          ]),
        ]),
      ]);

  /// The `extensionRequest` attribute carrying the SAN extension.
  ///
  /// Routes are addressed as `<route>.<hostname>`, so the SAN holds the host
  /// and everything one label in front of it: without the wildcard every
  /// route is refused by the visitor's client. The common name cannot stand
  /// in: no client has fallen back to it for years.
  ///
  /// The nesting is the full standard one — Attribute{extensionRequest,
  /// {Extensions{Extension}}} — matching what opencode itself sends and what
  /// `openssl req -addext` produces, byte for byte. The middle `Extensions`
  /// SEQUENCE OF is easy to skip (one Extension looks complete without it),
  /// and the service refuses the request without it.
  ///
  /// This returns the Attribute SEQUENCE itself, not a SET of them: the
  /// `attributes` field of a request is tagged `[0]` *implicitly*, so the tag
  /// replaces the SET's rather than wrapping it. Leaving the SET in produces a
  /// structure a strict parser refuses, which is what a certificate authority
  /// is.
  static Uint8List _subjectAltName(String hostname) => Der.sequence([
        Der.objectIdentifier('1.2.840.113549.1.9.14'),
        Der.set([
          Der.sequence([
            Der.sequence([
              Der.objectIdentifier('2.5.29.17'),
              Der.octetString(
                Der.sequence([
                  Der.contextPrimitive(
                    2,
                    Uint8List.fromList(ascii.encode(hostname)),
                  ),
                  Der.contextPrimitive(
                    2,
                    Uint8List.fromList(ascii.encode('*.$hostname')),
                  ),
                ]),
              ),
            ]),
          ]),
        ]),
      ]);

  /// PKCS#8, the shape `SecurityContext.usePrivateKey` reads.
  static Uint8List _pkcs8(ECPrivateKey private, ECPublicKey public) =>
      Der.sequence([
        Der.integer(BigInt.zero),
        Der.sequence([
          Der.objectIdentifier(_idEcPublicKey),
          Der.objectIdentifier(_prime256v1),
        ]),
        Der.octetString(
          Der.sequence([
            Der.integer(BigInt.one),
            Der.octetString(_fixed(private.d!)),
            Der.contextConstructed(0, Der.objectIdentifier(_prime256v1)),
            Der.contextConstructed(1, Der.bitString(_uncompressedPoint(public))),
          ]),
        ),
      ]);

  /// An EC coordinate, always the width the curve uses.
  ///
  /// Big integers drop leading zeros, and a field of the wrong length decodes
  /// as a different number, silently, and only when something goes wrong later.
  /// 32 bytes is what P-256 uses.
  static Uint8List _fixed(BigInt value) {
    final bytes = Der.unsigned(value);
    if (bytes.length == 32) return bytes;
    if (bytes.length > 32) {
      throw ArgumentError.value(value, 'value', 'too wide for P-256');
    }
    return Uint8List(32 - bytes.length)..setRange(32 - bytes.length, 32, bytes);
  }

  /// `0x04 || X || Y`, the uncompressed point, the only form X.509 allows.
  ///
  /// The point arrives as field elements rather than numbers; they are already
  /// reduced mod the curve, so they are the coordinates that belong in here.
  static Uint8List _uncompressedPoint(ECPublicKey public) {
    final point = public.Q;
    if (point == null) {
      throw StateError('the generated key carries no public point');
    }
    return Uint8List.fromList([
      0x04,
      ..._fixed(point.x!.toBigInteger()!),
      ..._fixed(point.y!.toBigInteger()!),
    ]);
  }

  // Written out rather than imported: pointycastle 4 ships the CSR skeleton
  // and an OID registry, but nothing that builds the hard part — the SAN
  // extension with its implicit tags. Depending on its encoder for the easy
  // primitives while hand-rolling the tricky composition would leave two
  // encoders and two sets of edge cases in one request; one local encoder
  // with one set of rules is the smaller risk.

  static const _idEcPublicKey = '1.2.840.10045.2.1';
  static const _prime256v1 = '1.2.840.10045.3.1.7';
  static const _ecdsaWithSha256 = '1.2.840.10045.4.3.2';

  /// The name this library knows the curve by.
  static const curve = 'prime256v1';

  /// The generator the key is drawn from.
  ///
  /// Nothing in this package registers a default, so the parameterless
  /// `SecureRandom()` the rest of the library reaches for throws; and the one
  /// registered under a self-seeding name still expects a key before it will
  /// produce a byte. So the seed is taken here, from the platform generator,
  /// rather than assumed.
  static SecureRandom _random() {
    final entropy = Random.secure();
    return SecureRandom(_randomSource)
      ..seed(
        KeyParameter(
          Uint8List.fromList(List<int>.generate(32, (_) => entropy.nextInt(256))),
        ),
      );
  }

  static const _randomSource = 'AES/CTR/AUTO-SEED-PRNG';
}