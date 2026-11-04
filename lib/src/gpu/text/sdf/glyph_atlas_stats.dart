import 'dart:math' as math;

import '../../../logger.dart';
import '../../gpu_map_settings.dart';
import 'glyph_readback.dart';

/// Glyph atlas counters and the logging policy for them.
///
/// The app routes [GpuMapSettings.logger] warnings to Sentry breadcrumbs on
/// staging, so warnings stay rare. A re-read is expected on some Vulkan GPUs
/// (flutter/flutter#194987; about one atlas in five on a Mali-G68), so:
/// - the first atlas that needed a re-read gets one `log` line;
/// - an atlas that needed a re-render, or hit a render error, gets a `warn`;
/// - a withheld atlas gets a `warn`;
/// - a `log` summary follows every 50 built atlases.
class GlyphAtlasStats {
  int built = 0;
  int totalMs = 0;
  int maxMs = 0;
  int retried = 0;
  int withheld = 0;
  bool _loggedFirstRetry = false;

  /// Records an atlas built from [readback] in [ms], described by [what].
  void onBuilt(String what, ValidatedReadback readback, int ms) {
    built++;
    totalMs += ms;
    maxMs = math.max(maxMs, ms);
    if (readback.retried) {
      retried++;
    }
    if (readback.renders > 1 || readback.hadRenderErrors) {
      warn(() => 'Glyph read-back needed ${readback.renders} renders for '
          '$what; verdicts ${readback.verdicts.join(',')}');
    } else if (readback.retried && !_loggedFirstRetry) {
      _loggedFirstRetry = true;
      log(() => 'Glyph read-back retried, expected on some Vulkan GPUs '
          '(flutter/flutter#194987): $what; verdicts '
          '${readback.verdicts.join(',')}');
    }
    if (built % 50 == 0) {
      log(summary);
    }
  }

  /// Records an atlas that was withheld, because no read validated
  /// ([readback]) or because of an [error].
  void onWithheld(String what, {ValidatedReadback? readback, Object? error}) {
    withheld++;
    if (readback != null) {
      warn(() => 'Glyph atlas withheld: no valid read-back in '
          '${readback.verdicts.length} attempts (${readback.renders} renders) '
          'for $what; verdicts ${readback.verdicts.join(',')}');
    } else {
      warn(() => 'Glyph atlas withheld after an error: $what: $error');
    }
  }

  String summary() => 'Glyph atlases: $built built (avg '
      '${totalMs ~/ math.max(built, 1)} ms, max $maxMs ms), $retried needed '
      'a re-read, $withheld withheld';

  void reset() {
    built = 0;
    totalMs = 0;
    maxMs = 0;
    retried = 0;
    withheld = 0;
    _loggedFirstRetry = false;
  }

  // Logging must never break the atlas generation queue.

  static void log(MessageFunction message) {
    try {
      GpuMapSettings.logger.log(message);
    } catch (_) {}
  }

  static void warn(MessageFunction message) {
    try {
      GpuMapSettings.logger.warn(message);
    } catch (_) {}
  }
}
