/// Characteristic-impedance calculations (Level 1 - analytical).
///
/// Methods
/// * Microstrip: Hammerstad & Jensen (1980) closed-form model with the
///   Hammerstad-Jensen finite-thickness correction. Quasi-static (no
///   dispersion). Typical accuracy ~1 % versus field solvers for
///   0.1 < W/h < 20.
/// * Symmetric stripline: Wheeler (1978) formula including strip thickness
///   (Wadell, "Transmission Line Design Handbook", 3.5). Agrees with Cohn's
///   exact zero-thickness solution within ~0.5 %.
/// * Asymmetric (offset) stripline: parallel-combination approximation
///   Z = 2*Z(b1)*Z(b2)/(Z(b1)+Z(b2)), where Z(bi) is a symmetric stripline
///   with plane spacing 2*hi + t (IPC-2141 / Wadell).
/// * Differential pairs: IPC-2141 coupling approximations
///     microstrip  Zdiff = 2*Z0*(1 - 0.48*exp(-0.96*s/h))
///     stripline   Zdiff = 2*Z0*(1 - 0.347*exp(-2.9*s/b))
///   Typical accuracy +/-5..10 %; use a 2D field solver for sign-off.
library;

import 'dart:math' as math;

import '../common/physics.dart';
import '../model/config.dart';
import 'coupled_lines.dart';

enum LineStructure { microstrip, stripline }

extension LineStructureInfo on LineStructure {
  String get label => this == LineStructure.microstrip ? 'Microstrip' : 'Stripline';
}

/// Cross-section derived from the stackup for the selected signal layer.
class TraceGeometry {
  const TraceGeometry({
    required this.structure,
    required this.h1,
    required this.h2,
    required this.t,
    required this.er,
    required this.notes,
    this.referenceAbove,
    this.referenceBelow,
  });

  final LineStructure structure;

  /// Dielectric height from the trace to the nearest reference plane (m).
  /// For stripline: distance to the plane below.
  final double h1;

  /// Stripline only: distance from the trace to the plane above (m).
  final double? h2;

  /// Trace copper thickness (m).
  final double t;
  final double er;
  final int? referenceAbove;
  final int? referenceBelow;
  final List<String> notes;
}

