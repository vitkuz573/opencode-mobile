import 'dart:convert';
import 'dart:typed_data';

/// Just enough DER to build a certificate request, and to read one back.
///
/// A CSR is a handful of nested structures with fixed tags, and the library
/// that could have written them does not ship one. Writing the bytes here
/// rather than assembling them out of a general ASN.1 builder keeps the output
/// exactly what was asked for - DER, shortest form, no optional fields that
/// happen to be empty - which is what a certificate authority will parse, and
/// what a test can assert on byte for byte.
///
/// Only what [TunnelIdentity] needs is here. This is not an ASN.1 library.
class Der {
  const Der._();

  static const _sequence = 0x30;
  static const _set = 0x31;
  static const _integer = 0x02;
  static const _bitString = 0x03;
  static const _octetString = 0x04;
  static const _objectIdentifier = 0x06;
  static const _utf8String = 0x0C;

  /// `IA5String`, which is how a DNS name travels inside a certificate.
  static Uint8List ia5String(String value) =>
      _tagged(0x16, Uint8List.fromList(ascii.encode(value)));

  /// `SEQUENCE OF ...`
  static Uint8List sequence(List<Uint8List> items) => _tagged(_sequence, _concat(items));

  /// `SET OF ...`
  static Uint8List set(List<Uint8List> items) => _tagged(_set, _concat(items));

  /// A non-negative INTEGER, with the leading zero DER requires when the top
  /// bit of the first byte would otherwise read as a negative number.
  static Uint8List integer(BigInt value) {
    if (value.isNegative) {
      throw ArgumentError.value(value, 'value', 'DER here is unsigned');
    }
    if (value == BigInt.zero) return _tagged(_integer, Uint8List.fromList([0]));
    var bytes = unsigned(value);
    if (bytes.first & 0x80 != 0) bytes = Uint8List.fromList([0, ...bytes]);
    return _tagged(_integer, bytes);
  }

  /// `BIT STRING`, carrying whole bytes only: the trailing-bits count is
  /// always zero here, and saying otherwise would change the encoding of the
  /// bytes inside.
  static Uint8List bitString(Uint8List bytes) =>
      _tagged(_bitString, Uint8List.fromList([0, ...bytes]));

  static Uint8List octetString(Uint8List bytes) => _tagged(_octetString, bytes);

  static Uint8List utf8String(String value) =>
      _tagged(_utf8String, Uint8List.fromList(utf8.encode(value)));

  /// `[tag]` wrapping a constructed value, as `attributes` and the named curve
  /// inside a key are encoded.
  static Uint8List contextConstructed(int tag, Uint8List content) =>
      _tagged(0xA0 | tag, content);

  /// `[tag]` wrapping a primitive value, as each entry of `GeneralNames` is.
  static Uint8List contextPrimitive(int tag, Uint8List content) =>
      _tagged(0x80 | tag, content);

  /// A dotted object identifier, encoded as its base-128 arcs.
  ///
  /// The first two arcs share a byte: 42 and 0x550401 encode as 0x86f7 0x0d,
  /// which is why this cannot be "each arc on its own".
  static Uint8List objectIdentifier(String dotted) {
    final arcs = dotted.split('.').map(BigInt.parse).toList();
    if (arcs.length < 2) {
      throw ArgumentError.value(dotted, 'dotted', 'needs at least two arcs');
    }
    final bytes = <int>[
      ..._base128(arcs[0] * BigInt.from(40) + arcs[1]),
      for (final arc in arcs.skip(2)) ..._base128(arc),
    ];
    return _tagged(_objectIdentifier, Uint8List.fromList(bytes));
  }

  /// PEM wrapping, so a key can be handed to `SecurityContext` unchanged.
  static String pem(String label, Uint8List der, String Function(List<int>) encode) {
    final body = encode(der);
    final lines = [
      for (var i = 0; i < body.length; i += 64)
        body.substring(i, (i + 64) < body.length ? i + 64 : body.length),
    ];
    return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
  }

  static Uint8List _tagged(int tag, Uint8List content) =>
      Uint8List.fromList([tag, ..._length(content.length), ...content]);

  /// A tag-length-value triple around [content].
  ///
  /// Public because reading a structure and writing it back has to agree: a
  /// signature is verified over the encoded bytes, and the encoded bytes are
  /// the tag and length as well as the content.
  static Uint8List tagged(int tag, Uint8List content) => _tagged(tag, content);

  /// Big-endian, no sign byte, at least one byte.
  static Uint8List unsigned(BigInt value) {
    final length = (value.bitLength + 7) ~/ 8;
    final bytes = Uint8List(length);
    var remaining = value;
    for (var i = length - 1; i >= 0; i--) {
      bytes[i] = (remaining & BigInt.from(0xff)).toInt();
      remaining >>= 8;
    }
    return bytes;
  }

