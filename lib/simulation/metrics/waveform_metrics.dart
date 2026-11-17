/// Measurements on simulated waveforms (Level 2 results).
library;

import 'dart:math' as math;

class Crossing {
  const Crossing(this.time, this.rising);
  final double time;
  final bool rising;
}

/// All crossings of [level] (linear interpolation between samples).
List<Crossing> crossings(List<double> v, double dt, double level, {int from = 0, int? to}) {
  final out = <Crossing>[];
  final end = math.min(to ?? v.length, v.length);
  for (var i = math.max(from, 1); i < end; i++) {
    final a = v[i - 1] - level;
    final b = v[i] - level;
    if ((a < 0 && b >= 0) || (a > 0 && b <= 0)) {
      final f = a / (a - b);
      out.add(Crossing((i - 1 + f) * dt, b > a));
    }
  }
  return out;
}

/// First crossing of [level] in direction [rising] within [t0, t1].
double? firstCrossing(List<double> v, double dt, double level, bool rising, double t0, double t1) {
  final i0 = math.max(1, (t0 / dt).floor());
  final i1 = math.min(v.length, (t1 / dt).ceil() + 1);
  for (var i = i0; i < i1; i++) {
    final a = v[i - 1] - level;
    final b = v[i] - level;
    final hit = rising ? (a < 0 && b >= 0) : (a > 0 && b <= 0);
    if (hit) {
      final t = (i - 1 + a / (a - b)) * dt;
      if (t >= t0 && t <= t1) return t;
    }
  }
  return null;
}

double maxIn(List<double> v, int i0, int i1) {
  var m = -double.infinity;
  for (var i = math.max(0, i0); i < math.min(i1, v.length); i++) {
    if (v[i] > m) m = v[i];
  }
  return m;
}

double minIn(List<double> v, int i0, int i1) {
  var m = double.infinity;
  for (var i = math.max(0, i0); i < math.min(i1, v.length); i++) {
    if (v[i] < m) m = v[i];
  }
  return m;
}

/// An expected transition at the receiver, from the ideal stimulus.
class ExpectedEdge {
  const ExpectedEdge({
    required this.t50,
    required this.rising,
    required this.windowStart,
    required this.windowEnd,
  });

  /// Expected 50 % arrival time at the receiver (s).
  final double t50;
  final bool rising;

  /// Start of the search window (s).
  final double windowStart;

  /// End of the observation window (start of the next edge's arrival) (s).
  final double windowEnd;
}

class EdgeStats {
  EdgeStats({
    required this.riseTime,
    required this.fallTime,
    required this.overshoot,
    required this.undershoot,
    required this.peak,
    required this.trough,
    required this.ringbackHigh,
    required this.ringbackLow,
    required this.settlingTime,
    required this.settledFraction,
    required this.edgesMeasured,
  });

  /// Mean 10-90 % rise time at the receiver (s), NaN if not measurable.
  final double riseTime;
  final double fallTime;

  /// Peak above the settled high level (V, >= 0).
  final double overshoot;

  /// Excursion below the settled low level (V, >= 0).
  final double undershoot;
  final double peak;
  final double trough;

  /// Worst margin min(v) - VIH after rising edges reach VIH (V). Negative
  /// means the waveform rang back into the undefined input region.
  final double ringbackHigh;

  /// Worst margin VIL - max(v) after falling edges (V).
  final double ringbackLow;

  /// Worst settling time to +/-5 % of the swing, from the 50 % crossing (s).
  final double settlingTime;

  /// Fraction of edges that settled before the next edge.
  final double settledFraction;
  final int edgesMeasured;
}

