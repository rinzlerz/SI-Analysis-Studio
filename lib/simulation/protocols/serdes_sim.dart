/// High-speed SerDes link simulation: USB 3.0 (5 Gb/s) and PCIe Gen 1-5.
///
/// Model (Level 2, behavioural)
/// * Differential pair, each leg simulated with the odd-mode impedance
///   (Zdiff/2) through the lossy Branin line solver (skin effect with
///   roughness + dielectric loss).
/// * TX: Thevenin source per leg behind the TX impedance; 3-tap FIR
///   (de-emphasis for USB 3.0 / PCIe Gen1-2, presets P0-P10 for Gen3+).
/// * RX: termination per leg to AC ground + pin capacitance; behavioural
///   CTLE (optionally auto-optimised DC gain) and ideal-decision DFE.
/// * Eye and jitter are computed from the simulated waveform; random jitter
///   is only included when the user enters it (TJ = DJ + 2 x 7.03 x RJ at
///   BER 1e-12, dual-Dirac).
/// * AC-coupling capacitors, packages, vias, connectors and crosstalk are
///   not modelled. Line states come directly from the data pattern
///   (8b/10b or 128b/130b encoding not applied).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../common/format.dart';
import '../equalization/equalization.dart';
import '../impedance/impedance.dart';
import '../metrics/classify.dart';
import '../metrics/compliance.dart';
import '../metrics/eye_advanced.dart';
import '../metrics/eye.dart';
import '../model/config.dart';
import '../model/result.dart';
import '../sparams/touchstone.dart';
import '../reflection/reflection.dart';
import '../termination/termination.dart';
import '../waveform_engine/channel_builder.dart';
import 'channel_report.dart';
import 'crosstalk_sim.dart';
import '../waveform_engine/line_solver.dart';
import '../waveform_engine/link_context.dart';
import '../waveform_engine/stimulus.dart';

SiStatus _maskStatus(EyeResult e, double maskH, double maskWui) {
  final wUi = e.eyeWidth / e.ui;
  if (e.eyeHeight < maskH || wUi < maskWui) return SiStatus.critical;
  if (e.eyeHeight < 1.5 * maskH || wUi < maskWui + 0.1) return SiStatus.warning;
  return SiStatus.good;
}