class StackupError implements Exception {
  StackupError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Derives the line structure (microstrip or stripline) and the dielectric
/// heights from the stackup and the selected signal layer.
TraceGeometry geometryFromStackup(StackupConfig s) {
  final idx = s.signalLayer;
  if (idx < 0 || idx >= s.layers.length) {
    throw StackupError('Signal layer index is outside the stackup.');
  }
  if (s.layers[idx].role != LayerRole.signal) {
    throw StackupError('Layer L${idx + 1} is a plane; choose a signal layer for routing.');
  }
  int? above;
  for (var i = idx - 1; i >= 0; i--) {
    if (s.layers[i].role.isPlane) {
      above = i;
      break;
    }
  }
  int? below;
  for (var i = idx + 1; i < s.layers.length; i++) {
    if (s.layers[i].role.isPlane) {
      below = i;
      break;
    }
  }
  if (above == null && below == null) {
    throw StackupError('No reference plane (GND/PWR) exists for L${idx + 1}. '
        'A controlled-impedance trace needs an adjacent reference plane.');
  }
  // Distance from the signal copper to a plane: dielectrics in between plus
  // copper of any intermediate (signal) layers.
  double distTo(int plane) {
    final lo = math.min(plane, idx);
    final hi = math.max(plane, idx);
    var d = 0.0;
    for (var i = lo; i < hi; i++) {
      d += s.dielectrics[i];
      if (i != lo) d += s.layers[i].copperThickness;
    }
    return d;
  }

  final t = s.layers[idx].copperThickness;
  final notes = <String>[];
  final isOuter = idx == 0 || idx == s.layers.length - 1;
  if (above != null && below != null) {
    if ((idx - above) > 1 || (below - idx) > 1) {
      notes.add('Intermediate signal layers between the trace and its reference '
          'planes are treated as dielectric.');
    }
    return TraceGeometry(
      structure: LineStructure.stripline,
      h1: distTo(below),
      h2: distTo(above),
      t: t,
      er: s.dk,
      referenceAbove: above,
      referenceBelow: below,
      notes: notes,
    );
  }
  final plane = (above ?? below)!;
  if (!isOuter) {
    notes.add('L${idx + 1} is an inner layer with a plane on one side only. '
        'Modelled as surface microstrip; the dielectric on the far side is '
        'ignored (real impedance will be lower, delay longer).');
  }
  if ((plane - idx).abs() > 1) {
    notes.add('Nearest reference plane is L${plane + 1}; intermediate layers are '
        'treated as dielectric.');
  }
  notes.add('No solder mask modelled (solder mask typically lowers microstrip '
      'Z0 by 1-3 ohm).');
  return TraceGeometry(
    structure: LineStructure.microstrip,
    h1: distTo(plane),
    h2: null,
    t: t,
    er: s.dk,
    referenceAbove: plane < idx ? plane : null,
    referenceBelow: plane > idx ? plane : null,
    notes: notes,
  );
}

// ---------------------------------------------------------------------------
// Microstrip (Hammerstad & Jensen)
// ---------------------------------------------------------------------------

double _z01(double u) {
  final f = 6 + (2 * math.pi - 6) * math.exp(-math.pow(30.666 / u, 0.7528));
  return eta0 / (2 * math.pi) * math.log(f / u + math.sqrt(1 + (2 / u) * (2 / u)));
}

double _eeffHJ(double u, double er) {
  final a = 1 +
      math.log((math.pow(u, 4) + math.pow(u / 52, 2)) / (math.pow(u, 4) + 0.432)) / 49 +
      math.log(1 + math.pow(u / 18.1, 3)) / 18.7;
  final b = 0.564 * math.pow((er - 0.9) / (er + 3), 0.053);
  return (er + 1) / 2 + (er - 1) / 2 * math.pow(1 + 10 / u, -a * b);
}

/// Returns (Z0, effective permittivity) of a microstrip.
({double z0, double eeff}) microstripHJ({
  required double w,
  required double h,
  required double t,
  required double er,
}) {
  final u = w / h;
  var du1 = 0.0;
  var dur = 0.0;
  if (t > 0) {
    final tn = t / h;
    final ct = coth(math.sqrt(6.517 * u));
    du1 = tn / math.pi * math.log(1 + 4 * math.e / (tn * ct * ct));
    dur = 0.5 * (1 + 1 / cosh(math.sqrt(er - 1))) * du1;
  }
  final u1 = u + du1;
  final ur = u + dur;
  final e = _eeffHJ(ur, er);
  final z0 = _z01(ur) / math.sqrt(e);
  final z1 = _z01(u1);
  final zr = _z01(ur);
  final eeff = e * (z1 / zr) * (z1 / zr);
  return (z0: z0, eeff: eeff);
}

// ---------------------------------------------------------------------------
// Stripline (Wheeler)
// ---------------------------------------------------------------------------

/// Symmetric stripline, ground-plane spacing [b] (includes strip thickness).
double striplineWheeler({
  required double w,
  required double b,
  required double t,
  required double er,
}) {
  final x = t / b;
  var dw = 0.0;
  if (x > 0) {
    final m = 2 / (1 + 2 / 3 * x / (1 - x));
    dw = x /
        (math.pi * (1 - x)) *
        (1 -
            0.5 *
                math.log(math.pow(x / (2 - x), 2) +
                    math.pow(0.0796 * x / (w / b + 1.1 * x), m)));
  }
  final wp = w / (b - t) + dw;
  final q = 4 / (math.pi * wp);
  return 30 / math.sqrt(er) * math.log(1 + q * (2 * q + math.sqrt(4 * q * q + 6.27)));
}

/// Offset stripline with distances [h1] and [h2] from strip to each plane.
double striplineOffset({
  required double w,
  required double h1,
  required double h2,
  required double t,
  required double er,
}) {
  final za = striplineWheeler(w: w, b: 2 * h1 + t, t: t, er: er);
  final zb = striplineWheeler(w: w, b: 2 * h2 + t, t: t, er: er);
  return 2 * za * zb / (za + zb);
}

// ---------------------------------------------------------------------------
// Combined result
// ---------------------------------------------------------------------------

class ImpedanceResult {
  const ImpedanceResult({
    required this.structure,
    required this.z0,
    required this.eeff,
    required this.zDiff,
    required this.method,
    required this.assumptions,
    this.zEven,
    this.eeffOdd,
    this.eeffEven,
  });

  /// Even-mode impedance and modal permittivities (coupled model only).
  final double? zEven;
  final double? eeffOdd;
  final double? eeffEven;

