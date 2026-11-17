/// Time-domain transmission-line solver (Level 2 - behavioural).
///
/// Uses the method of characteristics (Branin, 1967), which is exact for a
/// lossless line. Each line end is replaced by a Thevenin source e(t) behind
/// Z0:
///   e1(t) = v2(t - T) + Z0 * i2(t - T)
///   e2(t) = v1(t - T) + Z0 * i1(t - T)
/// where i_k is the current flowing INTO the line at port k. Because e(t)
/// depends only on past values, each end network is solved independently at
/// every time step (one nodal equation per end). Capacitors use trapezoidal
/// companion models.
///
/// Loss: the travelling waves are convolved with the causal minimum-phase
/// impulse response of exp(-alpha(f) L) (see channel_loss.dart).
/// Fractional delays are handled with linear interpolation (dt <= T).
///
/// Reflected-wave diagnostics at the source:
///   backward (reflected) wave arriving at port 1  b1 = e1 / 2
///   forward (incident) wave at port 1              a1 = v1 - b1
library;

import 'dart:typed_data';

import '../termination/termination.dart';

class LineSolution {
  LineSolution({
    required this.vNear,
    required this.vFar,
    required this.incidentNear,
    required this.reflectedNear,
  });

  /// Voltage at the driver end of the line (TX pin).
  final Float64List vNear;

  /// Voltage at the receiver end of the line (RX pin).
  final Float64List vFar;

  /// Forward (incident) wave at the TX pin.
  final Float64List incidentNear;

  /// Backward (reflected) wave arriving at the TX pin.
  final Float64List reflectedNear;
}

class SolverError implements Exception {
  SolverError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Simulates one line driven at port 1 by the open-circuit source [vs]
/// (one sample per [dt]).
LineSolution solveLine({
  required Float64List vs,
  required double dt,
  required double delay,
  required double z0,
  required SourceEnd source,
  required LoadEnd load,
  Float64List? lossImpulse,
}) {
  if (!(z0 > 0)) throw SolverError('Line impedance must be positive.');
  if (!(source.rTotal > 0)) {
    throw SolverError('Driver + series resistance must be greater than 0 ohm.');
  }
  final dSteps = delay / dt;
  if (dSteps < 1 - 1e-9) {
    throw SolverError('Time step must not exceed the line delay.');
  }
  final dInt = dSteps.floor().clamp(1, 1 << 30);
  final frac = (dSteps - dInt).clamp(0.0, 1.0);

  // Combined kernel: loss impulse convolved with linear-interp fractional delay.
  final h = lossImpulse ?? (Float64List(1)..[0] = 1.0);
  final g = Float64List(h.length + 1);
  for (var k = 0; k < h.length; k++) {
    g[k] += h[k] * (1 - frac);
    g[k + 1] += h[k] * frac;
  }
  var kLen = g.length;
  while (kLen > 1 && g[kLen - 1] == 0) {
    kLen--;
  }

  // Pre-roll with the idle source level so lossy lines settle to their DC
  // state before t = 0.
  final pre = lossImpulse == null ? 0 : 6 * dInt + kLen;
  final nOut = vs.length;
  final n = nOut + pre;

  final gs = 1 / source.rTotal;
  final y0 = 1 / z0;
  final gr = load.rIn.isFinite ? 1 / load.rIn : 0.0;
  final gt = load.rTerm.isFinite ? 1 / load.rTerm : 0.0;
  final gc = load.cIn > 0 ? 2 * load.cIn / dt : 0.0;
  final hasAc = load.hasAc;
  final rcAc = hasAc ? dt / (2 * load.cAc) : 0.0;
  final gAc = hasAc ? 1 / (load.rAc + rcAc) : 0.0;
  final vtt = load.vtt;
  final den1 = gs + y0;
  final den2 = y0 + gr + gt + gc + gAc;

  final vs0 = vs.isEmpty ? 0.0 : vs[0];
  final vdc = dcLineVoltage(vs0, source, load);
  final i1dc = (vs0 - vdc) * gs;
  final f1Init = vdc + z0 * i1dc;
  final f2Init = vdc - z0 * i1dc;

  final f1 = Float64List(n); // v1 + Z0 i1
  final f2 = Float64List(n); // v2 + Z0 i2
  final vNear = Float64List(nOut);
  final vFar = Float64List(nOut);
  final inc = Float64List(nOut);
  final refl = Float64List(nOut);

  // Quiet-period acceleration: when the source and both travelling waves
  // have been constant for longer than delay + kernel length, the incoming
  // waves cannot change, so the convolution is skipped.
  const eps = 1e-9;
  final quietNeed = dInt + kLen + 1;
  var quiet = 0;
  var e1Last = 0.0;
  var e2Last = 0.0;
  var srcPrev = double.nan;
  var f1Prev = f1Init;
  var f2Prev = f2Init;

  var vPrev = vdc;
  var icPrev = 0.0;
  var vHist = vdc; // AC branch capacitor history (no DC current)

  for (var i = 0; i < n; i++) {
    final src = i < pre ? vs0 : vs[i - pre];
    // Delayed + filtered incoming waves.
    var e1 = e1Last;
    var e2 = e2Last;
    if (quiet < quietNeed) {
      e1 = 0.0;
      e2 = 0.0;
      final base = i - dInt;
      for (var k = 0; k < kLen; k++) {
        final idx = base - k;
        final gk = g[k];
        if (idx >= 0) {
          e1 += gk * f2[idx];
          e2 += gk * f1[idx];
        } else {
          e1 += gk * f2Init;
          e2 += gk * f1Init;
        }
      }
      e1Last = e1;
      e2Last = e2;
    }
    // Port 1 (driver).
    final v1 = (src * gs + e1 * y0) / den1;
    final i1 = (v1 - e1) * y0;
    f1[i] = v1 + z0 * i1;
    // Port 2 (receiver).
    final v2 = (e2 * y0 + vtt * gt + gc * vPrev + icPrev + gAc * vHist) / den2;
    final i2 = (v2 - e2) * y0;
    f2[i] = v2 + z0 * i2;
    if (src == srcPrev && (f1[i] - f1Prev).abs() < eps && (f2[i] - f2Prev).abs() < eps) {
      quiet++;
    } else {
      quiet = 0;
    }
    srcPrev = src;
    f1Prev = f1[i];
    f2Prev = f2[i];
    if (gc > 0) {
      icPrev = gc * (v2 - vPrev) - icPrev;
    }
    vPrev = v2;
    if (hasAc) {
      final iAc = (v2 - vHist) * gAc;
      final vc = vHist + rcAc * iAc;
      vHist = vc + rcAc * iAc;
    }
    if (i >= pre) {
      final o = i - pre;
      vNear[o] = v1;
      vFar[o] = v2;
      refl[o] = 0.5 * e1;
      inc[o] = v1 - 0.5 * e1;
    }
  }
  return LineSolution(vNear: vNear, vFar: vFar, incidentNear: inc, reflectedNear: refl);
}
