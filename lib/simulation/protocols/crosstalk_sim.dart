/// Crosstalk between two parallel single-ended traces (aggressor / victim),
/// Level 2 behavioural.
///
/// The coupled section is modelled with even/odd modes (Kirschning-Jansen
/// for microstrip, Cohn for stripline) in the circuit solver. The aggressor
/// is driven with the protocol stimulus; the victim driver holds its idle
/// level through the same source impedance; both lines see the protocol
/// receiver load. Coupled section only (lossless); the remaining route is
/// not part of this analysis.
///
///   Backward coefficient   Kb = (Ze - Zo) / (2 (Ze + Zo))
///   Saturation length      Lsat = tr * v / 2
///   FEXT exists only when the modal velocities differ (microstrip).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../common/format.dart';
import '../impedance/coupled_lines.dart';
import '../metrics/classify.dart';
import '../model/config.dart';
import '../model/result.dart';
import '../termination/termination.dart';
import '../waveform_engine/circuit_solver.dart';
import '../waveform_engine/link_context.dart';

class CrosstalkOutput {
  CrosstalkOutput(this.metrics, this.findings, this.traces, this.assumption);
  final List<Metric> metrics;
  final List<Finding> findings;
  final List<WaveformTrace> traces;
  final String assumption;
}

CrosstalkOutput crosstalkAnalysis({
  required AnalysisConfig cfg,
  required LinkContext link,
  required Float64List aggressorVs,
  required double victimLevel,
  required SourceEnd source,
  required LoadEnd load,
  required double riseTime,
}) {
  final x = cfg.pcb.crosstalk;
  final thr = cfg.thresholds;
  final g = link.geometry;
  final w = cfg.pcb.traceWidth;
  final cpl = coupledLines(g, w, x.spacing);
  final dt = link.dt;
  final n = aggressorVs.length;
  final de = math.max(dt, x.coupledLength * math.sqrt(cpl.eeffEven) / 299792458.0);
  final dO = math.max(dt, x.coupledLength * math.sqrt(cpl.eeffOdd) / 299792458.0);

  final c = Circuit();
  final a1 = c.node(), a2 = c.node(), b1 = c.node(), b2 = c.node();
  c.source(a1, source.rTotal, aggressorVs);
  c.source(a2, source.rTotal, Float64List(n)..fillRange(0, n, victimLevel));
  void loadAt(int node) {
    if (load.rIn.isFinite) c.resistor(node, -1, load.rIn);
    c.capacitor(node, -1, load.cIn);
    if (load.rTerm.isFinite) {
      if (load.vtt == 0) {
        c.resistor(node, -1, load.rTerm);
      } else {
        c.source(node, load.rTerm, Float64List(n)..fillRange(0, n, load.vtt));
      }
    }
    if (load.hasAc) {
      final m = c.node();
      c.resistor(node, m, load.rAc);
      c.capacitor(m, -1, load.cAc);
    }
  }

  loadAt(b1);
  loadAt(b2);
  c.coupledLine(
      a1: a1, a2: a2, b1: b1, b2: b2, zEven: cpl.zEven, zOdd: cpl.zOdd, delayEven: de, delayOdd: dO);
  final r = c.run(dt: dt, n: n, probe: [a1, a2, b1, b2]);
  final aggNear = r.probes[a1]!;
  final vNear = r.probes[a2]!;
  final vFar = r.probes[b2]!;
  // Victim quiescent levels.
  final qNear = vNear[0], qFar = vFar[0];
  var next = 0.0, fext = 0.0;
  for (var i = 0; i < n; i++) {
    next = math.max(next, (vNear[i] - qNear).abs());
    fext = math.max(fext, (vFar[i] - qFar).abs());
  }
  var lo = double.infinity, hi = -double.infinity;
  for (final v in aggNear) {
    lo = math.min(lo, v);
    hi = math.max(hi, v);
  }
  final swing = math.max(1e-9, hi - lo);
  final nextPct = next / swing * 100;
  final fextPct = fext / swing * 100;
  final vel = 299792458.0 / math.sqrt(cpl.eeffOdd);
  final lsat = riseTime * vel / 2;

  // Spacing that brings the saturated NEXT coefficient below the Good limit.
  double? sGood;
  {
    final target = thr.xtalkGoodPct / 100;
    double kb(double s) => coupledLines(g, w, s).kBackward;
    if (kb(x.spacing) > target) {
      var lo2 = x.spacing, hi2 = x.spacing;
      for (var i = 0; i < 30 && kb(hi2) > target; i++) {
        hi2 *= 1.5;
      }
      if (kb(hi2) <= target) {
        for (var i = 0; i < 40; i++) {
          final mid = (lo2 + hi2) / 2;
          if (kb(mid) > target) {
            lo2 = mid;
          } else {
            hi2 = mid;
          }
        }
        sGood = hi2;
      }
    }
  }

  final stNext = classifyHigherWorse(nextPct, thr.xtalkGoodPct, thr.xtalkWarnPct);
  final stFext = classifyHigherWorse(fextPct, thr.xtalkGoodPct, thr.xtalkWarnPct);
  final metrics = <Metric>[
    Metric(
      id: 'xt_zeo',
      label: 'Coupled Zeven / Zodd (aggressor–victim)',
      value: cpl.zEven,
      unit: 'ohm',
      status: SiStatus.info,
      level: ModelLevel.advanced,
      note: 'Zodd ${ohm(cpl.zOdd)}; Kb = ${cpl.kBackward.toStringAsFixed(4)}; ${cpl.method}',
    ),
    Metric(
      id: 'xt_next',
      label: 'Near-end crosstalk (NEXT) peak',
      value: next,
      unit: 'V',
      status: stNext,
      level: ModelLevel.advanced,
      note: '${pct(nextPct)} of aggressor swing; spacing ${mm(x.spacing)} over ${mm(x.coupledLength)}. '
          'Limits ${thr.xtalkGoodPct}% / ${thr.xtalkWarnPct}%',
    ),
    Metric(
      id: 'xt_fext',
      label: 'Far-end crosstalk (FEXT) peak',
      value: fext,
      unit: 'V',
      status: stFext,
      level: ModelLevel.advanced,
      note: '${pct(fextPct)} of aggressor swing; ${g.structure.name == 'stripline' ? 'homogeneous stripline: FEXT ≈ 0' : 'grows with coupled length (modal velocity difference)'}',
    ),
    Metric(
      id: 'xt_lsat',
      label: 'NEXT saturation length',
      value: lsat,
      unit: 'm',
      status: SiStatus.info,
      level: ModelLevel.advanced,
      note: 'tr·v/2 – NEXT stops growing beyond this parallel length',
    ),
  ];
  final findings = <Finding>[];
  final worstSt = worst([stNext, stFext]);
  if (worstSt != SiStatus.good) {
    final dominant = nextPct >= fextPct ? 'NEXT' : 'FEXT';
    findings.add(Finding(
      status: worstSt,
      title: 'Crosstalk ($dominant)',
      reason: 'With ${mm(x.spacing)} edge spacing (S/W = ${(x.spacing / w).toStringAsFixed(1)}, S/h = '
          '${(x.spacing / g.h1).toStringAsFixed(1)}) the victim sees ${volts(next)} NEXT and ${volts(fext)} FEXT '
          '(${pct(math.max(nextPct, fextPct))} of the aggressor swing). Coupling Kb = ${cpl.kBackward.toStringAsFixed(3)}; '
          'NEXT saturates for parallel runs longer than ${mm(lsat)}.',
      recommendation: [
        if (sGood != null) 'Increase spacing to ≥ ${mm(sGood)} (${milStr(sGood)}) to bring saturated NEXT below ${thr.xtalkGoodPct}%.',
        if (dominant == 'FEXT') 'Shorten the parallel run or route as stripline (FEXT cancels in a homogeneous dielectric).',
        if (dominant == 'NEXT' && x.coupledLength < lsat) 'Shortening the parallel run reduces NEXT (below saturation length).',
        'Reduce dielectric height to the reference plane to tighten coupling to the plane.',
      ].join(' '),
    ));
  }
  Float32List f32(Float64List v) => Float32List.fromList(v);
  final traces = [
    WaveformTrace(id: 'xt_aggressor', label: 'Aggressor (near end)', group: 'Crosstalk', kind: TraceKind.tx, values: f32(aggNear)),
    WaveformTrace(id: 'xt_victim_near', label: 'Victim near end (NEXT)', group: 'Crosstalk', kind: TraceKind.reflected, values: f32(vNear)),
    WaveformTrace(id: 'xt_victim_far', label: 'Victim far end (FEXT)', group: 'Crosstalk', kind: TraceKind.rx, values: f32(vFar)),
  ];
  return CrosstalkOutput(
    metrics,
    findings,
    traces,
    'Crosstalk: aggressor and victim single-ended traces (W ${mm(w)}) parallel for ${mm(x.coupledLength)} at '
        '${mm(x.spacing)} spacing with the protocol driver/receiver on both; coupled section only, lossless'
        '${cfg.protocol.differential ? '; for pairs this is leg-to-leg coupling (differential noise is lower when both legs couple equally)' : ''}.',
  );
}
