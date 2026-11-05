import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';
import 'package:vector_tile/raw/raw_vector_tile.dart' as raw;
import 'package:vector_tile/vector_tile.dart';
import 'package:vector_tile_renderer/src/mvt_decoder.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import 'test_files.dart';
import 'test_logger.dart';

/// Expects [actual] to hold exactly what the protobuf decoder put in
/// [expected].
void expectSameTile(VectorTile actual, VectorTile expected) {
  expect(actual.layers.map((l) => l.name), expected.layers.map((l) => l.name));
  for (var i = 0; i < expected.layers.length; i++) {
    final a = actual.layers[i];
    final e = expected.layers[i];
    expect(a.extent, e.extent, reason: e.name);
    expect(a.version, e.version, reason: e.name);
    expect(a.keys, e.keys, reason: e.name);
    expect(a.values.map((v) => (v.type, v.value)),
        e.values.map((v) => (v.type, v.value)),
        reason: e.name);
    expect(a.features, hasLength(e.features.length), reason: e.name);
    for (var j = 0; j < e.features.length; j++) {
      final fa = a.features[j];
      final fe = e.features[j];
      final where = '${e.name} feature $j';
      expect(fa.id, fe.id, reason: where);
      expect(fa.type, fe.type, reason: where);
      expect(fa.tags, fe.tags, reason: where);
      expect(fa.geometryList, fe.geometryList, reason: where);
      expect(fa.extent, fe.extent, reason: where);
      expect(fa.keys, same(a.keys), reason: where);
      expect(fa.values, same(a.values), reason: where);
    }
  }
}

List<int> _varint(int value) {
  final out = <int>[];
  var v = value;
  while (true) {
    final byte = v & 0x7f;
    v = v >>> 7;
    if (v == 0) {
      out.add(byte);
      return out;
    }
    out.add(byte | 0x80);
  }
}

List<int> _field(int number, int wire, List<int> payload) =>
    [..._varint(number << 3 | wire), ...payload];

List<int> _bytesField(int number, List<int> bytes) =>
    _field(number, 2, [..._varint(bytes.length), ...bytes]);

List<int> _packed(List<int> values) => [for (final v in values) ..._varint(v)];

