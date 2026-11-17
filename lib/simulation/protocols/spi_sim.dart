/// SPI link simulation: SCLK, MOSI, CS (controller -> peripheral) and MISO
/// (peripheral -> controller), each a single-ended line with the same
/// routing and termination.
///
/// Timing model
/// * Mode = CPOL/CPHA. Data shifts on one SCLK edge and is sampled on the
///   opposite edge, so the data window is half an SCLK period.
/// * The peripheral launches MISO tCO after SCLK *arrives* at its pin
///   (50 % crossing), so MISO setup at the controller includes the SCLK
///   flight time + tCO + MISO flight time.
/// * Setup slack = t_sample - t_valid - t_su, where t_valid is the last entry
///   of the received data into the valid region (>= VIH or <= VIL).
/// * Hold slack  = t_invalid - t_sample - t_h.
/// * MISO data = bitwise inverse of the MOSI pattern (so both directions
///   toggle). MISO is assumed driven low before the first bit.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../common/format.dart';
import '../ibis/ibis.dart';
import '../impedance/impedance.dart';
import '../metrics/classify.dart';
import '../metrics/compliance.dart';
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

class _Line {
  _Line(this.id, this.name, this.vs, this.sol, this.transitions, this.initial, this.delay);
  final String id;
  final String name;
  final Float64List vs;
  final LineSolution sol;
  final List<Transition> transitions;
  final double initial;
  final double delay;
}

Float64List _idealAtRx(Float64List vs, double vdd, double vLow, double vHigh, int shift) {
  final out = Float64List(vs.length);
  for (var i = 0; i < vs.length; i++) {
    final j = i - shift;
    final x = j < 0 ? vs[0] : vs[j];
    out[i] = vLow + x / vdd * (vHigh - vLow);
  }
  return out;
}

List<ExpectedEdge> _expectedEdges(List<Transition> tr, double initial, double delay,
    double riseTime, double fallTime, double tEnd) {
  final out = <ExpectedEdge>[];
  var prev = initial;
  for (var i = 0; i < tr.length; i++) {
    final rising = tr[i].level > prev;
    final w = (rising ? riseTime : fallTime) / 0.8;
    final arr = tr[i].t50 + delay;
    final prevArr = i == 0 ? 0.0 : tr[i - 1].t50 + delay;
    double end;
    if (i + 1 < tr.length) {
      final nRising = tr[i + 1].level > tr[i].level;
      final nw = (nRising ? riseTime : fallTime) / 0.8;
      end = tr[i + 1].t50 + delay - nw / 2;
    } else {
      end = tEnd;
    }
    out.add(ExpectedEdge(
      t50: arr,
      rising: rising,
      windowStart: math.max(prevArr + 0.5 * (arr - prevArr), arr - 2 * w),
      windowEnd: end,
    ));
    prev = tr[i].level;
  }
  return out;
}

