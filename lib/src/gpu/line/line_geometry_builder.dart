import 'dart:math';
import 'dart:typed_data';

import 'package:vector_math/vector_math.dart';

import '../../model/geometry_model.dart';
import '../../themes/style.dart';

/// Builds the vertices and indices of a line mesh.
///
/// Vertices and indices are written straight into two growing typed buffers.
/// Building them in a small list per segment, join and cap made several
/// objects per segment: garbage that, on the map's worker isolates, triggers
/// collections of the heap they share with the UI isolate.
class LineGeometryBuilder {
  /// [expectedPoints], the number of points in the lines to build, sizes the
  /// first buffers (a segment takes 32 vertex floats and 6 indices, a join
  /// a few more); they still grow when it is too small. A sparse tile has
  /// many small groups, and fixed 20 KB buffers for each were garbage too.
  LineGeometryBuilder({int? expectedPoints})
      : _vertices = Float32List(
            expectedPoints == null ? 4096 : max(64, expectedPoints * 40)),
        _indices = Uint32List(
            expectedPoints == null ? 1024 : max(16, expectedPoints * 12));

  int indexOffset = 0;
  Float32List _vertices;
  int _vertexCount = 0;
  Uint32List _indices;
  int _indexCount = 0;
  Float32List _cumulativeLengths = Float32List(0);

  int startIndex = 0;

  // Reusable Vector2 objects for setupJoinsMiter to avoid allocations
  final Vector2 _v2Temp1 = Vector2.zero();
  final Vector2 _v2Temp2 = Vector2.zero();
  final Vector2 _v2Temp3 = Vector2.zero();
  final Vector2 _v2Temp4 = Vector2.zero();

  /// Reserves [count] vertex floats and returns the index of the first.
  int _addVertices(int count) {
    final start = _vertexCount;
    final end = start + count;
    if (end > _vertices.length) {
      _vertices = Float32List(max(end, _vertices.length * 2))
        ..setRange(0, start, _vertices);
    }
    _vertexCount = end;
    return start;
  }

  /// Reserves [count] indices and returns the index of the first.
  int _addIndices(int count) {
    final start = _indexCount;
    final end = start + count;
    if (end > _indices.length) {
      _indices = Uint32List(max(end, _indices.length * 2))
        ..setRange(0, start, _indices);
    }
    _indexCount = end;
    return start;
  }

  (ByteData, ByteData) build(
      List<List<TilePoint>> lines, LineCap lineCaps, LineJoin lineJoins) {
    double totalCumulativeLength = 0.0;

    for (var line in lines) {
      startIndex = 0;

      setupLine(line, lineCaps, lineJoins, totalCumulativeLength);

      if (_cumulativeLengths.isNotEmpty) {
        totalCumulativeLength = _cumulativeLengths.last;
      }

      indexOffset += startIndex;
    }

    return (
      ByteData.sublistView(_vertices, 0, _vertexCount),
      ByteData.sublistView(_indices, 0, _indexCount),
    );
  }

  setupLine(
    List<TilePoint> points,
    LineCap lineCaps,
    LineJoin lineJoins,
    double startingCumulativeLength,
  ) {
    final segmentCount = points.length - 1;

    computeCumulativeDistances(points, segmentCount, startingCumulativeLength);
    setupSegments(points, segmentCount);
    setupEnds(points, segmentCount, lineCaps);
    setupJoins(points, lineJoins);
  }

