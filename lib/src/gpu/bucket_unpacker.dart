import '../tileset_raster.dart';
import 'background/background_geometry.dart';
import 'colored_material.dart';
import 'line/line_geometry.dart';
import 'line/line_material.dart';
import 'map_material.dart';
import 'map_render_pass.dart';
import 'polygon/polygon_geometry.dart';
import 'raster/raster_layer_builder.dart';
import 'static_uniform.dart';
import 'text/text_geometry.dart';
import 'text/text_material.dart';
import 'texture_provider.dart';
import 'tile_geometry.dart';
import 'tile_render_data.dart';

/// Turns a tile's packed meshes into GPU geometry and materials, uploading
/// the vertex data. The draws keep the packed (style layer) order.
class BucketUnpacker {
  final TextureProvider textureProvider;
  final RasterTileset rasterTileset;

  BucketUnpacker(this.textureProvider, this.rasterTileset);

  List<MapDraw> unpack(TileRenderData bucket) {
    final draws = <MapDraw>[];
    for (final packed in bucket.data) {
      if (packed.geometry.type == GeometryType.raster) {
        final draw = RasterLayerBuilder().build(packed.layer,
            packed.geometry.uniform!, packed.material.uniform!, rasterTileset);
        if (draw != null) {
          draws.add(draw);
        }
      } else {
        draws.add(MapDraw(packed.layer, _unpackGeometry(packed.geometry),
            _unpackMaterial(packed.material)));
      }
    }
    uploadStaticUniforms([
      for (final draw in draws) ...[
        ...draw.geometry.staticUniforms,
        ...draw.material.staticUniforms,
      ],
    ]);
    return draws;
  }

  MapMaterial _unpackMaterial(PackedMaterial packed) =>
      _materialConstructors[packed.type.index]!.call(packed, textureProvider);

  TileGeometry _unpackGeometry(PackedGeometry packed) =>
      _geometryConstructors[packed.type.index]!.call(packed);
}

enum GeometryType {
  line,
  polygon,
  background,
  raster,
  text;
}

enum MaterialType {
  line,
  colored,
  raster,
  text,
}

final _geometryTypeToConstructor =
    <GeometryType, TileGeometry Function(PackedGeometry)>{
  GeometryType.line: (a) => LineGeometry(a),
  GeometryType.polygon: (a) => PolygonGeometry(a),
  GeometryType.background: (a) => BackgroundGeometry(),
  GeometryType.raster: (a) => throw UnimplementedError(),
  GeometryType.text: (a) => TextGeometry(a)
};

final _geometryConstructors =
    GeometryType.values.map((v) => _geometryTypeToConstructor[v]).toList();

final _materialTypeToConstructor =
    <MaterialType, MapMaterial Function(PackedMaterial, TextureProvider)>{
  MaterialType.line: (a, b) => LineMaterial(a),
  MaterialType.colored: (a, b) => ColoredMaterial(a),
  MaterialType.raster: (a, b) => throw UnimplementedError(),
  MaterialType.text: (a, b) => TextMaterial(a, b),
};

final _materialConstructors =
    MaterialType.values.map((v) => _materialTypeToConstructor[v]).toList();
