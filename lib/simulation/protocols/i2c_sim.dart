/// I2C bus simulation (open-drain, Standard / Fast / Fast-mode Plus).
///
/// Model
/// * Each line (SCL, SDA) is a pull-up resistor to VDD plus an open-drain
///   pull-down at the controller. When pulling low, the driver sinks
///   I = gOn (v - vRamp(t)) for v > vRamp, with gOn = IOL / 0.4 V and vRamp
///   falling linearly from VDD to 0 over the driver fall ramp (a
///   slope-controlled output; 70-30 % fall ≈ 0.4 × ramp on a light load).
///   On release the conductance turns off over a quarter of the ramp. The
///   rising edge is therefore set by the pull-up and the bus capacitance,
///   exactly as on a real I2C bus.
/// * The PCB trace is a lossless transmission line (Branin) from the
///   controller to the farthest target. When the line is electrically much
///   shorter than the simulation step it is represented by its capacitance.
/// * Controller pin capacitance sits at the near end; the other devices'
///   pin capacitance and any extra capacitance are lumped at the far end
///   (worst case for the far target).
/// * Timing parameters follow NXP UM10204: rise/fall between 30 % and 70 %
///   of VDD, tLOW measured at 0.3 VDD, tHIGH at 0.7 VDD, tSU;DAT from the
///   SDA threshold crossing to the SCL rising 0.3 VDD crossing.
/// * The controller uses fixed SCL timing (no clock synchronisation), so a
///   slow rise shortens the effective SCL high time.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../common/format.dart';
import '../common/physics.dart';
import '../impedance/impedance.dart';
import '../metrics/classify.dart';
import '../metrics/compliance.dart';
import '../metrics/waveform_metrics.dart';
import '../model/config.dart';
import '../model/result.dart';
import '../waveform_engine/circuit_solver.dart';
import '../waveform_engine/link_context.dart';
import '../waveform_engine/stimulus.dart';

/// Open-drain pull-down with a slope-controlled fall and a fast release.
class OpenDrainDevice implements NonlinearDevice {
  OpenDrainDevice({
    required this.node,
    required this.gOn,
    required this.vdd,
    required this.tOn,
    required this.tOff,
    required this.events,
  });

  @override
  final int node;
  final double gOn;
  final double vdd;
  final double tOn;
  final double tOff;

  /// (start time, pull low?) sorted by time; initial state released.
  final List<(double, bool)> events;
  int _cursor = 0;

  void _seek(double t) {
    while (_cursor > 0 && events[_cursor - 1].$1 > t) {
      _cursor--;
    }
    while (_cursor < events.length && events[_cursor].$1 <= t) {
      _cursor++;
    }
  }

  @override
  bool active(double t) {
    _seek(t);
    if (_cursor == 0) return false;
    final (t0, low) = events[_cursor - 1];
    return t - t0 <= (low ? tOn : tOff);
  }

  @override
  (double, double) eval(double v, double t) {
    const leak = 1e-9;
    _seek(t);
    if (_cursor == 0) return (leak * v, leak);
    final (t0, low) = events[_cursor - 1];
    if (low) {
      final vRamp = vdd * (1 - ((t - t0) / tOn).clamp(0.0, 1.0));
      if (v <= vRamp) return (leak * v, leak);
      return (gOn * (v - vRamp) + leak * v, gOn + leak);
    }
    final x = 1 - ((t - t0) / tOff).clamp(0.0, 1.0);
    final g = gOn * x + leak;
    return (g * v, g);
  }
}

/// Nearest E12 value not above [x].
double e12Below(double x) {
  const e12 = [1.0, 1.2, 1.5, 1.8, 2.2, 2.7, 3.3, 3.9, 4.7, 5.6, 6.8, 8.2];
  if (!(x > 0)) return double.nan;
  final dec = math.pow(10, (math.log(x) / math.ln10 + 1e-9).floor()).toDouble();
  var best = e12.first * dec;
  for (final m in e12) {
    if (m * dec <= x * (1 + 1e-9)) best = m * dec;
  }
  return best;
}

class _I2cTiming {
  _I2cTiming({required this.scl, required this.sda, required this.tEnd, required this.sampleRises, required this.bitChanges});

  /// Controller pull-down events (time, low?).
  final List<(double, bool)> scl;
  final List<(double, bool)> sda;
  final double tEnd;

  /// Nominal SCL release times for data bits (where targets sample).
  final List<double> sampleRises;