SimulationResult simulateSerdes(AnalysisConfig cfg) {
  final sw = Stopwatch()..start();
  final isPcie = cfg.protocol == Protocol.pcie;
  final isHdmi = cfg.protocol == Protocol.hdmi;
  final p = cfg.serdes;
  final thr = cfg.thresholds;
  final rate = cfg.serdesRate;
  final ui = 1 / rate;
  final fN = rate / 2;
  final name = isPcie ? 'PCIe ${p.gen.label}' : (isHdmi ? 'HDMI ${p.hdmiMode.label}' : 'USB 3.0');
  final laneSkewLimit = isHdmi ? p.hdmiMode.laneSkewLimit : p.gen.laneSkewLimit;
  final encoding = isPcie ? p.gen.encoding : (isHdmi ? p.hdmiMode.encoding : '8b/10b');
  final bits = patternBits(cfg.sim, cfg.sim.numBits);
  final nb = bits.length;
  final t0 = 4 * ui;
  final mismatch = cfg.pcb.lengthMismatch;
  final taps = txTapsFor(cfg.protocol, p);

  final link = prepareLink(
    cfg: cfg,
    differential: true,
    minEdge: p.riseTime,
    stepsPerEdge: 20,
    extraLength: mismatch,
    durationFor: (t) => t0 + (nb + 6) * ui + 6 * t,
  );
  final dt = link.dt;
  final n = link.samples;
  final lineP = link.line;
  final lineN = link.withLength(cfg.pcb.traceLength + mismatch);
  final zOdd = lineP.z0;
  final imp = link.impedance;
  final zDiff = imp.zDiff!;
  final source = SourceEnd(rDriver: p.txImpedance);
  final load = LoadEnd(rIn: 1e6, cIn: p.receiverCap, rTerm: p.rxTermination, vtt: 0);

  // ---- Stimulus (3-tap FIR) -------------------------------------------------
  // Open-circuit leg swing that launches txSwingPp (diff p-p) into a match.
  final vocSwing = p.txSwingPp / 2 * (p.txImpedance + p.rxTermination) / p.rxTermination;
  final y = firLevels(bits, taps);
  final trP = <Transition>[];
  final trN = <Transition>[];
  for (var k = 1; k < nb; k++) {
    if ((y[k] - y[k - 1]).abs() > 1e-12) {
      final t = t0 + k * ui;
      trP.add(Transition(t, vocSwing / 2 * (1 + y[k])));
      trN.add(Transition(t, vocSwing / 2 * (1 - y[k])));
    }
  }
  Float64List stim(double init, List<Transition> tr) => buildStimulus(
        initial: init,
        transitions: tr,
        riseTime: p.riseTime,
        fallTime: p.riseTime,
        dt: dt,
        samples: n,
      );
  final vsP = stim(vocSwing / 2 * (1 + y[0]), trP);
  final vsN = stim(vocSwing / 2 * (1 - y[0]), trN);
  LineSolution solve(Float64List vs, double length) => solveLeg(
        link: link,
        length: length,
        vs: vs,
        source: source,
        load: load,
        elements: cfg.pcb.elements,
        segmentScale: 0.5,
      );
  final sp = p.useTouchstone ? p.sparams : null;
  final LineSolution solP;
  final LineSolution solN;
  if (sp != null) {
    // Touchstone channel: launched differential waveform convolved with the
    // causal SDD21 (S21) impulse response; terminations = reference Z.
    final launch = Float64List(n);
    for (var i = 0; i < n; i++) {
      launch[i] = (vsP[i] - vsN[i]) / vocSwing * (p.txSwingPp / 2);
    }
    final h = sp.impulseResponse(dt);
    var dc = 0.0;
    for (final v in h) {
      dc += v;
    }
    final l0 = launch[0];
    final rx = convolve(Float64List.fromList([for (final v in launch) v - l0]), h);
    for (var i = 0; i < n; i++) {
      rx[i] += l0 * dc;
    }
    final cm = vocSwing / 2 * p.rxTermination / (p.txImpedance + p.rxTermination);
    Float64List leg(Float64List d, double sign) => Float64List.fromList([for (final v in d) cm + sign * v / 2]);
    solP = LineSolution(vNear: leg(launch, 1), vFar: leg(rx, 1), incidentNear: Float64List(n), reflectedNear: Float64List(n));
    solN = LineSolution(vNear: leg(launch, -1), vFar: leg(rx, -1), incidentNear: Float64List(n), reflectedNear: Float64List(n));
  } else {
    solP = solve(vsP, cfg.pcb.traceLength);
    solN = solve(vsN, cfg.pcb.traceLength + mismatch);
  }

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
  final meanDelay = sp != null ? sp.groupDelay() : 0.5 * (lineP.delay + lineN.delay);

  // Ideal: FIR output into a matched load, delayed by the line delay.
  final shift = (meanDelay / dt).round();
  final ideal = Float64List(n);
  final vd = dcLineVoltage(vocSwing, source, load) - dcLineVoltage(0, source, load);
  for (var i = 0; i < n; i++) {
    final j = math.max(0, i - shift);
    ideal[i] = (vsP[j] - vsN[j]) / vocSwing * vd;
  }

  // ---- Raw eye ---------------------------------------------------------------
  final idealHeight = p.txSwingPp;
  final rawEye = computeEye(
    v: diffRx,
    dt: dt,
    ui: ui,
    bits: bits,
    t0: t0,
    delayEstimate: meanDelay,
    threshold: 0,
    idealEyeHeight: idealHeight,
    label: 'RX pin (no equalisation)',
    skipBits: 8,
  );

  // ---- Equalisation ----------------------------------------------------------
  Float64List? ctleOut;
  double? ctleDb;
  DfeResult? dfe;
  EyeResult? eqEye;
  final useCtle = p.ctleEnabled;
  final useDfe = p.dfeTaps > 0;
  if (useCtle || useDfe) {
    ({Float64List v, EyeResult? eye, DfeResult? dfe}) equalise(Float64List x, {bool full = false}) {
      final e0 = computeEye(
          v: x, dt: dt, ui: ui, bits: bits, t0: t0, delayEstimate: meanDelay, threshold: 0,
          idealEyeHeight: idealHeight, label: '', skipBits: 8, measureCrossing: false);
      if (!useDfe || e0 == null) return (v: x, eye: e0, dfe: null);
      final r = applyDfe(
          v: x, dt: dt, ui: ui, t0: t0, phaseDelay: e0.phaseDelay, bits: bits, nTaps: p.dfeTaps);
      if (r == null) return (v: x, eye: e0, dfe: null);
      final e1 = computeEye(
          v: r.signal, dt: dt, ui: ui, bits: bits, t0: t0, delayEstimate: meanDelay, threshold: 0,
          idealEyeHeight: idealHeight, label: '', skipBits: 8, measureCrossing: false);
      return (v: r.signal, eye: e1, dfe: r);
    }

    Float64List best = diffRx;
    var bestScore = -double.infinity;
    final candidates = !useCtle ? <double?>[null] : (p.ctleAuto ? [for (var g = 0; g >= -12; g--) g.toDouble()] : [p.ctleDcGainDb]);
    for (final g in candidates) {
      final x = g == null ? diffRx : applyCtle(diffRx, dt, g, fN);
      final r = equalise(x);
      final e = r.eye;
      final score = e == null ? -1e9 : e.eyeHeight + 1e-3 * e.eyeWidth / ui;
      if (score > bestScore) {
        bestScore = score;
        best = r.v;
        ctleDb = g;
        ctleOut = g == null ? null : x;
        dfe = r.dfe;
      }
    }
    final label = [if (useCtle) 'CTLE ${ctleDb!.toStringAsFixed(0)} dB', if (dfe != null) '${p.dfeTaps}-tap DFE'].join(' + ');
    eqEye = computeEye(
      v: best,
      dt: dt,
      ui: ui,
      bits: bits,
      t0: t0,
      delayEstimate: meanDelay,
      threshold: 0,
      idealEyeHeight: idealHeight,
      label: 'After $label',
      skipBits: 8,
    );
  }
  final finalEye = eqEye ?? rawEye;
  for (final e in [eqEye, rawEye]) {
    if (e != null) analyseEye(e, maskHeight: p.maskHeight, maskWidthUi: p.maskWidthUi, rj: p.rjRms);
  }

  // ---- Metrics ---------------------------------------------------------------
  final target = p.targetZdiff;
  final zDev = (zDiff - target) / target * 100;
  final widthT = solveWidthForTarget(link.geometry, target,
      spacing: cfg.pcb.traceSpacing, diffModel: cfg.pcb.diffModel);
  final skew = lineN.delay - lineP.delay;
  final skewPctUi = skew.abs() / ui * 100;
  final gs = sourceReflection(source, zOdd);
  final gl = loadReflection(load, zOdd);
  final gWorst = math.max(gs.abs(), gl.abs());
  final il = lineP.insertionLossDb(fN);
  final rl = returnLossDb(worstCaseLineS11(zDiff, target));
  var cmPkPk = 0.0;
  {
    final i0 = (t0 / dt).floor();
    var lo = double.infinity, hi = -double.infinity;
    for (var i = i0; i < n; i++) {
      lo = math.min(lo, cmRx[i]);
      hi = math.max(hi, cmRx[i]);
    }
    cmPkPk = hi - lo < 1e-6 ? 0 : hi - lo;
  }
  final laneSkew = lineP.tpdPerMetre * p.laneMismatch.abs();
  final tj = finalEye == null ? double.nan : finalEye.jitterPkPk + 2 * 7.034 * p.rjRms;

  Metric eyeMetric(String id, String label, EyeResult e, {required bool classify}) {
    return Metric(
      id: id,
      label: label,
      value: e.eyeHeight,
      unit: 'V',
      status: classify ? _maskStatus(e, p.maskHeight, p.maskWidthUi) : SiStatus.info,
      level: ModelLevel.behavioral,
      note: 'Width ${secs(e.eyeWidth)} (${pct(e.eyeWidth / ui * 100)} UI). '
          '${classify ? 'Reference RX minimum ${volts(p.maskHeight)} / ${p.maskWidthUi} UI.' : ''}',
    );
  }

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
      note: 'Limits: Good <= ${thr.impedanceGoodPct}%, Warning <= ${thr.impedanceWarnPct}%',
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
      label: 'Propagation delay (P leg)',
      value: lineP.delay,
      unit: 's',
      status: SiStatus.info,
      level: ModelLevel.analytical,
      note: '${(lineP.delay / ui).toStringAsFixed(1)} UI',
    ),
    Metric(
      id: 'skew',
      label: 'Intra-pair skew',
      value: skew,
      unit: 's',
      status: classifyHigherWorse(skewPctUi, thr.skewGoodPctUi, thr.skewWarnPctUi),
      level: ModelLevel.analytical,
      note: '${pct(skewPctUi)} of UI from ${mm(mismatch.abs())} mismatch. '
          'Limits: Good <= ${thr.skewGoodPctUi}% UI, Warning <= ${thr.skewWarnPctUi}% UI',
    ),
    if ((isPcie || isHdmi) && p.lanes > 1)
      Metric(
        id: 'laneskew',
        label: 'Lane-to-lane skew (x${p.lanes})',
        value: laneSkew,
        unit: 's',
        status: classifyHigherWorse(laneSkew / laneSkewLimit * 100, 50, 100),
        level: ModelLevel.analytical,
        note: 'From ${mm(p.laneMismatch.abs())} lane length spread; reference RX tolerance '
            '${secs(laneSkewLimit)} (Good <= 50 %, Warning <= 100 %).',
      ),
    Metric(
      id: 'gbest',
      label: 'Worst end |Γ| (per leg)',
      value: gWorst,
      unit: '',
      status: classifyHigherWorse(gWorst, thr.reflectionGood, thr.reflectionWarn),
      level: ModelLevel.analytical,
      note: 'ΓTX ${gs.toStringAsFixed(3)}, ΓRX ${gl.toStringAsFixed(3)} vs Zodd ${ohm(zOdd)}',
    ),
    Metric(
      id: 'il',
      label: 'Insertion loss @ Nyquist (${eng(fN, 'Hz')})',
      value: il,
      unit: 'dB',
      status: classifyHigherWorse(il, thr.lossGoodDb, thr.lossWarnDb),
      level: ModelLevel.analytical,
      note: 'PCB trace only. Conductor ${lineP.conductorLossDb(fN).toStringAsFixed(2)} dB '
          '(roughness ×${lineP.roughnessFactor(fN).toStringAsFixed(2)}) + dielectric '
          '${lineP.dielectricLossDb(fN).toStringAsFixed(2)} dB. Limits ${thr.lossGoodDb}/${thr.lossWarnDb} dB',
    ),
    Metric(
      id: 'rl',
      label: 'Return loss (impedance-mismatch estimate)',
      value: rl,
      unit: 'dB',
      status: SiStatus.info,
      level: ModelLevel.analytical,
      note: 'Worst-case |S11| of a ${ohm(zDiff)} trace in a ${ohm(target)} system',
    ),
    Metric(
      id: 'txfir',
      label: 'TX FIR (${isPcie && p.gen.usesPresets ? 'preset P${p.preset}' : 'de-emphasis'})',
      value: taps.deEmphasisDb,
      unit: 'dB',
      status: SiStatus.info,
      level: ModelLevel.behavioral,
      note: '$taps; preshoot ${taps.preshootDb} dB',
    ),
    if (rawEye != null)
      eyeMetric('eye_raw', 'Eye height at RX pin (no EQ)', rawEye, classify: eqEye == null),
    if (ctleDb != null)
      Metric(
        id: 'ctle',
        label: 'CTLE DC gain${p.ctleAuto ? ' (auto-optimised)' : ''}',
        value: ctleDb,
        unit: 'dB',
        status: SiStatus.info,
        level: ModelLevel.behavioral,
        note: 'Peaking ${(-ctleDb).toStringAsFixed(0)} dB; poles ${eng(fN / 2, 'Hz')} / ${eng(2 * fN, 'Hz')}',
      ),
    if (dfe != null)
      Metric(
        id: 'dfe',
        label: 'DFE taps',
        value: dfe.taps.first,
        unit: 'V',
        status: SiStatus.info,
        level: ModelLevel.behavioral,
        note: 'h1..h${dfe.taps.length}: ${dfe.taps.map((t) => volts(t)).join(', ')} (ideal decisions, unconstrained)',
      ),
    if (eqEye != null) eyeMetric('eye_eq', 'Eye height after equalisation', eqEye, classify: true),
    if (finalEye != null) ...[
      Metric(
        id: 'eye_w',
        label: 'Eye width${eqEye != null ? ' (after EQ)' : ''}',
        value: finalEye.eyeWidth,
        unit: 's',
        status: SiStatus.info,
        level: ModelLevel.behavioral,
        note: '${pct(finalEye.eyeWidth / ui * 100)} of UI (${secs(ui)})',
      ),
      Metric(
        id: 'jitter',
        label: 'Deterministic jitter (pk-pk)',
        value: finalEye.jitterPkPk < 0.01e-12 ? 0 : finalEye.jitterPkPk,
        unit: 's',
        status: SiStatus.info,
        level: ModelLevel.behavioral,
        note: 'ISI + reflections + skew from the simulation',
      ),
      if (p.rjRms > 0)
        Metric(
          id: 'tj',
          label: 'Total jitter @ BER 1e-12 (estimate)',
          value: tj,
          unit: 's',
          status: classifyHigherWorse(tj / ui, 1 - p.maskWidthUi - 0.1, 1 - p.maskWidthUi),
          level: ModelLevel.behavioral,
          note: 'TJ = DJ + 14.07 × RJ (${secs(p.rjRms)} rms, user input); '
              'eye width ${secs(math.max(0, ui - tj))}',
        ),
      Metric(
        id: 'crossing',
        label: 'Crossing percentage',
        value: finalEye.crossingPct,
        unit: '%',
        status: SiStatus.info,
        level: ModelLevel.behavioral,
      ),
    ],
    if (finalEye != null && finalEye.maskHits != null)
      Metric(
        id: 'mask_hits',
        label: 'Eye mask hits',
        value: finalEye.maskHits!.toDouble(),
        unit: '',
        status: finalEye.maskHits == 0 ? SiStatus.good : SiStatus.critical,
        level: ModelLevel.advanced,
        note: 'Hexagon ${volts(p.maskHeight)} × ${p.maskWidthUi} UI centred on the eye; '
            '${finalEye.maskHits} of ${finalEye.maskSamples} folded samples inside',
      ),
    if (finalEye != null && finalEye.eyeWidthAtBer != null)
      Metric(
        id: 'eye_w_ber',
        label: 'Eye width @ BER 1e-12 (bathtub)',
        value: finalEye.eyeWidthAtBer!,
        unit: 's',
        status: finalEye.eyeWidthAtBer! / ui >= p.maskWidthUi + 0.1
            ? SiStatus.good
            : (finalEye.eyeWidthAtBer! / ui >= p.maskWidthUi ? SiStatus.warning : SiStatus.critical),
        level: ModelLevel.advanced,
        note: 'Simulated DJ distribution ⊗ Gaussian RJ ${secs(p.rjRms)} rms; '
            '${pct(finalEye.eyeWidthAtBer! / ui * 100)} UI',
      ),
    Metric(
      id: 'cm',
      label: 'Common-mode AC (pk-pk) at RX',
      value: cmPkPk,
      unit: 'V',
      status: SiStatus.info,
      level: ModelLevel.behavioral,
      note: 'Mainly from intra-pair skew (odd-mode model approximation)',
    ),
  ];

  // ---- Findings ---------------------------------------------------------------
  Metric? m(String id) {
    for (final x in metrics) {
      if (x.id == id) return x;
    }
    return null;
  }

  final findings = <Finding>[];
  if (m('zdev')!.status != SiStatus.good) {
    findings.add(Finding(
      status: m('zdev')!.status,
      title: 'Differential impedance mismatch',
      reason: 'Zdiff = ${ohm(zDiff)} is ${pct(zDev)} from the ${ohm(target)} target. Packages, connectors and '
          'terminations are designed for the target, so each transition reflects '
          'Γ = ${reflectionCoefficient(target, zDiff).toStringAsFixed(3)} (return loss ≥ ${rl.toStringAsFixed(1)} dB).',
      recommendation: widthT != null
          ? 'With ${mm(cfg.pcb.traceSpacing)} spacing, a width of ≈ ${milStr(widthT)} (${mm(widthT)}) gives ${ohm(target)}.'
          : 'Target not reachable by width alone at this spacing; adjust spacing, dielectric height or Dk.',
    ));
  }
  if (m('skew')!.status != SiStatus.good) {
    final allowed = thr.skewGoodPctUi / 100 * ui / lineP.tpdPerMetre;
    findings.add(Finding(
      status: m('skew')!.status,
      title: 'Intra-pair skew',
      reason: 'The N leg is ${mm(mismatch.abs())} longer: ${secs(skew.abs())} = ${pct(skewPctUi)} of a '
          '${secs(ui)} UI. Skew converts differential energy to common mode and closes the eye.',
      recommendation: 'Length-match within ${mm(allowed)} (${milStr(allowed)}), compensating close to the mismatch '
          '(e.g. at the bend or pin field that causes it).',
    ));
  }
  if (m('laneskew') != null && m('laneskew')!.status != SiStatus.good) {
    findings.add(Finding(
      status: m('laneskew')!.status,
      title: 'Lane-to-lane skew',
      reason: 'Lane length spread ${mm(p.laneMismatch.abs())} gives ${secs(laneSkew)} of the '
          '${secs(laneSkewLimit)} receiver deskew tolerance.',
      recommendation: 'Reduce the lane length spread; lane-to-lane matching is much looser than intra-pair matching.',
    ));
  }
  if (m('gbest')!.status != SiStatus.good) {
    findings.add(Finding(
      status: m('gbest')!.status,
      title: 'Termination mismatch',
      reason: 'TX ${ohm(p.txImpedance)} / RX ${ohm(p.rxTermination)} per leg versus Zodd ${ohm(zOdd)} '
          '(ΓTX ${gs.toStringAsFixed(2)}, ΓRX ${gl.toStringAsFixed(2)}). Reflections return after '
          '${secs(lineP.roundTrip)} (${(lineP.roundTrip / ui).toStringAsFixed(1)} UI) and add ISI.',
      recommendation: 'Bring the trace odd-mode impedance toward the 50 Ω terminations (Zdiff ≈ 100 Ω) or use the '
          'protocol target; check the terminations in the device data sheet.',
    ));
  }
  if (m('il')!.status != SiStatus.good) {
    findings.add(Finding(
      status: m('il')!.status,
      title: 'Channel loss',
      reason: 'Trace loss ${il.toStringAsFixed(1)} dB at ${eng(fN, 'Hz')} '
          '(conductor ${lineP.conductorLossDb(fN).toStringAsFixed(1)} dB, dielectric '
          '${lineP.dielectricLossDb(fN).toStringAsFixed(1)} dB). Packages, vias and connectors add more.',
      recommendation: lineP.dielectricLossDb(fN) > lineP.conductorLossDb(fN)
          ? 'Dielectric loss dominates: use a lower-Df laminate (e.g. Df ≤ 0.008) or shorten the route.'
          : 'Conductor loss dominates: use wider traces, smoother copper (HVLP/VLP) or shorten the route.',
    ));
  }
  if (eqEye != null) {
    final st = _maskStatus(eqEye, p.maskHeight, p.maskWidthUi);
    if (st != SiStatus.good) {
      findings.add(Finding(
        status: st,
        title: 'Eye margin after equalisation',
        reason: 'Post-EQ eye ${volts(eqEye.eyeHeight)} × ${secs(eqEye.eyeWidth)} '
            '(${pct(eqEye.eyeWidth / ui * 100)} UI) versus the reference minimum ${volts(p.maskHeight)} × '
            '${p.maskWidthUi} UI. Remaining ISI comes from loss beyond the EQ range and from reflections, '
            'which linear EQ cannot remove.',
        recommendation: 'Reduce trace loss (shorter route, lower Df, smoother copper), fix impedance/termination '
            'mismatch${isPcie && p.gen.usesPresets ? ', and try other TX presets (P7/P8 often suit lossy channels)' : ''}. '
            'Packages, connectors and vias are not included and will reduce the margin further.',
      ));
    }
    if (rawEye != null && rawEye.eyeHeight <= 0.25 * p.maskHeight && st == SiStatus.good) {
      findings.add(Finding(
        status: SiStatus.info,
        title: 'Link relies on receiver equalisation',
        reason: 'The eye at the RX pin is ${rawEye.eyeHeight <= 0 ? 'closed' : 'nearly closed'} '
            '(${volts(rawEye.eyeHeight)}); the CTLE${dfe != null ? ' and DFE' : ''} open it to '
            '${volts(eqEye.eyeHeight)}.',
        recommendation: 'Normal for ${isPcie ? 'PCIe Gen3+' : (isHdmi ? 'HDMI 2.0/2.1 sinks' : 'this rate')}; confirm the device EQ range covers '
            'the chosen CTLE gain${dfe != null ? ' and DFE tap values' : ''}.',
      ));
    }
  } else if (rawEye != null) {
    final st = _maskStatus(rawEye, p.maskHeight, p.maskWidthUi);
    if (st != SiStatus.good) {
      findings.add(Finding(
        status: st,
        title: 'Eye margin at receiver',
        reason: 'Eye ${volts(rawEye.eyeHeight)} × ${secs(rawEye.eyeWidth)} versus reference minimum '
            '${volts(p.maskHeight)} × ${p.maskWidthUi} UI.',
        recommendation: 'Enable CTLE/DFE if the receiver has them, increase TX de-emphasis, or reduce channel loss.',
      ));
    }
  } else {
    findings.add(Finding(
      status: SiStatus.critical,
      title: 'Eye could not be formed',
      reason: 'Too few clean threshold crossings were found in the received waveform.',
      recommendation: 'Increase the number of bits, or reduce loss/mismatch.',
    ));
  }
  if (p.rjRms > 0 && m('tj') != null && m('tj')!.status != SiStatus.good) {
    findings.add(Finding(
      status: m('tj')!.status,
      title: 'Jitter budget',
      reason: 'Estimated TJ ${secs(tj)} (${pct(tj / ui * 100)} UI) leaves an eye width of '
          '${secs(math.max(0, ui - tj))}.',
      recommendation: 'Reduce ISI (loss, reflections, skew) and check reference-clock / PLL jitter.',
    ));
  }
  if (sp != null) {
    const pcbIds = {'zdiff', 'zdev', 'z0', 'tpd', 'delay', 'skew', 'gbest', 'il', 'rl'};
    metrics.removeWhere((x) => pcbIds.contains(x.id));
    const pcbFindings = {'Differential impedance mismatch', 'Intra-pair skew', 'Termination mismatch', 'Channel loss'};
    findings.removeWhere((f) => pcbFindings.contains(f.title));
    final ilSp = -sp.s21Db(fN);
    var rlSp = double.infinity;
    for (final f in sp.freq) {
      if (f <= fN) rlSp = math.min(rlSp, -sp.s11Db(f));
    }
    final ilSt = classifyHigherWorse(ilSp, thr.lossGoodDb, thr.lossWarnDb);
    metrics.insertAll(0, [
      Metric(
        id: 'sp',
        label: 'Channel: ${sp.name}',
        value: sp.fMax,
        unit: 'Hz',
        status: SiStatus.info,
        level: ModelLevel.advanced,
        note: '${sp.ports}-port Touchstone (${sp.ports == 4 ? 'SDD21, ${sp.mapping.label}' : 'S21'}), '
            'ref ${ohm(sp.refZ)}, ${sp.freq.length} points up to ${eng(sp.fMax, 'Hz')}; group delay ${secs(meanDelay)}',
      ),
      Metric(
        id: 'il',
        label: 'Insertion loss @ Nyquist (S-parameters)',
        value: ilSp,
        unit: 'dB',
        status: ilSt,
        level: ModelLevel.advanced,
        note: 'Limits ${thr.lossGoodDb}/${thr.lossWarnDb} dB (trace-only guideline; compare with the protocol channel budget)',
      ),
      if (rlSp.isFinite)
        Metric(
          id: 'rl',
          label: 'Worst return loss up to Nyquist (S-parameters)',
          value: rlSp,
          unit: 'dB',
          status: SiStatus.info,
          level: ModelLevel.advanced,
        ),
    ]);
    if (ilSt != SiStatus.good) {
      findings.add(Finding(
        status: ilSt,
        title: 'Channel loss (S-parameters)',
        reason: 'The imported channel loses ${ilSp.toStringAsFixed(1)} dB at ${eng(fN, 'Hz')}.',
        recommendation: 'Shorten the channel, use lower-loss materials or connectors, or rely on stronger TX/RX equalisation.',
      ));
    }
  }
  // ---- Phase 3: channel discontinuities and crosstalk ------------------------
  final chan = sp != null
      ? ChannelReport([], [], [])
      : channelReport(cfg, link, fN, differential: true);
  metrics.addAll(chan.metrics);
  findings.addAll(chan.findings);
  final xt = cfg.pcb.crosstalk.enabled && sp == null
      ? crosstalkAnalysis(
          cfg: cfg,
          link: link,
          aggressorVs: vsP,
          victimLevel: 0.0,
          source: source,
          load: load,
          riseTime: p.riseTime,
        )
      : null;
  if (xt != null) {
    metrics.addAll(xt.metrics);
    findings.addAll(xt.findings);
  }
  if (findings.where((f) => f.status != SiStatus.info).isEmpty) {
    findings.add(Finding(
      status: SiStatus.good,
      title: 'No SI concerns within configured limits',
      reason: 'Impedance, skew, termination, loss and the ${eqEye != null ? 'equalised ' : ''}eye are within the '
          'configured limits for this trace-only model.',
      recommendation: 'Not a compliance result: verify with the full channel (package, vias, connectors, '
          'AC-coupling caps) using S-parameters and the protocol compliance tools.',
    ));
  }

  // ---- Traces --------------------------------------------------------------
  Float32List f32(Float64List v) => Float32List.fromList(v);
  final traces = <WaveformTrace>[
    WaveformTrace(id: 'diff_ideal', label: 'Vdiff ideal (delayed)', group: 'Differential', kind: TraceKind.ideal, values: f32(ideal)),
    WaveformTrace(id: 'diff_tx', label: 'Vdiff TX (FIR)', group: 'Differential', kind: TraceKind.tx, values: f32(diffTx)),
    WaveformTrace(id: 'diff_rx', label: 'Vdiff RX pin', group: 'Differential', kind: TraceKind.rx, values: f32(diffRx)),
    if (ctleOut != null)
      WaveformTrace(id: 'diff_ctle', label: 'Vdiff after CTLE', group: 'Equalised', kind: TraceKind.other, values: f32(ctleOut)),
    if (dfe != null)
      WaveformTrace(id: 'diff_dfe', label: 'Vdiff after CTLE+DFE', group: 'Equalised', kind: TraceKind.commonMode, values: f32(dfe.signal)),
    WaveformTrace(id: 'p_rx', label: 'P RX', group: 'Single-ended', kind: TraceKind.rx, values: f32(solP.vFar)),
    WaveformTrace(id: 'n_rx', label: 'N RX', group: 'Single-ended', kind: TraceKind.other, values: f32(solN.vFar)),
    WaveformTrace(id: 'cm_rx', label: 'Vcm RX', group: 'Single-ended', kind: TraceKind.commonMode, values: f32(cmRx)),
    WaveformTrace(id: 'diff_inc', label: 'Vdiff incident @TX', group: 'Reflections', kind: TraceKind.incident, values: f32(incDiff)),
    WaveformTrace(id: 'diff_refl', label: 'Vdiff reflected @TX', group: 'Reflections', kind: TraceKind.reflected, values: f32(reflDiff)),
  ];
  final views = <String, List<String>>{
    'Differential': ['diff_ideal', 'diff_tx', 'diff_rx'],
    if (ctleOut != null || dfe != null)
      'Equalised': ['diff_rx', if (ctleOut != null) 'diff_ctle', if (dfe != null) 'diff_dfe'],
    'P / N / Vcm': ['p_rx', 'n_rx', 'cm_rx'],
    'Reflections': ['diff_inc', 'diff_refl', 'diff_tx'],
  };

  if (sp != null) {
    views.remove('P / N / Vcm');
    views.remove('Reflections');
    traces.removeWhere((t) => const {'p_rx', 'n_rx', 'cm_rx', 'diff_inc', 'diff_refl'}.contains(t.id));
  }
  if (xt != null) {
    traces.addAll(xt.traces);
    views['Crosstalk'] = [for (final t in xt.traces) t.id];
  }
  final assumptions = <String>[
    ...chan.assumptions,
    if (xt != null) xt.assumption,
    if (sp != null)
      'Level 3: channel from Touchstone file "${sp.name}"; TX/RX assumed terminated in the file reference '
          'impedance (${ohm(sp.refZ)}); PCB trace geometry, channel elements and crosstalk settings are not used.',
    ...link.assumptions,
    '$name at ${eng(rate, 'b/s')} (UI ${secs(ui)}); line states taken directly from the data pattern '
        '($encoding encoding${isHdmi ? '' : ', scrambling and AC-coupling caps'} not modelled).',
    if (isHdmi)
      'HDMI TMDS/FRL: DC-coupled current-mode source approximated as a ${ohm(p.txImpedance)} Thevenin source per leg; '
          'sink terminated 50 Ω to 3.3 V (modelled to AC ground). Eye minimums are approximate references, '
          'not the HDMI compliance test specification. The cable is not included.',
    'Each leg modelled with odd-mode impedance Zdiff/2; mode conversion is approximate.',
    'TX: ${volts(p.txSwingPp)} diff p-p into a matched load, ${ohm(p.txImpedance)} per leg, 3-tap FIR ($taps).',
    'RX: ${ohm(p.rxTermination)} per leg to AC ground || ${eng(p.receiverCap, 'F')}.',
    if (useCtle) 'CTLE: behavioural 1-zero/2-pole model (poles fN/2 and 2·fN), not a device model.',
    if (useDfe) 'DFE: ideal decisions, least-squares taps, no tap limits or error propagation.',
    'Eye and DJ are deterministic; RJ only enters the TJ estimate when entered. Not a compliance result.',
    'Loss kernel of the P leg reused for the N leg.',
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
    eyes: [if (eqEye != null) eqEye, if (rawEye != null) rawEye],
    animation: cfg.pcb.elements.isNotEmpty || sp != null
        ? null
        : AnimationSource(
      label: 'Vdiff',
      incidentId: 'diff_inc',
      reflectedId: 'diff_refl',
      txId: 'diff_tx',
      rxId: 'diff_rx',
      delay: lineP.delay,
      startTime: math.max(0, t0 - 2 * ui),
    ),
    computeMillis: sw.elapsedMilliseconds,
    checks: complianceChecks(cfg, metrics, eye: finalEye),
  );
}
