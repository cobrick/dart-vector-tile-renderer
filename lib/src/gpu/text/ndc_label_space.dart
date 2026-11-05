import 'dart:math';
import 'dart:ui';

/// The space labels already occupy in a tile, in normalized device
/// coordinates, so that new labels don't overlap them.
///
/// Labels along a line try a box at many positions, so the overlap test
/// runs very often on the map's worker isolates. It allocates nothing: lists,
/// points and projections made per test were garbage whose collections pause
/// the UI thread too.
class NdcLabelSpace {
  final _spatialGrid = <int, Map<int, List<LabelSpaceBox>>>{};
  final double _gridSize;

  NdcLabelSpace({double gridSize = 0.1}) : _gridSize = gridSize;

  // Marks the boxes one query has tested. Shared by every label space, so a
  // box in several spaces is never skipped by mistake.
  static int _query = 0;

  bool tryOccupy(LabelSpaceBox box,
      {bool simulate = false, bool canExceedTileBounds = true}) {
    if (!canExceedTileBounds && doesExceedTileBounds(box)) {
      return false;
    }

    if (_overlapsAny(box)) {
      return false;
    }

    if (!simulate) {
      _addToGrid(box);
    }
    return true;
  }

  void clear() {
    _spatialGrid.clear();
  }

  Set<LabelSpaceBox> getAll() {
    return _spatialGrid.values
        .expand((row) => row.values)
        .expand((cell) => cell)
        .toSet();
  }

  /// Whether [box] overlaps a box in the grid cells its AABB spans. Boxes are
  /// tested in the order the cells hold them, each once however many cells
  /// it spans.
  bool _overlapsAny(LabelSpaceBox box) {
    final query = ++_query;
    final minGridX = (box.aabb.left / _gridSize).floor();
    final maxGridX = (box.aabb.right / _gridSize).floor();
    final minGridY = (box.aabb.top / _gridSize).floor();
    final maxGridY = (box.aabb.bottom / _gridSize).floor();

    for (int gx = minGridX; gx <= maxGridX; gx++) {
      final row = _spatialGrid[gx];
      if (row == null) {
        continue;
      }
      for (int gy = minGridY; gy <= maxGridY; gy++) {
        final cell = row[gy];
        if (cell == null) {
          continue;
        }
        for (final existing in cell) {
          if (existing._query == query) {
            continue;
          }
          existing._query = query;
          if (_boxesOverlap(existing, box)) {
            return true;
          }
        }
      }
    }
    return false;
  }

  // Add box to all grid cells its AABB spans
  void _addToGrid(LabelSpaceBox box) {
    final minGridX = (box.aabb.left / _gridSize).floor();
    final maxGridX = (box.aabb.right / _gridSize).floor();
    final minGridY = (box.aabb.top / _gridSize).floor();
    final maxGridY = (box.aabb.bottom / _gridSize).floor();

    for (int gx = minGridX; gx <= maxGridX; gx++) {
      final row = _spatialGrid[gx] ??= <int, List<LabelSpaceBox>>{};
      for (int gy = minGridY; gy <= maxGridY; gy++) {
        (row[gy] ??= <LabelSpaceBox>[]).add(box);
      }
    }
  }

  // Optimized overlap detection for oriented rectangles
  bool _boxesOverlap(LabelSpaceBox box1, LabelSpaceBox box2) {
    // First check AABB overlap for quick rejection
    if (!box1.aabb.overlaps(box2.aabb)) {
      return false;
    }

    // Separating Axis Theorem (SAT) for oriented rectangles: the boxes
    // overlap unless the normal of one of their edges separates them.
    return !_edgeNormalSeparates(box1, box1, box2) &&
        !_edgeNormalSeparates(box2, box1, box2);
  }

  /// Whether the normal of one of [edges]' edges separates [a] and [b].
  static bool _edgeNormalSeparates(
          LabelSpaceBox edges, LabelSpaceBox a, LabelSpaceBox b) =>
      _normalSeparates(edges.p1, edges.p2, a, b) ||
      _normalSeparates(edges.p2, edges.p3, a, b) ||
      _normalSeparates(edges.p3, edges.p4, a, b) ||
      _normalSeparates(edges.p4, edges.p1, a, b);

