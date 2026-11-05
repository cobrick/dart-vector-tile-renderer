import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart' as gpu;

import '../map_material.dart';
import '../shaders.dart';

/// A raster tile's texture at the layer's opacity.
class RasterMaterial extends MapMaterial {
  RasterMaterial({
    required gpu.Texture colorTexture,
    required double resampling,
    required double opacity,
  })  : _texture = colorTexture,
        // FragInfo { vec4 color; float vertex_color_weight; }: white at the
        // layer opacity, vertex colour weight 1 (the former unlit default).
        _fragInfo = ByteData.sublistView(
            Float32List.fromList([1.0, 1.0, 1.0, opacity, 1.0])),
        _sampler = resampling == 0.0
            ? gpu.SamplerOptions()
            : gpu.SamplerOptions(
                minFilter: gpu.MinMagFilter.linear,
                magFilter: gpu.MinMagFilter.linear,
                mipFilter: gpu.MipFilter.linear,
                widthAddressMode: gpu.SamplerAddressMode.clampToEdge,
                heightAddressMode: gpu.SamplerAddressMode.clampToEdge,
              ),
        super(shaderLibrary['RasterFragment']!);

  final gpu.Texture _texture;
  final ByteData _fragInfo;
  final gpu.SamplerOptions _sampler;

  late final gpu.UniformSlot _fragInfoSlot =
      fragmentShader.getUniformSlot("FragInfo");
  late final gpu.UniformSlot _textureSlot =
      fragmentShader.getUniformSlot('base_color_texture');

  @override
  void bind(gpu.RenderPass pass, gpu.HostBuffer host) {
    pass.bindUniform(_fragInfoSlot, host.emplace(_fragInfo));
    pass.bindTexture(_textureSlot, _texture, sampler: _sampler);
  }
}
