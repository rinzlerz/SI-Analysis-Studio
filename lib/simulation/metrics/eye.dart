/// Deterministic eye analysis of a simulated receiver waveform.
///
/// The eye is folded from the simulated (not synthesised) waveform using the
/// known transmitted bits. Metrics include only deterministic effects that
/// the simulation contains (ISI from loss and edge rate, reflections, skew).
/// Random jitter, crosstalk and power-supply noise are NOT included.
///
/// * Eye height: min(v at centre | bit = 1) - max(v at centre | bit = 0)
/// * Jitter (DJ pk-pk): spread of threshold-crossing times modulo UI
/// * Eye width: UI - DJ pk-pk
/// * Crossing %: level where rising and falling edges intersect, relative
///   to the mean 0/1 levels at the eye centre
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../model/result.dart';
import 'waveform_metrics.dart';

double _interp(List<double> v, double dt, double t) {
  final x = t / dt;
  final i = x.floor();
  if (i < 0) return v.first;
  if (i >= v.length - 1) return v.last;
  final f = x - i;
  return v[i] * (1 - f) + v[i + 1] * f;
}

double _wrap(double r, double ui) {
  var x = r % ui;
  if (x > ui / 2) x -= ui;
  if (x <= -ui / 2) x += ui;
  return x;
}

/// Returns null when the waveform does not support a meaningful eye.
EyeResult? computeEye({
  required List<double> v,
  required double dt,
  required double ui,
  required List<int> bits,
  required double t0,
  required double delayEstimate,
  required double threshold,
  required double idealEyeHeight,
  required String label,
  int skipBits = 4,
  int pointsPerSegment = 64,
  int maxSegments = 400,
  bool measureCrossing = true,
}) {
  final tEnd = (v.length - 1) * dt;
  final tSkip = t0 + skipBits * ui + delayEstimate;
  final cr = crossings(v, dt, threshold).where((c) => c.time >= tSkip).toList();
  if (cr.length < 4) return null;

  // Recover sampling phase from the crossings.
  final res = cr.map((c) => _wrap(c.time - t0 - delayEstimate, ui)).toList();
  // Circular mean of the residuals.
  var sx = 0.0;
  var sy = 0.0;
  for (final r in res) {
    sx += math.cos(2 * math.pi * r / ui);
    sy += math.sin(2 * math.pi * r / ui);
  }
  final meanRes = math.atan2(sy, sx) / (2 * math.pi) * ui;
  // The crossing phase is only known modulo one UI. Loss, CTLE and RC delay
  // can shift the waveform by more than UI/2, so pick the whole-UI offset
  // that best separates the known 1s from the 0s.
  double separation(double dd) {
    var s1 = 0.0, s0 = 0.0;
    var n1 = 0, n0 = 0;
    for (var k = skipBits; k < bits.length; k++) {
      final tc = t0 + (k + 0.5) * ui + dd;
      if (tc + ui > tEnd) break;
      final x = _interp(v, dt, tc);
      if (bits[k] == 1) {
        s1 += x;
        n1++;
      } else {
        s0 += x;
        n0++;
      }
    }
    if (n1 == 0 || n0 == 0) return -double.infinity;
    return s1 / n1 - s0 / n0;
  }

  var d = delayEstimate + meanRes;
  var bestSep = -double.infinity;
  var bestM = 0;
  for (var m = -6; m <= 6; m++) {
    final sep = separation(d + m * ui);
    if (sep > bestSep) {
      bestSep = sep;
      bestM = m;
    }
  }
  d += bestM * ui;
  final rel = res.map((r) => _wrap(r - meanRes, ui)).toList();
  final jitter = rel.reduce(math.max) - rel.reduce(math.min);

  // Sample at the eye centre.
  final ones = <double>[];
  final zeros = <double>[];
  final segIdx = <int>[];
  for (var k = skipBits; k < bits.length; k++) {
    final tc = t0 + (k + 0.5) * ui + d;
    if (tc + ui > tEnd) break;
    final s = _interp(v, dt, tc);
    (bits[k] == 1 ? ones : zeros).add(s);
    segIdx.add(k);
  }
  if (ones.length < 2 || zeros.length < 2) return null;
  final eyeTop = ones.reduce(math.min);
  final eyeBottom = zeros.reduce(math.max);
  final eyeHeight = eyeTop - eyeBottom;
  final mean1 = ones.reduce((a, b) => a + b) / ones.length;
  final mean0 = zeros.reduce((a, b) => a + b) / zeros.length;

  // Crossing level: where mean rising and falling crossing times coincide.
  double? crossingLevel;
  double? prevDiff;
  double? prevLevel;
  for (var i = 0; measureCrossing && i <= 40; i++) {
    final level = mean0 + (mean1 - mean0) * (0.1 + 0.8 * i / 40);
    final c = crossings(v, dt, level).where((c) => c.time >= tSkip).toList();
    final up = <double>[];
    final down = <double>[];
    for (final x in c) {
      (x.rising ? up : down).add(_wrap(x.time - t0 - d, ui));
    }
    if (up.isEmpty || down.isEmpty) continue;
    final diff = up.reduce((a, b) => a + b) / up.length - down.reduce((a, b) => a + b) / down.length;
    if (prevDiff != null && prevLevel != null && (prevDiff <= 0) != (diff <= 0)) {
      final f = prevDiff / (prevDiff - diff);
      crossingLevel = prevLevel + f * (level - prevLevel);
      break;
    }
    prevDiff = diff;
    prevLevel = level;
  }
  crossingLevel ??= threshold;
  final crossingPct = (crossingLevel - mean0) / (mean1 - mean0) * 100;

  // Folded segments (2 UI each).
  final nSeg = math.min(segIdx.length, maxSegments);
  final seg = Float64List(nSeg * pointsPerSegment);
  var vMin = double.infinity;
  var vMax = -double.infinity;
  for (var s = 0; s < nSeg; s++) {
    final k = segIdx[s];
    final tc = t0 + (k + 0.5) * ui + d;
    for (var p = 0; p < pointsPerSegment; p++) {
      final t = tc - ui + 2 * ui * p / (pointsPerSegment - 1);
      final x = _interp(v, dt, t);
      seg[s * pointsPerSegment + p] = x;
      if (x < vMin) vMin = x;
      if (x > vMax) vMax = x;
    }
  }
  return EyeResult(
    ui: ui,
    segments: seg,
    pointsPerSegment: pointsPerSegment,
    eyeHeight: eyeHeight,
    eyeWidth: math.max(0, ui - jitter),
    crossingPct: crossingPct,
    jitterPkPk: jitter,
    idealEyeHeight: idealEyeHeight,
    vMin: vMin,
    vMax: vMax,
    traceLabel: label,
    eyeTop: eyeTop,
    eyeBottom: eyeBottom,
    phaseDelay: d,
    crossingOffsets: Float64List.fromList(rel),
  );
}
