import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart' as vm;
import 'text/sdf/atlas_generator.dart';
import 'text/sdf/atlas_provider.dart';
import 'texture_provider.dart';

import '../../vector_tile_renderer.dart';
import 'bucket_unpacker.dart';
import 'map_render_pass.dart';
import 'position_transform.dart';
import 'shaders.dart';
import 'text/atlas_creating_text_visitor.dart';
import 'text/text_material.dart';
import 'tile_prerenderer.dart';
import 'tile_render_data.dart';

/// Squared distance from point [p] to the nearest edge/corner of [r] (0 when
/// [p] is inside [r]). Used for the viewport cull without a sqrt.
double _distanceSquaredToRect(Offset p, Rect r) {
  final dx =
      p.dx < r.left ? r.left - p.dx : (p.dx > r.right ? p.dx - r.right : 0.0);
  final dy =
      p.dy < r.top ? r.top - p.dy : (p.dy > r.bottom ? p.dy - r.bottom : 0.0);
  return dx * dx + dy * dy;
}

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
  final Rect position;
  final Tileset tileset;
  final RasterTileset rasterTileset;
  final Uint8List? renderData;

  TileUiModel(
      {required this.tileId,
      required this.position,
      required this.tileset,
      required this.rasterTileset,
      required this.renderData});
}

/// Renders tiles with Flutter GPU, in one 2D render pass per frame (see
/// [MapRenderPass]).
///
/// This class is stateful, designed to be reused for rendering tiles
/// frame after frame.
class TilesRenderer with WidgetsBindingObserver {
  static final Completer<void> _initializer = Completer<void>();
  static Future<void> initialize = _initializer.future;

  final _positionByKey = <String, Rect>{};

  // The tiles built by the last [update], in model order, and recently
  // off-screen tiles kept for reuse (least recently used first).
  var _activeByKey = <String, List<MapDraw>>{};
  final _cachedByKey = <String, List<MapDraw>>{};

  // Whether the last [update] held back a tile (upload budget). Used to skip
  // the rebuild when the visible set has not changed.
  bool _lastUpdateDeferred = false;

  // Labels fade in over this long after their tile is built (the text
  // shader's `Age` uniform), plus a frame or two of margin.
  static const _labelFadeIn = Duration(milliseconds: 550);
  final _sinceLabelsBuilt = Stopwatch();
  final AtlasProvider _atlasProvider = AtlasProvider();
  final TextureProvider _textureProvider = TextureProvider();
  late final _atlasGenerator = AtlasGenerator(
      atlasProvider: _atlasProvider, textureProvider: _textureProvider);
  final _renderPass = MapRenderPass();
  Theme theme;

  TilesRenderer(this.theme) {
    // Listen for OS memory pressure so we can drop the off-screen GPU tile
    // cache before the Vulkan allocator runs out of device memory. flutter_gpu
    // textures have no explicit dispose(); the only way to reclaim their GPU
    // memory is to drop every Dart reference and let the GC collect them.
    WidgetsBinding.instance.addObserver(this);
    if (!_initializer.isCompleted) {
      // The tile shader bundle loads asynchronously (shader assets can't be
      // read synchronously on any backend); geometry/material construction
      // throws until it is ready.
      loadShaderLibrary().then((_) {
        if (!_initializer.isCompleted) {
          _initializer.complete();
        }
      });
    }
  }

  /// Whether this renderer only draws labels (every theme layer is a symbol
  /// layer). Such a renderer uses [GpuMapSettings.labelAntiAliasing].
  bool get _labelsOnly =>
      theme.layers.isNotEmpty &&
      theme.layers.every((layer) => layer.type == ThemeLayerType.symbol);

  /// Whether to draw with 4× MSAA: any anti-aliasing mode other than
  /// [MapAntiAliasing.none] (the 2D pass has no FXAA, so
  /// [MapAntiAliasing.fxaa] gets MSAA too), when the GPU supports it.
  bool get _msaa {
    final mode = _labelsOnly
        ? GpuMapSettings.labelAntiAliasing
        : GpuMapSettings.antiAliasing;
    return mode != MapAntiAliasing.none &&
        gpu.gpuContext.doesSupportOffscreenMSAA;
  }

  /// Whether the map must be updated and drawn again even if the camera and
  /// the tiles stay still: tiles held back by the upload budget are still
  /// waiting to be built, or labels of a recently built tile are fading in.
  bool get needsAnotherFrame =>
      _lastUpdateDeferred ||
      (_sinceLabelsBuilt.isRunning && _sinceLabelsBuilt.elapsed < _labelFadeIn);

  Uint8List Function(Theme theme, double zoom, Tileset tileset, String tileID)
      getPreRenderer() {
    final atlasProvider = _atlasProvider;
    final view = ui.PlatformDispatcher.instance.views.first;
    final pixelRatio = view.display.devicePixelRatio;
    return (Theme theme, double zoom, Tileset tileset, String tileID) =>
        TilePreRenderer().preRender(
            theme, zoom, tileset, atlasProvider.forTileID(tileID), pixelRatio);
  }

  Future preRenderUi(double zoom, Tileset tileset, String tileID) async {
    final visitor = AtlasCreatingTextVisitor(_atlasGenerator, theme);
    visitor.visitAllFeatures(tileset, zoom);
    await visitor.finish(tileID);
  }

