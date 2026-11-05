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

  AtlasGenerator generator(
    AtlasGeneratorFunction generate, {
    String baseChars = '',
    int baseSeedThreshold = 0,
  }) =>
      AtlasGenerator(
        atlasProvider: provider,
        textureProvider: TextureProvider(),
        generate: generate,
        nextFrame: () async {},
        baseChars: baseChars,
        baseSeedThreshold: baseSeedThreshold,
      );

  String atlasCharsFor(String tileID, String char) => provider
      .forTileID(tileID)
      .getAtlasForChar(char.codeUnitAt(0), font)!
      .atlasID
      .chars;

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
      baseChars: '',
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

  group('union atlases', () {
    test(
        'a new atlas holds the base set and every character seen for its '
        'font, so later tiles reuse it', () async {
      final built = <String>[];
      final atlases = generator(
        (id) async {
          built.add(id.chars);
          return _atlas(id);
        },
        baseChars: 'xyz',
      );

      await atlases.loadAtlas(str: 'ab', fontFamily: font, tileID: 't1');
      await atlases.loadAtlas(str: 'by', fontFamily: font, tileID: 't2');
      await atlases.loadAtlas(str: 'ac', fontFamily: font, tileID: 't3');

      expect(built, ['abxyz', 'abcxyz']);
      expect(hasAtlas('t2'), isTrue);
    });

    test('each font keeps its own characters', () async {
      final built = <String>[];
      final atlases = generator(
        (id) async {
          built.add('${id.font}:${id.chars}');
          return _atlas(id);
        },
        baseChars: 'z',
      );

      await atlases.loadAtlas(str: 'ab', fontFamily: 'A%normal', tileID: 't1');
      await atlases.loadAtlas(str: 'c', fontFamily: 'B%normal', tileID: 't2');

      expect(built, ['A%normal:abz', 'B%normal:cz']);
    });

    test(
        'past ${AtlasGenerator.maxAtlasChars} characters a new atlas holds '
        'only the requested ones', () async {
      final built = <String>[];
      final atlases = generator(
        (id) async {
          built.add(id.chars);
          return _atlas(id);
        },
        baseChars: String.fromCharCodes(List.generate(250, (i) => 0x400 + i)),
      );

      await atlases.loadAtlas(str: 'abcdefg', fontFamily: font, tileID: 't1');

      expect(built, ['abcdefg']);
    });

    test(
        'a tile covered by several atlases gets the largest completed one, '
        'and older unions age out with their tiles', () async {
      final built = <String>[];
      final atlases = generator(
        (id) async {
          built.add(id.chars);
          return _atlas(id);
        },
        baseChars: 'xyz',
      );

      await atlases.loadAtlas(str: 'a', fontFamily: font, tileID: 't1');
      await atlases.loadAtlas(str: 'b', fontFamily: font, tileID: 't2');
      await atlases.loadAtlas(str: 'x', fontFamily: font, tileID: 't3');
      expect(built, ['axyz', 'abxyz']);
      expect(atlasCharsFor('t3', 'x'), 'abxyz');

      atlases.unloadWhereNotFound({'t2', 't3'});
      await atlases.loadAtlas(str: 'b', fontFamily: font, tileID: 't4');
      expect(built, ['axyz', 'abxyz']);
      expect(atlasCharsFor('t4', 'b'), 'abxyz');
    });

    test('concurrent misses for one font cost two builds, not one per tile',
        () async {
      final built = <String>[];
      final release = Completer<void>();
      final atlases = generator(
        (id) async {
          built.add(id.chars);
          if (built.length == 1) {
            await release.future;
          }
          return _atlas(id);
        },
        baseChars: 'xyz',
      );

      final requests = [
        atlases.loadAtlas(str: 'ab', fontFamily: font, tileID: 't1'),
        atlases.loadAtlas(str: 'c', fontFamily: font, tileID: 't2'),
        atlases.loadAtlas(str: 'd', fontFamily: font, tileID: 't3'),
      ];
      await Future<void>.delayed(Duration.zero);
      release.complete();
      await Future.wait(requests);

      expect(built, ['abxyz', 'abcdxyz']);
      expect(atlasCharsFor('t2', 'c'), 'abcdxyz');
      expect(atlasCharsFor('t3', 'd'), 'abcdxyz');
    });

    test(
        'a union of exactly ${AtlasGenerator.maxAtlasChars} characters is '
        'still built', () async {
      final built = <String>[];
      final atlases = generator(
        (id) async {
          built.add(id.chars);
          return _atlas(id);
        },
        baseChars: String.fromCharCodes(List.generate(249, (i) => 0x400 + i)),
      );

      await atlases.loadAtlas(str: 'abcdefg', fontFamily: font, tileID: 't1');

      expect(built.single.length, AtlasGenerator.maxAtlasChars);
    });

    test('past the cap a font stays on per-tile atlases and logs it once',
        () async {
      final built = <String>[];
      final atlases = generator(
        (id) async {
          built.add(id.chars);
          return _atlas(id);
        },
        baseChars: String.fromCharCodes(List.generate(250, (i) => 0x400 + i)),
      );

      await atlases.loadAtlas(str: 'abcdefg', fontFamily: font, tileID: 't1');
      await atlases.loadAtlas(str: 'h', fontFamily: font, tileID: 't2');

      expect(built, ['abcdefg', 'h']);
      expect(
        logger.logs.where((it) => it.contains('per-tile atlases')),
        hasLength(1),
      );
    });

    test('a font below the seed threshold keeps a small atlas', () async {
      final built = <String>[];
      final atlases = generator(
        (id) async {
          built.add(id.chars);
          return _atlas(id);
        },
        baseChars: 'xyz',
        baseSeedThreshold: 5,
      );

      await atlases.loadAtlas(str: 'A4', fontFamily: font, tileID: 't1');
      await atlases.loadAtlas(str: 'S1', fontFamily: font, tileID: 't2');
      await atlases.loadAtlas(str: 'D7', fontFamily: font, tileID: 't3');

      expect(built, ['4A', '14AS', '147ADSxyz']);
    });

    test("a withheld union retries with the tile's own characters", () async {
      final built = <String>[];
      final atlases = generator(
        (id) async {
          built.add(id.chars);
          return id.chars == 'ab' ? _atlas(id) : null;
        },
        baseChars: 'xyz',
      );

      await atlases.loadAtlas(str: 'ab', fontFamily: font, tileID: 't1');

      expect(built, ['abxyz', 'ab']);
      expect(atlasCharsFor('t1', 'a'), 'ab');
    });

    test(
        'the default base set covers Polish, Czech, Danish and German, '
        'within the cap', () {
      const letters = 'ąćęłńóśźżĄĆĘŁŃÓŚŹŻ' // Polish
          'áčďéěíňóřšťúůýžÁČĎÉĚÍŇÓŘŠŤÚŮÝŽ' // Czech
          'æøåÆØÅ' // Danish
          'äöüßÄÖÜ' // German
          '0123456789 -.,()„”«»·\u00A0'; // digits and punctuation in labels
      final base = AtlasGenerator.defaultBaseChars;
      for (final char in letters.split('')) {
        expect(base, contains(char), reason: 'missing $char');
      }
      expect(base.length, 214);
      expect(base.length, lessThanOrEqualTo(AtlasGenerator.maxAtlasChars));
    });
  });

  group('loadGlyphs', () {
    test('loads atlases covering every glyph of each font for the tile',
        () async {
      const other = 'Roboto%italic';
      final atlases = generator((id) async => _atlas(id));
      final glyphs = {
        font: 'ab'.codeUnits.toSet(),
        other: 'xy'.codeUnits.toSet(),
      };

      final loaded = await atlases.loadGlyphs(glyphs, 't1');

      expect(AtlasSet(loaded).covers(glyphs), isTrue);
      expect(provider.forTileID('t1').covers(glyphs), isTrue);
      expect(provider.forTileID('t2').covers(glyphs), isFalse);
    });

    test('leaves a withheld atlas out of the result', () async {
      final atlases = generator((id) async => null);

      final loaded = await atlases.loadGlyphs({
        font: {'a'.codeUnitAt(0)},
      }, 't1');

      expect(loaded, isEmpty);
      expect(hasAtlas('t1'), isFalse);
    });

    test('requests at most maxAtlasChars characters per atlas', () async {
      final built = <String>[];
      final atlases = generator((id) async {
        built.add(id.chars);
        return _atlas(id);
      });
      final glyphs = {
        font: {for (var c = 0x100; c < 0x100 + 300; c++) c},
      };

      await atlases.loadGlyphs(glyphs, 't1');

      expect(built, hasLength(2));
      for (final chars in built) {
        expect(chars.length, lessThanOrEqualTo(AtlasGenerator.maxAtlasChars));
      }
      expect(provider.forTileID('t1').covers(glyphs), isTrue);
    });
  });
}

class _ThrowingLogger implements Logger {
  @override
  void log(MessageFunction message) => throw StateError('logger broke');

  @override
  void warn(MessageFunction message) => throw StateError('logger broke');
}
