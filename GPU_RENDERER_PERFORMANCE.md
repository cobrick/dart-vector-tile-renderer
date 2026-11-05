# GPU Renderer Performance Notes

This file records the GPU renderer baseline and the follow-up work aimed at
making pan and zoom smoother. It is intentionally separate from the regular
package README so profiling decisions have one source of truth.

## Current Pipeline: One 2D Render Pass (AMPS-3216)

Each map layer (`TilesRenderer`: world, labels) draws its visible tiles with
`MapRenderPass`, one Flutter GPU render pass per frame:

- **Target**: an 8-bit RGBA texture from a ring of three (the GPU never draws
  into a texture the compositor may still read), sized to the layer's area in
  physical pixels. With anti-aliasing, the pass draws into a 4× multisampled
  texture in transient (on-chip) memory and resolves into the target at the
  end of the pass. `MapAntiAliasing.fxaa` and `auto` mean MSAA too; labels
  default to none (`GpuMapSettings.labelAntiAliasing`), their SDF edges are
  already smooth.
- **Order**: meshes draw in style-layer order across all visible tiles
  (`layerMajorOrder`), with straight-alpha blending and no depth buffer, so
  each layer paints over the ones below it. Each packed mesh records its style
  layer index (`PackedMesh.layer`) for this. Drawing layer by layer also keeps
  geometry in a tile's buffer zone under the neighbouring tile's higher layers.
- **Colours**: style colours are written as they are, with no tone mapping or
  gamma, so the screen shows the style's values.
- **Per frame**: one `FrameInfo` uniform per tile, pipelines cached per shader
  pair, material and geometry uniforms emplaced in one host buffer.
- **Composite**: `canvas.drawImageRect` of the target into the layer's area.

It replaced flutter_scene's 3D pipeline, which per frame and per layer drew
into a 16-bit HDR target with a depth buffer, ran a full-screen tone-mapping
pass and (on FXAA profiles) a full-screen FXAA pass, and sorted opaque and
translucent meshes. That pipeline also rendered pixelRatio² as many pixels as
the screen shows, because the canvas was already scaled to physical pixels.
flutter_scene is still a dependency for raster tilesets
(`gpuTextureFromImage`) only.

### Measured (2026-11-05)

Release builds of Tactical Commander (Galaxy Tab Active5 8", Mali-G68,
Vulkan) and Base Station (Galaxy Tab Active5 Pro, Vulkan), both at
120 Hz. The app drives the camera along the same scripted route (swipes at
zoom 14, 16 and 11, a continuous pan at 13, zooms); only frames whose vsync
falls while the camera moves count. Mean of two runs.

| Build | 8" fps | 8" UI p50 | 8" frames > 16.7 ms | 8" GPU MB | Pro fps | Pro UI p50 |
| --- | --- | --- | --- | --- | --- | --- |
| Baseline (`e5f5b93`) | 44.9 | 18.9 ms | 86% | 313 | 64.4 | 12.9 ms |
| Labels without FXAA (`9a25154`) | 49.0 | 17.2 ms | 69% | 286 | 69.2 | 11.8 ms |
| Screen resolution (`4316971`) | 64.3 | 12.6 ms | 13% | 207 | 85.1 | 9.3 ms |
| 2D render pass (this) | 97.2 | 5.0 ms | 4% | 156 | 101.6 | 4.6 ms |

Diagnostics on the baseline showed the UI thread mostly waited for GPU work:
at half resolution the 8" ran at 93 fps, with the labels layer off at 70.

## Committed Baseline

The baseline is commit `1763352` (`feat: port GPU tile renderer to
flutter_scene 0.18.1 / new flutter_gpu`). It was already on branch
`pb/flutter-scene-0.18-master-gpu` before the performance follow-up.

It contains the Flutter master GPU migration and fixes required for correct
map rendering on the new API:

- Updates `flutter_scene`, `flutter_gpu_shaders`, native build hooks, shader
  loading, GPU buffer binding, material lighting, and camera APIs.
- Loads the tile shader library asynchronously and prevents renderer use until
  the scene and shaders are ready.
- Restores deterministic 2D layer order with per-layer depth offsets, depth
  testing/writes, and no face culling. This prevents the renderer's pipeline
  sorting from changing map paint order.
- Treats translucent colored material as non-opaque, preventing it from
  incorrectly covering layers below it.
- Fixes text visibility and scale after the new reflected vertex layout. Text
  is scaled by device display scale, with stable SDF softness.
- Adds process-wide `GpuMapSettings` for anti-aliasing and experimental
  frustum culling. Anti-aliasing is a quality/per-frame-GPU-cost tradeoff.

