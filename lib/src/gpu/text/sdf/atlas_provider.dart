import 'package:collection/collection.dart';

import 'glyph_atlas_data.dart';

class AtlasProvider {
  final _loaded = <String, Set<GlyphAtlas>>{};

  /// Atlases offered to tiles that are being laid out (see [offer]). They
  /// stay loaded for those tiles but are never offered on: only tiles that
  /// use an atlas keep offering it, so one no tile uses can be released.
  final _offered = <String, Set<GlyphAtlas>>{};

  void addLoaded(Set<GlyphAtlas> atlases, String tileID) {
    // A copy: the caller may hold on to [atlases], and this set grows.
    (_loaded[tileID] ??= {}).addAll(atlases);
  }

  AtlasSet forTileID(String tileID) {
    return AtlasSet({}
      ..addAll(_loaded[tileID] ?? {})
      ..addAll(_loaded[""] ?? {}));
  }

  /// Offers tile [tileID], about to be laid out, the atlas with the most
  /// characters per font among those loaded for tiles: usually the font's
  /// newest union, which covers the labels of most tiles that follow. The
  /// offer stays loaded for the tile until [accept] or [unload].
  Set<GlyphAtlas> offer(String tileID) {
    final largest = <String, GlyphAtlas>{};
    for (final atlases in _loaded.values) {
      for (final atlas in atlases) {
        final current = largest[atlas.fontFamily];
        if (current == null ||
            atlas.atlasID.chars.length > current.atlasID.chars.length) {
          largest[atlas.fontFamily] = atlas;
        }
      }
    }
    final offer = largest.values.toSet();
    _offered[tileID] = offer;
    return {...offer};
  }

  /// Tile [tileID] was laid out with its offer: keeps loaded for it the
  /// offered atlases of [fonts], the fonts its labels use.
  void accept(String tileID, Set<String> fonts) {
    final offer = _offered.remove(tileID);
    if (offer == null) {
      return;
    }
    final used = {
      for (final atlas in offer)
        if (fonts.contains(atlas.fontFamily)) atlas,
    };
    if (used.isNotEmpty) {
      addLoaded(used, tileID);
    }
  }

  Set<GlyphAtlas> unload(String tileID) {
    _offered.remove(tileID);
    final out = _loaded[tileID];
    _loaded.remove(tileID);
    return out ?? {};
  }

  /// Unloads the atlases of every tile not in [tileIDs] and returns those
  /// still loaded, offers included.
  Set<GlyphAtlas> unloadWhereNotFound(Set<String> tileIDs) {
    final keysToUnload = _loaded.keys
        .toSet()
        .whereNot((it) => it.isEmpty || tileIDs.contains(it));
    for (final key in keysToUnload) {
      _loaded.remove(key);
    }
    _offered.removeWhere((tileID, _) => !tileIDs.contains(tileID));
    return {
      ..._loaded.values.flattenedToSet,
      ..._offered.values.flattenedToSet,
    };
  }
}