  void setupSegments(List<TilePoint> points, int segmentCount) {
    for (int i = 0; i < segmentCount; i++) {
      TilePoint p0 = points[i];
      TilePoint p1 = points[i + 1];

      double cumulativeLength0 =
          (i < _cumulativeLengths.length ? _cumulativeLengths[i] : 0.0) / 32.0;
      double cumulativeLength1 = ((i + 1) < _cumulativeLengths.length
              ? _cumulativeLengths[i + 1]
              : 0.0) /
          32.0;

      final o = _addVertices(32);
      final vertices = _vertices;
      vertices[o + 0] = p1.x;
      vertices[o + 1] = p1.y;
      vertices[o + 2] = p0.x;
      vertices[o + 3] = p0.y;
      vertices[o + 4] = 1;
      vertices[o + 5] = 0;
      vertices[o + 6] = 0;
      vertices[o + 7] = cumulativeLength1;
      vertices[o + 8] = p0.x;
      vertices[o + 9] = p0.y;
      vertices[o + 10] = p1.x;
      vertices[o + 11] = p1.y;
      vertices[o + 12] = -1;
      vertices[o + 13] = 0;
      vertices[o + 14] = 0;
      vertices[o + 15] = cumulativeLength0;
      vertices[o + 16] = p0.x;
      vertices[o + 17] = p0.y;
      vertices[o + 18] = p1.x;
      vertices[o + 19] = p1.y;
      vertices[o + 20] = 1;
      vertices[o + 21] = 0;
      vertices[o + 22] = 0;
      vertices[o + 23] = cumulativeLength0;
      vertices[o + 24] = p1.x;
      vertices[o + 25] = p1.y;
      vertices[o + 26] = p0.x;
      vertices[o + 27] = p0.y;
      vertices[o + 28] = -1;
      vertices[o + 29] = 0;
      vertices[o + 30] = 0;
      vertices[o + 31] = cumulativeLength1;

      final base = (4 * i) + indexOffset;
      final x = _addIndices(6);
      final indices = _indices;
      indices[x + 0] = base;
      indices[x + 1] = base + 1;
      indices[x + 2] = base + 2;
      indices[x + 3] = base + 2;
      indices[x + 4] = base + 3;
      indices[x + 5] = base;
    }
    startIndex += max(segmentCount * 4, 0);
  }

  void setupEnds(List<TilePoint> points, int segmentCount, LineCap type) {
    if (type == LineCap.butt) return;
    final round = type == LineCap.round ? 1.0 : 0.0;

    TilePoint a = points[0];
    TilePoint b = points[1];
    TilePoint c = points[segmentCount - 1];
    TilePoint d = points[segmentCount];

    double startCumulativeLength =
        (_cumulativeLengths.isNotEmpty ? _cumulativeLengths.first : 0.0) / 32.0;
    double endCumulativeLength =
        (_cumulativeLengths.isNotEmpty ? _cumulativeLengths.last : 0.0) / 32.0;

    final o = _addVertices(32);
    final vertices = _vertices;
    vertices[o + 0] = a.x;
    vertices[o + 1] = a.y;
    vertices[o + 2] = b.x;
    vertices[o + 3] = b.y;
    vertices[o + 4] = -1;
    vertices[o + 5] = -1;
    vertices[o + 6] = round;
    vertices[o + 7] = startCumulativeLength;
    vertices[o + 8] = a.x;
    vertices[o + 9] = a.y;
    vertices[o + 10] = b.x;
    vertices[o + 11] = b.y;
    vertices[o + 12] = 1;
    vertices[o + 13] = -1;
    vertices[o + 14] = round;
    vertices[o + 15] = startCumulativeLength;
    vertices[o + 16] = d.x;
    vertices[o + 17] = d.y;
    vertices[o + 18] = c.x;
    vertices[o + 19] = c.y;
    vertices[o + 20] = -1;
    vertices[o + 21] = -1;
    vertices[o + 22] = round;
    vertices[o + 23] = endCumulativeLength;
    vertices[o + 24] = d.x;
    vertices[o + 25] = d.y;
    vertices[o + 26] = c.x;
    vertices[o + 27] = c.y;
    vertices[o + 28] = 1;
    vertices[o + 29] = -1;
    vertices[o + 30] = round;
    vertices[o + 31] = endCumulativeLength;

    final x = _addIndices(12);
    final indices = _indices;
    indices[x + 0] = startIndex + indexOffset;
    indices[x + 1] = startIndex + 1 + indexOffset;
    indices[x + 2] = 1 + indexOffset;
    indices[x + 3] = startIndex + 1 + indexOffset;
    indices[x + 4] = 2 + indexOffset;
    indices[x + 5] = 1 + indexOffset;
    indices[x + 6] = startIndex + 3 + indexOffset;
    indices[x + 7] = startIndex - 4 + indexOffset;
    indices[x + 8] = startIndex - 1 + indexOffset;
    indices[x + 9] = startIndex + 2 + indexOffset;
    indices[x + 10] = startIndex + 3 + indexOffset;
    indices[x + 11] = startIndex - 1 + indexOffset;
    startIndex += 4;
  }