Together with the smoothing work below, this commit provides the compatible,
visually correct GPU-rendering base on which tile scheduling and reuse work.

### Frustum Culling Is Currently Unusable

Obsolete since the 2D render pass: `GpuMapSettings.frustumCulling` has no
effect, and `viewportCulling` skips off-screen tiles.

Frustum culling has been tested on-device and must remain disabled
(`GpuMapSettings.frustumCulling = false`). Enabling it produces a rectangle
artifact around the centre of the map and causes text to disappear, which
breaks the rendered map.

The cause is not yet determined. The orthographic camera may not expose the
correct culling frustum after the Flutter GPU migration, or frustum culling may
be broken in the current renderer/engine combination. Treat it as unsupported
until the camera bounds and engine behaviour are investigated and verified.

## Pre-existing SDF Shader Correction

The current working tree also contains a pre-existing change in both SDF
generation stages:

- `shaders/sdf_gen/vector_tile_renderer$stage_a.frag`
- `shaders/sdf_gen/vector_tile_renderer$stage_b.frag`

The upper scan bound is clamped with `min(..., 1)`, matching the lower bound's
`max(..., 0)`. The previous `max(..., 1)` forced the scan to the atlas edge,
even when the configured SDF radius had already been reached. Keep this
change: it reduces unnecessary fragment work without changing the configured
distance range or dropping glyph data.

## Style Colours Pass Through Unchanged (AMPS-3216)

flutter_scene renders into a linear HDR target, and its resolve pass
tone-maps (PBR Neutral by default) and gamma-encodes with a fixed
`pow(1/2.2)`. Map style colours are already display (sRGB) values, so the
map came out lighter than its style. Measured on the dark theme (8"
Galaxy Tab Active5): buildings rgb(24, 24, 24) showed as 68 grey, major
roads 85 as 146, and water rgba(90, 173, 255, 0.21) over black as
(56, 91, 115) instead of (19, 36, 54).

The first fix set linear tone mapping and a colour-grading gamma of 1/2.2,
which cancelled the final encode. The 2D render pass (above) has no tone
mapping or gamma at all. Blending happens on the style's sRGB values, like
MapLibre and the canvas renderer.

## Current Uncommitted Smoothing Work

### Union glyph atlases per font (AMPS-3116)

History: an early version built a default atlas of all 256 low character
codes whenever a tile used text. It was replaced with atlases built from only
the characters in each tile (typically 54–65 glyphs). But a tile reused an
atlas only when the atlas held **all** of its characters, so panning kept
building atlases. The Silesia atlases drew ~400 glyphs for 74 distinct
characters.

Now `AtlasGenerator` builds **union atlases**. A new atlas for a font holds:
- every character already seen for that font, plus the tile's characters;
- a Latin base set (`defaultBaseChars`, 214 characters: ASCII, Latin-1
  letters, common punctuation, and the Central European letters of Latin
  Extended-A), once the font has needed `defaultBaseSeedThreshold` (32)
  distinct characters.

The main label font reaches the threshold on its first tile. Fonts that serve
one small layer (motorway refs, water names) keep small atlases.

- **Reuse:** a request takes the completed covering atlas with the most
  characters, so tiles converge on the newest union and older ones age out.
- **Concurrent misses:** while a union is in flight, a miss records its
  characters and waits. The next union then covers every tile that waited,
  so concurrent misses cost one extra build, not one per tile.
