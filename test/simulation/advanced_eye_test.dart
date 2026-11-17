// Phase 3: advanced eye analysis and compliance-style checks.
import 'package:flutter_test/flutter_test.dart';
import 'package:si_studio/simulation/engine.dart';
import 'package:si_studio/simulation/metrics/eye_advanced.dart';

AnalysisConfig gen(PcieGen g, {double length = 0.2}) {
  final c = AnalysisConfig.defaults(protocol: Protocol.pcie);
  c.pcie.gen = g;
  c.pcie.applyGenDefaults();
  c.applySerdesLossLimits();
  c.pcb.traceLength = length;
  applyTargetWidth(c);
  return c;
}

void main() {
  group('Statistics', () {
    test('erfc and Q-function tails', () {
      expect(erfc(0), closeTo(1, 1e-7));
      expect(erfc(1) , closeTo(0.157299207, 1e-7));
      expect(erfc(5) / 1.5374597944e-12, closeTo(1, 1e-6));
      expect(qFunc(7.034) / 1e-12, closeTo(1, 0.01));
    });
  });

  group('Mask and bathtub', () {
    test('open Gen3 eye has no mask hits; bathtub width shrinks with RJ', () {
      final c = gen(PcieGen.gen3)..pcie.rjRms = 1.5e-12;
      final r = runAnalysis(c);
      final e = r.eye!;
      expect(e.maskHits, 0);
      expect(e.bathtubLog10Ber, isNotNull);
      expect(e.eyeWidthAtBer!, lessThan(e.eyeWidth));
      expect(e.eyeWidthAtBer!, greaterThan(0));
      // BER at the eye centre is far below the target.
      final mid = e.bathtubLog10Ber![e.bathtubLog10Ber!.length ~/ 2];
      expect(mid, lessThan(-12));
      expect(r.metrics.firstWhere((m) => m.id == 'eye_w_ber').level, ModelLevel.advanced);
    });

    test('closed Gen5 eye (long channel, no EQ) hits the mask', () {
      final c = gen(PcieGen.gen5, length: 0.45)
        ..pcie.preset = 4
        ..pcie.ctleEnabled = false
        ..pcie.dfeTaps = 0;
      final r = runAnalysis(c);
      expect(r.eye!.maskHits!, greaterThan(0));
      expect(r.metrics.firstWhere((m) => m.id == 'mask_hits').status, SiStatus.critical);
    });
  });

  group('Compliance-style checks', () {
    test('every protocol produces labelled checks', () {
      for (final p in Protocol.values) {
        final c = AnalysisConfig.defaults(protocol: p);
        applyTargetWidth(c);
        final r = runAnalysis(c);
        expect(r.checks, isNotEmpty, reason: p.label);
        for (final k in r.checks) {
          expect(['spec reference', 'configured limit'].contains(k.source), isTrue);
        }
      }
    });

    test('SPI overshoot check fails for an unterminated long line', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.spi)
        ..spi.termination = TerminationScheme.none
        ..pcb.traceLength = 0.25;
      final r = runAnalysis(c);
      final os = r.checks.firstWhere((k) => k.name == 'Input overshoot');
      expect(os.pass, isFalse);
    });

    test('USB 2.0 HS checks the 500 ps minimum edge', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.usb2)..usb2.riseTime = 300e-12;
      final r = runAnalysis(c);
      expect(r.checks.firstWhere((k) => k.name.startsWith('HS driver rise')).pass, isFalse);
    });
  });
}