  void update(double zoom, List<TileUiModel> models, Iterable<String> tileIDs) {
    if (GpuMapSettings.tileNodeCacheCapacity <= 0) {
      _cachedByKey.clear();
    }

    // Fast path: the visible tile set is identical to the last update and that
    // update built all of it (nothing deferred by the upload budget). Only the
    // tile positions change frame to frame while the map moves — refresh
    // those and skip the rebuild, caching, and atlas prune (the set is
    // unchanged, so there is nothing to cache or unload). A set change or a
    // pending deferral falls through to the full rebuild below.
    if (!_lastUpdateDeferred && models.length == _activeByKey.length) {
      var sameSet = true;
      for (final model in models) {
        if (!_activeByKey.containsKey(model.tileId.key())) {
          sameSet = false;
          break;
        }
      }
      if (sameSet) {
        for (final model in models) {
          _positionByKey[model.tileId.key()] = model.position;
        }
        return;
      }
    }

    final previous = _activeByKey;
    final active = <String, List<MapDraw>>{};
    _positionByKey.clear();
    final uploadBudget = GpuMapSettings.maxTileUploadsPerUpdate;
    var newUploads = 0;
    var deferred = false;
    for (final model in models) {
      final key = model.tileId.key();
      var draws = previous.remove(key) ?? _cachedByKey.remove(key);
      if (draws == null) {
        // Brand-new tile: unpacking uploads its geometry to the GPU
        // synchronously. Cap uploads per update so a burst of new tiles (e.g. a
        // fast multi-level zoom) can't freeze the UI thread. Deferred tiles are
        // still display-ready and get built on a later update; the previous
        // tile pyramid keeps covering their area meanwhile.
        if (uploadBudget > 0 && newUploads >= uploadBudget) {
          deferred = true;
          continue;
        }
        final renderData = model.renderData;
        if (renderData == null) {
          throw Exception(
              "no render data for tile ${model.tileId}, did you call preRender?");
        }
        draws = BucketUnpacker(_textureProvider, model.rasterTileset)
            .unpack(TileRenderData.unpack(renderData));
        newUploads++;
        if (draws.any((draw) => draw.material is TextMaterial)) {
          _sinceLabelsBuilt
            ..reset()
            ..start();
        }
      }
      _positionByKey[key] = model.position;
      active[key] = draws;
    }

    // Whatever is left of the previous set went off screen.
    for (final entry in previous.entries) {
      _cacheTile(entry.key, entry.value);
    }

    _activeByKey = active;
    _lastUpdateDeferred = deferred;

    _atlasGenerator.unloadWhereNotFound({
      ...tileIDs,
      ..._cachedByKey.keys,
    });
  }

  void _cacheTile(String key, List<MapDraw> draws) {
    final capacity = GpuMapSettings.tileNodeCacheCapacity;
    // A tile built without its glyph atlas would come back without labels;
    // let it reload instead.
    if (capacity <= 0 || draws.any((draw) => !draw.material.isDrawable)) {
      return;
    }
    _cachedByKey.remove(key);
    _cachedByKey[key] = draws;
    while (_cachedByKey.length > capacity) {
      _cachedByKey.remove(_cachedByKey.keys.first);
    }
  }

  void render(ui.Canvas canvas, ui.Size size, double rotation) {
    canvas.clipRect(Offset.zero & size);

    // Draw in physical pixels: one target pixel per screen pixel.
    final view = ui.PlatformDispatcher.instance.views.first;
    final pixelRatio = view.display.devicePixelRatio;
    canvas.scale(1 / pixelRatio);
    final destination = ui.Offset.zero & canvas.getLocalClipBounds().size;
    final width = destination.width.ceil();
    final height = destination.height.ceil();

    // Draw-time viewport cull. The map rotates about the viewport centre, so a
    // tile whose nearest point is beyond the circle enclosing the viewport
    // (half the viewport diagonal, plus a safety margin) cannot be visible at
    // any rotation. Culled tiles stay uploaded, so nothing pops; only their
    // draws are skipped this frame.
    final cull = GpuMapSettings.viewportCulling;
    final center = Offset(size.width / 2, size.height / 2);
    const cullMargin = 0.15;
    final cullRadiusSquared = 0.25 *
        (size.width * size.width + size.height * size.height) *
        (1 + cullMargin) *
        (1 + cullMargin);

    final tiles = <TileFrame>[];
    for (final entry in _activeByKey.entries) {
      final position = _positionByKey[entry.key];
      if (position == null ||
          (cull &&
              _distanceSquaredToRect(center, position) > cullRadiusSquared)) {
        continue;
      }
      tiles.add(TileFrame(
          entry.value, tileTransformMatrix(position, size, rotation)));
    }

    // Maps clip space to target pixels. The shaders use it only to size lines
    // and text (one unit per screen pixel); positions come from the tile
    // transforms.
    final camera = vm.Matrix4.identity()
      ..scaleByDouble(width.toDouble(), height.toDouble(), 1.0, 1.0)
      ..rotateZ(rotation * pi / 180);

    _renderPass.render(
      canvas,
      destination,
      width: width,
      height: height,
      tiles: tiles,
      camera: camera,
      msaa: _msaa,
    );
  }

  @override
  void didHaveMemoryPressure() {
    // The OS is under memory pressure. Drop the off-screen tile cache and
    // any glyph atlases/textures that aren't backing a currently visible tile,
    // so the GC can reclaim their GPU memory. Visible tiles keep their atlases;
    // revisited tiles simply re-render (progressive), rather than crashing the
    // GPU driver with an out-of-device-memory allocation.
    _cachedByKey.clear();
    _atlasGenerator.unloadWhereNotFound(_positionByKey.keys.toSet());
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _activeByKey = {};
    _cachedByKey.clear();
    _positionByKey.clear();
    _renderPass.dispose();
    // Release every retained glyph atlas and its GPU texture. Without this a
    // theme switch or layer teardown leaks a full set of GPU resources until
    // the whole renderer is garbage collected.
    _atlasGenerator.unloadWhereNotFound(const <String>{});
  }
}
