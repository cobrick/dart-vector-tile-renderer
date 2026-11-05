import 'package:test/test.dart';
import 'package:vector_tile_renderer/src/gpu/static_uniform.dart';

void main() {
  for (final alignment in [16, 64, 256]) {
    test(
        'uniform blocks start aligned to $alignment, keep their std140 size '
        'apart, and leave room past the last block for GLES', () {
      // A line's geometry (8), a fill (16), a line's material (24), a
      // label's FragInfo (32) and Age (4) blocks.
      final lengths = [8, 16, 24, 32, 4, 8];

      final (:offsets, :size) = staticUniformLayout(lengths, alignment);

      for (var i = 0; i < lengths.length; i++) {
        expect(offsets[i] % alignment, 0, reason: 'block $i');
        final std140 = (lengths[i] + 15) ~/ 16 * 16;
        final next = i + 1 < lengths.length ? offsets[i + 1] : size;
        expect(offsets[i] + std140, lessThanOrEqualTo(next),
            reason: 'block $i');
      }
      // Any map shader block (32 bytes at most) read from the last offset
      // stays inside the buffer, with room to spare.
      expect(size - offsets.last, greaterThanOrEqualTo(256));
    });
  }

  test('one block still gets room for the whole shader block', () {
    final (:offsets, :size) = staticUniformLayout([4], 256);

    expect(offsets, [0]);
    expect(size, greaterThanOrEqualTo(256));
  });
}
