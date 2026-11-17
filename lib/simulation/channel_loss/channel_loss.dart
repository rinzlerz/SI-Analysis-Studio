/// Causal impulse response of the frequency-dependent line loss.
///
/// The magnitude response |H(f)| = exp(-alpha(f) * L) (excluding the pure
/// propagation delay, which the line solver applies separately) is converted
/// to a minimum-phase, causal impulse response with the real-cepstrum method:
///   c   = IFFT(ln|H|)
///   c_m = fold(c)   (c[0], 2c[1..N/2-1], c[N/2], 0...)
///   H_m = exp(FFT(c_m)),  h = Re(IFFT(H_m))
/// A minimum-phase response is causal and reproduces the dispersion of a
/// skin-effect / dielectric-loss line to first order.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../transmission_line/line_params.dart';

/// In-place iterative radix-2 complex FFT. [inverse] applies 1/N scaling.
void fft(Float64List re, Float64List im, {bool inverse = false}) {
  final n = re.length;
  if (n != im.length || n & (n - 1) != 0) {
    throw ArgumentError('FFT length must be a power of two');
  }
  // Bit reversal.
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      final ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }
  for (var len = 2; len <= n; len <<= 1) {
    final ang = 2 * math.pi / len * (inverse ? 1 : -1);
    final wr = math.cos(ang);
    final wi = math.sin(ang);
    final half = len >> 1;
    for (var i = 0; i < n; i += len) {
      var cr = 1.0;
      var ci = 0.0;
      for (var k = 0; k < half; k++) {
        final a = i + k;
        final b = a + half;
        final xr = re[b] * cr - im[b] * ci;
        final xi = re[b] * ci + im[b] * cr;
        re[b] = re[a] - xr;
        im[b] = im[a] - xi;
        re[a] += xr;
        im[a] += xi;
        final ncr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = ncr;
      }
    }
  }
  if (inverse) {
    for (var i = 0; i < n; i++) {
      re[i] /= n;
      im[i] /= n;
    }
  }
}

/// Builds the minimum-phase impulse response sampled at [dt] for the
/// magnitude function [attenuationNp] (total attenuation in nepers at f).
Float64List minimumPhaseImpulse(double Function(double f) attenuationNp, double dt,
    {int fftSize = 8192, double energyTail = 1e-7, int maxTaps = 4096}) {
  final n = fftSize;
  final re = Float64List(n);
  final im = Float64List(n);
  final fs = 1 / dt;
  for (var k = 0; k <= n ~/ 2; k++) {
    final f = k * fs / n;
    final a = math.min(attenuationNp(f), 40.0); // ln|H| = -a (clamped)
    re[k] = -a;
    if (k > 0 && k < n ~/ 2) re[n - k] = -a;
  }
  // Real cepstrum.
  fft(re, im, inverse: true);
  for (var k = 0; k < n; k++) {
    im[k] = 0;
  }
  for (var k = 1; k < n ~/ 2; k++) {
    re[k] *= 2;
  }
  for (var k = n ~/ 2 + 1; k < n; k++) {
    re[k] = 0;
  }
  // exp(FFT(c_m))
  fft(re, im);
  for (var k = 0; k < n; k++) {
    final mag = math.exp(re[k]);
    final ph = im[k];
    re[k] = mag * math.cos(ph);
    im[k] = mag * math.sin(ph);
  }
  fft(re, im, inverse: true);
  // Truncate the tail: keep samples until the remaining energy is negligible.
  var total = 0.0;
  for (var k = 0; k < n ~/ 2; k++) {
    total += re[k] * re[k];
  }
  var acc = 0.0;
  var len = 1;
  for (var k = 0; k < n ~/ 2; k++) {
    acc += re[k] * re[k];
    len = k + 1;
    if (total - acc <= energyTail * total || len >= maxTaps) break;
  }
  final h = Float64List(len);
  var sum = 0.0;
  for (var k = 0; k < len; k++) {
    h[k] = re[k];
    sum += re[k];
  }
  // Restore exact DC gain after truncation.
  final dcGain = math.exp(-attenuationNp(0));
  if (sum.abs() > 1e-12) {
    final s = dcGain / sum;
    for (var k = 0; k < len; k++) {
      h[k] *= s;
    }
  }
  return h;
}

/// Loss impulse response for [line] at time step [dt]; null when the line is
/// practically lossless at the frequencies resolved by [dt].
Float64List? lineLossImpulse(LineParams line, double dt) {
  final fNyq = 0.5 / dt;
  if (line.attenuationNp(fNyq) < 1e-4) return null;
  // FFT long enough to resolve ~20 one-way delays of dispersion tail.
  var n = 2048;
  final want = (20 * line.delay / dt).ceil();
  while (n < want && n < 65536) {
    n <<= 1;
  }
  return minimumPhaseImpulse(line.attenuationNp, dt, fftSize: n);
}
