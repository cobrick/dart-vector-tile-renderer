import 'dart:typed_data';

import '../../../vector_tile_renderer.dart';
import '../map_render_pass.dart';
import 'raster_geometry.dart';
import 'raster_material.dart';

class RasterLayerBuilder {
  /// The draw for one raster layer of a tile, or null when the tile has no
  /// texture for it.
  MapDraw? build(int layer, ByteData packedTileKey, ByteData packedPaintModel,
      RasterTileset rasterTileset) {
    final bytes = Uint8List.fromList(packedTileKey.buffer.asUint8List(
      packedTileKey.offsetInBytes,
      packedTileKey.lengthInBytes,
    ));
    final uint16View = bytes.buffer.asUint16List();
    final tileKey = String.fromCharCodes(uint16View);
    final rasterTile = rasterTileset.tiles[tileKey];

    final opacity = packedPaintModel.getFloat64(0, Endian.little);
    final resampling = packedPaintModel.getFloat64(8, Endian.little);

    final texture = rasterTile?.texture;
    if (rasterTile == null || texture == null) {
      return null;
    }
    return MapDraw(
      layer,
      RasterGeometry(rasterTile),
      RasterMaterial(
        colorTexture: texture,
        resampling: resampling,
        opacity: opacity,
      ),
    );
  }
}
