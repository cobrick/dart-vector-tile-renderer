import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart' as gpu;

/// Base class for the tile renderer's geometries: a vertex shader and the
/// vertex (and optional index) buffer it reads.
///
/// The shaders read the tile's model transform and the camera from a
/// `FrameInfo` uniform ({ model_transform, camera_transform,
/// camera_position }), which the render pass emplaces once per tile and
/// passes to [bind].
abstract class TileGeometry {
  late final gpu.Shader vertexShader;
  late final gpu.UniformSlot _frameInfoSlot =
      vertexShader.getUniformSlot('FrameInfo');

  gpu.BufferView? _vertices;
  int _vertexCount = 0;
  gpu.BufferView? _indices;
  gpu.IndexType _indexType = gpu.IndexType.int16;
  int _indexCount = 0;
  bool _indexed = false;

  void setVertexShader(gpu.Shader shader) {
    vertexShader = shader;
  }

  /// Whether there is nothing to draw. An indexed geometry whose index data
  /// is empty (e.g. earcut found no triangles) draws nothing, rather than
  /// its vertices as an unindexed triangle list.
  bool get isEmpty =>
      _vertices == null || (_indexed ? _indexCount : _vertexCount) == 0;

  /// Uploads [vertices] (and [indices], if any) into one host-visible device
  /// buffer, indices right after the vertices.
  void uploadVertexData(
    ByteData vertices,
    int vertexCount,
    ByteData? indices, {
    gpu.IndexType indexType = gpu.IndexType.int16,
  }) {
    if (vertices.lengthInBytes == 0) {
      return;
    }
    final indexBytes = indices?.lengthInBytes ?? 0;
    final buffer = gpu.gpuContext.createDeviceBuffer(
      gpu.StorageMode.hostVisible,
      vertices.lengthInBytes + indexBytes,
    );
    buffer.overwrite(vertices, destinationOffsetInBytes: 0);
    _vertices = gpu.BufferView(
      buffer,
      offsetInBytes: 0,
      lengthInBytes: vertices.lengthInBytes,
    );
    _vertexCount = vertexCount;
    _indexed = indices != null;
    if (indices != null && indexBytes > 0) {
      buffer.overwrite(indices,
          destinationOffsetInBytes: vertices.lengthInBytes);
      _indices = gpu.BufferView(
        buffer,
        offsetInBytes: vertices.lengthInBytes,
        lengthInBytes: indexBytes,
      );
      _indexType = indexType;
      _indexCount = indexBytes ~/ (indexType == gpu.IndexType.int16 ? 2 : 4);
    }
  }

  /// Binds the buffers and the tile's [frameInfo] for the next draw.
  void bind(
      gpu.RenderPass pass, gpu.HostBuffer host, gpu.BufferView frameInfo) {
    pass.bindVertexBuffer(_vertices!);
    final indices = _indices;
    if (indices != null) {
      pass.bindIndexBuffer(indices, _indexType);
    }
    pass.bindUniform(_frameInfoSlot, frameInfo);
  }

  void draw(gpu.RenderPass pass) {
    if (_indexed) {
      pass.drawIndexed(_indexCount);
    } else {
      pass.draw(_vertexCount);
    }
  }
}