/// Edge measurements given the settled logic levels [vLow]/[vHigh] and the
/// input thresholds [vil]/[vih] (absolute volts).
EdgeStats measureEdges({
  required List<double> v,
  required double dt,
  required double vLow,
  required double vHigh,
  required double vil,
  required double vih,
  required List<ExpectedEdge> edges,
  double settleBand = 0.05,
}) {
  final swing = vHigh - vLow;
  final p10 = vLow + 0.1 * swing;
  final p90 = vLow + 0.9 * swing;
  final p50 = vLow + 0.5 * swing;
  final rises = <double>[];
  final falls = <double>[];
  var rbHigh = double.infinity;
  var rbLow = double.infinity;
  var settleWorst = 0.0;
  var settledCount = 0;
  var measured = 0;
  for (final e in edges) {
    // Search the transition from half an edge-window before the expected time.
    if (e.windowEnd <= e.t50) continue;
    final tStart = math.max(0.0, e.windowStart);
    final tEnd = math.min(e.windowEnd, (v.length - 1) * dt);
    if (tEnd <= tStart) continue;
    measured++;
    final a = firstCrossing(v, dt, e.rising ? p10 : p90, e.rising, tStart, tEnd);
    final b = a == null ? null : firstCrossing(v, dt, e.rising ? p90 : p10, e.rising, a, tEnd);
    if (a != null && b != null) (e.rising ? rises : falls).add(b - a);
    // Ring-back after crossing the input threshold.
    final th = e.rising ? vih : vil;
    final tc = firstCrossing(v, dt, th, e.rising, tStart, tEnd);
    if (tc != null) {
      final i1 = (tEnd / dt).floor();
      // Start after the edge has finished moving (its first extremum), so the
      // edge itself is not mistaken for ring-back.
      var i0 = (tc / dt).ceil() + 1;
      final eps = 1e-6 * swing.abs();
      while (i0 < i1 && i0 < v.length && (e.rising ? v[i0] >= v[i0 - 1] - eps : v[i0] <= v[i0 - 1] + eps)) {
        i0++;
      }
      if (i1 > i0) {
        if (e.rising) {
          rbHigh = math.min(rbHigh, minIn(v, i0, i1) - vih);
        } else {
          rbLow = math.min(rbLow, vil - maxIn(v, i0, i1));
        }
      }
    }
    // Settling to +/- band around the final level.
    final t50 = firstCrossing(v, dt, p50, e.rising, tStart, tEnd);
    if (t50 != null) {
      final target = e.rising ? vHigh : vLow;
      final band = settleBand * swing.abs();
      final i50 = (t50 / dt).ceil();
      final iEnd = (tEnd / dt).floor();
      var lastOut = i50;
      for (var i = i50; i <= iEnd && i < v.length; i++) {
        if ((v[i] - target).abs() > band) lastOut = i;
      }
      final settled = lastOut < iEnd;
      if (settled) settledCount++;
      final ts = (lastOut + 1) * dt - t50;
      settleWorst = math.max(settleWorst, settled ? ts : (tEnd - t50));
    }
  }
  double mean(List<double> x) => x.isEmpty ? double.nan : x.reduce((p, q) => p + q) / x.length;
  final peak = maxIn(v, 0, v.length);
  final trough = minIn(v, 0, v.length);
  return EdgeStats(
    riseTime: mean(rises),
    fallTime: mean(falls),
    overshoot: math.max(0, peak - vHigh),
    undershoot: math.max(0, vLow - trough),
    peak: peak,
    trough: trough,
    ringbackHigh: rbHigh,
    ringbackLow: rbLow,
    settlingTime: settleWorst,
    settledFraction: measured == 0 ? 1 : settledCount / measured,
    edgesMeasured: measured,
  );
}

/// Data-valid analysis at a receiver for timing checks.
///
/// Returns the time at which the waveform last entered the valid region for
/// [bit] (>= vih for 1, <= vil for 0) before [tSample], or null if it is not
/// valid at [tSample].
double? lastValidEntry(List<double> v, double dt, int bit, double vih, double vil, double tSample,
    {double lookBack = double.infinity}) {
  final iS = (tSample / dt).floor();
  if (iS < 0 || iS >= v.length) return null;
  bool valid(double x) => bit == 1 ? x >= vih : x <= vil;
  // Interpolated value at sample time.
  final f = tSample / dt - iS;
  final vs = iS + 1 < v.length ? v[iS] * (1 - f) + v[iS + 1] * f : v[iS];
  if (!valid(vs)) return null;
  final iMin = lookBack.isFinite ? math.max(0, ((tSample - lookBack) / dt).floor()) : 0;
  for (var i = iS; i > iMin; i--) {
    if (!valid(v[i - 1])) {
      final th = bit == 1 ? vih : vil;
      final a = v[i - 1] - th;
      final b = v[i] - th;
      final fr = (a - b).abs() < 1e-30 ? 0.0 : a / (a - b);
      return (i - 1 + fr) * dt;
    }
  }
  return iMin * dt;
}

/// First time after [tSample] at which the waveform leaves the valid region
/// for [bit]; null if it stays valid until [tLimit].
double? firstInvalidExit(List<double> v, double dt, int bit, double vih, double vil, double tSample,
    double tLimit) {
  bool valid(double x) => bit == 1 ? x >= vih : x <= vil;
  final i0 = math.max(1, (tSample / dt).ceil());
  final i1 = math.min(v.length, (tLimit / dt).floor() + 1);
  for (var i = i0; i < i1; i++) {
    if (!valid(v[i])) {
      final th = bit == 1 ? vih : vil;
      final a = v[i - 1] - th;
      final b = v[i] - th;
      final fr = (a - b).abs() < 1e-30 ? 0.0 : a / (a - b);
      return math.max(tSample, (i - 1 + fr) * dt);
    }
  }
  return null;
}

/// Measurements on an arbitrary window, used by the interactive viewer.
class WindowMeasurement {
  WindowMeasurement({
    required this.vMax,
    required this.vMin,
    required this.riseTime,
    required this.fallTime,
  });
  final double vMax;
  final double vMin;
  double get vpp => vMax - vMin;
  final double riseTime;
  final double fallTime;
}

WindowMeasurement measureWindow(List<double> v, double dt, double t0, double t1) {
  final i0 = math.max(0, (t0 / dt).floor());
  final i1 = math.min(v.length, (t1 / dt).ceil() + 1);
  if (i1 - i0 < 2) {
    return WindowMeasurement(vMax: double.nan, vMin: double.nan, riseTime: double.nan, fallTime: double.nan);
  }
  final hi = maxIn(v, i0, i1);
  final lo = minIn(v, i0, i1);
  final s = hi - lo;
  double edge(bool rising) {
    final a = firstCrossing(v, dt, rising ? lo + 0.1 * s : lo + 0.9 * s, rising, i0 * dt, (i1 - 1) * dt);
    if (a == null) return double.nan;
    final b = firstCrossing(v, dt, rising ? lo + 0.9 * s : lo + 0.1 * s, rising, a, (i1 - 1) * dt);
    return b == null ? double.nan : b - a;
  }

  return WindowMeasurement(vMax: hi, vMin: lo, riseTime: edge(true), fallTime: edge(false));
}
