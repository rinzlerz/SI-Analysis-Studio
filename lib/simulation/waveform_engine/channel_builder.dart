/// Builds and solves a multi-segment channel for one signal leg:
///   driver -> trace pieces / vias / AC caps / connector segments / shunt C
///          -> receiver.
///
/// Via model (Howard Johnson, "High-Speed Digital Design"):
///   C [pF] = 1.41 er T D1 / (D2 - D1)      T barrel length, D1 pad, D2 antipad [in]
///   L [nH] = 5.08 h (ln(4h/d) + 1)         h barrel length, d drill [in]
///   represented as a pi network C/2 - L - C/2.
///   Unused stub: open transmission line, Z = (60/sqrt(er)) ln(D2/d) (coaxial
///   approximation), delay = l sqrt(er)/c0; quarter-wave resonance
///   f = c0 / (4 l sqrt(er)).
/// AC-coupling capacitor: series C + ESL with pad capacitance split on both
/// sides. Connector / package: lossless line segment (Z, delay).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../common/physics.dart';
import '../model/config.dart';
import '../termination/termination.dart';
import 'circuit_solver.dart';
import 'line_solver.dart';
import 'link_context.dart';

const double _inch = 0.0254;

class ViaParams {
  const ViaParams({required this.c, required this.l, required this.zStub, required this.stubDelay});
  final double c;
  final double l;
  final double zStub;
  final double stubDelay;

  /// Quarter-wave stub resonance (Hz); infinity without stub.
  double get stubResonance => stubDelay <= 0 ? double.infinity : 1 / (4 * stubDelay);
}

ViaParams viaParams(ChannelElement e, double er) {
  final t = e.barrelLength / _inch;
  final d1 = e.pad / _inch;
  final d2 = e.antipad / _inch;
  final d = e.drill / _inch;
  final cPf = d2 > d1 ? 1.41 * er * t * d1 / (d2 - d1) : 1.41 * er * t * d1 / 0.002;
  final lNh = t > 0 && d > 0 ? 5.08 * t * (math.log(4 * t / d) + 1) : 0.0;
  final zStub = 60 / math.sqrt(er) * math.log(math.max(1.05, e.antipad / e.drill));
  return ViaParams(
    c: cPf * 1e-12,
    l: math.max(0, lNh) * 1e-9,
    zStub: zStub,
    stubDelay: e.stubLength * math.sqrt(er) / c0,
  );
}

/// Nonlinear driver / receiver hooks (IBIS).
class LegDevices {
  const LegDevices({this.driver, this.driverCcomp = 0, this.receiver, this.receiverCcomp = 0});

  /// Creates the driver device on the given node (replaces the Thevenin
  /// source). Null = linear source.
  final NonlinearDevice Function(int node)? driver;
  final double driverCcomp;
  final NonlinearDevice Function(int node)? receiver;
  final double receiverCcomp;

  bool get any => driver != null || receiver != null;
}

/// Solves one leg. Uses the fast single-line solver when the channel is a
/// plain trace with linear ends.
LineSolution solveLeg({
  required LinkContext link,
  required double length,
  required Float64List vs,
  required SourceEnd source,
  required LoadEnd load,
  List<ChannelElement> elements = const [],
  double segmentScale = 1,
  LegDevices devices = const LegDevices(),
}) {
  final line = link.withLength(length);
  if (elements.isEmpty && !devices.any) {
    return solveLine(
      vs: vs,
      dt: link.dt,
      delay: line.delay,
      z0: line.z0,
      source: source,
      load: load,
      lossImpulse: link.lossImpulse,
    );
  }
  final dt = link.dt;
  final er = link.geometry.er;
  final c = Circuit();
  final pin = c.node();
  // Driver.
  if (devices.driver != null) {
    final dn = source.rSeries > 0 ? c.node() : pin;
    c.nonlinear(devices.driver!(dn));
    c.capacitor(dn, -1, devices.driverCcomp);
    if (source.rSeries > 0) c.resistor(dn, pin, source.rSeries);
  } else {
    c.source(pin, source.rTotal, vs);
  }
  // Route.
  final sorted = [...elements]..sort((a, b) => a.position.compareTo(b.position));
  var cur = pin;
  var pos = 0.0;
  final tpd = link.line.tpdPerMetre;
  final kernels = <double, Float64List?>{};
  Float64List? kernelFor(double len) =>
      kernels.putIfAbsent((len * 1e7).roundToDouble(), () => link.kernelFor(len));
  void trace(double len) {
    if (len <= 1e-7) return;
    final m = c.node();
    // Keep each piece at least one time step long.
    final delay = math.max(dt, tpd * len);
    c.line(cur, m, link.line.z0, delay, lossKernel: kernelFor(len));
    cur = m;
  }

  for (final e in sorted) {
    final p = e.position.clamp(0.0, length);
    trace(p - pos);
    pos = p;
    switch (e.type) {
      case ChannelElementType.via:
        final v = viaParams(e, er);
        final right = c.node();
        c.capacitor(cur, -1, v.c / 2);
        if (v.l > 0) {
          c.inductor(cur, right, v.l);
        } else {
          c.resistor(cur, right, 1e-3);
        }
        c.capacitor(right, -1, v.c / 2);
        if (e.stubLength > 0) {
          final s = c.node();
          c.line(right, s, v.zStub, math.max(dt, v.stubDelay));
        }
        cur = right;
      case ChannelElementType.acCap:
        final mid = c.node();
        c.capacitor(cur, -1, e.padCap / 2);
        c.capacitor(cur, mid, e.capacitance);
        var right = mid;
        if (e.esl > 0) {
          right = c.node();
          c.inductor(mid, right, e.esl);
        }
        c.capacitor(right, -1, e.padCap / 2);
        cur = right;
      case ChannelElementType.segment:
        final m = c.node();
        c.line(cur, m, e.z * segmentScale, math.max(dt, e.delay));
        cur = m;
      case ChannelElementType.shuntCap:
        c.capacitor(cur, -1, e.capacitance);
    }
  }
  trace(length - pos);
  final rx = cur;
  // Receiver.
  if (load.rIn.isFinite) c.resistor(rx, -1, load.rIn);
  c.capacitor(rx, -1, load.cIn);
  if (load.rTerm.isFinite) {
    if (load.vtt == 0) {
      c.resistor(rx, -1, load.rTerm);
    } else {
      c.source(rx, load.rTerm, Float64List(vs.length)..fillRange(0, vs.length, load.vtt));
    }
  }
  if (load.hasAc) {
    final m = c.node();
    c.resistor(rx, m, load.rAc);
    c.capacitor(m, -1, load.cAc);
  }
  if (devices.receiver != null) {
    c.nonlinear(devices.receiver!(rx));
    c.capacitor(rx, -1, devices.receiverCcomp);
  }
  try {
    final r = c.run(dt: dt, n: vs.length, probe: [pin, rx]);
    final n = vs.length;
    return LineSolution(
      vNear: r.probes[pin]!,
      vFar: r.probes[rx]!,
      incidentNear: r.incident ?? Float64List(n),
      reflectedNear: r.reflected ?? Float64List(n),
    );
  } on CircuitError catch (e) {
    throw SimulationError(e.message);
  }
}
