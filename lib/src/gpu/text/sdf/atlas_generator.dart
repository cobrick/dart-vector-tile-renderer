import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../../shaders.dart';
import 'atlas_provider.dart';
import 'glyph_atlas_stats.dart';
import 'glyph_readback.dart';
import 'glyph_stamp.dart';
import 'sdf_renderer.dart';
import '../../texture_provider.dart';
import 'glyph_atlas_data.dart';

/// Builds the glyph atlas for an [AtlasID], or returns `null` to withhold it.
typedef AtlasGeneratorFunction = Future<GlyphAtlas?> Function(AtlasID id);

class AtlasGenerator {
  final _loading = <AtlasID, Completer<GlyphAtlas?>>{};
  static Future<void> _generationTail = Future.value();
  static final _stats = GlyphAtlasStats();

  final AtlasProvider atlasProvider;
  final TextureProvider textureProvider;
  final AtlasGeneratorFunction? _generate;
  final Future<void> Function() _nextFrame;

  AtlasGenerator({
    required this.atlasProvider,
    required this.textureProvider,
    @visibleForTesting AtlasGeneratorFunction? generate,
    @visibleForTesting Future<void> Function()? nextFrame,
  })  : _generate = generate,
        _nextFrame = nextFrame ?? _endOfFrame;

  static Future<void> _endOfFrame() => SchedulerBinding.instance.endOfFrame;

  /// Resets the process-wide generation state between tests.
  @visibleForTesting
  static void resetForTesting() {
    _generationTail = Future.value();
    _stats.reset();
  }

  Future loadAtlas(
      {required String str,
      required String fontFamily,
      required String tileID}) async {
    final existingEntry = _loading.entries
        .firstWhereOrNull((entry) => entry.key.canBeUsedFor(str, fontFamily));

    final atlas = existingEntry != null
        ? await existingEntry.value.future
        : await _loadAtlas(AtlasID(chars: str, font: fontFamily));

    // A withheld atlas was logged where it failed. Text layout drops every
    // label of this tile that needs one of its characters, and the tile keeps
    // that label-less render data until it leaves the tile cache. The next
    // request for these characters generates the atlas again.
    if (atlas == null) {
      return;
    }
    atlasProvider.addLoaded({atlas}, tileID);
  }

  void unloadWhereNotFound(Set<String> tileIDs) {
    final stillLoaded = atlasProvider.unloadWhereNotFound(tileIDs);
    final stillLoadedIDs = stillLoaded.map((it) => it.id).toSet();
    // Keep entries whose generation is still in flight. Dropping an in-flight
    // completer here means a tile that scrolls away and back mid-generation
    // re-enqueues a duplicate SDF render + texture upload for the same atlas.
    // Completed-but-unneeded entries are still removed, and an in-flight entry
    // is cleaned up on the next call once its generation has finished.
    final toRemove = _loading.keys
        .where(
            (id) => !stillLoadedIDs.contains(id) && _loading[id]!.isCompleted)
        .toList();

    for (var id in toRemove) {
      _loading.remove(id);
    }

    final neededTextureKeys = stillLoadedIDs.map((id) => id.hashCode).toSet();
    textureProvider.unloadWhereNotFound(neededTextureKeys);
  }

  Future<GlyphAtlas?> _loadAtlas(AtlasID id) {
    var atlas = _loading[id];
    if (atlas == null) {
      atlas = Completer<GlyphAtlas?>();
      _loading[id] = atlas;
      _enqueueGeneration(id, atlas);
    }
    return atlas.future;
  }

  void _enqueueGeneration(AtlasID id, Completer<GlyphAtlas?> completer) {
    _generationTail = _generationTail.then((_) async {
      GlyphAtlas? atlas;
      try {
        atlas = await (_generate ?? _generateDefault)(id);
      } catch (error) {
        _stats.onWithheld(_describe(id), error: error);
      }
      if (atlas == null && identical(_loading[id], completer)) {
        // Let the next request generate it again instead of reusing a miss.
        _loading.remove(id);
      }
      completer.complete(atlas);

      // Keep one frame available for map gestures before starting the next atlas.
      await _nextFrame();
    }).catchError((Object error) {
      // Never let one failure stop every later atlas.
      if (!completer.isCompleted) {
        completer.complete(null);
      }
      GlyphAtlasStats.warn(() => 'Glyph atlas queue error: $error');
    });
  }

  Future<GlyphAtlas?> _generateDefault(AtlasID id) =>
      _generateBitmapAtlas(id, 24);

