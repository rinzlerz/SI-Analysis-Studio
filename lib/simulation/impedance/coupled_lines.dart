/// Edge-coupled line even/odd-mode parameters (Level 1 - analytical).
///
/// * Coupled microstrip: Kirschning & Jansen (1984) quasi-static model,
///   valid for 0.1 <= W/h <= 10, 0.1 <= s/h <= 10, 1 <= er <= 18 (accuracy
///   ~1 %). The finite-thickness correction (Jansen) is applied when
///   s > 20 t; otherwise Z is scaled by the single-line Hammerstad-Jensen
///   thickness ratio (approximation).
/// * Coupled stripline: Cohn's exact zero-thickness solution
///     Z0e,o = (30 pi / sqrt(er)) K(k'e,o) / K(ke,o)
///     ke = tanh(pi W / 2b) tanh(pi (W+S) / 2b)
///     ko = tanh(pi W / 2b) coth(pi (W+S) / 2b)
///   scaled by the Wheeler thickness ratio. Offset striplines use the
///   symmetric equivalent b = h1 + h2 + t.
///
///   Zdiff = 2 Zodd,  Zcommon = Zeven / 2.
library;

import 'dart:math' as math;

import '../common/physics.dart';
import 'impedance.dart';

class CoupledResult {
  const CoupledResult({
    required this.zEven,
    required this.zOdd,
    required this.eeffEven,
    required this.eeffOdd,
    required this.method,
  });

  final double zEven;
  final double zOdd;
  final double eeffEven;
  final double eeffOdd;
  final String method;

  double get zDiff => 2 * zOdd;
  double get zCommon => zEven / 2;

  /// Backward (near-end) crosstalk coefficient for matched lines.
  double get kBackward => (zEven - zOdd) / (2 * (zEven + zOdd));
}

double _ab(double u, double er, void Function(double a, double b) out) {
  final a = 1 +
      math.log((math.pow(u, 4) + math.pow(u / 52, 2)) / (math.pow(u, 4) + 0.432)) / 49 +
      math.log(1 + math.pow(u / 18.1, 3)) / 18.7;
  final b = 0.564 * math.pow((er - 0.9) / (er + 3), 0.053);
  out(a, b);
  return 0;
}

double _erHJ(double u, double er) {
  late double a, b;
  _ab(u, er, (x, y) {
    a = x;
    b = y;
  });
  return (er + 1) / 2 + (er - 1) / 2 * math.pow(1 + 10 / u, -a * b);
}

double _zlHJ(double u) {
  final fu = 6 + (2 * math.pi - 6) * math.exp(-math.pow(30.666 / u, 0.7528));
  return eta0 / 2 / math.pi * math.log(fu / u + math.sqrt(1 + (2 / u) * (2 / u)));
}

