/// Touchstone (v1.x) parsing and conversion of a through channel to a
/// causal impulse response (PRD Phase 3: S-parameter import).
///
/// * Supports .s2p (single-ended through, S21) and .s4p (differential,
///   mixed-mode SDD21 / SDD11) in MA, DB or RI format, any frequency unit.
/// * 4-port mappings:
///     A "1,2 in / 3,4 out" (P1 N1 / P2 N2):
///        SDD21 = (S31 - S32 - S41 + S42)/2,  SDD11 = (S11 - S12 - S21 + S22)/2
///     B "1->2, 3->4" (P in 1 out 2; N in 3 out 4):
///        SDD21 = (S21 - S23 - S41 + S43)/2,  SDD11 = (S11 - S13 - S31 + S33)/2
/// * Impulse response: magnitude and unwrapped phase are interpolated onto a
///   uniform grid; below the first point the magnitude is held and phase is
///   extrapolated linearly to 0 at DC; above the last point a raised-cosine
///   taper is applied; a Hermitian-symmetric IFFT gives a real response.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../channel_loss/channel_loss.dart';

class TouchstoneError implements Exception {
  TouchstoneError(this.message);
  final String message;
  @override
  String toString() => message;
}

enum PortMapping { inOut12_34, thru12_34 }

extension PortMappingInfo on PortMapping {
  String get label => this == PortMapping.inOut12_34
      ? 'Ports 1,2 = TX (P,N); 3,4 = RX (P,N)'
      : 'P: 1→2, N: 3→4';
}

/// Through-channel data extracted from a Touchstone file (stored with the
/// analysis so results stay reproducible offline).
class ChannelSParams {
  ChannelSParams({
    required this.name,
    required this.ports,
    required this.refZ,
    required this.freq,
    required this.s21re,
    required this.s21im,
    required this.s11re,
    required this.s11im,
    required this.mapping,
  });

  final String name;
  final int ports;

  /// Reference impedance of the extracted parameters (ohm): single-ended
  /// for 2-port, differential (2 x R) for mixed-mode 4-port.
  final double refZ;
  final List<double> freq;
  final List<double> s21re, s21im, s11re, s11im;
  final PortMapping mapping;

  double get fMax => freq.last;

  Map<String, Object?> toJson() => {
        'name': name,
        'ports': ports,
        'refZ': refZ,
        'f': freq,
        's21re': s21re,
        's21im': s21im,
        's11re': s11re,
        's11im': s11im,
        'map': mapping.name,
      };

  static ChannelSParams? fromJson(Object? o) {
    if (o is! Map) return null;
    final j = o.cast<String, Object?>();
    List<double> l(String k) => (j[k] as List? ?? const []).map((e) => (e as num).toDouble()).toList();
    final f = l('f');
    if (f.length < 2) return null;
    return ChannelSParams(
      name: '${j['name'] ?? 'channel'}',
      ports: (j['ports'] as num?)?.toInt() ?? 2,
      refZ: (j['refZ'] as num?)?.toDouble() ?? 50,
      freq: f,
      s21re: l('s21re'),
      s21im: l('s21im'),
      s11re: l('s11re'),
      s11im: l('s11im'),
      mapping: PortMapping.values.firstWhere((m) => m.name == j['map'], orElse: () => PortMapping.inOut12_34),
    );
  }

  /// Linear interpolation of the magnitude in dB.
  double s21Db(double f) => _interpDb(f, s21re, s21im);
  double s11Db(double f) => _interpDb(f, s11re, s11im);

  double _interpDb(double f, List<double> re, List<double> im) {
    double db(int i) => 20 * math.log(math.max(1e-12, math.sqrt(re[i] * re[i] + im[i] * im[i]))) / math.ln10;
    if (f <= freq.first) return db(0);
    if (f >= freq.last) return db(freq.length - 1);
    var i = 1;
    while (freq[i] < f) {
      i++;
    }
    final t = (f - freq[i - 1]) / (freq[i] - freq[i - 1]);
    return db(i - 1) * (1 - t) + db(i) * t;
  }

