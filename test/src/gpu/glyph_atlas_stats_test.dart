import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vector_tile_renderer/src/gpu/text/sdf/glyph_atlas_stats.dart';
import 'package:vector_tile_renderer/src/gpu/text/sdf/glyph_readback.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

class _CapturingLogger implements Logger {
  final logs = <String>[];
  final warnings = <String>[];

  @override
  void log(MessageFunction message) => logs.add(message());

  @override
  void warn(MessageFunction message) => warnings.add(message());
}

ValidatedReadback _readback(
  List<String> verdicts, {
  int renders = 1,
  bool valid = true,
}) =>
    ValidatedReadback(valid ? Uint8List(4) : null, verdicts, renders);

void main() {
  const what = 'Roboto Regular%normal, 12 chars';
  late _CapturingLogger logger;
  late GlyphAtlasStats stats;

  setUp(() {
    logger = _CapturingLogger();
    GpuMapSettings.logger = logger;
    stats = GlyphAtlasStats();
  });

  tearDown(() => GpuMapSettings.logger = const Logger.noop());

  test('a clean atlas logs nothing', () {
    stats.onBuilt(what, _readback(['ok']), 30);

    expect(logger.logs, isEmpty);
    expect(logger.warnings, isEmpty);
  });

  test('re-reads are expected: only the first is logged, none is warned', () {
    stats.onBuilt(what, _readback(['stale', 'ok']), 60);
    stats.onBuilt(what, _readback(['partial(256/4096 px)', 'ok']), 60);

    expect(logger.warnings, isEmpty);
    expect(logger.logs, hasLength(1));
    expect(logger.logs.single, contains('verdicts stale,ok'));
  });

  test('an atlas that needed a re-render is warned', () {
    stats.onBuilt(
      what,
      _readback(['black', 'black', 'black', 'black', 'black', 'ok'],
          renders: 2),
      200,
    );

    expect(logger.warnings, hasLength(1));
    expect(logger.warnings.single, contains('needed 2 renders'));
  });

  test('a render error is warned even when the next render succeeded', () {
    stats.onBuilt(
      what,
      _readback(['render-throw(Bad state: GPU unavailable.)', 'ok']),
      90,
    );

    expect(logger.warnings, hasLength(1));
    expect(logger.warnings.single, contains('GPU unavailable'));
  });

  test('a withheld atlas is warned with its verdicts and counted', () {
    stats.onWithheld(
      what,
      readback: _readback(List.filled(30, 'stale'), renders: 6, valid: false),
    );

    expect(logger.warnings, hasLength(1));
    expect(logger.warnings.single, contains('withheld'));
    expect(logger.warnings.single, contains('30 attempts (6 renders)'));
    expect(stats.summary(), contains('1 withheld'));
  });

  test('an atlas withheld after an error is warned with the error', () {
    stats.onWithheld(what, error: StateError('Texture creation failed'));

    expect(logger.warnings.single, contains('Texture creation failed'));
    expect(stats.withheld, 1);
  });

  test('exactly one summary per 50 built atlases', () {
    for (var i = 0; i < 49; i++) {
      stats.onBuilt(what, _readback(['ok']), 10);
    }
    expect(logger.logs, isEmpty);

    stats.onBuilt(what, _readback(['stale', 'ok']), 110);
    expect(logger.logs, hasLength(2)); // the first re-read, then the summary
    expect(
      logger.logs.last,
      'Glyph atlases: 50 built (avg 12 ms, max 110 ms), 1 needed a re-read, '
      '0 withheld',
    );

    for (var i = 0; i < 50; i++) {
      stats.onBuilt(what, _readback(['ok']), 10);
    }
    expect(logger.logs.where((it) => it.startsWith('Glyph atlases:')),
        hasLength(2));
  });
}
