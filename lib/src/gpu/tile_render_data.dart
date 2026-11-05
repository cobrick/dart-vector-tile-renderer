import 'dart:typed_data';

import 'bucket_unpacker.dart';

class TileRenderData {
  final List<PackedMesh> data = [];

  /// Index of the style layer whose meshes are being added. Meshes record
  /// it so that tiles can be drawn layer by layer.
  int currentLayer = 0;

  void addMesh(PackedMesh mesh) {
    data.add(mesh..layer = currentLayer);
  }

  void addMeshes(Iterable<PackedMesh> meshes) {
    meshes.forEach(addMesh);
  }

  static TileRenderData unpack(Uint8List bytes) {
    final result = TileRenderData();
    final view =
        ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes);

    final meshCount = _readHeader(view);
    int offset = _headerLength;

    for (int i = 0; i < meshCount; i++) {
      final mesh = _readMesh(view, bytes, offset);
      result.data.add(mesh.mesh);
      offset = mesh.nextOffset;
    }

    return result;
  }

  /// The meshes in one list of exactly their packed length.
  ///
  /// Exact on purpose: a list that views a larger buffer (as a growing
  /// `BytesBuilder` returns) sends that whole buffer to the isolate that
  /// receives it, and the spare bytes stay alive with the render data.
  Uint8List pack() {
    var length = _headerLength;
    for (final mesh in data) {
      length += _meshHeaderLength + _meshDataLength(mesh);
    }
    final bytes = Uint8List(length);
    final view = ByteData.sublistView(bytes);

    // Header: the mesh count, then 4 reserved bytes (zero).
    view.setUint32(0, data.length, Endian.little);
    var offset = _headerLength;
    for (final mesh in data) {
      _writeMeshHeader(view, offset, mesh);
      offset = _writeMeshData(bytes, offset + _meshHeaderLength, mesh);
    }
    assert(offset == length);
    return bytes;
  }

  static int _readHeader(ByteData view) {
    return view.getUint32(0, Endian.little);
  }

  static _MeshReadResult _readMesh(ByteData view, Uint8List bytes, int offset) {
    final header = _readMeshHeader(view, offset);
    offset += _meshHeaderLength;

    final meshData = _readMeshData(bytes, offset, header);

    final mesh = PackedMesh(
      PackedGeometry(
        vertices: meshData.vertices,
        indices: meshData.indices,
        uniform: meshData.geometryUniform,
        type: header.geometryType,
      ),
      PackedMaterial(
        uniform: meshData.materialUniform,
        type: header.materialType,
      ),
    )..layer = header.layer;

    return _MeshReadResult(mesh, meshData.nextOffset);
  }

  static _MeshHeader _readMeshHeader(ByteData view, int offset) {
    return _MeshHeader(
      geometryType: GeometryType.values[view.getUint8(offset)],
      materialType: MaterialType.values[view.getUint8(offset + 1)],
      verticesLength: view.getUint32(offset + 2, Endian.little),
      indicesLength: view.getUint32(offset + 6, Endian.little),
      geometryUniformLength: view.getUint32(offset + 10, Endian.little),
      materialUniformLength: view.getUint32(offset + 14, Endian.little),
      layer: view.getUint16(offset + 18, Endian.little),
    );
  }

  static const _meshHeaderLength = 20;

  static _MeshData _readMeshData(
      Uint8List bytes, int offset, _MeshHeader header) {
    final vertices = _readByteDataView(bytes, offset, header.verticesLength);
    offset += header.verticesLength;

    final indices = _readByteDataView(bytes, offset, header.indicesLength);
    offset += header.indicesLength;

    ByteData? geometryUniform;
    if (header.geometryUniformLength > 0) {
      geometryUniform =
          _readByteDataView(bytes, offset, header.geometryUniformLength);
      offset += header.geometryUniformLength;
    }

    ByteData? materialUniform;
    if (header.materialUniformLength > 0) {
      materialUniform =
          _readByteDataView(bytes, offset, header.materialUniformLength);
      offset += header.materialUniformLength;
    }

    return _MeshData(
        vertices, indices, geometryUniform, materialUniform, offset);
  }

  static ByteData _readByteDataView(Uint8List bytes, int offset, int length) {
    return ByteData.view(bytes.buffer, bytes.offsetInBytes + offset, length);
  }

  static const _headerLength = 8;

  static int _meshDataLength(PackedMesh mesh) =>
      mesh.geometry.vertices.lengthInBytes +
      mesh.geometry.indices.lengthInBytes +
      (mesh.geometry.uniform?.lengthInBytes ?? 0) +
      (mesh.material.uniform?.lengthInBytes ?? 0);

  static void _writeMeshHeader(ByteData view, int offset, PackedMesh mesh) {
    // Mesh Header (20 bytes total):
    //   - geometryType: uint8 (1 byte) at offset 0
    //   - materialType: uint8 (1 byte) at offset 1
    //   - verticesLength: uint32 (4 bytes) at offset 2
    //   - indicesLength: uint32 (4 bytes) at offset 6
    //   - geometryUniformLength: uint32 (4 bytes) at offset 10
    //   - materialUniformLength: uint32 (4 bytes) at offset 14
    //   - layer: uint16 (2 bytes) at offset 18, the style layer index
    view
      ..setUint8(offset, mesh.geometry.type.index)
      ..setUint8(offset + 1, mesh.material.type.index)
      ..setUint32(
          offset + 2, mesh.geometry.vertices.lengthInBytes, Endian.little)
      ..setUint32(
          offset + 6, mesh.geometry.indices.lengthInBytes, Endian.little)
      ..setUint32(
          offset + 10, mesh.geometry.uniform?.lengthInBytes ?? 0, Endian.little)
      ..setUint32(
          offset + 14, mesh.material.uniform?.lengthInBytes ?? 0, Endian.little)
      ..setUint16(offset + 18, mesh.layer, Endian.little);
  }

  /// Writes the mesh's data at [offset] and returns the offset after it.
  static int _writeMeshData(Uint8List bytes, int offset, PackedMesh mesh) {
    offset = _writeByteData(bytes, offset, mesh.geometry.vertices);
    offset = _writeByteData(bytes, offset, mesh.geometry.indices);
    final geometryUniform = mesh.geometry.uniform;
    if (geometryUniform != null) {
      offset = _writeByteData(bytes, offset, geometryUniform);
    }
    final materialUniform = mesh.material.uniform;
    if (materialUniform != null) {
      offset = _writeByteData(bytes, offset, materialUniform);
    }
    return offset;
  }

  static int _writeByteData(Uint8List bytes, int offset, ByteData data) {
    final end = offset + data.lengthInBytes;
    bytes.setRange(offset, end, Uint8List.sublistView(data));
    return end;
  }
}