  /// Unwrapped S21 phase (rad) at each data point.
  List<double> _phase() {
    final out = <double>[];
    var prev = 0.0, offset = 0.0;
    for (var i = 0; i < freq.length; i++) {
      final p = math.atan2(s21im[i], s21re[i]);
      if (i > 0) {
        final d = p - prev;
        if (d > math.pi) offset -= 2 * math.pi;
        if (d < -math.pi) offset += 2 * math.pi;
      }
      prev = p;
      out.add(p + offset);
    }
    return out;
  }

  /// Group delay estimated from the phase slope over the lower half band.
  double groupDelay() {
    final ph = _phase();
    final n = math.max(2, freq.length ~/ 2);
    // Least-squares slope of phase vs omega through the first n points.
    var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
    for (var i = 0; i < n; i++) {
      final w = 2 * math.pi * freq[i];
      sx += w;
      sy += ph[i];
      sxx += w * w;
      sxy += w * ph[i];
    }
    final slope = (n * sxy - sx * sy) / (n * sxx - sx * sx);
    return math.max(0, -slope);
  }

  /// Real, causal impulse response sampled at [dt].
  Float64List impulseResponse(double dt, {double minDuration = 10e-9}) {
    final td = groupDelay();
    final dur = math.max(minDuration, 4 * td + 5e-9);
    var n = 1024;
    while (n * dt < dur && n < (1 << 18)) {
      n <<= 1;
    }
    final fs = 1 / dt;
    final ph = _phase();
    final mag = [for (var i = 0; i < freq.length; i++) math.sqrt(s21re[i] * s21re[i] + s21im[i] * s21im[i])];
    final re = Float64List(n);
    final im = Float64List(n);
    final f0 = freq.first, f1 = freq.last;
    for (var k = 0; k <= n ~/ 2; k++) {
      final f = k * fs / n;
      double m, p;
      if (f <= f0) {
        m = mag.first;
        p = f0 > 0 ? ph.first * f / f0 : 0;
      } else if (f >= f1) {
        // Hold the phase slope, taper the magnitude to zero over 20 % of fMax.
        final slope = (ph.last - ph[ph.length - 2]) / (freq.last - freq[freq.length - 2]);
        p = ph.last + slope * (f - f1);
        final x = (f - f1) / (0.2 * f1);
        m = x >= 1 ? 0 : mag.last * 0.5 * (1 + math.cos(math.pi * x));
      } else {
        var i = 1;
        while (freq[i] < f) {
          i++;
        }
        final t = (f - freq[i - 1]) / (freq[i] - freq[i - 1]);
        m = mag[i - 1] * (1 - t) + mag[i] * t;
        p = ph[i - 1] * (1 - t) + ph[i] * t;
      }
      re[k] = m * math.cos(p);
      im[k] = m * math.sin(p);
      if (k > 0 && k < n ~/ 2) {
        re[n - k] = re[k];
        im[n - k] = -im[k];
      }
    }
    im[n ~/ 2] = 0;
    fft(re, im, inverse: true);
    return re;
  }
}

double _unitScale(String u) => switch (u.toUpperCase()) {
      'HZ' => 1,
      'KHZ' => 1e3,
      'MHZ' => 1e6,
      'GHZ' => 1e9,
      _ => throw TouchstoneError('Unknown frequency unit "$u".'),
    };

