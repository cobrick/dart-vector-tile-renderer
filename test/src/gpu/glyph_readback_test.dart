import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vector_tile_renderer/src/gpu/text/sdf/glyph_readback.dart';
import 'package:vector_tile_renderer/src/gpu/text/sdf/glyph_stamp.dart';

class _FakeImage {
  int disposeCount = 0;
}

/// Drives [readValidated] from a script. Each read takes the next step of
/// [reads] (the last one repeats): a [GlyphStampResult], `'throw'` for an
/// asynchronous error or `'syncThrow'` for a synchronous one. Render calls
/// listed in [failingRenders] throw.
class _Harness {
  _Harness(
    this.reads, {
    this.failingRenders = const {},
    this.allRendersFail = false,
    this.waitThrows = false,
  });

  final List<Object> reads;
  final Set<int> failingRenders;
  final bool allRendersFail;
  final bool waitThrows;
  final images = <_FakeImage>[];
  var readCount = 0;
  var waitCount = 0;
  var renderCalls = 0;

  Future<StampedRender<_FakeImage>> _render() async {
    final call = renderCalls++;
    if (allRendersFail || failingRenders.contains(call)) {
      throw StateError('render failed');
    }
    final image = _FakeImage();
    images.add(image);
    return StampedRender(image, 7);
  }

  Future<Uint8List> _read(_FakeImage image) {
    final step = reads[readCount < reads.length ? readCount : reads.length - 1];
    readCount++;
    if (step == 'syncThrow') {
      throw StateError('sync read failure');
    }
    if (step == 'throw') {
      return Future.error(StateError('async read failure'));
    }
    return Future.value(Uint8List.fromList([(step as GlyphStampResult).index]));
  }

  GlyphStampVerdict _verdict(Uint8List bytes, int nonce) {
    final result = GlyphStampResult.values[bytes[0]];
    return GlyphStampVerdict(
      result,
      badPixels: result == GlyphStampResult.ok ? 0 : 1,
      totalPixels: 1,
    );
  }

  Future<ValidatedReadback> run() => readValidated<_FakeImage>(
        render: _render,
        read: _read,
        dispose: (image) => image.disposeCount++,
        wait: () async {
          waitCount++;
          if (waitThrows) {
            throw StateError('wait failed');
          }
        },
        verdict: _verdict,
      );
}

void main() {
  const ok = GlyphStampResult.ok;
  const stale = GlyphStampResult.stale;
  const black = GlyphStampResult.black;

  test('a good first read returns at once and disposes the image', () async {
    final harness = _Harness([ok]);
    final result = await harness.run();

    expect(result.bytes, isNotNull);
    expect(result.verdicts, ['ok']);
    expect(result.renders, 1);
    expect(result.retried, isFalse);
    expect(harness.waitCount, 0);
    expect(harness.images.single.disposeCount, 1);
  });

  test('a stale read is read again after one wait', () async {
    final harness = _Harness([stale, ok]);
    final result = await harness.run();

    expect(result.bytes, isNotNull);
    expect(result.verdicts, ['stale', 'ok']);
    expect(result.renders, 1);
    expect(result.retried, isTrue);
    expect(harness.readCount, 2);
    expect(harness.waitCount, 1);
    expect(harness.images.single.disposeCount, 1);
  });

  test('five failed reads trigger one re-render', () async {
    final harness = _Harness([black, black, black, black, black, ok]);
    final result = await harness.run();

    expect(result.bytes, isNotNull);
    expect(result.renders, 2);
    expect(result.verdicts, hasLength(6));
    expect(harness.images.map((it) => it.disposeCount), [1, 1]);
  });

  test('reads that throw, synchronously or not, count as failures', () async {
    final harness = _Harness(['syncThrow', 'throw', ok]);
    final result = await harness.run();

    expect(result.bytes, isNotNull);
    expect(result.verdicts, [
      'throw(Bad state: sync read failure)',
      'throw(Bad state: async read failure)',
      'ok',
    ]);
  });

  test('a repeated error keeps its message only the first time', () async {
    final harness = _Harness(['throw', 'throw', ok]);
    final result = await harness.run();

    expect(result.verdicts, [
      'throw(Bad state: async read failure)',
      'throw',
      'ok',
    ]);
  });

  test('a render that throws is followed by a fresh render', () async {
    final harness = _Harness([ok], failingRenders: {0});
    final result = await harness.run();

    expect(result.bytes, isNotNull);
    expect(result.verdicts, ['render-throw(Bad state: render failed)', 'ok']);
    expect(result.renders, 1);
    expect(result.hadRenderErrors, isTrue);
    expect(harness.renderCalls, 2);
    expect(harness.waitCount, 1);
  });

  test('a re-render that throws after five bad reads is tried again', () async {
    final harness = _Harness(
      [black, black, black, black, black, ok],
      failingRenders: {1},
    );
    final result = await harness.run();

    expect(result.bytes, isNotNull);
    expect(result.verdicts, hasLength(7));
    expect(result.verdicts[5], startsWith('render-throw'));
    expect(result.renders, 2);
    expect(harness.images.map((it) => it.disposeCount), [1, 1]);
  });

  test('when every render throws, nothing is returned or disposed', () async {
    final harness = _Harness([ok], allRendersFail: true);
    final result = await harness.run();

    expect(result.bytes, isNull);
    expect(result.verdicts, hasLength(30));
    expect(
        result.verdicts.every((it) => it.startsWith('render-throw')), isTrue);
    expect(result.renders, 0);
    expect(harness.images, isEmpty);
  });

  test('a wait that throws does not stop the retries', () async {
    final harness = _Harness([stale, ok], waitThrows: true);
    final result = await harness.run();

    expect(result.bytes, isNotNull);
    expect(result.verdicts, ['stale', 'ok']);
    expect(harness.images.single.disposeCount, 1);
  });

  test('gives up after 30 attempts and disposes every image once', () async {
    final harness = _Harness([stale]);
    final result = await harness.run();

    expect(result.bytes, isNull);
    expect(result.verdicts, hasLength(30));
    expect(result.renders, 6);
    expect(harness.waitCount, 29);
    expect(harness.images, hasLength(6));
    expect(harness.images.every((it) => it.disposeCount == 1), isTrue);
  });
}
