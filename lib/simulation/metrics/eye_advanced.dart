/// Level 3 advanced eye analysis: mask test and statistical bathtub.
///
/// Mask: hexagon centred on the eye (height H about the 0 V differential
/// threshold, width W, flat top/bottom of width W/2). Hits = folded
/// waveform samples inside the mask.
///
/// Bathtub (dual-Dirac style, using the simulated crossing distribution):
///   BER(x) = rho_T * [ mean_i Q((x - r_i)/sigma) + mean_i Q((UI + r_i - x)/sigma) ]
/// with r_i the simulated crossing offsets (deterministic jitter), sigma the
/// user-supplied random jitter (rms) and rho_T = 0.5 (random data). The eye
/// width at the target BER is the span where BER < target.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../model/result.dart';

/// Complementary error function (Numerical Recipes erfcc, relative error
/// < 1.2e-7 everywhere, suitable for BER tails).
double erfc(double x) {
  final z = x.abs();
  final t = 1 / (1 + 0.5 * z);
  final r = t *
      math.exp(-z * z -
          1.26551223 +
          t * (1.00002368 +
              t * (0.37409196 +
                  t * (0.09678418 +
                      t * (-0.18628806 +
                          t * (0.27886807 + t * (-1.13520398 + t * (1.48851587 + t * (-0.82215223 + t * 0.17087277)))))))));
  return x >= 0 ? r : 2 - r;
}

double qFunc(double x) => 0.5 * erfc(x / math.sqrt2);

bool _insideHexagon(double x, double y, double w, double h) {
  final ax = x.abs(), ay = y.abs();
  if (ax > w / 2 || ay > h / 2) return false;
  // Sloped edge from (w/4, h/2) to (w/2, 0).
  if (ax <= w / 4) return true;
  final yEdge = h / 2 * (w / 2 - ax) / (w / 4);
  return ay <= yEdge;
}

/// Fills the mask and bathtub fields of [e].
void analyseEye(EyeResult e, {double? maskHeight, double? maskWidthUi, double rj = 0, double targetBer = 1e-12}) {
  final n = e.pointsPerSegment;
  if (maskHeight != null && maskWidthUi != null && maskHeight > 0 && maskWidthUi > 0) {
    final w = maskWidthUi * e.ui;
    var hits = 0, total = 0;
    for (var s = 0; s < e.segmentCount; s++) {
      for (var i = 0; i < n; i++) {
        final t = (-1 + 2 * i / (n - 1)) * e.ui;
        final v = e.segments[s * n + i];
        total++;
        if (_insideHexagon(t, v, w, maskHeight)) hits++;
      }
    }
    e.maskHeight = maskHeight;
    e.maskWidth = w;
    e.maskHits = hits;
    e.maskSamples = total;
  }
  if (rj > 0 && e.crossingOffsets.isNotEmpty) {
    const pts = 201;
    final ph = Float64List(pts);
    final lb = Float64List(pts);
    final r = e.crossingOffsets;
    final ui = e.ui;
    final m = r.length;
    var lo = double.nan, hi = double.nan;
    for (var k = 0; k < pts; k++) {
      final x = ui * k / (pts - 1); // from left crossing (0) to right crossing (UI)
      var a = 0.0, b = 0.0;
      for (final ri in r) {
        a += qFunc((x - ri) / rj);
        b += qFunc((ui + ri - x) / rj);
      }
      final ber = math.max(1e-30, 0.5 * (a + b) / m);
      ph[k] = x - ui / 2;
      lb[k] = math.log(ber) / math.ln10;
      if (ber < targetBer) {
        if (lo.isNaN) lo = ph[k];
        hi = ph[k];
      }
    }
    e.bathtubPhase = ph;
    e.bathtubLog10Ber = lb;
    e.targetBer = targetBer;
    e.eyeWidthAtBer = lo.isNaN ? 0 : hi - lo + ui / (pts - 1);
  }
}
