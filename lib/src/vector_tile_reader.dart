import 'dart:typed_data';

import 'package:vector_tile/vector_tile.dart';

import 'mvt_decoder.dart';
import 'profiling.dart';

class VectorTileReader {
  /// Decodes a vector tile. With [layerNames], only the layers it names are
  /// decoded and returned; the others are skipped.
  VectorTile read(Uint8List bytes, {Set<String>? layerNames}) {
    return profileSync('ReadTile', () {
      if (!_isWeb) {
        final tile = decodeMvt(bytes, layerNames: layerNames);
        if (tile != null) {
          return tile;
        }
      }
      // The reference decoder: on the web, where ints are not 64-bit, and
      // for data decodeMvt leaves to it, malformed tiles included (it throws
      // its own errors for those).
      final tile = VectorTile.fromBytes(bytes: bytes);
      if (layerNames == null) {
        return tile;
      }
      return VectorTile(layers: [
        for (final layer in tile.layers)
          if (layerNames.contains(layer.name)) layer,
      ]);
    });
  }
}

const _isWeb = bool.fromEnvironment('dart.library.js_interop');
