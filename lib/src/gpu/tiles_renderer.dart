import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_scene/scene.dart';
import 'text/sdf/atlas_generator.dart';
import 'text/sdf/atlas_provider.dart';
import 'texture_provider.dart';

import '../../vector_tile_renderer.dart';
import 'bucket_unpacker.dart';
import 'orthographic_camera.dart';
import 'position_transform.dart';
import 'shaders.dart';
import 'text/atlas_creating_text_visitor.dart';
import 'tile_prerenderer.dart';
import 'tile_render_data.dart';

AntiAliasingMode _sceneAntiAliasing(MapAntiAliasing aa) => switch (aa) {
      MapAntiAliasing.none => AntiAliasingMode.none,
      MapAntiAliasing.fxaa => AntiAliasingMode.fxaa,
      MapAntiAliasing.msaa => AntiAliasingMode.msaa,
      MapAntiAliasing.auto => AntiAliasingMode.auto,
    };

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

/// Experimental: renders tiles using flutter_gpu
///
/// this class is stateful, designed to be reused for rendering a tile
/// multiple times.
///
class TilesRenderer with WidgetsBindingObserver {
  static final Completer<void> _initializer = Completer<void>();
  static Future<void> initialize = _initializer.future;

  final _positionByKey = <String, Rect>{};
  final _cachedNodes = <String, Node>{};

  // The visible tile keys built into the scene by the last [update], and
  // whether that update deferred any tile (upload budget). Used to skip the
  // scene teardown/rebuild when the visible set has not changed.
  Set<String> _lastTileKeys = const {};
  bool _lastUpdateDeferred = false;
  final AtlasProvider _atlasProvider = AtlasProvider();
  final TextureProvider _textureProvider = TextureProvider();
  late final _atlasGenerator = AtlasGenerator(
      atlasProvider: _atlasProvider, textureProvider: _textureProvider);
  Theme theme;
  Scene? _scene;

  TilesRenderer(this.theme) {
    // Listen for OS memory pressure so we can drop the off-screen GPU tile
    // cache before the Vulkan allocator runs out of device memory. flutter_gpu
    // textures have no explicit dispose(); the only way to reclaim their GPU
    // memory is to drop every Dart reference and let the GC collect them.
    WidgetsBinding.instance.addObserver(this);
    if (!_initializer.isCompleted) {
      // flutter_scene's base shader bundle and our tile shader bundle both load
      // asynchronously (shader assets can't be read synchronously on any
      // backend); geometry/material construction throws until both are ready.
      Future.wait([
        Scene.initializeStaticResources(),
        loadShaderLibrary(),
      ]).then((_) {
        if (!_initializer.isCompleted) {
          _initializer.complete();
        }
      });
    }
  }

