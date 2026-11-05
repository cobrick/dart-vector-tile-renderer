import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart';

import 'map_material.dart';
import 'tile_geometry.dart';

/// One mesh of a tile: its geometry and material, and the index of the style
/// layer it belongs to.
class MapDraw {
  MapDraw(this.layer, this.geometry, this.material);

  final int layer;
  final TileGeometry geometry;
  final MapMaterial material;

  bool get isDrawable => !geometry.isEmpty && material.isDrawable;
}

/// A tile to draw this frame: its meshes, sorted by style layer, and the
/// transform that places it on screen.
class TileFrame {
  TileFrame(this.draws, this.transform);

  final List<MapDraw> draws;
  final Matrix4 transform;
}

/// The order in which to draw the meshes of several tiles: every tile's
/// meshes of the lowest style layer first, then the next layer, and so on.
/// Within a layer, tiles keep their order and each tile keeps its meshes'
/// order. [layersPerTile] lists, per tile, the layer of each mesh, sorted
/// ascending. Returns (tile, mesh) index pairs.
///
/// Drawing layer by layer is what keeps the style's paint order across
/// tiles: geometry in a tile's buffer zone (just outside its square) is
/// painted under the neighbour's higher layers, not over them.
List<(int, int)> layerMajorOrder(List<List<int>> layersPerTile) {
  final order = <(int, int)>[];
  final cursors = List<int>.filled(layersPerTile.length, 0);
  while (true) {
    int? layer;
    for (var t = 0; t < layersPerTile.length; t++) {
      final layers = layersPerTile[t];
      final c = cursors[t];
      if (c < layers.length && (layer == null || layers[c] < layer)) {
        layer = layers[c];
      }
    }
    if (layer == null) return order;
    for (var t = 0; t < layersPerTile.length; t++) {
      final layers = layersPerTile[t];
      while (cursors[t] < layers.length && layers[cursors[t]] == layer) {
        order.add((t, cursors[t]));
        cursors[t]++;
      }
    }
  }
}

/// Draws map tiles with Flutter GPU in one 2D render pass per frame and
/// composites the result onto a canvas.
///
/// The pass draws into an 8-bit colour target taken from a small ring, so the
/// GPU never draws into a texture the compositor may still be reading. With
/// MSAA, it draws into a 4× multisampled texture in transient (on-chip)
/// memory and resolves into the colour target at the end of the pass. Meshes
/// are drawn in style-layer order across all tiles with straight-alpha
/// blending, so each layer paints over the ones below it as the style
/// describes. There is no depth buffer, tone mapping or post-processing, and
/// style colours reach the screen unchanged.
class MapRenderPass {
  static const _framesInFlight = 3;

  static final _blend = gpu.ColorBlendEquation(
    colorBlendOperation: gpu.BlendOperation.add,
    sourceColorBlendFactor: gpu.BlendFactor.sourceAlpha,
    destinationColorBlendFactor: gpu.BlendFactor.oneMinusSourceAlpha,
    alphaBlendOperation: gpu.BlendOperation.add,
    sourceAlphaBlendFactor: gpu.BlendFactor.one,
    destinationAlphaBlendFactor: gpu.BlendFactor.oneMinusSourceAlpha,
  );

  static final _pipelines = <(gpu.Shader, gpu.Shader), gpu.RenderPipeline>{};

  final _colors = <gpu.Texture>[];
  int _cursor = 0;
  int _width = 0;
  int _height = 0;
  gpu.Texture? _msaaColor;
  gpu.HostBuffer? _host;