/// Parses Touchstone v1 text with [ports] ports (2 or 4).
ChannelSParams parseTouchstone(String text, {required int ports, required String name, PortMapping mapping = PortMapping.inOut12_34}) {
  if (ports != 2 && ports != 4) throw TouchstoneError('Only 2-port (.s2p) and 4-port (.s4p) files are supported.');
  var unit = 1e9;
  var fmt = 'MA';
  var ref = 50.0;
  final nums = <double>[];
  for (var raw in text.split(RegExp(r'\r?\n'))) {
    final bang = raw.indexOf('!');
    if (bang >= 0) raw = raw.substring(0, bang);
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('[')) {
      throw TouchstoneError('Touchstone 2.0 keyword files are not supported; export as version 1.');
    }
    if (line.startsWith('#')) {
      final tok = line.substring(1).trim().split(RegExp(r'\s+'));
      for (var i = 0; i < tok.length; i++) {
        final t = tok[i].toUpperCase();
        if (['HZ', 'KHZ', 'MHZ', 'GHZ'].contains(t)) unit = _unitScale(t);
        if (['MA', 'DB', 'RI'].contains(t)) fmt = t;
        if (t == 'R' && i + 1 < tok.length) ref = double.tryParse(tok[i + 1]) ?? ref;
        if (['Y', 'Z', 'H', 'G'].contains(t)) throw TouchstoneError('Only S-parameter files are supported.');
      }
      continue;
    }
    for (final t in line.split(RegExp(r'\s+'))) {
      final v = double.tryParse(t);
      if (v == null) throw TouchstoneError('Invalid number "$t".');
      nums.add(v);
    }
  }
  final per = 1 + 2 * ports * ports;
  if (nums.length < 2 * per || nums.length % per != 0) {
    throw TouchstoneError('Data does not match a $ports-port file (${nums.length} values).');
  }
  final rows = nums.length ~/ per;
  final freq = <double>[];
  final s21re = <double>[], s21im = <double>[], s11re = <double>[], s11im = <double>[];
  (double, double) cplx(double a, double b) => switch (fmt) {
        'RI' => (a, b),
        'DB' => (math.pow(10, a / 20) * math.cos(b * math.pi / 180), math.pow(10, a / 20) * math.sin(b * math.pi / 180)),
        _ => (a * math.cos(b * math.pi / 180), a * math.sin(b * math.pi / 180)),
      };
  for (var r = 0; r < rows; r++) {
    final o = r * per;
    freq.add(nums[o] * unit);
    // s(i, j) with 1-based port indices.
    (double, double) s(int i, int j) {
      int idx;
      if (ports == 2) {
        // 2-port order: S11 S21 S12 S22
        idx = const {11: 0, 21: 1, 12: 2, 22: 3}[i * 10 + j]!;
      } else {
        idx = (i - 1) * ports + (j - 1);
      }
      return cplx(nums[o + 1 + 2 * idx], nums[o + 2 + 2 * idx]);
    }

    if (ports == 2) {
      final a = s(2, 1), b = s(1, 1);
      s21re.add(a.$1);
      s21im.add(a.$2);
      s11re.add(b.$1);
      s11im.add(b.$2);
    } else {
      (double, double) comb(List<(int, int, double)> terms) {
        var re = 0.0, im = 0.0;
        for (final t in terms) {
          final v = s(t.$1, t.$2);
          re += t.$3 * v.$1;
          im += t.$3 * v.$2;
        }
        return (re / 2, im / 2);
      }

      final (d21, d11) = mapping == PortMapping.inOut12_34
          ? (
              comb([(3, 1, 1), (3, 2, -1), (4, 1, -1), (4, 2, 1)]),
              comb([(1, 1, 1), (1, 2, -1), (2, 1, -1), (2, 2, 1)]),
            )
          : (
              comb([(2, 1, 1), (2, 3, -1), (4, 1, -1), (4, 3, 1)]),
              comb([(1, 1, 1), (1, 3, -1), (3, 1, -1), (3, 3, 1)]),
            );
      s21re.add(d21.$1);
      s21im.add(d21.$2);
      s11re.add(d11.$1);
      s11im.add(d11.$2);
    }
  }
  for (var i = 1; i < freq.length; i++) {
    if (freq[i] <= freq[i - 1]) throw TouchstoneError('Frequencies must increase.');
  }
  return ChannelSParams(
    name: name,
    ports: ports,
    refZ: ports == 4 ? 2 * ref : ref,
    freq: freq,
    s21re: s21re,
    s21im: s21im,
    s11re: s11re,
    s11im: s11im,
    mapping: mapping,
  );
}

/// Linear convolution y = h * x (same length as x), FFT-based.
Float64List convolve(Float64List x, Float64List h) {
  final n = x.length + h.length;
  var m = 1;
  while (m < n) {
    m <<= 1;
  }
  final ar = Float64List(m), ai = Float64List(m), br = Float64List(m), bi = Float64List(m);
  ar.setRange(0, x.length, x);
  br.setRange(0, h.length, h);
  fft(ar, ai);
  fft(br, bi);
  for (var k = 0; k < m; k++) {
    final r = ar[k] * br[k] - ai[k] * bi[k];
    final i = ar[k] * bi[k] + ai[k] * br[k];
    ar[k] = r;
    ai[k] = i;
  }
  fft(ar, ai, inverse: true);
  return Float64List.fromList(ar.sublist(0, x.length));
}
