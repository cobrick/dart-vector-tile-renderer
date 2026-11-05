import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart' as gpu;

import 'gpu_map_settings.dart';

/// A uniform block that stays the same for every draw of a mesh.
///
/// [uploadStaticUniforms] copies a tile's blocks into one device buffer when
/// the tile is built, and each draw binds a view of it. Copying every block
/// into the frame's host buffer at every draw cost a native copy and a
/// buffer view per draw, frame after frame.
class StaticUniform {
  StaticUniform(this.data);

  final ByteData data;
  gpu.BufferView? _view;

  /// The block to bind: its place in the tile's uniform buffer once
  /// uploaded, otherwise a copy in this frame's [host] buffer.
  gpu.BufferView view(gpu.HostBuffer host) => _view ?? host.emplace(data);
}

bool _warnedUploadFailed = false;

/// Uploads [uniforms] into one device buffer, each block at an offset the
/// GPU accepts for a uniform binding. If the buffer can't be created, the
/// blocks keep being copied at every draw.
void uploadStaticUniforms(List<StaticUniform> uniforms) {
  if (uniforms.isEmpty) {
    return;
  }
  final alignment = gpu.gpuContext.minimumUniformByteAlignment;
  final offsets = List<int>.filled(uniforms.length, 0);
  var size = 0;
  for (var i = 0; i < uniforms.length; i++) {
    size = (size + alignment - 1) ~/ alignment * alignment;
    offsets[i] = size;
    size += uniforms[i].data.lengthInBytes;
  }
  final bytes = Uint8List(size);
  for (var i = 0; i < uniforms.length; i++) {
    final data = uniforms[i].data;
    bytes.setRange(offsets[i], offsets[i] + data.lengthInBytes,
        Uint8List.sublistView(data));
  }
  final gpu.DeviceBuffer buffer;
  try {
    buffer =
        gpu.gpuContext.createDeviceBufferWithCopy(ByteData.sublistView(bytes));
  } catch (error) {
    if (!_warnedUploadFailed) {
      _warnedUploadFailed = true;
      GpuMapSettings.logger.warn(() =>
          'Tile uniforms stay in the per-frame buffer: creating their device '
          'buffer ($size bytes) failed: $error');
    }
    return;
  }
  for (var i = 0; i < uniforms.length; i++) {
    uniforms[i]._view = gpu.BufferView(buffer,
        offsetInBytes: offsets[i],
        lengthInBytes: uniforms[i].data.lengthInBytes);
  }
}