- **Cap:** past `maxAtlasChars` (256, the visitor's chunk size, a 16×16 grid)
  a font switches to per-tile atlases for the rest of the generator's life,
  and logs it once.
- **Withheld union:** if a union is withheld, the tile retries once with only
  its own characters.
- **Slicing:** glyph metrics and recording yield to the event loop every
  `glyphsPerSlice` (32) glyphs, so a large atlas doesn't block the UI thread
  in one piece.

Measured on the same scripted 3.5-minute route, cold start, release builds of
Tactical Commander, per-tile atlases vs union atlases (2026-11-04):

| | Galaxy Tab Active5 (Mali-G68, Vulkan) | Getac ZX10 (Adreno 512, GLES) |
| --- | --- | --- |
| Atlases built while panning | 49 → 0 | 62 → 0 |
| Atlas work while panning | 4.7 s → 0 | 8.3 s → 0 |
| Atlases at startup | 11 → 2 | 10 → 2 |
| First atlas at startup | 194 → 528 ms | 1.6 → 1.8 s (incl. shader compile) |
| GPU memory after the route | 335.5 → 310.7 MB | 63.5 → 63.3 MB |

Frame smoothness while panning was unchanged; map rendering dominates it.
The trade-off is ~0.3 s more to the first labels after a cold start on the
Galaxy Tab. A union holds ~7 MB of SDF texture per font
(1408×1232 RGBA).

### Serialize atlas generation globally

`AtlasGenerator` queues SDF atlas generation through one static future tail.
The tail is static so the world and text renderer instances cannot launch
competing atlas jobs at the same time. It also waits for an end-of-frame before
starting the next job, leaving a frame available for gestures.

This intentionally trades peak throughput for frame consistency: new labels
may appear progressively during a fast pan or zoom, but each requested atlas
remains queued and is eventually generated. It does not discard tiles,
geometry, or text.

### Retain recently off-screen GPU tile nodes

`TilesRenderer` retains a least-recently-used cache of fully prepared GPU
`Node`s. Returning to the same `z/x/y` tile can reuse its geometry, materials,
buffers, textures, and atlas ownership instead of unpacking it again.

`GpuMapSettings.tileNodeCacheCapacity` controls the cache:

- `0` disables it.
- `12` is the renderer fallback when an application does not override it.
- The current application default is `32`, set in
  `common/apollo_uikit/lib/src/map/widgets/partials/`
  `flutter_map_vector_tile_layer.dart`. Change that value for an on-device
  GPU-memory/cache-size comparison.

Larger values improve same-zoom backtracking pans but retain more GPU memory.
They do not provide exact matches for a different zoom level, because the
tile coordinates and tile contents change.

Cached node keys are included when unused glyph atlases and textures are
released. A cached node therefore keeps the atlas textures it needs; it cannot
be restored with missing text textures.

### Profiling Output

The temporary `[PERF]` console prints used for device profiling have been
removed. Historical logs use `atlas`, `preRenderUi`, and `update` entries to
show glyph raster/readback time, SDF command recording/submission time, atlas
wait/work time, and tile-node reuse.

The historical `sdf_gpu` field is not a GPU fence measurement. It captures
CPU-side time to issue SDF work; readback and queue waits can include prior GPU
work. Similarly, a large historical `preRenderUi` total can be deliberate
queue latency rather than one uninterrupted UI/GPU operation.

## What This Does Not Cache

The upstream `vector_map_tiles` cache stores raw vector tile (`.pbf`) bytes.
It still decodes and prepares render data before this renderer receives a tile.
The GPU node cache begins later in the pipeline and avoids rebuilding already
prepared GPU scene content when a tile returns.

The renderer does not persist rendered tiles as disk raster images. Raster
serialization and later image upload would add I/O, memory pressure, texture
upload work, and invalidation concerns for theme, device scale, and style
changes. The in-memory GPU node cache is the appropriate first-level reuse
mechanism for interactive panning.

## Combined Behaviour and Benefit

The branch now operates as one GPU tile-rendering pipeline:

1. The migrated Flutter GPU scene and shaders render map layers in the correct
   order, with correct transparency and text scale.
2. For a new tile, the renderer reuses its font's union atlas when that atlas
   covers the tile's characters. Otherwise it builds one union atlas holding
   every character seen for the font, plus the tile's characters and the
   Latin base set (see "Union glyph atlases per font").
3. Atlas jobs run one at a time across renderer instances, with a frame between
   jobs, rather than all incoming tiles competing for the GPU together.
4. The completed tile geometry, materials, textures, and glyph atlas are
   retained in a small GPU-node LRU cache after the tile leaves the viewport.
5. Returning to the same tile reattaches its prepared GPU node. It does not
   rebuild geometry or regenerate its still-owned glyph atlas.

The combined result is a correct Flutter GPU map that avoids the previous
all-at-once atlas workload. Pans and zooms remain responsive because expensive
text preparation is spread over time, while prior tiles remain visible until
their replacements are ready. Revisiting nearby tiles at the same zoom is
faster because their GPU representation can be reused.

Nothing is skipped: every requested tile, feature, and label is eventually
rendered. The deliberate tradeoff is progressive arrival of new labels during
fast movement. A first-time tile can still have an expensive glyph
raster/readback operation, and a different zoom level cannot reuse a tile node
with different coordinates/content.

## Current Result and Next Direction

The expected profile shape is smaller interaction freezes, frequent
`newTiles=0` / `cachedTiles>0` reuse when revisiting an area, and later
progressive arrival of new labels during aggressive movement. This resolves
the dominant simultaneous atlas-generation burst while preserving complete map
output. A single large glyph readback can still be costly, so the work reduces
peak contention rather than guaranteeing that every tile completes instantly.

The remaining improvement is motion-aware scheduling: while the camera is
actively moving, keep the old tile pyramid visible and defer expensive text
atlas preparation until motion settles. That requires a deliberate integration
with `vector_map_tiles` camera/map-event state; it should not be approximated
with an uncoordinated timer in this renderer.
