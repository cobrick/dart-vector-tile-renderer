import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math' as math;
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

/// How many glyphs are measured or recorded before yielding to the event
/// loop, so building a large atlas doesn't block the UI thread in one piece.
const glyphsPerSlice = 32;

class AtlasGenerator {
  final _loading = <AtlasID, Completer<GlyphAtlas?>>{};
  static Future<void> _generationTail = Future.value();
  static final _stats = GlyphAtlasStats();

  /// The most characters a union atlas grows to: a 16×16 grid. Past it, a
  /// font uses per-tile atlases holding only the requested characters, for
  /// the rest of the generator's life.
  static const maxAtlasChars = 256;

  /// A font's union starts including the base set once the font has needed
  /// this many distinct characters. The main label font gets there on its
  /// first tile; fonts that serve one small layer (motorway refs, water
  /// names) keep small atlases instead of ~7 MB ones.
  static const defaultBaseSeedThreshold = 32;

  /// The base set of a font's union: ASCII, Latin-1 letters, common
  /// punctuation and the Central European letters of Latin Extended-A
  /// (Polish, Czech, Slovak, Hungarian). Danish and German are covered by
  /// Latin-1. 214 characters.
  static final String defaultBaseChars = String.fromCharCodes(<int>[
    for (var c = 0x20; c <= 0x7E; c++) c,
    for (var c = 0xC0; c <= 0xFF; c++)
      if (c != 0xD7 && c != 0xF7) c,
    ...'\u00A0«»·°–—‘’“”„…'.codeUnits,
    ...'ĄąĆćČčĎďĘęĚěĹĺĽľŁłŃńŇňŐőŔŕŘřŚśŠšŤťŮůŰűŹźŻżŽž'.codeUnits,
  ]);

  final AtlasProvider atlasProvider;
  final TextureProvider textureProvider;
  final AtlasGeneratorFunction? _generate;
  final Future<void> Function() _nextFrame;
  final String _baseChars;
  final int _baseSeedThreshold;

  /// Every character requested per font so far, so a new union covers all
  /// of them and later tiles reuse it instead of building their own.
  final _seenByFont = <String, SplayTreeSet<int>>{};

  /// The latest union per font, so concurrent misses wait for it.
  final _unionByFont = <String, AtlasID>{};

  /// Fonts that passed [maxAtlasChars] and use per-tile atlases from now on.
  final _overflowedFonts = <String>{};

  AtlasGenerator({
    required this.atlasProvider,
    required this.textureProvider,
    @visibleForTesting AtlasGeneratorFunction? generate,
    @visibleForTesting Future<void> Function()? nextFrame,
    @visibleForTesting String? baseChars,
    @visibleForTesting int? baseSeedThreshold,
  })  : _generate = generate,
        _nextFrame = nextFrame ?? _endOfFrame,
        _baseChars = baseChars ?? defaultBaseChars,
        _baseSeedThreshold = baseSeedThreshold ?? defaultBaseSeedThreshold;

  static Future<void> _endOfFrame() => SchedulerBinding.instance.endOfFrame;

  /// Resets the process-wide generation state between tests.
  @visibleForTesting
  static void resetForTesting() {
    _generationTail = Future.value();
    _stats.reset();
  }

  /// Loads an atlas holding [str] in [fontFamily] for tile [tileID] and
  /// returns it, or null when it was withheld.
  Future<GlyphAtlas?> loadAtlas(
      {required String str,
      required String fontFamily,
      required String tileID}) async {
    GlyphAtlas? atlas;
    while (true) {
      final covering = _bestCovering(str, fontFamily);
      if (covering != null) {
        atlas = await covering.future;
        break;
      }
      final pending = _pendingUnion(fontFamily);
      if (pending != null) {
        // Don't queue a union per tile while one is in flight: record what
        // this tile needs, wait, and look again. The first tile to retry
        // builds one union covering every tile that waited.
        _seen(fontFamily).addAll(str.codeUnits);
        await pending.future;
        continue;
      }
      final id =
          AtlasID(chars: _charsToBuild(str, fontFamily), font: fontFamily);
      atlas = await _loadAtlas(id);
      if (atlas == null && id.chars != str) {
        // A withheld union would drop this font's labels on every tile
        // waiting on it. This tile's own characters make a much smaller
        // atlas, so try them once.
        atlas = await _loadAtlas(AtlasID(chars: str, font: fontFamily));
      }
      break;
    }

    // A withheld atlas was logged where it failed. Text layout drops every
    // label of this tile that needs one of its characters, and the tile keeps
    // that label-less render data until it leaves the tile cache. The next
    // request for these characters generates the atlas again.
    if (atlas == null) {
      return null;
    }
    atlasProvider.addLoaded({atlas}, tileID);
    return atlas;
  }