  final LineStructure structure;

  /// Single-ended characteristic impedance (ohm).
  final double z0;

  /// Effective relative permittivity.
  final double eeff;

  /// Differential impedance (ohm), only for coupled pairs.
  final double? zDiff;

  /// Odd-mode impedance = Zdiff / 2.
  double? get zOdd => zDiff == null ? null : zDiff! / 2;
  final String method;
  final List<String> assumptions;

  Map<String, Object?> toJson() => {
        'structure': structure.name,
        'z0': z0,
        'eeff': eeff,
        'zDiff': zDiff,
        'method': method,
      };
}

/// Computes impedances for a trace of width [w] on geometry [g]. When
/// [spacing] is given, the differential impedance is also computed.
ImpedanceResult computeImpedance(TraceGeometry g, double w,
    {double? spacing, DiffModel diffModel = DiffModel.ipc2141}) {
  final assumptions = <String>[...g.notes];
  double z0;
  double eeff;
  String method;
  if (g.structure == LineStructure.microstrip) {
    final r = microstripHJ(w: w, h: g.h1, t: g.t, er: g.er);
    z0 = r.z0;
    eeff = r.eeff;
    method = 'Microstrip: Hammerstad-Jensen (quasi-static, thickness-corrected)';
  } else {
    final h2 = g.h2!;
    final symmetric = (g.h1 - h2).abs() <= 1e-9;
    z0 = symmetric
        ? striplineWheeler(w: w, b: g.h1 + h2 + g.t, t: g.t, er: g.er)
        : striplineOffset(w: w, h1: g.h1, h2: h2, t: g.t, er: g.er);
    eeff = g.er;
    method = symmetric
        ? 'Stripline: Wheeler (thickness-corrected)'
        : 'Offset stripline: Wheeler + parallel-combination approximation';
  }
  double? zDiff;
  CoupledResult? cpl;
  if (spacing != null && diffModel == DiffModel.coupled) {
    cpl = coupledLines(g, w, spacing);
    zDiff = cpl.zDiff;
    method += '; Zdiff: ${cpl.method}';
    assumptions.add('Differential impedance from even/odd-mode coupled-line model; '
        'the pair propagates at the odd-mode velocity (εeff,odd ${cpl.eeffOdd.toStringAsFixed(3)}).');
  } else if (spacing != null) {
    if (g.structure == LineStructure.microstrip) {
      zDiff = 2 * z0 * (1 - 0.48 * math.exp(-0.96 * spacing / g.h1));
      method += '; Zdiff: IPC-2141 edge-coupled microstrip';
    } else {
      final b = g.h1 + (g.h2 ?? g.h1) + g.t;
      zDiff = 2 * z0 * (1 - 0.347 * math.exp(-2.9 * spacing / b));
      method += '; Zdiff: IPC-2141 edge-coupled stripline';
    }
    assumptions.add('Differential impedance uses IPC-2141 coupling approximations '
        '(typ. +/-5-10 %). Odd-mode velocity assumed equal to single-ended.');
  }
  assumptions.add('Smooth copper, no solder mask, quasi-static (no dispersion).');
  return ImpedanceResult(
    structure: g.structure,
    z0: z0,
    eeff: eeff,
    zDiff: zDiff,
    method: method,
    assumptions: assumptions,
    zEven: cpl?.zEven,
    eeffOdd: cpl?.eeffOdd,
    eeffEven: cpl?.eeffEven,
  );
}

/// Solves for the trace width giving [target] impedance (single-ended, or
/// differential when [spacing] is non-null) by bisection. Returns null if
/// the target is outside the achievable range.
double? solveWidthForTarget(TraceGeometry g, double target,
    {double? spacing, DiffModel diffModel = DiffModel.ipc2141}) {
  double z(double w) {
    final r = computeImpedance(g, w, spacing: spacing, diffModel: diffModel);
    return spacing == null ? r.z0 : r.zDiff!;
  }

  var lo = g.h1 * 0.02;
  var hi = g.h1 * 30;
  final zLo = z(lo); // narrow -> high impedance
  final zHi = z(hi); // wide -> low impedance
  if (target > zLo || target < zHi) return null;
  for (var i = 0; i < 80; i++) {
    final mid = 0.5 * (lo + hi);
    if (z(mid) > target) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return 0.5 * (lo + hi);
}
