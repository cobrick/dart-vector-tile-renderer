import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
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

/// Spare bytes at the end of a tile's uniform buffer, more than any of the
/// map shaders' uniform blocks (32 bytes at most).
const _tailPadding = 256;

/// Where each uniform block of [lengths] goes in one buffer, and the
/// buffer's size. Each block starts at a multiple of [alignment] with room
/// for its std140 size (its length rounded up to 16 bytes), and the buffer
/// ends with spare bytes: Impeller's GLES backend reads a block's whole size
/// as the shader declares it, past the data of the last block, and fails
/// the draw (aborting the app) when that leaves the buffer.
@visibleForTesting
({List<int> offsets, int size}) staticUniformLayout(
    List<int> lengths, int alignment) {
  int roundUp(int value, int to) => (value + to - 1) ~/ to * to;
  final offsets = List<int>.filled(lengths.length, 0);
  var end = 0;
  for (var i = 0; i < lengths.length; i++) {
    offsets[i] = roundUp(end, alignment);
    end = offsets[i] + roundUp(lengths[i], 16);
  }
  return (offsets: offsets, size: end + max(alignment, _tailPadding));
}

/// Uploads [uniforms] into one device buffer, each block at an offset the
/// GPU accepts for a uniform binding. If the buffer can't be created, the
/// blocks keep being copied at every draw.
void uploadStaticUniforms(List<StaticUniform> uniforms) {
  if (uniforms.isEmpty) {
    return;
  }
  final (:offsets, :size) = staticUniformLayout(
    [for (final uniform in uniforms) uniform.data.lengthInBytes],
    gpu.gpuContext.minimumUniformByteAlignment,
  );
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
