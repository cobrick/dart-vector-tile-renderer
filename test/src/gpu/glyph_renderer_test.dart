import 'package:test/test.dart';
import 'package:vector_tile_renderer/src/gpu/text/sdf/atlas_generator.dart';
import 'package:vector_tile_renderer/src/gpu/text/sdf/glyph_atlas_data.dart';
import 'package:vector_tile_renderer/src/gpu/text/sdf/glyph_stamp.dart';

void main() {
  tearDown(GlyphStamp.reset);

  test('an atlas larger than one slice renders and reads back validated',
      () async {
    final chars = String.fromCharCodes(List.generate(40, (i) => 0x41 + i));
    final config = AtlasConfig(
      atlasID: AtlasID(chars: chars, font: 'Roboto Regular%normal'),
    );
    final renderer = GlyphRenderer(
      fontFamily: 'Roboto Regular%normal',
      config: config,
    );

    final result = await renderer.renderGlyphBytes(48);

    expect(chars.length, greaterThan(glyphsPerSlice));
    expect(result.verdicts, ['ok']);
    final cell = 48 + config.sdfPadding * config.renderScale;
    expect(
      result.bytes!.length,
      cell * config.gridCols * cell * config.gridRows * 4,
    );
  });
}
