import 'dart:async';

import 'package:test/test.dart';
import 'package:vector_tile_renderer/src/gpu/text/sdf/atlas_generator.dart';
import 'package:vector_tile_renderer/src/gpu/text/sdf/atlas_provider.dart';
import 'package:vector_tile_renderer/src/gpu/text/sdf/glyph_atlas_data.dart';
import 'package:vector_tile_renderer/src/gpu/texture_provider.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

class _CapturingLogger implements Logger {
  final logs = <String>[];
  final warnings = <String>[];

  @override
  void log(MessageFunction message) => logs.add(message());

  @override
  void warn(MessageFunction message) => warnings.add(message());
}

GlyphAtlas _atlas(AtlasID id) => GlyphAtlas(
      atlasID: id,
      atlasWidth: 1,
      atlasHeight: 1,
      cellWidth: 1,
      cellHeight: 1,
      glyphMetrics: const {},
      fontFamily: id.font,
      fontSize: 24,
      colorFormat: 'grayscale',
      sdfRadius: 16,
      gridCols: 1,
    );

void main() {
  const font = 'Roboto%normal';
  late _CapturingLogger logger;
  late AtlasProvider provider;

  setUp(() {
    logger = _CapturingLogger();
    GpuMapSettings.logger = logger;
    provider = AtlasProvider();
  });

  tearDown(() {
    GpuMapSettings.logger = const Logger.noop();
    AtlasGenerator.resetForTesting();
  });

  AtlasGenerator generator(AtlasGeneratorFunction generate) => AtlasGenerator(
        atlasProvider: provider,
        textureProvider: TextureProvider(),
        generate: generate,
        nextFrame: () async {},
      );

  bool hasAtlas(String tileID) => !provider.forTileID(tileID).isEmpty;

  test('a built atlas is added for the tile', () async {
    final atlases = generator((id) async => _atlas(id));

    await atlases.loadAtlas(str: 'ab', fontFamily: font, tileID: 't1');

    expect(
      provider.forTileID('t1').getAtlasForChar('a'.codeUnitAt(0), font),
      isNotNull,
    );
    expect(logger.warnings, isEmpty);
  });

  test(
      'a throwing generator withholds the atlas with one warning, and the '
      'next request generates it again', () async {
    var calls = 0;
    final atlases = generator((id) async {
      calls++;
      if (calls == 1) {
        throw StateError('createTexture failed');
      }
      return _atlas(id);
    });

    await atlases.loadAtlas(str: 'ab', fontFamily: font, tileID: 't1');
    expect(hasAtlas('t1'), isFalse);
    expect(logger.warnings, hasLength(1));
    expect(logger.warnings.single, contains('withheld'));
    expect(logger.warnings.single, contains('createTexture failed'));

    await atlases.loadAtlas(str: 'ab', fontFamily: font, tileID: 't1');
    expect(calls, 2);
    expect(hasAtlas('t1'), isTrue);
  });

  test('a withheld (null) atlas is not added and is generated again next time',
      () async {
    var calls = 0;
    final atlases = generator((id) async => ++calls == 1 ? null : _atlas(id));

    await atlases.loadAtlas(str: 'ab', fontFamily: font, tileID: 't1');
    expect(hasAtlas('t1'), isFalse);

    await atlases.loadAtlas(str: 'ab', fontFamily: font, tileID: 't1');
    expect(calls, 2);
    expect(hasAtlas('t1'), isTrue);
  });

  test('every request waiting on a failing atlas completes', () async {
    final release = Completer<void>();
    final atlases = generator((id) async {
      await release.future;
      throw StateError('boom');
    });

    final first = atlases.loadAtlas(str: 'ab', fontFamily: font, tileID: 't1');
    // 'a' is covered by the in-flight 'ab' atlas, so it waits on the same one.
    final second = atlases.loadAtlas(str: 'a', fontFamily: font, tileID: 't2');
    release.complete();
    await Future.wait([first, second]);

    expect(hasAtlas('t1'), isFalse);
    expect(hasAtlas('t2'), isFalse);
  });

  test('the queue keeps generating after a failure', () async {
    final atlases = generator((id) async {
      if (id.chars == 'ab') {
        throw StateError('boom');
      }
      return _atlas(id);
    });

    await atlases.loadAtlas(str: 'ab', fontFamily: font, tileID: 't1');
    await atlases.loadAtlas(str: 'cd', fontFamily: font, tileID: 't2');

    expect(hasAtlas('t1'), isFalse);
    expect(hasAtlas('t2'), isTrue);
  });

  test(
      'a frame wait that throws still completes the request, warns once, '
      'and keeps the queue going', () async {
    var frames = 0;
    final atlases = AtlasGenerator(
      atlasProvider: provider,
      textureProvider: TextureProvider(),
      generate: (id) async => _atlas(id),
      nextFrame: () async {
        if (++frames == 1) {
          throw StateError('frame failed');
        }
      },
    );

    await atlases.loadAtlas(str: 'ab', fontFamily: font, tileID: 't1');
    await atlases.loadAtlas(str: 'cd', fontFamily: font, tileID: 't2');

    expect(hasAtlas('t1'), isTrue);
    expect(hasAtlas('t2'), isTrue);
    expect(
      logger.warnings.where((it) => it.contains('queue error')),
      hasLength(1),
    );
  });

  test('a logger that throws cannot break the queue', () async {
    GpuMapSettings.logger = _ThrowingLogger();
    final atlases = generator((id) async {
      if (id.chars == 'ab') {
        throw StateError('boom');
      }
      return _atlas(id);
    });

    await atlases.loadAtlas(str: 'ab', fontFamily: font, tileID: 't1');
    await atlases.loadAtlas(str: 'cd', fontFamily: font, tileID: 't2');

    expect(hasAtlas('t2'), isTrue);
  });
}

class _ThrowingLogger implements Logger {
  @override
  void log(MessageFunction message) => throw StateError('logger broke');

  @override
  void warn(MessageFunction message) => throw StateError('logger broke');
}