  /// (time, new SDA level 0/1) for each data bit change.
  final List<(double, int)> bitChanges;
}

_I2cTiming _schedule(I2cConfig p, List<int> bits) {
  final t = 1 / p.clockHz;
  final tLow = p.sclLowFraction * t;
  final tHigh = t - tLow;
  final scl = <(double, bool)>[];
  final sda = <(double, bool)>[];
  final rises = <double>[];
  final changes = <(double, int)>[];
  var now = 0.5 * t;
  // START: SDA falls while SCL is high, SCL follows after tHD;STA = tHigh.
  sda.add((now, true));
  now += tHigh;
  var sdaLow = true;
  for (final b in bits) {
    scl.add((now, true)); // SCL low
    final tChange = now + 0.25 * tLow;
    final wantLow = b == 0;
    if (wantLow != sdaLow) {
      sda.add((tChange, wantLow));
      sdaLow = wantLow;
      changes.add((tChange, b));
    }
    now += tLow;
    scl.add((now, false)); // release SCL
    rises.add(now);
    now += tHigh;
  }
  // STOP: SDA low during SCL low, SCL released, then SDA released.
  scl.add((now, true));
  if (!sdaLow) sda.add((now + 0.25 * tLow, true));
  now += tLow;
  scl.add((now, false));
  now += tHigh;
  sda.add((now, false));
  return _I2cTiming(scl: scl, sda: sda, tEnd: now + t, sampleRises: rises, bitChanges: changes);
}

