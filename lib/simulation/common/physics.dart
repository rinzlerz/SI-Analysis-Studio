/// Physical constants used by the SI Studio simulation engine.
///
/// All engine quantities are in base SI units (m, s, V, A, ohm, F, Hz)
/// unless a name explicitly says otherwise.
library;

import 'dart:math' as math;

/// Speed of light in vacuum (m/s).
const double c0 = 299792458.0;

/// Vacuum permeability (H/m).
const double mu0 = 1.25663706212e-6;

/// Impedance of free space (ohm).
const double eta0 = 376.730313668;

/// Resistivity of electro-deposited / annealed PCB copper at 20 C (ohm*m).
const double rhoCopper = 1.72e-8;

/// One mil (thousandth of an inch) in metres.
const double mil = 25.4e-6;

/// One ounce of copper (nominal 1 oz/ft^2) thickness in metres.
const double copperOz = 34.79e-6;

/// Skin depth in copper at frequency [f] (m).
double skinDepth(double f, {double rho = rhoCopper}) =>
    math.sqrt(rho / (math.pi * f * mu0));

/// Surface resistance of copper at frequency [f] (ohm/square).
double surfaceResistance(double f, {double rho = rhoCopper}) =>
    math.sqrt(math.pi * f * mu0 * rho);

double coth(double x) => 1.0 / _tanh(x);

double _tanh(double x) {
  final e2 = math.exp(2 * x);
  return (e2 - 1) / (e2 + 1);
}

double cosh(double x) => (math.exp(x) + math.exp(-x)) / 2;

/// Parallel combination of resistances; `double.infinity` means "open".
double parallel(double a, double b) {
  if (a.isInfinite) return b;
  if (b.isInfinite) return a;
  return a * b / (a + b);
}
