/// Anti-aliasing quality for the flutter_gpu vector map.
///
/// Higher quality means smoother edges but more GPU cost per frame. On slow
/// devices, dropping from [msaa] to [fxaa] or [none] is the biggest single
/// performance lever.
enum MapAntiAliasing {
  /// No anti-aliasing. Fastest; edges are aliased ("pixelated").
  none,

  /// Cheap full-screen post-process AA. Softer edges at low cost.
  fxaa,

  /// 4x multisample AA. Best edge quality, highest cost (the historical
  /// default). Falls back to [fxaa] on backends without MSAA support.
  msaa,

  /// MSAA where the backend supports it, otherwise FXAA.
  auto,
}

/// Global, mutable performance/quality knobs for the flutter_gpu vector map
/// renderer (`TilesRenderer`).
///
/// These are process-wide (the renderer is created deep inside
/// `vector_map_tiles`, which exposes no configuration hook), so set them once —
/// e.g. from app startup or a debug settings screen — to trade quality for
/// frame rate. [antiAliasing] applies on the next rendered frame;
/// [frustumCulling] applies the next time tiles are (re)built (pan/zoom or a
/// hot restart).
class GpuMapSettings {
  GpuMapSettings._();

  /// Anti-aliasing mode. Defaults to [MapAntiAliasing.msaa].
  static MapAntiAliasing antiAliasing = MapAntiAliasing.msaa;

  /// Number of recently off-screen GPU tile nodes to retain per renderer.
  ///
  /// Set to zero to disable reuse. Higher values make backtracking pans
  /// smoother at the cost of GPU memory.
  static int tileNodeCacheCapacity = 12;

  /// Max number of brand-new tiles whose GPU geometry is uploaded per
  /// `TilesRenderer.update` call.
  ///
  /// Building a new tile uploads its vertex/index buffers to the GPU
  /// synchronously; a burst of new tiles (e.g. a fast multi-level pinch-zoom
  /// that flies through every zoom level) can otherwise freeze the UI thread
  /// for seconds. Capping the uploads per update spreads that work across
  /// frames: deferred tiles stay pending and are built on a later update,
  /// while already-built / cached tiles keep covering the view.
  ///
  /// Already-built and cached tiles are always shown — only first-time uploads
  /// are throttled, so a slow, deliberate zoom (few new tiles per frame) is
  /// unaffected. Set to zero to disable the cap (upload everything each update).
  static int maxTileUploadsPerUpdate = 3;

  /// Whether to frustum-cull tile geometry outside the camera view.
  ///
  /// When `true`, off-screen geometry is skipped, cutting draw calls when many
  /// tiles are loaded. When `false` (default) every tile in the scene is drawn
  /// each frame.
  ///
  /// Experimental: the map's orthographic camera does not yet produce a tight
  /// view frustum, so enabling this can drop visible tiles — verify on-device.
  static bool frustumCulling = false;
}
