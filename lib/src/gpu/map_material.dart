import 'package:flutter_gpu/gpu.dart' as gpu;

import 'static_uniform.dart';

/// The fragment side of a map mesh: a fragment shader and the uniforms and
/// textures it reads.
///
/// Pipeline state (blending, culling) belongs to the render pass, which sets
/// it once for every draw, so materials only bind their own data.
abstract class MapMaterial {
  MapMaterial(this.fragmentShader);

  final gpu.Shader fragmentShader;

  /// Whether this material has everything it needs to draw. A label whose
  /// glyph atlas texture is gone is skipped rather than drawn as boxes.
  bool get isDrawable => true;

  /// The uniform blocks that never change, uploaded once with the tile.
  List<StaticUniform> get staticUniforms => const [];

  /// Binds this material's uniforms and textures for the next draw.
  void bind(gpu.RenderPass pass, gpu.HostBuffer host);
}
