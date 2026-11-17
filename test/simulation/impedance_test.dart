// Reference values:
//  * Microstrip: scikit-rf 2.2 MLine (Hammerstad-Jensen, quasi-static) -
//    an independent implementation of the same model.
//  * Stripline: Cohn's exact zero-thickness solution
//    Z0 = 30*pi/sqrt(er) * K(k)/K(k'),  k = sech(pi*W/(2b)).
import 'package:flutter_test/flutter_test.dart';
import 'package:si_studio/simulation/impedance/impedance.dart';
import 'package:si_studio/simulation/model/config.dart';

void main() {
  group('Microstrip (Hammerstad-Jensen)', () {
    final cases = <List<double>>[
      // w, h, t, er, Z0, eeff
      [3.0e-3, 1.6e-3, 0, 4.4, 50.6173, 3.3255],
      [0.3e-3, 0.18e-3, 35e-6, 4.3, 51.8665, 3.0910],
      [0.127e-3, 0.1e-3, 17.5e-6, 3.8, 63.1235, 2.7143],
      [0.2e-3, 0.2e-3, 35e-6, 4.2, 67.5956, 2.8863],
      [1e-3, 0.1e-3, 35e-6, 4.5, 14.3002, 3.8721],
    ];
    for (final c in cases) {
      test('w=${c[0]} h=${c[1]} t=${c[2]} er=${c[3]}', () {
        final r = microstripHJ(w: c[0], h: c[1], t: c[2], er: c[3]);
        expect(r.z0, closeTo(c[4], 0.01));
        expect(r.eeff, closeTo(c[5], 0.001));
      });
    }
  });

  group('Stripline (Wheeler vs Cohn exact, t = 0)', () {
    final cases = <List<double>>[
      // w, b, er, Z0 exact
      [0.15e-3, 0.4e-3, 4.2, 56.8865],
      [0.1e-3, 0.3e-3, 3.8, 63.2600],
      [0.5e-3, 0.5e-3, 4.4, 31.1777],
    ];
    for (final c in cases) {
      test('w=${c[0]} b=${c[1]} er=${c[2]} within 0.5 %', () {
        final z = striplineWheeler(w: c[0], b: c[1], t: 0, er: c[2]);
        expect((z - c[3]).abs() / c[3], lessThan(0.005));
      });
    }
    test('finite thickness lowers Z0', () {
      final z0 = striplineWheeler(w: 0.15e-3, b: 0.4175e-3, t: 0, er: 4.2);
      final zt = striplineWheeler(w: 0.15e-3, b: 0.4175e-3, t: 17.5e-6, er: 4.2);
      expect(zt, lessThan(z0));
    });
    test('offset stripline equals symmetric when centred', () {
      final a = striplineOffset(w: 0.15e-3, h1: 0.2e-3, h2: 0.2e-3, t: 17.5e-6, er: 4.2);
      final b = striplineWheeler(w: 0.15e-3, b: 0.4175e-3, t: 17.5e-6, er: 4.2);
      expect(a, closeTo(b, 1e-9));
    });
  });

  group('Stackup geometry', () {
    test('4-layer top layer is microstrip over L2', () {
      final s = StackupConfig.preset(4);
      final g = geometryFromStackup(s);
      expect(g.structure, LineStructure.microstrip);
      expect(g.h1, closeTo(0.2e-3, 1e-12));
      expect(g.referenceBelow, 1);
    });
    test('6-layer L3 is stripline between L2 and L4', () {
      final s = StackupConfig.preset(6)..signalLayer = 2;
      final g = geometryFromStackup(s);
      expect(g.structure, LineStructure.stripline);
      expect(g.h1, closeTo(0.71e-3, 1e-12));
      expect(g.h2, closeTo(0.2e-3, 1e-12));
    });
    test('plane layer cannot be routed', () {
      final s = StackupConfig.preset(4)..signalLayer = 1;
      expect(() => geometryFromStackup(s), throwsA(isA<StackupError>()));
    });
  });

  group('Differential and width solver', () {
    test('Zdiff decreases as spacing shrinks', () {
      final g = geometryFromStackup(StackupConfig.preset(4));
      final wide = computeImpedance(g, 0.2e-3, spacing: 0.5e-3).zDiff!;
      final tight = computeImpedance(g, 0.2e-3, spacing: 0.1e-3).zDiff!;
      expect(tight, lessThan(wide));
      expect(wide, lessThan(2 * computeImpedance(g, 0.2e-3).z0));
    });
    test('solved width reproduces target', () {
      final g = geometryFromStackup(StackupConfig.preset(4));
      final w = solveWidthForTarget(g, 50)!;
      expect(computeImpedance(g, w).z0, closeTo(50, 0.01));
      final wd = solveWidthForTarget(g, 90, spacing: 0.2e-3)!;
      expect(computeImpedance(g, wd, spacing: 0.2e-3).zDiff!, closeTo(90, 0.01));
    });
  });
}