  Future<GlyphAtlas?> _generateBitmapAtlas(AtlasID id, int fontSize) async {
    // Tiles can pre-render before TilesRenderer.initialize has loaded the
    // shaders. Idempotent.
    await loadShaderLibrary();
    final stopwatch = Stopwatch()..start();

    final config = AtlasConfig(atlasID: id);

    final metricsExtractor =
        GlyphMetricsExtractor(fontFamily: id.font, fontSize: fontSize);
    final glyphRenderer = GlyphRenderer(fontFamily: id.font, config: config);

    final cellSize = fontSize + config.sdfPadding;

    final renderFontSize = fontSize * config.renderScale;

    final charCodes = id.chars.codeUnits;
    final metrics = <int, GlyphMetrics>{
      for (var code in charCodes)
        code: metricsExtractor.extractMetrics(code, cellSize, cellSize)
    };

    final sdfRenderer = SdfRenderer(config, cellSize * config.renderScale);

    final readback = await glyphRenderer.renderGlyphBytes(renderFontSize);
    final glyphs = readback.bytes;
    if (glyphs == null) {
      _stats.onWithheld(_describe(id), readback: readback);
      return null;
    }

    final sdfTexture = sdfRenderer.renderToSDF(glyphs);
    textureProvider.addLoaded(sdfTexture, id.hashCode);

    _stats.onBuilt(_describe(id), readback, stopwatch.elapsedMilliseconds);

    return GlyphAtlas(
      atlasID: id,
      atlasWidth: cellSize * config.gridCols,
      atlasHeight: cellSize * config.gridRows,
      cellWidth: cellSize,
      cellHeight: cellSize,
      glyphMetrics: metrics,
      fontFamily: id.font,
      fontSize: fontSize + 0.0,
      colorFormat: 'grayscale',
      sdfRadius: config.sdfRadius,
      gridCols: config.gridCols,
    );
  }

  static String _describe(AtlasID id) => '${id.font}, ${id.chars.length} chars';
}

/// Configuration for atlas generation
class AtlasConfig {
  final AtlasID atlasID;
  late final int charCount;
  late final int gridCols;
  late final int gridRows;
  late final int sdfRadius;
  final int renderScale;
  final double sdfCutoff;
  final int sdfPadding;

  AtlasConfig({
    required this.atlasID,
    this.renderScale = 2,
    this.sdfCutoff = 0.25,
    this.sdfPadding = 20,
  }) {
    charCount = atlasID.chars.length;
    sdfRadius = 8 * renderScale;
    gridCols = _getColumnCount(charCount);
    gridRows = _calculateRows(charCount, gridCols);
  }

  /// Calculate side length of smallest square with area >= [charCount] and power of 2 side lengths
  static int _getColumnCount(int charCount) {
    int exp = ((_log2(charCount) / 2) - 0.000001).ceil();
    return math.pow(2, exp) as int;
  }

  /// base 2 log function
  static double _log2(num num) => math.log(num) * _invLn2;

  /// 1 / ln(2)
  static const double _invLn2 = 1.442695040888963407359924681;

  /// Calculate number of rows needed for the given character count and columns
  static int _calculateRows(int charCount, int cols) {
    return (charCount / cols).ceil();
  }
}

/// Result of rendering a single glyph
class RenderedGlyph {
  final GlyphMetrics metrics;
  final Uint8List sdfData;
  final int sdfSize;

  const RenderedGlyph({
    required this.metrics,
    required this.sdfData,
    required this.sdfSize,
  });
}

/// Responsible for extracting glyph metrics from text
class GlyphMetricsExtractor {
  final String fontFamily;
  final int fontSize;
  final ui.TextStyle _textStyle;

  GlyphMetricsExtractor({required this.fontFamily, required this.fontSize})
      : _textStyle = ui.TextStyle(
            fontFamily: fontFamily.split("%").first,
            fontStyle: ui.FontStyle.values
                .firstWhere((it) => it.name == fontFamily.split("%").last),
            fontSize: fontSize.toDouble(),
            color: const ui.Color(0x000000FF),
            fontWeight: ui.FontWeight.normal,
            letterSpacing: fontSize.toDouble() / 16);

  GlyphMetrics extractMetrics(
      int charCode, int targetCellWidth, int targetCellHeight) {
    GlyphMetrics metrics;
    ui.Paragraph? paragraph;

    try {
      final character = String.fromCharCode(charCode);

      final paragraphBuilder = ui.ParagraphBuilder(ui.ParagraphStyle(
        textDirection: ui.TextDirection.ltr,
        fontSize: fontSize.toDouble(),
      ));

      paragraphBuilder.pushStyle(_textStyle);
      paragraphBuilder.addText(character);
      paragraph = paragraphBuilder.build();
      paragraph.layout(const ui.ParagraphConstraints(width: double.infinity));

      if (paragraph.getGlyphInfoAt(0) case final glyphInfo?) {
        final glyphBounds = glyphInfo.graphemeClusterLayoutBounds;
        final baseline = paragraph.alphabeticBaseline;

        metrics = GlyphMetrics(
          charCode: charCode,
          width: targetCellWidth,
          height: targetCellHeight,
          glyphWidth: glyphBounds.width.round(),
          glyphHeight: glyphBounds.height.round(),
          glyphTop: (baseline - glyphBounds.top).round(),
          glyphLeft:
              math.max(0, ((targetCellWidth - glyphBounds.width) / 2).round()),
          glyphAdvance: glyphBounds.width,
        );
      } else {
        metrics =
            _createFallbackMetrics(charCode, targetCellWidth, targetCellHeight);
      }
    } catch (e) {
      metrics =
          _createFallbackMetrics(charCode, targetCellWidth, targetCellHeight);
    }

    paragraph?.dispose();
    return metrics;
  }

