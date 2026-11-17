/// Display units used by input fields. Engine values are always SI.
library;

import '../../simulation/common/physics.dart';

class UnitSpec {
  const UnitSpec(this.label, this.factor);

  /// Unit label shown to the user.
  final String label;

  /// SI value of one display unit (SI = display * factor).
  final double factor;

  double toDisplay(double si) => si / factor;
  double toSi(double display) => display * factor;
}

enum GeometryUnit { mil, mm }

enum LengthUnit { mm, inch }

extension GeometryUnitSpec on GeometryUnit {
  UnitSpec get spec => this == GeometryUnit.mil ? const UnitSpec('mil', mil) : const UnitSpec('mm', 1e-3);
}

extension LengthUnitSpec on LengthUnit {
  UnitSpec get spec => this == LengthUnit.mm ? const UnitSpec('mm', 1e-3) : const UnitSpec('in', 0.0254);
}

class Units {
  static const ohm = UnitSpec('Ω', 1);
  static const volt = UnitSpec('V', 1);
  static const ps = UnitSpec('ps', 1e-12);
  static const ns = UnitSpec('ns', 1e-9);
  static const pf = UnitSpec('pF', 1e-12);
  static const mhz = UnitSpec('MHz', 1e6);
  static const khz = UnitSpec('kHz', 1e3);
  static const ma = UnitSpec('mA', 1e-3);
  static const kohm = UnitSpec('kΩ', 1e3);
  static const oz = UnitSpec('oz', copperOz);
  static const percent = UnitSpec('%', 1);
  static const none = UnitSpec('', 1);
  static const db = UnitSpec('dB', 1);
}

/// Formats a number for an input field without trailing zeros.
String formatInput(double v, {int maxDecimals = 4}) {
  if (v.isNaN || v.isInfinite) return '';
  var s = v.toStringAsFixed(maxDecimals);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    s = s.replaceFirst(RegExp(r'\.$'), '');
  }
  return s == '-0' ? '0' : s;
}
