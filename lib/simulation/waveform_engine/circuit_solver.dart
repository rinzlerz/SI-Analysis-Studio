/// General time-domain circuit solver for multi-segment channels
/// (Level 2 - behavioural).
///
/// Modified nodal analysis with a constant conductance matrix (fixed time
/// step), so the matrix is inverted once and each step is a matrix-vector
/// product.
/// * Resistors, capacitors and inductors (trapezoidal companion models).
/// * Thevenin sources (voltage samples behind a resistance).
/// * Transmission lines: method of characteristics (Branin) with optional
///   causal loss kernel and fractional delay, identical to line_solver.dart.
/// * Symmetric coupled line pairs: even/odd modal decomposition, each mode a
///   Branin line with its own impedance, velocity and loss (crosstalk).
/// * Up to a few nonlinear shunt devices (IBIS drivers / receiver clamps):
///   solved by Newton iteration on the reduced system
///   x_nl = a - B I(x_nl), with B taken from the inverse matrix.
library;

import 'dart:math' as math;
import 'dart:typed_data';

class CircuitError implements Exception {
  CircuitError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Nonlinear shunt device from a node to ground. [eval] returns the current
/// flowing from the node into the device and its derivative dI/dV at time t.
abstract class NonlinearDevice {
  int get node;
  (double, double) eval(double v, double t);

  /// True while the device is switching (disables quiet-period skipping).
  bool active(double t);
}

class _R {
  _R(this.a, this.b, this.g);
  final int a, b;
  final double g;
}

class _C {
  _C(this.a, this.b, this.c);
  final int a, b;
  final double c;
  double g = 0, vPrev = 0, iPrev = 0;
}

class _L {
  _L(this.a, this.b, this.l);
  final int a, b;
  final double l;
  double g = 0, vPrev = 0, iPrev = 0;
}

class _Src {
  _Src(this.node, this.r, this.v);
  final int node;
  final double r;
  final Float64List v;
}

/// One propagating mode between two ports.
class _Mode {
  _Mode(this.z, this.delay, this.kernel);
  final double z;
  final double delay;
  final Float64List? kernel;
  late Float64List g;
  late int kLen, dInt;
  late Float64List fA, fB; // v + Z i at each port (history)
  double fAInit = 0, fBInit = 0;
  double eA = 0, eB = 0;

  void prepare(double dt, int n) {
    final ds = delay / dt;
    if (ds < 1 - 1e-9) throw CircuitError('Time step exceeds a line delay.');
    dInt = math.max(1, ds.floor());
    final frac = (ds - dInt).clamp(0.0, 1.0);
    final h = kernel ?? (Float64List(1)..[0] = 1.0);
    g = Float64List(h.length + 1);
    for (var k = 0; k < h.length; k++) {
      g[k] += h[k] * (1 - frac);
      g[k + 1] += h[k] * frac;
    }
    kLen = g.length;
    while (kLen > 1 && g[kLen - 1] == 0) {
      kLen--;
    }
    fA = Float64List(n);
    fB = Float64List(n);
  }

  void incoming(int i) {
    var a = 0.0, b = 0.0;
    final base = i - dInt;
    for (var k = 0; k < kLen; k++) {
      final idx = base - k;
      final gk = g[k];
      if (idx >= 0) {
        a += gk * fB[idx];
        b += gk * fA[idx];
      } else {
        a += gk * fBInit;
        b += gk * fAInit;
      }
    }
    eA = a;
    eB = b;
  }
}

class _Line {
  _Line(this.a, this.b, this.mode);
  final int a, b;
  final _Mode mode;
}

class _Coupled {
  _Coupled(this.a1, this.a2, this.b1, this.b2, this.even, this.odd);
  final int a1, a2, b1, b2;
  final _Mode even, odd;
}

class CircuitResult {
  CircuitResult(this.probes, this.incident, this.reflected);

  /// Node voltages for each probed node.
  final Map<int, Float64List> probes;

