import 'dart:collection';
import 'dart:typed_data';

import '../color_extension.dart';
import 'line_geometry_builder.dart';
import '../tile_render_data.dart';

import '../../../vector_tile_renderer.dart';
import '../../model/geometry_model.dart';
import '../../themes/expression/expression.dart';
import '../../themes/feature_resolver.dart';
import '../../themes/paint_model.dart';
import '../../themes/style.dart';
import '../bucket_unpacker.dart';

class FeatureGroup {
  final List<List<TilePoint>> lines = [];
  int size = 0;
}

/// A polygon ring as a closed line: its points, then its first point again.
/// A view: copying every ring to close it was garbage on the map's worker
/// isolates, whose collections pause the UI thread too.
class _ClosedRing extends ListBase<TilePoint> {
  _ClosedRing(this._points) {
    if (_points.isEmpty) {
      // As `ring.points.first` threw before.
      throw StateError('No element');
    }
  }

  final List<TilePoint> _points;

  @override
  int get length => _points.length + 1;

  @override
  set length(int newLength) => throw UnsupportedError('A closed ring');

  @override
  TilePoint operator [](int index) =>
      index == _points.length ? _points[0] : _points[index];

  @override
  void operator []=(int index, TilePoint value) =>
      throw UnsupportedError('A closed ring');
}

class SceneLineBuilder {
  final TileRenderData renderData;
  final VisitorContext context;

  SceneLineBuilder(this.renderData, this.context);

  void addFeatures(Style style, Iterable<LayerFeature> features) {
    Map<PaintModel, FeatureGroup> featureGroups = {};
    for (final feature in features) {
      final result = _getLines(style, feature);
      if (result != null) {
        final (paint, lines) = result;

        if (!featureGroups.containsKey(paint)) {
          featureGroups[paint] = FeatureGroup();
        }

        var group = featureGroups[paint]!;

        group.size += lines.fold(0, (sum, line) => sum + line.length);

        group.lines.addAll(lines);
      }
    }

    featureGroups.forEach((paint, group) {
      _addMesh(
        group.lines,
        group.size,
        paint.strokeWidth!,
        features.first.layer.extent,
        paint,
        paint.strokeDashPattern,
      );
    });
  }

  (PaintModel, Iterable<List<TilePoint>>)? _getLines(
      Style style, LayerFeature feature) {
    EvaluationContext evaluationContext = EvaluationContext(
        () => feature.feature.properties, TileFeatureType.none, context.logger,
        zoom: context.zoom, zoomScaleFactor: 1.0, hasImage: (_) => false);

    final paint = style.linePaint?.evaluate(evaluationContext);

    if (paint != null && paint.strokeWidth != null && paint.strokeWidth! > 0) {
      if (feature.feature.modelLines.isNotEmpty) {
        return (paint, feature.feature.modelLines.map((it) => it.points));
      } else if (feature.feature.modelPolygons.isNotEmpty) {
        final outlines = <List<TilePoint>>[
          for (final polygon in feature.feature.modelPolygons)
            for (final ring in polygon.rings) _ClosedRing(ring.points),
        ];

        return (paint, outlines);
      }
    }
    return null;
  }

  void _addMesh(List<List<TilePoint>> lines, int points, double lineWidth,
      int extent, PaintModel paint, List<double>? dashLengths) {
    final (vertices, indices) =
        LineGeometryBuilder(expectedPoints: points).build(
      lines,
      paint.lineCap ?? LineCap.DEFAULT,
      paint.lineJoin ?? LineJoin.DEFAULT,
    );

    final ByteData geomUniform = Float32List.fromList([
      lineWidth / 128,
      extent / 2,
    ]).buffer.asByteData();

    final color = paint.color.vector4;

    final ByteData materialUniform = Float32List.fromList([
      color.x,
      color.y,
      color.z,
      color.w,
      dashLengths?[0] ?? 64.0,
      dashLengths?[1] ?? 0.0,
    ]).buffer.asByteData();

    renderData.addMesh(PackedMesh(
        PackedGeometry(
            vertices: vertices,
            indices: indices,
            uniform: geomUniform,
            type: GeometryType.line),
        PackedMaterial(uniform: materialUniform, type: MaterialType.line)));
  }
}
