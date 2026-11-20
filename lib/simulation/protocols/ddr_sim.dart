/// DDR3 / DDR4 / LPDDR4 memory interface: byte lane and command/address.
///
/// Byte lane (DQ0–7, DM, DQS), point to point, one rank
/// * Write: controller driver (Ron) → trace → DRAM pin C + ODT.
///   Read:  DRAM driver (Ron) → trace → controller pin C + ODT.
/// * ODT returns to VDDQ/2 (DDR3 SSTL), VDDQ (DDR4 POD) or VSSQ (LPDDR4
///   LVSTL). VREF is VDDQ/2 for DDR3 and the trained mid level otherwise.
/// * The eye of DQ − VREF is checked against a rectangular receiver mask
///   centred on the eye (DQS training). The usable width is reduced by the
///   transmitter jitter and, with per-byte training, the DQ-to-DQ skew from
///   the per-signal lengths.
/// * The ODT values of the standard are swept for writes and reads.
///
/// Command / address
/// * DDR3/DDR4 fly-by: lead-in, N devices on short stubs, VTT termination
///   after the last device. LPDDR4: point to point with on-die CA ODT.
/// * CK is launched with CA (centre-aligned); each device samples CA at its
///   own CK arrival, so CA setup/hold is checked per device. LPDDR4 CA is
///   trained (command bus training) and checked like DQ.
/// * The CK delay from the first to the last device is what write leveling
///   must absorb.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../common/format.dart';
import '../impedance/impedance.dart';
import '../metrics/classify.dart';
import '../metrics/eye.dart';
import '../metrics/waveform_metrics.dart';
import '../model/bus_lengths.dart';
import '../model/config.dart';
import '../model/result.dart';
import '../waveform_engine/circuit_solver.dart';
import '../waveform_engine/link_context.dart';
import '../waveform_engine/stimulus.dart';
import 'channel_report.dart';

/// Tail from the last device to the VTT resistor (m).
const double _vttTail = 5e-3;

class _Lane {
  _Lane(this.tx, this.rx, this.vHigh, this.vLow, this.vref, this.eye, this.widthAtMask, this.heightAtCentre);
  final Float64List tx, rx;
  final double vHigh, vLow, vref;
  final EyeResult? eye;
  final double widthAtMask;
  final double heightAtCentre;
}

/// Width of the open region around the eye centre where no trace enters the
/// band ±h/2 (segments are DQ − VREF, 2 UI wide).
double _widthAtHeight(EyeResult e, double h) {
  final n = e.pointsPerSegment;
  final open = List<bool>.filled(n, true);
  for (var s = 0; s < e.segmentCount; s++) {
    for (var i = 0; i < n; i++) {
      if (e.segments[s * n + i].abs() < h / 2) open[i] = false;
    }
  }
  final c = (n - 1) ~/ 2;
  if (!open[c] && !open[c + 1]) return 0;
  var a = open[c] ? c : c + 1, b = a;
  while (a > 0 && open[a - 1]) {
    a--;
  }
  while (b < n - 1 && open[b + 1]) {
    b++;
  }
  return (b - a + 1) * 2 * e.ui / (n - 1);
}

/// Counts eye samples inside a rectangular mask centred on the eye.
int _rectHits(EyeResult e, double w, double h) {
  final n = e.pointsPerSegment;
  var hits = 0;
  for (var s = 0; s < e.segmentCount; s++) {
    for (var i = 0; i < n; i++) {
      final t = (-1 + 2 * i / (n - 1)) * e.ui;
      if (t.abs() <= w / 2 && e.segments[s * n + i].abs() < h / 2) hits++;
    }
  }
  return hits;
}

Float64List _const(int n, double v) => Float64List(n)..fillRange(0, n, v);

