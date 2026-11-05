import 'package:test/test.dart';
import 'package:vector_tile_renderer/src/gpu/map_render_pass.dart';

void main() {
  group('layerMajorOrder', () {
    test('draws every tile of a layer before the next layer', () {
      final order = layerMajorOrder([
        [0, 2, 5],
        [0, 1, 5],
      ]);

      expect(order, [(0, 0), (1, 0), (1, 1), (0, 1), (0, 2), (1, 2)]);
    });

    test('keeps the order of a tile\'s meshes within one layer', () {
      final order = layerMajorOrder([
        [3, 3, 3],
        [3],
      ]);

      expect(order, [(0, 0), (0, 1), (0, 2), (1, 0)]);
    });

    test('handles tiles that lack layers and empty tiles', () {
      final order = layerMajorOrder([
        <int>[],
        [4],
        [1, 9],
      ]);

      expect(order, [(2, 0), (1, 0), (2, 1)]);
    });

    test('returns nothing for no tiles', () {
      expect(layerMajorOrder([]), isEmpty);
    });
  });
}
