import 'dart:collection';

import 'geometry_decoding.dart';
import 'geometry_model.dart';
import 'tile_model.dart';

class TileData {
  final List<TileDataLayer> layers;

  TileData({required this.layers});

  Tile toTile() =>
      Tile(layers: layers.map((e) => e.toTileLayer()).toList(growable: false));
}

class TileDataLayer {
  final String name;
  final int extent;
  final List<TileDataFeature> features;

  TileDataLayer(
      {required this.name, required this.extent, required this.features});

  TileLayer toTileLayer() => TileLayer(
      name: name,
      extent: extent,
      features: features.map((e) => e.toTileFeature()).toList(growable: false));
}

class TileDataFeature {
  final TileFeatureType type;
  final Map<String, dynamic> properties;
  List<int>? _geometry;
  Iterable<TilePoint>? _points;
  Iterable<TileLine>? _lines;
  Iterable<TilePolygon>? _polygons;

  TileDataFeature(
      {required this.type,
      required this.properties,
      required List<int>? geometry,
      Iterable<TilePoint>? points,
      Iterable<TileLine>? lines,
      Iterable<TilePolygon>? polygons})
      : _geometry = geometry,
        _points = points,
        _lines = lines,
        _polygons = polygons;

  bool get hasLines => type == TileFeatureType.linestring;
  bool get hasPolygons => type == TileFeatureType.polygon;
  bool get hasPoints => type == TileFeatureType.point;

  Iterable<TilePoint> get points {
    if (type != TileFeatureType.point) {
      throw StateError('Feature does not have points');
    }
    var points = _points;
    if (points == null) {
      points = decodePoints(_geometry!);
      _geometry = null;
      _points = points;
    }
    return points;
  }

  Iterable<TileLine> get lines {
    if (type != TileFeatureType.linestring) {
      throw StateError('Feature does not have lines');
    }
    var lines = _lines;
    if (lines == null) {
      lines = decodeLineStrings(_geometry!);
      _geometry = null;
      _lines = lines;
    }
    return lines;
  }

  Iterable<TilePolygon> get polygons {
    if (type != TileFeatureType.polygon) {
      throw StateError('Feature does not have polygons');
    }
    var polygons = _polygons;
    if (polygons == null) {
      polygons = decodePolygons(_geometry!);
      _geometry = null;
      _polygons = polygons;
    }
    return polygons;
  }

  /// The feature for drawing. Its geometry is decoded when first read: a
  /// feature that no theme layer's filter selects is never decoded.
  TileFeature toTileFeature() {
    return TileFeature(
        type: type,
        properties: properties,
        points: hasPoints
            ? _DecodedOnRead(() => points.toList(growable: false))
            : null,
        lines: hasLines
            ? _DecodedOnRead(() => lines.toList(growable: false))
            : null,
        polygons: hasPolygons
            ? _DecodedOnRead(() => polygons.toList(growable: false))
            : null);
  }
}

/// A read-only list whose elements are decoded on first read.
///
/// Decoding every feature's geometry up front made a point object per
/// vertex for features no theme layer draws: garbage that, on the map's
/// worker isolates, triggers collections of the heap they share with the UI
/// isolate, each of which pauses the UI thread.
class _DecodedOnRead<T> extends ListBase<T> {
  _DecodedOnRead(this._decode);

  List<T> Function()? _decode;
  List<T>? _values;

  List<T> get _list {
    var values = _values;
    if (values == null) {
      values = _decode!();
      _values = values;
      _decode = null;
    }
    return values;
  }

  @override
  int get length => _list.length;

  @override
  set length(int newLength) => throw UnsupportedError('Read-only geometry');

  @override
  T operator [](int index) => _list[index];

  @override
  void operator []=(int index, T value) =>
      throw UnsupportedError('Read-only geometry');
}
