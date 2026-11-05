import 'dart:isolate';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vector_tile_renderer/src/gpu/bucket_unpacker.dart';
import 'package:vector_tile_renderer/src/gpu/text/glyph_collector.dart';
import 'package:vector_tile_renderer/src/gpu/text/sdf/atlas_provider.dart';
import 'package:vector_tile_renderer/src/gpu/text/sdf/glyph_atlas_data.dart';
import 'package:vector_tile_renderer/src/gpu/tile_render_data.dart';
import 'package:vector_tile_renderer/src/themes/light_theme.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../test_logger.dart';
import '../test_tile.dart';

/// An atlas of [font] holding [chars], with plausible metrics for layout.
GlyphAtlas _atlas(String font, String chars) => GlyphAtlas(
      atlasID: AtlasID(font: font, chars: chars),
      atlasWidth: 16 * 32,
      atlasHeight: (chars.length / 16).ceil() * 32,
      cellWidth: 32,
      cellHeight: 32,
      glyphMetrics: {
        for (final c in chars.codeUnits)
          c: GlyphMetrics(
            charCode: c,
            width: 32,
            height: 32,
            glyphWidth: 20,
            glyphHeight: 24,
            glyphTop: 20,
            glyphLeft: 6,
            glyphAdvance: 18,
          ),
      },
      fontFamily: font,
      fontSize: 24,
      colorFormat: 'grayscale',
      sdfRadius: 8,
      gridCols: 16,
    );

/// One atlas per font, holding every glyph of [glyphs].
AtlasSet _covering(Map<String, Set<int>> glyphs) => AtlasSet({
      for (final MapEntry(key: font, value: chars) in glyphs.entries)
        _atlas(font, String.fromCharCodes(chars)),
    });

/// The light theme without its symbol (label) layers.
Theme _withoutLabels() {
  final data = lightThemeData();
  final layers = [
    for (final layer in data['layers'] as List)
      if ((layer as Map)['type'] != 'symbol') layer,
  ];
  return ThemeReader(logger: testLogger).read({...data, 'layers': layers});
}

PreRenderInput _input(AtlasSet atlases, {bool generated = false}) =>
    PreRenderInput.forTesting(atlases, generated: generated);

