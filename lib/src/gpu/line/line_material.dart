import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart';

import '../map_material.dart';
import '../shaders.dart';
import '../tile_render_data.dart';

class LineMaterial extends MapMaterial {
  LineMaterial(PackedMaterial packed)
      : _uniform = packed.uniform!,
        super(shaderLibrary["LineFragment"]!);

  final ByteData _uniform;
  late final UniformSlot _lineMaterialSlot =
      fragmentShader.getUniformSlot('LineMaterial');

  @override
  void bind(RenderPass pass, HostBuffer host) {
    pass.bindUniform(_lineMaterialSlot, host.emplace(_uniform));
  }
}
