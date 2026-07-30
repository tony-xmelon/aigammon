/// A hand-rolled, minimal protobuf wire codec — exactly as much as
/// `google.firestore.v1.Firestore/Listen` needs, and not one field more.
///
/// ## Why hand-rolled rather than generated
///
/// Firestore's real-time `Listen` RPC is gRPC-only (there is no REST equivalent
/// — `:runQuery` is a one-shot), so `firestore_listen.dart` speaks protobuf.
/// Generating `google/firestore/v1/*.pbgrpc.dart` would drag `protoc` plus
/// `protoc_plugin` into the build of a project whose whole online design is "no
/// toolchain, no server, pure Dart, testable headless on Windows" — CI would
/// have to install a native compiler to build a chat channel. The Listen surface
/// we actually use is small (two request messages and four response messages),
/// its field numbers are frozen by protobuf's own compatibility contract, and
/// the wire format is a hundred lines. So we encode it by hand and keep
/// `package:grpc` for nothing but HTTP/2 framing, TLS and metadata — see
/// [ClientMethod] in `firestore_listen.dart`, whose serialiser is the identity
/// function over these bytes.
///
/// Everything here is deliberately generic (no Firestore vocabulary): the
/// message shapes live in `firestore_listen.dart`, next to the field numbers they
/// belong to.
library;

import 'dart:convert';
import 'dart:typed_data';

/// The protobuf wire types, as they appear in the low 3 bits of a tag.
abstract final class ProtoWire {
  static const int varint = 0;
  static const int fixed64 = 1;
  static const int lengthDelimited = 2;
  static const int fixed32 = 5;
}

/// Builds a protobuf message body, field by field.
///
/// Nested messages are built with their own [ProtoWriter] and attached with
/// [message], which is what keeps the encoders in `firestore_listen.dart`
/// readable as a transcript of the `.proto`.
class ProtoWriter {
  final BytesBuilder _out = BytesBuilder(copy: false);

  /// The encoded message body (no length prefix — [message] adds that).
  Uint8List toBytes() => _out.toBytes();

  /// A varint-encoded `int32`/`int64`/`enum` field.
  ///
  /// Negative values encode as the full ten-byte two's complement protobuf
  /// requires, because [_varint] shifts UNSIGNED. That is not hypothetical: the
  /// events target's cursor is `seq > -1` for the whole log.
  void integer(int field, int value) {
    _tag(field, ProtoWire.varint);
    _varint(value);
  }

  /// A `bool` field.
  void boolean(int field, bool value) {
    _tag(field, ProtoWire.varint);
    _varint(value ? 1 : 0);
  }

  /// A `bytes` field.
  void bytes(int field, List<int> value) {
    _tag(field, ProtoWire.lengthDelimited);
    _varint(value.length);
    _out.add(value);
  }

  /// A `string` field (UTF-8).
  void string(int field, String value) => bytes(field, utf8.encode(value));

  /// A nested message field.
  void message(int field, ProtoWriter value) => bytes(field, value.toBytes());

  /// A `double` field (fixed64, little-endian IEEE-754).
  void float(int field, double value) {
    _tag(field, ProtoWire.fixed64);
    final scratch = ByteData(8)..setFloat64(0, value, Endian.little);
    _out.add(scratch.buffer.asUint8List());
  }

  void _tag(int field, int wire) => _varint((field << 3) | wire);

  void _varint(int value) {
    var rest = value;
    while (true) {
      final byte = rest & 0x7f;
      rest = rest >>> 7;
      if (rest == 0) {
        _out.addByte(byte);
        return;
      }
      _out.addByte(byte | 0x80);
    }
  }
}

/// Reads a protobuf message body as a flat tag-then-value stream.
///
/// Usage is always the same shape: loop while [hasNext], [readTag], switch on
/// `tag >> 3`, and [skip] `tag & 7` in the default branch — which is what makes
/// the decoders forward-compatible with fields Firestore adds later.
class ProtoReader {
  ProtoReader(this._bytes, [int start = 0, int? end])
      : _pos = start,
        _end = end ?? _bytes.length;

  final Uint8List _bytes;
  int _pos;
  final int _end;

  /// True while unread bytes remain in THIS message (not the whole buffer).
  bool get hasNext => _pos < _end;

  /// The next field tag: `(fieldNumber << 3) | wireType`.
  int readTag() => readVarint();

  /// A varint. Ten-byte (negative) encodings round-trip, since Dart's `int` is
  /// itself 64-bit two's complement.
  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (_pos >= _end) {
        throw const FormatException('truncated protobuf varint');
      }
      final byte = _bytes[_pos++];
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
      if (shift > 63) {
        throw const FormatException('protobuf varint longer than 64 bits');
      }
    }
  }

  /// A length-delimited field's payload, as a VIEW over the same buffer.
  Uint8List readBytes() {
    final length = readVarint();
    _require(length);
    final view = Uint8List.sublistView(_bytes, _pos, _pos + length);
    _pos += length;
    return view;
  }

  /// A length-delimited field decoded as UTF-8.
  String readString() => utf8.decode(readBytes());

  /// A nested message, as a reader bounded to that message's bytes.
  ProtoReader readMessage() {
    final length = readVarint();
    _require(length);
    final sub = ProtoReader(_bytes, _pos, _pos + length);
    _pos += length;
    return sub;
  }

  /// A fixed64 field read as an IEEE-754 double.
  double readDouble() {
    _require(8);
    final value =
        ByteData.sublistView(_bytes, _pos, _pos + 8).getFloat64(0, Endian.little);
    _pos += 8;
    return value;
  }

  /// A `repeated` numeric field, accepting BOTH encodings: proto3 packs by
  /// default (length-delimited), but a peer may legally send one varint per
  /// occurrence, and Firestore's own `target_ids` has been seen both ways.
  void readIntegers(int wireType, List<int> into) {
    if (wireType == ProtoWire.lengthDelimited) {
      final packed = readMessage();
      while (packed.hasNext) {
        into.add(packed.readVarint());
      }
    } else {
      into.add(readVarint());
    }
  }

  /// Discard the value of a field we do not model.
  void skip(int wireType) {
    switch (wireType) {
      case ProtoWire.varint:
        readVarint();
      case ProtoWire.fixed64:
        _advance(8);
      case ProtoWire.lengthDelimited:
        _advance(readVarint());
      case ProtoWire.fixed32:
        _advance(4);
      default:
        throw FormatException('unsupported protobuf wire type $wireType');
    }
  }

  void _advance(int count) {
    _require(count);
    _pos += count;
  }

  void _require(int count) {
    if (count < 0 || _pos + count > _end) {
      throw const FormatException('truncated protobuf field');
    }
  }
}
