import 'dart:math';
import 'dart:typed_data';

import 'package:dart_earcut/dart_earcut.dart';

import '../../model/geometry_model.dart';

/// Triangulates polygons into one vertex buffer (x, y, z per vertex, in the
/// tile's clip space) and one index buffer.
///
/// Vertices and indices go straight into growing typed buffers, and one list
/// of ring coordinates serves every polygon. A vertex list, an index list
/// and their copies per polygon, joined through a `BytesBuilder`, were
/// garbage on the map's worker isolates, whose collections pause the UI
/// thread too.
class PolygonGeometryBuilder {
  /// [expectedPoints], the number of ring points in the polygons to build,
  /// sizes the first buffers (3 floats per point; about one triangle per
  /// point); they still grow when it is too small.
  PolygonGeometryBuilder({int? expectedPoints})
      : _vertices = Float32List(
            expectedPoints == null ? 3072 : max(16, expectedPoints * 3)),
        _indices = Uint32List(
            expectedPoints == null ? 3072 : max(16, expectedPoints * 3));

  Float32List _vertices;
  int _vertexFloats = 0;
  Uint32List _indices;
  int _indexCount = 0;
  final _flat = <double>[];
  final _holeIndices = <int>[];

  (ByteData, ByteData) build(List<TilePolygon> polygons) {
    var offset = 0;
    for (final polygon in polygons) {
      offset += _triangulate(polygon, offset);
    }
    return (
      ByteData.sublistView(_vertices, 0, _vertexFloats),
      ByteData.sublistView(_indices, 0, _indexCount),
    );
  }

  /// Adds [polygon]'s vertices, and its triangles with indices shifted by
  /// [offset]. Returns its vertex count.
  int _triangulate(TilePolygon polygon, int offset) {
    final flat = _flat..clear();
    final holeIndices = _holeIndices..clear();
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

    final vertexCount = flat.length ~/ 2;
    var v = _addVertexFloats(vertexCount * 3);
    final vertices = _vertices;
    for (var i = 0; i < flat.length; i += 2) {
      vertices[v] = flat[i] / 2048.0 - 1;
      vertices[v + 1] = 1 - flat[i + 1] / 2048.0;
      vertices[v + 2] = 0.0;
      v += 3;
    }

    var k = _addIndices(triangles.length);
    final indices = _indices;
    for (final index in triangles) {
      indices[k++] = index + offset;
    }
    return vertexCount;
  }

  /// Reserves [count] floats of vertex data and returns the first's index.
  int _addVertexFloats(int count) {
    final start = _vertexFloats;
    final end = start + count;
    if (end > _vertices.length) {
      _vertices = Float32List(max(end, _vertices.length * 2))
        ..setRange(0, start, _vertices);
    }
    _vertexFloats = end;
    return start;
  }

  /// Reserves [count] indices and returns the first's index.
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
}
