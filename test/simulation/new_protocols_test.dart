// I2C, QSPI/OSPI, RGMII and HDMI models.
import 'package:flutter_test/flutter_test.dart';
import 'package:si_studio/simulation/common/format.dart';
import 'package:si_studio/simulation/engine.dart';
import 'package:si_studio/simulation/protocols/i2c_sim.dart';

Metric metric(SimulationResult r, String id) => r.metrics.firstWhere((m) => m.id == id);

void main() {
  group('I2C', () {
    test('default bus passes in every speed mode', () {
      for (final mode in I2cMode.values) {
        final c = AnalysisConfig.defaults(protocol: Protocol.i2c);
        c.i2c.mode = mode;
        c.i2c.applyModeDefaults();
        final r = runAnalysis(c);
        expect(r.overallStatus, isNot(SiStatus.critical), reason: mode.name);
        expect(metric(r, 'tr').value, lessThan(mode.trMax));
        expect(r.checks.where((k) => k.pass == false), isEmpty, reason: mode.name);
      }
    });

    test('rise time follows 0.8473 Rp Cb', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.i2c);
      c.i2c.mode = I2cMode.standard;
      c.i2c.applyModeDefaults();
      c.i2c.extraCap = 100e-12;
      final r = runAnalysis(c);
      final cb = metric(r, 'cb').value;
      final est = 0.8473 * c.i2c.pullupR * cb;
      expect(metric(r, 'tr').value, closeTo(est, 0.1 * est));
    });

    test('overloaded bus is critical and a feasible pull-up is recommended', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.i2c);
      c.i2c.deviceCount = 12;
      c.i2c.extraCap = 150e-12;
      c.i2c.pullupR = 10e3;
      final r = runAnalysis(c);
      expect(r.overallStatus, SiStatus.critical);
      final rec = metric(r, 'rp_rec').value;
      expect(rec, lessThan(2e3));
      final fixed = c.copy()..i2c.pullupR = rec;
      final r2 = runAnalysis(fixed);
      expect(metric(r2, 'tr').value, lessThan(I2cMode.fast.trMax));
    });

    test('too strong a pull-up raises VOL above the limit', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.i2c);
      c.i2c.pullupR = 400;
      final r = runAnalysis(c);
      expect(metric(r, 'vol').value, greaterThan(0.4));
      expect(metric(r, 'vol').status, SiStatus.critical);
    });

    test('E12 helper', () {
      expect(e12Below(2500), 2200);
      expect(e12Below(1000), 1000);
      expect(e12Below(9999), 8200);
    });
  });

  group('QSPI / OSPI', () {
    test('104 MHz SDR read fails without capture delay and the recommendation fixes it', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.qspi);
      final r = runAnalysis(c);
      expect(metric(r, 'su_miso').value, lessThan(0));
      final rec = metric(r, 'rsd_rec').value;
      expect(rec, greaterThan(0));
      final fixed = c.copy()..qspi.readSampleDelay = rec;
      final r2 = runAnalysis(fixed);
      expect(metric(r2, 'su_miso').value, greaterThan(0));
      expect(metric(r2, 'ho_miso').value, greaterThan(0));
    });

    test('IO-to-CLK mismatch is reported as routing skew', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.qspi)..qspi.dataClockMismatch = 10e-3;
      final r = runAnalysis(c);
      expect(metric(r, 'dcskew').value, greaterThan(50e-12));
    });

    test('DTR with DQS runs and halves the bit time', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.qspi)
        ..qspi.dtr = true
        ..qspi.useDqs = true
        ..qspi.clockHz = 100e6
        ..qspi.setupTime = 0.5e-9
        ..qspi.holdTime = 0.5e-9;
      final r = runAnalysis(c);
      expect(r.metrics.any((m) => m.id == 'rsd_rec'), isTrue);
      expect(metric(r, 'su_mosi').value, greaterThan(0));
    });

    test('SPI is unaffected by the QSPI-only fields', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.spi);
      final r = runAnalysis(c);
      expect(r.metrics.any((m) => m.id == 'rsd_rec'), isFalse);
      expect(r.overallStatus, SiStatus.good);
    });
  });

  group('RGMII', () {
    test('2 ns internal delay meets timing, no delay and double delay fail', () {
      final ok = runAnalysis(AnalysisConfig.defaults(protocol: Protocol.rgmii));
      for (final id in ['su_tx', 'ho_tx', 'su_rx', 'ho_rx']) {
        expect(metric(ok, id).value, greaterThan(0), reason: id);
      }
      final none = runAnalysis(AnalysisConfig.defaults(protocol: Protocol.rgmii)..rgmii.txClockDelay = 0);
      expect(metric(none, 'su_tx').value, lessThan(0));
      expect(none.findings.first.recommendation.contains('internal delay'), isTrue);
      final dbl = runAnalysis(AnalysisConfig.defaults(protocol: Protocol.rgmii)..rgmii.rxClockDelay = 4e-9);
      expect(metric(dbl, 'su_rx').value, lessThan(0));
      expect(dbl.findings.map((f) => f.recommendation).join().contains('twice'), isTrue);
    });

    test('best clock delay is close to 2 ns', () {
      final r = runAnalysis(AnalysisConfig.defaults(protocol: Protocol.rgmii));
      expect(metric(r, 'opt_delay').value, closeTo(2e-9, 0.4e-9));
    });

    test('a longer clock trace adds PCB delay', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.rgmii)
        ..rgmii.txClockDelay = 0
        ..rgmii.clockExtraLength = 300e-3;
      final r = runAnalysis(c);
      expect(metric(r, 'clkskew').value, greaterThan(1.5e-9));
      expect(metric(r, 'su_tx').value, greaterThan(-0.5e-9));
    });
  });

  group('HDMI', () {
    test('all link rates run on a 100 ohm pair', () {
      for (final m in HdmiMode.values) {
        final c = AnalysisConfig.defaults(protocol: Protocol.hdmi);
        c.hdmi.hdmiMode = m;
        c.hdmi.applyHdmiDefaults();
        c.applySerdesLossLimits();
        expect(applyTargetWidth(c), isTrue);
        final r = runAnalysis(c);
        expect(r.impedance.target, 100);
        expect(r.eyes, isNotEmpty, reason: m.name);
        expect(r.overallStatus, isNot(SiStatus.critical), reason: m.name);
      }
    });

    test('lane skew uses the HDMI tolerance', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.hdmi)..hdmi.laneMismatch = 0.3;
      final r = runAnalysis(c);
      expect(metric(r, 'laneskew').note!.contains(secs(HdmiMode.tmds340.laneSkewLimit)), isTrue);
    });
  });

  group('Configuration', () {
    test('new protocol settings survive JSON round-trip', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.i2c)
        ..i2c.pullupR = 3.3e3
        ..qspi.dtr = true
        ..qspi.readSampleDelay = 3e-9
        ..rgmii.txClockDelay = 1.5e-9
        ..hdmi.hdmiMode = HdmiMode.frl12;
      final d = AnalysisConfig.fromJson(c.toJson());
      expect(d.i2c.pullupR, 3.3e3);
      expect(d.qspi.dtr, isTrue);
      expect(d.qspi.readSampleDelay, 3e-9);
      expect(d.rgmii.txClockDelay, 1.5e-9);
      expect(d.hdmi.hdmiMode, HdmiMode.frl12);
    });

    test('analyses saved before these protocols still load', () {
      final old = AnalysisConfig.defaults(protocol: Protocol.spi).toJson()
        ..remove('qspi')
        ..remove('i2c')
        ..remove('rgmii')
        ..remove('hdmi');
      final c = AnalysisConfig.fromJson(old);
      expect(c.qspi.clockHz, 104e6);
      expect(c.hdmi.targetZdiff, 100);
      expect(runAnalysis(c).overallStatus, isNotNull);
    });
  });
}