class _MeshReadResult {
  final PackedMesh mesh;
  final int nextOffset;

  _MeshReadResult(this.mesh, this.nextOffset);
}

class _MeshHeader {
  final GeometryType geometryType;
  final MaterialType materialType;
  final int verticesLength;
  final int indicesLength;
  final int geometryUniformLength;
  final int materialUniformLength;
  final int layer;

  _MeshHeader({
    required this.geometryType,
    required this.materialType,
    required this.verticesLength,
    required this.indicesLength,
    required this.geometryUniformLength,
    required this.materialUniformLength,
    required this.layer,
  });
}

class _MeshData {
  final ByteData vertices;
  final ByteData indices;
  final ByteData? geometryUniform;
  final ByteData? materialUniform;
  final int nextOffset;

  _MeshData(this.vertices, this.indices, this.geometryUniform,
      this.materialUniform, this.nextOffset);
}

class PackedMesh {
  final PackedGeometry geometry;
  final PackedMaterial material;

  /// Index of the style layer this mesh draws (set by
  /// [TileRenderData.addMesh]).
  int layer = 0;

  PackedMesh(this.geometry, this.material);
}

class PackedGeometry {
  final ByteData vertices;
  final ByteData indices;
  final ByteData? uniform;
  final GeometryType type;

  PackedGeometry(
      {required this.vertices,
      required this.indices,
      this.uniform,
      required this.type});
}

class PackedMaterial {
  final ByteData? uniform;
  final MaterialType type;

  PackedMaterial({this.uniform, required this.type});
}
