/// USB 2.0 differential-pair simulation (High-Speed and Full-Speed).
///
/// Model
/// * Each leg (D+ / D−) is simulated as a single-ended line with the
///   odd-mode impedance Zodd = Zdiff / 2 (pure differential excitation).
///   Skew-induced common-mode is therefore approximate.
/// * HS driver: 17.78 mA current steered into a 45 Ω source termination,
///   represented as a 0.8 V Thevenin source behind R_driver per leg.
///   HS receiver: 45 Ω to GND per leg (on-die termination).
/// * FS driver: 3.3 V CMOS source with output + external series resistance;
///   receiver unterminated (high impedance).
/// * The N leg is routed [lengthMismatch] longer than the P leg.
/// * Line states are taken directly from the data pattern (NRZI encoding
///   and bit stuffing are not applied).
///
///   Vdiff = V(D+) − V(D−),   Vcm = (V(D+) + V(D−)) / 2
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../common/format.dart';
import '../impedance/impedance.dart';
import '../metrics/classify.dart';
import '../metrics/compliance.dart';
import '../metrics/eye.dart';
import '../metrics/waveform_metrics.dart';
import '../model/config.dart';
import '../model/result.dart';
import '../reflection/reflection.dart';
import '../termination/termination.dart';
import '../waveform_engine/channel_builder.dart';
import 'channel_report.dart';
import 'crosstalk_sim.dart';
import '../waveform_engine/line_solver.dart';
import '../waveform_engine/link_context.dart';
import '../waveform_engine/stimulus.dart';