  /// Loads atlases covering [glyphs] (the characters each font needs) for
  /// tile [tileID], at most [maxAtlasChars] characters per request, and
  /// returns them. Withheld atlases are missing from the result.
  Future<Set<GlyphAtlas>> loadGlyphs(
      Map<String, Set<int>> glyphs, String tileID) async {
    final loaded = <GlyphAtlas>{};
    for (final MapEntry(key: font, value: charCodes) in glyphs.entries) {
      final sorted = charCodes.toList()..sort();
      for (var i = 0; i < sorted.length; i += maxAtlasChars) {
        final end = math.min(i + maxAtlasChars, sorted.length);
        final atlas = await loadAtlas(
            str: String.fromCharCodes(sorted.sublist(i, end)),
            fontFamily: font,
            tileID: tileID);
        if (atlas != null) {
          loaded.add(atlas);
        }
      }
    }
    return loaded;
  }

  /// The atlas to reuse for [str]: a completed one before an in-flight one,
  /// then the one with the most characters, so tiles converge on the newest
  /// union and older ones age out.
  Completer<GlyphAtlas?>? _bestCovering(String str, String font) {
    MapEntry<AtlasID, Completer<GlyphAtlas?>>? best;
    for (final entry in _loading.entries) {
      if (!entry.key.canBeUsedFor(str, font)) {
        continue;
      }
      if (best == null) {
        best = entry;
        continue;
      }
      final done = entry.value.isCompleted;
      if (done != best.value.isCompleted) {
        if (done) {
          best = entry;
        }
        continue;
      }
      if (entry.key.chars.length > best.key.chars.length) {
        best = entry;
      }
    }
    return best?.value;
  }

  Completer<GlyphAtlas?>? _pendingUnion(String font) {
    final id = _unionByFont[font];
    final completer = id == null ? null : _loading[id];
    return completer != null && !completer.isCompleted ? completer : null;
  }

  SplayTreeSet<int> _seen(String font) =>
      _seenByFont.putIfAbsent(font, SplayTreeSet<int>.new);

  /// The characters for a new atlas of [font] that must cover [str]: every
  /// character seen for [font] so far plus [str], and the base set once the
  /// font has needed [_baseSeedThreshold] characters. Falls back to [str]
  /// alone, for good, once that union would pass [maxAtlasChars].
  String _charsToBuild(String str, String font) {
    if (_overflowedFonts.contains(font)) {
      return str;
    }
    final seen = _seen(font)..addAll(str.codeUnits);
    if (seen.length >= _baseSeedThreshold) {
      seen.addAll(_baseChars.codeUnits);
    }
    if (seen.length > maxAtlasChars) {
      _overflowedFonts.add(font);
      GlyphAtlasStats.log(() => 'Glyph atlases for $font passed '
          '$maxAtlasChars characters; using per-tile atlases from now on');
      return str;
    }
    final chars = String.fromCharCodes(seen);
    _unionByFont[font] = AtlasID(chars: chars, font: font);
    return chars;
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
    final metrics = <int, GlyphMetrics>{};
    for (var i = 0; i < charCodes.length; i++) {
      // A union atlas has ~200 glyphs: give frames a turn between batches.
      if (i > 0 && i % glyphsPerSlice == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final code = charCodes[i];
      metrics[code] = metricsExtractor.extractMetrics(code, cellSize, cellSize);
    }

    final sdfRenderer = SdfRenderer(config, cellSize * config.renderScale);

    final readback = await glyphRenderer.renderGlyphBytes(renderFontSize);
    final glyphs = readback.bytes;
    if (glyphs == null) {
      _stats.onWithheld(_describe(id), readback: readback);
      return null;
    }

    final sdfTexture = sdfRenderer.renderToSDF(glyphs);
    textureProvider.addLoaded(sdfTexture, id.hashCode);

    _stats.onBuilt(_describe(id), readback, stopwatch.elapsedMilliseconds,
        shared: _isUnion(id));

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

  bool _isUnion(AtlasID id) => _unionByFont[id.font] == id;

  String _describe(AtlasID id) => '${id.font}, ${id.chars.length} chars, '
      '${_isUnion(id) ? 'union' : 'requested'}';
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
    final (picture, width, height) = await _record(renderFontSize, nonce);
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
  Future<(ui.Picture, int, int)> _record(int renderFontSize, int nonce) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    final cellSize =
        renderFontSize + (config.sdfPadding * config.renderScale.toDouble());

    final canvasSize =
        Offset(cellSize * config.gridCols, cellSize * config.gridRows);
    final bounds = Rect.fromPoints(Offset.zero, canvasSize);

    canvas.saveLayer(bounds, Paint()..colorFilter = GlyphStamp.filter(nonce));
    try {
      canvas.drawRect(
        bounds,
        Paint()..color = Colors.white,
      );

      final charCodes = config.atlasID.chars.codeUnits;
      for (int i = 0; i < charCodes.length; i++) {
        if (i > 0 && i % glyphsPerSlice == 0) {
          await Future<void>.delayed(Duration.zero);
        }
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

        try {
          textPainter.layout();

          final paddingLeft = (cellSize - textPainter.width) / 2;
          final paddingTop = (cellSize - textPainter.height) / 2;

          textPainter.paint(
              canvas,
              Offset(paddingLeft + (col * cellSize),
                  paddingTop + (row * cellSize)));
        } finally {
          textPainter.dispose();
        }
      }
    } finally {
      canvas.restore();
    }

    return (
      recorder.endRecording(),
      canvasSize.dx.toInt(),
      canvasSize.dy.toInt()
    );
  }
}