  /// Forward / backward wave at port A of the first line (driver diagnostics).
  final Float64List? incident;
  final Float64List? reflected;
}

class Circuit {
  int _nodes = 0;
  final _rs = <_R>[];
  final _cs = <_C>[];
  final _ls = <_L>[];
  final _srcs = <_Src>[];
  final _lines = <_Line>[];
  final _coupled = <_Coupled>[];
  final _nl = <NonlinearDevice>[];

  int get nodeCount => _nodes;
  int node() => _nodes++;

  /// Node index -1 is ground.
  void resistor(int a, int b, double r) {
    if (!(r > 0)) throw CircuitError('Resistance must be > 0.');
    _rs.add(_R(a, b, 1 / r));
  }

  void capacitor(int a, int b, double c) {
    if (c > 0) _cs.add(_C(a, b, c));
  }

  void inductor(int a, int b, double l) {
    if (!(l > 0)) throw CircuitError('Inductance must be > 0.');
    _ls.add(_L(a, b, l));
  }

  void source(int node, double r, Float64List v) {
    if (!(r > 0)) throw CircuitError('Source resistance must be > 0.');
    _srcs.add(_Src(node, r, v));
  }

  /// Returns the index of the line (for incident/reflected diagnostics).
  int line(int a, int b, double z, double delay, {Float64List? lossKernel}) {
    _lines.add(_Line(a, b, _Mode(z, delay, lossKernel)));
    return _lines.length - 1;
  }

  void coupledLine({
    required int a1,
    required int a2,
    required int b1,
    required int b2,
    required double zEven,
    required double zOdd,
    required double delayEven,
    required double delayOdd,
    Float64List? kernelEven,
    Float64List? kernelOdd,
  }) {
    _coupled.add(_Coupled(a1, a2, b1, b2, _Mode(zEven, delayEven, kernelEven), _Mode(zOdd, delayOdd, kernelOdd)));
  }

  void nonlinear(NonlinearDevice d) => _nl.add(d);

  // -------------------------------------------------------------------------

  static List<Float64List> _invert(List<Float64List> m) {
    final n = m.length;
    final a = [for (final r in m) Float64List.fromList(r)];
    final inv = [for (var i = 0; i < n; i++) Float64List(n)..[i] = 1.0];
    for (var c = 0; c < n; c++) {
      var p = c;
      for (var r = c + 1; r < n; r++) {
        if (a[r][c].abs() > a[p][c].abs()) p = r;
      }
      if (a[p][c].abs() < 1e-15) {
        throw CircuitError('Circuit matrix is singular (floating node?).');
      }
      if (p != c) {
        final t = a[p];
        a[p] = a[c];
        a[c] = t;
        final u = inv[p];
        inv[p] = inv[c];
        inv[c] = u;
      }
      final d = a[c][c];
      for (var k = 0; k < n; k++) {
        a[c][k] /= d;
        inv[c][k] /= d;
      }
      for (var r = 0; r < n; r++) {
        if (r == c) continue;
        final f = a[r][c];
        if (f == 0) continue;
        for (var k = 0; k < n; k++) {
          a[r][k] -= f * a[c][k];
          inv[r][k] -= f * inv[c][k];
        }
      }
    }
    return inv;
  }

  void _stamp(List<Float64List> m, int a, int b, double g) {
    if (a >= 0) m[a][a] += g;
    if (b >= 0) m[b][b] += g;
    if (a >= 0 && b >= 0) {
      m[a][b] -= g;
      m[b][a] -= g;
    }
  }

  void _stampCoupled(List<Float64List> m, int p1, int p2, double ze, double zo) {
    final gs = 1 / (2 * ze) + 1 / (2 * zo);
    final gm = 1 / (2 * ze) - 1 / (2 * zo);
    m[p1][p1] += gs;
    m[p2][p2] += gs;
    m[p1][p2] += gm;
    m[p2][p1] += gm;
  }

