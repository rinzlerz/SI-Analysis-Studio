// End-to-end checks of the PRD acceptance criteria 6-12 on the engine.
import 'package:flutter_test/flutter_test.dart';
import 'package:si_studio/simulation/engine.dart';

Metric metric(SimulationResult r, String id) => r.metrics.firstWhere((m) => m.id == id);

double peak(SimulationResult r, String traceId) {
  final v = r.trace(traceId)!.values;
  var p = -1e9;
  for (final x in v) {
    if (x > p) p = x;
  }
  return p;
}

AnalysisConfig spi({double length = 0.1, TerminationScheme term = TerminationScheme.none, double clock = 25e6}) {
  final c = AnalysisConfig.defaults(protocol: Protocol.spi);
  c.pcb.traceLength = length;
  c.spi.termination = term;
  c.spi.clockHz = clock;
  return c;
}

void main() {
  group('SPI', () {
    test('runs and produces all four signals', () {
      final r = runAnalysis(spi());
      for (final id in ['sclk_rx', 'mosi_rx', 'miso_rx', 'cs_rx', 'sclk_ideal', 'sclk_inc', 'sclk_refl']) {
        expect(r.trace(id), isNotNull, reason: id);
        expect(r.trace(id)!.values.length, r.sampleCount);
      }
      expect(r.findings, isNotEmpty);
    });

    test('changing trace length changes propagation delay', () {
      final a = metric(runAnalysis(spi(length: 0.05)), 'delay').value;
      final b = metric(runAnalysis(spi(length: 0.15)), 'delay').value;
      expect(b / a, closeTo(3, 1e-9));
    });

    test('series termination reduces overshoot on a long unterminated line', () {
      final bare = runAnalysis(spi(length: 0.2));
      final cfg = spi(length: 0.2, term: TerminationScheme.series);
      cfg.spi.seriesR = (bare.impedance.z0 - cfg.spi.driverImpedance).clamp(0, 200).toDouble();
      final term = runAnalysis(cfg);
      expect(metric(term, 'overshoot').value, lessThan(metric(bare, 'overshoot').value));
      expect(peak(term, 'sclk_rx'), lessThan(peak(bare, 'sclk_rx')));
      expect(metric(bare, 'overshoot').status, isNot(SiStatus.good));
    });

    test('changing impedance (trace width) changes reflection behaviour', () {
      final a = spi(length: 0.2, term: TerminationScheme.series);
      a.spi.seriesR = 25;
      final b = a.copy()..pcb.traceWidth = 0.6e-3; // lower Z0
      final ra = runAnalysis(a);
      final rb = runAnalysis(b);
      expect(metric(rb, 'z0').value, lessThan(metric(ra, 'z0').value));
      expect(metric(rb, 'gs').value, isNot(closeTo(metric(ra, 'gs').value, 1e-3)));
      // The receiver waveforms must differ (matched vs over-damped source).
      final va = ra.trace('sclk_rx')!.values;
      final vb = rb.trace('sclk_rx')!.values;
      var maxDiff = 0.0;
      for (var i = 0; i < va.length && i < vb.length; i++) {
        final d = (va[i] - vb[i]).abs();
        if (d > maxDiff) maxDiff = d;
      }
      expect(maxDiff, greaterThan(0.1));
    });

    test('long trace at high SCLK violates MISO setup', () {
      final c = spi(length: 0.6, term: TerminationScheme.series, clock: 50e6);
      final r = runAnalysis(c);
      expect(metric(r, 'su_miso').value, lessThan(0));
      expect(r.findings.any((f) => f.title.contains('MISO timing violation')), isTrue);
    });

    test('short terminated link at moderate SCLK has positive MISO slack', () {
      final c = spi(length: 0.05, term: TerminationScheme.series, clock: 10e6);
      final r = runAnalysis(c);
      expect(metric(r, 'su_miso').value, greaterThan(0));
      expect(metric(r, 'su_mosi').value, greaterThan(0));
    });

    test('all SPI modes simulate', () {
      for (var m = 0; m < 4; m++) {
        final c = spi(term: TerminationScheme.series)..spi.mode = m;
        final r = runAnalysis(c);
        expect(metric(r, 'su_mosi').value.isFinite, isTrue, reason: 'mode $m');
      }
    });

    test('invalid input is rejected with an explicit message', () {
      final c = spi()..pcb.traceWidth = 0;
      expect(() => runAnalysis(c), throwsA(isA<SimulationError>()));
    });
  });

  group('USB 2.0', () {
    test('HS matched 90 Ω pair: settled 400 mV and an open eye', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.usb2);
      // Choose width for ~90 Ω on the default stackup.
      c.pcb.traceWidth = 0.3e-3;
      c.pcb.traceSpacing = 0.2e-3;
      final r = runAnalysis(c);
      expect(metric(r, 'vamp').value, closeTo(0.4, 0.002));
      expect(r.eye, isNotNull);
      expect(r.eye!.eyeHeight, greaterThan(0.5));
      expect(r.eye!.eyeWidth / r.eye!.ui, greaterThan(0.8));
      expect(r.eye!.crossingPct, inInclusiveRange(40, 60));
    });

    test('length mismatch creates skew and common mode', () {
      final a = AnalysisConfig.defaults(protocol: Protocol.usb2);
      final b = a.copy()..pcb.lengthMismatch = 10e-3;
      final ra = runAnalysis(a);
      final rb = runAnalysis(b);
      expect(metric(ra, 'skew').value, closeTo(0, 1e-15));
      expect(metric(rb, 'skew').value, greaterThan(50e-12));
      expect(metric(rb, 'cm').value, greaterThan(metric(ra, 'cm').value));
      expect(rb.findings.any((f) => f.title.contains('skew')), isTrue);
    });

    test('impedance mismatch is flagged', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.usb2)
        ..pcb.traceWidth = 0.5e-3
        ..pcb.traceSpacing = 0.1e-3;
      final r = runAnalysis(c);
      expect(metric(r, 'zdev').status, SiStatus.critical);
      expect(r.findings.any((f) => f.title.contains('impedance mismatch')), isTrue);
    });

    test('full-speed simulates', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.usb2);
      c.usb2.speed = Usb2Speed.fullSpeed;
      c.usb2.applySpeedDefaults();
      c.sim.numBits = 64;
      final r = runAnalysis(c);
      expect(r.eye, isNotNull);
      expect(r.metrics.any((m) => m.id == 'vamp'), isFalse);
    });

    test('config JSON round trip is lossless', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.usb2)..pcb.lengthMismatch = 1e-3;
      final j = c.toJson();
      expect(AnalysisConfig.fromJson(j).toJson().toString(), j.toString());
    });
  });
}