  void setupJoins(List<TilePoint> points, LineJoin type) {
    if (type == LineJoin.bevel) {
      setupJoinsBevel(points);
    } else if (type == LineJoin.round) {
      setupJoinsRound(points);
    } else {
      setupJoinsBevel(points);
      setupJoinsMiter(points);
    }
  }

  void setupJoinsRound(List<TilePoint> points) {
    final joinCount = points.length - 2;

    for (int i = 0; i < joinCount; i++) {
      TilePoint p0 = points[i];
      TilePoint p1 = points[i + 1];

      double joinCumulativeLength = ((i + 1) < _cumulativeLengths.length
              ? _cumulativeLengths[i + 1]
              : 0.0) /
          32.0;

      final o = _addVertices(16);
      final vertices = _vertices;
      vertices[o + 0] = p1.x;
      vertices[o + 1] = p1.y;
      vertices[o + 2] = p0.x;
      vertices[o + 3] = p0.y;
      vertices[o + 4] = -1;
      vertices[o + 5] = -1;
      vertices[o + 6] = 1;
      vertices[o + 7] = joinCumulativeLength;
      vertices[o + 8] = p1.x;
      vertices[o + 9] = p1.y;
      vertices[o + 10] = p0.x;
      vertices[o + 11] = p0.y;
      vertices[o + 12] = 1;
      vertices[o + 13] = -1;
      vertices[o + 14] = 1;
      vertices[o + 15] = joinCumulativeLength;

      int offset = i * 4;

      int a = startIndex + (2 * i);
      int b = startIndex + (2 * i) + 1;
      int c = offset + 0;
      int d = offset + 3;

      final x = _addIndices(6);
      final indices = _indices;
      indices[x + 0] = c + indexOffset;
      indices[x + 1] = d + indexOffset;
      indices[x + 2] = b + indexOffset;
      indices[x + 3] = b + indexOffset;
      indices[x + 4] = d + indexOffset;
      indices[x + 5] = a + indexOffset;
    }
    startIndex += max(2 * joinCount, 0);
  }

  void setupJoinsBevel(List<TilePoint> points) {
    final joinCount = points.length - 2;

    for (int i = 0; i < joinCount; i++) {
      TilePoint p = points[i + 1];

      double joinCumulativeLength = ((i + 1) < _cumulativeLengths.length
              ? _cumulativeLengths[i + 1]
              : 0.0) /
          32.0;

      final o = _addVertices(8);
      final vertices = _vertices;
      vertices[o + 0] = p.x;
      vertices[o + 1] = p.y;
      vertices[o + 2] = 0;
      vertices[o + 3] = 0;
      vertices[o + 4] = 0;
      vertices[o + 5] = 0;
      vertices[o + 6] = 0;
      vertices[o + 7] = joinCumulativeLength;

      int offset = i * 4;

      final x = _addIndices(6);
      final indices = _indices;
      indices[x + 0] = offset + 5 + indexOffset;
      indices[x + 1] = offset + indexOffset;
      indices[x + 2] = startIndex + i + indexOffset;
      indices[x + 3] = offset + 3 + indexOffset;
      indices[x + 4] = offset + 6 + indexOffset;
      indices[x + 5] = startIndex + i + indexOffset;
    }
    startIndex += max(joinCount, 0);
  }

