/// Shared preparation for protocol simulations: geometry, impedance, line
/// parameters, time step and loss kernel.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../channel_loss/channel_loss.dart';
import '../impedance/impedance.dart';
import '../model/config.dart';
import '../transmission_line/line_params.dart';

class SimulationError implements Exception {
  SimulationError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Hard limit on time steps to keep simulations within a few seconds on a
/// phone.
const int maxSimulationSteps = 3000000;

class LinkContext {
  LinkContext({
    required this.geometry,
    required this.impedance,
    required this.line,
    required this.dt,
    required this.lossImpulse,
    required this.assumptions,
    required this.duration,
    required this.lossy,
  });

  final bool lossy;

  /// Loss kernel for a trace piece of [length] (null when lossless).
  Float64List? kernelFor(double length) => lossy ? lineLossImpulse(withLength(length), dt) : null;

  /// Simulated time span (s).
  final double duration;

  /// Number of samples covering [duration].
  int get samples => (duration / dt).ceil() + 1;

  final TraceGeometry geometry;
  final ImpedanceResult impedance;

  /// Line model of the propagating mode (Z0 or odd-mode Z).
  final LineParams line;
  final double dt;
  final Float64List? lossImpulse;
  final List<String> assumptions;

  /// Same line with a different routed length (e.g. the N leg of a pair).
  LineParams withLength(double length) => LineParams(
        z0: line.z0,
        eeff: line.eeff,
        length: length,
        width: line.width,
        geometry: line.geometry,
        tanD: line.tanD,
        roughness: line.roughness,
      );
}

LinkContext prepareLink({
  required AnalysisConfig cfg,
  required bool differential,
  required double minEdge,
  int stepsPerEdge = 40,
  required double Function(double oneWayDelay) durationFor,
  double extraLength = 0,
}) {
  final pcb = cfg.pcb;
  final TraceGeometry geom;
  try {
    geom = geometryFromStackup(pcb.stackup);
  } on StackupError catch (e) {
    throw SimulationError(e.message);
  }
  final imp = computeImpedance(geom, pcb.traceWidth,
      spacing: differential ? pcb.traceSpacing : null, diffModel: pcb.diffModel);
  final zMode = differential ? imp.zOdd! : imp.z0;
  final line = LineParams(
    z0: zMode,
    eeff: differential && imp.eeffOdd != null ? imp.eeffOdd! : imp.eeff,
    length: pcb.traceLength,
    width: pcb.traceWidth,
    geometry: geom,
    tanD: pcb.stackup.df,
    roughness: pcb.stackup.roughnessRms,
  );
  final assumptions = <String>[...imp.assumptions];
  final minDelay = line.tpdPerMetre * math.min(pcb.traceLength, pcb.traceLength + extraLength);
  final auto = minEdge / stepsPerEdge;
  final target = cfg.sim.timeStepTarget > 0 ? cfg.sim.timeStepTarget : auto;
  if (cfg.sim.timeStepTarget > 0 && cfg.sim.timeStepTarget > minEdge / 10) {
    assumptions.add('User time step is coarser than tr/10; edges and ringing may be under-resolved.');
  }
  var dt = math.min(target, minDelay);
  // Channel discontinuities: resolve the shortest stub / segment / piece.
  final els = [...pcb.elements]..sort((a, b) => a.position.compareTo(b.position));
  if (els.isNotEmpty) {
    var minEl = double.infinity;
    var last = 0.0;
    final sqEr = math.sqrt(geom.er);
    for (final e in els) {
      final p = e.position.clamp(0.0, pcb.traceLength);
      if (p - last > 1e-7) minEl = math.min(minEl, (p - last) * line.tpdPerMetre);
      last = p;
      if (e.type == ChannelElementType.via && e.stubLength > 0) {
        minEl = math.min(minEl, e.stubLength * sqEr / 299792458.0);
      }
      if (e.type == ChannelElementType.segment) minEl = math.min(minEl, e.delay);
    }
    if (pcb.traceLength - last > 1e-7) minEl = math.min(minEl, (pcb.traceLength - last) * line.tpdPerMetre);
    if (minEl.isFinite) {
      final floor = 0.2e-12;
      if (minEl < floor) {
        assumptions.add('A channel element is shorter than ${floor * 1e12} ps; its delay is rounded up to the time step.');
      }
      dt = math.min(dt, math.max(floor, minEl));
    }
  }
  final duration = durationFor(line.delay + math.max(0, extraLength) * line.tpdPerMetre);
  final steps = duration / dt;
  if (steps > maxSimulationSteps) {
    throw SimulationError('The simulation would need ${steps.toStringAsFixed(0)} time steps '
        '(limit $maxSimulationSteps). Reduce the number of bits, increase the clock/data rate, '
        'or use a coarser time step.');
  }
  Float64List? loss;
  if (cfg.sim.lossy) {
    loss = lineLossImpulse(line, dt);
    final rq = pcb.stackup.roughnessRms;
    assumptions.add('Frequency-dependent conductor (skin effect) and dielectric loss included; '
        '${rq > 0 ? 'copper roughness ${(rq * 1e6).toStringAsFixed(2)} µm rms (Hammerstad-Groiss)' : 'smooth copper'}; '
        'causal minimum-phase loss response.');
  } else {
    assumptions.add('Lossless transmission line (loss disabled in simulation settings).');
  }
  assumptions.add('Ideal reference plane and return path; no vias, connectors, or crosstalk.');
  return LinkContext(
    geometry: geom,
    impedance: imp,
    line: line,
    dt: dt,
    lossImpulse: loss,
    assumptions: assumptions,
    duration: duration,
    lossy: cfg.sim.lossy,
  );
}
