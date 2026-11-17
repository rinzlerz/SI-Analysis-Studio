/// Engineering-notation formatting shared by the engine (finding text) and UI.
library;

import 'dart:math' as math;

const _prefixes = {
  -15: 'f',
  -12: 'p',
  -9: 'n',
  -6: 'µ',
  -3: 'm',
  0: '',
  3: 'k',
  6: 'M',
  9: 'G',
};

/// Formats [value] with an SI prefix, e.g. eng(1.2e-9, 's') -> "1.20 ns".
String eng(double value, String unit, {int digits = 3}) {
  if (value.isNaN) return '—';
  if (value.isInfinite) return value > 0 ? '∞' : '-∞';
  if (value == 0) return '0 $unit'.trim();
  final a = value.abs();
  var exp = (math.log(a) / math.ln10 / 3).floor() * 3;
  exp = exp.clamp(-15, 9);
  final scaled = value / math.pow(10, exp);
  final s = _sig(scaled, digits);
  return '$s ${_prefixes[exp]}$unit'.trim();
}

String _sig(double x, int digits) {
  final a = x.abs();
  final intDigits = a >= 100 ? 3 : (a >= 10 ? 2 : 1);
  final dec = math.max(0, digits - intDigits);
  return x.toStringAsFixed(dec);
}

String ohm(double v) => v.isInfinite ? 'open' : '${_sig(v, 3)} Ω';

String pct(double v, {int decimals = 1}) => v.isNaN ? '—' : '${v.toStringAsFixed(decimals)} %';

String volts(double v) => eng(v, 'V');

String secs(double v) => eng(v, 's');

/// Length in mm with 2-3 significant decimals.
String mm(double metres) => '${(metres * 1e3).toStringAsFixed(metres < 1e-3 ? 3 : 2)} mm';

/// Length in mil.
String milStr(double metres) => '${(metres / 25.4e-6).toStringAsFixed(2)} mil';