  Scene get scene {
    var scene = _scene;
    if (scene == null) {
      scene = _createScene();
      _scene = scene;
    }
    return scene;
  }

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
      _cachedNodes.clear();
    }
    final scene = this.scene;

    // Fast path: the visible tile set is identical to the last update and that
    // update built all of it (nothing deferred by the upload budget), so the
    // scene graph already holds exactly these nodes. Only the tile positions
    // change frame to frame while the map moves — refresh those and skip the
    // teardown/rebuild, node caching, and atlas prune (the set is unchanged, so
    // there is nothing to cache or unload). A set change or a pending deferral
    // falls through to the full rebuild below.
    if (!_lastUpdateDeferred && models.length == _lastTileKeys.length) {
      var sameSet = true;
      for (final model in models) {
        if (!_lastTileKeys.contains(model.tileId.key())) {
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

    final activeNodesByKey =
        Map.fromEntries(scene.root.children.map((n) => MapEntry(n.name, n)));
    scene.root.removeAll();
    _positionByKey.clear();
    final currentTileKeys = <String>{};
    final uploadBudget = GpuMapSettings.maxTileUploadsPerUpdate;
    var newUploads = 0;
    var deferred = false;
    for (final model in models) {
      final key = model.tileId.key();
      currentTileKeys.add(key);
      var node = activeNodesByKey[key] ?? _cachedNodes.remove(key);
      if (node == null) {
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
        node = Node(name: key);
        BucketUnpacker(_textureProvider, model.rasterTileset)
            .unpackOnto(node, TileRenderData.unpack(renderData));
        newUploads++;
      }
      _positionByKey[key] = model.position;
      scene.add(node);
    }

    for (final entry in activeNodesByKey.entries) {
      if (!currentTileKeys.contains(entry.key)) {
        _cacheNode(entry.key, entry.value);
      }
    }

    _lastTileKeys = currentTileKeys;
    _lastUpdateDeferred = deferred;

    _atlasGenerator.unloadWhereNotFound({
      ...tileIDs,
      ..._cachedNodes.keys,
    });
  }

  void _cacheNode(String key, Node node) {
    final capacity = GpuMapSettings.tileNodeCacheCapacity;
    if (capacity <= 0) {
      return;
    }
    _cachedNodes.remove(key);
    _cachedNodes[key] = node;
    while (_cachedNodes.length > capacity) {
      _cachedNodes.remove(_cachedNodes.keys.first);
    }
  }

  void render(ui.Canvas canvas, ui.Size size, double rotation) {
    final scene = this.scene;
    // Read live so a change to GpuMapSettings takes effect next frame.
    scene.antiAliasingMode = _sceneAntiAliasing(GpuMapSettings.antiAliasing);

    canvas.clipRect(Offset.zero & size);

    // Apply device pixel ratio scaling
    final view = ui.PlatformDispatcher.instance.views.first;
    final pixelRatio = view.display.devicePixelRatio;
    canvas.scale(1 / pixelRatio);

    // Draw-time viewport cull. The map rotates about the viewport centre, so a
    // tile whose nearest point is beyond the circle enclosing the viewport
    // (half the viewport diagonal, plus a safety margin) cannot be visible at
    // any rotation. Culled tiles are only hidden (visible=false) — they stay
    // uploaded in the scene, so nothing pops and only the per-frame draw is
    // skipped.
    final cull = GpuMapSettings.viewportCulling;
    final center = Offset(size.width / 2, size.height / 2);
    const cullMargin = 0.15;
    final cullRadiusSquared = 0.25 *
        (size.width * size.width + size.height * size.height) *
        (1 + cullMargin) *
        (1 + cullMargin);

    for (final node in scene.root.children) {
      final position = _positionByKey[node.name];
      if (position == null) {
        continue;
      }
      node.localTransform = tileTransformMatrix(position, size, rotation);
      node.visible = !cull ||
          _distanceSquaredToRect(center, position) <= cullRadiusSquared;
    }
    scene.render(OrthographicCamera(pixelRatio, rotation), canvas,
        viewport: ui.Offset.zero & canvas.getLocalClipBounds().size);
  }

  Scene _createScene() {
    Scene scene = Scene();
    scene.antiAliasingMode = _sceneAntiAliasing(GpuMapSettings.antiAliasing);
    return scene;
  }

  @override
  void didHaveMemoryPressure() {
    // The OS is under memory pressure. Drop the off-screen tile-node cache and
    // any glyph atlases/textures that aren't backing a currently visible tile,
    // so the GC can reclaim their GPU memory. Visible tiles keep their atlases;
    // revisited tiles simply re-render (progressive), rather than crashing the
    // GPU driver with an out-of-device-memory allocation.
    _cachedNodes.clear();
    _atlasGenerator.unloadWhereNotFound(_positionByKey.keys.toSet());
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scene?.root.removeAll();
    _scene = null;
    _cachedNodes.clear();
    _positionByKey.clear();
    // Release every retained glyph atlas and its GPU texture. Without this a
    // theme switch or layer teardown leaks a full set of GPU resources until
    // the whole renderer is garbage collected.
    _atlasGenerator.unloadWhereNotFound(const <String>{});
  }
}
