/// Ethernet RGMII (Reduced Gigabit Media Independent Interface) timing.
///
/// Model
/// * Source-synchronous single-ended bus: a clock (TXC / RXC) and data
///   (TXD[3:0], TX_CTL / RXD[3:0], RX_CTL) launched edge-aligned by the
///   transmitter (RGMII v2.0). At 1000 Mb/s data changes on both clock edges
///   (125 MHz DDR); at 100 / 10 Mb/s on the rising edge.
/// * The receiver samples each bit at the arriving clock edge plus the clock
///   delay: internal delay (MAC TX / PHY RX "RGMII-ID", typically 1.5-2 ns)
///   and/or a longer PCB clock trace.
/// * Setup slack = t_sample - t_valid - TsetupR - TskewT,
///   hold slack = t_invalid - t_sample - TholdR - TskewT, where t_valid /
///   t_invalid are the data entering / leaving the VIH / VIL region at the
///   receiver pin. TskewT (transmitter clock-to-data skew) is applied as a
///   worst-case reduction of both.
/// * One representative data line; TX and RX directions share the routing
///   and buffers and differ only in their clock delay.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../common/format.dart';
import '../impedance/impedance.dart';
import '../metrics/classify.dart';
import '../metrics/compliance.dart';
import '../metrics/waveform_metrics.dart';
import '../model/config.dart';
import '../model/result.dart';
import '../termination/termination.dart';
import '../waveform_engine/channel_builder.dart';
import '../waveform_engine/line_solver.dart';
import '../waveform_engine/link_context.dart';
import '../waveform_engine/stimulus.dart';
import 'channel_report.dart';

