/// Compliance-style checks (PRD Phase 3). Each check states whether its
/// limit is a protocol-specification reference value or a configured limit.
/// They indicate likely problems; they are NOT compliance certification.
library;

import '../common/format.dart';
import '../model/config.dart';
import '../model/result.dart';

List<ComplianceCheck> complianceChecks(
  AnalysisConfig cfg,
  List<Metric> metrics, {
  EyeResult? eye,
  Map<String, double> extra = const {},
}) {
  Metric? m(String id) {
    for (final x in metrics) {
      if (x.id == id) return x;
    }
    return null;
  }

  final out = <ComplianceCheck>[];
  void add(String name, String req, String meas, bool? pass, {bool spec = false}) =>
      out.add(ComplianceCheck(
          name: name, requirement: req, measured: meas, pass: pass, source: spec ? 'spec reference' : 'configured limit'));

  void impedance(double target, double tolPct, {bool spec = false}) {
    final z = m('zdiff') ?? m('z0');
    if (z == null) {
      add('Trace impedance', '${ohm(target)} ±${tolPct.toStringAsFixed(0)} %', 'n/a (S-parameter channel)', null);
      return;
    }
    final dev = (z.value - target).abs() / target * 100;
    add('Trace impedance', '${ohm(target)} ±${tolPct.toStringAsFixed(0)} %', '${ohm(z.value)} (${pct(dev)})',
        dev <= tolPct,
        spec: spec);
  }

  void eyeCheck(double h, double wUi) {
    if (eye == null) {
      add('Receiver eye', '≥ ${volts(h)} × ${wUi.toStringAsFixed(2)} UI', 'eye not formed', false);
      return;
    }
    final w = eye.eyeWidth / eye.ui;
    add('Receiver eye (${eye.traceLabel})', '≥ ${volts(h)} × ${wUi.toStringAsFixed(2)} UI',
        '${volts(eye.eyeHeight)} × ${w.toStringAsFixed(2)} UI', eye.eyeHeight >= h && w >= wUi);
    if (eye.maskHits != null) {
      add('Eye mask hits', '0 samples inside the hexagon mask', '${eye.maskHits} of ${eye.maskSamples}', eye.maskHits == 0);
    }
    if (eye.eyeWidthAtBer != null) {
      add('Eye width @ BER ${eye.targetBer}', '≥ ${wUi.toStringAsFixed(2)} UI',
          '${(eye.eyeWidthAtBer! / eye.ui).toStringAsFixed(2)} UI', eye.eyeWidthAtBer! / eye.ui >= wUi);
    }
  }

  switch (cfg.protocol) {
    case Protocol.i2c:
    case Protocol.rgmii:
    case Protocol.ddr:
      break; // Protocol checks are produced by the I2C / RGMII / DDR engines.
    case Protocol.spi:
    case Protocol.qspi:
      final p = cfg.spiCfg;
      final vdd = extra['vdd'] ?? p.voltage;
      final peak = extra['peak'];
      final trough = extra['trough'];
      impedance(p.targetZ0, cfg.thresholds.impedanceWarnPct);
      final rb = m('rb_sclk');
      add('SCLK monotonic at receiver', 'No re-entry into VIL–VIH after an edge',
          rb == null || rb.value.isInfinite ? 'n/a' : 'margin ${volts(rb.value)}', rb == null || rb.value.isInfinite ? null : rb.value >= 0);
      for (final id in ['su_mosi', 'ho_mosi', 'su_miso', 'ho_miso', 'su_wr_dtr', 'ho_wr_dtr']) {
        final x = m(id);
        if (x == null || x.value.isInfinite) continue;
        add(x.label, 'slack ≥ 0', secs(x.value), x.value >= 0);
      }
      if (peak != null) {
        add('Input overshoot', '≤ VDD + 0.3 V (typical CMOS abs. max – check datasheet)', volts(peak), peak <= vdd + 0.3,
            spec: true);
      }
      if (trough != null) {
        add('Input undershoot', '≥ −0.3 V (typical CMOS abs. max – check datasheet)', volts(trough), trough >= -0.3,
            spec: true);
      }
    case Protocol.usb2:
      final p = cfg.usb2;
      impedance(90, 15, spec: true);
      if (p.speed == Usb2Speed.highSpeed) {
        add('HS driver rise/fall time', '≥ 500 ps (10–90 %)', secs(p.riseTime < p.fallTime ? p.riseTime : p.fallTime),
            p.riseTime >= 500e-12 && p.fallTime >= 500e-12,
            spec: true);
        final a = m('vamp');
        if (a != null) {
          add('HS differential amplitude (settled)', '360–440 mV', volts(a.value), a.value >= 0.36 && a.value <= 0.44,
              spec: true);
        }
      } else {
        add('FS driver rise/fall time', '4–20 ns (10–90 %)', secs(p.riseTime),
            p.riseTime >= 4e-9 && p.riseTime <= 20e-9 && p.fallTime >= 4e-9 && p.fallTime <= 20e-9,
            spec: true);
        final zd = p.driverImpedance + p.seriesR;
        add('FS driver output impedance', '28–44 Ω (incl. series R)', ohm(zd), zd >= 28 && zd <= 44, spec: true);
      }
      if (eye != null) {
        add('Eye open', 'eye height > 0', volts(eye.eyeHeight), eye.eyeHeight > 0);
      }
    case Protocol.usb3:
      final p = cfg.usb3;
      impedance(p.targetZdiff, cfg.thresholds.impedanceWarnPct);
      add('TX de-emphasis', '−3.0 to −4.0 dB (USB 3.0 Gen 1)', '${p.deEmphasisDb.toStringAsFixed(1)} dB',
          p.deEmphasisDb <= -3.0 && p.deEmphasisDb >= -4.0,
          spec: true);
      add('TX swing', '0.8–1.2 V diff p-p', volts(p.txSwingPp), p.txSwingPp >= 0.8 && p.txSwingPp <= 1.2, spec: true);
      eyeCheck(p.maskHeight, p.maskWidthUi);
    case Protocol.hdmi:
      final p = cfg.hdmi;
      impedance(100, 10, spec: true);
      if (p.hdmiMode != HdmiMode.frl12) {
        add('TMDS differential swing', '0.8–1.2 V p-p (400–600 mV single-ended)', volts(p.txSwingPp),
            p.txSwingPp >= 0.8 && p.txSwingPp <= 1.2,
            spec: true);
      }
      final ls = m('laneskew');
      if (ls != null) {
        add('Inter-pair (lane) skew', '≤ ${secs(p.hdmiMode.laneSkewLimit)} (sink tolerance, reference)', secs(ls.value),
            ls.value <= p.hdmiMode.laneSkewLimit,
            spec: true);
      }
      eyeCheck(p.maskHeight, p.maskWidthUi);
    case Protocol.pcie:
      final p = cfg.pcie;
      impedance(p.targetZdiff, cfg.thresholds.impedanceWarnPct);
      if (p.gen == PcieGen.gen1) {
        add('TX de-emphasis (Gen 1)', '−3.5 dB ±0.5 dB', '${p.deEmphasisDb.toStringAsFixed(1)} dB',
            (p.deEmphasisDb + 3.5).abs() <= 0.5,
            spec: true);
      } else if (p.gen == PcieGen.gen2) {
        final ok = (p.deEmphasisDb + 3.5).abs() <= 0.5 || (p.deEmphasisDb + 6).abs() <= 0.5;
        add('TX de-emphasis (Gen 2)', '−3.5 dB or −6.0 dB (±0.5 dB)', '${p.deEmphasisDb.toStringAsFixed(1)} dB', ok, spec: true);
      } else {
        add('TX preset', 'P0–P10', 'P${p.preset}', p.preset >= 0 && p.preset <= 10, spec: true);
      }
      final ls = m('laneskew');
      if (ls != null) {
        add('Lane-to-lane skew', '≤ ${secs(p.gen.laneSkewLimit)} (L_RX-SKEW)', secs(ls.value), ls.value <= p.gen.laneSkewLimit,
            spec: true);
      }
      for (final x in metrics.where((x) => x.id.startsWith('accap'))) {
        add(x.label, x.note ?? 'reference range', '${x.value.toStringAsFixed(0)} nF', x.status == SiStatus.good, spec: true);
      }
      eyeCheck(p.maskHeight, p.maskWidthUi);
  }
  final il = m('il');
  if (il != null) {
    add('Insertion loss @ reference frequency', '≤ ${cfg.thresholds.lossWarnDb} dB', '${il.value.toStringAsFixed(2)} dB',
        il.value <= cfg.thresholds.lossWarnDb);
  }
  final xn = m('xt_next'), xf = m('xt_fext');
  if (xn != null && xf != null) {
    add('Crosstalk (NEXT / FEXT)', '≤ ${cfg.thresholds.xtalkWarnPct} % of aggressor swing',
        '${volts(xn.value)} / ${volts(xf.value)}', xn.status != SiStatus.critical && xf.status != SiStatus.critical);
  }
  return out;
}