SimulationResult simulateDdr(AnalysisConfig cfg) {
  final sw = Stopwatch()..start();
  final p = cfg.ddr;
  final std = p.standard;
  final vddq = p.vddq;
  final ui = p.ui;
  final tck = p.tck;
  final edge1090 = p.edge / 0.6 * 0.8;
  final thr = cfg.thresholds;
  final maskDq = p.dqMask;
  final maskCa = p.caMask;
  final term = std.dqTerm;
  final vTerm = switch (term) { DqTermination.ctt => vddq / 2, DqTermination.pod => vddq, DqTermination.lvstl => 0.0 };

  // ---- Byte-lane lengths ---------------------------------------------------
  final lane = groupLengths(cfg).first;
  final dqsLen = lane.clock;
  final dqMax = lane.dataMax;
  final dqMin = lane.dataMin;
  final bits = patternBits(cfg.sim, cfg.sim.numBits);
  final nb = bits.length;
  final t0 = 3 * ui;

  // CA / CK lengths.
  final flyBy = std.caTopology == CaTopology.flyBy;
  final nDev = flyBy ? p.devices : math.min(p.devices, 2);
  final caLead = p.leadIn;
  final ckLead = math.max(1e-3, p.leadIn - p.caClkMismatch);
  final caBits = math.min(nb, 48);
  final caUi = p.caUi;

  final link = prepareLink(
    cfg: cfg,
    differential: false,
    minEdge: p.edge,
    baseLength: dqMax,
    otherLengths: [dqMin, dqsLen],
    durationFor: (d) => t0 + nb * ui + d + 6 * ui,
  );
  final caLink = prepareLink(
    cfg: cfg,
    differential: false,
    minEdge: p.edge,
    baseLength: caLead,
    otherLengths: [ckLead, p.stub, if (nDev > 1) p.spacing, if (flyBy) _vttTail],
    durationFor: (d) => t0 + caBits * caUi + d + (nDev - 1) * p.spacing * link.line.tpdPerMetre + 6 * caUi,
  );
  final line = link.line;
  final z0 = line.z0;
  final tpd = line.tpdPerMetre;

  // ---- Byte lane -------------------------------------------------------------
  final dqTr = <Transition>[];
  var last = 0;
  for (var k = 0; k < nb; k++) {
    if (bits[k] != last) dqTr.add(Transition(t0 + k * ui, bits[k] == 1 ? vddq : 0));
    last = bits[k];
  }

  _Lane runLane(LinkContext lk, double ron, double rtt, double cio) {
    final dt = lk.dt;
    final n = lk.samples;
    final vs = buildStimulus(initial: 0, transitions: dqTr, riseTime: edge1090, fallTime: edge1090, dt: dt, samples: n);
    final c = Circuit();
    final a = c.node(), b = c.node();
    c.source(a, ron, vs);
    if (cio > 0) {
      c.capacitor(a, -1, cio);
      c.capacitor(b, -1, cio);
    }
    c.line(a, b, z0, lk.withLength(dqMax).delay, lossKernel: lk.kernelFor(dqMax));
    if (term == DqTermination.lvstl) {
      c.resistor(b, -1, rtt);
    } else {
      c.source(b, rtt, _const(n, vTerm));
    }
    final res = c.run(dt: dt, n: n, probe: [a, b]);
    final vH = vTerm + (vddq - vTerm) * rtt / (ron + rtt);
    final vL = vTerm + (0 - vTerm) * rtt / (ron + rtt);
    final vref = term == DqTermination.ctt ? vddq / 2 : (vH + vL) / 2;
    final rx = res.probes[b]!;
    final rel = Float64List.fromList([for (final x in rx) x - vref]);
    final e = computeEye(
      v: rel,
      dt: dt,
      ui: ui,
      bits: bits,
      t0: t0,
      delayEstimate: lk.withLength(dqMax).delay + 0.5 * (ron * rtt / (ron + rtt)) * cio,
      threshold: 0,
      idealEyeHeight: vH - vL,
      label: 'DQ',
      pointsPerSegment: 160,
      measureCrossing: false,
    );
    final w = e == null ? 0.0 : _widthAtHeight(e, maskDq.height);
    return _Lane(res.probes[a]!, rx, vH, vL, vref, e, w, e?.eyeHeight ?? 0);
  }

  // Skew inside the byte (per-byte training centres DQS on the byte only).
  final dqSpreadT = (dqMax - dqMin) * tpd;
  final skewPenalty = p.training == DdrTraining.perByte ? dqSpreadT : 0.0;
  final jitW = p.jitterWrite, jitR = p.jitterReadPp;
  double margin(_Lane l, double jit) => l.widthAtMask - maskDq.width - jit - skewPenalty;

  final wr = runLane(link, p.ctrlRon, p.odtWrite, p.ioCap);
  final rd = runLane(link, p.dramRon, p.odtRead, p.ioCap);
  final wrMargin = margin(wr, jitW);
  final rdMargin = margin(rd, jitR);

  // ODT sweep (writes: DRAM ODT; reads: controller ODT).
  ({double odt, double margin, double height}) sweep(List<double> opts, double ron, double jit) {
    var best = (odt: opts.first, margin: -double.infinity, height: 0.0);
    for (final o in opts) {
      final l = runLane(link, ron, o, p.ioCap);
      final m = margin(l, jit);
      // Options are in ascending order: a weaker (higher) ODT must gain more
      // than 2 % UI to replace a stronger one, which damps ringing better.
      if (m > best.margin + 0.02 * ui) {
        best = (odt: o, margin: m, height: l.heightAtCentre);
      }
    }
    return best;
  }

  // Keep the current ODT when it is within 2 % UI of the best option.
  ({double odt, double margin, double height}) keep(({double odt, double margin, double height}) b, double odt, _Lane cur, double m) =>
      m >= b.margin - 0.02 * ui ? (odt: odt, margin: m, height: cur.heightAtCentre) : b;
  final bestWr = keep(sweep(std.dramOdtOptions, p.ctrlRon, jitW), p.odtWrite, wr, wrMargin);
  final bestRd = keep(sweep(std.ctrlOdtOptions, p.dramRon, jitR), p.odtRead, rd, rdMargin);

  // ---- Command / address and clock ------------------------------------------
  final cdt = caLink.dt;
  final cn = caLink.samples;
  final caVt = flyBy ? vddq / 2 : 0.0;
  ({Map<int, Float64List> v, List<int> dev, Float64List tx}) runCa(Float64List vs, double lead) {
    final c = Circuit();
    final a = c.node();
    c.source(a, p.caRon, vs);
    var j = c.node();
    c.line(a, j, z0, caLink.withLength(lead).delay, lossKernel: caLink.kernelFor(lead));
    final devs = <int>[];
    for (var i = 0; i < nDev; i++) {
      final d = c.node();
      c.line(j, d, z0, caLink.withLength(p.stub).delay, lossKernel: caLink.kernelFor(p.stub));
      c.capacitor(d, -1, p.deviceCap);
      if (!flyBy && i == nDev - 1) c.resistor(d, -1, p.caOdt);
      devs.add(d);
      if (i < nDev - 1) {
        final nj = c.node();
        c.line(j, nj, z0, caLink.withLength(p.spacing).delay, lossKernel: caLink.kernelFor(p.spacing));
        j = nj;
      }
    }
    if (flyBy) {
      final t = c.node();
      c.line(j, t, z0, caLink.withLength(_vttTail).delay, lossKernel: caLink.kernelFor(_vttTail));
      c.source(t, p.vttR, _const(cn, caVt));
    }
    final res = c.run(dt: cdt, n: cn, probe: [a, ...devs]);
    return (v: res.probes, dev: devs, tx: res.probes[a]!);
  }

  final caPattern = [for (var k = 0; k < caBits; k++) bits[(k * 3 + 1) % nb]];
  final caTr = <Transition>[];
  last = 0;
  for (var k = 0; k < caBits; k++) {
    if (caPattern[k] != last) caTr.add(Transition(t0 + k * caUi, caPattern[k] == 1 ? vddq : 0));
    last = caPattern[k];
  }
  final ckPhase = p.twoT && !std.lp ? 0.0 : tck / 2;
  final ckTr = <Transition>[];
  final nCk = ((caBits * caUi) / tck).ceil() + 2;
  for (var m = 0; m < nCk; m++) {
    ckTr.add(Transition(t0 + ckPhase + m * tck, vddq));
    ckTr.add(Transition(t0 + ckPhase + m * tck + tck / 2, 0));
  }
  final caVs = buildStimulus(initial: 0, transitions: caTr, riseTime: edge1090, fallTime: edge1090, dt: cdt, samples: cn);
  final ckVs = buildStimulus(initial: 0, transitions: ckTr, riseTime: edge1090, fallTime: edge1090, dt: cdt, samples: cn);
  final ca = runCa(caVs, caLead);
  final ck = runCa(ckVs, ckLead);

  // DC levels and VREF on the CA bus.
  final double caHigh, caLow;
  if (flyBy) {
    // Approximate: driver into the VTT resistor (device inputs are capacitive).
    caHigh = caVt + (vddq - caVt) * p.vttR / (p.caRon + p.vttR);
    caLow = caVt - caVt * p.vttR / (p.caRon + p.vttR);
  } else {
    caHigh = vddq * p.caOdt / (p.caRon + p.caOdt);
    caLow = 0;
  }
  final caVref = flyBy ? vddq / 2 : (caHigh + caLow) / 2;

  // CK arrival delay at each device (single leg of the pair, 50 % crossing).
  final ckMid = (caHigh + caLow) / 2;
  // The flight time can exceed tCK, so search one period around the expected
  // loaded delay rather than from the launch edge.
  final ckDelay = <double>[];
  final loadF = flyBy && nDev > 1 ? math.sqrt(1 + p.deviceCap / (tpd / z0 * p.spacing)) : 1.0;
  for (var i = 0; i < ck.dev.length; i++) {
    final v = ck.v[ck.dev[i]]!;
    final est = tpd * (ckLead + p.stub + i * p.spacing * loadF) + 0.5 * (z0 / 2) * p.deviceCap + 0.3 * p.edge;
    final ds = <double>[];
    for (var m = 2; m < nCk - 1; m++) {
      final tl = t0 + ckPhase + m * tck;
      final x = firstCrossing(v, cdt, ckMid, true, tl + est - tck / 2, tl + est + tck / 2);
      if (x != null) ds.add(x - tl);
    }
    ckDelay.add(ds.isEmpty ? double.nan : ds.reduce((a, b) => a + b) / ds.length);
  }
  final flySkew = ckDelay.length > 1 ? ckDelay.last - ckDelay.first : 0.0;

  // CA timing at each device.
  final caVih = caVref + maskCa.height / 2, caVil = caVref - maskCa.height / 2;
  final tis = maskCa.setup ?? maskCa.width / 2, tih = maskCa.hold ?? maskCa.width / 2;
  final caSetup = <double>[], caHold = <double>[];
  final caEyes = <EyeResult?>[];
  final caWidths = <double>[];
  for (var i = 0; i < nDev; i++) {
    final v = ca.v[ca.dev[i]]!;
    if (std.lp) {
      // Trained CA: rectangular mask like DQ.
      final rel = Float64List.fromList([for (final x in v) x - caVref]);
      final e = computeEye(
          v: rel, dt: cdt, ui: caUi, bits: caPattern, t0: t0, delayEstimate: ckDelay[i].isNaN ? 0 : ckDelay[i],
          threshold: 0, idealEyeHeight: caHigh - caLow, label: 'CA @ die ${i + 1}', pointsPerSegment: 160,
          measureCrossing: false);
      final w = e == null ? 0.0 : _widthAtHeight(e, maskCa.height);
      caEyes.add(e);
      caWidths.add(w);
      final mg = (w - maskCa.width - jitW) / 2;
      caSetup.add(mg);
      caHold.add(mg);
      continue;
    }
    var su = double.infinity, ho = double.infinity;
    for (var k = 3; k < caBits - 1; k++) {
      final ts = t0 + k * caUi + caUi / 2 + ckDelay[i];
      final entry = lastValidEntry(v, cdt, caPattern[k], caVih, caVil, ts, lookBack: 2 * caUi);
      if (entry == null) {
        // Not valid at the sampling edge: setup deficit = time until it is.
        final th = caPattern[k] == 1 ? caVih : caVil;
        final tv = firstCrossing(v, cdt, th, caPattern[k] == 1, ts, ts + caUi);
        su = math.min(su, tv == null ? -caUi : -(tv - ts) - tis);
        continue;
      }
      su = math.min(su, ts - entry - tis);
      final exit = firstInvalidExit(v, cdt, caPattern[k], caVih, caVil, ts, ts + 2 * caUi);
      if (exit != null) ho = math.min(ho, exit - ts - tih);
    }
    caSetup.add(su);
    caHold.add(ho.isFinite ? ho : caUi / 2);
    final rel = Float64List.fromList([for (final x in v) x - caVref]);
    caEyes.add(computeEye(
        v: rel, dt: cdt, ui: caUi, bits: caPattern, t0: t0, delayEstimate: ckDelay[i].isNaN ? 0 : ckDelay[i],
        threshold: 0, idealEyeHeight: caHigh - caLow, label: 'CA @ device ${i + 1}', pointsPerSegment: 160,
        measureCrossing: false));
    caWidths.add(0);
  }
  var worstDev = 0;
  for (var i = 1; i < nDev; i++) {
    if (math.min(caSetup[i], caHold[i]) < math.min(caSetup[worstDev], caHold[worstDev])) worstDev = i;
  }
  final caSu = caSetup[worstDev], caHo = caHold[worstDev];

  // Loaded fly-by impedance.
  final c0 = tpd / z0; // F/m
  final zLoaded = flyBy && nDev > 1 ? z0 / math.sqrt(1 + p.deviceCap / (c0 * p.spacing)) : z0;

  // Write leveling: CK must reach each DRAM after DQS (leveling only delays DQS).
  final ckToFirst = ckLead + p.stub;
  final ckShort = flyBy && ckToFirst < dqsLen;

  // ---- Edge quality ------------------------------------------------------------
  double peak(Iterable<Float64List> vs) => vs.map((v) => v.reduce(math.max)).reduce(math.max);
  double trough(Iterable<Float64List> vs) => vs.map((v) => v.reduce(math.min)).reduce(math.min);
  final allRx = [wr.rx, rd.rx, for (final d in ca.dev) ca.v[d]!];
  final over = math.max(0.0, peak(allRx) - vddq);
  final under = math.max(0.0, -trough(allRx));
  final swing = wr.vHigh - wr.vLow;

  // ---- Metrics -------------------------------------------------------------------
  final imp = link.impedance;
  final zDev = (imp.z0 - p.targetZ0) / p.targetZ0 * 100;
  SiStatus marginStatus(double m, double unit) => m < 0 ? SiStatus.critical : (m < 0.1 * unit ? SiStatus.warning : SiStatus.good);
  String eyeNote(_Lane l, double jit) => 'Eye ${secs(l.widthAtMask)} wide at ±${volts(maskDq.height / 2)}, height ${volts(l.heightAtCentre)}; '
      'needs mask ${secs(maskDq.width)} + jitter ${secs(jit)}${skewPenalty > 0 ? ' + DQ skew ${secs(skewPenalty)}' : ''}';
  final metrics = <Metric>[
    Metric(
      id: 'z0',
      label: 'Characteristic impedance Z0',
      value: imp.z0,
      unit: 'ohm',
      target: p.targetZ0,
      status: classifyHigherWorse(zDev.abs(), thr.impedanceGoodPct, thr.impedanceWarnPct),
      level: ModelLevel.analytical,
      note: imp.method,
    ),
    Metric(
      id: 'zdev',
      label: 'Impedance deviation',
      value: zDev,
      unit: '%',
      status: classifyHigherWorse(zDev.abs(), thr.impedanceGoodPct, thr.impedanceWarnPct),
      level: ModelLevel.analytical,
    ),
    Metric(
      id: 'wr_margin',
      label: 'Write eye margin @ DRAM (ODT ${ohm(p.odtWrite)})',
      value: wrMargin,
      unit: 's',
      status: marginStatus(wrMargin, ui),
      level: ModelLevel.behavioral,
      note: eyeNote(wr, jitW),
    ),
    Metric(
      id: 'wr_height',
      label: 'Write eye height @ DRAM',
      value: wr.heightAtCentre,
      unit: 'V',
      status: wr.heightAtCentre < maskDq.height ? SiStatus.critical : (wr.heightAtCentre < 1.5 * maskDq.height ? SiStatus.warning : SiStatus.good),
      level: ModelLevel.behavioral,
      note: 'Mask height ${volts(maskDq.height)} around VREF ${volts(wr.vref)} (${maskDq.source})',
    ),
    Metric(
      id: 'rd_margin',
      label: 'Read eye margin @ controller (ODT ${ohm(p.odtRead)})',
      value: rdMargin,
      unit: 's',
      status: marginStatus(rdMargin, ui),
      level: ModelLevel.behavioral,
      note: eyeNote(rd, jitR),
    ),
    Metric(
      id: 'rd_height',
      label: 'Read eye height @ controller',
      value: rd.heightAtCentre,
      unit: 'V',
      status: rd.heightAtCentre < maskDq.height ? SiStatus.critical : (rd.heightAtCentre < 1.5 * maskDq.height ? SiStatus.warning : SiStatus.good),
      level: ModelLevel.behavioral,
      note: 'VREF ${volts(rd.vref)}',
    ),
    Metric(
      id: 'odt_wr_best',
      label: 'Best DRAM ODT for writes',
      value: bestWr.odt,
      unit: 'ohm',
      status: SiStatus.info,
      level: ModelLevel.behavioral,
      note: bestWr.odt == p.odtWrite
          ? 'The current setting is within 2 % UI of the best; swept ${std.dramOdtOptions.map((o) => o.toStringAsFixed(0)).join('/')} Ω'
          : 'Margin ${secs(bestWr.margin)} (current ${ohm(p.odtWrite)}: ${secs(wrMargin)}); swept ${std.dramOdtOptions.map((o) => o.toStringAsFixed(0)).join('/')} Ω',
    ),
    Metric(
      id: 'odt_rd_best',
      label: 'Best controller ODT for reads',
      value: bestRd.odt,
      unit: 'ohm',
      status: SiStatus.info,
      level: ModelLevel.behavioral,
      note: bestRd.odt == p.odtRead
          ? 'The current setting is within 2 % UI of the best'
          : 'Margin ${secs(bestRd.margin)} (current ${ohm(p.odtRead)}: ${secs(rdMargin)})',
    ),
    Metric(
      id: 'dq_spread',
      label: 'DQ-to-DQ skew in the byte',
      value: dqSpreadT,
      unit: 's',
      status: p.training == DdrTraining.perBit
          ? SiStatus.info
          : classifyHigherWorse(dqSpreadT / ui * 100, thr.skewGoodPctUi, thr.skewWarnPctUi),
      level: ModelLevel.analytical,
      note: '${dqMax - dqMin < 1e-9 ? 'All DQ ${mm(dqMax)}' : '${lane.shortest.name} ${mm(dqMin)} – ${lane.longest.name} ${mm(dqMax)}'}'
          '${p.training == DdrTraining.perBit ? '; removed by per-bit deskew' : '; reduces the eye with per-byte training'}',
    ),
    Metric(
      id: 'dqs_dq',
      label: 'DQS to byte routing offset',
      value: (dqsLen - (dqMax + dqMin) / 2) * tpd,
      unit: 's',
      status: SiStatus.info,
      level: ModelLevel.analytical,
      note: 'DQS ${mm(dqsLen)}; removed by DQS-DQ training',
    ),
    Metric(
      id: 'ca_su',
      label: '${std.lp ? 'CA margin (trained)' : 'CA setup slack'} @ ${flyBy ? 'device' : 'die'} ${worstDev + 1}',
      value: caSu,
      unit: 's',
      status: marginStatus(caSu, caUi / 2),
      level: ModelLevel.behavioral,
      note: std.lp
          ? 'Width ${secs(caWidths[worstDev])} at ±${volts(maskCa.height / 2)} vs TcIVW ${secs(maskCa.width)} (${maskCa.source})'
          : 'tIS ${secs(tis)}, VIH/VIL(AC) ±${volts(maskCa.height / 2)} around ${volts(caVref)} (${maskCa.source})',
    ),
    if (!std.lp)
      Metric(
        id: 'ca_ho',
        label: 'CA hold slack @ device ${worstDev + 1}',
        value: caHo,
        unit: 's',
        status: marginStatus(caHo, caUi / 2),
        level: ModelLevel.behavioral,
        note: 'tIH ${secs(tih)}; worst of $nDev device(s)',
      ),
    if (flyBy && nDev > 1) ...[
      Metric(
        id: 'flyby_skew',
        label: 'CK fly-by delay, first → last device',
        value: flySkew,
        unit: 's',
        status: flySkew > 2 * tck ? SiStatus.warning : SiStatus.info,
        level: ModelLevel.behavioral,
        note: '${(flySkew / tck).toStringAsFixed(2)} tCK – absorbed by write leveling',
      ),
      Metric(
        id: 'z_loaded',
        label: 'Loaded fly-by impedance',
        value: zLoaded,
        unit: 'ohm',
        status: (p.vttR - zLoaded).abs() / zLoaded > 0.35 ? SiStatus.warning : SiStatus.good,
        level: ModelLevel.analytical,
        note: '${ohm(z0)} trace with ${eng(p.deviceCap, 'F')} every ${mm(p.spacing)}; VTT resistor ${ohm(p.vttR)}',
      ),
    ],
    Metric(
      id: 'overshoot',
      label: 'Overshoot above VDDQ (worst pin)',
      value: over,
      unit: 'V',
      status: classifyHigherWorse(over / swing * 100, thr.overshootGoodPct, thr.overshootWarnPct),
      level: ModelLevel.behavioral,
    ),
    Metric(
      id: 'undershoot',
      label: 'Undershoot below VSS (worst pin)',
      value: under,
      unit: 'V',
      status: classifyHigherWorse(under / swing * 100, thr.overshootGoodPct, thr.overshootWarnPct),
      level: ModelLevel.behavioral,
    ),
  ];

  // ---- Findings ---------------------------------------------------------------------
  final findings = <Finding>[];
  void eyeFinding(String dir, double m, _Lane l, double jit, double odt, ({double odt, double margin, double height}) best, String odtName) {
    if (m >= 0.1 * ui) return;
    final recs = <String>[
      if (best.odt != odt && best.margin > m + 0.02 * ui) 'Set $odtName to ${ohm(best.odt)} (margin ${secs(best.margin)}).',
      if (skewPenalty > 0.05 * ui) 'Match DQ0–7/DM within the byte: ${lane.longest.name} is ${mm(dqMax - dqMin)} longer than ${lane.shortest.name}.',
      if (l.heightAtCentre < 1.5 * maskDq.height) 'The eye is short: check the trace impedance (${ohm(imp.z0)}) and loss, or use a stronger driver.',
      'Shorten the byte lane (now ${mm(dqMax)}) or lower the data rate.',
    ];
    findings.add(Finding(
      status: m < 0 ? SiStatus.critical : SiStatus.warning,
      title: m < 0 ? '$dir eye fails the receiver mask' : '$dir eye margin is small',
      reason: '${eyeNote(l, jit)}. Margin ${secs(m)} (${(m / ui * 100).toStringAsFixed(0)} % UI).',
      recommendation: recs.join(' '),
    ));
  }

  eyeFinding('Write', wrMargin, wr, jitW, p.odtWrite, bestWr, 'the DRAM write ODT (RTT_WR/RTT_NOM)');
  eyeFinding('Read', rdMargin, rd, jitR, p.odtRead, bestRd, 'the controller read ODT');
  if (math.min(caSu, caHo) < 0.1 * caUi / 2) {
    final bad = math.min(caSu, caHo) < 0;
    findings.add(Finding(
      status: bad ? SiStatus.critical : SiStatus.warning,
      title: bad ? 'Command/address timing fails' : 'Command/address margin is small',
      reason: std.lp
          ? 'Die ${worstDev + 1}: CA eye ${secs(caWidths[worstDev])} wide at the mask height, TcIVW ${secs(maskCa.width)}.'
          : 'Device ${worstDev + 1} of $nDev: setup slack ${secs(caSu)}, hold slack ${secs(caHo)} '
              '(tIS ${secs(tis)}, tIH ${secs(tih)}, ${p.twoT ? '2T' : '1T'} timing). '
              '${worstDev == 0 && nDev > 1 ? 'The first device sees the most reflection from the stubs that follow it.' : ''}',
      recommendation: [
        if (flyBy && (p.vttR - zLoaded).abs() / zLoaded > 0.25) 'Use a VTT resistor near the loaded impedance (≈ ${ohm(zLoaded)}).',
        if (flyBy && p.stub > 3e-3) 'Shorten the stubs to the devices (now ${mm(p.stub)}).',
        if (!p.twoT && !std.lp) 'Enable 2T command timing if the controller supports it.',
        if (p.caClkMismatch.abs() > 2e-3) 'Match CA to CK (now ${mm(p.caClkMismatch)} difference).',
        'Lower the CA trace impedance toward the loaded value or reduce the number of devices per fly-by.',
      ].join(' '),
    ));
  }
  if (ckShort) {
    findings.add(Finding(
      status: SiStatus.warning,
      title: 'CK shorter than DQS at the first DRAM',
      reason: 'CK reaches device 1 through ${mm(ckToFirst)}, DQS through ${mm(dqsLen)}. Write leveling can only delay DQS, '
          'so most controllers need CK to arrive after DQS at every DRAM.',
      recommendation: 'Lengthen the CK lead-in by ≈ ${mm(dqsLen - ckToFirst + 2e-3)} (or shorten DQS), keeping CA matched to CK.',
    ));
  }
  if (flyBy && nDev > 1 && flySkew > 2 * tck) {
    findings.add(Finding(
      status: SiStatus.warning,
      title: 'Large fly-by delay',
      reason: 'CK reaches the last device ${secs(flySkew)} (${(flySkew / tck).toStringAsFixed(1)} tCK) after the first.',
      recommendation: 'Check the write-leveling range of the controller; reduce the device spacing if it is exceeded.',
    ));
  }
  if (_m('zdev', metrics).status != SiStatus.good) {
    final w = solveWidthForTarget(link.geometry, p.targetZ0);
    findings.add(Finding(
      status: _m('zdev', metrics).status,
      title: 'Impedance mismatch',
      reason: 'Z0 = ${ohm(imp.z0)} deviates ${pct(zDev)} from the ${ohm(p.targetZ0)} target.',
      recommendation: w != null ? 'Use a trace width of ≈ ${milStr(w)} (${mm(w)}).' : 'Review the stackup.',
    ));
  }
  if (_m('overshoot', metrics).status != SiStatus.good || _m('undershoot', metrics).status != SiStatus.good) {
    findings.add(Finding(
      status: worst([_m('overshoot', metrics).status, _m('undershoot', metrics).status]),
      title: 'Overshoot / undershoot',
      reason: 'Peak ${volts(over)} above VDDQ and ${volts(under)} below VSS on the worst pin.',
      recommendation: 'Increase ODT strength (lower RTT) or reduce the driver strength (higher Ron).',
    ));
  }
  final chan = channelReport(cfg, link, 0.5 / ui, differential: false);
  metrics.addAll(chan.metrics);
  findings.addAll(chan.findings);
  if (findings.isEmpty) {
    findings.add(Finding(
      status: SiStatus.good,
      title: '${std.label}-${p.rate} passes with margin',
      reason: 'Write and read eyes clear the receiver mask with margin, and command/address timing is met at every device.',
      recommendation: 'Confirm with the controller vendor\'s IBIS models and the full byte-lane and fly-by topology.',
    ));
  }

  // ---- Compliance-style checks ---------------------------------------------------------
  final checks = <ComplianceCheck>[
    ComplianceCheck(
        name: 'Trace impedance',
        requirement: '${ohm(p.targetZ0)} ±${thr.impedanceWarnPct.toStringAsFixed(0)} %',
        measured: '${ohm(imp.z0)} (${pct(zDev.abs())})',
        pass: zDev.abs() <= thr.impedanceWarnPct,
        source: 'configured limit'),
    ComplianceCheck(
        name: 'Write eye vs Rx mask @ DRAM',
        requirement: '${secs(maskDq.width)} × ${volts(maskDq.height)} (approx.) + jitter/skew',
        measured: 'margin ${secs(wrMargin)}',
        pass: wrMargin >= 0,
        source: 'spec reference'),
    ComplianceCheck(
        name: 'Read eye vs Rx mask @ controller',
        requirement: '${secs(maskDq.width)} × ${volts(maskDq.height)} (approx.) + jitter/skew',
        measured: 'margin ${secs(rdMargin)}',
        pass: rdMargin >= 0,
        source: 'spec reference'),
    ComplianceCheck(
        name: std.lp ? 'CA eye vs CA Rx mask' : 'CA setup / hold (tIS / tIH)',
        requirement: std.lp ? '${secs(maskCa.width)} × ${volts(maskCa.height)} (approx.)' : 'slack ≥ 0 at every device (approx. tIS/tIH)',
        measured: std.lp ? 'margin ${secs(caSu)}' : 'setup ${secs(caSu)}, hold ${secs(caHo)}',
        pass: math.min(caSu, caHo) >= 0,
        source: 'spec reference'),
    if (flyBy)
      ComplianceCheck(
          name: 'CK arrives after DQS at each DRAM',
          requirement: 'CK length ≥ DQS length (common controller rule)',
          measured: 'CK ${mm(ckToFirst)}, DQS ${mm(dqsLen)}',
          pass: !ckShort,
          source: 'configured limit'),
  ];

  // ---- Waveforms and eyes ------------------------------------------------------------------
  final traces = <WaveformTrace>[
    WaveformTrace(id: 'wr_tx', label: 'Write DQ @ controller', group: 'Write', kind: TraceKind.tx, values: Float32List.fromList(wr.tx)),
    WaveformTrace(id: 'wr_rx', label: 'Write DQ @ DRAM', group: 'Write', kind: TraceKind.rx, values: Float32List.fromList(wr.rx)),
    WaveformTrace(id: 'rd_tx', label: 'Read DQ @ DRAM', group: 'Read', kind: TraceKind.tx, values: Float32List.fromList(rd.tx)),
    WaveformTrace(id: 'rd_rx', label: 'Read DQ @ controller', group: 'Read', kind: TraceKind.rx, values: Float32List.fromList(rd.rx)),
  ];
  // CA / CK run on their own time step: resample onto the byte-lane grid.
  Float32List resample(Float64List v) {
    final n = link.samples;
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      final x = i * link.dt / cdt;
      final k = x.floor();
      if (k >= v.length - 1) {
        out[i] = v.last;
      } else {
        final f = x - k;
        out[i] = v[k] * (1 - f) + v[k + 1] * f;
      }
    }
    return out;
  }

  final caIds = <String>[];
  for (var i = 0; i < nDev; i++) {
    if (nDev > 2 && i != 0 && i != nDev - 1) continue;
    final id = 'ca_d$i';
    caIds.add(id);
    traces.add(WaveformTrace(
        id: id, label: 'CA @ ${flyBy ? 'device' : 'die'} ${i + 1}', group: 'CA', kind: TraceKind.rx, values: resample(ca.v[ca.dev[i]]!)));
  }
  traces.add(WaveformTrace(id: 'ca_tx', label: 'CA @ controller', group: 'CA', kind: TraceKind.tx, values: resample(ca.tx)));
  traces.add(WaveformTrace(id: 'ck_d0', label: 'CK (one leg) @ ${flyBy ? 'device' : 'die'} 1', group: 'CK', kind: TraceKind.rx, values: resample(ck.v[ck.dev.first]!)));
  if (nDev > 1) {
    traces.add(WaveformTrace(
        id: 'ck_dn', label: 'CK (one leg) @ ${flyBy ? 'device' : 'die'} $nDev', group: 'CK', kind: TraceKind.rx, values: resample(ck.v[ck.dev.last]!)));
  }
  final views = <String, List<String>>{
    'Write DQ': ['wr_tx', 'wr_rx'],
    'Read DQ': ['rd_tx', 'rd_rx'],
    'CA ${flyBy ? 'fly-by' : 'bus'}': ['ca_tx', ...caIds],
    'CK': ['ck_d0', if (nDev > 1) 'ck_dn'],
  };
  final eyes = <EyeResult>[];
  void addEye(EyeResult? e, String label, DdrMask mask) {
    if (e == null) return;
    final x = EyeResult(
      ui: e.ui,
      segments: e.segments,
      pointsPerSegment: e.pointsPerSegment,
      eyeHeight: e.eyeHeight,
      eyeWidth: e.eyeWidth,
      crossingPct: e.crossingPct,
      jitterPkPk: e.jitterPkPk,
      idealEyeHeight: e.idealEyeHeight,
      vMin: e.vMin,
      vMax: e.vMax,
      traceLabel: label,
      eyeTop: e.eyeTop,
      eyeBottom: e.eyeBottom,
      phaseDelay: e.phaseDelay,
      crossingOffsets: e.crossingOffsets,
    )
      ..maskHeight = mask.height
      ..maskWidth = mask.width
      ..maskRect = true
      ..maskHits = _rectHits(e, mask.width, mask.height)
      ..maskSamples = e.segmentCount * e.pointsPerSegment;
    eyes.add(x);
  }

  addEye(wr.eye, 'Write DQ − VREF @ DRAM', maskDq);
  addEye(rd.eye, 'Read DQ − VREF @ controller', maskDq);
  addEye(caEyes[worstDev], 'CA − VREF @ ${flyBy ? 'device' : 'die'} ${worstDev + 1}', maskCa);

  final assumptions = <String>[
    ...chan.assumptions,
    ...link.assumptions,
    '${std.label}-${p.rate}: UI ${secs(ui)}, VDDQ ${volts(vddq)}, ${switch (term) { DqTermination.ctt => 'SSTL with ODT to VDDQ/2', DqTermination.pod => 'POD with ODT to VDDQ', DqTermination.lvstl => 'LVSTL with ODT to VSSQ' }}.',
    'Byte lane point to point, one rank (no RTT_PARK on a second rank). Drivers are linear: Ron behind an ideal source with '
        '${secs(p.edge)} 20–80 % edges; ${eng(p.ioCap, 'F')} pin capacitance at each end; no package model.',
    'VREF ${term == DqTermination.ctt ? 'fixed at VDDQ/2' : 'trained to the middle of the received levels'}; DQS centred on the '
        '${p.training == DdrTraining.perBit ? 'each DQ bit (per-bit deskew)' : 'byte (per-byte training)'}. Subtracted from the eye width: '
        'controller TX jitter ${secs(jitW)} (writes) and DRAM output uncertainty ≈ 1 − tQH ${secs(jitR)} (reads), pk-pk. '
        'Crosstalk, SSO and package effects are not modelled beyond these allowances.',
    'Masks: DQ ${secs(maskDq.width)} × ${volts(maskDq.height)} (${maskDq.source}); CA ${std.lp ? '${secs(maskCa.width)} × ' : 'tIS ${secs(tis)} / tIH ${secs(tih)}, '}'
        '${volts(maskCa.height)} (${maskCa.source}). Approximate reference values – check the DRAM datasheet.',
    flyBy
        ? 'CA/CK fly-by: lead-in ${mm(caLead)} (CK ${mm(ckLead)}), $nDev devices every ${mm(p.spacing)} on ${mm(p.stub)} stubs, '
            '${eng(p.deviceCap, 'F')} per device, ${ohm(p.vttR)} to VTT ${mm(_vttTail)} after the last device. CK simulated as one '
            'leg of the pair; CA launched centre-aligned to CK (${p.twoT ? '2T' : '1T'}).'
        : 'CA point to point: ${mm(caLead)} to ${nDev == 1 ? 'one die' : '$nDev dies'}, on-die CA ODT ${ohm(p.caOdt)} to VSSQ; CA trained.',
    if (flyBy) 'The byte lane is assumed to connect to the first device (worst case for the CK-after-DQS rule).',
  ];
  sw.stop();
  return SimulationResult(
    config: cfg,
    dt: link.dt,
    sampleCount: link.samples,
    traces: traces,
    views: views,
    metrics: metrics,
    findings: findings,
    assumptions: assumptions,
    impedance: ImpedanceSummary(
      structure: link.geometry.structure.label,
      z0: imp.z0,
      zDiff: null,
      eeff: imp.eeff,
      target: p.targetZ0,
      targetIsDiff: false,
      method: imp.method,
      widthForTarget: solveWidthForTarget(link.geometry, p.targetZ0),
    ),
    eyes: eyes,
    animation: null,
    computeMillis: sw.elapsedMilliseconds,
    checks: checks,
  );
}

Metric _m(String id, List<Metric> ms) => ms.firstWhere((x) => x.id == id);
