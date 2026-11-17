// Phase 3: Touchstone import and S-parameter channel simulation.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:si_studio/simulation/engine.dart';
import 'package:si_studio/simulation/sparams/touchstone.dart';

const double tDelay = 1.0e-9;

/// Matched lossy line: |S21| = exp(-(a sqrt(f) + b f)), delay 1 ns.
(double, double) s21(double f) {
  final mag = math.exp(-(2e-6 * math.sqrt(f) + 4e-11 * f));
  final ph = -360 * f * tDelay; // degrees
  return (mag, ph);
}

String s2p({int points = 400, double fMax = 40e9}) {
  final b = StringBuffer('! synthetic\n# GHz S MA R 50\n');
  for (var i = 1; i <= points; i++) {
    final f = fMax * i / points;
    final (m, p) = s21(f);
    b.writeln('${f / 1e9} 0.01 0 $m $p $m $p 0.01 0');
  }
  return b.toString();
}

String s4p({double fMax = 40e9, int points = 200}) {
  // Two identical uncoupled lines: P 1->3, N 2->4 (mapping A).
  final b = StringBuffer('# GHz S DB R 50\n');
  for (var i = 1; i <= points; i++) {
    final f = fMax * i / points;
    final (m, p) = s21(f);
    final db = 20 * math.log(m) / math.ln10;
    final s = List.generate(4, (_) => List.filled(4, '-60 0'));
    s[2][0] = '$db $p';
    s[0][2] = '$db $p';
    s[3][1] = '$db $p';
    s[1][3] = '$db $p';
    b.write('${f / 1e9}');
    for (var r = 0; r < 4; r++) {
      b.writeln(' ${s[r].join(' ')}');
    }
  }
  return b.toString();
}

void main() {
  group('Touchstone parsing', () {
    test('s2p (MA, GHz) gives S21 and S11', () {
      final sp = parseTouchstone(s2p(), ports: 2, name: 'line.s2p');
      expect(sp.freq.length, 400);
      expect(sp.refZ, 50);
      final f = sp.freq[99];
      expect(sp.s21Db(f), closeTo(20 * math.log(s21(f).$1) / math.ln10, 1e-6));
      expect(sp.s11Db(f), closeTo(-40, 1e-6));
    });

    test('s4p mixed-mode SDD21 equals the leg transfer for uncoupled lines', () {
      final sp = parseTouchstone(s4p(), ports: 4, name: 'pair.s4p');
      expect(sp.refZ, 100);
      final f = sp.freq[50];
      // The -60 dB cross terms (S32, S41) shift the result by < 0.02 dB.
      expect(sp.s21Db(f), closeTo(20 * math.log(s21(f).$1) / math.ln10, 0.02));
    });

    test('rejects malformed data', () {
      expect(() => parseTouchstone('# GHz S MA R 50\n1 2 3', ports: 2, name: 'x'), throwsA(isA<TouchstoneError>()));
      expect(() => parseTouchstone('[Version] 2.0', ports: 2, name: 'x'), throwsA(isA<TouchstoneError>()));
    });
  });

  group('Impulse response', () {
    test('group delay and DC gain are recovered', () {
      final sp = parseTouchstone(s2p(), ports: 2, name: 'line.s2p');
      expect(sp.groupDelay(), closeTo(tDelay, 5e-12));
      const dt = 2e-12;
      final h = sp.impulseResponse(dt);
      var sum = 0.0, peak = 0.0, at = 0;
      for (var i = 0; i < h.length; i++) {
        sum += h[i];
        if (h[i] > peak) {
          peak = h[i];
          at = i;
        }
      }
      expect(sum, closeTo(s21(sp.freq.first).$1, 0.02));
      expect(at * dt, closeTo(tDelay, 30e-12));
    });
  });

  group('S-parameter channel simulation', () {
    test('PCIe Gen3 with an imported channel uses file loss and opens an eye', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.pcie);
      c.pcie.gen = PcieGen.gen3;
      c.pcie.applyGenDefaults();
      c.applySerdesLossLimits();
      c.pcie.useTouchstone = true;
      c.pcie.sparams = parseTouchstone(s4p(), ports: 4, name: 'pair.s4p');
      final r = runAnalysis(c);
      final il = r.metrics.firstWhere((m) => m.id == 'il');
      expect(il.level, ModelLevel.advanced);
      expect(il.value, closeTo(-20 * math.log(s21(4e9).$1) / math.ln10, 0.05));
      expect(r.metrics.any((m) => m.id == 'zdiff'), isFalse);
      expect(r.eye, isNotNull);
      expect(r.eye!.eyeHeight, greaterThan(0.05));
      expect(r.eye!.crossingPct, inInclusiveRange(35, 65));
    });

    test('Touchstone config survives JSON round trip', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.usb3);
      c.usb3.useTouchstone = true;
      c.usb3.sparams = parseTouchstone(s2p(points: 50), ports: 2, name: 'a.s2p');
      final back = AnalysisConfig.fromJson(c.toJson());
      expect(back.usb3.sparams!.freq.length, 50);
      expect(back.usb3.useTouchstone, isTrue);
    });

    test('missing file is a validation error', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.usb3)..usb3.useTouchstone = true;
      expect(() => runAnalysis(c), throwsA(isA<SimulationError>()));
    });
  });
}