SimulationResult simulateI2c(AnalysisConfig cfg) {
  final sw = Stopwatch()..start();
  final p = cfg.i2c;
  final mode = p.mode;
  final vdd = p.voltage;
  final pcb = cfg.pcb;

  // ---- Geometry / line ---------------------------------------------------
  final TraceGeometry geom;
  try {
    geom = geometryFromStackup(pcb.stackup);
  } on StackupError catch (e) {
    throw SimulationError(e.message);
  }
  final imp = computeImpedance(geom, pcb.traceWidth);
  final z0 = imp.z0;
  final tpd = math.sqrt(imp.eeff) / c0;
  final delay = tpd * pcb.traceLength;
  final cTrace = delay / z0;
  final cFar = (p.deviceCount - 1) * p.pinCap + p.extraCap;
  final cb = cTrace + p.deviceCount * p.pinCap + p.extraCap;

  // ---- Time base -----------------------------------------------------------
  final bits = patternBits(cfg.sim, cfg.sim.numBits);
  final sched = _schedule(p, bits);
  final tOn = p.driverFallTime;
  final tOff = p.driverFallTime / 4;
  final auto = tOff / 10;
  var dt = cfg.sim.timeStepTarget > 0 ? cfg.sim.timeStepTarget : auto;
  final useLine = delay >= dt;
  final n = (sched.tEnd / dt).ceil() + 1;
  if (n > maxSimulationSteps) {
    // Coarsen the step for very slow buses; the line becomes lumped.
    dt = sched.tEnd / (maxSimulationSteps - 1);
  }
  final samples = (sched.tEnd / dt).ceil() + 1;
  final lumped = !(delay >= dt);

  ({Float64List near, Float64List far}) solve(List<(double, bool)> events) {
    final c = Circuit();
    final pin = c.node();
    final drv = p.seriesR > 0 ? c.node() : pin;
    if (p.seriesR > 0) c.resistor(drv, pin, p.seriesR);
    c.nonlinear(OpenDrainDevice(node: drv, gOn: 1 / p.rOn, vdd: vdd, tOn: tOn, tOff: tOff, events: events));
    c.capacitor(pin, -1, p.pinCap);
    final int far;
    if (lumped) {
      far = pin;
      c.capacitor(pin, -1, cTrace + cFar);
    } else {
      far = c.node();
      c.line(pin, far, z0, delay);
      c.capacitor(far, -1, cFar);
    }
    final rpNode = p.pullupAtTarget ? far : pin;
    c.source(rpNode, p.pullupR, Float64List(samples)..fillRange(0, samples, vdd));
    try {
      final r = c.run(dt: dt, n: samples, probe: [pin, far]);
      return (near: r.probes[pin]!, far: r.probes[far]!);
    } on CircuitError catch (e) {
      throw SimulationError(e.message);
    }
  }

  final scl = solve(sched.scl);
  final sda = solve(sched.sda);
  final tEnd = (samples - 1) * dt;

  // ---- Measurements (far target) --------------------------------------------
  final v30 = 0.3 * vdd, v70 = 0.7 * vdd;
  final vil = 0.3 * vdd, vih = 0.7 * vdd;
  double worstRise = 0, worstFall = 0, fastestFall = double.infinity;
  void edges(Float64List v, List<(double, bool)> ev) {
    for (var i = 0; i < ev.length; i++) {
      final (t0, low) = ev[i];
      final tNext = i + 1 < ev.length ? ev[i + 1].$1 : tEnd;
      final i0 = (t0 / dt).floor().clamp(0, v.length - 1);
      if (low) {
        // Only edges that start from a valid high level are measured.
        if (v[i0] < v70) continue;
        final a = firstCrossing(v, dt, v70, false, t0, tNext);
        final b = a == null ? null : firstCrossing(v, dt, v30, false, a, tNext);
        if (a != null && b != null) {
          worstFall = math.max(worstFall, b - a);
          fastestFall = math.min(fastestFall, b - a);
        } else {
          worstFall = double.infinity;
        }
      } else {
        if (v[i0] > v30) continue;
        final a = firstCrossing(v, dt, v30, true, t0, tNext);
        final b = a == null ? null : firstCrossing(v, dt, v70, true, a, tNext);
        worstRise = (a != null && b != null) ? math.max(worstRise, b - a) : double.infinity;
      }
    }
  }

  edges(scl.far, sched.scl);
  edges(sda.far, sched.sda);

  // Low level: voltage at the end of each SCL low period.
  var vol = 0.0;
  for (var i = 0; i < sched.scl.length; i++) {
    final (t0, low) = sched.scl[i];
    if (!low || i + 1 >= sched.scl.length) continue;
    final idx = ((sched.scl[i + 1].$1 - 0.01 * (sched.scl[i + 1].$1 - t0)) / dt).floor().clamp(0, samples - 1);
    vol = math.max(vol, scl.far[idx]);
  }
  final volMax = vdd > 2 ? 0.4 : 0.2 * vdd;

  // Effective tLOW / tHIGH of SCL at the far target.
  var tLowEff = double.infinity, tHighEff = double.infinity;
  for (var i = 0; i + 1 < sched.scl.length; i++) {
    final (t0, low) = sched.scl[i];
    final t1 = sched.scl[i + 1].$1;
    final t2 = i + 2 < sched.scl.length ? sched.scl[i + 2].$1 : tEnd;
    if (low) {
      final a = firstCrossing(scl.far, dt, v30, false, t0, t1);
      final b = firstCrossing(scl.far, dt, v30, true, t1, t2);
      if (a != null && b != null) tLowEff = math.min(tLowEff, b - a);
    } else {
      final a = firstCrossing(scl.far, dt, v70, true, t0, t1);
      final b = firstCrossing(scl.far, dt, v70, false, t1, t2);
      if (a != null && b != null) tHighEff = math.min(tHighEff, b - a);
      if (a == null) tHighEff = 0;
    }
  }

  // tSU;DAT: SDA valid -> SCL rising through 0.3 VDD (same target pin).
  var tSuDat = double.infinity;
  for (final (tc, b) in sched.bitChanges) {
    final rise = sched.sampleRises.firstWhere((r) => r > tc, orElse: () => double.nan);
    if (rise.isNaN) continue;
    final sclAt = firstCrossing(scl.far, dt, v30, true, rise, rise + 1 / p.clockHz) ?? double.nan;
    final sdaAt = firstCrossing(sda.far, dt, b == 1 ? vih : vil, b == 1, tc, rise + 1 / p.clockHz);
    if (sclAt.isNaN) continue;
    tSuDat = math.min(tSuDat, sdaAt == null ? -double.infinity : sclAt - sdaAt);
  }

  // Ringing: over/undershoot and ring-back after falling edges.
  double peak = -double.infinity, trough = double.infinity;
  for (final v in [scl.far, sda.far, scl.near, sda.near]) {
    peak = math.max(peak, maxIn(v, 0, v.length));
    trough = math.min(trough, minIn(v, 0, v.length));
  }
  var ringback = double.infinity;
  for (var i = 0; i < sched.scl.length; i++) {
    final (t0, low) = sched.scl[i];
    if (!low || i + 1 >= sched.scl.length) continue;
    final t1 = sched.scl[i + 1].$1;
    final c = firstCrossing(scl.far, dt, vil, false, t0, t1);
    if (c == null) continue;
    // Ring-back = rise after the first minimum following the fall.
    final iC = (c / dt).ceil();
    final iEnd = (t1 / dt).floor().clamp(iC + 1, samples);
    var iMin = iC;
    for (var i = iC; i < iEnd; i++) {
      if (scl.far[i] < scl.far[iMin]) iMin = i;
      if (scl.far[i] > scl.far[iMin] + 1e-3 && i > iMin + 2) break;
    }
    final mx = maxIn(scl.far, iMin, iEnd);
    ringback = math.min(ringback, vil - mx);
  }

  // ---- Analytical sizing -------------------------------------------------------
  final rpMin = (vdd - volMax) / p.sinkCurrent;
  final rpMax = mode.trMax / (0.8473 * cb);
  final trRc = 0.8473 * p.pullupR * cb;
  final volCalc = vdd * (p.rOn + p.seriesR) / (p.rOn + p.seriesR + p.pullupR);
  // Largest E12 value with 30 % rise-time margin, kept <= 10 kOhm for noise immunity.
  final rpRec = e12Below(math.min(0.7 * rpMax, 10e3));
  final feasible = rpMin <= rpMax;
  final rpRecOk = feasible && rpRec >= rpMin;
  final tfMin = mode == I2cMode.standard ? 0.0 : 20e-9 * vdd / 5.5;
  if (fastestFall.isInfinite) fastestFall = double.nan;
  // Highest SCL frequency the rise time allows with this controller timing.
  final tau = p.pullupR * cb;
  final fMaxEst = 1 /
      math.max((mode.tHighMin + 1.204 * tau) / (1 - p.sclLowFraction),
          (mode.tLowMin + 0.357 * tau + worstFall.clamp(0, 1e-6)) / p.sclLowFraction);
  final zDev = (z0 - p.targetZ0) / p.targetZ0 * 100;

  SiStatus limit(double v, double max, {double good = 0.8}) =>
      v.isNaN ? SiStatus.info : (v <= good * max ? SiStatus.good : (v <= max ? SiStatus.warning : SiStatus.critical));
  SiStatus atLeast(double v, double min) =>
      v.isNaN ? SiStatus.info : (v >= 1.05 * min ? SiStatus.good : (v >= min ? SiStatus.warning : SiStatus.critical));

  final rpStatus = !feasible
      ? SiStatus.critical
      : (p.pullupR < rpMin || p.pullupR > rpMax)
          ? SiStatus.critical
          : (p.pullupR < 1.1 * rpMin || p.pullupR > 0.9 * rpMax)
              ? SiStatus.warning
              : SiStatus.good;
  final fallStatus = worstFall > mode.tfMax
      ? SiStatus.critical
      : (fastestFall < tfMin ? SiStatus.warning : SiStatus.good);

  final metrics = <Metric>[
    Metric(
      id: 'fscl',
      label: 'SCL frequency',
      value: p.clockHz,
      unit: 'Hz',
      status: p.clockHz <= mode.fMax ? SiStatus.good : SiStatus.critical,
      level: ModelLevel.analytical,
      note: '${mode.label}: ≤ ${eng(mode.fMax, 'Hz')}',
    ),
    Metric(
      id: 'cb',
      label: 'Bus capacitance Cb',
      value: cb,
      unit: 'F',
      status: limit(cb, mode.cbMax),
      level: ModelLevel.analytical,
      note: 'Trace ${eng(cTrace, 'F')} + ${p.deviceCount} × ${eng(p.pinCap, 'F')} pins'
          '${p.extraCap > 0 ? ' + ${eng(p.extraCap, 'F')} other' : ''}. Limit ${eng(mode.cbMax, 'F')}.',
    ),
    Metric(
      id: 'rp',
      label: 'Pull-up resistor',
      value: p.pullupR,
      unit: 'ohm',
      status: rpStatus,
      level: ModelLevel.analytical,
      note: feasible
          ? 'Allowed ${ohm(rpMin)} – ${ohm(rpMax)} (Rp min = (VDD − VOL)/IOL, Rp max = tr / (0.8473 Cb))'
          : 'No valid value: Rp min ${ohm(rpMin)} > Rp max ${ohm(rpMax)}',
    ),
    Metric(
      id: 'rp_rec',
      label: 'Recommended pull-up',
      value: rpRecOk ? rpRec : double.nan,
      unit: 'ohm',
      status: SiStatus.info,
      level: ModelLevel.analytical,
      note: rpRecOk
          ? 'Largest E12 value with 30 % rise-time margin (capped at 10 kΩ for noise immunity)'
          : 'Reduce bus capacitance or use a bus buffer',
    ),
    Metric(
      id: 'tr',
      label: 'Rise time (30–70 %, worst)',
      value: worstRise,
      unit: 's',
      status: limit(worstRise, mode.trMax),
      level: ModelLevel.behavioral,
      note: worstRise.isInfinite
          ? 'An edge did not reach 0.7 VDD before the next fall (limit ${secs(mode.trMax)}; RC estimate ${secs(trRc)})'
          : 'Limit ${secs(mode.trMax)}. RC estimate 0.8473·Rp·Cb = ${secs(trRc)}',
    ),
    Metric(
      id: 'tf',
      label: 'Fall time (70–30 %, worst)',
      value: worstFall,
      unit: 's',
      status: fallStatus,
      level: ModelLevel.behavioral,
      note: 'Limit ${secs(mode.tfMax)}${tfMin > 0 ? ', minimum ${secs(tfMin)} (fastest ${secs(fastestFall)})' : ''}',
    ),
    Metric(
      id: 'vol',
      label: 'Low level VOL at target',
      value: vol,
      unit: 'V',
      status: vol <= volMax ? (vil - vol >= 0.1 * vdd ? SiStatus.good : SiStatus.warning) : SiStatus.critical,
      level: ModelLevel.behavioral,
      note: 'Limit ${volts(volMax)}; noise margin to VIL ${volts(vil - vol)} (≥ 0.1 VDD). '
          'Divider estimate ${volts(volCalc)}',
    ),
    Metric(
      id: 'tlow',
      label: 'Effective SCL tLOW',
      value: tLowEff,
      unit: 's',
      status: atLeast(tLowEff, mode.tLowMin),
      level: ModelLevel.behavioral,
      note: 'Minimum ${secs(mode.tLowMin)} (measured at 0.3 VDD)',
    ),
    Metric(
      id: 'thigh',
      label: 'Effective SCL tHIGH',
      value: tHighEff,
      unit: 's',
      status: atLeast(tHighEff, mode.tHighMin),
      level: ModelLevel.behavioral,
      note: 'Minimum ${secs(mode.tHighMin)} (measured at 0.7 VDD); slow rises eat into it',
    ),
    Metric(
      id: 'tsudat',
      label: 'Data setup tSU;DAT',
      value: tSuDat,
      unit: 's',
      status: tSuDat.isInfinite && tSuDat > 0 ? SiStatus.info : atLeast(tSuDat, mode.tSuDatMin),
      level: ModelLevel.behavioral,
      note: 'Minimum ${secs(mode.tSuDatMin)}',
    ),
    Metric(
      id: 'fmax_est',
      label: 'Max SCL frequency (estimate)',
      value: fMaxEst,
      unit: 'Hz',
      status: SiStatus.info,
      level: ModelLevel.analytical,
      note: 'Highest clock meeting tLOW/tHIGH with this rise time and ${pct(p.sclLowFraction * 100, decimals: 0)} low duty',
    ),
    Metric(
      id: 'undershoot',
      label: 'Lowest voltage (undershoot)',
      value: trough,
      unit: 'V',
      status: trough >= -0.3 ? SiStatus.good : (trough >= -0.5 ? SiStatus.warning : SiStatus.critical),
      level: ModelLevel.behavioral,
      note: 'Typical absolute maximum −0.5 V; check the device data sheet',
    ),
    Metric(
      id: 'overshoot_peak',
      label: 'Highest voltage',
      value: peak,
      unit: 'V',
      status: peak <= vdd + 0.3 ? SiStatus.good : SiStatus.warning,
      level: ModelLevel.behavioral,
    ),
    if (ringback.isFinite)
      Metric(
        id: 'rb_scl',
        label: 'SCL ring-back margin (low)',
        value: ringback,
        unit: 'V',
        status: classifySlack(ringback, 0.1 * vdd),
        level: ModelLevel.behavioral,
        note: 'Distance of post-fall ringing below VIL; negative = false clock edge risk',
      ),
    Metric(
      id: 'z0',
      label: 'Trace impedance Z0',
      value: z0,
      unit: 'ohm',
      status: SiStatus.info,
      level: ModelLevel.analytical,
      note: '${imp.method}. ${pct(zDev)} from ${ohm(p.targetZ0)}; I²C does not need controlled impedance.',
    ),
    Metric(
      id: 'delay',
      label: 'Propagation delay (one-way)',
      value: delay,
      unit: 's',
      status: SiStatus.info,
      level: ModelLevel.analytical,
    ),
  ];

  // ---- Findings --------------------------------------------------------------
  Metric m(String id) => metrics.firstWhere((x) => x.id == id);
  final findings = <Finding>[];
  if (m('cb').status != SiStatus.good) {
    findings.add(Finding(
      status: m('cb').status,
      title: cb > mode.cbMax ? 'Bus capacitance above the I²C limit' : 'Bus capacitance close to the limit',
      reason: 'Cb = ${eng(cb, 'F')} against ${eng(mode.cbMax, 'F')} for ${mode.label}. Every device pin, '
          'connector and centimetre of trace adds capacitance that the pull-up must charge.',
      recommendation: 'Remove unneeded devices or connectors from this segment, shorten the bus, or split it with '
          'an I²C bus buffer / repeater. A rise-time accelerator also helps on long buses.',
    ));
  }
  if (rpStatus != SiStatus.good) {
    findings.add(Finding(
      status: rpStatus,
      title: !feasible
          ? 'No pull-up value can satisfy this bus'
          : p.pullupR > rpMax
              ? 'Pull-up resistor too large'
              : p.pullupR < rpMin
                  ? 'Pull-up resistor too small'
                  : 'Pull-up resistor near its limit',
      reason: !feasible
          ? 'The smallest pull-up the drivers can sink (${ohm(rpMin)}) is larger than the largest one that '
              'meets the ${secs(mode.trMax)} rise time with Cb = ${eng(cb, 'F')} (${ohm(rpMax)}).'
          : 'Rp = ${ohm(p.pullupR)}. A larger Rp gives slow rising edges; a smaller one prevents the '
              'drivers from pulling the line below VOL ${volts(volMax)} at IOL ${eng(p.sinkCurrent, 'A')}. '
              'Allowed range ${ohm(rpMin)} – ${ohm(rpMax)}.',
      recommendation: rpRecOk
          ? 'Use ≈ ${ohm(rpRec)} on SCL and SDA.'
          : 'Reduce the bus capacitance, lower the bus speed mode, or use stronger (Fast-mode Plus, 20 mA) drivers '
              'or a bus buffer.',
    ));
  }
  if (m('tr').status != SiStatus.good) {
    findings.add(Finding(
      status: m('tr').status,
      title: worstRise > mode.trMax ? 'Rising edges too slow' : 'Rise time close to the limit',
      reason: '${worstRise.isInfinite ? 'Some rising edges never reach 0.7 VDD' : 'Rise time ${secs(worstRise)} (30–70 % VDD)'} against ${secs(mode.trMax)}. It is set by '
          'Rp × Cb = ${ohm(p.pullupR)} × ${eng(cb, 'F')}.',
      recommendation: rpRecOk ? 'Lower the pull-up to ≈ ${ohm(rpRec)} or reduce the bus capacitance.' : 'Reduce the bus capacitance.',
    ));
  }
  if (fallStatus != SiStatus.good) {
    findings.add(Finding(
      status: fallStatus,
      title: worstFall > mode.tfMax ? 'Falling edges too slow' : 'Falling edges faster than the spec minimum',
      reason: worstFall > mode.tfMax
          ? 'Fall time ${secs(worstFall)} exceeds ${secs(mode.tfMax)}: the drivers are too weak for Cb.'
          : 'Fastest fall ${secs(fastestFall)} is below ${secs(tfMin)}. Very fast falls ring on long traces and radiate.',
      recommendation: worstFall > mode.tfMax
          ? 'Use drivers with more sink current or reduce the bus capacitance.'
          : 'Enable the device\'s slope control, or add ≈ 100 Ω series resistors at the device pins.',
    ));
  }
  if (m('vol').status != SiStatus.good) {
    findings.add(Finding(
      status: m('vol').status,
      title: 'Low level too high',
      reason: 'The line only reaches ${volts(vol)} when pulled low (limit ${volts(volMax)}, VIL ${volts(vil)}). '
          'The pull-up and any series resistance fight the open-drain driver.',
      recommendation: 'Increase the pull-up to at least ${ohm(rpMin)}${p.seriesR > 0 ? ' or reduce the series resistor' : ''}.',
    ));
  }
  for (final id in ['tlow', 'thigh', 'tsudat']) {
    final x = m(id);
    if (x.status == SiStatus.good || x.status == SiStatus.info) continue;
    findings.add(Finding(
      status: x.status,
      title: '${x.label} ${x.status == SiStatus.critical ? 'below the minimum' : 'has little margin'}',
      reason: '${x.label} = ${secs(x.value)} at the farthest target (${x.note}).',
      recommendation: id == 'thigh'
          ? 'Speed up the rising edge (smaller pull-up / less capacitance) or lower SCL to ≤ ${eng(fMaxEst, 'Hz')}. '
              'Controllers with clock synchronisation stretch SCL instead, which lowers the real bus speed.'
          : id == 'tlow'
              ? 'Increase the controller SCL low time (duty cycle) or lower the SCL frequency.'
              : 'Change SDA earlier in the SCL low phase or speed up the SDA edges.',
    ));
  }
  if (m('undershoot').status != SiStatus.good || (ringback.isFinite && ringback < 0.1 * vdd)) {
    findings.add(Finding(
      status: worst([m('undershoot').status, if (ringback.isFinite) classifySlack(ringback, 0.1 * vdd)]),
      title: 'Ringing on falling edges',
      reason: 'Fast falls on a ${secs(delay)} trace ring to ${volts(trough)}'
          '${ringback.isFinite ? ' with ring-back margin ${volts(ringback)} below VIL' : ''}.',
      recommendation: 'Add ≈ 100 Ω series resistors at the drivers or use slope-controlled outputs.',
    ));
  }
  if (p.clockHz > mode.fMax) {
    findings.add(Finding(
      status: SiStatus.critical,
      title: 'SCL frequency above the mode maximum',
      reason: '${eng(p.clockHz, 'Hz')} exceeds ${eng(mode.fMax, 'Hz')} for ${mode.label}.',
      recommendation: 'Select a faster mode (if all devices support it) or lower the clock.',
    ));
  }
  if (findings.isEmpty) {
    findings.add(Finding(
      status: SiStatus.good,
      title: 'I²C bus within specification',
      reason: 'Rise/fall times, bus capacitance, pull-up value, low level and SCL timing meet the '
          '${mode.label} limits at the farthest target.',
      recommendation: rpRecOk && (p.pullupR - rpRec).abs() / rpRec > 0.3
          ? 'Optional: ${ohm(rpRec)} pull-ups balance rise time and power.'
          : 'No change needed. Re-check if devices or connectors are added.',
    ));
  }

  // ---- Checks (UM10204 reference values) ---------------------------------------
  final checks = <ComplianceCheck>[
    ComplianceCheck(name: 'SCL clock frequency', requirement: '≤ ${eng(mode.fMax, 'Hz')}', measured: eng(p.clockHz, 'Hz'),
        pass: p.clockHz <= mode.fMax, source: 'spec reference'),
    ComplianceCheck(name: 'Rise time tr (30–70 %)', requirement: '≤ ${secs(mode.trMax)}',
        measured: worstRise.isInfinite ? 'edge incomplete' : secs(worstRise),
        pass: worstRise <= mode.trMax, source: 'spec reference'),
    ComplianceCheck(name: 'Fall time tf (70–30 %)', requirement: tfMin > 0 ? '${secs(tfMin)} – ${secs(mode.tfMax)}' : '≤ ${secs(mode.tfMax)}',
        measured: secs(worstFall), pass: worstFall <= mode.tfMax && fastestFall >= tfMin, source: 'spec reference'),
    ComplianceCheck(name: 'Bus capacitance Cb', requirement: '≤ ${eng(mode.cbMax, 'F')}', measured: eng(cb, 'F'),
        pass: cb <= mode.cbMax, source: 'spec reference'),
    ComplianceCheck(name: 'Low-level output VOL', requirement: '≤ ${volts(volMax)}', measured: volts(vol), pass: vol <= volMax,
        source: 'spec reference'),
    ComplianceCheck(name: 'SCL low period tLOW', requirement: '≥ ${secs(mode.tLowMin)}', measured: secs(tLowEff),
        pass: tLowEff >= mode.tLowMin, source: 'spec reference'),
    ComplianceCheck(name: 'SCL high period tHIGH', requirement: '≥ ${secs(mode.tHighMin)}', measured: secs(tHighEff),
        pass: tHighEff >= mode.tHighMin, source: 'spec reference'),
    if (tSuDat.isFinite)
      ComplianceCheck(name: 'Data setup tSU;DAT', requirement: '≥ ${secs(mode.tSuDatMin)}', measured: secs(tSuDat),
          pass: tSuDat >= mode.tSuDatMin, source: 'spec reference'),
    ComplianceCheck(name: 'Pull-up within range', requirement: feasible ? '${ohm(rpMin)} – ${ohm(rpMax)}' : 'no valid range',
        measured: ohm(p.pullupR), pass: feasible && p.pullupR >= rpMin && p.pullupR <= rpMax, source: 'spec reference'),
    ...complianceChecks(cfg, metrics),
  ];

  // ---- Traces ------------------------------------------------------------------
  Float32List ideal(List<(double, bool)> ev) {
    final out = Float32List(samples);
    var k = 0;
    var low = false;
    for (var i = 0; i < samples; i++) {
      final t = i * dt;
      while (k < ev.length && ev[k].$1 <= t) {
        low = ev[k].$2;
        k++;
      }
      out[i] = low ? 0 : vdd;
    }
    return out;
  }

  final traces = <WaveformTrace>[
    WaveformTrace(id: 'scl_ideal', label: 'SCL controller logic', group: 'SCL', kind: TraceKind.ideal, values: ideal(sched.scl)),
    WaveformTrace(id: 'scl_tx', label: 'SCL @ controller', group: 'SCL', kind: TraceKind.tx, values: Float32List.fromList(scl.near)),
    WaveformTrace(id: 'scl_rx', label: 'SCL @ farthest target', group: 'SCL', kind: TraceKind.rx, values: Float32List.fromList(scl.far)),
    WaveformTrace(id: 'sda_ideal', label: 'SDA controller logic', group: 'SDA', kind: TraceKind.ideal, values: ideal(sched.sda)),
    WaveformTrace(id: 'sda_tx', label: 'SDA @ controller', group: 'SDA', kind: TraceKind.tx, values: Float32List.fromList(sda.near)),
    WaveformTrace(id: 'sda_rx', label: 'SDA @ farthest target', group: 'SDA', kind: TraceKind.rx, values: Float32List.fromList(sda.far)),
  ];
  final views = <String, List<String>>{
    'Bus at target': ['scl_rx', 'sda_rx'],
    'SCL': ['scl_ideal', 'scl_tx', 'scl_rx'],
    'SDA': ['sda_ideal', 'sda_tx', 'sda_rx'],
  };

  final assumptions = <String>[
    ...imp.assumptions,
    'Open-drain drivers: on-resistance ${ohm(p.rOn)} (VOL 0.4 V at ${eng(p.sinkCurrent, 'A')}), '
        'turn-on ${secs(tOn)}; rising edges come from the ${ohm(p.pullupR)} pull-up '
        '${p.pullupAtTarget ? 'at the far target' : 'at the controller'}.',
    'Controller pin capacitance at the near end; the other ${p.deviceCount - 1} device(s) and '
        '${eng(p.extraCap, 'F')} extra capacitance lumped at the far end (worst case).',
    useLine && !lumped
        ? 'Trace modelled as a lossless transmission line (${secs(delay)}, ${ohm(z0)}).'
        : 'Trace is electrically very short for this time step; modelled by its capacitance (${eng(cTrace, 'F')}).',
    'START + ${bits.length} data bits + STOP driven by the controller; acknowledge bits and clock stretching by '
        'targets are not modelled. Fixed controller SCL timing (${pct(p.sclLowFraction * 100, decimals: 0)} low).',
    'Thresholds VIL 0.3 VDD, VIH 0.7 VDD; limits from NXP UM10204 (I²C-bus specification) for ${mode.label}.',
    if (pcb.elements.isNotEmpty) 'Channel elements (vias, connectors) are ignored for I²C; add their capacitance as "other capacitance".',
    if (pcb.crosstalk.enabled) 'Crosstalk analysis is not available for I²C.',
  ];
  sw.stop();
  return SimulationResult(
    config: cfg,
    dt: dt,
    sampleCount: samples,
    traces: traces,
    views: views,
    metrics: metrics,
    findings: findings,
    assumptions: assumptions,
    impedance: ImpedanceSummary(
      structure: geom.structure.label,
      z0: z0,
      zDiff: null,
      eeff: imp.eeff,
      target: p.targetZ0,
      targetIsDiff: false,
      method: imp.method,
      widthForTarget: solveWidthForTarget(geom, p.targetZ0),
    ),
    eyes: const [],
    animation: null,
    computeMillis: sw.elapsedMilliseconds,
    checks: checks,
  );
}
