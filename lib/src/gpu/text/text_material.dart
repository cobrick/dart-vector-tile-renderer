import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart';

import '../gpu_map_settings.dart';
import '../map_material.dart';
import '../shaders.dart';
import '../texture_provider.dart';
import '../tile_render_data.dart';
import '../utils.dart';

/// SDF text. The packed uniform starts with the glyph atlas texture id
/// (8 bytes), followed by the `FragInfo` block.
class TextMaterial extends MapMaterial {
  TextMaterial(PackedMaterial packed, TextureProvider textureProvider)
      : super(shaderLibrary['TextFragment']!) {
    final uniform = packed.uniform;
    if (uniform != null) {
      _fragInfo = ByteData.sublistView(uniform, 8);
      _texture = textureProvider
          .get(byteDataToInt(ByteData.sublistView(uniform, 0, 8)));
    }
    if (!isDrawable && !_warnedMissingAtlas) {
      _warnedMissingAtlas = true;
      GpuMapSettings.logger.warn(
          () => 'Labels skipped: a tile was built after its glyph atlas was '
              'unloaded (memory pressure); they return when the tile reloads');
    }
  }

  static bool _warnedMissingAtlas = false;

  /// A monotonic clock for the fade-in, so a wall-clock step (GNSS or
  /// network time sync in the field) can't make the age negative.
  static final _clock = Stopwatch()..start();

  static final _sampler = SamplerOptions(
    minFilter: MinMagFilter.linear,
    magFilter: MinMagFilter.linear,
    mipFilter: MipFilter.linear,
    widthAddressMode: SamplerAddressMode.clampToEdge,
    heightAddressMode: SamplerAddressMode.clampToEdge,
  );

  ByteData? _fragInfo;
  Texture? _texture;

  /// Labels fade in from when their tile is built; the shader reads the age
  /// from the `Age` uniform.
  final int _createdAt = _clock.elapsedMilliseconds;

  late final UniformSlot _fragInfoSlot =
      fragmentShader.getUniformSlot("FragInfo");
  late final UniformSlot _ageSlot = fragmentShader.getUniformSlot("Age");
  late final UniformSlot _sdfSlot = fragmentShader.getUniformSlot('sdf');

  @override
  bool get isDrawable => _fragInfo != null && _texture != null;

  @override
  void bind(RenderPass pass, HostBuffer host) {
    pass.bindUniform(_fragInfoSlot, host.emplace(_fragInfo!));
    // Impeller GLES only supports float uniforms; the shader declares
    // `Age { float milliseconds; }`.
    final age = (_clock.elapsedMilliseconds - _createdAt).toDouble();
    pass.bindUniform(_ageSlot,
        host.emplace(ByteData.sublistView(Float32List.fromList([age]))));
    pass.bindTexture(_sdfSlot, _texture!, sampler: _sampler);
  }
}