  /// Draws [tiles] into a [width]×[height] pixel target and paints it into
  /// [destination] on [canvas]. [camera] maps the tiles' clip space to
  /// pixels; shaders use it to size lines and text.
  void render(
    ui.Canvas canvas,
    ui.Rect destination, {
    required int width,
    required int height,
    required List<TileFrame> tiles,
    required Matrix4 camera,
    required bool msaa,
  }) {
    if (width < 1 || height < 1) return;
    final color = _nextColorTarget(width, height);
    final msaaColor = msaa ? _msaaTarget(width, height) : null;
    final host = _host ??= gpu.gpuContext.createHostBuffer();
    host.reset();

    final commandBuffer = gpu.gpuContext.createCommandBuffer();
    final pass = commandBuffer.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(
          texture: msaaColor ?? color,
          resolveTexture: msaaColor == null ? null : color,
          storeAction: msaaColor == null
              ? gpu.StoreAction.store
              : gpu.StoreAction.multisampleResolve,
          clearValue: Vector4.zero(),
        ),
      ),
    );
    pass
      ..setCullMode(gpu.CullMode.none)
      ..setColorBlendEnable(true)
      ..setColorBlendEquation(_blend)
      ..setPrimitiveType(gpu.PrimitiveType.triangle);
    _encode(pass, host, tiles, camera);
    commandBuffer.submit();

    canvas.drawImageRect(
      color.asImage(),
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      destination,
      ui.Paint()..filterQuality = ui.FilterQuality.low,
    );
  }

  void _encode(
    gpu.RenderPass pass,
    gpu.HostBuffer host,
    List<TileFrame> tiles,
    Matrix4 camera,
  ) {
    // One FrameInfo uniform per tile, shared by all of the tile's meshes.
    final frameInfos = [
      for (final tile in tiles)
        host.emplace(_frameInfo(tile.transform, camera)),
    ];
    final order = layerMajorOrder([
      for (final tile in tiles) [for (final d in tile.draws) d.layer],
    ]);
    gpu.RenderPipeline? bound;
    for (final (t, i) in order) {
      final draw = tiles[t].draws[i];
      if (!draw.isDrawable) continue;
      final vertexShader = draw.geometry.vertexShader;
      final fragmentShader = draw.material.fragmentShader;
      final pipeline = _pipelines[(vertexShader, fragmentShader)] ??=
          gpu.gpuContext.createRenderPipeline(vertexShader, fragmentShader);
      pass.clearBindings();
      if (!identical(pipeline, bound)) {
        pass.bindPipeline(pipeline);
        bound = pipeline;
      }
      draw.geometry.bind(pass, host, frameInfos[t]);
      draw.material.bind(pass, host);
      draw.geometry.draw(pass);
    }
  }

  // std140 FrameInfo { mat4 model_transform; mat4 camera_transform;
  // vec3 camera_position; }. The camera position only feeds a varying the
  // fragment shaders ignore; it keeps flutter_scene's former value.
  static ByteData _frameInfo(Matrix4 model, Matrix4 camera) {
    final data = Float32List(36)
      ..setRange(0, 16, model.storage)
      ..setRange(16, 32, camera.storage)
      ..[34] = -1000000;
    return ByteData.sublistView(data);
  }

  gpu.Texture _nextColorTarget(int width, int height) {
    if (width != _width || height != _height) {
      _colors.clear();
      _cursor = 0;
      _msaaColor = null;
      _width = width;
      _height = height;
    }
    if (_cursor == _colors.length) {
      _colors.add(
        gpu.gpuContext.createTexture(
          gpu.StorageMode.devicePrivate,
          width,
          height,
          enableRenderTargetUsage: true,
          enableShaderReadUsage: true,
        ),
      );
    }
    final texture = _colors[_cursor];
    _cursor = (_cursor + 1) % _framesInFlight;
    return texture;
  }

  gpu.Texture _msaaTarget(int width, int height) =>
      _msaaColor ??= gpu.gpuContext.createTexture(
        gpu.StorageMode.deviceTransient,
        width,
        height,
        sampleCount: 4,
        enableRenderTargetUsage: true,
        enableShaderReadUsage: false,
      );

  void dispose() {
    _colors.clear();
    _cursor = 0;
    _width = 0;
    _height = 0;
    _msaaColor = null;
    _host = null;
  }
}
