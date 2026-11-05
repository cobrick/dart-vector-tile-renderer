import 'dart:math';
import 'dart:typed_data';

import 'package:dart_earcut/dart_earcut.dart';
import 'package:test/test.dart';
import 'package:vector_tile_renderer/src/gpu/polygon/polygon_geometry_builder.dart';
import 'package:vector_tile_renderer/src/model/geometry_model.dart';

void main() {
  test(
      'polygons with holes come out byte for byte as the per-polygon builder '
      'made them, while the buffers grow', () {
    final random = Random(3216);
    TileLine ring(double cx, double cy, double r, int n) => TileLine([
          for (var i = 0; i < n; i++)
            TilePoint(
              (cx + r * cos(2 * pi * i / n) * (0.8 + 0.4 * random.nextDouble()))
                  .roundToDouble(),
              (cy + r * sin(2 * pi * i / n) * (0.8 + 0.4 * random.nextDouble()))
                  .roundToDouble(),
            ),
        ]);
    final polygons = [
      for (var p = 0; p < 300; p++)
        TilePolygon([
          ring(random.nextDouble() * 4096, random.nextDouble() * 4096, 60,
              4 + random.nextInt(40)),
          if (p % 3 == 0)
            ring(random.nextDouble() * 4096, random.nextDouble() * 4096, 15,
                3 + random.nextInt(6)),
        ]),
      TilePolygon([]),
    ];

    final (vertices, indices) = PolygonGeometryBuilder().build(polygons);
    final (expectedVertices, expectedIndices) = _perPolygonBuild(polygons);

    expect(Uint8List.sublistView(vertices),
        Uint8List.sublistView(expectedVertices));
    expect(
        Uint8List.sublistView(indices), Uint8List.sublistView(expectedIndices));
    expect(indices.lengthInBytes, greaterThan(3072 * 4),
        reason: 'the index buffer must have grown past its first size');
  });

  test('no polygons give empty buffers', () {
    final (vertices, indices) = PolygonGeometryBuilder().build([]);

    expect(vertices.lengthInBytes, 0);
    expect(indices.lengthInBytes, 0);
  });
}

/// The builder before AMPS-3216: one vertex and one index list per polygon,
/// joined through a BytesBuilder.
(ByteData, ByteData) _perPolygonBuild(List<TilePolygon> polygons) {
  final vertexBytes = BytesBuilder(copy: false);
  final indexBytes = BytesBuilder(copy: false);
  var offset = 0;
  for (final polygon in polygons) {
    final flat = <double>[];
    final holeIndices = <int>[];
    for (var i = 0; i < polygon.rings.length; i++) {
      if (i > 0) {
        holeIndices.add(flat.length ~/ 2);
      }
      for (final point in polygon.rings[i].points) {
        flat
          ..add(point.x.toDouble())
          ..add(point.y.toDouble());
      }
    }
    final triangles = Earcut.triangulateRaw(flat, holeIndices: holeIndices);
    final vertices = Float32List((flat.length * 1.5).truncate());
    var ptr = 0;
    for (var i = 0; i < flat.length; i += 2) {
      vertices[ptr] = flat[i] / 2048.0 - 1;
      vertices[ptr + 1] = 1 - flat[i + 1] / 2048.0;
      vertices[ptr + 2] = 0.0;
      ptr += 3;
    }
    final indices = Uint32List.fromList(
        triangles.map((it) => it + offset).toList(growable: false));
    offset += vertices.length ~/ 3;
    vertexBytes.add(vertices.buffer.asUint8List());
    indexBytes.add(indices.buffer.asUint8List());
  }
  return (
    ByteData.sublistView(vertexBytes.takeBytes()),
    ByteData.sublistView(indexBytes.takeBytes()),
  );
}
