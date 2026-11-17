/// Reflection calculations (Level 1 - analytical).
///
///   Gamma = (ZL - Z0) / (ZL + Z0)
///
/// Lattice (bounce) diagram for a resistive source Rs and load RL driving a
/// lossless line with an ideal step Vstep:
///   V_incident = Vstep * Z0 / (Rs + Z0)
///   V_load(after k round trips) = V_inc * (1 + GL) * sum_{i=0..k} (GS*GL)^i
library;

import 'dart:math' as math;

/// Reflection coefficient of load [zl] on a line of impedance [z0].
/// `double.infinity` represents an open circuit (Gamma = +1).
double reflectionCoefficient(double zl, double z0) {
  if (zl.isInfinite) return 1.0;
  return (zl - z0) / (zl + z0);
}

/// Return loss (dB, positive) for a reflection coefficient.
double returnLossDb(double gamma) {
  final g = gamma.abs();
  if (g <= 1e-12) return double.infinity;
  return -20 * math.log(g) / math.ln10;
}

/// Worst-case |S11| of a uniform line of impedance [z0] inserted between
/// ports of reference impedance [zRef] (occurs at quarter-wave frequencies):
///   |S11|max = 2|G| / (1 + G^2),  G = (Z0 - Zref)/(Z0 + Zref)
double worstCaseLineS11(double z0, double zRef) {
  final g = reflectionCoefficient(z0, zRef).abs();
  return 2 * g / (1 + g * g);
}

class BounceStep {
  const BounceStep(this.time, this.voltage);

  /// Time at which this level is reached at the load (s).
  final double time;

  /// Load voltage after this arrival (V).
  final double voltage;
}

/// Analytical load-voltage staircase for a resistive source/load.
List<BounceStep> latticeLoadVoltages({
  required double vStep,
  required double rs,
  required double rl,
  required double z0,
  required double delay,
  int arrivals = 8,
}) {
  final gs = reflectionCoefficient(rs, z0);
  final gl = reflectionCoefficient(rl, z0);
  final vInc = vStep * z0 / (rs + z0);
  final out = <BounceStep>[];
  var v = 0.0;
  var wave = vInc;
  for (var k = 0; k < arrivals; k++) {
    v += wave * (1 + gl);
    out.add(BounceStep(delay * (2 * k + 1), v));
    wave *= gl * gs;
  }
  return out;
}
