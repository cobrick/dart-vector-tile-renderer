import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vector_tile_renderer/src/gpu/line/line_geometry_builder.dart';
import 'package:vector_tile_renderer/src/model/geometry_model.dart';
import 'package:vector_tile_renderer/src/themes/style.dart';

void main() {
  test(
      'a long line keeps every segment and join while its buffers grow, in '
      'order', () {
    const n = 500;
    final line = [for (var i = 0; i < n; i++) TilePoint(i * 2.0, i % 7 * 3.0)];

    final (vertexData, indexData) =
        LineGeometryBuilder().build([line], LineCap.butt, LineJoin.bevel);
    final vertices = Float32List.sublistView(vertexData);
    final indices = Uint32List.sublistView(indexData);

    // 4 vertices of 8 floats per segment, 1 per bevel join; 6 indices each.
    expect(vertices, hasLength((n - 1) * 32 + (n - 2) * 8));
    expect(indices, hasLength((n - 1) * 6 + (n - 2) * 6));
    for (final k in [0, 1, 255, n - 2]) {
      expect(vertices.sublist(k * 32, k * 32 + 4),
          [line[k + 1].x, line[k + 1].y, line[k].x, line[k].y],
          reason: 'segment $k');
      expect(indices.sublist(k * 6, k * 6 + 6),
          [4 * k, 4 * k + 1, 4 * k + 2, 4 * k + 2, 4 * k + 3, 4 * k],
          reason: 'segment $k');
    }
    const firstJoin = (n - 1) * 32;
    expect(vertices.sublist(firstJoin, firstJoin + 2), [line[1].x, line[1].y]);
  });

  test('the expected point count only sizes the buffers, too small or not', () {
    final lines = [
      for (var l = 0; l < 20; l++)
        [
          for (var i = 0; i < 40; i++)
            TilePoint(i * 3.0 + l, (i * l) % 11 * 2.0)
        ],
    ];
    Uint8List bytes(ByteData data) => Uint8List.sublistView(data);

    final (v, i) =
        LineGeometryBuilder().build(lines, LineCap.round, LineJoin.round);
    for (final hint in [0, 10, 800, 100000]) {
      final (hv, hi) = LineGeometryBuilder(expectedPoints: hint)
          .build(lines, LineCap.round, LineJoin.round);
      expect(bytes(hv), bytes(v), reason: 'hint $hint');
      expect(bytes(hi), bytes(i), reason: 'hint $hint');
    }
  });
}
