import 'dart:math';
import 'dart:ui';

import 'package:test/test.dart';
import 'package:vector_tile_renderer/src/gpu/text/ndc_label_space.dart';

import 'ndc_label_space_reference.dart';

void main() {
  test(
      'placing thousands of rotated labels gives the same answers, and the '
      'same boxes, as the label space before AMPS-3216', () {
    final random = Random(3216);
    final space = NdcLabelSpace();
    final reference = ReferenceLabelSpace();
    var placed = 0;
    for (var i = 0; i < 4000; i++) {
      final cx = random.nextDouble() * 2.4 - 1.2;
      final cy = random.nextDouble() * 2.4 - 1.2;
      final halfWidth = 0.005 + random.nextDouble() * 0.12;
      final halfHeight = 0.004 + random.nextDouble() * 0.03;
      final rect = Rect.fromLTRB(
          cx - halfWidth, cy - halfHeight, cx + halfWidth, cy + halfHeight);
      // Some labels upright, some along lines at any angle, some degenerate.
      final rotation = switch (i % 4) {
        0 => 0.0,
        1 => (random.nextDouble() - 0.5) * pi,
        2 => random.nextDouble() * 2 * pi,
        _ => i % 8 == 3 ? pi / 2 : -pi / 4,
      };
      final fulcrum = Point(cx + random.nextDouble() * 0.01, -cy);
      final simulate = i % 3 == 0;
      final canExceedTileBounds = i % 5 != 0;

      final box = LabelSpaceBox.create(rect, rotation, fulcrum);
      final referenceBox = ReferenceBox.create(rect, rotation, fulcrum);
      expect([box.p1, box.p2, box.p3, box.p4], referenceBox.points,
          reason: 'label $i corners');
      expect(box.aabb, referenceBox.aabb, reason: 'label $i bounds');

      final occupied = space.tryOccupy(box,
          simulate: simulate, canExceedTileBounds: canExceedTileBounds);
      expect(
          occupied,
          reference.tryOccupy(referenceBox,
              simulate: simulate, canExceedTileBounds: canExceedTileBounds),
          reason: 'label $i');
      if (occupied && !simulate) placed++;
    }
    expect(placed, greaterThan(100), reason: 'a dense, not an empty, space');
    expect(space.getStats(), reference.getStats());
  });

  test('a box tested in two label spaces is checked against both', () {
    final a = NdcLabelSpace();
    final b = NdcLabelSpace();
    final box = LabelSpaceBox.create(
        const Rect.fromLTRB(-0.1, -0.1, 0.1, 0.1), 0, const Point(0.0, 0.0));
    expect(a.tryOccupy(box), isTrue);
    expect(b.tryOccupy(box), isTrue);

    final overlapping = LabelSpaceBox.create(
        const Rect.fromLTRB(0.0, 0.0, 0.2, 0.2), 0.3, const Point(0.1, -0.1));
    expect(a.tryOccupy(overlapping, simulate: true), isFalse);
    expect(b.tryOccupy(overlapping, simulate: true), isFalse);
  });
}
