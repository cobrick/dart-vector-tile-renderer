import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:test/test.dart';
import 'package:vector_tile_renderer/src/gpu/text/sdf/glyph_stamp.dart';

/// [pixels] opaque pixels with red [r] and [nonce] in green and blue.
Uint8List _stamped(int pixels, int nonce, {int r = 255}) {
  final out = Uint8List(pixels * 4);
  for (var i = 0; i < pixels; i++) {
    out[i * 4] = r;
    out[i * 4 + 1] = nonce & 0xFF;
    out[i * 4 + 2] = (nonce >> 8) & 0xFF;
    out[i * 4 + 3] = 255;
  }
  return out;
}

void main() {
  setUp(GlyphStamp.reset);
  tearDown(GlyphStamp.reset);

  group('GlyphStamp.next', () {
    bool reserved(int n) {
      final g = n & 0xFF;
      final b = n >> 8;
      return (g <= 1 && b <= 1) || (g >= 0xFE && b >= 0xFE);
    }

    List<int> cycle() => [for (var i = 0; i < 65528; i++) GlyphStamp.next()];

    test('cycles through 65528 nonces, none near black or white', () {
      final nonces = cycle();
      expect(nonces.toSet(), hasLength(65528));
      expect(nonces.where(reserved), isEmpty);
      expect(GlyphStamp.next(), nonces.first);
    });

    test('no nonce of the previous 83 renders validates for the current one',
        () {
      final nonces = cycle();
      final px = Uint8List(4);
      for (var i = 0; i < nonces.length; i++) {
        for (var back = 1; back <= 83; back++) {
          final old = nonces[(i - back) % nonces.length];
          px
            ..[0] = 255
            ..[1] = old & 0xFF
            ..[2] = old >> 8
            ..[3] = 255;
          if (GlyphStamp.verdict(px, nonces[i]).isOk) {
            fail('nonce ${nonces[i]} accepts the one $back renders back');
          }
        }
      }
    });

    test('an unstamped white or opaque black raster never validates', () {
      final white = Uint8List.fromList([255, 255, 255, 255]);
      final black = Uint8List.fromList([0, 0, 0, 255]);
      for (final nonce in cycle()) {
        expect(GlyphStamp.verdict(white, nonce).isOk, isFalse);
        expect(GlyphStamp.verdict(black, nonce).isOk, isFalse);
      }
    });
  });

  group('GlyphStamp.verdict', () {
    const nonce = 0x1234;

    test('is ok when every pixel carries the nonce, glyph or background', () {
      final px = _stamped(64, nonce);
      for (var i = 0; i < 32; i++) {
        px[i * 4] = 0; // black glyph pixels: red 0, same green and blue
      }
      expect(GlyphStamp.verdict(px, nonce).result, GlyphStampResult.ok);
    });

    test('accepts ±1 per channel', () {
      final px = _stamped(4, nonce);
      px[1] = 0x35; // green +1
      px[6] = 0x11; // blue −1
      expect(GlyphStamp.verdict(px, nonce).isOk, isTrue);
    });

    test('rejects a transparent pixel even with the right green and blue', () {
      final px = _stamped(4, nonce);
      px[3] = 0;
      expect(GlyphStamp.verdict(px, nonce).isOk, isFalse);
    });

    test('never accepts an empty buffer', () {
      expect(GlyphStamp.verdict(Uint8List(0), nonce).isOk, isFalse);
    });

    test('accepts an odd-offset view through the slow path', () {
      final backing = Uint8List(4 * 4 + 1);
      final view = Uint8List.sublistView(backing, 1);
      view.setAll(0, _stamped(4, nonce));
      expect(GlyphStamp.verdict(view, nonce).isOk, isTrue);
    });

    test('is black when every pixel is zero', () {
      expect(
        GlyphStamp.verdict(Uint8List(64 * 4), nonce).result,
        GlyphStampResult.black,
      );
    });

    test('is stale when every pixel carries one other nonce', () {
      expect(
        GlyphStamp.verdict(_stamped(64, 0x1200), nonce).result,
        GlyphStampResult.stale,
      );
    });

    test('is partial for one stale 16×16 tile inside a good image', () {
      const width = 64;
      final px = _stamped(width * width, nonce);
      for (var y = 24; y < 40; y++) {
        for (var x = 24; x < 40; x++) {
          final i = (y * width + x) * 4;
          px[i + 1] = 0x00;
          px[i + 2] = 0x12;
        }
      }
      final verdict = GlyphStamp.verdict(px, nonce);
      expect(verdict.result, GlyphStampResult.partial);
      expect(verdict.badPixels, 256);
      expect(verdict.toString(), 'partial(256/4096 px)');
    });

    test('is partial when only part of the image is zero', () {
      final px = _stamped(64, nonce);
      px.fillRange(0, 32 * 4, 0);
      expect(
        GlyphStamp.verdict(px, nonce).result,
        GlyphStampResult.partial,
      );
    });

    test('is partial when pixels carry two other nonces', () {
      final px = _stamped(64, 0x1200);
      px.setRange(0, 32 * 4, _stamped(32, 0x1100));
      expect(
        GlyphStamp.verdict(px, nonce).result,
        GlyphStampResult.partial,
      );
    });
  });

  group('GlyphStamp.filter', () {
    test('keeps red and alpha and stamps green and blue on every pixel',
        () async {
      const nonce = 0xA5C3;
      const bounds = ui.Rect.fromLTWH(0, 0, 8, 4);
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.saveLayer(
        bounds,
        ui.Paint()..colorFilter = GlyphStamp.filter(nonce),
      );
      canvas.drawRect(bounds, ui.Paint()..color = const ui.Color(0xFFFFFFFF));
      canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, 4, 4),
        ui.Paint()..color = const ui.Color(0xFF000000),
      );
      canvas.restore();
      final picture = recorder.endRecording();
      final image = await picture.toImage(8, 4);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      picture.dispose();

      final px = data!.buffer.asUint8List();
      expect(px.sublist(0, 4), [0, 0xC3, 0xA5, 255]); // black glyph pixel
      expect(px.sublist(7 * 4, 8 * 4), [255, 0xC3, 0xA5, 255]); // background
      expect(GlyphStamp.verdict(px, nonce).isOk, isTrue);
    });
  });
}