/// Kirschning-Jansen coupled microstrip (port of the published equations).
CoupledResult coupledMicrostripKJ({
  required double w,
  required double h,
  required double s,
  required double t,
  required double er,
}) {
  final u = w / h;
  final g = s / h;
  var ue = u;
  var uo = u;
  var thicknessApplied = false;
  if (t > 0 && s > 20 * t) {
    var dW = 0.0;
    if (u >= 1 / math.pi / 2 && 1 / math.pi / 2 > 2 * t / h) {
      dW = t * (1 + math.log(2 * h / t)) / math.pi;
    } else if (w > 2 * t) {
      dW = t * (1 + math.log(4 * math.pi * w / t)) / math.pi;
    }
    final dt = 2 * t * h / s / er;
    final we = w + dW * (1 - 0.5 * math.exp(-0.69 * dW / dt));
    final wo = we + dt;
    ue = we / h;
    uo = wo / h;
    thicknessApplied = true;
  }
  // Even-mode effective permittivity.
  final v = ue * (20 + g * g) / (10 + g * g) + g * math.exp(-g);
  final eeffE = _erHJ(v, er);
  // Odd-mode effective permittivity.
  final eeff = _erHJ(uo, er);
  final d = 0.593 + 0.694 * math.exp(-0.562 * uo);
  final bo = 0.747 * er / (0.15 + er);
  final co = bo - (bo - 0.207) * math.exp(-0.414 * uo);
  final ao = 0.7287 * (eeff - (er + 1) / 2) * (1 - math.exp(-0.179 * uo));
  final eeffO = ((er + 1) / 2 + ao - eeff) * math.exp(-co * math.pow(g, d)) + eeff;
  // Single-line impedance.
  final zl1 = _zlHJ(u) / math.sqrt(eeff);
  // Even impedance.
  final q1 = 0.8695 * math.pow(ue, 0.194);
  final q2 = 1 + 0.7519 * g + 0.189 * math.pow(g, 2.31);
  final q3 = 0.1975 +
      math.pow(16.6 + math.pow(8.4 / g, 6), -0.387) +
      math.log(math.pow(g, 10) / (1 + math.pow(g / 3.4, 10))) / 241;
  final q4 = q1 / q2 * 2 / (math.exp(-g) * math.pow(ue, q3) + (2 - math.exp(-g)) * math.pow(ue, -q3));
  var zE = math.sqrt(eeff / eeffE) * zl1 / (1 - zl1 * math.sqrt(eeff) * q4 / eta0);
  // Odd impedance.
  final q5 = 1.794 + 1.14 * math.log(1 + 0.638 / (g + 0.517 * math.pow(g, 2.43)));
  final q6 = 0.2305 +
      math.log(math.pow(g, 10) / (1 + math.pow(g / 5.8, 10))) / 281.3 +
      math.log(1 + 0.598 * math.pow(g, 1.154)) / 5.1;
  final q7 = (10 + 190 * g * g) / (1 + 82.3 * g * g * g);
  final q8 = math.exp(-6.5 - 0.95 * math.log(g) - math.pow(g / 0.15, 5));
  final q9 = math.log(q7) * (q8 + 1 / 16.5);
  final q10 = (q2 * q4 - q5 * math.exp(math.log(uo) * q6 * math.pow(uo, -q9))) / q2;
  var zO = math.sqrt(eeff / eeffO) * zl1 / (1 - zl1 * math.sqrt(eeff) * q10 / eta0);
  if (!thicknessApplied && t > 0) {
    final ratio = microstripHJ(w: w, h: h, t: t, er: er).z0 / microstripHJ(w: w, h: h, t: 0, er: er).z0;
    zE *= ratio;
    zO *= ratio;
  }
  return CoupledResult(
    zEven: zE,
    zOdd: zO,
    eeffEven: eeffE,
    eeffOdd: eeffO,
    method: 'Coupled microstrip: Kirschning-Jansen'
        '${thicknessApplied ? ' (Jansen thickness correction)' : t > 0 ? ' (thickness by H-J ratio)' : ''}',
  );
}

/// Complete elliptic integral of the first kind K(k) via the AGM.
double ellipticK(double k) {
  var a = 1.0;
  var b = math.sqrt(1 - k * k);
  for (var i = 0; i < 40; i++) {
    final an = (a + b) / 2;
    final bn = math.sqrt(a * b);
    a = an;
    b = bn;
    if ((a - b).abs() < 1e-15) break;
  }
  return math.pi / (2 * a);
}

double _tanh(double x) {
  final e = math.exp(2 * x);
  return (e - 1) / (e + 1);
}

/// Cohn coupled stripline (zero thickness) with plane spacing [b].
({double zEven, double zOdd}) coupledStriplineCohn({
  required double w,
  required double s,
  required double b,
  required double er,
}) {
  final t1 = _tanh(math.pi * w / (2 * b));
  final t2 = _tanh(math.pi * (w + s) / (2 * b));
  final ke = t1 * t2;
  final ko = t1 / t2;
  double z(double k) => 30 * math.pi / math.sqrt(er) * ellipticK(math.sqrt(1 - k * k)) / ellipticK(k);
  return (zEven: z(ke), zOdd: z(ko));
}

/// Even/odd parameters for an edge-coupled pair on geometry [g].
CoupledResult coupledLines(TraceGeometry g, double w, double s) {
  if (g.structure == LineStructure.microstrip) {
    return coupledMicrostripKJ(w: w, h: g.h1, s: s, t: g.t, er: g.er);
  }
  final h2 = g.h2 ?? g.h1;
  final b = g.h1 + h2 + g.t;
  final c = coupledStriplineCohn(w: w, s: s, b: b, er: g.er);
  // Thickness / offset correction from the single-line models.
  final zThick = (g.h1 - h2).abs() <= 1e-9
      ? striplineWheeler(w: w, b: b, t: g.t, er: g.er)
      : striplineOffset(w: w, h1: g.h1, h2: h2, t: g.t, er: g.er);
  final zThin = striplineWheeler(w: w, b: b, t: 0, er: g.er);
  final ratio = zThick / zThin;
  return CoupledResult(
    zEven: c.zEven * ratio,
    zOdd: c.zOdd * ratio,
    eeffEven: g.er,
    eeffOdd: g.er,
    method: 'Coupled stripline: Cohn exact (t = 0) × Wheeler thickness/offset ratio',
  );
}
