import 'package:flutter_gpu/gpu.dart';

import '../shaders.dart';
import '../static_uniform.dart';
import '../tile_geometry.dart';
import '../tile_render_data.dart';

class LineGeometry extends TileGeometry {
  late final StaticUniform _uniform;
  late final UniformSlot _lineGeometrySlot =
      vertexShader.getUniformSlot('LineGeometry');

  LineGeometry(PackedGeometry packed) {
    setVertexShader(shaderLibrary["LineVertex"]!);

    _uniform = StaticUniform(packed.uniform!);

    final vertexCount = packed.vertices.lengthInBytes ~/ 32;
    uploadVertexData(packed.vertices, vertexCount, packed.indices,
        indexType: IndexType.int32);
  }

  @override
  List<StaticUniform> get staticUniforms => [_uniform];

  @override
  void bind(RenderPass pass, HostBuffer host, BufferView frameInfo) {
    super.bind(pass, host, frameInfo);
    pass.bindUniform(_lineGeometrySlot, _uniform.view(host));
  }
}
