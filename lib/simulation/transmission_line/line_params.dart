/// Transmission-line parameters (Level 1 - analytical).
///
/// Propagation velocity  v = c0 / sqrt(eeff)
/// Delay per length      tpd = sqrt(eeff) / c0
/// One-way delay         T = tpd * length
/// Electrical length     T / tr (line is "electrically long" when T > tr/6)
///
/// Simplified frequency-dependent loss (per unit length, Np/m):
///   conductor   alpha_c(f) = R(f) / (2 Z0),  R(f) = sqrt(Rdc^2 + Rac(f)^2)
///               Rdc = rho / (W t)
///               Rac = Rs/W + Rs/(W + 2 pi h)      (microstrip: strip + ground)
///               Rac = Rs/(2W) + Rs/(W + 2 pi h)   (stripline: two planes)
///               Rs  = sqrt(pi f mu0 rho)
///               Roughness (Hammerstad-Groiss): Rac *= 1 + (2/pi) atan(1.4 (Rq/delta)^2)
///   dielectric  microstrip: alpha_d = (pi f / c0) * er/sqrt(eeff) *
///                                     (eeff-1)/(er-1) * tan_d
///               stripline : alpha_d = (pi f / c0) * sqrt(er) * tan_d
/// The ground-return term uses an effective spreading width of W + 2*pi*h
/// (current distribution of a filament above a plane). Roughness uses the
/// Hammerstad-Groiss factor (saturates at 2x; optimistic above a few GHz
/// for very rough copper).
library;

import 'dart:math' as math;

import '../common/physics.dart';
import '../impedance/impedance.dart';

class LineParams {
  LineParams({
    required this.z0,
    required this.eeff,
    required this.length,
    required this.width,
    required this.geometry,
    required this.tanD,
    this.roughness = 0,
  });

  /// RMS copper roughness (m).
  final double roughness;

  /// Impedance of the propagating mode used by the time-domain model
  /// (single-ended Z0, or odd-mode Zdiff/2 for differential pairs).
  final double z0;
  final double eeff;
  final double length;
  final double width;
  final TraceGeometry geometry;
  final double tanD;

  double get velocity => c0 / math.sqrt(eeff);

  /// Delay per metre (s/m).
  double get tpdPerMetre => math.sqrt(eeff) / c0;

  /// One-way delay (s).
  double get delay => tpdPerMetre * length;

  double get roundTrip => 2 * delay;

  /// Ratio of one-way delay to edge time.
  double electricalLength(double riseTime) => delay / riseTime;

  /// Length at which the one-way delay equals tr/6 (m).
  double criticalLength(double riseTime) => riseTime / 6 / tpdPerMetre;

  double get rdcPerMetre => rhoCopper / (width * geometry.t);

  /// AC (skin-effect) resistance per metre at [f] (ohm/m).
  /// Hammerstad-Groiss roughness multiplier.
  double roughnessFactor(double f) {
    if (roughness <= 0 || f <= 0) return 1;
    final x = roughness / skinDepth(f);
    return 1 + 2 / math.pi * math.atan(1.4 * x * x);
  }

  double racPerMetre(double f) {
    if (f <= 0) return 0;
    final rs = surfaceResistance(f) * roughnessFactor(f);
    final h = geometry.h1;
    final w = width;
    if (geometry.structure == LineStructure.microstrip) {
      return rs / w + rs / (w + 2 * math.pi * h);
    }
    final hAvg = 0.5 * (geometry.h1 + (geometry.h2 ?? geometry.h1));
    return rs / (2 * w) + rs / (w + 2 * math.pi * hAvg);
  }

  double resistancePerMetre(double f) {
    final rdc = rdcPerMetre;
    final rac = racPerMetre(f);
    return math.sqrt(rdc * rdc + rac * rac);
  }

  /// Conductor attenuation (Np/m).
  double alphaConductor(double f) => resistancePerMetre(f) / (2 * z0);

  /// Dielectric attenuation (Np/m).
  double alphaDielectric(double f) {
    final er = geometry.er;
    if (geometry.structure == LineStructure.stripline) {
      return math.pi * f / c0 * math.sqrt(er) * tanD;
    }
    if (er <= 1.0001) return 0;
    return math.pi * f / c0 * er / math.sqrt(eeff) * (eeff - 1) / (er - 1) * tanD;
  }

  /// Total line attenuation over the full length (Np).
  double attenuationNp(double f) => (alphaConductor(f) + alphaDielectric(f)) * length;

  /// Insertion loss magnitude of the matched line (dB, positive number).
  double insertionLossDb(double f) => 8.685889638 * attenuationNp(f);

  double conductorLossDb(double f) => 8.685889638 * alphaConductor(f) * length;
  double dielectricLossDb(double f) => 8.685889638 * alphaDielectric(f) * length;
}
