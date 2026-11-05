import 'dart:ui';

import '../../../vector_tile_renderer.dart';
import '../../themes/expression/expression.dart';
import '../../themes/feature_resolver.dart';
import '../../themes/style.dart';
import 'sdf/glyph_atlas_data.dart';

/// The characters the labels of [tileset] need at [zoom], per font. Fonts
/// are keyed like the glyph atlases: `<family>%<style>`.
///
/// Pure Dart, so it runs on the worker isolate that lays the tile out.
Map<String, Set<int>> collectGlyphs(Theme theme, Tileset tileset, double zoom) {
  final collector = _GlyphCollector();
  final context = VisitorContext(
      logger: const Logger.noop(),
      tileSource: TileSource(
          tileset: tileset, rasterTileset: const RasterTileset(tiles: {})),
      zoom: zoom,
      pixelRatio: 1.0);
  for (final layer in theme.layers) {
    layer.accept(context, collector);
  }
  return collector.fontToCharCodes;
}

class _GlyphCollector extends LayerVisitor {
  final fontToCharCodes = <String, Set<int>>{};

  @override
  void visitFeatures(VisitorContext context, ThemeLayerType layerType,
      Style style, Iterable<LayerFeature> features) {
    final symbolLayout = style.symbolLayout;
    if (symbolLayout == null || layerType != ThemeLayerType.symbol) {
      return;
    }
    for (final feature in features) {
      final evaluationContext = EvaluationContext(
          () => feature.feature.properties,
          TileFeatureType.none,
          context.logger,
          zoom: context.zoom,
          zoomScaleFactor: 1.0,
          hasImage: (_) => false);

      final text = symbolLayout.text?.text.evaluate(evaluationContext);
      if (text == null || text.isEmpty) {
        continue;
      }
      final fontFamily = symbolLayout.text?.fontFamily ?? AtlasID.defaultFont;
      final fontStyle = symbolLayout.text?.fontStyle ?? FontStyle.normal;

      fontToCharCodes
          .putIfAbsent("$fontFamily%${fontStyle.name}", () => <int>{})
          .addAll(text.codeUnits);
    }
  }
}