  GlyphMetrics _createFallbackMetrics(
      int charCode, int targetCellWidth, int targetCellHeight) {
    final estimatedWidth = fontSize * 0.6;
    return GlyphMetrics(
      charCode: charCode,
      width: targetCellWidth,
      height: targetCellHeight,
      glyphWidth: estimatedWidth.round(),
      glyphHeight: fontSize,
      glyphTop: (fontSize * 0.8).round(),
      glyphLeft: ((targetCellWidth - estimatedWidth) / 2).round(),
      glyphAdvance: estimatedWidth,
    );
  }
}

/// Responsible for rendering individual glyphs and generating SDF
class GlyphRenderer {
  final String fontFamily;
  final AtlasConfig config;

  GlyphRenderer({required this.fontFamily, required this.config});

  /// Renders the glyphs and reads them back as `rawRgba`, validated against
  /// a per-render nonce (see [GlyphStamp]). The bytes are `null` when no read
  /// validated within the attempt budget.
  Future<ValidatedReadback> renderGlyphBytes(int renderFontSize) {
    return readValidated<ui.Image>(
      render: () => _render(renderFontSize),
      read: _read,
      dispose: (image) => image.dispose(),
      wait: _waitForGpu,
    );
  }

  /// A retry needs GPU time, not a UI frame, so this waits for whichever comes
  /// first: the next frame or 32 ms. `endOfFrame` alone never completes while
  /// the app is hidden.
  static Future<void> _waitForGpu() => Future.any<void>([
        SchedulerBinding.instance.endOfFrame,
        Future<void>.delayed(const Duration(milliseconds: 32)),
      ]);

  Future<StampedRender<ui.Image>> _render(int renderFontSize) async {
    final nonce = GlyphStamp.next();
    final (picture, width, height) = _record(renderFontSize, nonce);
    try {
      return StampedRender(await picture.toImage(width, height), nonce);
    } finally {
      picture.dispose();
    }
  }

  static Future<Uint8List> _read(ui.Image image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      throw StateError('toByteData returned null');
    }
    final expected = image.width * image.height * 4;
    if (data.lengthInBytes != expected) {
      throw StateError(
          'toByteData returned ${data.lengthInBytes} bytes, expected $expected');
    }
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  /// The glyph raster (white background, black glyphs), drawn inside a layer
  /// that stamps [nonce] into green and blue (see [GlyphStamp]).
  (ui.Picture, int, int) _record(int renderFontSize, int nonce) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    final cellSize =
        renderFontSize + (config.sdfPadding * config.renderScale.toDouble());

    final canvasSize =
        Offset(cellSize * config.gridCols, cellSize * config.gridRows);
    final bounds = Rect.fromPoints(Offset.zero, canvasSize);

    canvas.saveLayer(bounds, Paint()..colorFilter = GlyphStamp.filter(nonce));

    canvas.drawRect(
      bounds,
      Paint()..color = Colors.white,
    );

    final charCodes = config.atlasID.chars.codeUnits;
    for (int i = 0; i < charCodes.length; i++) {
      final charCode = charCodes[i];
      final col = i % config.gridCols;
      final row = i ~/ config.gridCols;

      final textPainter = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(charCode),
          style: TextStyle(
            fontFamily: fontFamily.split("%").first,
            fontStyle: ui.FontStyle.values
                .firstWhere((it) => it.name == fontFamily.split("%").last),
            fontSize: renderFontSize.toDouble(),
            color: Colors.black,
            fontWeight: FontWeight.w200,
          ),
        ),
        textDirection: TextDirection.ltr,
      );

      textPainter.layout();

      final paddingLeft = (cellSize - textPainter.width) / 2;
      final paddingTop = (cellSize - textPainter.height) / 2;

      textPainter.paint(
          canvas,
          Offset(
              paddingLeft + (col * cellSize), paddingTop + (row * cellSize)));
      textPainter.dispose();
    }

    canvas.restore();

    return (
      recorder.endRecording(),
      canvasSize.dx.toInt(),
      canvasSize.dy.toInt()
    );
  }
}
