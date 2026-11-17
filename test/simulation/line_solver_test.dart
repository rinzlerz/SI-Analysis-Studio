// Known reflection and propagation-delay scenarios, checked against the
// analytical lattice (bounce) diagram.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:si_studio/simulation/channel_loss/channel_loss.dart';
import 'package:si_studio/simulation/common/physics.dart';
import 'package:si_studio/simulation/impedance/impedance.dart';
import 'package:si_studio/simulation/reflection/reflection.dart';
import 'package:si_studio/simulation/termination/termination.dart';
import 'package:si_studio/simulation/transmission_line/line_params.dart';
import 'package:si_studio/simulation/waveform_engine/line_solver.dart';
import 'package:si_studio/simulation/waveform_engine/stimulus.dart';

const double dt = 1e-12;
const double tDelay = 100e-12; // 100 steps

Float64List step(int n) {
  final v = Float64List(n);
  for (var i = 1; i < n; i++) {
    v[i] = 1.0;
  }
  return v;
}

double at(Float64List v, double t) => v[(t / dt).round()];

void main() {
  group('Reflection coefficient', () {
    test('open, short, matched', () {
      expect(reflectionCoefficient(double.infinity, 50), 1.0);
      expect(reflectionCoefficient(0, 50), -1.0);
      expect(reflectionCoefficient(50, 50), 0.0);
      expect(reflectionCoefficient(75, 50), closeTo(0.2, 1e-12));
    });
    test('return loss of Γ=0.1 is 20 dB', () {
      expect(returnLossDb(0.1), closeTo(20, 1e-9));
    });
  });

  group('Lossless line vs lattice diagram', () {
    test('matched source, open load: Vrx = 1 V after T, Vtx = 0.5 V until 2T', () {
      final s = solveLine(
        vs: step(1000),
        dt: dt,
        delay: tDelay,
        z0: 50,
        source: const SourceEnd(rDriver: 50),
        load: const LoadEnd(),
      );
      expect(at(s.vFar, 50e-12), closeTo(0, 1e-9));
      expect(at(s.vFar, 150e-12), closeTo(1.0, 1e-6));
      expect(at(s.vNear, 50e-12), closeTo(0.5, 1e-9));
      expect(at(s.vNear, 150e-12), closeTo(0.5, 1e-9));
      expect(at(s.vNear, 250e-12), closeTo(1.0, 1e-6));
      // Reflected wave arrives back at the source at 2T.
      expect(at(s.reflectedNear, 150e-12), closeTo(0, 1e-9));
      expect(at(s.reflectedNear, 250e-12), closeTo(0.5, 1e-6));
    });

    test('25 Ω source, open load matches bounce diagram (ringing)', () {
      final s = solveLine(
        vs: step(1200),
        dt: dt,
        delay: tDelay,
        z0: 50,
        source: const SourceEnd(rDriver: 25),
        load: const LoadEnd(),
      );
      final expected = latticeLoadVoltages(vStep: 1, rs: 25, rl: double.infinity, z0: 50, delay: tDelay, arrivals: 5);
      expect(expected[0].voltage, closeTo(4 / 3, 1e-12));
      expect(expected[1].voltage, closeTo(8 / 9, 1e-12));
      for (final b in expected) {
        expect(at(s.vFar, b.time + 50e-12), closeTo(b.voltage, 1e-6));
      }
    });

    test('series termination (Rdrv 10 + Rser 40 = Z0) removes ringing', () {
      final s = solveLine(
        vs: step(1200),
        dt: dt,
        delay: tDelay,
        z0: 50,
        source: const SourceEnd(rDriver: 10, rSeries: 40),
        load: const LoadEnd(),
      );
      var peak = 0.0;
      for (final x in s.vFar) {
        peak = math.max(peak, x);
      }
      expect(peak, closeTo(1.0, 1e-6));
    });

    test('parallel termination to VTT: load sees divider level once', () {
      final s = solveLine(
        vs: step(1000),
        dt: dt,
        delay: tDelay,
        z0: 50,
        source: const SourceEnd(rDriver: 10),
        load: const LoadEnd(rTerm: 50),
      );
      expect(at(s.vFar, 150e-12), closeTo(50 / 60, 1e-6));
      expect(at(s.vFar, 450e-12), closeTo(50 / 60, 1e-6));
    });

    test('capacitive load charges with tau = Z0*C', () {
      const c = 2e-12; // tau = 100 ps
      final s = solveLine(
        vs: step(1000),
        dt: dt,
        delay: tDelay,
        z0: 50,
        source: const SourceEnd(rDriver: 50),
        load: const LoadEnd(cIn: c),
      );
      for (final tau in [0.5, 1.0, 2.0]) {
        final t = tDelay + tau * 100e-12;
        expect(at(s.vFar, t + dt), closeTo(1 - math.exp(-tau), 0.01));
      }
    });

    test('AC (RC) termination: initially matched, settles to source level', () {
      final s = solveLine(
        vs: step(20000),
        dt: dt,
        delay: tDelay,
        z0: 50,
        source: const SourceEnd(rDriver: 10),
        load: const LoadEnd(rAc: 50, cAc: 100e-12),
      );
      expect(at(s.vFar, 105e-12), closeTo(50 / 60, 0.01));
      expect(s.vFar.last, closeTo(1.0, 0.01));
    });

    test('fractional delay is honoured', () {
      final s = solveLine(
        vs: step(1000),
        dt: dt,
        delay: 100.5e-12,
        z0: 50,
        source: const SourceEnd(rDriver: 50),
        load: const LoadEnd(rIn: 50),
      );
      expect(at(s.vFar, 100e-12), closeTo(0, 1e-9));
      expect(at(s.vFar, 102e-12), closeTo(0.5, 1e-6));
    });
  });

  group('Propagation delay', () {
    final g = geometryFromStackupForTest();
    test('delay = length * sqrt(eeff) / c and scales with length', () {
      final imp = computeImpedance(g, 0.2e-3);
      LineParams lp(double len) =>
          LineParams(z0: imp.z0, eeff: imp.eeff, length: len, width: 0.2e-3, geometry: g, tanD: 0.02);
      expect(lp(0.1).delay, closeTo(0.1 * math.sqrt(imp.eeff) / c0, 1e-18));
      expect(lp(0.2).delay, closeTo(2 * lp(0.1).delay, 1e-18));
      // FR-4 microstrip is roughly 5.5-6.5 ps/mm.
      expect(lp(1e-3).delay * 1e12, inInclusiveRange(5.0, 7.0));
    });
  });

  group('Loss model', () {
    final g = geometryFromStackupForTest();
    final imp = computeImpedance(g, 0.2e-3);
    final line = LineParams(z0: imp.z0, eeff: imp.eeff, length: 0.25, width: 0.2e-3, geometry: g, tanD: 0.02);
    test('FR-4 loss at 1 GHz is a few tenths of a dB per inch', () {
      final dbPerInch = line.insertionLossDb(1e9) / (0.25 / 0.0254);
      expect(dbPerInch, inInclusiveRange(0.05, 0.4));
    });
    test('minimum-phase impulse reproduces |H(f)| and is causal', () {
      const ts = 5e-12;
      final h = minimumPhaseImpulse(line.attenuationNp, ts, fftSize: 16384);
      double mag(double f) {
        var re = 0.0;
        var im = 0.0;
        for (var k = 0; k < h.length; k++) {
          re += h[k] * math.cos(2 * math.pi * f * k * ts);
          im -= h[k] * math.sin(2 * math.pi * f * k * ts);
        }
        return math.sqrt(re * re + im * im);
      }

      var sum = 0.0;
      for (final x in h) {
        sum += x;
      }
      expect(sum, closeTo(math.exp(-line.attenuationNp(0)), 1e-9));
      for (final f in [1e8, 1e9, 5e9]) {
        expect(mag(f), closeTo(math.exp(-line.attenuationNp(f)), 0.01));
      }
    });
    test('lossy line attenuates and slows a fast edge', () {
      const ts = 2e-12;
      final h = lineLossImpulse(line, ts);
      expect(h, isNotNull);
      final vs = buildStimulus(
          initial: 0, transitions: const [Transition(50e-12, 1)], riseTime: 20e-12, fallTime: 20e-12, dt: ts, samples: 4000);
      final lossless = solveLine(
          vs: vs, dt: ts, delay: line.delay, z0: line.z0, source: SourceEnd(rDriver: line.z0), load: LoadEnd(rIn: line.z0));
      final lossy = solveLine(
          vs: vs,
          dt: ts,
          delay: line.delay,
          z0: line.z0,
          source: SourceEnd(rDriver: line.z0),
          load: LoadEnd(rIn: line.z0),
          lossImpulse: h);
      final tProbe = line.delay + 60e-12;
      expect(at2(lossy.vFar, tProbe, ts), lessThan(at2(lossless.vFar, tProbe, ts)));
      expect(lossy.vFar.last, closeTo(0.5 * math.exp(-line.attenuationNp(0)), 0.005));
    });
  });

  group('Stimulus', () {
    test('10-90 % rise time equals the configured value', () {
      const ts = 1e-12;
      final v = buildStimulus(
          initial: 0, transitions: const [Transition(500e-12, 1)], riseTime: 200e-12, fallTime: 200e-12, dt: ts, samples: 1000);
      double cross(double l) {
        for (var i = 1; i < v.length; i++) {
          if (v[i - 1] < l && v[i] >= l) return (i - 1 + (l - v[i - 1]) / (v[i] - v[i - 1])) * ts;
        }
        return double.nan;
      }

      expect(cross(0.9) - cross(0.1), closeTo(200e-12, 1e-13));
      expect(cross(0.5), closeTo(500e-12, 1e-13));
    });
    test('PRBS7 has period 127 with 64 ones', () {
      final b = prbs7(254);
      expect(b.sublist(0, 127).where((x) => x == 1).length, 64);
      for (var i = 0; i < 127; i++) {
        expect(b[i], b[i + 127]);
      }
    });
    test('custom pattern parsing', () {
      expect(parseCustomPattern('A5'), [1, 0, 1, 0, 0, 1, 0, 1]);
      expect(parseCustomPattern('0b110'), [1, 1, 0]);
      expect(() => parseCustomPattern('XYZ'), throwsA(isA<PatternError>()));
    });
  });
}

double at2(Float64List v, double t, double ts) => v[(t / ts).round()];

TraceGeometry geometryFromStackupForTest() => const TraceGeometry(
      structure: LineStructure.microstrip,
      h1: 0.2e-3,
      h2: null,
      t: 35e-6,
      er: 4.2,
      notes: [],
    );
