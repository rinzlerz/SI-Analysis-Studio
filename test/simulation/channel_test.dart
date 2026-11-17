// Phase 3: circuit solver, channel elements, coupled lines.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:si_studio/simulation/engine.dart';
import 'package:si_studio/simulation/impedance/coupled_lines.dart';
import 'package:si_studio/simulation/impedance/impedance.dart';
import 'package:si_studio/simulation/termination/termination.dart';
import 'package:si_studio/simulation/waveform_engine/channel_builder.dart';
import 'package:si_studio/simulation/waveform_engine/circuit_solver.dart';
import 'package:si_studio/simulation/waveform_engine/line_solver.dart';

Float64List step(int n, {double v = 1}) {
  final x = Float64List(n);
  for (var i = 1; i < n; i++) {
    x[i] = v;
  }
  return x;
}

double maxAbsDiff(Float64List a, Float64List b) {
  var m = 0.0;
  for (var i = 0; i < a.length; i++) {
    m = math.max(m, (a[i] - b[i]).abs());
  }
  return m;
}

void main() {
  group('Circuit solver vs single-line solver', () {
    test('lossless line with RC load and fractional delay matches', () {
      const dt = 1e-12;
      final vs = step(2000);
      final ref = solveLine(
          vs: vs, dt: dt, delay: 100.4e-12, z0: 50, source: const SourceEnd(rDriver: 20), load: const LoadEnd(rIn: 1e6, cIn: 1e-12));
      final c = Circuit();
      final a = c.node(), b = c.node();
      c.source(a, 20, vs);
      c.line(a, b, 50, 100.4e-12);
      c.resistor(b, -1, 1e6);
      c.capacitor(b, -1, 1e-12);
      final r = c.run(dt: dt, n: vs.length, probe: [a, b]);
      expect(maxAbsDiff(r.probes[b]!, ref.vFar), lessThan(1e-6));
      expect(maxAbsDiff(r.probes[a]!, ref.vNear), lessThan(1e-6));
      expect(maxAbsDiff(r.reflected!, ref.reflectedNear), lessThan(1e-6));
    });

    test('two cascaded half-lines equal one full line', () {
      const dt = 1e-12;
      final vs = step(1500);
      final ref = solveLine(vs: vs, dt: dt, delay: 200e-12, z0: 50, source: const SourceEnd(rDriver: 25), load: const LoadEnd());
      final c = Circuit();
      final a = c.node(), m = c.node(), b = c.node();
      c.source(a, 25, vs);
      c.line(a, m, 50, 100e-12);
      c.line(m, b, 50, 100e-12);
      final r = c.run(dt: dt, n: vs.length, probe: [b]);
      expect(maxAbsDiff(r.probes[b]!, ref.vFar), lessThan(1e-6));
    });

    test('series inductor + shunt C (LC low-pass) settles to the source divider', () {
      const dt = 1e-12;
      final vs = step(20000);
      final c = Circuit();
      final a = c.node(), b = c.node();
      c.source(a, 50, vs);
      c.inductor(a, b, 1e-9);
      c.capacitor(b, -1, 1e-12);
      c.resistor(b, -1, 50);
      final r = c.run(dt: dt, n: vs.length, probe: [b]);
      expect(r.probes[b]!.last, closeTo(0.5, 1e-3));
    });
  });

  group('Channel elements', () {
    AnalysisConfig base() {
      final c = AnalysisConfig.defaults(protocol: Protocol.pcie);
      c.pcie.gen = PcieGen.gen4;
      c.pcie.applyGenDefaults();
      c.applySerdesLossLimits();
      applyTargetWidth(c);
      return c;
    }

    double eye(AnalysisConfig c) => runAnalysis(c).metrics.firstWhere((m) => m.id == 'eye_eq').value;

    test('a no-op element (0 F shunt C) reproduces the plain-trace result', () {
      final a = base();
      final b = a.copy()..pcb.elements = [ChannelElement(type: ChannelElementType.shuntCap, position: 0.1, capacitance: 0)];
      final ra = runAnalysis(a).trace('diff_rx')!.values;
      final rb = runAnalysis(b).trace('diff_rx')!.values;
      var m = 0.0;
      for (var i = 0; i < math.min(ra.length, rb.length); i += 7) {
        m = math.max(m, (ra[i] - rb[i]).abs());
      }
      // Different time step (element piece lengths) -> small numerical difference only.
      expect(m, lessThan(0.05));
    });

    test('via with a long stub degrades the Gen4 eye; back-drilling recovers it', () {
      final plain = eye(base());
      final stub = base()
        ..pcb.elements = [ChannelElement(type: ChannelElementType.via, position: 0.1, barrelLength: 1.0e-3, stubLength: 2.0e-3)];
      final drilled = base()
        ..pcb.elements = [ChannelElement(type: ChannelElementType.via, position: 0.1, barrelLength: 1.0e-3, stubLength: 0)];
      final eStub = eye(stub);
      final eDrill = eye(drilled);
      expect(eStub, lessThan(plain));
      expect(eDrill, greaterThan(eStub));
      final r = runAnalysis(stub);
      expect(r.findings.any((f) => f.title.contains('stub')), isTrue);
    });

    test('via parameters follow the Johnson formulas', () {
      final v = viaParams(ChannelElement(type: ChannelElementType.via, barrelLength: 1.6e-3, pad: 0.5e-3, antipad: 0.8e-3, drill: 0.25e-3, stubLength: 1e-3), 4.2);
      // C = 1.41*4.2*0.063*0.01969/(0.0315-0.01969) pF
      expect(v.c * 1e12, closeTo(1.41 * 4.2 * (1.6 / 25.4) * (0.5 / 25.4) / ((0.8 - 0.5) / 25.4), 1e-6));
      expect(v.l * 1e9, closeTo(5.08 * (1.6 / 25.4) * (math.log(4 * 1.6 / 0.25) + 1), 1e-6));
      expect(v.stubResonance, closeTo(299792458 / (4 * 1e-3 * math.sqrt(4.2)), 1e3));
    });

    test('AC-coupling cap passes the high-speed signal (eye still open)', () {
      final c = base()..pcb.elements = [ChannelElement(type: ChannelElementType.acCap, position: 0.02, capacitance: 220e-9)];
      expect(eye(c), greaterThan(0.05));
    });

    test('channel elements are honoured for SPI (single-ended)', () {
      final a = AnalysisConfig.defaults(protocol: Protocol.spi);
      final b = a.copy()..pcb.elements = [ChannelElement(type: ChannelElementType.shuntCap, position: 0.1, capacitance: 20e-12)];
      final ra = runAnalysis(a);
      final rb = runAnalysis(b);
      expect(rb.metrics.firstWhere((m) => m.id == 'rise').value, greaterThan(ra.metrics.firstWhere((m) => m.id == 'rise').value));
    });
  });

  group('Coupled lines and crosstalk', () {
    test('coupled microstrip tends to the single line at large spacing', () {
      final r = coupledMicrostripKJ(w: 0.2e-3, h: 0.2e-3, s: 1.9e-3, t: 0, er: 4.2);
      final single = microstripHJ(w: 0.2e-3, h: 0.2e-3, t: 0, er: 4.2).z0;
      expect(r.zEven, closeTo(single, 0.01 * single));
      expect(r.zOdd, closeTo(single, 0.01 * single));
      expect(r.eeffEven, greaterThan(r.eeffOdd));
    });

    test('Kirschning-Jansen port matches reference values', () {
      final r = coupledMicrostripKJ(w: 0.2e-3, h: 0.2e-3, s: 0.2e-3, t: 0, er: 4.2);
      expect(r.zEven, closeTo(82.6242, 1e-3));
      expect(r.zOdd, closeTo(61.7393, 1e-3));
      expect(r.eeffEven, closeTo(3.2430, 1e-4));
      expect(r.eeffOdd, closeTo(2.7759, 1e-4));
    });

    test('Cohn coupled stripline tends to the single stripline', () {
      final r = coupledStriplineCohn(w: 0.15e-3, s: 5e-3, b: 0.4e-3, er: 4.2);
      expect(r.zEven, closeTo(56.8865, 0.01));
      expect(r.zOdd, closeTo(56.8865, 0.01));
    });

    test('stripline crosstalk: NEXT ≈ Kb·V, FEXT ≈ 0 (homogeneous medium)', () {
      const dt = 1e-12;
      final cpl = coupledStriplineCohn(w: 0.15e-3, s: 0.15e-3, b: 0.4e-3, er: 4.2);
      final z0 = math.sqrt(cpl.zEven * cpl.zOdd);
      final vs = step(3000, v: 2);
      final c = Circuit();
      final a1 = c.node(), a2 = c.node(), b1 = c.node(), b2 = c.node();
      c.source(a1, z0, vs);
      c.resistor(a2, -1, z0);
      c.resistor(b1, -1, z0);
      c.resistor(b2, -1, z0);
      c.coupledLine(a1: a1, a2: a2, b1: b1, b2: b2, zEven: cpl.zEven, zOdd: cpl.zOdd, delayEven: 500e-12, delayOdd: 500e-12);
      final r = c.run(dt: dt, n: vs.length, probe: [a2, b2, b1]);
      final kb = (cpl.zEven - cpl.zOdd) / (2 * (cpl.zEven + cpl.zOdd));
      // Incident wave 1 V; NEXT plateau = Kb * 1 V during 0..2T.
      expect(r.probes[a2]![600], closeTo(kb, 0.01));
      var fext = 0.0;
      for (final x in r.probes[b2]!) {
        fext = math.max(fext, x.abs());
      }
      expect(fext, lessThan(0.01));
      expect(r.probes[b1]![2000], closeTo(1.0, 0.02));
    });

    test('crosstalk analysis appears in SPI results when enabled', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.spi)
        ..pcb.crosstalk.enabled = true
        ..pcb.crosstalk.spacing = 0.2e-3
        ..pcb.crosstalk.coupledLength = 50e-3;
      final r = runAnalysis(c);
      final next = r.metrics.firstWhere((m) => m.id == 'xt_next').value;
      final fext = r.metrics.firstWhere((m) => m.id == 'xt_fext').value;
      expect(next, greaterThan(0.01));
      expect(fext, greaterThan(0));
      expect(r.trace('xt_victim_near'), isNotNull);
      final wide = c.copy()..pcb.crosstalk.spacing = 1.0e-3;
      expect(runAnalysis(wide).metrics.firstWhere((m) => m.id == 'xt_next').value, lessThan(next));
    });
  });
}
