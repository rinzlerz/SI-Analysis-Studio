/// Input validation (PRD 13 Reliability): invalid electrical configurations
/// are rejected with explicit messages instead of substituted defaults.
library;

import 'impedance/impedance.dart';
import 'model/bus_lengths.dart';
import 'model/config.dart';
import 'waveform_engine/stimulus.dart';

class ValidationIssue {
  const ValidationIssue(this.field, this.message, {this.blocking = true});
  final String field;
  final String message;

  /// Blocking issues prevent simulation; non-blocking ones are warnings.
  final bool blocking;
  @override
  String toString() => '$field: $message';
}

List<ValidationIssue> validateConfig(AnalysisConfig c) {
  final out = <ValidationIssue>[];
  void err(String f, String m) => out.add(ValidationIssue(f, m));
  void warn(String f, String m) => out.add(ValidationIssue(f, m, blocking: false));
  bool pos(double v) => v.isFinite && v > 0;

  if (!c.protocol.supported) {
    err('Protocol', '${c.protocol.label} is planned for Phase 2 and is not simulated yet.');
    return out;
  }
  // --- Stackup / PCB -------------------------------------------------------
  final s = c.pcb.stackup;
  if (s.layers.length < 2) err('Stackup', 'At least two copper layers are required.');
  if (s.dielectrics.length != s.layers.length - 1) {
    err('Stackup', 'Dielectric count must be layer count - 1.');
  }
  for (var i = 0; i < s.dielectrics.length; i++) {
    if (!pos(s.dielectrics[i])) err('Stackup', 'Dielectric ${i + 1} thickness must be > 0.');
  }
  for (var i = 0; i < s.layers.length; i++) {
    if (!pos(s.layers[i].copperThickness)) err('Stackup', 'L${i + 1} copper thickness must be > 0.');
  }
  if (!(s.dk >= 1 && s.dk <= 15)) err('Dk', 'Dielectric constant must be between 1 and 15.');
  if (!(s.df >= 0 && s.df <= 0.1)) err('Df', 'Dissipation factor must be between 0 and 0.1.');
  if (!pos(c.pcb.traceWidth)) err('Trace width', 'Must be > 0.');
  if (!pos(c.pcb.traceLength)) err('Trace length', 'Must be > 0.');
  if (perSignalOn(c)) {
    for (final sig in busSignals(c)) {
      final l = signalLength(c, sig);
      if (!(l > 0 && l <= 2)) err('${sig.name} length', 'Must be > 0 and <= 2 m.');
    }
  }
  if (c.pcb.traceLength > 2) err('Trace length', 'Must be <= 2 m for this model.');
  if (c.protocol.differential) {
    if (!pos(c.pcb.traceSpacing)) err('Trace spacing', 'Must be > 0 for a differential pair.');
    if (c.pcb.lengthMismatch.abs() >= c.pcb.traceLength) {
      err('Length mismatch', 'Must be smaller than the trace length.');
    }
  }
  if (out.any((e) => e.blocking)) return out;
  try {
    final g = geometryFromStackup(s);
    final u = c.pcb.traceWidth / g.h1;
    if (u < 0.01 || u > 100) {
      err('Trace width', 'W/h = ${u.toStringAsFixed(3)} is outside the model range (0.01-100).');
    } else if (u < 0.1 || u > 20) {
      warn('Trace width', 'W/h = ${u.toStringAsFixed(2)} is outside 0.1-20; impedance accuracy is reduced.');
    }
    if (g.t >= g.h1) err('Copper thickness', 'Copper thickness must be smaller than the dielectric height.');
    for (final n in g.notes) {
      if (n.contains('one side only')) warn('Stackup', n);
    }
  } on StackupError catch (e) {
    err('Stackup', e.message);
  }

  // --- Protocol ------------------------------------------------------------
  if (c.protocol.spiFamily) {
    final p = c.spiCfg;
    if (!(p.clockHz >= 1e3 && p.clockHz <= 200e6)) err('Clock', 'Clock must be 1 kHz - 200 MHz.');
    if (!(p.voltage >= 0.5 && p.voltage <= 5.5)) err('Voltage', 'VDD must be 0.5 - 5.5 V.');
    if (!pos(p.riseTime) || !pos(p.fallTime)) err('Edges', 'Rise and fall time must be > 0.');
    final dtr = c.protocol == Protocol.qspi && p.dtr;
    final half = (dtr ? 0.25 : 0.5) / p.clockHz;
    final what = dtr ? 'a quarter of the clock period (DTR bit time / 2)' : 'half the clock period';
    if (pos(p.riseTime) && p.riseTime / 0.8 > half) {
      err('Rise time', 'Edge (tr/0.8) is longer than $what.');
    }
    if (pos(p.fallTime) && p.fallTime / 0.8 > half) {
      err('Fall time', 'Edge (tf/0.8) is longer than $what.');
    }
    if (c.protocol == Protocol.qspi) {
      if (!p.perSignalLengths && !(p.dataClockMismatch.abs() < c.pcb.traceLength)) {
        err('IO-to-CLK mismatch', 'Must be smaller than the trace length.');
      }
      if (!(p.readSampleDelay >= 0 && p.readSampleDelay < 2 / p.clockHz)) {
        err('Read sample delay', 'Must be 0 to two clock periods.');
      }
      if (p.useDqs && !p.dtr) warn('DQS', 'DQS read capture is used with DTR (octal DDR) only; it is ignored in SDR.');
      if (p.clockHz > 133e6 && !p.dtr) warn('Clock', 'Most quad SPI flash devices support at most 133 MHz in SDR.');
    }
    if (!pos(p.driverImpedance)) err('Driver impedance', 'Must be > 0 ohm.');
    if (p.termination.hasSeries && !(p.seriesR >= 0)) err('Series R', 'Must be >= 0 ohm.');
    if (p.termination.hasParallel && !pos(p.parallelR)) err('Parallel R', 'Must be > 0 ohm.');
    if (p.termination.hasAc && (!pos(p.acR) || !pos(p.acC))) err('AC termination', 'R and C must be > 0.');
    if (!(p.receiverCap >= 0)) err('Receiver capacitance', 'Must be >= 0.');
    if (!pos(p.receiverRin)) err('Receiver resistance', 'Must be > 0.');
    if (!(p.vilFraction > 0 && p.vilFraction < p.vihFraction && p.vihFraction < 1)) {
      err('Thresholds', 'Require 0 < VIL < VIH < VDD.');
    }
    if (!(p.slaveTco >= 0 && p.setupTime >= 0 && p.holdTime >= 0)) {
      err('Timing', 'tCO, setup and hold must be >= 0.');
    }
    if (!pos(p.targetZ0)) err('Target Z0', 'Must be > 0.');
    if (p.useIbis) {
      if (p.ibisDriver == null || !p.ibisDriver!.canDrive) {
        err('IBIS', 'Select an IBIS driver model with [Pullup], [Pulldown] and [Ramp] data.');
      }
      if (p.ibisReceiver == null) err('IBIS', 'Select an IBIS receiver (input) model.');
    }
    if (!(c.sim.numBits >= 1 && c.sim.numBits <= 256)) err('Bits', 'SPI frame must be 1-256 bits.');
  } else if (c.protocol == Protocol.i2c) {
    final p = c.i2c;
    if (!(p.clockHz >= 1e3 && p.clockHz <= 1e6)) err('Clock', 'SCL must be 1 kHz - 1 MHz.');
    if (!(p.voltage >= 1.0 && p.voltage <= 5.5)) err('Voltage', 'VDD must be 1.0 - 5.5 V.');
    if (!(p.pullupR >= 50 && p.pullupR <= 1e6)) err('Pull-up', 'Must be 50 Ω - 1 MΩ.');
    if (!(p.deviceCount >= 2 && p.deviceCount <= 127)) err('Devices', '2 - 127 devices (including the controller).');
    if (!(p.pinCap >= 0 && p.pinCap <= 50e-12)) err('Pin capacitance', 'Must be 0 - 50 pF.');
    if (!(p.extraCap >= 0 && p.extraCap <= 5e-9)) err('Other capacitance', 'Must be 0 - 5 nF.');
    if (!(p.sinkCurrent >= 0.5e-3 && p.sinkCurrent <= 100e-3)) err('Sink current', 'Must be 0.5 - 100 mA.');
    if (!(p.driverFallTime >= 1e-9 && p.driverFallTime <= 1e-6)) err('Driver turn-on time', 'Must be 1 ns - 1 µs.');
    if (!(p.sclLowFraction >= 0.3 && p.sclLowFraction <= 0.7)) err('SCL duty', 'Low fraction must be 0.3 - 0.7.');
    if (!(p.seriesR >= 0 && p.seriesR <= 1000)) err('Series R', 'Must be 0 - 1 kΩ.');
    if (p.pinCap > 10e-12) warn('Pin capacitance', 'The I²C specification allows at most 10 pF per pin.');
    if (!(c.sim.numBits >= 1 && c.sim.numBits <= 36)) err('Bits', 'I²C transfer must be 1-36 bits.');
  } else if (c.protocol == Protocol.rgmii) {
    final p = c.rgmii;
    final tBit = (p.speed.ddr ? 0.5 : 1.0) / p.speed.clockHz;
    if (!(p.voltage >= 1.2 && p.voltage <= 3.6)) err('Voltage', 'VDD must be 1.2 - 3.6 V.');
    if (!pos(p.riseTime) || !pos(p.fallTime)) err('Edges', 'Rise and fall time must be > 0.');
    if (pos(p.riseTime) && p.riseTime / 0.8 > tBit / 2) err('Rise time', 'Edge (tr/0.8) exceeds half a bit time.');
    if (pos(p.fallTime) && p.fallTime / 0.8 > tBit / 2) err('Fall time', 'Edge (tf/0.8) exceeds half a bit time.');
    if (!pos(p.driverImpedance)) err('Driver impedance', 'Must be > 0 ohm.');
    if (!(p.seriesR >= 0)) err('Series R', 'Must be >= 0 ohm.');
    if (!(p.receiverCap >= 0)) err('Receiver capacitance', 'Must be >= 0.');
    if (!(p.txClockDelay >= 0 && p.txClockDelay < tBit * 2) || !(p.rxClockDelay >= 0 && p.rxClockDelay < tBit * 2)) {
      err('Clock delay', 'Internal delays must be 0 to two bit times.');
    }
    if (!p.perSignalLengths && !(c.pcb.traceLength + p.clockExtraLength > 0)) {
      err('Clock length', 'The clock trace must be longer than 0.');
    }
    if (!(p.txSkew >= 0 && p.setupTime >= 0 && p.holdTime >= 0)) err('Timing', 'Skew, setup and hold must be >= 0.');
    if (!(c.sim.numBits >= 4 && c.sim.numBits <= 512)) err('Bits', 'RGMII pattern must be 4-512 bits.');
  } else if (c.protocol == Protocol.ddr) {
    final p = c.ddr;
    if (!p.standard.rates.contains(p.rate) && !(p.rate >= 400 && p.rate <= 6400)) {
      err('Data rate', 'Use 400 – 6400 MT/s.');
    } else if (!p.standard.rates.contains(p.rate)) {
      warn('Data rate', '${p.rate} MT/s is not a standard ${p.standard.label} speed bin; the nearest lower bin\'s mask is used.');
    }
    for (final (f, v) in [('Controller Ron', p.ctrlRon), ('DRAM Ron', p.dramRon), ('Write ODT', p.odtWrite), ('Read ODT', p.odtRead), ('CA Ron', p.caRon)]) {
      if (!(v >= 10 && v <= 1000)) err(f, 'Must be 10 Ω – 1 kΩ.');
    }
    if (!(p.ioCap >= 0 && p.ioCap <= 10e-12)) err('Pin capacitance', 'Must be 0 – 10 pF.');
    if (!(p.deviceCap >= 0 && p.deviceCap <= 10e-12)) err('Device capacitance', 'Must be 0 – 10 pF.');
    if (!(p.devices >= 1 && p.devices <= 16)) err('Devices', '1 – 16 devices.');
    if (p.standard.lp && p.devices > 2) warn('Devices', 'LPDDR4 channels have one or two dies; ${p.devices} is modelled as 2.');
    if (!(p.leadIn > 1e-3 && p.leadIn <= 0.5)) err('CA lead-in', 'Must be 1 – 500 mm.');
    if (!(p.leadIn - p.caClkMismatch > 1e-3)) err('CA − CK length', 'The CK lead-in must stay longer than 1 mm.');
    if (p.devices > 1 && !(p.spacing >= 1e-3 && p.spacing <= 0.1)) err('Device spacing', 'Must be 1 – 100 mm.');
    if (!(p.stub >= 0.2e-3 && p.stub <= 30e-3)) err('Stub length', 'Must be 0.2 – 30 mm.');
    if (p.standard.caTopology == CaTopology.flyBy && !(p.vttR >= 10 && p.vttR <= 200)) err('VTT resistor', 'Must be 10 – 200 Ω.');
    if (p.standard.lp && !(p.caOdt >= 20 && p.caOdt <= 1000)) err('CA ODT', 'Must be 20 Ω – 1 kΩ.');
    if (p.riseTime != 0 && !(p.riseTime > 10e-12 && p.riseTime < 0.6 * p.ui)) err('Edge time', 'Must be 10 ps – 0.6 UI (0 = automatic).');
    if (!(p.jitter >= 0 && p.jitter < p.ui) || !(p.jitterRead >= 0 && p.jitterRead < p.ui)) err('Jitter', 'Must be 0 – 1 UI (0 = automatic).');
    for (final (f, v) in [('DQ mask height', p.dqMaskV), ('CA mask height', p.caMaskV)]) {
      if (v != null && !(v > 0 && v < p.vddq)) err(f, 'Must be between 0 and VDDQ.');
    }
    for (final (f, v) in [('DQ mask width', p.dqMaskT), ('CA setup', p.caSetup), ('CA hold', p.caHold)]) {
      if (v != null && !(v >= 0 && v < 2 * p.tck)) err(f, 'Must be 0 – 2 tCK.');
    }
    if (!(c.sim.numBits >= 32 && c.sim.numBits <= 1024)) err('Bits', 'DDR pattern must be 32 – 1024 bits.');
  } else if (c.protocol == Protocol.usb2) {
    final p = c.usb2;
    final ui = 1 / p.speed.bitRate;
    if (!pos(p.riseTime) || !pos(p.fallTime)) err('Edges', 'Rise and fall time must be > 0.');
    if (pos(p.riseTime) && p.riseTime / 0.8 > ui) err('Rise time', 'Edge (tr/0.8) exceeds one UI.');
    if (pos(p.fallTime) && p.fallTime / 0.8 > ui) err('Fall time', 'Edge (tf/0.8) exceeds one UI.');
    if (!pos(p.driverImpedance)) err('Driver impedance', 'Must be > 0 ohm.');
    if (!(p.seriesR >= 0)) err('Series R', 'Must be >= 0 ohm.');
    if (p.rxTermEnabled && !pos(p.rxTermR)) err('RX termination', 'Must be > 0 ohm.');
    if (!(p.receiverCap >= 0)) err('Receiver capacitance', 'Must be >= 0.');
    if (!pos(p.receiverRin)) err('Receiver resistance', 'Must be > 0.');
    if (!pos(p.targetZdiff)) err('Target Zdiff', 'Must be > 0.');
    if (!(c.sim.numBits >= 8 && c.sim.numBits <= 2048)) err('Bits', 'USB pattern must be 8-2048 bits.');
    if (p.speed == Usb2Speed.highSpeed && p.riseTime < 500e-12) {
      warn('Rise time', 'USB 2.0 HS specifies a minimum 10-90 % rise time of 500 ps.');
    }
  }
  if (c.protocol.serdes) {
    final p = c.serdes;
    final ui = 1 / c.serdesRate;
    if (!pos(p.riseTime)) err('Rise time', 'Must be > 0.');
    if (pos(p.riseTime) && p.riseTime / 0.8 > ui) err('Rise time', 'Edge (tr/0.8) exceeds one UI (${(ui * 1e12).toStringAsFixed(1)} ps).');
    if (!(p.txSwingPp >= 0.05 && p.txSwingPp <= 2)) err('TX swing', 'Must be 0.05 - 2 V differential p-p.');
    if (!pos(p.txImpedance)) err('TX impedance', 'Must be > 0 ohm.');
    if (!pos(p.rxTermination)) err('RX termination', 'Must be > 0 ohm.');
    if (!(p.receiverCap >= 0)) err('Receiver capacitance', 'Must be >= 0.');
    if (!(p.deEmphasisDb >= -12 && p.deEmphasisDb <= 0)) err('De-emphasis', 'Must be between -12 and 0 dB.');
    if (!(p.ctleDcGainDb >= -20 && p.ctleDcGainDb <= 0)) err('CTLE', 'DC gain must be between -20 and 0 dB.');
    if (!(p.dfeTaps >= 0 && p.dfeTaps <= 5)) err('DFE', '0 - 5 taps.');
    if (!(p.rjRms >= 0 && p.rjRms < ui)) err('RJ', 'Must be >= 0 and smaller than one UI.');
    if (!pos(p.maskHeight) || !(p.maskWidthUi > 0 && p.maskWidthUi < 1)) err('Eye minimum', 'Height > 0 and width 0-1 UI.');
    if (c.protocol != Protocol.hdmi && ![1, 2, 4, 8, 16].contains(p.lanes)) err('Lanes', 'Use x1, x2, x4, x8 or x16.');
    if (!(p.laneMismatch >= 0 && p.laneMismatch <= 1)) err('Lane mismatch', 'Must be 0 - 1 m.');
    if (!pos(p.targetZdiff)) err('Target Zdiff', 'Must be > 0.');
    if (p.useTouchstone && p.sparams == null) err('S-parameters', 'Load a Touchstone (.s2p/.s4p) file or switch to the PCB model.');
    if (p.useTouchstone && p.sparams != null && p.sparams!.fMax < 0.5 * c.serdesRate) {
      warn('S-parameters', 'File bandwidth (${(p.sparams!.fMax / 1e9).toStringAsFixed(1)} GHz) is below 1.5× Nyquist; edges are band-limited by the taper.');
    } else if (p.useTouchstone && p.sparams != null && p.sparams!.fMax < 0.75 * c.serdesRate) {
      warn('S-parameters', 'File bandwidth is below 1.5× Nyquist; high-frequency content is tapered.');
    }
    if (!(c.sim.numBits >= 32 && c.sim.numBits <= 1024)) err('Bits', 'SerDes pattern must be 32-1024 bits.');
  }
  if (c.sim.pattern == DataPattern.custom) {
    try {
      parseCustomPattern(c.sim.customPattern);
    } on PatternError catch (e) {
      err('Data pattern', e.message);
    }
  }
  if (c.sim.timeStepTarget < 0) err('Time step', 'Must be >= 0 (0 = automatic).');
  return out;
}
