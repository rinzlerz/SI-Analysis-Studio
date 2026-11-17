/// Transmitter FIR, receiver CTLE and DFE models (behavioural, Level 2).
///
/// TX FIR (3-tap): y_k = c(-1) s_(k+1) + c(0) s_k + c(+1) s_(k-1),
///   s = +/-1, |c(-1)| + |c(0)| + |c(+1)| = 1 (full swing on transitions).
///   From preshoot Ps and de-emphasis De (dB), with
///   Va = c0 + |c+1| - |c-1|, Vb = c0 - |c-1| - |c+1|, Vc = c0 + |c-1| - |c+1|:
///     De = 20 log(Vb/Va),  Ps = 20 log(Vc/Vb)
///     Vb = 1 / (rP + 1/rD - 1),  |c-1| = Vb (rP - 1)/2,  |c+1| = Vb (1/rD - 1)/2
///   (reproduces the PCIe Gen3 preset table, e.g. P7 -> -0.1 / 0.7 / -0.2).
///
/// CTLE: H(s) = Kdc (1 + s/wz) / ((1 + s/wp1)(1 + s/wp2)), wz = Kdc wp1,
///   so the gain rises from Kdc at DC to ~1 between fp1 and fp2.
///   fp1 = fNyquist/2, fp2 = 2 fNyquist (scaled from the PCIe Gen3 reference
///   CTLE: 2 GHz / 8 GHz at 8 GT/s). Discretised with the bilinear transform.
///
/// DFE: ideal-decision DFE. Post-cursor taps h1..hN are fitted by least
///   squares to the centre samples (v_k = h0 s_k + sum h_j s_(k-j) + offset)
///   and their contribution is subtracted over each UI. Tap magnitudes are
///   not limited.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../model/config.dart';

class TxTaps {
  const TxTaps(this.pre, this.main, this.post, {this.preshootDb = 0, this.deEmphasisDb = 0});
  final double pre; // c(-1), <= 0
  final double main; // c(0)
  final double post; // c(+1), <= 0
  final double preshootDb;
  final double deEmphasisDb;

  /// Steady (non-transition) level relative to the full swing.
  double get steadyLevel => main - pre.abs() - post.abs();

  @override
  String toString() =>
      'c-1 ${pre.toStringAsFixed(3)}, c0 ${main.toStringAsFixed(3)}, c+1 ${post.toStringAsFixed(3)}';
}

TxTaps tapsFromPresetDb(double preshootDb, double deEmphasisDb) {
  final rP = math.pow(10, preshootDb / 20).toDouble();
  final rD = math.pow(10, deEmphasisDb / 20).toDouble();
  final vb = 1 / (rP + 1 / rD - 1);
  final a = vb * (rP - 1) / 2;
  final d = vb * (1 / rD - 1) / 2;
  return TxTaps(-a, 1 - a - d, -d, preshootDb: preshootDb, deEmphasisDb: deEmphasisDb);
}

/// TX taps for the selected protocol / generation.
TxTaps txTapsFor(Protocol protocol, SerdesConfig c) {
  if (protocol == Protocol.pcie && c.gen.usesPresets) {
    final p = pciePresets[c.preset.clamp(0, 10)];
    return tapsFromPresetDb(p.$1, p.$2);
  }
  return tapsFromPresetDb(0, c.deEmphasisDb.clamp(-12.0, 0.0));
}

/// Per-bit FIR output levels in [-1, 1] for bits [b] (0/1).
List<double> firLevels(List<int> b, TxTaps t) {
  final n = b.length;
  double s(int k) => b[k.clamp(0, n - 1)] == 1 ? 1.0 : -1.0;
  return List<double>.generate(n, (k) => t.pre * s(k + 1) + t.main * s(k) + t.post * s(k - 1));
}

