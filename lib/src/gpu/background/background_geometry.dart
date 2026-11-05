import 'dart:typed_data';

import '../shaders.dart';
import '../tile_geometry.dart';

/// The tile's background: a quad slightly larger than the tile's square.
///
/// The fill shader clips every tile to its own square per pixel, and a pixel
/// on a shared edge belongs to one tile only. Like the tile's other
/// geometry, the background reaches past the edge, so that tile covers the
/// whole edge pixel, all of its MSAA samples; a quad ending exactly at the
/// edge would leave the neighbour's half of the pixel empty.
class BackgroundGeometry extends TileGeometry {
  static const _r = 1.01;
  static final _vertices = ByteData.sublistView(Float32List.fromList([
    -_r, -_r, 0, // maintain formatting
    _r, -_r, 0,
    _r, _r, 0,
    -_r, _r, 0,
  ]));

  static final _indices = ByteData.sublistView(Uint16List.fromList([
    0, 2, 1, // maintain formatting
    2, 0, 3,
  ]));

  BackgroundGeometry() {
    setVertexShader(shaderLibrary["SimpleVertex"]!);

    uploadVertexData(_vertices, 4, _indices);
  }
}
