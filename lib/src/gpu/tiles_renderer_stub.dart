// Web stub: GPU tiles renderer is unavailable on web.
// Provides API-compatible no-op classes so consuming code compiles for web.

import 'dart:typed_data';
import 'dart:ui' as ui;

import '../tileset.dart';
import '../tileset_raster.dart';
import '../themes/theme.dart' show Theme;

class TileId {
  final int z;
  final int x;
  final int y;

  TileId({required this.z, required this.x, required this.y});

  @override
  String toString() => key();

  String key() => 'z=$z,x=$x,y=$y';
}

class TileUiModel {
  final TileId tileId;
  final ui.Rect position;
  final Tileset tileset;
  final RasterTileset rasterTileset;
  final Uint8List? renderData;

  TileUiModel({
    required this.tileId,
    required this.position,
    required this.tileset,
    required this.rasterTileset,
    this.renderData,
  });
}

class PreRenderInput {
  PreRenderInput._();
}

class PreRenderOutput {
  PreRenderOutput._(this.renderData);

  final Uint8List? renderData;
}

class TilesRenderer {
  Theme theme;

  TilesRenderer(this.theme);

  static Future<void> initialize = Future.value();

  static PreRenderOutput preRender(
          Theme theme, double zoom, Tileset tileset, PreRenderInput input) =>
      PreRenderOutput._(Uint8List(0));

  PreRenderInput preRenderInput(String tileID) => PreRenderInput._();

  void keepUsedAtlases(PreRenderOutput output, String tileID) {}

  Future<PreRenderInput> loadGlyphs(
          PreRenderOutput missed, String tileID) async =>
      PreRenderInput._();

  void update(
      double zoom, List<TileUiModel> models, Iterable<String> tileIDs) {}

  void render(ui.Canvas canvas, ui.Size size, double rotation) {}

  bool get needsAnotherFrame => false;

  void dispose() {}
}