/// Applies the behavioural CTLE to [x] sampled at [dt].
Float64List applyCtle(Float64List x, double dt, double dcGainDb, double fNyquist) {
  final kdc = math.pow(10, dcGainDb / 20).toDouble();
  final wp1 = 2 * math.pi * fNyquist / 2;
  final wp2 = 2 * math.pi * fNyquist * 2;
  final wz = kdc * wp1;
  final k = 2 / dt;
  // Section 1: (1 + s/wz) / (1 + s/wp1)
  final b0 = 1 + k / wz, b1 = 1 - k / wz, a0 = 1 + k / wp1, a1 = 1 - k / wp1;
  // Section 2: 1 / (1 + s/wp2)
  final c0 = 1.0, c1 = 1.0, d0 = 1 + k / wp2, d1 = 1 - k / wp2;
  final out = Float64List(x.length);
  if (x.isEmpty) return out;
  var x1 = x[0], y1 = x[0]; // DC steady state (unity DC gain sections)
  var z1 = x[0], w1 = x[0];
  for (var i = 0; i < x.length; i++) {
    final y = (b0 * x[i] + b1 * x1 - a1 * y1) / a0;
    x1 = x[i];
    y1 = y;
    final w = (c0 * y + c1 * z1 - d1 * w1) / d0;
    z1 = y;
    w1 = w;
    out[i] = kdc * w;
  }
  return out;
}

/// CTLE magnitude at [f] (linear), for documentation / plots.
double ctleGain(double f, double dcGainDb, double fNyquist) {
  final kdc = math.pow(10, dcGainDb / 20).toDouble();
  final fp1 = fNyquist / 2, fp2 = 2 * fNyquist, fz = kdc * fp1;
  double mag(double fc) => math.sqrt(1 + (f / fc) * (f / fc));
  return kdc * mag(fz) / (mag(fp1) * mag(fp2));
}

class DfeResult {
  DfeResult(this.signal, this.taps, this.cursor);
  final Float64List signal;

  /// Post-cursor taps h1..hN (V).
  final List<double> taps;

  /// Main cursor h0 (V).
  final double cursor;
}

/// Solves the linear system A x = y (small, dense) by Gaussian elimination.
List<double>? _solve(List<List<double>> a, List<double> y) {
  final n = y.length;
  final m = [for (var i = 0; i < n; i++) [...a[i], y[i]]];
  for (var c = 0; c < n; c++) {
    var p = c;
    for (var r = c + 1; r < n; r++) {
      if (m[r][c].abs() > m[p][c].abs()) p = r;
    }
    if (m[p][c].abs() < 1e-12) return null;
    final tmp = m[c];
    m[c] = m[p];
    m[p] = tmp;
    for (var r = 0; r < n; r++) {
      if (r == c) continue;
      final f = m[r][c] / m[c][c];
      for (var k = c; k <= n; k++) {
        m[r][k] -= f * m[c][k];
      }
    }
  }
  return [for (var i = 0; i < n; i++) m[i][n] / m[i][i]];
}

/// Ideal-decision DFE with [nTaps] post-cursor taps.
DfeResult? applyDfe({
  required Float64List v,
  required double dt,
  required double ui,
  required double t0,
  required double phaseDelay,
  required List<int> bits,
  required int nTaps,
  int skipBits = 8,
}) {
  if (nTaps <= 0) return null;
  final nb = bits.length;
  double s(int k) => (k < 0 ? bits[0] : (k >= nb ? bits[nb - 1] : bits[k])) == 1 ? 1.0 : -1.0;
  double sample(double t) {
    final x = t / dt;
    final i = x.floor();
    if (i < 0 || i >= v.length - 1) return double.nan;
    final f = x - i;
    return v[i] * (1 - f) + v[i + 1] * f;
  }

  // Normal equations for [h0, h1..hN, offset].
  final p = nTaps + 2;
  final ata = List.generate(p, (_) => List<double>.filled(p, 0));
  final aty = List<double>.filled(p, 0);
  var rows = 0;
  for (var k = math.max(skipBits, nTaps); k < nb; k++) {
    final y = sample(t0 + (k + 0.5) * ui + phaseDelay);
    if (y.isNaN) break;
    final row = [s(k), for (var j = 1; j <= nTaps; j++) s(k - j), 1.0];
    for (var i = 0; i < p; i++) {
      aty[i] += row[i] * y;
      for (var j = 0; j < p; j++) {
        ata[i][j] += row[i] * row[j];
      }
    }
    rows++;
  }
  if (rows < 4 * p) return null;
  final sol = _solve(ata, aty);
  if (sol == null) return null;
  final taps = sol.sublist(1, nTaps + 1);
  final out = Float64List(v.length);
  for (var i = 0; i < v.length; i++) {
    final t = i * dt;
    final k = ((t - t0 - phaseDelay) / ui).floor();
    var corr = 0.0;
    if (k >= 0 && k < nb) {
      for (var j = 1; j <= nTaps; j++) {
        corr += taps[j - 1] * s(k - j);
      }
    }
    out[i] = v[i] - corr;
  }
  return DfeResult(out, taps, sol[0]);
}