void main() {
  const font = 'Roboto%normal';
  late Theme theme;
  late Tileset tileset;
  late Map<String, Set<int>> glyphs;

  setUpAll(() async {
    theme = ProvidedThemes.lightTheme(logger: testLogger);
    tileset = Tileset({'openmaptiles': await readTestTile(theme)});
    glyphs = collectGlyphs(theme, tileset, 14);
  });

  group('collectGlyphs', () {
    test('collects the characters of the labels, per font', () {
      expect(glyphs, isNotEmpty);
      for (final MapEntry(key: font, value: chars) in glyphs.entries) {
        expect(font, matches(RegExp(r'^.+%(normal|italic)$')));
        expect(chars, isNotEmpty);
      }
    });

    test('collects nothing for a theme without labels', () {
      expect(collectGlyphs(_withoutLabels(), tileset, 14), isEmpty);
    });
  });

  group('AtlasSet.covers', () {
    final atlases = AtlasSet({_atlas(font, 'ab'), _atlas('Other%normal', 'c')});

    test('is true when an atlas of each font holds every character', () {
      expect(
        atlases.covers({
          font: 'ab'.codeUnits.toSet(),
          'Other%normal': {'c'.codeUnitAt(0)},
        }),
        isTrue,
      );
      expect(atlases.covers(const {}), isTrue);
    });

    test('is false when a character is missing from its font', () {
      expect(atlases.covers({font: 'ac'.codeUnits.toSet()}), isFalse);
      expect(
          atlases.covers({
            'Third%normal': {'a'.codeUnitAt(0)}
          }),
          isFalse);
    });
  });

  group('AtlasProvider', () {
    test('offers the atlas with the most characters per font', () {
      final small = _atlas(font, 'ab');
      final large = _atlas(font, 'abcde');
      final other = _atlas('Other%normal', 'xyz');
      final provider = AtlasProvider()
        ..addLoaded({small}, 't1')
        ..addLoaded({large, other}, 't2');

      expect(provider.offer('t3'), {large, other});
    });

    test(
        'keeps an offer loaded for its tile but never offers it on, so an '
        'atlas no tile uses is released', () {
      final atlas = _atlas(font, 'ab');
      final provider = AtlasProvider()..addLoaded({atlas}, 't1');

      expect(provider.offer('t2'), {atlas});
      // t1 is gone; t2, still being laid out, keeps the atlas loaded.
      expect(provider.unloadWhereNotFound({'t2', 't3'}), {atlas});
      expect(provider.offer('t3'), isEmpty);
      expect(provider.unloadWhereNotFound({'t3'}), isEmpty);
    });

    test('accept keeps the offered atlases of the fonts the tile uses', () {
      final used = _atlas(font, 'ab');
      final unused = _atlas('Other%normal', 'xyz');
      final provider = AtlasProvider()..addLoaded({used, unused}, 't1');
      provider.offer('t2');

      provider.accept('t2', {font});

      expect(provider.forTileID('t2').covers({font: 'ab'.codeUnits.toSet()}),
          isTrue);
      expect(provider.unloadWhereNotFound({'t2'}), {used});
    });

    test('unload drops the offer too', () {
      final provider = AtlasProvider()..addLoaded({_atlas(font, 'ab')}, 't1');
      provider.offer('t2');

      provider.unload('t2');

      expect(provider.unloadWhereNotFound({'t2'}), isEmpty);
    });

    test('addLoaded keeps its own copy of the atlases', () {
      final atlases = {_atlas(font, 'ab')};
      final provider = AtlasProvider()..addLoaded(atlases, 't1');
      provider.addLoaded({_atlas(font, 'cd')}, 't1');

      expect(atlases, hasLength(1));
    });
  });

  group('TilesRenderer.preRender', () {
    test('asks for the glyphs when the atlases lack some', () {
      final output =
          TilesRenderer.preRender(theme, 14, tileset, _input(AtlasSet({})));

      expect(output.renderData, isNull);
      expect(output.glyphs, glyphs);
    });

    test(
        'lays the tile out, labels included, when the atlases hold every '
        'glyph', () {
      final output = TilesRenderer.preRender(
          theme, 14, tileset, _input(_covering(glyphs)));

      expect(_hasLabels(output.renderData!), isTrue);
      expect(output.glyphs, isEmpty);
      expect(output.fonts, glyphs.keys.toSet());
    });

    test(
        'lays the tile out with atlases generated for it, without the labels '
        'they lack', () {
      final output = TilesRenderer.preRender(
          theme, 14, tileset, _input(AtlasSet({}), generated: true));

      expect(_hasLabels(output.renderData!), isFalse);
      expect(output.fonts, isNull);
    });

    test('lays out a tile without labels with no atlases at all', () {
      final output = TilesRenderer.preRender(
          _withoutLabels(), 14, tileset, _input(AtlasSet({})));

      expect(output.renderData, isNotNull);
    });

    test('runs on another isolate, with its input and output sent across',
        () async {
      final input = _input(_covering(glyphs));
      final tileTheme = theme;
      final tileTileset = tileset;

      final output = await Isolate.run(
          () => TilesRenderer.preRender(tileTheme, 14, tileTileset, input));

      expect(_hasLabels(output.renderData!), isTrue);
      expect(output.fonts, glyphs.keys.toSet());
    });
  });
}

/// Whether [renderData] holds any label (text) mesh.
bool _hasLabels(Uint8List renderData) => TileRenderData.unpack(renderData)
    .data
    .any((mesh) => mesh.material.type == MaterialType.text);