  /// Newton solve of x_nl = a - B I(x_nl) for the nonlinear nodes.
  List<double> _newton(List<double> a, List<List<double>> bm, double t, List<double> guess) {
    final k = _nl.length;
    final x = List<double>.of(guess);
    for (var it = 0; it < 60; it++) {
      final iv = List<double>.filled(k, 0);
      final di = List<double>.filled(k, 0);
      for (var j = 0; j < k; j++) {
        final r = _nl[j].eval(x[j], t);
        iv[j] = r.$1;
        di[j] = r.$2;
      }
      // F = x - a + B I ; J = I + B diag(dI)
      final f = List<double>.generate(k, (r) {
        var s = x[r] - a[r];
        for (var c = 0; c < k; c++) {
          s += bm[r][c] * iv[c];
        }
        return s;
      });
      var norm = 0.0;
      for (final v in f) {
        norm = math.max(norm, v.abs());
      }
      if (norm < 1e-9) break;
      final jm = List.generate(k, (r) => List<double>.generate(k, (c) => (r == c ? 1.0 : 0.0) + bm[r][c] * di[c]));
      List<double> dx;
      if (k == 1) {
        dx = [f[0] / (jm[0][0].abs() < 1e-12 ? 1e-12 : jm[0][0])];
      } else {
        // Small dense solve (k <= 4).
        final aug = [for (var r = 0; r < k; r++) [...jm[r], f[r]]];
        for (var c = 0; c < k; c++) {
          var p = c;
          for (var r = c + 1; r < k; r++) {
            if (aug[r][c].abs() > aug[p][c].abs()) p = r;
          }
          final tmp = aug[c];
          aug[c] = aug[p];
          aug[p] = tmp;
          final d = aug[c][c].abs() < 1e-12 ? 1e-12 : aug[c][c];
          for (var r = 0; r < k; r++) {
            if (r == c) continue;
            final fct = aug[r][c] / d;
            for (var q = c; q <= k; q++) {
              aug[r][q] -= fct * aug[c][q];
            }
          }
        }
        dx = [for (var r = 0; r < k; r++) aug[r][k] / (aug[r][r].abs() < 1e-12 ? 1e-12 : aug[r][r])];
      }
      // Damped update (limit to 0.5 V per iteration).
      for (var j = 0; j < k; j++) {
        x[j] -= dx[j].clamp(-0.5, 0.5);
      }
    }
    return x;
  }

