import 'package:fixnum/fixnum.dart';
import 'package:vector_tile/vector_tile.dart';

import '../extensions.dart';
import '../logger.dart';
import '../themes/expression/expression.dart';
import '../themes/theme.dart';
import '../themes/theme_layers.dart';
import 'tile_data_model.dart';
import 'tile_model.dart';

class TileFactory {
  final Logger logger;
  final Theme theme;
  late final Set<String> propertyNames;
  late final Set<String> layerNames;
  TileFactory(this.theme, this.logger) {
    final layers =
        theme.layers.whereType<DefaultLayer>().toList(growable: false);
    propertyNames = layers.map((e) => e.propertyNames()).flatSet();
    layerNames =
        layers.map((e) => e.selector.layerSelector.layerNames()).flatSet();
  }

  /// The source layers that a theme layer can draw at [zoom]: those of every
  /// layer whose zoom range holds `zoom.truncate()`, as its selector checks
  /// it when the tile is laid out. Decoding only these gives the same render
  /// data at [zoom]; a labels theme, for one, skips the roads below zoom 15.
  Set<String> layerNamesAt(double zoom) {
    final z = zoom.truncate();
    return {
      for (final layer in theme.layers.whereType<DefaultLayer>())
        if (_mayDraw(layer, z)) ...layer.selector.layerSelector.layerNames(),
    };
  }

  // The selector's widest range, so a layer it may draw is never skipped.
  static bool _mayDraw(DefaultLayer layer, int zoom) {
    final selector = layer.selector.layerSelector;
    final min = selector.minZoom();
    final max = selector.maxZoom();
    return (min == null || zoom >= min) && (max == null || zoom <= max);
  }

  TileData createTileData(VectorTile tile) {
    return TileData(
        layers: tile.layers
            .where((layer) => layerNames.contains(layer.name))
            .map(_vectorLayerToTileDataLayer)
            .whereType<TileDataLayer>()
            .toList(growable: false));
  }

  Tile create(VectorTile tile) {
    return createTileData(tile).toTile();
  }

  TileDataLayer? _vectorLayerToTileDataLayer(VectorTileLayer vectorLayer) {
    return TileDataLayer(
        name: vectorLayer.name,
        extent: vectorLayer.extent,
        features: vectorLayer.features
            .map(_vectorFeatureToTileDataFeature)
            .whereType<TileDataFeature>()
            .toList(growable: false));
  }

  TileDataFeature? _vectorFeatureToTileDataFeature(
      VectorTileFeature vectorFeature) {
    final type = vectorFeature.type;
    if (type == null || type == VectorTileGeomType.UNKNOWN) {
      return null;
    }
    if (type == VectorTileGeomType.POINT) {
      return TileDataFeature(
          type: TileFeatureType.point,
          properties: _decodeProperties(vectorFeature),
          geometry: vectorFeature.geometryList!);
    } else if (type == VectorTileGeomType.LINESTRING) {
      return TileDataFeature(
          type: TileFeatureType.linestring,
          properties: _decodeProperties(vectorFeature),
          geometry: vectorFeature.geometryList!);
    } else if (type == VectorTileGeomType.POLYGON) {
      return TileDataFeature(
          type: TileFeatureType.polygon,
          properties: _decodeProperties(vectorFeature),
          geometry: vectorFeature.geometryList!);
    }
    return null;
  }

  /// The feature's properties, decoded straight from its tags into one map.
  /// It equals `feature.decodeProperties()` with converted values (same
  /// entries, same order, the same errors for broken tags) without building
  /// and caching an intermediate map per feature.
  Map<String, dynamic> _decodeProperties(VectorTileFeature feature) {
    final tags = feature.tags;
    final keys = feature.keys!;
    final values = feature.values!;
    final properties = <String, dynamic>{};
    for (var i = 0; i < tags.length; i += 2) {
      properties[keys[tags[i]]] = _convertValue(values[tags[i + 1]]);
    }
    return properties;
  }

  _convertValue(VectorTileValue value) {
    final v = value.value;
    if (v is Int64) {
      return v.toInt();
    }
    return v;
  }
}

extension _DefaultLayerExtension on DefaultLayer {
  Set<String> propertyNames() {
    final names = <String>{};
    names.addAll(selector.layerSelector.propertyNames());
    names.addProperties(style.fillPaint);
    names.addProperties(style.linePaint);
    names.addProperties(style.outlinePaint);
    names.addProperties(style.textPaint);
    names.addProperties(style.symbolLayout?.text?.text);
    names.addProperties(style.symbolLayout?.text?.anchor);
    names.addProperties(style.symbolLayout?.text?.justify);
    names.addProperties(style.symbolLayout?.text?.maxWidth);
    names.addProperties(style.symbolLayout?.text?.textLetterSpacing);
    names.addProperties(style.symbolLayout?.text?.textSize);
    names.addProperties(style.symbolLayout?.icon?.icon);
    names.addProperties(style.symbolLayout?.icon?.anchor);
    names.addProperties(style.symbolLayout?.icon?.opacity);
    return names.whereType<String>().toSet();
  }
}

extension _StringSet on Set<String> {
  void addProperties(Expression? expression) {
    if (expression != null) {
      addAll(expression.properties());
    }
  }
}