  void setupJoinsMiter(List<TilePoint> points) {
    final joinCount = points.length - 2;

    for (int i = 0; i < joinCount; i++) {
      // Reuse Vector2 objects instead of creating new ones
      _v2Temp1.setValues(points[i].x, points[i].y); // p0
      _v2Temp2.setValues(points[i + 2].x, points[i + 2].y); // p1
      _v2Temp3.setValues(points[i + 1].x, points[i + 1].y); // origin

      // Calculate a = perp((p0 - origin).normalized(), -1)
      _v2Temp4.setFrom(_v2Temp1); // p0
      _v2Temp4.sub(_v2Temp3); // p0 - origin
      _v2Temp4.normalize();
      // perp with flip = -1: (v.y * -1, -v.x * -1) = (-v.y, v.x)
      final aX = -_v2Temp4.y;
      final aY = _v2Temp4.x;

      // Reuse _v2Temp4 for b = perp((p1 - origin).normalized(), 1)
      _v2Temp4.setFrom(_v2Temp2); // p1
      _v2Temp4.sub(_v2Temp3); // p1 - origin
      _v2Temp4.normalize();
      // perp with flip = 1: (v.y * 1, -v.x * 1) = (v.y, -v.x)
      final bX = _v2Temp4.y;
      final bY = -_v2Temp4.x;

      // Check dot product j = a.dot(b)
      final j = aX * bX + aY * bY;
      if (j > 0.9999 || j < -0.9999) {
        startIndex -= 2;
        continue;
      }

      // a = a + origin, b = b + origin
      final finalAX = aX + _v2Temp3.x;
      final finalAY = aY + _v2Temp3.y;
      final finalBX = bX + _v2Temp3.x;
      final finalBY = bY + _v2Temp3.y;

      // c = (a + b) * 0.5
      final cX = (finalAX + finalBX) * 0.5;
      final cY = (finalAY + finalBY) * 0.5;

      // vec = c - origin
      final vecX = cX - _v2Temp3.x;
      final vecY = cY - _v2Temp3.y;

      // resultLength = (c - a).length2 / vec.length2
      final diffX = cX - finalAX;
      final diffY = cY - finalAY;
      final vecLength2 = vecX * vecX + vecY * vecY;
      final resultLength = (diffX * diffX + diffY * diffY) / vecLength2;

      // out = vec * (1 + resultLength)
      final scale = 1 + resultLength;
      final outX = vecX * scale;
      final outY = vecY * scale;

      double joinCumulativeLength = ((i + 1) < _cumulativeLengths.length
              ? _cumulativeLengths[i + 1]
              : 0.0) /
          32.0;

      final o = _addVertices(16);
      final vertices = _vertices;
      vertices[o + 0] = cX;
      vertices[o + 1] = cY;
      vertices[o + 2] = cX;
      vertices[o + 3] = cY + 1;
      vertices[o + 4] = outX;
      vertices[o + 5] = -outY;
      vertices[o + 6] = 0;
      vertices[o + 7] = joinCumulativeLength;
      vertices[o + 8] = _v2Temp3.x;
      vertices[o + 9] = _v2Temp3.y;
      vertices[o + 10] = _v2Temp3.x;
      vertices[o + 11] = _v2Temp3.y + 1;
      vertices[o + 12] = -outX;
      vertices[o + 13] = outY;
      vertices[o + 14] = 0;
      vertices[o + 15] = joinCumulativeLength;

      int offset = i * 4;

      final x = _addIndices(6);
      final indices = _indices;
      indices[x + 0] = offset + 6 + indexOffset;
      indices[x + 1] = offset + 3 + indexOffset;
      indices[x + 2] = startIndex + (2 * i) + indexOffset;
      indices[x + 3] = offset + indexOffset;
      indices[x + 4] = offset + 5 + indexOffset;
      indices[x + 5] = startIndex + (2 * i) + 1 + indexOffset;
    }
    startIndex += max(2 * joinCount, 0);
  }

  void computeCumulativeDistances(List<TilePoint> points, int segmentCount,
      double startingCumulativeLength) {
    // Reuse existing buffer if possible to avoid allocation
    if (_cumulativeLengths.length != points.length) {
      _cumulativeLengths = Float32List(points.length);
    }
    _cumulativeLengths[0] = startingCumulativeLength;

    double sum = startingCumulativeLength;
    for (int i = 1; i < points.length; i++) {
      final dx = points[i].x - points[i - 1].x;
      final dy = points[i].y - points[i - 1].y;
      final segmentLength = sqrt(dx * dx + dy * dy);
      sum += segmentLength;
      _cumulativeLengths[i] = sum;
    }
  }
}
