import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart';

import 'map_material.dart';
import 'shaders.dart';
import 'tile_render_data.dart';

/// A flat colour: fills and the background. The uniform is
/// `Paint { vec4 color }`, the style colour with its opacity in alpha.
class ColoredMaterial extends MapMaterial {
  ColoredMaterial(PackedMaterial packed)
      : _uniform = packed.uniform!,
        super(shaderLibrary["SimpleFragment"]!);

  final ByteData _uniform;
  late final UniformSlot _paintSlot = fragmentShader.getUniformSlot("Paint");

  @override
  void bind(RenderPass pass, HostBuffer host) {
    pass.bindUniform(_paintSlot, host.emplace(_uniform));
  }
}