  /// Short form below 128, long form above: a long form under 128 bytes is
  /// valid DER but a decoder that is strict about it will refuse the lot.
  static List<int> _length(int length) {
    if (length < 0x80) return [length];
    final bytes = <int>[];
    var remaining = length;
    while (remaining > 0) {
      bytes.insert(0, remaining & 0xff);
      remaining >>= 8;
    }
    return [0x80 | bytes.length, ...bytes];
  }

  /// Big-endian base-128, most significant group first, each group carrying its
  /// continuation bit on all but the last.
  static List<int> _base128(BigInt value) {
    final groups = <int>[];
    var remaining = value;
    while (true) {
      groups.insert(0, (remaining & BigInt.from(0x7f)).toInt());
      remaining >>= 7;
      if (remaining == BigInt.zero) break;
    }
    return [
      for (var i = 0; i < groups.length; i++)
        i == groups.length - 1 ? groups[i] : groups[i] | 0x80,
    ];
  }

  static Uint8List _concat(List<Uint8List> items) {
    final total = items.fold(0, (sum, item) => sum + item.length);
    final out = Uint8List(total);
    var offset = 0;
    for (final item in items) {
      out.setRange(offset, offset + item.length, item);
      offset += item.length;
    }
    return out;
  }
}

/// One tag-length-value triple, read back out of a DER blob.
class DerNode {
  DerNode(this.tag, this.value);

  final int tag;
  final Uint8List value;

  /// Whether this value holds other values rather than bytes of its own.
  ///
  /// Bit 6 of the tag says so, and everything context-specific in here is
  /// either explicitly constructed (`[0]`) or explicitly not (`[2] dNSName`).
  bool get isConstructed => tag & 0x20 != 0;

  /// The children of a constructed value, empty for a primitive.
  ///
  /// Read from the start of [value], which is a copy: an offset into the
  /// original buffer means nothing here.
  List<DerNode> get children =>
      isConstructed ? _readChildren(value, 0) : const <DerNode>[];

  /// This node as it appears in a DER blob, tag and length included.
  Uint8List encode() => Der.tagged(tag, value);

  /// The contents as an INTEGER.
  BigInt get asInteger => _decodeInteger(value);

  /// The contents as a dotted object identifier.
  String get asObjectIdentifier => _decodeOid(value);

  /// The contents of a BIT STRING, minus the trailing-bits byte.
  Uint8List get asBitString =>
      value.isEmpty ? Uint8List(0) : Uint8List.fromList(value.sublist(1));

  /// Reads the structures inside a constructed value.
  static List<DerNode> read(Uint8List bytes) => _readChildren(bytes, 0);

  static List<DerNode> _readChildren(Uint8List bytes, int from) {
    final nodes = <DerNode>[];
    var offset = from;
    while (offset < bytes.length) {
      final tag = bytes[offset];
      final length = _readLength(bytes, offset + 1);
      final contentStart = offset + 1 + length.consumed;
      final end = contentStart + length.value;
      if (end > bytes.length) {
        throw FormatException('DER value runs past the end of the input');
      }
      nodes.add(
        DerNode(tag, Uint8List.fromList(Uint8List.sublistView(bytes, contentStart, end))),
      );
      offset = end;
    }
    return nodes;
  }

  /// The length field, and how many bytes it occupied.
  static ({int value, int consumed}) _readLength(Uint8List bytes, int offset) {
    if (offset >= bytes.length) {
      throw const FormatException('DER length is missing');
    }
    final first = bytes[offset];
    if (first < 0x80) return (value: first, consumed: 1);
    final count = first & 0x7f;
    if (offset + count >= bytes.length) {
      throw const FormatException('DER length runs past the end of the input');
    }
    var value = 0;
    for (var i = 0; i < count; i++) {
      value = (value << 8) | bytes[offset + 1 + i];
    }
    return (value: value, consumed: count + 1);
  }

  static BigInt _decodeInteger(Uint8List bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    if (bytes.isNotEmpty && bytes.first & 0x80 != 0) {
      result -= BigInt.one << (bytes.length * 8);
    }
    return result;
  }

  static String _decodeOid(Uint8List bytes) {
    final arcs = <int>[];
    var value = 0;
    var started = false;
    for (final byte in bytes) {
      value = (value << 7) | (byte & 0x7f);
      started = true;
      if (byte & 0x80 == 0) {
        if (arcs.isEmpty) {
          arcs.add(value ~/ 40);
          arcs.add(value % 40);
        } else {
          arcs.add(value);
        }
        value = 0;
        started = false;
      }
    }
    if (started) arcs.add(value);
    return arcs.join('.');
  }
}