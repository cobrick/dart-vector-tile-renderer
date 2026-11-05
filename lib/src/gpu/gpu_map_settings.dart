import '../logger.dart';

/// Anti-aliasing for the flutter_gpu vector map.
///
/// The map draws in one 2D pass. Anti-aliasing is 4× MSAA in transient
/// (on-chip) memory, resolved at the end of the pass: cheap on the tile-based
/// GPUs of mobile devices. Without offscreen MSAA support the map draws
/// without anti-aliasing.
enum MapAntiAliasing {
  /// No anti-aliasing. Fastest; edges are aliased ("pixelated").
  none,

  /// Kept for existing configurations: the 2D pass has no FXAA, so this
  /// draws with MSAA, like [msaa].
  fxaa,

  /// 4× multisample anti-aliasing.
  msaa,

  /// The same as [msaa].
  auto,
}

/// Global, mutable performance/quality knobs for the flutter_gpu vector map
/// renderer (`TilesRenderer`).
///
/// These are process-wide (the renderer is created deep inside
/// `vector_map_tiles`, which exposes no configuration hook), so set them once —
/// e.g. from app startup or a debug settings screen — to trade quality for
/// frame rate. [antiAliasing] applies on the next rendered frame.
class GpuMapSettings {
  GpuMapSettings._();

  /// Anti-aliasing mode. Defaults to [MapAntiAliasing.msaa].
  static MapAntiAliasing antiAliasing = MapAntiAliasing.msaa;

  /// Anti-aliasing mode of a renderer whose theme holds only symbol (label)
  /// layers. Defaults to [MapAntiAliasing.none]: labels are SDF-shaded, so
  /// their edges are already smooth without it.
  static MapAntiAliasing labelAntiAliasing = MapAntiAliasing.none;

  /// Number of recently off-screen GPU tiles to retain per renderer.
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

  /// Has no effect: the map no longer renders through flutter_scene's 3D
  /// camera. [viewportCulling] skips off-screen tiles.
  @Deprecated('No effect; use viewportCulling.')
  static bool frustumCulling = false;

  /// Whether to skip drawing tiles that fall entirely outside the viewport.
  ///
  /// A cheap 2D test against the viewport in screen space: a tile is skipped
  /// only when its screen rect lies beyond the circle enclosing the viewport,
  /// so it is correct at any map rotation and never hides a visible tile.
  /// Culled tiles stay uploaded, so nothing pops — only their draws are
  /// skipped that frame.
  static bool viewportCulling = true;

  /// Where the renderer reports glyph-atlas diagnostics.
  ///
  /// - `warn`: an atlas that needed a re-render or hit a render error, an
  ///   atlas withheld after failing, and a generation queue error.
  /// - `log`: the first atlas that needed a re-read (expected on some Vulkan
  ///   GPUs, flutter/flutter#194987) and a summary every 50 atlases.
  ///
  /// Silent by default. Set it once at startup to route these lines into
  /// the app's own logging. Messages are built lazily, so a silent logger
  /// costs nothing.
  static Logger logger = const Logger.noop();
}