void main() {
  late Uint8List sample;

  setUpAll(() async {
    sample = await readTestFile('sample_tile.pbf');
  });

  test('decodes the sample tile exactly as the protobuf decoder does', () {
    expectSameTile(decodeMvt(sample)!, VectorTile.fromBytes(bytes: sample));
  });

  test('skips the layers not named, keeping the order of the others', () {
    final reference = VectorTile.fromBytes(bytes: sample);
    final names = {reference.layers[3].name, reference.layers[0].name};

    final tile = decodeMvt(sample, layerNames: names)!;

    expectSameTile(
        tile,
        VectorTile(layers: [
          for (final layer in reference.layers)
            if (names.contains(layer.name)) layer,
        ]));
    expect(VectorTileReader().read(sample, layerNames: names).layers,
        hasLength(2));
  });

  test(
      'decodes every value type, defaults and unknown fields as protobuf '
      'does', () {
    final bytes = raw.VectorTile(layers: [
      raw.VectorTile_Layer(
        name: 'values',
        version: 2,
        keys: ['s', 'f', 'd', 'i', 'u', 'z', 'b', 'both'],
        values: [
          raw.VectorTile_Value(stringValue: 'Łódź'),
          raw.VectorTile_Value(floatValue: 1.5),
          raw.VectorTile_Value(doubleValue: -2.25),
          raw.VectorTile_Value(intValue: Int64(-7)),
          raw.VectorTile_Value(
              uintValue: Int64.parseInt('18446744073709551615')),
          raw.VectorTile_Value(sintValue: Int64(-123456789012)),
          raw.VectorTile_Value(boolValue: true),
          raw.VectorTile_Value(stringValue: '', boolValue: false),
        ],
        features: [
          raw.VectorTile_Feature(
            id: Int64(42),
            tags: [0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7],
            type: raw.VectorTile_GeomType.POINT,
            geometry: [9, 50, 34],
          ),
          // No id, type, tags or geometry: protobuf's defaults.
          raw.VectorTile_Feature(),
        ],
      ),
      // No extent or version: 4096 and 1.
      raw.VectorTile_Layer(name: 'defaults'),
    ]).writeToBuffer();
    // An extension field the decoders don't know.
    final withUnknown = Uint8List.fromList([
      ...bytes,
      ..._field(99, 0, [5])
    ]);

    expectSameTile(
        decodeMvt(withUnknown)!, VectorTile.fromBytes(bytes: withUnknown));
  });

  test(
      'reads unpacked and split repeated fields, and keeps the type over an '
      'unknown enum value', () {
    final feature = [
      ..._field(1, 0, _varint(7)),
      ..._field(2, 0, _varint(0)),
      ..._field(2, 0, _varint(0)),
      ..._field(3, 0, _varint(2)),
      ..._field(3, 0, _varint(9)),
      ..._bytesField(4, _packed([9, 2, 4])),
      ..._bytesField(4, _packed([18, 0, 16, 300])),
      ..._field(50, 5, [1, 2, 3, 4]),
    ];
    final layer = [
      ..._bytesField(1, 'roads'.codeUnits),
      ..._bytesField(2, feature),
      ..._bytesField(3, 'class'.codeUnits),
      ..._bytesField(4, _bytesField(1, 'primary'.codeUnits)),
      // The extent after the features, and the name given twice.
      ..._field(5, 0, _varint(512)),
      ..._bytesField(1, 'transportation'.codeUnits),
      ..._field(15, 0, _varint(2)),
    ];
    final bytes = Uint8List.fromList(_bytesField(3, layer));

    final tile = decodeMvt(bytes)!;

    expectSameTile(tile, VectorTile.fromBytes(bytes: bytes));
    expect(tile.layers.single.name, 'transportation');
    expect(
        tile.layers.single.features.single.type, VectorTileGeomType.LINESTRING);
  });

  test('leaves malformed tiles to the reference decoder', () {
    final truncated = Uint8List.sublistView(sample, 0, sample.length - 5);
    final emptyValue = Uint8List.fromList(_bytesField(3, [
      ..._bytesField(1, 'x'.codeUnits),
      ..._bytesField(4, []),
    ]));

    expect(decodeMvt(truncated), isNull);
    expect(decodeMvt(emptyValue), isNull);
    expect(() => VectorTileReader().read(truncated), throwsA(isA<Exception>()));
  });

  test(
      'leaves singular scalars sent length-delimited to the reference '
      'decoder, which reads them its own way', () {
    Uint8List tile(
            List<int> layerExtra, List<int> featureExtra, List<int> value) =>
        Uint8List.fromList(_bytesField(3, [
          ..._bytesField(1, 'roads'.codeUnits),
          ..._bytesField(2, [
            ..._bytesField(4, _packed([9, 2, 4])),
            ...featureExtra,
          ]),
          ..._bytesField(4, value),
          ...layerExtra,
        ]));
    final value = _bytesField(1, 'x'.codeUnits);
    final extent = tile(_bytesField(5, _varint(2)), [], value);
    final version = tile(_bytesField(15, _varint(2)), [], value);
    final id = tile([], _bytesField(1, _varint(7)), value);
    final type = tile([], _bytesField(3, _varint(2)), value);
    final intValue = tile([], [], _bytesField(4, _varint(3)));
    final boolValue = tile([], [], _bytesField(7, _varint(1)));

    for (final bytes in [extent, version, id, type, intValue, boolValue]) {
      expect(decodeMvt(bytes), isNull);
      // The reader then does what the reference decoder does: the same
      // tile, or the same failure.
      VectorTile? reference;
      try {
        reference = VectorTile.fromBytes(bytes: bytes);
      } on Exception {
        reference = null;
      }
      if (reference == null) {
        expect(() => VectorTileReader().read(bytes), throwsA(isA<Exception>()));
      } else {
        expectSameTile(VectorTileReader().read(bytes), reference);
      }
    }
  });

  test('a long unpacked geometry decodes as the reference does', () {
    final feature = [
      for (var i = 0; i < 5000; i++) ..._field(4, 0, _varint(i * 7)),
      ..._bytesField(4, _packed([9, 2, 4])),
      for (var i = 0; i < 300; i++) ..._field(2, 0, _varint(i % 2)),
    ];
    final bytes = Uint8List.fromList(_bytesField(3, [
      ..._bytesField(1, 'roads'.codeUnits),
      ..._bytesField(2, feature),
      ..._bytesField(3, 'class'.codeUnits),
      ..._bytesField(4, _bytesField(1, 'primary'.codeUnits)),
    ]));

    final tile = decodeMvt(bytes)!;

    expectSameTile(tile, VectorTile.fromBytes(bytes: bytes));
    expect(tile.layers.single.features.single.geometryList, isA<Uint32List>());
  });

  test('properties are decoded as VectorTileFeature.decodeProperties does', () {
    final theme = ProvidedThemes.lightTheme(logger: testLogger);
    final reference = VectorTile.fromBytes(bytes: sample);
    final data = TileFactory(theme, testLogger)
        .createTileData(VectorTile.fromBytes(bytes: sample));

    for (final layer in data.layers) {
      final source = reference.layers.firstWhere((l) => l.name == layer.name);
      final features = source.features
          .where((f) => f.type != null && f.type != VectorTileGeomType.UNKNOWN)
          .toList();
      for (var i = 0; i < layer.features.length; i++) {
        final expected = features[i].decodeProperties().map((k, v) => MapEntry(
            k, v.value is Int64 ? (v.value as Int64).toInt() : v.value));
        expect(layer.features[i].properties, expected);
        expect(layer.features[i].properties.keys, expected.keys);
      }
    }
  });
}
