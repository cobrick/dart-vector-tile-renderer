import 'package:flutter_gpu/gpu.dart';

import '../map_material.dart';
import '../shaders.dart';
import '../static_uniform.dart';
import '../tile_render_data.dart';

class LineMaterial extends MapMaterial {
  LineMaterial(PackedMaterial packed)
      : _uniform = StaticUniform(packed.uniform!),
        super(shaderLibrary["LineFragment"]!);

  final StaticUniform _uniform;
  late final UniformSlot _lineMaterialSlot =
      fragmentShader.getUniformSlot('LineMaterial');

  @override
  List<StaticUniform> get staticUniforms => [_uniform];

  @override
  void bind(RenderPass pass, HostBuffer host) {
    pass.bindUniform(_lineMaterialSlot, _uniform.view(host));
  }
}
