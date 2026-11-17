/// Metrics, findings and assumptions for channel discontinuities (vias, AC
/// caps, connector / package segments, shunt capacitance).
library;

import 'dart:math' as math;

import '../common/format.dart';
import '../model/config.dart';
import '../model/result.dart';
import '../waveform_engine/channel_builder.dart';
import '../waveform_engine/link_context.dart';

class ChannelReport {
  ChannelReport(this.metrics, this.findings, this.assumptions);
  final List<Metric> metrics;
  final List<Finding> findings;
  final List<String> assumptions;
}

/// [fRef] is the highest frequency of interest (Nyquist or knee frequency).
ChannelReport channelReport(AnalysisConfig cfg, LinkContext link, double fRef, {required bool differential}) {
  final metrics = <Metric>[];
  final findings = <Finding>[];
  final notes = <String>[];
  final els = [...cfg.pcb.elements]..sort((a, b) => a.position.compareTo(b.position));
  if (els.isEmpty) return ChannelReport(metrics, findings, notes);
  final er = link.geometry.er;
  var i = 0;
  for (final e in els) {
    i++;
    final at = 'at ${mm(e.position)}';
    switch (e.type) {
      case ChannelElementType.via:
        final v = viaParams(e, er);
        final fr = v.stubResonance;
        final st = !fr.isFinite
            ? SiStatus.good
            : (fr < 1.5 * fRef ? SiStatus.critical : (fr < 3 * fRef ? SiStatus.warning : SiStatus.good));
        metrics.add(Metric(
          id: 'via$i',
          label: 'Via $i $at: stub resonance',
          value: fr.isFinite ? fr : double.infinity,
          unit: 'Hz',
          status: st,
          level: ModelLevel.advanced,
          note: 'C ${eng(v.c, 'F')}, L ${eng(v.l, 'H')}, stub ${mm(e.stubLength)} (Z ${ohm(v.zStub)}). '
              'Limits: Critical < 1.5×, Warning < 3× ${eng(fRef, 'Hz')}',
        ));
        if (st != SiStatus.good) {
          final maxStub = 299792458.0 / (4 * 3 * fRef * math.sqrt(er));
          findings.add(Finding(
            status: st,
            title: 'Via $i stub resonance',
            reason: 'The ${mm(e.stubLength)} unused via stub is a quarter-wave resonator at ${eng(fr, 'Hz')}, '
                'close to the signal band (${eng(fRef, 'Hz')}). Energy is reflected/absorbed near resonance, '
                'creating an insertion-loss notch and ISI.',
            recommendation: 'Back-drill the via, use a blind/buried via, or route on a layer that uses the full '
                'barrel; keep the stub below ${mm(maxStub)}.',
          ));
        }
        notes.add('Via $i $at: π-model C/2–L–C/2 (Johnson) + open stub line (coaxial Z approximation)'
            '${differential ? ', applied per leg' : ''}.');
      case ChannelElementType.acCap:
        notes.add('AC cap $at: ${eng(e.capacitance, 'F')} + ESL ${eng(e.esl, 'H')}, pads ${eng(e.padCap, 'F')}.');
        if (cfg.protocol == Protocol.pcie) {
          final g = cfg.pcie.gen;
          final lo = g.index >= 3 ? 176e-9 : 75e-9;
          const hi = 265e-9;
          final ok = e.capacitance >= lo && e.capacitance <= hi;
          metrics.add(Metric(
            id: 'accap$i',
            label: 'AC cap $i value',
            value: e.capacitance * 1e9,
            unit: 'nF',
            status: ok ? SiStatus.good : SiStatus.warning,
            level: ModelLevel.advanced,
            note: 'PCIe ${g.label} reference range ${eng(lo, 'F')}–${eng(hi, 'F')}',
          ));
        }
      case ChannelElementType.segment:
        notes.add('Segment $at: ${ohm(e.z)}${differential ? ' differential' : ''}, ${secs(e.delay)} (lossless).');
        final target = cfg.targetImpedance;
        final dev = (e.z - target) / target * 100;
        if (dev.abs() > cfg.thresholds.impedanceWarnPct) {
          findings.add(Finding(
            status: SiStatus.warning,
            title: 'Segment $i impedance discontinuity',
            reason: 'Connector/package segment $at is ${ohm(e.z)} versus the ${ohm(target)} target '
                '(${pct(dev)}), reflecting part of each edge for ${secs(2 * e.delay)}.',
            recommendation: 'Use a connector/package with an impedance closer to the target, or keep the '
                'discontinuity electrically short.',
          ));
        }
      case ChannelElementType.shuntCap:
        notes.add('Shunt C $at: ${eng(e.capacitance, 'F')} to ground.');
        final z = differential ? cfg.targetImpedance / 2 : cfg.targetImpedance;
        final tau = z / 2 * e.capacitance;
        if (tau > 0) {
          metrics.add(Metric(
            id: 'shunt$i',
            label: 'Shunt C $i edge degradation (Z0·C/2)',
            value: tau,
            unit: 's',
            status: SiStatus.info,
            level: ModelLevel.advanced,
            note: '10–90 % added rise ≈ ${secs(2.2 * tau)}',
          ));
        }
    }
  }
  notes.add('Animation is disabled for multi-segment channels (the single-line reconstruction does not apply).');
  return ChannelReport(metrics, findings, notes);
}