  /// Runs [n] steps of size [dt]. [probe] lists nodes whose voltages are
  /// returned. Sources must provide n samples.
  CircuitResult run({required double dt, required int n, required List<int> probe, int preRoll = 0}) {
    final nn = _nodes;
    if (nn == 0) throw CircuitError('Empty circuit.');
    for (final s in _srcs) {
      if (s.v.length < n) throw CircuitError('Source has fewer samples than steps.');
    }
    final modes = <_Mode>[for (final l in _lines) l.mode, for (final c in _coupled) ...[c.even, c.odd]];
    var pre = preRoll;
    for (final m in modes) {
      if (m.kernel != null) pre = math.max(pre, 6 * (m.delay / dt).ceil() + m.kernel!.length);
    }
    final total = n + pre;
    for (final m in modes) {
      m.prepare(dt, total);
    }

    // ---- DC operating point (capacitors open, inductors/lines shorted) -----
    const gBig = 1e6;
    final dc = List.generate(nn, (_) => Float64List(nn));
    for (final r in _rs) {
      _stamp(dc, r.a, r.b, r.g);
    }
    for (final l in _ls) {
      _stamp(dc, l.a, l.b, gBig);
    }
    for (final l in _lines) {
      _stamp(dc, l.a, l.b, gBig);
    }
    for (final c in _coupled) {
      _stamp(dc, c.a1, c.b1, gBig);
      _stamp(dc, c.a2, c.b2, gBig);
    }
    for (final s in _srcs) {
      dc[s.node][s.node] += 1 / s.r;
    }
    // Weak leak to ground keeps isolated (AC-coupled) islands defined.
    for (var i = 0; i < nn; i++) {
      dc[i][i] += 1e-9;
    }
    final dcInv = _invert(dc);
    final rhs0 = Float64List(nn);
    for (final s in _srcs) {
      rhs0[s.node] += s.v[0] / s.r;
    }
    final x0 = _solveWith(dcInv, rhs0, 0.0, List<double>.filled(_nl.length, 0));

    // ---- Transient matrix -----------------------------------------------------
    final gm = List.generate(nn, (_) => Float64List(nn));
    for (final r in _rs) {
      _stamp(gm, r.a, r.b, r.g);
    }
    for (final c in _cs) {
      c.g = 2 * c.c / dt;
      _stamp(gm, c.a, c.b, c.g);
    }
    for (final l in _ls) {
      l.g = dt / (2 * l.l);
      _stamp(gm, l.a, l.b, l.g);
    }
    for (final s in _srcs) {
      gm[s.node][s.node] += 1 / s.r;
    }
    for (final l in _lines) {
      final y = 1 / l.mode.z;
      gm[l.a][l.a] += y;
      gm[l.b][l.b] += y;
    }
    for (final c in _coupled) {
      _stampCoupled(gm, c.a1, c.a2, c.even.z, c.odd.z);
      _stampCoupled(gm, c.b1, c.b2, c.even.z, c.odd.z);
    }
    for (var i = 0; i < nn; i++) {
      gm[i][i] += 1e-9;
    }
    final inv = _invert(gm);

    // ---- Initial histories from the DC solution ------------------------------
    double v(List<double> x, int i) => i < 0 ? 0.0 : x[i];
    for (final c in _cs) {
      c.vPrev = v(x0, c.a) - v(x0, c.b);
      c.iPrev = 0;
    }
    for (final l in _ls) {
      l.vPrev = 0;
      l.iPrev = gBig * (v(x0, l.a) - v(x0, l.b));
    }
    for (final l in _lines) {
      final i = gBig * (v(x0, l.a) - v(x0, l.b)); // into line at A
      l.mode.fAInit = v(x0, l.a) + l.mode.z * i;
      l.mode.fBInit = v(x0, l.b) - l.mode.z * i;
    }
    for (final c in _coupled) {
      final i1 = gBig * (v(x0, c.a1) - v(x0, c.b1));
      final i2 = gBig * (v(x0, c.a2) - v(x0, c.b2));
      final veA = (v(x0, c.a1) + v(x0, c.a2)) / 2, voA = (v(x0, c.a1) - v(x0, c.a2)) / 2;
      final veB = (v(x0, c.b1) + v(x0, c.b2)) / 2, voB = (v(x0, c.b1) - v(x0, c.b2)) / 2;
      final ie = (i1 + i2) / 2, io = (i1 - i2) / 2;
      c.even.fAInit = veA + c.even.z * ie;
      c.even.fBInit = veB - c.even.z * ie;
      c.odd.fAInit = voA + c.odd.z * io;
      c.odd.fBInit = voB - c.odd.z * io;
    }

    // ---- Time stepping ------------------------------------------------------------
    final outs = {for (final p in probe) p: Float64List(n)};
    final inc = _lines.isEmpty ? null : Float64List(n);
    final refl = _lines.isEmpty ? null : Float64List(n);
    final rhs = Float64List(nn);
    var guess = [for (final d in _nl) v(x0, d.node)];
    var quiet = 0;
    var quietNeed = 1;
    for (final m in modes) {
      quietNeed = math.max(quietNeed, m.dInt + m.kLen + 1);
    }
    final prevSrc = Float64List(_srcs.length)..fillRange(0, _srcs.length, double.nan);
    var x = List<double>.of(x0);

    for (var i = 0; i < total; i++) {
      final step = i < pre ? 0 : i - pre;
      final t = step * dt;
      if (quiet < quietNeed) {
        for (final m in modes) {
          m.incoming(i);
        }
      }
      rhs.fillRange(0, nn, 0);
      var srcChanged = false;
      for (var s = 0; s < _srcs.length; s++) {
        final src = _srcs[s];
        final val = src.v[step];
        if (val != prevSrc[s]) srcChanged = true;
        prevSrc[s] = val;
        rhs[src.node] += val / src.r;
      }
      for (final c in _cs) {
        final ieq = c.g * c.vPrev + c.iPrev;
        if (c.a >= 0) rhs[c.a] += ieq;
        if (c.b >= 0) rhs[c.b] -= ieq;
      }
      for (final l in _ls) {
        final ih = l.iPrev + l.g * l.vPrev;
        if (l.a >= 0) rhs[l.a] -= ih;
        if (l.b >= 0) rhs[l.b] += ih;
      }
      for (final l in _lines) {
        rhs[l.a] += l.mode.eA / l.mode.z;
        rhs[l.b] += l.mode.eB / l.mode.z;
      }
      for (final c in _coupled) {
        final eE = c.even, eO = c.odd;
        rhs[c.a1] += eE.eA / eE.z + eO.eA / eO.z;
        rhs[c.a2] += eE.eA / eE.z - eO.eA / eO.z;
        rhs[c.b1] += eE.eB / eE.z + eO.eB / eO.z;
        rhs[c.b2] += eE.eB / eE.z - eO.eB / eO.z;
      }
      x = _solveWith(inv, rhs, t, guess);
      if (_nl.isNotEmpty) guess = [for (final d in _nl) x[d.node]];

      // Update element histories.
      for (final c in _cs) {
        final vab = v(x, c.a) - v(x, c.b);
        c.iPrev = c.g * (vab - c.vPrev) - c.iPrev;
        c.vPrev = vab;
      }
      for (final l in _ls) {
        final vab = v(x, l.a) - v(x, l.b);
        l.iPrev = l.iPrev + l.g * (vab + l.vPrev);
        l.vPrev = vab;
      }
      var changed = srcChanged;
      void push(_Mode m, double vA, double iA, double vB, double iB) {
        final fa = vA + m.z * iA;
        final fb = vB + m.z * iB;
        final pa = i == 0 ? m.fAInit : m.fA[i - 1];
        final pb = i == 0 ? m.fBInit : m.fB[i - 1];
        if ((fa - pa).abs() > 1e-9 || (fb - pb).abs() > 1e-9) changed = true;
        m.fA[i] = fa;
        m.fB[i] = fb;
      }

      for (final l in _lines) {
        final vA = x[l.a], vB = x[l.b];
        push(l.mode, vA, (vA - l.mode.eA) / l.mode.z, vB, (vB - l.mode.eB) / l.mode.z);
      }
      for (final c in _coupled) {
        final veA = (x[c.a1] + x[c.a2]) / 2, voA = (x[c.a1] - x[c.a2]) / 2;
        final veB = (x[c.b1] + x[c.b2]) / 2, voB = (x[c.b1] - x[c.b2]) / 2;
        push(c.even, veA, (veA - c.even.eA) / c.even.z, veB, (veB - c.even.eB) / c.even.z);
        push(c.odd, voA, (voA - c.odd.eA) / c.odd.z, voB, (voB - c.odd.eB) / c.odd.z);
      }
      for (final d in _nl) {
        if (d.active(t)) changed = true;
      }
      quiet = changed ? 0 : quiet + 1;

      if (i >= pre) {
        for (final p in probe) {
          outs[p]![step] = v(x, p);
        }
        if (inc != null) {
          final l = _lines.first;
          refl![step] = 0.5 * l.mode.eA;
          inc[step] = x[l.a] - 0.5 * l.mode.eA;
        }
      }
    }
    return CircuitResult(outs, inc, refl);
  }

  List<double> _solveWith(List<Float64List> inv, Float64List rhs, double t, List<double> guess) {
    final nn = rhs.length;
    final x = List<double>.filled(nn, 0);
    for (var r = 0; r < nn; r++) {
      final row = inv[r];
      var s = 0.0;
      for (var c = 0; c < nn; c++) {
        s += row[c] * rhs[c];
      }
      x[r] = s;
    }
    if (_nl.isEmpty) return x;
    final k = _nl.length;
    final a = [for (final d in _nl) x[d.node]];
    final bm = [for (final dr in _nl) [for (final dc in _nl) inv[dr.node][dc.node]]];
    final xn = _newton(a, bm, t, guess);
    final iv = [for (var j = 0; j < k; j++) _nl[j].eval(xn[j], t).$1];
    for (var r = 0; r < nn; r++) {
      var s = x[r];
      for (var j = 0; j < k; j++) {
        s -= inv[r][_nl[j].node] * iv[j];
      }
      x[r] = s;
    }
    return x;
  }
}
