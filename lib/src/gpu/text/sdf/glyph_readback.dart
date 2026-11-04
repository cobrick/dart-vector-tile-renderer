import 'dart:async';
import 'dart:typed_data';

import 'glyph_stamp.dart';

/// A rendered glyph raster of type [I] and the nonce stamped into it.
class StampedRender<I> {
  StampedRender(this.image, this.nonce);

  final I image;
  final int nonce;
}

/// The outcome of [readValidated].
class ValidatedReadback {
  ValidatedReadback(this.bytes, this.verdicts, this.renders);

  /// The validated `rawRgba` bytes, or `null` when no read validated within
  /// the attempt budget.
  final Uint8List? bytes;

  /// One entry per attempt: a [GlyphStampVerdict] as text, or `throw` for a
  /// read that threw and `render-throw` for a render that threw. The first
  /// time a distinct error appears, its message follows in parentheses.
  final List<String> verdicts;

  /// How many renders succeeded.
  final int renders;

  /// Whether more than one attempt was needed.
  bool get retried => verdicts.length > 1;

  /// Whether any render threw, which is not the known read-back race.
  bool get hadRenderErrors =>
      verdicts.any((verdict) => verdict.startsWith('render-throw'));
}

/// Reads back a stamped glyph raster until every pixel carries its nonce.
///
/// - A read that fails validation, or throws, is retried on the same image
///   after [wait]. One re-read was enough for every bad read measured on a
///   Mali-G68 (16 of 86 atlases).
/// - After [rerenderEvery] failed reads of one image, the image is disposed
///   and the glyphs are rendered again under a new nonce. A render that
///   throws is retried on the next attempt.
/// - After [maxAttempts] attempts, renders included, it gives up and returns
///   `null` bytes. A bad atlas is never returned.
///
/// Every rendered image is disposed exactly once, including on success: the
/// returned bytes don't depend on it. A [wait] that throws only shortens the
/// pause.
Future<ValidatedReadback> readValidated<I>({
  required Future<StampedRender<I>> Function() render,
  required Future<Uint8List> Function(I image) read,
  required void Function(I image) dispose,
  required Future<void> Function() wait,
  GlyphStampVerdict Function(Uint8List rgba, int nonce) verdict =
      GlyphStamp.verdict,
  int maxAttempts = 30,
  int rerenderEvery = 5,
}) async {
  final verdicts = <String>[];
  final seenErrors = <String>{};
  String describe(String kind, Object error) {
    final text = error.toString();
    final brief = text.length > 80 ? '${text.substring(0, 80)}...' : text;
    return seenErrors.add(brief) ? '$kind($brief)' : kind;
  }

  var renders = 0;
  var failedReads = 0;
  StampedRender<I>? current;
  try {
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (attempt > 0) {
        try {
          await wait();
        } catch (_) {
          // Only the pause is lost; the next attempt still runs.
        }
      }
      if (current != null && failedReads >= rerenderEvery) {
        final stale = current;
        current = null;
        dispose(stale.image);
      }
      if (current == null) {
        failedReads = 0;
        try {
          current = await render();
          renders++;
        } catch (error) {
          verdicts.add(describe('render-throw', error));
          continue;
        }
      }
      try {
        final bytes = await read(current.image);
        final result = verdict(bytes, current.nonce);
        verdicts.add(result.toString());
        if (result.isOk) {
          return ValidatedReadback(bytes, verdicts, renders);
        }
      } catch (error) {
        verdicts.add(describe('throw', error));
      }
      failedReads++;
    }
    return ValidatedReadback(null, verdicts, renders);
  } finally {
    final last = current;
    current = null;
    if (last != null) {
      dispose(last.image);
    }
  }
}