SimulationResult simulateSpi(AnalysisConfig cfg) {
  final sw = Stopwatch()..start();
  final p = cfg.spiCfg;
  final isQ = cfg.protocol == Protocol.qspi;
  final dtr = isQ && p.dtr;
  final dqs = dtr && p.useDqs;
  final clkName = isQ ? 'CLK' : 'SCLK';
  final wrName = isQ ? 'IO write' : 'MOSI';
  final rdName = isQ ? 'IO read' : 'MISO';
  final csName = isQ ? 'CS#' : 'CS';
  final tgtName = isQ ? 'flash' : 'peripheral';
  final dataLen = isQ ? cfg.pcb.traceLength + p.dataClockMismatch : cfg.pcb.traceLength;
  final thr = cfg.thresholds;
  final ibis = p.useIbis ? p.ibisDriver : null;
  final ibisRx = p.useIbis ? p.ibisReceiver : null;
  final corner = p.ibisCorner;
  final vdd = ibis != null ? ibis.vccOf(corner) : p.voltage;
  // Edge rates: user values, or IBIS [Ramp] (0-100 % ramp x 0.8 ~ 10-90 %).
  final riseT = ibis != null ? ibis.rampTime(corner, rising: true) * 0.8 : p.riseTime;
  final fallT = ibis != null ? ibis.rampTime(corner, rising: false) * 0.8 : p.fallTime;
  final tclk = 1 / p.clockHz;
  final half = tclk / 2;
  final bits = patternBits(cfg.sim, cfg.sim.numBits);
  final misoBits = bits.map((b) => 1 - b).toList();
  final nb = bits.length;
  final cpol = p.cpol;
  final cpha = p.cpha;

  final tCs = tclk;
  double lead(int k) => tCs + half + k * tclk;
  double trail(int k) => lead(k) + half;
  // DTR transfers one bit per clock edge.
  final nc = dtr ? (nb + 1) ~/ 2 : nb;
  final tBit = dtr ? half : tclk;
  double edgeT(int k) => k.isEven ? lead(k ~/ 2) : trail(k ~/ 2);
  final tCsEnd = trail(nc - 1) + half;

  final link = prepareLink(
    cfg: cfg,
    differential: false,
    minEdge: math.min(riseT, fallT),
    durationFor: (t) => tCsEnd + tclk + 4 * t + p.slaveTco + p.readSampleDelay + 2 * math.max(riseT, fallT),
    extraLength: dataLen - cfg.pcb.traceLength,
  );
  final dt = link.dt;
  final n = link.samples;
  final tEnd = (n - 1) * dt;
  final line = link.line;
  final z0 = line.z0;
  final delay = line.delay;
  final dataDelay = link.withLength(dataLen).delay;
  final ends0 = spiEnds(p);
  // With IBIS, the linear source/load only feed the analytical metrics; the
  // driver resistance is the small-signal pull-up/pull-down average.
  final rIbis = ibis == null
      ? 0.0
      : 0.5 * (ibis.pulldownResistance(corner) + ibis.pullupResistance(corner)).clamp(0.1, 1e4);
  final ends = ibis == null
      ? ends0
      : (
          source: SourceEnd(rDriver: rIbis, rSeries: ends0.source.rSeries),
          load: LoadEnd(
            rIn: ends0.load.rIn,
            cIn: 0,
            rTerm: ends0.load.rTerm,
            vtt: ends0.load.vtt,
            rAc: ends0.load.rAc,
            cAc: ends0.load.cAc,
          ),
        );
  final shift = (delay / dt).round();

  LineSolution solve(Float64List vs, List<Transition> tr, double initial, {double? length}) => solveLeg(
        link: link,
        length: length ?? cfg.pcb.traceLength,
        vs: vs,
        source: ends.source,
        load: ends.load,
        elements: cfg.pcb.elements,
        devices: ibis == null
            ? const LegDevices()
            : LegDevices(
                driver: (node) => IbisDriverDevice(
                  node: node,
                  model: ibis,
                  corner: corner,
                  initialHigh: initial > vdd / 2,
                  edges: [for (final t in tr) LogicEdge(t.t50, t.level > vdd / 2)],
                ),
                driverCcomp: ibis.cCompOf(corner),
                receiver: ibisRx == null ? null : (node) => IbisReceiverDevice(node: node, model: ibisRx, corner: corner),
                receiverCcomp: ibisRx?.cCompOf(corner) ?? 0,
              ),
      );

  Float64List stim(double initial, List<Transition> t) => buildStimulus(
        initial: initial,
        transitions: t,
        riseTime: riseT,
        fallTime: fallT,
        dt: dt,
        samples: n,
      );

  // ---- Controller-driven lines ---------------------------------------------
  final idle = cpol ? vdd : 0.0;
  final active = cpol ? 0.0 : vdd;
  final sclkTr = <Transition>[];
  for (var k = 0; k < nc; k++) {
    sclkTr.add(Transition(lead(k), active));
    sclkTr.add(Transition(trail(k), idle));
  }
  final csTr = [Transition(tCs, 0), Transition(tCsEnd, vdd)];
  final mosiTr = <Transition>[];
  var last = 0;
  for (var k = 0; k < nb; k++) {
    // DTR writes are centre-aligned: data changes a quarter clock before each edge.
    final t = dtr ? edgeT(k) - tclk / 4 : (cpha ? lead(k) : (k == 0 ? tCs : trail(k - 1)));
    if (bits[k] != last) mosiTr.add(Transition(t, bits[k] == 1 ? vdd : 0));
    last = bits[k];
  }
  final sclkVs = stim(idle, sclkTr);
  final csVs = stim(vdd, csTr);
  final mosiVs = stim(0, mosiTr);
  final sclk = _Line('sclk', clkName, sclkVs, solve(sclkVs, sclkTr, idle), sclkTr, idle, delay);
  final cs = _Line('cs', csName, csVs, solve(csVs, csTr, vdd), csTr, vdd, delay);
  final mosi = _Line('mosi', wrName, mosiVs, solve(mosiVs, mosiTr, 0, length: dataLen), mosiTr, 0, dataDelay);

  // DC levels at the receiver (with IBIS: from the simulated DC state of the
  // CS line, idle high, and MOSI, idle low).
  final vHigh = ibis != null ? cs.sol.vFar[0] : dcLineVoltage(vdd, ends.source, ends.load);
  final vLow = ibis != null ? mosi.sol.vFar[0] : dcLineVoltage(0, ends.source, ends.load);
  final vMid = 0.5 * (vHigh + vLow);
  final vih = ibisRx?.vinh ?? p.vihFraction * vdd;
  final vil = ibisRx?.vinl ?? p.vilFraction * vdd;
  final wr = riseT / 0.8;
  final wf = fallT / 0.8;

  var sclkMissing = 0;
  double arrival(Float64List rx, double tSrc, bool rising) {
    final t = firstCrossing(rx, dt, vMid, rising, tSrc - math.max(wr, wf), tSrc + delay + half);
    if (t == null) {
      sclkMissing++;
      return tSrc + delay;
    }
    return t;
  }

  final leadRising = !cpol;
  final leadArr = List<double>.generate(nc, (k) => arrival(sclk.sol.vFar, lead(k), leadRising));
  final trailArr = List<double>.generate(nc, (k) => arrival(sclk.sol.vFar, trail(k), !leadRising));
  double edgeArr(int k) => k.isEven ? leadArr[k ~/ 2] : trailArr[k ~/ 2];
  final csArr = firstCrossing(cs.sol.vFar, dt, vMid, false, tCs - wf, tCs + delay + half) ??
      (tCs + delay);

  // ---- Peripheral-driven MISO ---------------------------------------------
  final misoTr = <Transition>[];
  last = 0;
  final misoLaunch = <double>[];
  for (var k = 0; k < nb; k++) {
    final tLaunch = (dtr ? edgeArr(k) : (cpha ? leadArr[k] : (k == 0 ? csArr : trailArr[k - 1]))) + p.slaveTco;
    misoLaunch.add(tLaunch);
    if (misoBits[k] != last) misoTr.add(Transition(tLaunch, misoBits[k] == 1 ? vdd : 0));
    last = misoBits[k];
  }
  final misoVs = stim(0, misoTr);
  final miso = _Line('miso', rdName, misoVs, solve(misoVs, misoTr, 0, length: dataLen), misoTr, 0, dataDelay);

  // ---- Timing --------------------------------------------------------------
  double validAfter(Float64List v, int bit, double ts) {
    final th = bit == 1 ? vih : vil;
    final t = firstCrossing(v, dt, th, bit == 1, ts, math.min(ts + tclk, tEnd));
    return t ?? ts + tclk;
  }

  ({double setup, double hold}) timing(Float64List rx, List<int> b, List<double> sampleTimes) {
    var su = double.infinity;
    var ho = double.infinity;
    for (var k = 0; k < b.length; k++) {
      final ts = sampleTimes[k];
      if (ts >= tEnd) continue;
      final entry = lastValidEntry(rx, dt, b[k], vih, vil, ts, lookBack: tclk);
      final s = entry == null ? -(validAfter(rx, b[k], ts) - ts) - p.setupTime : ts - entry - p.setupTime;
      su = math.min(su, s);
      if (entry != null) {
        final exit = firstInvalidExit(rx, dt, b[k], vih, vil, ts, math.min(ts + tclk, tEnd));
        if (exit != null) ho = math.min(ho, exit - ts - p.holdTime);
      }
    }
    return (setup: su, hold: ho);
  }

  final slaveSample = dtr ? List<double>.generate(nb, edgeArr) : (cpha ? trailArr : leadArr);
  // Read capture: next clock edge after launch (+ programmable delay), or the
  // flash data strobe (DQS, routed with CLK) delayed by half a bit.
  List<double> masterSampleAt(double d) => List<double>.generate(
      nb,
      (k) => dqs
          ? misoLaunch[k] + delay + tBit / 2 + d
          : (dtr ? edgeT(k) + half : (cpha ? trail(k) : lead(k))) + d);
  final masterSample = masterSampleAt(p.readSampleDelay);
  final mosiT = timing(mosi.sol.vFar, bits, slaveSample);
  final misoT = timing(miso.sol.vFar, misoBits, masterSample);
  // QSPI: find the read capture delay that centres the data window.
  double? bestDelay;
  var bestMargin = -double.infinity;
  if (isQ) {
    final span = dqs ? tBit : 2 * tclk;
    const steps = 160;
    for (var i = 0; i <= steps; i++) {
      final d = (dqs ? -tBit / 2 : 0) + span * i / steps;
      if (d < 0 && !dqs) continue;
      final t = timing(miso.sol.vFar, misoBits, masterSampleAt(d));
      final margin = math.min(t.setup, t.hold.isFinite ? t.hold : t.setup);
      if (margin > bestMargin) {
        bestMargin = margin;
        bestDelay = d;
      }
    }
  }

  // ---- Edge statistics -----------------------------------------------------
  EdgeStats stats(_Line l) => measureEdges(
        v: l.sol.vFar,
        dt: dt,
        vLow: vLow,
        vHigh: vHigh,
        vil: vil,
        vih: vih,
        edges: _expectedEdges(l.transitions, l.initial, l.delay, riseT, fallT, tEnd),
      );
  final sSclk = stats(sclk);
  final sMosi = stats(mosi);
  final sMiso = stats(miso);
  final sCs = stats(cs);
  final all = [sSclk, sMosi, sMiso, sCs];
  final swing = vHigh - vLow;
  final worstOs = all.map((s) => s.overshoot).reduce(math.max);
  final worstUs = all.map((s) => s.undershoot).reduce(math.max);
  final worstSettle = all.map((s) => s.settlingTime).reduce(math.max);
  double rb(EdgeStats s) => math.min(s.ringbackHigh, s.ringbackLow);
  final rbSclk = rb(sSclk);
  final rbData = [sMosi, sMiso, sCs].map(rb).reduce(math.min);

  // ---- Metrics -------------------------------------------------------------
  final imp = link.impedance;
  final width = solveWidthForTarget(link.geometry, p.targetZ0);
  final zDev = (imp.z0 - p.targetZ0) / p.targetZ0 * 100;
  final tr = math.min(riseT, fallT);
  final elecLen = line.electricalLength(tr);
  final longLine = delay > tr / 6;
  final gs = sourceReflection(ends.source, z0);
  final gl = loadReflection(ends.load, z0);
  final bestEnd = math.min(gs.abs(), gl.abs());
  final fKnee = 0.35 / tr;
  final il = line.insertionLossDb(fKnee);
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
      note: 'Limits: Good <= ${thr.impedanceGoodPct}%, Warning <= ${thr.impedanceWarnPct}%',
    ),
    Metric(
      id: 'eeff',
      label: 'Effective Dk (εeff)',
      value: imp.eeff,
      unit: '',
      status: SiStatus.info,
      level: ModelLevel.analytical,
    ),
    Metric(
      id: 'tpd',
      label: 'Delay per length',
      value: line.tpdPerMetre * 1e12 / 1e3,
      unit: 'ps/mm',
      status: SiStatus.info,
      level: ModelLevel.analytical,
    ),
    Metric(
      id: 'delay',
      label: 'Propagation delay (one-way)',
      value: delay,
      unit: 's',
      status: SiStatus.info,
      level: ModelLevel.analytical,
      note: 'Round trip ${secs(2 * delay)}',
    ),
    Metric(
      id: 'eleclen',
      label: 'Electrical length T / tr',
      value: elecLen,
      unit: '',
      status: SiStatus.info,
      level: ModelLevel.analytical,
      note: longLine
          ? 'Electrically long (T > tr/6): termination matters. Critical length ${mm(line.criticalLength(tr))}.'
          : 'Electrically short (T <= tr/6). Critical length ${mm(line.criticalLength(tr))}.',
    ),
    Metric(
      id: 'gs',
      label: 'Reflection coeff. at source ΓS',
      value: gs,
      unit: '',
      status: SiStatus.info,
      level: ModelLevel.analytical,
      note: 'Rs = ${ohm(ends.source.rTotal)} vs Z0',
    ),
    Metric(
      id: 'gl',
      label: 'Reflection coeff. at load ΓL',
      value: gl,
      unit: '',
      status: SiStatus.info,
      level: ModelLevel.analytical,
      note: 'Resistive load ${ohm(ends.load.rHighFrequency)} (Cin ignored)',
    ),
    Metric(
      id: 'gbest',
      label: 'Best-matched end |Γ|',
      value: bestEnd,
      unit: '',
      status: longLine
          ? classifyHigherWorse(bestEnd, thr.reflectionGood, thr.reflectionWarn)
          : SiStatus.good,
      level: ModelLevel.analytical,
      note: longLine
          ? 'A long line needs at least one matched end. Limits: Good <= ${thr.reflectionGood}, Warning <= ${thr.reflectionWarn}'
          : 'Line is electrically short; reflections overlap the edge.',
    ),
    Metric(
      id: 'il',
      label: 'Line loss at f_knee (${eng(fKnee, 'Hz')})',
      value: il,
      unit: 'dB',
      status: classifyHigherWorse(il, thr.lossGoodDb, thr.lossWarnDb),
      level: ModelLevel.analytical,
      note: 'f_knee = 0.35/tr. Conductor ${line.conductorLossDb(fKnee).toStringAsFixed(2)} dB + '
          'dielectric ${line.dielectricLossDb(fKnee).toStringAsFixed(2)} dB',
    ),
    Metric(
      id: 'overshoot',
      label: 'Overshoot (worst line)',
      value: worstOs,
      unit: 'V',
      status: classifyHigherWorse(worstOs / swing * 100, thr.overshootGoodPct, thr.overshootWarnPct),
      level: ModelLevel.behavioral,
      note: '${pct(worstOs / swing * 100)} of swing. Limits: Good <= ${thr.overshootGoodPct}%, '
          'Warning <= ${thr.overshootWarnPct}%',
    ),
    Metric(
      id: 'undershoot',
      label: 'Undershoot (worst line)',
      value: worstUs,
      unit: 'V',
      status: classifyHigherWorse(worstUs / swing * 100, thr.overshootGoodPct, thr.overshootWarnPct),
      level: ModelLevel.behavioral,
      note: '${pct(worstUs / swing * 100)} of swing',
    ),
    Metric(
      id: 'rise',
      label: '$clkName rise time at receiver',
      value: sSclk.riseTime,
      unit: 's',
      status: SiStatus.info,
      level: ModelLevel.behavioral,
      note: 'Driver tr = ${secs(riseT)} (10-90 %)',
    ),
    Metric(
      id: 'fall',
      label: '$clkName fall time at receiver',
      value: sSclk.fallTime,
      unit: 's',
      status: SiStatus.info,
      level: ModelLevel.behavioral,
      note: 'Driver tf = ${secs(fallT)} (90-10 %)',
    ),
    Metric(
      id: 'rb_sclk',
      label: '$clkName ring-back margin',
      value: rbSclk,
      unit: 'V',
      status: rbSclk.isInfinite ? SiStatus.info : classifySlack(rbSclk, thr.ringbackWarnPctVdd / 100 * vdd),
      level: ModelLevel.behavioral,
      note: 'Distance of post-edge ringing from VIH/VIL. Negative = re-enters the threshold region (double-clocking risk).',
    ),
    Metric(
      id: 'rb_data',
      label: 'Data/CS ring-back margin',
      value: rbData,
      unit: 'V',
      status: rbData.isInfinite ? SiStatus.info : classifySlack(rbData, thr.ringbackWarnPctVdd / 100 * vdd),
      level: ModelLevel.behavioral,
    ),
    Metric(
      id: 'settle',
      label: 'Settling time (±5 %, worst)',
      value: worstSettle,
      unit: 's',
      status: worstSettle <= 0.5 * half ? SiStatus.good : SiStatus.warning,
      level: ModelLevel.behavioral,
      note: 'Limit: Good <= 50 % of SCLK half-period (${secs(0.5 * half)})',
    ),
    Metric(
      id: 'su_mosi',
      label: '$wrName setup slack @ $tgtName',
      value: mosiT.setup,
      unit: 's',
      status: classifySlack(mosiT.setup, thr.timingWarnPctPeriod / 100 * tclk),
      level: ModelLevel.behavioral,
      note: 't_su = ${secs(p.setupTime)}',
    ),
    Metric(
      id: 'ho_mosi',
      label: '$wrName hold slack @ $tgtName',
      value: mosiT.hold,
      unit: 's',
      status: mosiT.hold.isInfinite ? SiStatus.info : classifySlack(mosiT.hold, thr.timingWarnPctPeriod / 100 * tclk),
      level: ModelLevel.behavioral,
      note: 't_h = ${secs(p.holdTime)}',
    ),
    Metric(
      id: 'su_miso',
      label: '$rdName setup slack @ controller',
      value: misoT.setup,
      unit: 's',
      status: classifySlack(misoT.setup, thr.timingWarnPctPeriod / 100 * tclk),
      level: ModelLevel.behavioral,
      note: dqs
          ? 'Captured with DQS: only IO/DQS skew and edge quality matter'
          : 'Includes 2 x flight time + tCO (${secs(p.slaveTco)})${isQ ? ' and sample delay ${secs(p.readSampleDelay)}' : ''}',
    ),
    Metric(
      id: 'ho_miso',
      label: '$rdName hold slack @ controller',
      value: misoT.hold,
      unit: 's',
      status: misoT.hold.isInfinite ? SiStatus.info : classifySlack(misoT.hold, thr.timingWarnPctPeriod / 100 * tclk),
      level: ModelLevel.behavioral,
    ),
    if (isQ && bestDelay != null)
      Metric(
        id: 'rsd_rec',
        label: dqs ? 'Recommended DQS capture adjust' : 'Recommended read sample delay',
        value: bestDelay,
        unit: 's',
        status: bestMargin >= 0 ? SiStatus.info : SiStatus.critical,
        level: ModelLevel.behavioral,
        note: bestMargin >= 0
            ? 'Centres the read window: worst setup/hold slack ${secs(bestMargin)} (current delay ${secs(p.readSampleDelay)})'
            : 'The read data window is smaller than setup + hold; no sample delay can fix it',
      ),
    if (isQ && p.dataClockMismatch != 0)
      Metric(
        id: 'dcskew',
        label: 'IO-to-CLK routing skew',
        value: dataDelay - delay,
        unit: 's',
        status: classifyHigherWorse((dataDelay - delay).abs() / tBit * 100, thr.skewGoodPctUi * 2, thr.skewWarnPctUi * 2),
        level: ModelLevel.analytical,
        note: '${mm(p.dataClockMismatch)} length difference; ${pct((dataDelay - delay).abs() / tBit * 100)} of the bit time',
      ),
  ];

  // ---- Findings ------------------------------------------------------------
  final findings = <Finding>[];
  final rSerOpt = math.max(0.0, z0 - p.driverImpedance);
  final lCrit = line.criticalLength(tr);
  Metric m(String id) => metrics.firstWhere((x) => x.id == id);

  if (m('zdev').status != SiStatus.good) {
    findings.add(Finding(
      status: m('zdev').status,
      title: 'Impedance mismatch',
      reason: 'Z0 = ${ohm(imp.z0)} deviates ${pct(zDev)} from the ${ohm(p.targetZ0)} target. '
          'Wherever the signal meets the target impedance (connectors, other segments, '
          'termination sized for the target) it reflects Γ = '
          '${reflectionCoefficient(p.targetZ0, imp.z0).toStringAsFixed(3)} of the incident wave.',
      recommendation: width != null
          ? 'Change trace width to ≈ ${milStr(width)} (${mm(width)}) for ${ohm(p.targetZ0)} on this stackup, '
              'or adjust dielectric height / Dk. Z0 rises with dielectric height and falls with width and Dk.'
          : 'The target is outside the range reachable by width alone; review dielectric height, Dk and reference plane.',
    ));
  }
  if (longLine && m('gbest').status != SiStatus.good) {
    findings.add(Finding(
      status: m('gbest').status,
      title: 'Unterminated electrically-long line',
      reason: 'One-way delay ${secs(delay)} exceeds tr/6 (${secs(tr / 6)}), so the line behaves as a '
          'transmission line. Neither end is matched (ΓS = ${gs.toStringAsFixed(2)}, '
          'ΓL = ${gl.toStringAsFixed(2)}), so each edge bounces between the ends every '
          '${secs(2 * delay)} before settling.',
      recommendation: 'Add a series resistor of ≈ ${ohm(rSerOpt)} at the driver (Z0 − R_driver) so the '
          'reflection from the high-impedance receiver is absorbed at the source, or shorten the route '
          'below the critical length ${mm(lCrit)}.',
    ));
  }
  final osPct = worstOs / swing * 100;
  if (m('overshoot').status != SiStatus.good || m('undershoot').status != SiStatus.good) {
    final st = worst([m('overshoot').status, m('undershoot').status]);
    findings.add(Finding(
      status: st,
      title: 'Overshoot / undershoot',
      reason: 'Peak ${volts(all.map((s) => s.peak).reduce(math.max))} '
          '(${pct(osPct)} above the settled high level) and trough '
          '${volts(all.map((s) => s.trough).reduce(math.min))}. Excess voltage stresses receiver ESD '
          'diodes and couples noise; it results from the receiver reflection (ΓL = ${gl.toStringAsFixed(2)}) '
          'adding to the incident wave.',
      recommendation: gs < -0.05
          ? 'Increase source resistance toward Z0: series R ≈ ${ohm(rSerOpt)} damps the reflection. '
              'Slower driver edges also reduce the overshoot.'
          : 'Source is already ≥ Z0; check receiver loading and consider slower edges or a parallel/AC termination.',
    ));
  }
  if (!rbSclk.isInfinite && rbSclk < thr.ringbackWarnPctVdd / 100 * vdd) {
    findings.add(Finding(
      status: rbSclk < 0 ? SiStatus.critical : SiStatus.warning,
      title: rbSclk < 0 ? 'SCLK ring-back into threshold region' : 'Low SCLK ring-back margin',
      reason: 'After crossing the input threshold the clock rings back to within '
          '${volts(rbSclk)} of VIH/VIL. A clock that re-crosses the threshold can be seen as an extra '
          'edge by the peripheral (double clocking, shifted data).',
      recommendation: 'Clock lines need a monotonic edge: add/adjust series termination '
          '(≈ ${ohm(rSerOpt)}), keep the clock routed point-to-point without stubs, or reduce the edge rate.',
    ));
  }
  if (!rbData.isInfinite && rbData < 0) {
    findings.add(Finding(
      status: SiStatus.warning,
      title: 'Data ring-back into threshold region',
      reason: 'MOSI/MISO/CS ringing re-enters the VIL-VIH band after an edge (margin ${volts(rbData)}). '
          'This shortens the valid data window around the sampling edge.',
      recommendation: 'Apply the same termination as the clock (series R ≈ ${ohm(rSerOpt)}).',
    ));
  }
  void timingFinding(String name, double setup, double hold, String path) {
    if (setup < 0 || (hold.isFinite && hold < 0)) {
      final deficit = -math.min(setup, hold.isFinite ? hold : setup);
      final fmax = 1 / (2 * (half + math.max(0, -setup)));
      findings.add(Finding(
        status: SiStatus.critical,
        title: '$name timing violation',
        reason: '$path. Setup slack ${secs(setup)}, hold slack ${hold.isFinite ? secs(hold) : 'n/a'}. '
            'The data window is half an SCLK period (${secs(half)}); flight time, edge rate and '
            'device timing consume more than that.',
        recommendation: setup < 0
            ? 'Lower SCLK to ≤ ${eng(fmax, 'Hz')} (estimate), shorten the route '
                '(each mm adds ${(2 * line.tpdPerMetre * 1e-3 * 1e12).toStringAsFixed(1)} ps round trip), '
                'or use the controller\'s delayed-sampling option if available. Deficit ${secs(deficit)}.'
            : 'Hold violation: add delay to the data path or sample earlier; check tCO/hold figures.',
      ));
    } else if (setup < thr.timingWarnPctPeriod / 100 * tclk) {
      findings.add(Finding(
        status: SiStatus.warning,
        title: '$name timing margin is small',
        reason: '$path. Setup slack ${secs(setup)} is below ${pct(thr.timingWarnPctPeriod, decimals: 0)} '
            'of the SCLK period.',
        recommendation: 'Leave margin for temperature, voltage and part variation: shorten the trace or '
            'lower the SCLK frequency.',
      ));
    }
  }

  timingFinding(rdName, misoT.setup, misoT.hold,
      dqs
          ? 'Read data is captured with the flash DQS strobe; IO vs CLK/DQS routing skew ${secs(dataDelay - delay)}'
          : '$rdName arrives after $clkName flight (${secs(delay)}) + tCO (${secs(p.slaveTco)}) + data flight (${secs(dataDelay)})');
  timingFinding(wrName, mosiT.setup, mosiT.hold, '$wrName and $clkName travel together to the $tgtName');
  final readBad = misoT.setup < 0 || (misoT.hold.isFinite && misoT.hold < 0);
  if (isQ && bestDelay != null && readBad && bestMargin >= 0) {
    // The window exists - the controller just samples it in the wrong place.
    findings.removeWhere((f) => f.title == '$rdName timing violation');
    findings.add(Finding(
      status: SiStatus.critical,
      title: 'Read data sampled outside its valid window',
      reason: 'With a ${secs(p.readSampleDelay)} capture delay the controller samples read data '
          '${misoT.setup < 0 ? 'before it is valid' : 'after it has changed'} (setup ${secs(misoT.setup)}, hold '
          '${misoT.hold.isFinite ? secs(misoT.hold) : 'n/a'}). Read data returns after the clock flight '
          '(${secs(delay)}) + flash tV (${secs(p.slaveTco)}) + data flight (${secs(dataDelay)}).',
      recommendation: 'Set the controller read sample / capture delay to ≈ ${secs(bestDelay)}'
          '${dqs ? ' (DQS delay adjust)' : ' (e.g. "sample delay" or "read capture delay" register)'}; that leaves '
          '${secs(bestMargin)} worst-case setup/hold slack.',
    ));
  } else if (isQ && bestDelay != null && !readBad && bestMargin - math.min(misoT.setup, misoT.hold) > 0.1 * tBit) {
    final i = findings.indexWhere((f) => f.title == '$rdName timing margin is small');
    final f = Finding(
      status: i >= 0 ? SiStatus.warning : SiStatus.info,
      title: i >= 0 ? '$rdName timing margin is small' : 'Read capture delay can be centred',
      reason: 'Current read slack ${secs(math.min(misoT.setup, misoT.hold))} with a ${secs(p.readSampleDelay)} capture '
          'delay; the read data window allows ${secs(bestMargin)} on both sides.',
      recommendation: 'Set the controller read capture delay to ≈ ${secs(bestDelay)} to centre the sampling point.',
    );
    if (i >= 0) {
      findings[i] = f;
    } else {
      findings.add(f);
    }
  }
  if (sclkMissing > 0) {
    findings.add(Finding(
      status: SiStatus.critical,
      title: 'SCLK edges not detected at the peripheral',
      reason: '$sclkMissing SCLK edge(s) did not cross the 50 % level at the receiver within half a period.',
      recommendation: 'The clock is too attenuated or slow at the receiver: reduce loading/termination '
          'or lower the clock frequency.',
    ));
  }
  final rcTau = ends.source.rTotal * (p.receiverCap);
  if (!sSclk.riseTime.isNaN && sSclk.riseTime > 2 * riseT && sSclk.riseTime > 0.2 * half) {
    findings.add(Finding(
      status: SiStatus.warning,
      title: 'Slow edges at receiver',
      reason: 'Receiver rise time ${secs(sSclk.riseTime)} is more than twice the driver edge and > 20 % of '
          'the half period. Source resistance × receiver capacitance τ = ${secs(rcTau)} plus line '
          'charging slows the edge.',
      recommendation: 'Reduce series resistance or receiver capacitance, or lower the SCLK frequency.',
    ));
  }
  // ---- Phase 3: channel discontinuities and crosstalk ------------------------
  final chan = channelReport(cfg, link, fKnee, differential: false);
  metrics.addAll(chan.metrics);
  findings.addAll(chan.findings);
  final xt = cfg.pcb.crosstalk.enabled
      ? crosstalkAnalysis(
          cfg: cfg,
          link: link,
          aggressorVs: sclkVs,
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
      reason: 'Impedance, reflections, overshoot, ring-back and timing are within the configured '
          'thresholds for this simplified model.',
      recommendation: 'Confirm with IBIS-based simulation for sign-off, including vias, connectors and crosstalk.',
    ));
  }

  // ---- Traces --------------------------------------------------------------
  final traces = <WaveformTrace>[];
  final views = <String, List<String>>{};
  for (final l in [sclk, mosi, miso, cs]) {
    final id = l.id;
    traces.add(WaveformTrace(
        id: '${id}_ideal',
        label: '${l.name} ideal (delayed)',
        group: l.name,
        kind: TraceKind.ideal,
        values: Float32List.fromList(_idealAtRx(l.vs, vdd, vLow, vHigh, shift))));
    traces.add(WaveformTrace(
        id: '${id}_tx', label: '${l.name} TX pin', group: l.name, kind: TraceKind.tx, values: Float32List.fromList(l.sol.vNear)));
    traces.add(WaveformTrace(
        id: '${id}_rx', label: '${l.name} RX pin', group: l.name, kind: TraceKind.rx, values: Float32List.fromList(l.sol.vFar)));
    views[l.name] = ['${id}_ideal', '${id}_tx', '${id}_rx'];
  }
  traces.add(WaveformTrace(
      id: 'sclk_inc',
      label: '$clkName incident @TX',
      group: 'SCLK',
      kind: TraceKind.incident,
      values: Float32List.fromList(sclk.sol.incidentNear)));
  traces.add(WaveformTrace(
      id: 'sclk_refl',
      label: '$clkName reflected @TX',
      group: 'SCLK',
      kind: TraceKind.reflected,
      values: Float32List.fromList(sclk.sol.reflectedNear)));
  views['$clkName reflections'] = ['sclk_inc', 'sclk_refl', 'sclk_tx'];
  views['All receivers'] = ['sclk_rx', 'mosi_rx', 'miso_rx', 'cs_rx'];

  if (xt != null) {
    traces.addAll(xt.traces);
    views['Crosstalk'] = [for (final t in xt.traces) t.id];
  }
  final assumptions = <String>[
    ...chan.assumptions,
    if (xt != null) xt.assumption,
    ...link.assumptions,
    if (ibis == null)
      'Driver: ideal voltage source with linear edges and ${ohm(p.driverImpedance)} output resistance.'
    else
      'Level 3 IBIS driver "${ibis.name}" (${ibis.file}, ${corner.label}): V-I tables switched by [Ramp] '
          '(no V-T waveforms, no package), VDD ${volts(vdd)}, C_comp ${eng(ibis.cCompOf(corner), 'F')}, '
          'small-signal R ≈ ${ohm(rIbis)}. Same model used for the peripheral MISO driver.',
    if (ibisRx == null)
      'Receiver: ${ohm(p.receiverRin)} || ${eng(p.receiverCap, 'F')}; VIH ${pct(p.vihFraction * 100, decimals: 0)}, '
          'VIL ${pct(p.vilFraction * 100, decimals: 0)} of VDD.'
    else
      'Level 3 IBIS receiver "${ibisRx.name}": clamp diodes + C_comp ${eng(ibisRx.cCompOf(corner), 'F')}; '
          'VIH ${volts(vih)}, VIL ${volts(vil)}.',
    if (!isQ) 'All four SPI signals share the same routing length, layer and termination.',
    if (!isQ) 'MISO pattern is the inverse of the MOSI pattern; MISO driven low before the first bit.',
    if (isQ)
      'IO0 represents all ${p.ioWidth} IO lines (same routing, ${mm(dataLen)}); CLK and CS# ${mm(cfg.pcb.traceLength)}. '
          '${dtr ? 'DTR: one bit per clock edge, writes centre-aligned (data a quarter clock before each edge).' : 'SDR transfers.'} '
          'Read data is the inverse of the write pattern, driven by the flash tV = ${secs(p.slaveTco)} after each launching clock edge.',
    if (isQ && p.seriesR > 0 && p.termination.hasSeries)
      'Series resistor modelled at each driver output (flash outputs included); a single resistor placed near the '
          'controller damps the read path less than modelled.',
    if (dqs) 'DQS routed with CLK and centred on the read data by the controller (ideal 90° delay).',
    'Settled levels: low ${volts(vLow)}, high ${volts(vHigh)} at the receiver (DC).',
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
    animation: cfg.pcb.elements.isNotEmpty
        ? null
        : AnimationSource(
      label: clkName,
      incidentId: 'sclk_inc',
      reflectedId: 'sclk_refl',
      txId: 'sclk_tx',
      rxId: 'sclk_rx',
      delay: delay,
      startTime: math.max(0, lead(0) - math.max(riseT, fallT)),
    ),
    computeMillis: sw.elapsedMilliseconds,
    checks: complianceChecks(cfg, metrics, extra: {
      'vdd': vdd,
      'peak': all.map((s) => s.peak).reduce(math.max),
      'trough': all.map((s) => s.trough).reduce(math.min),
    }),
  );
}
