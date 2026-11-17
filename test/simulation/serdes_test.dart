// Phase 2: USB 3.0 / PCIe models, equalisation and roughness.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:si_studio/simulation/engine.dart';
import 'package:si_studio/simulation/equalization/equalization.dart';
import 'package:si_studio/simulation/impedance/impedance.dart';
import 'package:si_studio/simulation/transmission_line/line_params.dart';

Metric? metric(SimulationResult r, String id) {
  for (final m in r.metrics) {
    if (m.id == id) return m;
  }
  return null;
}

AnalysisConfig pcie(PcieGen gen, {double length = 0.2}) {
  final c = AnalysisConfig.defaults(protocol: Protocol.pcie);
  c.pcie.gen = gen;
  c.pcie.applyGenDefaults();
  c.applySerdesLossLimits();
  c.pcb.traceLength = length;
  applyTargetWidth(c);
  return c;
}

void main() {
  group('TX FIR', () {
    test('PCIe preset P7 = -0.1 / 0.7 / -0.2', () {
      final t = tapsFromPresetDb(3.5, -6.0);
      expect(t.pre, closeTo(-0.1, 0.002));
      expect(t.main, closeTo(0.7, 0.002));
      expect(t.post, closeTo(-0.2, 0.002));
    });
    test('P1 (-3.5 dB de-emphasis) and P5 (1.9 dB preshoot)', () {
      final p1 = tapsFromPresetDb(0, -3.5);
      expect(p1.pre, closeTo(0, 1e-9));
      expect(p1.post, closeTo(-0.166, 0.002));
      final p5 = tapsFromPresetDb(1.9, 0);
      expect(p5.post, closeTo(0, 1e-9));
      expect(p5.pre, closeTo(-0.1, 0.003));
    });
    test('taps sum of magnitudes is 1 for every preset', () {
      for (final p in pciePresets) {
        final t = tapsFromPresetDb(p.$1, p.$2);
        expect(t.pre.abs() + t.main.abs() + t.post.abs(), closeTo(1, 1e-9));
      }
    });
    test('FIR levels: transition bits get full swing, runs are de-emphasised', () {
      final t = tapsFromPresetDb(0, -6);
      final y = firLevels([0, 0, 1, 1, 1], t);
      expect(y[2], closeTo(1.0, 1e-9));
      expect(y[4], closeTo(t.steadyLevel, 1e-9));
      expect(20 * math.log(y[4] / y[2]) / math.ln10, closeTo(-6, 0.01));
    });
  });

  group('CTLE', () {
    test('DC gain equals the setting and high-frequency gain approaches 1', () {
      expect(ctleGain(1e3, -9, 8e9), closeTo(math.pow(10, -9 / 20), 1e-4));
      expect(ctleGain(8e9, -9, 8e9), greaterThan(0.6));
    });
    test('filter output preserves the DC gain', () {
      final x = Float64List(20000)..fillRange(1000, 20000, 1.0);
      final y = applyCtle(x, 1e-12, -6, 8e9);
      expect(y.last, closeTo(math.pow(10, -6 / 20), 1e-3));
    });
  });

  group('Roughness', () {
    test('rough copper increases conductor loss, bounded by 2x', () {
      const g = TraceGeometry(structure: LineStructure.microstrip, h1: 0.1e-3, h2: null, t: 35e-6, er: 4, notes: []);
      LineParams lp(double rq) =>
          LineParams(z0: 50, eeff: 3, length: 0.1, width: 0.15e-3, geometry: g, tanD: 0.01, roughness: rq);
      expect(lp(1e-6).conductorLossDb(10e9), greaterThan(lp(0).conductorLossDb(10e9)));
      expect(lp(5e-6).roughnessFactor(50e9), lessThanOrEqualTo(2.0));
      expect(lp(0).roughnessFactor(10e9), 1.0);
    });
  });

  group('SerDes simulation', () {
    test('USB 3.0 default link has an open eye and no critical findings', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.usb3);
      applyTargetWidth(c);
      final r = runAnalysis(c);
      expect(r.eye, isNotNull);
      expect(r.eye!.eyeHeight, greaterThan(0.3));
      expect(r.overallStatus, isNot(SiStatus.critical));
      expect(r.animation, isNotNull);
    });

    test('every PCIe generation simulates with generation-specific rate', () {
      for (final g in PcieGen.values) {
        final r = runAnalysis(pcie(g));
        expect(r.eye, isNotNull, reason: g.label);
        expect(r.eye!.ui, closeTo(1 / g.rate, 1e-18));
        expect(r.eye!.crossingPct, inInclusiveRange(35, 65), reason: g.label);
      }
    });

    test('longer channel -> more insertion loss and a smaller equalised eye', () {
      final a = runAnalysis(pcie(PcieGen.gen4, length: 0.15));
      final b = runAnalysis(pcie(PcieGen.gen4, length: 0.45));
      expect(metric(b, 'il')!.value, greaterThan(metric(a, 'il')!.value * 2.5));
      expect(metric(b, 'eye_eq')!.value, lessThan(metric(a, 'eye_eq')!.value));
    });

    test('equalisation opens a Gen5 eye that is closed at the RX pin', () {
      final c = pcie(PcieGen.gen5, length: 0.4)..pcie.preset = 4;
      final r = runAnalysis(c);
      expect(metric(r, 'eye_raw')!.value, lessThan(0));
      expect(metric(r, 'eye_eq')!.value, greaterThan(0));
      expect(metric(r, 'ctle')!.value, lessThan(0));
    });

    test('lane-to-lane skew is reported for multi-lane links', () {
      final c = pcie(PcieGen.gen3)
        ..pcie.lanes = 4
        ..pcie.laneMismatch = 0.05;
      final r = runAnalysis(c);
      expect(metric(r, 'laneskew'), isNotNull);
      expect(metric(r, 'laneskew')!.value, greaterThan(200e-12));
    });

    test('random jitter adds a total-jitter estimate', () {
      final c = pcie(PcieGen.gen3)..pcie.rjRms = 1e-12;
      final r = runAnalysis(c);
      final tj = metric(r, 'tj')!.value;
      expect(tj, closeTo(r.eye!.jitterPkPk + 14.068e-12, 1e-14));
    });

    test('SerDes config round-trips through JSON', () {
      final c = pcie(PcieGen.gen4)..pcie.preset = 3;
      expect(AnalysisConfig.fromJson(c.toJson()).toJson().toString(), c.toJson().toString());
    });
  });
}
