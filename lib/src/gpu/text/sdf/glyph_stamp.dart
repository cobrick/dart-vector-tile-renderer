import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// A per-render nonce carried in the green and blue channels of every pixel
/// of a glyph raster, used to validate its CPU read-back.
///
/// On Impeller Vulkan, `Image.toByteData` right after `Picture.toImage` can
/// return zero, stale (an earlier same-size render) or torn pixels. The copy's
/// barrier isn't ordered after the render (flutter/flutter#194987), and Mali
/// GPUs show it. The glyph raster is white with black glyphs, and the SDF
/// passes read only the red channel, so the nonce can sit in green and blue
/// without changing the atlas. A read-back is accepted only when every pixel
/// carries this render's nonce, and no nonce of the previous 83 renders
/// passes for it.
class GlyphStamp {
  GlyphStamp._();

  static int _last = 0;

  /// Nonces step by 3, so consecutive renders differ by 3 in green and a read
  /// of a recent earlier render fails [verdict]'s ±1 tolerance. The nearest
  /// earlier nonce that would pass is 84 renders back.
  static const _step = 3;

  /// The next nonce: a 16-bit value with green as the low byte and blue as
  /// the high byte.
  ///
  /// It never comes within ±1 of opaque black or white in both channels, so
  /// an unstamped black or white raster can't pass [verdict].
  static int next() {
    do {
      _last = (_last + _step) & 0xFFFF;
    } while (_isReserved(_last));
    return _last;
  }

  static bool _isReserved(int nonce) {
    final g = nonce & 0xFF;
    final b = nonce >> 8;
    return (g <= 1 && b <= 1) || (g >= 0xFE && b >= 0xFE);
  }

  /// Restarts the [next] sequence.
  @visibleForTesting
  static void reset() => _last = 0;

  /// A colour filter that keeps red and alpha and sets green and blue to
  /// [nonce] on every pixel. Translations are in 0..255 units.
  ///
  /// Unlike a text colour, it also stamps colour glyphs such as emoji.
  static ui.ColorFilter filter(int nonce) => ui.ColorFilter.matrix(<double>[
        1, 0, 0, 0, 0, //
        0, 0, 0, 0, (nonce & 0xFF).toDouble(), //
        0, 0, 0, 0, ((nonce >> 8) & 0xFF).toDouble(), //
        0, 0, 0, 1, 0, //
      ]);

  /// Checks a `rawRgba` read-back of a raster stamped with [nonce].
  ///
  /// Every pixel must be opaque and carry the nonce, within ±1 per channel
  /// (float-to-UNORM conversion may round either way). Checking every pixel
  /// matters: a racing read can leave single stale 16–32 px tiles that a
  /// check of a few pixels would miss. An empty buffer never passes.
  static GlyphStampVerdict verdict(Uint8List rgba, int nonce) {
    final total = rgba.lengthInBytes ~/ 4;
    if (total == 0) {
      return const GlyphStampVerdict(
        GlyphStampResult.partial,
        badPixels: 0,
        totalPixels: 0,
      );
    }
    if (_allExact(rgba, nonce, total)) {
      return GlyphStampVerdict(
        GlyphStampResult.ok,
        badPixels: 0,
        totalPixels: total,
      );
    }
    return _classify(rgba, nonce, total);
  }

  /// The fast path for the usual case: every pixel exactly (any, G, B, 255),
  /// compared a 32-bit word at a time.
  static bool _allExact(Uint8List rgba, int nonce, int total) {
    if (rgba.offsetInBytes % 4 != 0 || Endian.host != Endian.little) {
      return false;
    }
    final words = rgba.buffer.asUint32List(rgba.offsetInBytes, total);
    // Little-endian words of R, G, B, A bytes: R | G << 8 | B << 16 | A << 24.
    final want =
        0xFF000000 | (((nonce >> 8) & 0xFF) << 16) | ((nonce & 0xFF) << 8);
    for (var i = 0; i < words.length; i++) {
      if ((words[i] & 0xFFFFFF00) != want) {
        return false;
      }
    }
    return true;
  }

  static GlyphStampVerdict _classify(Uint8List rgba, int nonce, int total) {
    final wantG = nonce & 0xFF;
    final wantB = (nonce >> 8) & 0xFF;
    final data = ByteData.sublistView(rgba);
    var bad = 0;
    var zero = 0;
    var other = -1;
    var oneOther = true;
    for (var i = 0; i < total; i++) {
      final v = data.getUint32(i * 4, Endian.little);
      final a = v >>> 24;
      final g = (v >>> 8) & 0xFF;
      final b = (v >>> 16) & 0xFF;
      if (a == 0xFF && (g - wantG).abs() <= 1 && (b - wantB).abs() <= 1) {
        continue;
      }
      bad++;
      if (v == 0) {
        zero++;
        continue;
      }
      final gb = a == 0xFF ? g | (b << 8) : -2;
      if (other == -1) {
        other = gb;
      } else if (other != gb) {
        oneOther = false;
      }
    }
    final GlyphStampResult result;
    if (bad == 0) {
      result = GlyphStampResult.ok;
    } else if (zero == total) {
      result = GlyphStampResult.black;
    } else if (bad == total && zero == 0 && oneOther && other >= 0) {
      result = GlyphStampResult.stale;
    } else {
      result = GlyphStampResult.partial;
    }
    return GlyphStampVerdict(result, badPixels: bad, totalPixels: total);
  }
}

/// How a read-back compares with the nonce of its render.
enum GlyphStampResult {
  /// Every pixel carries the nonce.
  ok,

  /// Every pixel is zero.
  black,

  /// Every pixel carries one other render's nonce.
  stale,

  /// A mix: torn, partly zero, or from several renders.
  partial,
}

/// The result of [GlyphStamp.verdict], with the number of bad pixels.
@immutable
class GlyphStampVerdict {
  const GlyphStampVerdict(
    this.result, {
    required this.badPixels,
    required this.totalPixels,
  });

  final GlyphStampResult result;
  final int badPixels;
  final int totalPixels;

  bool get isOk => result == GlyphStampResult.ok;

  @override
  String toString() => result == GlyphStampResult.partial
      ? 'partial($badPixels/$totalPixels px)'
      : result.name;
}
