import 'dart:convert';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:vector_tile/vector_tile.dart';

/// Decodes a Mapbox Vector Tile into the same [VectorTile] that
/// `VectorTile.fromBytes` builds, with far less garbage.
///
/// `VectorTile.fromBytes` parses every layer into protobuf messages, growing a
/// list element by element for each feature's geometry and tags, and then
/// copies it all into [VectorTile] objects. On the map's worker isolates that
/// garbage triggers collections of the heap they share with the UI isolate,
/// and every collection pauses the UI thread too. Here geometry and tags land
/// in exact-size typed lists, nothing is decoded twice, and layers missing
/// from [layerNames] are skipped without being decoded at all.
///
/// Returns null for data it leaves to the reference decoder: malformed tiles,
/// and protobuf groups. Native only: it reads 64-bit varints into `int`.
VectorTile? decodeMvt(Uint8List bytes, {Set<String>? layerNames}) {
  try {
    return _decodeTile(_Reader(bytes, 0, bytes.length), layerNames);
  } on _Malformed {
    return null;
  } on RangeError {
    return null;
  }
}

class _Malformed implements Exception {
  const _Malformed();
}

const _malformed = _Malformed();
const _utf8 = Utf8Codec(allowMalformed: true);
final _noInts = Uint32List(0);

VectorTile _decodeTile(_Reader r, Set<String>? layerNames) {
  final layers = <VectorTileLayer>[];
  while (r.pos < r.end) {
    final (field, wire) = r.tag();
    if (field == 3 && wire == 2) {
      final layer = _decodeLayer(r.message(), layerNames);
      if (layer != null) {
        layers.add(layer);
      }
    } else {
      r.skip(wire);
    }
  }
  return VectorTile(layers: layers);
}

VectorTileLayer? _decodeLayer(_Reader layer, Set<String>? layerNames) {
  // The name first, without decoding the rest. Like protobuf, the last one
  // wins.
  var name = '';
  final scan = layer.copy();
  while (scan.pos < scan.end) {
    final (field, wire) = scan.tag();
    if (field == 1 && wire == 2) {
      name = scan.string();
    } else {
      scan.skip(wire);
    }
  }
  if (layerNames != null && !layerNames.contains(name)) {
    return null;
  }

  var extent = 4096;
  var version = 1;
  final keys = <String>[];
  final values = <VectorTileValue>[];
  final features = <_Reader>[];
  while (layer.pos < layer.end) {
    final (field, wire) = layer.tag();
    switch ((field, wire)) {
      case (2, 2):
        features.add(layer.message());
      case (3, 2):
        keys.add(layer.string());
      case (4, 2):
        values.add(_decodeValue(layer.message()));
      case (5, 0):
        extent = layer.varint() & 0xffffffff;
      case (15, 0):
        version = layer.varint() & 0xffffffff;
      default:
        layer.skip(wire);
    }
  }
  return VectorTileLayer(
    name: name,
    extent: extent,
    version: version,
    keys: keys,
    values: values,
    // Features take the layer's final extent, which may come after them.
    features: [
      for (final feature in features)
        _decodeFeature(feature, extent, keys, values),
    ],
  );
}

VectorTileFeature _decodeFeature(
    _Reader r, int extent, List<String> keys, List<VectorTileValue> values) {
  var id = Int64.ZERO;
  var type = VectorTileGeomType.UNKNOWN;
  List<int>? tags;
  List<int>? geometry;
  while (r.pos < r.end) {
    final (field, wire) = r.tag();
    switch ((field, wire)) {
      case (1, 0):
        id = Int64(r.varint());
      case (2, 2):
        tags = _concat(tags, r.packedUint32());
      case (2, 0):
        tags = _concat(tags, Uint32List(1)..[0] = r.varint());
      case (3, 0):
        // An unknown enum value is kept aside by protobuf: the type stays.
        final value = r.varint() & 0xffffffff;
        if (value < VectorTileGeomType.values.length) {
          type = VectorTileGeomType.values[value];
        }
      case (4, 2):
        geometry = _concat(geometry, r.packedUint32());
      case (4, 0):
        geometry = _concat(geometry, Uint32List(1)..[0] = r.varint());
      default:
        r.skip(wire);
    }
  }
  return VectorTileFeature(
    id: id,
    tags: tags ?? _noInts,
    type: type,
    geometryList: geometry ?? _noInts,
    extent: extent,
    keys: keys,
    values: values,
  );
}