SimulationResult simulateUsb2(AnalysisConfig cfg) {
  final sw = Stopwatch()..start();
  final p = cfg.usb2;
  final thr = cfg.thresholds;
  final hs = p.speed == Usb2Speed.highSpeed;
  final ui = 1 / p.speed.bitRate;
  final bits = patternBits(cfg.sim, cfg.sim.numBits);
  final nb = bits.length;
  final vOc = p.sourceHigh;
  final t0 = 4 * ui;
  final mismatch = cfg.pcb.lengthMismatch;

  final link = prepareLink(
    cfg: cfg,
    differential: true,
    minEdge: math.min(p.riseTime, p.fallTime),
    extraLength: mismatch,
    durationFor: (t) => t0 + (nb + 4) * ui + 6 * t,
  );
  final dt = link.dt;
  final n = link.samples;
  final tEnd = (n - 1) * dt;
  final lineP = link.line;
  final lineN = link.withLength(cfg.pcb.traceLength + mismatch);
  final zOdd = lineP.z0;
  final imp = link.impedance;
  final zDiff = imp.zDiff!;
  final ends = usb2LegEnds(p);

  // ---- Stimulus ------------------------------------------------------------
  final trP = <Transition>[];
  final trN = <Transition>[];
  for (var k = 1; k < nb; k++) {
    if (bits[k] != bits[k - 1]) {
      final t = t0 + k * ui;
      trP.add(Transition(t, bits[k] == 1 ? vOc : 0));
      trN.add(Transition(t, bits[k] == 1 ? 0 : vOc));
    }
  }
  final initP = bits[0] == 1 ? vOc : 0.0;
  final initN = bits[0] == 1 ? 0.0 : vOc;
  Float64List stim(double init, List<Transition> tr) => buildStimulus(
        initial: init,
        transitions: tr,
        riseTime: p.riseTime,
        fallTime: p.fallTime,
        dt: dt,
        samples: n,
      );
  final vsP = stim(initP, trP);
  final vsN = stim(initN, trN);
  LineSolution solve(Float64List vs, double length) => solveLeg(
        link: link,
        length: length,
        vs: vs,
        source: ends.source,
        load: ends.load,
        elements: cfg.pcb.elements,
        segmentScale: 0.5,
      );
  final solP = solve(vsP, cfg.pcb.traceLength);
  final solN = solve(vsN, cfg.pcb.traceLength + mismatch);

  Float64List combine(Float64List a, Float64List b, double ka, double kb) {
    final o = Float64List(a.length);
    for (var i = 0; i < a.length; i++) {
      o[i] = ka * a[i] + kb * b[i];
    }
    return o;
  }

  final diffRx = combine(solP.vFar, solN.vFar, 1, -1);
  final diffTx = combine(solP.vNear, solN.vNear, 1, -1);
  final cmRx = combine(solP.vFar, solN.vFar, 0.5, 0.5);
  final incDiff = combine(solP.incidentNear, solN.incidentNear, 1, -1);
  final reflDiff = combine(solP.reflectedNear, solN.reflectedNear, 1, -1);

  // Settled per-leg levels and differential amplitude at the receiver.
  final legHigh = dcLineVoltage(vOc, ends.source, ends.load);
  final legLow = dcLineVoltage(0, ends.source, ends.load);
  final vd = legHigh - legLow; // settled |Vdiff|
  final meanDelay = 0.5 * (lineP.delay + lineN.delay);
  final shift = (meanDelay / dt).round();
  final ideal = Float64List(n);
  for (var i = 0; i < n; i++) {
    final j = math.max(0, i - shift);
    ideal[i] = (vsP[j] - vsN[j]) / vOc * vd;
  }

  // ---- Differential edge statistics ---------------------------------------
  final diffTr = <Transition>[
    for (var k = 1; k < nb; k++)
      if (bits[k] != bits[k - 1]) Transition(t0 + k * ui, bits[k] == 1 ? vd : -vd),
  ];
  final edges = <ExpectedEdge>[];
  var prev = bits[0] == 1 ? vd : -vd;
  for (var i = 0; i < diffTr.length; i++) {
    final rising = diffTr[i].level > prev;
    final arr = diffTr[i].t50 + meanDelay;
    final prevArr = i == 0 ? 0.0 : diffTr[i - 1].t50 + meanDelay;
    final end = i + 1 < diffTr.length ? diffTr[i + 1].t50 + meanDelay - 0.5 * p.riseTime / 0.8 : tEnd;
    edges.add(ExpectedEdge(
      t50: arr,
      rising: rising,
      windowStart: math.max(prevArr + 0.5 * (arr - prevArr), arr - 2 * p.riseTime / 0.8),
      windowEnd: end,
    ));
    prev = diffTr[i].level;
  }
  final es = measureEdges(v: diffRx, dt: dt, vLow: -vd, vHigh: vd, vil: 0, vih: 0, edges: edges);

  // ---- Eye -----------------------------------------------------------------
  final eye = computeEye(
    v: diffRx,
    dt: dt,
    ui: ui,
    bits: bits,
    t0: t0,
    delayEstimate: meanDelay,
    threshold: 0,
    idealEyeHeight: 2 * vd,
    label: 'Differential RX',
  );

  // ---- Metrics -------------------------------------------------------------
  final target = p.targetZdiff;
  final zDev = (zDiff - target) / target * 100;
  final widthT = solveWidthForTarget(link.geometry, target,
      spacing: cfg.pcb.traceSpacing, diffModel: cfg.pcb.diffModel);
  final skew = lineN.delay - lineP.delay;
  final skewPctUi = skew.abs() / ui * 100;
  final gs = sourceReflection(ends.source, zOdd);
  final gl = loadReflection(ends.load, zOdd);
  final bothTerminated = p.rxTermEnabled;
  final gEval = bothTerminated ? math.max(gs.abs(), gl.abs()) : math.min(gs.abs(), gl.abs());
  final tr = math.min(p.riseTime, p.fallTime);
  final longLine = lineP.delay > tr / 6;
  final fNyq = p.speed.bitRate / 2;
  final il = lineP.insertionLossDb(fNyq);
  final s11 = worstCaseLineS11(zDiff, target);
  final rl = returnLossDb(s11);
  final swing = 2 * vd;
  var cmPkPk = maxIn(cmRx, (t0 / dt).floor(), n) - minIn(cmRx, (t0 / dt).floor(), n);
  if (cmPkPk < 1e-6) cmPkPk = 0; // numerical noise floor
  final ampDevPct = hs ? (vd - 0.4) / 0.4 * 100 : double.nan;

  final metrics = <Metric>[
    Metric(
      id: 'zdiff',
      label: 'Differential impedance Zdiff',
      value: zDiff,
      unit: 'ohm',
      target: target,
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
      note: 'Limits: Good <= ${thr.impedanceGoodPct}%, Warning <= ${thr.impedanceWarnPct}% (USB 2.0: 90 Ω ±15 %)',
    ),
    Metric(
      id: 'z0',
      label: 'Single-ended Z0 (uncoupled)',
      value: imp.z0,
      unit: 'ohm',
      status: SiStatus.info,
      level: ModelLevel.analytical,
      note: 'Odd-mode Zodd = ${ohm(zOdd)}',
    ),
    Metric(
      id: 'tpd',
      label: 'Delay per length',
      value: lineP.tpdPerMetre * 1e12 / 1e3,
      unit: 'ps/mm',
      status: SiStatus.info,
      level: ModelLevel.analytical,
    ),
    Metric(
      id: 'delay',
      label: 'Propagation delay (D+)',
      value: lineP.delay,
      unit: 's',
      status: SiStatus.info,
      level: ModelLevel.analytical,
      note: 'Round trip ${secs(lineP.roundTrip)}; ${(lineP.delay / ui).toStringAsFixed(2)} UI',
    ),
    Metric(
      id: 'skew',
      label: 'Intra-pair skew',
      value: skew,
      unit: 's',
      status: classifyHigherWorse(skewPctUi, thr.skewGoodPctUi, thr.skewWarnPctUi),
      level: ModelLevel.analytical,
      note: '${pct(skewPctUi)} of UI from ${mm(mismatch.abs())} length mismatch. '
          'Limits: Good <= ${thr.skewGoodPctUi}% UI, Warning <= ${thr.skewWarnPctUi}% UI',
    ),
    Metric(
      id: 'gs',
      label: 'Reflection coeff. at TX (per leg) ΓS',
      value: gs,
      unit: '',
      status: SiStatus.info,
      level: ModelLevel.analytical,
      note: 'R_source ${ohm(ends.source.rTotal)} vs Zodd ${ohm(zOdd)}',
    ),
    Metric(
      id: 'gl',
      label: 'Reflection coeff. at RX (per leg) ΓL',
      value: gl,
      unit: '',
      status: SiStatus.info,
      level: ModelLevel.analytical,
      note: 'R_load ${ohm(ends.load.rHighFrequency)} (Cin ignored)',
    ),
    Metric(
      id: 'gbest',
      label: bothTerminated ? 'Worst end |Γ| (both ends terminated)' : 'Best-matched end |Γ|',
      value: gEval,
      unit: '',
      status: longLine || bothTerminated
          ? classifyHigherWorse(gEval, thr.reflectionGood, thr.reflectionWarn)
          : SiStatus.good,
      level: ModelLevel.analytical,
      note: 'Limits: Good <= ${thr.reflectionGood}, Warning <= ${thr.reflectionWarn}',
    ),
    Metric(
      id: 'il',
      label: 'Insertion loss @ Nyquist (${eng(fNyq, 'Hz')})',
      value: il,
      unit: 'dB',
      status: classifyHigherWorse(il, thr.lossGoodDb, thr.lossWarnDb),
      level: ModelLevel.analytical,
      note: 'PCB trace only. Conductor ${lineP.conductorLossDb(fNyq).toStringAsFixed(3)} dB + '
          'dielectric ${lineP.dielectricLossDb(fNyq).toStringAsFixed(3)} dB',
    ),
    Metric(
      id: 'rl',
      label: 'Return loss (impedance-mismatch estimate)',
      value: rl,
      unit: 'dB',
      status: SiStatus.info,
      level: ModelLevel.analytical,
      note: 'Worst-case |S11| of a ${ohm(zDiff)} line in a ${ohm(target)} system',
    ),
    if (hs)
      Metric(
        id: 'vamp',
        label: 'Settled |Vdiff| at receiver',
        value: vd,
        unit: 'V',
        status: classifyHigherWorse(ampDevPct.abs(), 10, 20),
        level: ModelLevel.analytical,
        note: 'Nominal HS 400 mV (45 Ω/45 Ω termination). Limits ±10 % Good, ±20 % Warning.',
      ),
    Metric(
      id: 'overshoot',
      label: 'Differential overshoot',
      value: es.overshoot,
      unit: 'V',
      status: classifyHigherWorse(es.overshoot / swing * 100, thr.overshootGoodPct, thr.overshootWarnPct),
      level: ModelLevel.behavioral,
      note: '${pct(es.overshoot / swing * 100)} of the differential swing',
    ),
    Metric(
      id: 'undershoot',
      label: 'Differential undershoot',
      value: es.undershoot,
      unit: 'V',
      status: classifyHigherWorse(es.undershoot / swing * 100, thr.overshootGoodPct, thr.overshootWarnPct),
      level: ModelLevel.behavioral,
      note: '${pct(es.undershoot / swing * 100)} of the differential swing',
    ),
    Metric(
      id: 'rise',
      label: 'Differential rise time at RX',
      value: es.riseTime,
      unit: 's',
      status: SiStatus.info,
      level: ModelLevel.behavioral,
      note: 'Driver tr = ${secs(p.riseTime)}',
    ),
    Metric(
      id: 'fall',
      label: 'Differential fall time at RX',
      value: es.fallTime,
      unit: 's',
      status: SiStatus.info,
      level: ModelLevel.behavioral,
    ),
    Metric(
      id: 'cm',
      label: 'Common-mode AC (pk-pk) at RX',
      value: cmPkPk,
      unit: 'V',
      status: SiStatus.info,
      level: ModelLevel.behavioral,
      note: 'Caused mainly by skew and rise/fall asymmetry (odd-mode model approximation)',
    ),
    if (eye != null) ...[
      Metric(
        id: 'eye_h',
        label: 'Eye height',
        value: eye.eyeHeight,
        unit: 'V',
        status: classifyLowerWorse(eye.eyeHeight / eye.idealEyeHeight * 100, thr.eyeHeightGoodPct,
            thr.eyeHeightWarnPct),
        level: ModelLevel.behavioral,
        note: '${pct(eye.eyeHeight / eye.idealEyeHeight * 100)} of the ideal ${volts(eye.idealEyeHeight)}',
      ),
      Metric(
        id: 'eye_w',
        label: 'Eye width',
        value: eye.eyeWidth,
        unit: 's',
        status: classifyLowerWorse(eye.eyeWidth / ui * 100, thr.eyeWidthGoodPctUi, thr.eyeWidthWarnPctUi),
        level: ModelLevel.behavioral,
        note: '${pct(eye.eyeWidth / ui * 100)} of UI (${secs(ui)})',
      ),
      Metric(
        id: 'jitter',
        label: 'Deterministic jitter (pk-pk)',
        value: eye.jitterPkPk < 0.05e-12 ? 0 : eye.jitterPkPk,
        unit: 's',
        status: SiStatus.info,
        level: ModelLevel.behavioral,
        note: 'ISI + reflections + skew only; random jitter not modelled',
      ),
      Metric(
        id: 'crossing',
        label: 'Crossing percentage',
        value: eye.crossingPct,
        unit: '%',
        status: SiStatus.info,
        level: ModelLevel.behavioral,
      ),
      Metric(
        id: 'vmargin',
        label: 'Vertical noise margin',
        value: eye.verticalMargin,
        unit: 'V',
        status: SiStatus.info,
        level: ModelLevel.behavioral,
        note: 'Eye height / 2 about the 0 V differential threshold',
      ),
      Metric(
        id: 'hmargin',
        label: 'Horizontal timing margin',
        value: eye.horizontalMargin,
        unit: 's',
        status: SiStatus.info,
        level: ModelLevel.behavioral,
        note: 'Eye width / 2',
      ),
    ],
  ];

  // ---- Findings ------------------------------------------------------------
  final findings = <Finding>[];
  Metric? m(String id) {
    for (final x in metrics) {
      if (x.id == id) return x;
    }
    return null;
  }

  if (m('zdev')!.status != SiStatus.good) {
    findings.add(Finding(
      status: m('zdev')!.status,
      title: 'Differential impedance mismatch',
      reason: 'Zdiff = ${ohm(zDiff)} is ${pct(zDev)} from the ${ohm(target)} target. The USB '
          'terminations (2 × 45 Ω) and cable are 90 Ω, so the trace reflects Γ = '
          '${reflectionCoefficient(target, zDiff).toStringAsFixed(3)} at each end and the worst-case return '
          'loss is ${rl.toStringAsFixed(1)} dB.',
      recommendation: widthT != null
          ? 'With ${mm(cfg.pcb.traceSpacing)} spacing, a trace width of ≈ ${milStr(widthT)} (${mm(widthT)}) gives '
              '${ohm(target)}. Tighter spacing lowers Zdiff; wider traces or thinner dielectric lower it too.'
          : 'Target is not reachable by width alone at this spacing; change spacing, dielectric height or Dk.',
    ));
  }
  if (m('skew')!.status != SiStatus.good) {
    final allowed = thr.skewGoodPctUi / 100 * ui / lineP.tpdPerMetre;
    findings.add(Finding(
      status: m('skew')!.status,
      title: 'Intra-pair skew',
      reason: 'D− is ${mm(mismatch.abs())} longer than D+, a skew of ${secs(skew.abs())} '
          '(${pct(skewPctUi)} UI). Skew converts differential signal into common mode, slows the '
          'differential edge and closes the eye horizontally.',
      recommendation: 'Length-match the pair to within ${mm(allowed)} (${milStr(allowed)}) using small serpentine '
          'bumps near the mismatch source.',
    ));
  }
  if (m('gbest')!.status != SiStatus.good) {
    findings.add(Finding(
      status: m('gbest')!.status,
      title: 'Termination mismatch',
      reason: 'Per-leg source ${ohm(ends.source.rTotal)} and load ${ohm(ends.load.rHighFrequency)} versus the '
          'odd-mode impedance ${ohm(zOdd)} give ΓS = ${gs.toStringAsFixed(2)}, ΓL = ${gl.toStringAsFixed(2)}. '
          'Reflections re-arrive after ${secs(lineP.roundTrip)} and add ISI.',
      recommendation: hs
          ? 'HS requires 45 Ω (±10 %) terminations at both ends and a 90 Ω pair; check driver/receiver '
              'termination and avoid external series resistors in HS mode.'
          : 'For FS, bring driver + series resistance closer to Zodd (USB spec 28–44 Ω).',
    ));
  }
  if (m('overshoot')!.status != SiStatus.good) {
    findings.add(Finding(
      status: m('overshoot')!.status,
      title: 'Differential overshoot',
      reason: 'Overshoot ${volts(es.overshoot)} above the settled ${volts(vd)} level is caused by the load '
          'reflection (ΓL = ${gl.toStringAsFixed(2)}) and receiver capacitance.',
      recommendation: 'Improve termination matching and minimise stubs (ESD/CMC pads) along the pair.',
    ));
  }
  if (eye != null) {
    final h = m('eye_h')!;
    final w = m('eye_w')!;
    if (h.status != SiStatus.good || w.status != SiStatus.good) {
      findings.add(Finding(
        status: worst([h.status, w.status]),
        title: 'Eye closure',
        reason: 'Eye height ${volts(eye.eyeHeight)} (${pct(eye.eyeHeight / eye.idealEyeHeight * 100)} of ideal) '
            'and width ${secs(eye.eyeWidth)} (${pct(eye.eyeWidth / ui * 100)} UI). Loss '
            '(${il.toStringAsFixed(2)} dB @ Nyquist), reflections and skew cause inter-symbol interference.',
        recommendation: 'Shorten the route, fix impedance/termination mismatch and reduce skew. '
            'This eye excludes random jitter, crosstalk and connector/cable effects.',
      ));
    }
  }
  if (m('il')!.status != SiStatus.good) {
    findings.add(Finding(
      status: m('il')!.status,
      title: 'Channel loss',
      reason: 'Trace loss ${il.toStringAsFixed(2)} dB at ${eng(fNyq, 'Hz')} (conductor + dielectric) '
          'attenuates high-frequency content and slows the edge.',
      recommendation: 'Shorten the trace, use wider traces (lower conductor loss) or a lower-Df laminate.',
    ));
  }
  // ---- Phase 3: channel discontinuities and crosstalk ------------------------
  final chan = channelReport(cfg, link, fNyq, differential: true);
  metrics.addAll(chan.metrics);
  findings.addAll(chan.findings);
  final xt = cfg.pcb.crosstalk.enabled
      ? crosstalkAnalysis(
          cfg: cfg,
          link: link,
          aggressorVs: vsP,
          victimLevel: 0.0,
          source: ends.source,
          load: ends.load,
          riseTime: tr,
        )
      : null;
  if (xt != null) {
    metrics.addAll(xt.metrics);
    findings.addAll(xt.findings);
  }
  if (findings.isEmpty) {
    findings.add(Finding(
      status: SiStatus.good,
      title: 'No SI concerns within configured limits',
      reason: 'Impedance, skew, termination, loss and the deterministic eye are within the configured '
          'thresholds for this simplified model.',
      recommendation: 'This is not a USB-IF compliance result; verify with eye-mask testing on hardware.',
    ));
  }

  // ---- Traces --------------------------------------------------------------
  final traces = <WaveformTrace>[
    WaveformTrace(id: 'diff_ideal', label: 'Vdiff ideal (delayed)', group: 'Differential', kind: TraceKind.ideal, values: Float32List.fromList(ideal)),
    WaveformTrace(id: 'diff_tx', label: 'Vdiff TX', group: 'Differential', kind: TraceKind.tx, values: Float32List.fromList(diffTx)),
    WaveformTrace(id: 'diff_rx', label: 'Vdiff RX', group: 'Differential', kind: TraceKind.rx, values: Float32List.fromList(diffRx)),
    WaveformTrace(id: 'p_rx', label: 'D+ RX', group: 'Single-ended', kind: TraceKind.rx, values: Float32List.fromList(solP.vFar)),
    WaveformTrace(id: 'n_rx', label: 'D− RX', group: 'Single-ended', kind: TraceKind.other, values: Float32List.fromList(solN.vFar)),
    WaveformTrace(id: 'p_tx', label: 'D+ TX', group: 'Single-ended', kind: TraceKind.tx, values: Float32List.fromList(solP.vNear), visibleByDefault: false),
    WaveformTrace(id: 'n_tx', label: 'D− TX', group: 'Single-ended', kind: TraceKind.tx, values: Float32List.fromList(solN.vNear), visibleByDefault: false),
    WaveformTrace(id: 'cm_rx', label: 'Vcm RX', group: 'Single-ended', kind: TraceKind.commonMode, values: Float32List.fromList(cmRx)),
    WaveformTrace(id: 'diff_inc', label: 'Vdiff incident @TX', group: 'Reflections', kind: TraceKind.incident, values: Float32List.fromList(incDiff)),
    WaveformTrace(id: 'diff_refl', label: 'Vdiff reflected @TX', group: 'Reflections', kind: TraceKind.reflected, values: Float32List.fromList(reflDiff)),
  ];
  final views = <String, List<String>>{
    'Differential': ['diff_ideal', 'diff_tx', 'diff_rx'],
    'D+ / D− / Vcm': ['p_rx', 'n_rx', 'cm_rx', 'p_tx', 'n_tx'],
    'Reflections': ['diff_inc', 'diff_refl', 'diff_tx'],
  };

  if (xt != null) {
    traces.addAll(xt.traces);
    views['Crosstalk'] = [for (final t in xt.traces) t.id];
  }
  final assumptions = <String>[
    ...chan.assumptions,
    if (xt != null) xt.assumption,
    ...link.assumptions,
    'Each leg modelled with odd-mode impedance Zodd = Zdiff/2 (pure differential mode); '
        'even-mode and mode-conversion effects are approximate.',
    hs
        ? 'HS driver: 0.8 V Thevenin source per leg behind ${ohm(ends.source.rTotal)} (17.78 mA into 45 Ω).'
        : 'FS driver: 3.3 V CMOS source per leg behind ${ohm(ends.source.rTotal)}.',
    'Receiver per leg: ${p.rxTermEnabled ? '${ohm(p.rxTermR)} to GND || ' : ''}'
        '${ohm(p.receiverRin)} || ${eng(p.receiverCap, 'F')}.',
    'Line states taken directly from the data pattern (no NRZI / bit-stuffing / SYNC).',
    'Loss kernel of D+ reused for D− (mismatch assumed small).',
    'Eye and jitter are deterministic only; this is not a USB-IF compliance test.',
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
      structure: '${link.geometry.structure.label} (edge-coupled pair)',
      z0: imp.z0,
      zDiff: zDiff,
      eeff: imp.eeff,
      target: target,
      targetIsDiff: true,
      method: imp.method,
      widthForTarget: widthT,
    ),
    eyes: [if (eye != null) eye],
    animation: cfg.pcb.elements.isNotEmpty
        ? null
        : AnimationSource(
      label: 'Vdiff',
      incidentId: 'diff_inc',
      reflectedId: 'diff_refl',
      txId: 'diff_tx',
      rxId: 'diff_rx',
      delay: lineP.delay,
      startTime: diffTr.isEmpty ? t0 : math.max(0, diffTr.first.t50 - p.riseTime),
    ),
    computeMillis: sw.elapsedMilliseconds,
    checks: complianceChecks(cfg, metrics, eye: eye),
  );
}