SimulationResult simulateRgmii(AnalysisConfig cfg) {
  final sw = Stopwatch()..start();
  final p = cfg.rgmii;
  final thr = cfg.thresholds;
  final vdd = p.voltage;
  final f = p.speed.clockHz;
  final tclk = 1 / f;
  final half = tclk / 2;
  final ddr = p.speed.ddr;
  final tBit = ddr ? half : tclk;
  final bits = patternBits(cfg.sim, cfg.sim.numBits);
  final nb = bits.length;
  final clkLen = cfg.pcb.traceLength + p.clockExtraLength;
  final t0 = tclk;
  // Clock edge k (k counts bits for DDR, rising edges otherwise).
  double edge(int k) => t0 + (ddr ? k * half : k * tclk);
  final nEdges = ddr ? nb + 2 : 2 * nb + 2;
  final tStop = t0 + (ddr ? (nb + 2) * half : (nb + 1) * tclk);
  final maxDelay = math.max(p.txClockDelay, p.rxClockDelay);

  final link = prepareLink(
    cfg: cfg,
    differential: false,
    minEdge: math.min(p.riseTime, p.fallTime),
    extraLength: p.clockExtraLength,
    durationFor: (t) => tStop + 4 * t + maxDelay + 2 * tclk,
  );
  final dt = link.dt;
  final n = link.samples;
  final tEnd = (n - 1) * dt;
  final line = link.line;
  final z0 = line.z0;
  final dataDelay = line.delay;
  final clkDelay = link.withLength(clkLen).delay;
  final source = SourceEnd(rDriver: p.driverImpedance, rSeries: p.seriesR);
  final load = LoadEnd(rIn: 1e6, cIn: p.receiverCap);

  Float64List stim(double initial, List<Transition> t) => buildStimulus(
        initial: initial,
        transitions: t,
        riseTime: p.riseTime,
        fallTime: p.fallTime,
        dt: dt,
        samples: n,
      );
  LineSolution solve(Float64List vs, double length) => solveLeg(
        link: link,
        length: length,
        vs: vs,
        source: source,
        load: load,
        elements: cfg.pcb.elements,
      );

  // Clock: 50 % duty, first rising edge at t0.
  final clkTr = <Transition>[];
  for (var k = 0; k < nEdges; k++) {
    final t = t0 + k * half;
    clkTr.add(Transition(t, k.isEven ? vdd : 0));
  }
  final dataTr = <Transition>[];
  var last = 0;
  for (var k = 0; k < nb; k++) {
    if (bits[k] != last) dataTr.add(Transition(edge(k), bits[k] == 1 ? vdd : 0));
    last = bits[k];
  }
  final clkVs = stim(0, clkTr);
  final dataVs = stim(0, dataTr);
  final clk = solve(clkVs, clkLen);
  final data = solve(dataVs, cfg.pcb.traceLength);

  final vHigh = dcLineVoltage(vdd, source, load);
  final vLow = 0.0;
  final vMid = vHigh / 2;
  final vih = 0.7 * vdd;
  final vil = 0.3 * vdd;

  // Clock arrival (50 %) for each data bit's launching edge.
  final arr = <double>[];
  for (var k = 0; k < nb; k++) {
    final te = edge(k);
    final rising = ddr ? k.isEven : true;
    arr.add(firstCrossing(clk.vFar, dt, vMid, rising, te, te + clkDelay + half) ?? te + clkDelay);
  }

  ({double setup, double hold}) timing(double clockDelay) {
    var su = double.infinity, ho = double.infinity;
    for (var k = 0; k < nb; k++) {
      final ts = arr[k] + clockDelay;
      if (ts >= tEnd) continue;
      final entry = lastValidEntry(data.vFar, dt, bits[k], vih, vil, ts, lookBack: 2 * tBit);
      if (entry == null) {
        su = math.min(su, -tBit);
        continue;
      }
      su = math.min(su, ts - entry - p.setupTime - p.txSkew);
      final exit = firstInvalidExit(data.vFar, dt, bits[k], vih, vil, ts, math.min(ts + 2 * tBit, tEnd));
      if (exit != null) ho = math.min(ho, exit - ts - p.holdTime - p.txSkew);
    }
    return (setup: su, hold: ho);
  }

  final tx = timing(p.txClockDelay);
  final rx = timing(p.rxClockDelay);
  // Clock delay that maximises the worst of setup and hold (swept).
  var bestDelay = double.nan, bestMargin = -double.infinity;
  for (var i = 0; i <= 200; i++) {
    final d = 1.5 * tBit * i / 200;
    final t = timing(d);
    final mg = math.min(t.setup, t.hold.isFinite ? t.hold : t.setup);
    if (mg > bestMargin) {
      bestMargin = mg;
      bestDelay = d;
    }
  }
  double optimum(({double setup, double hold}) t, double d) => bestDelay;

  // Edge statistics.
  List<ExpectedEdge> expected(List<Transition> tr, double delay) {
    final out = <ExpectedEdge>[];
    var prev = 0.0;
    for (var i = 0; i < tr.length; i++) {
      final rising = tr[i].level > prev;
      final arrT = tr[i].t50 + delay;
      final next = i + 1 < tr.length ? tr[i + 1].t50 + delay - p.riseTime : tEnd;
      out.add(ExpectedEdge(t50: arrT, rising: rising, windowStart: arrT - 2 * p.riseTime, windowEnd: next));
      prev = tr[i].level;
    }
    return out;
  }

  EdgeStats stats(LineSolution s, List<Transition> tr, double delay) => measureEdges(
        v: s.vFar,
        dt: dt,
        vLow: vLow,
        vHigh: vHigh,
        vil: vil,
        vih: vih,
        edges: expected(tr, delay),
      );
  final sClk = stats(clk, clkTr, clkDelay);
  final sData = stats(data, dataTr, dataDelay);
  final swing = vHigh - vLow;
  final os = math.max(sClk.overshoot, sData.overshoot);
  final us = math.max(sClk.undershoot, sData.undershoot);
  final rb = math.min(sClk.ringbackHigh, sClk.ringbackLow);
  // RGMII specifies 20-80 % edges; for a linear-like edge 20-80 ≈ 0.75 × 10-90.
  final clkRise2080 = sClk.riseTime * 0.75;

  // ---- Metrics -----------------------------------------------------------
  final imp = link.impedance;
  final zDev = (z0 - p.targetZ0) / p.targetZ0 * 100;
  final tr = math.min(p.riseTime, p.fallTime);
  final longLine = dataDelay > tr / 6;
  final gl = loadReflection(load, z0);
  final fKnee = 0.35 / tr;
  final il = line.insertionLossDb(fKnee);
  final routeSkew = clkDelay - dataDelay;
  final width = solveWidthForTarget(link.geometry, p.targetZ0);
  // RGMII budgets are tight by design (2 ns delay vs 1 ns setup + 0.5 ns skew),
  // so only slack below 100 ps is flagged as a warning.
  const warnSlack = 0.1e-9;
  SiStatus slack(double v) => v.isFinite ? classifySlack(v, warnSlack) : SiStatus.info;

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
      id: 'delay',
      label: 'Data trace delay',
      value: dataDelay,
      unit: 's',
      status: SiStatus.info,
      level: ModelLevel.analytical,
      note: '${mm(cfg.pcb.traceLength)} · ${(line.tpdPerMetre * 1e9).toStringAsFixed(2)} ps/mm',
    ),
    Metric(
      id: 'clkskew',
      label: 'Clock-to-data routing delay',
      value: routeSkew,
      unit: 's',
      status: SiStatus.info,
      level: ModelLevel.analytical,
      note: p.clockExtraLength == 0
          ? 'Clock and data matched in length'
          : 'Clock trace ${mm(p.clockExtraLength)} ${p.clockExtraLength > 0 ? 'longer' : 'shorter'} than data',
    ),
    Metric(
      id: 'il',
      label: 'Line loss at f_knee (${eng(fKnee, 'Hz')})',
      value: il,
      unit: 'dB',
      status: classifyHigherWorse(il, thr.lossGoodDb, thr.lossWarnDb),
      level: ModelLevel.analytical,
    ),
    Metric(
      id: 'overshoot',
      label: 'Overshoot (worst line)',
      value: os,
      unit: 'V',
      status: classifyHigherWorse(os / swing * 100, thr.overshootGoodPct, thr.overshootWarnPct),
      level: ModelLevel.behavioral,
      note: '${pct(os / swing * 100)} of swing',
    ),
    Metric(
      id: 'undershoot',
      label: 'Undershoot (worst line)',
      value: us,
      unit: 'V',
      status: classifyHigherWorse(us / swing * 100, thr.overshootGoodPct, thr.overshootWarnPct),
      level: ModelLevel.behavioral,
    ),
    Metric(
      id: 'clk_tr',
      label: 'Clock rise time at receiver (20–80 %)',
      value: clkRise2080,
      unit: 's',
      status: clkRise2080.isNaN ? SiStatus.info : (clkRise2080 <= 0.75e-9 ? SiStatus.good : SiStatus.warning),
      level: ModelLevel.behavioral,
      note: 'RGMII limit 0.75 ns; estimated from the 10–90 % time (${secs(sClk.riseTime)})',
    ),
    Metric(
      id: 'rb_clk',
      label: 'Clock ring-back margin',
      value: rb,
      unit: 'V',
      status: rb.isInfinite ? SiStatus.info : classifySlack(rb, thr.ringbackWarnPctVdd / 100 * vdd),
      level: ModelLevel.behavioral,
      note: 'Negative = ringing re-enters VIL–VIH (false clock edge risk)',
    ),
    Metric(
      id: 'su_tx',
      label: 'TX setup slack @ PHY (TXC delay ${secs(p.txClockDelay)})',
      value: tx.setup,
      unit: 's',
      status: slack(tx.setup),
      level: ModelLevel.behavioral,
      note: 'TsetupR ${secs(p.setupTime)}, TskewT ±${secs(p.txSkew)}',
    ),
    Metric(
      id: 'ho_tx',
      label: 'TX hold slack @ PHY',
      value: tx.hold,
      unit: 's',
      status: slack(tx.hold),
      level: ModelLevel.behavioral,
      note: 'TholdR ${secs(p.holdTime)}',
    ),
    Metric(
      id: 'su_rx',
      label: 'RX setup slack @ MAC (RXC delay ${secs(p.rxClockDelay)})',
      value: rx.setup,
      unit: 's',
      status: slack(rx.setup),
      level: ModelLevel.behavioral,
    ),
    Metric(
      id: 'ho_rx',
      label: 'RX hold slack @ MAC',
      value: rx.hold,
      unit: 's',
      status: slack(rx.hold),
      level: ModelLevel.behavioral,
    ),
    Metric(
      id: 'opt_delay',
      label: 'Best clock delay (centres the window)',
      value: optimum(tx, p.txClockDelay),
      unit: 's',
      status: SiStatus.info,
      level: ModelLevel.behavioral,
      note: bestMargin >= 0
          ? 'Internal clock delay that balances setup and hold (worst slack ${secs(bestMargin)}); RGMII-ID devices use 1.5–2.0 ns'
          : 'No clock delay meets setup and hold with these edges and TskewT',
    ),
  ];

  // ---- Findings ------------------------------------------------------------
  Metric m(String id) => metrics.firstWhere((x) => x.id == id);
  final findings = <Finding>[];
  final mmPerNs = 1e-9 / line.tpdPerMetre * 1e3;
  void timingFinding(String dir, double d, ({double setup, double hold}) t, String where) {
    final bad = t.setup < 0 || (t.hold.isFinite && t.hold < 0);
    final tight = !bad && (t.setup < warnSlack || (t.hold.isFinite && t.hold < warnSlack));
    if (!bad && !tight) return;
    final opt = optimum(t, d);
    final totalDelay = d + routeSkew;
    final String rec;
    if (totalDelay < 0.5e-9) {
      rec = 'There is almost no clock delay (${secs(totalDelay)}). Enable the ${dir == 'TX' ? 'MAC TX or PHY TX' : 'PHY RX or MAC RX'} '
          'internal delay (RGMII-ID, ≈ 2 ns) - adding it with PCB trace would need ≈ ${(2 * mmPerNs).toStringAsFixed(0)} mm of extra clock length.';
    } else if (totalDelay > 0.75 * tBit) {
      rec = 'The clock is delayed by ${secs(totalDelay)}, close to a full bit (${secs(tBit)}). The delay is probably added twice '
          '(e.g. the internal delay is enabled in both the MAC and the PHY, or a long PCB clock trace is added on top of RGMII-ID). '
          'Enable exactly one 2 ns delay.';
    } else if (opt.isFinite) {
      rec = 'Adjust the $dir clock delay to ≈ ${secs(opt)} (many PHYs have programmable delay steps), or change the clock '
          'trace length by ≈ ${((opt - d) * mmPerNs).toStringAsFixed(1)} mm.';
    } else {
      rec = 'Increase the clock delay or speed up the data edges.';
    }
    findings.add(Finding(
      status: bad ? SiStatus.critical : SiStatus.warning,
      title: bad ? '$dir timing violation' : '$dir timing margin is small',
      reason: 'At the $where the data must be stable ${secs(p.setupTime)} before and ${secs(p.holdTime)} after the '
          'delayed clock edge (plus ±${secs(p.txSkew)} transmitter skew). Setup slack ${secs(t.setup)}, hold slack '
          '${t.hold.isFinite ? secs(t.hold) : 'n/a'} with ${secs(d)} internal + ${secs(routeSkew)} PCB clock delay.',
      recommendation: rec,
    ));
  }

  timingFinding('TX', p.txClockDelay, tx, 'PHY');
  timingFinding('RX', p.rxClockDelay, rx, 'MAC');
  if (m('zdev').status != SiStatus.good) {
    findings.add(Finding(
      status: m('zdev').status,
      title: 'Impedance mismatch',
      reason: 'Z0 = ${ohm(imp.z0)} deviates ${pct(zDev)} from the ${ohm(p.targetZ0)} target.',
      recommendation: width != null ? 'Use a trace width of ≈ ${milStr(width)} (${mm(width)}).' : 'Review the stackup.',
    ));
  }
  if (m('overshoot').status != SiStatus.good || m('undershoot').status != SiStatus.good ||
      (!rb.isInfinite && rb < 0)) {
    final rSer = math.max(0.0, z0 - p.driverImpedance);
    findings.add(Finding(
      status: worst([m('overshoot').status, m('undershoot').status, if (!rb.isInfinite && rb < 0) SiStatus.warning]),
      title: 'Ringing on clock / data',
      reason: 'Overshoot ${volts(os)}, undershoot ${volts(us)}${!rb.isInfinite ? ', clock ring-back margin ${volts(rb)}' : ''}. '
          '${longLine ? 'The trace is electrically long and the receiver reflects (ΓL = ${gl.toStringAsFixed(2)}).' : ''}',
      recommendation: 'Fit a source series resistor of ≈ ${ohm(rSer)} close to each RGMII driver (MAC TX side and '
          'PHY RX side), or reduce the driver strength setting.',
    ));
  }
  if (m('clk_tr').status != SiStatus.good && m('clk_tr').status != SiStatus.info) {
    findings.add(Finding(
      status: SiStatus.warning,
      title: 'Slow clock edges',
      reason: 'Clock 20–80 % rise ≈ ${secs(clkRise2080)} exceeds the 0.75 ns RGMII limit.',
      recommendation: 'Reduce series resistance or receiver load, or raise the driver strength.',
    ));
  }
  final chan = channelReport(cfg, link, fKnee, differential: false);
  metrics.addAll(chan.metrics);
  findings.addAll(chan.findings);
  if (findings.isEmpty) {
    findings.add(Finding(
      status: SiStatus.good,
      title: 'RGMII timing met in both directions',
      reason: 'Setup and hold slack at the PHY (TX) and MAC (RX) are positive with margin, and the edges are clean.',
      recommendation: 'Keep clock and data of each direction length-matched within ≈ ${(0.1 * mmPerNs).toStringAsFixed(0)} mm (100 ps).',
    ));
  }

  final checks = <ComplianceCheck>[
    ComplianceCheck(
        name: 'Trace impedance',
        requirement: '${ohm(p.targetZ0)} ±10 %',
        measured: '${ohm(z0)} (${pct(zDev.abs())})',
        pass: zDev.abs() <= 10,
        source: 'configured limit'),
    for (final (name, v) in [
      ('TX setup @ PHY (TsetupR)', tx.setup),
      ('TX hold @ PHY (TholdR)', tx.hold),
      ('RX setup @ MAC (TsetupR)', rx.setup),
      ('RX hold @ MAC (TholdR)', rx.hold),
    ])
      if (v.isFinite)
        ComplianceCheck(
            name: name,
            requirement: 'slack ≥ 0 (incl. ±${secs(p.txSkew)} TskewT)',
            measured: secs(v),
            pass: v >= 0,
            source: 'spec reference'),
    if (!clkRise2080.isNaN)
      ComplianceCheck(
          name: 'Clock rise time (20–80 %)',
          requirement: '≤ 0.75 ns',
          measured: secs(clkRise2080),
          pass: clkRise2080 <= 0.75e-9,
          source: 'spec reference'),
    ...complianceChecks(cfg, metrics),
  ];

  // ---- Traces -------------------------------------------------------------
  Float32List ideal(Float64List vs, int shift) {
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      final j = i - shift;
      out[i] = (j < 0 ? vs[0] : vs[j]) / vdd * vHigh;
    }
    return out;
  }

  // Clock as seen by the sampling flip-flop (delayed by the TX internal delay).
  final shiftD = (p.txClockDelay / dt).round();
  final clkDelayed = Float32List(n);
  for (var i = 0; i < n; i++) {
    final j = i - shiftD;
    clkDelayed[i] = j < 0 ? clk.vFar[0] : clk.vFar[j];
  }
  final traces = <WaveformTrace>[
    WaveformTrace(id: 'clk_tx', label: 'Clock TX pin', group: 'Clock', kind: TraceKind.tx, values: Float32List.fromList(clk.vNear)),
    WaveformTrace(id: 'clk_rx', label: 'Clock RX pin', group: 'Clock', kind: TraceKind.rx, values: Float32List.fromList(clk.vFar)),
    WaveformTrace(
        id: 'clk_ideal', label: 'Clock ideal (delayed)', group: 'Clock', kind: TraceKind.ideal, values: ideal(clkVs, (clkDelay / dt).round())),
    WaveformTrace(id: 'clk_int', label: 'Clock + internal delay', group: 'Timing', kind: TraceKind.other, values: clkDelayed),
    WaveformTrace(id: 'd_tx', label: 'Data TX pin', group: 'Data', kind: TraceKind.tx, values: Float32List.fromList(data.vNear)),
    WaveformTrace(id: 'd_rx', label: 'Data RX pin', group: 'Data', kind: TraceKind.rx, values: Float32List.fromList(data.vFar)),
    WaveformTrace(
        id: 'd_ideal', label: 'Data ideal (delayed)', group: 'Data', kind: TraceKind.ideal, values: ideal(dataVs, (dataDelay / dt).round())),
  ];
  final views = <String, List<String>>{
    'Clock vs data @ RX': ['clk_int', 'd_rx'],
    'Clock': ['clk_ideal', 'clk_tx', 'clk_rx'],
    'Data': ['d_ideal', 'd_tx', 'd_rx'],
  };

  final assumptions = <String>[
    ...chan.assumptions,
    ...link.assumptions,
    'RGMII ${p.speed.label}: clock and data launched edge-aligned; data ${ddr ? 'on both clock edges' : 'on rising edges'}.',
    'One data line represents TXD[3:0]/TX_CTL and RXD[3:0]/RX_CTL; TX and RX use the same routing and buffers, '
        'and differ only in clock delay (TX ${secs(p.txClockDelay)}, RX ${secs(p.rxClockDelay)}).',
    'Internal clock delay applied at the sampling point; PCB delay from the ${mm(clkLen)} clock trace.',
    'Driver ${ohm(p.driverImpedance)} + ${ohm(p.seriesR)} series; receiver ${eng(p.receiverCap, 'F')}; '
        'VIH 0.7 VDD, VIL 0.3 VDD at ${volts(vdd)}.',
    'Transmitter skew TskewT ±${secs(p.txSkew)} subtracted from setup and hold (worst case); receiver window '
        'TsetupR ${secs(p.setupTime)} / TholdR ${secs(p.holdTime)} (RGMII v2.0 reference values).',
  ];
  sw.stop();
  return SimulationResult(
    config: cfg,
    dt: dt,
    sampleCount: n,
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
      widthForTarget: width,
    ),
    eyes: const [],
    animation: null,
    computeMillis: sw.elapsedMilliseconds,
    checks: checks,
  );
}
