// The label space before AMPS-3216, verbatim except for the class names:
// the reference that ndc_label_space_test.dart compares against.
// ignore_for_file: prefer_final_locals, unnecessary_this
import 'dart:math';
import 'dart:ui';

class ReferenceLabelSpace {
  final _spatialGrid = <int, Map<int, List<ReferenceBox>>>{};
  final double _gridSize;

  ReferenceLabelSpace({double gridSize = 0.1}) : _gridSize = gridSize;

  bool tryOccupy(ReferenceBox box,
      {bool simulate = false, bool canExceedTileBounds = true}) {
    if (!canExceedTileBounds && doesExceedTileBounds(box)) {
      return false;
    }

    final candidateBoxes = _getCandidateBoxes(box);

    for (final existing in candidateBoxes) {
      if (_boxesOverlap(existing, box)) {
        return false;
      }
    }

    if (!simulate) {
      _addToGrid(box);
    }
    return true;
  }

  void clear() {
    _spatialGrid.clear();
  }

  Set<ReferenceBox> getAll() {
    return _spatialGrid.values
        .expand((row) => row.values)
        .expand((cell) => cell)
        .toSet();
  }

  // Get candidate boxes that might overlap based on AABB
  List<ReferenceBox> _getCandidateBoxes(ReferenceBox box) {
    final candidates = <ReferenceBox>{};

    // Get grid cells that the AABB spans
    final minGridX = (box.aabb.left / _gridSize).floor();
    final maxGridX = (box.aabb.right / _gridSize).floor();
    final minGridY = (box.aabb.top / _gridSize).floor();
    final maxGridY = (box.aabb.bottom / _gridSize).floor();

    for (int gx = minGridX; gx <= maxGridX; gx++) {
      for (int gy = minGridY; gy <= maxGridY; gy++) {
        final cellBoxes = _spatialGrid[gx]?[gy];
        if (cellBoxes != null) {
          candidates.addAll(cellBoxes);
        }
      }
    }

    return candidates.toList();
  }

  // Add box to all grid cells its AABB spans
  void _addToGrid(ReferenceBox box) {
    final minGridX = (box.aabb.left / _gridSize).floor();
    final maxGridX = (box.aabb.right / _gridSize).floor();
    final minGridY = (box.aabb.top / _gridSize).floor();
    final maxGridY = (box.aabb.bottom / _gridSize).floor();

    for (int gx = minGridX; gx <= maxGridX; gx++) {
      for (int gy = minGridY; gy <= maxGridY; gy++) {
        _spatialGrid.putIfAbsent(gx, () => <int, List<ReferenceBox>>{});
        _spatialGrid[gx]!.putIfAbsent(gy, () => <ReferenceBox>[]);
        _spatialGrid[gx]![gy]!.add(box);
      }
    }
  }

  // Optimized overlap detection for oriented rectangles
  bool _boxesOverlap(ReferenceBox box1, ReferenceBox box2) {
    // First check AABB overlap for quick rejection
    if (!box1.aabb.overlaps(box2.aabb)) {
      return false;
    }

    // Use Separating Axis Theorem (SAT) for oriented rectangle overlap
    return _satOverlap(box1, box2);
  }

  // Separating Axis Theorem implementation
  bool _satOverlap(ReferenceBox box1, ReferenceBox box2) {
    final axes = <Point<double>>[];

    // Get the edges (axes) of both boxes
    axes.addAll(_getAxes(box1));
    axes.addAll(_getAxes(box2));

    // Test each axis
    for (final axis in axes) {
      final proj1 = _projectBox(box1, axis);
      final proj2 = _projectBox(box2, axis);

      // Check if projections overlap
      if (proj1.max < proj2.min || proj2.max < proj1.min) {
        return false; // Separating axis found
      }
    }

    return true; // No separating axis found, boxes overlap
  }

  // Get the axes (normals to edges) of a box
  List<Point<double>> _getAxes(ReferenceBox box) {
    final axes = <Point<double>>[];
    final points = [box.p1, box.p2, box.p3, box.p4, box.p1]; // Close the loop

    for (int i = 0; i < 4; i++) {
      final edge =
          Point(points[i + 1].x - points[i].x, points[i + 1].y - points[i].y);
      final length = sqrt(edge.x * edge.x + edge.y * edge.y);

      if (length > 0) {
        // Normal to edge (perpendicular)
        axes.add(Point(-edge.y / length, edge.x / length));
      }
    }

    return axes;
  }

  // Project a box onto an axis
  _ReferenceProjection _projectBox(ReferenceBox box, Point<double> axis) {
    final points = [box.p1, box.p2, box.p3, box.p4];

    double min = _dotProduct(points[0], axis);
    double max = min;

    for (int i = 1; i < points.length; i++) {
      final projection = _dotProduct(points[i], axis);
      if (projection < min) min = projection;
      if (projection > max) max = projection;
    }

    return _ReferenceProjection(min, max);
  }

  double _dotProduct(Point<double> a, Point<double> b) {
    return a.x * b.x + a.y * b.y;
  }

  // Debug method to get statistics
  Map<String, dynamic> getStats() {
    int totalBoxes = 0;
    int filledCells = 0;

    for (final row in _spatialGrid.values) {
      for (final cell in row.values) {
        if (cell.isNotEmpty) {
          filledCells++;
          totalBoxes += cell.length;
        }
      }
    }

    return {
      'totalBoxes': totalBoxes,
      'filledCells': filledCells,
      'gridSize': _gridSize,
    };
  }

  bool doesExceedTileBounds(ReferenceBox box) =>
      box.points.any((p) => p.x < -1.0 || p.x > 1.0 || p.y < -1.0 || p.y > 1.0);
}

class _ReferenceProjection {
  final double min;
  final double max;

  const _ReferenceProjection(this.min, this.max);
}

class ReferenceBox {
  final Point<double> p1;
  final Point<double> p2;
  final Point<double> p3;
  final Point<double> p4;

  late final Rect aabb;

  List<Point<double>> get points => [p1, p2, p3, p4];

  ReferenceBox(this.p1, this.p2, this.p3, this.p4) {
    final points = [p1, p2, p3, p4];

    final xs = points.map((p) => p.x);
    final ys = points.map((p) => p.y);

    aabb = Rect.fromLTRB(
        xs.reduce(min), ys.reduce(min), xs.reduce(max), ys.reduce(max));
  }

  static ReferenceBox create(
      Rect size, double rotation, Point<double> fulcrum) {
    final corners = [
      Point(size.left, size.top), // Top-left
      Point(size.right, size.top), // Top-right
      Point(size.right, size.bottom), // Bottom-right
      Point(size.left, size.bottom), // Bottom-left
    ];

    final rotatedCorners = corners.map((corner) {
      return _rotatePointAroundFulcrum(corner, fulcrum, rotation);
    }).toList();

    return ReferenceBox(
      rotatedCorners[0],
      rotatedCorners[1],
      rotatedCorners[2],
      rotatedCorners[3],
    );
  }

  static Point<double> _rotatePointAroundFulcrum(
      Point<double> point, Point<double> fulcrum, double rotation) {
    final cosine = cos(rotation);
    final sine = sin(rotation);

    final translatedX = point.x - fulcrum.x;
    final translatedY = point.y - fulcrum.y;

    final rotatedX = translatedX * cosine - translatedY * sine;
    final rotatedY = translatedX * sine + translatedY * cosine;

    return Point(
      rotatedX + fulcrum.x,
      rotatedY + fulcrum.y,
    );
  }
}