  /// Whether the normal of the edge [from]→[to] separates [a] and [b]: their
  /// projections onto it don't overlap. A zero-length edge has no normal.
  static bool _normalSeparates(
      Point<double> from, Point<double> to, LabelSpaceBox a, LabelSpaceBox b) {
    final edgeX = to.x - from.x;
    final edgeY = to.y - from.y;
    final length = sqrt(edgeX * edgeX + edgeY * edgeY);
    if (!(length > 0)) {
      return false;
    }
    final axisX = -edgeY / length;
    final axisY = edgeX / length;

    var min1 = a.p1.x * axisX + a.p1.y * axisY;
    var max1 = min1;
    var projection = a.p2.x * axisX + a.p2.y * axisY;
    if (projection < min1) min1 = projection;
    if (projection > max1) max1 = projection;
    projection = a.p3.x * axisX + a.p3.y * axisY;
    if (projection < min1) min1 = projection;
    if (projection > max1) max1 = projection;
    projection = a.p4.x * axisX + a.p4.y * axisY;
    if (projection < min1) min1 = projection;
    if (projection > max1) max1 = projection;

    var min2 = b.p1.x * axisX + b.p1.y * axisY;
    var max2 = min2;
    projection = b.p2.x * axisX + b.p2.y * axisY;
    if (projection < min2) min2 = projection;
    if (projection > max2) max2 = projection;
    projection = b.p3.x * axisX + b.p3.y * axisY;
    if (projection < min2) min2 = projection;
    if (projection > max2) max2 = projection;
    projection = b.p4.x * axisX + b.p4.y * axisY;
    if (projection < min2) min2 = projection;
    if (projection > max2) max2 = projection;

    return max1 < min2 || max2 < min1;
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

  bool doesExceedTileBounds(LabelSpaceBox box) =>
      _outsideTile(box.p1) ||
      _outsideTile(box.p2) ||
      _outsideTile(box.p3) ||
      _outsideTile(box.p4);

  static bool _outsideTile(Point<double> p) =>
      p.x < -1.0 || p.x > 1.0 || p.y < -1.0 || p.y > 1.0;
}

class LabelSpaceBox {
  final Point<double> p1;
  final Point<double> p2;
  final Point<double> p3;
  final Point<double> p4;

  final Rect aabb;

  // The last NdcLabelSpace query that tested this box.
  int _query = 0;

  List<Point<double>> get points => [p1, p2, p3, p4];

  LabelSpaceBox(this.p1, this.p2, this.p3, this.p4)
      : aabb = Rect.fromLTRB(
            min(min(min(p1.x, p2.x), p3.x), p4.x),
            min(min(min(p1.y, p2.y), p3.y), p4.y),
            max(max(max(p1.x, p2.x), p3.x), p4.x),
            max(max(max(p1.y, p2.y), p3.y), p4.y));

  static LabelSpaceBox create(
      Rect size, double rotation, Point<double> fulcrum) {
    final cosine = cos(rotation);
    final sine = sin(rotation);
    return LabelSpaceBox(
      _rotate(size.left, size.top, fulcrum, cosine, sine), // Top-left
      _rotate(size.right, size.top, fulcrum, cosine, sine), // Top-right
      _rotate(size.right, size.bottom, fulcrum, cosine, sine), // Bottom-right
      _rotate(size.left, size.bottom, fulcrum, cosine, sine), // Bottom-left
    );
  }

  static Point<double> _rotate(
      double x, double y, Point<double> fulcrum, double cosine, double sine) {
    final translatedX = x - fulcrum.x;
    final translatedY = y - fulcrum.y;

    final rotatedX = translatedX * cosine - translatedY * sine;
    final rotatedY = translatedX * sine + translatedY * cosine;

    return Point(
      rotatedX + fulcrum.x,
      rotatedY + fulcrum.y,
    );
  }
}
