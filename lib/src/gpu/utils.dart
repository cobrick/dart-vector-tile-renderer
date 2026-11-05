import 'dart:typed_data';

import 'package:vector_math/vector_math.dart';

double getScaleFactor(Matrix4 cameraTransform, Matrix4 modelTransform) {
  final matrix = Matrix4.identity()
    ..transposeMultiply(modelTransform)
    ..transposeMultiply(cameraTransform);

  return Vector2(matrix.row0.x, matrix.row1.x).length / _tileSize;
}

const _tileSize = 256;

String formatBytes(int size) {
  if (size < 1000) {
    return "$size B";
  } else if (size < 1000000) {
    return "${(size / 100).truncate() / 10} KB";
  } else if (size < 1000000000) {
    return "${(size / 100000).truncate() / 10} MB";
  } else {
    return "${(size / 100000000).truncate() / 10} GB";
  }
}

ByteData intToByteData(int value) {
  final byteData = ByteData(8);
  byteData.setInt64(0, value, Endian.little);
  return byteData;
}

int byteDataToInt(ByteData byteData) {
  return byteData.getInt64(0, Endian.little);
}