VectorTileValue _decodeValue(_Reader r) {
  String? string;
  double? float;
  double? double_;
  int? int_;
  int? uint;
  int? sint;
  bool? bool_;
  while (r.pos < r.end) {
    final (field, wire) = r.tag();
    switch ((field, wire)) {
      case (1, 2):
        string = r.string();
      case (2, 5):
        float = r.float32();
      case (3, 1):
        double_ = r.float64();
      case (4, 0):
        int_ = r.varint();
      case (5, 0):
        uint = r.varint();
      case (6, 0):
        sint = _zigZag64(r.varint());
      case (7, 0):
        bool_ = (r.varint() & 0xffffffff) != 0;
      default:
        r.skip(wire);
    }
  }
  // The first value set, in VectorTileValue.fromRaw's order.
  if (string != null) return VectorTileValue.from(ValueType.string, string);
  if (float != null) return VectorTileValue.from(ValueType.float, float);
  if (double_ != null) return VectorTileValue.from(ValueType.double, double_);
  if (int_ != null) return VectorTileValue.from(ValueType.int, Int64(int_));
  if (uint != null) return VectorTileValue.from(ValueType.uint, Int64(uint));
  if (sint != null) return VectorTileValue.from(ValueType.sint, Int64(sint));
  if (bool_ != null) return VectorTileValue.from(ValueType.bool, bool_);
  // VectorTileValue.fromRaw throws for an empty value; so will the reference
  // decoder.
  throw _malformed;
}

/// protobuf's zigzag decoding of a 64-bit value, including its result for
/// values at or above 2^63.
int _zigZag64(int value) {
  var v = value;
  if ((v & 1) == 1) v = -v;
  return v >> 1;
}

List<int> _concat(List<int>? a, Uint32List b) {
  if (a == null) {
    return b;
  }
  return Uint32List(a.length + b.length)
    ..setRange(0, a.length, a)
    ..setRange(a.length, a.length + b.length, b);
}

/// Reads protobuf wire format from [bytes] between [pos] and [end].
class _Reader {
  _Reader(this.bytes, this.pos, this.end);

  final Uint8List bytes;
  int pos;
  final int end;

  _Reader copy() => _Reader(bytes, pos, end);

  /// The next field's number and wire type.
  (int, int) tag() {
    final key = varint() & 0xffffffff;
    final field = key >> 3;
    if (field == 0) {
      throw _malformed;
    }
    return (field, key & 7);
  }

  /// A varint of up to 10 bytes, as protobuf reads it, in a 64-bit int.
  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (pos >= end) {
        throw _malformed;
      }
      final byte = bytes[pos++];
      result |= (byte & 0x7f) << shift;
      if (byte < 0x80) {
        return result;
      }
      shift += 7;
      if (shift >= 70) {
        throw _malformed;
      }
    }
  }

  /// The length of a length-delimited field, checked against what is left.
  int _length() {
    final length = varint();
    if (length < 0 || length > end - pos) {
      throw _malformed;
    }
    return length;
  }

  /// A reader over the next length-delimited field; this one moves past it.
  _Reader message() {
    final length = _length();
    final message = _Reader(bytes, pos, pos + length);
    pos += length;
    return message;
  }

  String string() {
    final length = _length();
    final value = _utf8.decode(Uint8List.sublistView(bytes, pos, pos + length));
    pos += length;
    return value;
  }

  double float32() {
    _need(4);
    final value =
        ByteData.sublistView(bytes, pos, pos + 4).getFloat32(0, Endian.little);
    pos += 4;
    return value;
  }

  double float64() {
    _need(8);
    final value =
        ByteData.sublistView(bytes, pos, pos + 8).getFloat64(0, Endian.little);
    pos += 8;
    return value;
  }

  /// A packed repeated uint32, in a list of exactly its length.
  Uint32List packedUint32() {
    final length = _length();
    final stop = pos + length;
    if (length > 0 && bytes[stop - 1] >= 0x80) {
      throw _malformed;
    }
    var count = 0;
    for (var p = pos; p < stop; p++) {
      if (bytes[p] < 0x80) {
        count++;
      }
    }
    final values = Uint32List(count);
    for (var i = 0; i < count; i++) {
      values[i] = varint();
    }
    return values;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        varint();
      case 1:
        _need(8);
        pos += 8;
      case 2:
        // Not `pos += _length()`: that adds to pos as read before the length.
        final length = _length();
        pos += length;
      case 5:
        _need(4);
        pos += 4;
      default:
        // Groups, deprecated and unused by vector tiles, and invalid types.
        throw _malformed;
    }
  }

  void _need(int count) {
    if (count > end - pos) {
      throw _malformed;
    }
  }
}
