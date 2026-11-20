import '../../simulation/common/format.dart';
import '../../simulation/engine.dart';

/// Formats a metric value according to its unit hint.
String formatMetric(Metric m) {
  final v = m.value;
  if (v.isNaN) return '—';
  if (v.isInfinite) return 'n/a';
  return switch (m.unit) {
    'ohm' => ohm(v),
    's' => secs(v),
    'V' => volts(v),
    '%' => pct(v),
    'dB' => '${v.toStringAsFixed(2)} dB',
    'ps/mm' => '${v.toStringAsFixed(2)} ps/mm',
    'Hz' => eng(v, 'Hz'),
    'm' => mm(v),
    'nF' => '${v.toStringAsFixed(0)} nF',
    '' => m.id == 'mask_hits' ? v.toStringAsFixed(0) : v.toStringAsFixed(3),
    _ => '${v.toStringAsPrecision(4)} ${m.unit}',
  };
}

/// Plain-text SI report (PRD 11: configuration, PCB parameters, metrics,
/// violations, recommendations, assumptions and limitations).
String buildTextReport(String name, SimulationResult r) {
  final c = r.config;
  final b = StringBuffer();
  void h(String s) => b
    ..writeln()
    ..writeln(s)
    ..writeln('-' * s.length);
  b.writeln('SI STUDIO – QUICK SI ANALYSIS REPORT');
  b.writeln('Analysis: $name');
  b.writeln('Generated: ${DateTime.now().toIso8601String()}');
  b.writeln('Simulation model: $simulationModelVersion');
  b.writeln('Overall status: ${r.overallStatus.label.toUpperCase()}');
  b.writeln('NOTE: Preliminary engineering analysis (analytical + behavioural models). '
      'Not a protocol-compliance result.');

  h('Protocol configuration');
  if (c.protocol.spiFamily) {
    final p = c.spiCfg;
    b.writeln('${c.protocol.label}: ${c.protocolDetail}, mode ${p.mode}');
    if (c.protocol == Protocol.qspi) {
      b.writeln('x${p.ioWidth} IO, IO-to-CLK mismatch ${mm(p.dataClockMismatch)}, read capture delay '
          '${secs(p.readSampleDelay)}${p.dtr && p.useDqs ? ', DQS read capture' : ''}');
    }
    b.writeln('tr/tf ${secs(p.riseTime)} / ${secs(p.fallTime)}; target Z0 ${ohm(p.targetZ0)}');
    b.writeln('Driver ${ohm(p.driverImpedance)}; termination: ${p.termination.label}'
        '${p.termination.hasSeries ? ', Rs ${ohm(p.seriesR)}' : ''}'
        '${p.termination.hasParallel ? ', Rp ${ohm(p.parallelR)} to ${p.vtt} V' : ''}'
        '${p.termination.hasAc ? ', AC ${ohm(p.acR)} + ${eng(p.acC, 'F')}' : ''}');
    b.writeln('Receiver ${eng(p.receiverCap, 'F')} || ${ohm(p.receiverRin)}; '
        'tCO ${secs(p.slaveTco)}, tsu ${secs(p.setupTime)}, th ${secs(p.holdTime)}');
  } else if (c.protocol.serdes) {
    final p = c.serdes;
    final isPcie = c.protocol == Protocol.pcie;
    b.writeln('${c.protocol.label} ${c.protocolDetail} at ${eng(c.serdesRate, 'b/s')}; '
        'tr ${secs(p.riseTime)}; TX ${volts(p.txSwingPp)} p-p, ${ohm(p.txImpedance)}/leg');
    b.writeln(isPcie && p.gen.usesPresets ? 'TX preset P${p.preset}' : 'TX de-emphasis ${p.deEmphasisDb} dB');
    b.writeln('RX ${ohm(p.rxTermination)}/leg, ${eng(p.receiverCap, 'F')}; CTLE ${p.ctleEnabled ? (p.ctleAuto ? 'auto' : '${p.ctleDcGainDb} dB') : 'off'}; '
        'DFE ${p.dfeTaps} taps; RJ ${secs(p.rjRms)}');
    b.writeln('Target Zdiff ${ohm(p.targetZdiff)}; eye minimum ${volts(p.maskHeight)} / ${p.maskWidthUi} UI');
  } else if (c.protocol == Protocol.i2c) {
    final p = c.i2c;
    b.writeln('I²C ${p.mode.label} at ${eng(p.clockHz, 'Hz')}, VDD ${p.voltage} V');
    b.writeln('Pull-up ${ohm(p.pullupR)} at the ${p.pullupAtTarget ? 'far target' : 'controller'}; '
        '${p.deviceCount} devices × ${eng(p.pinCap, 'F')}, other ${eng(p.extraCap, 'F')}');
    b.writeln('Driver sink ${eng(p.sinkCurrent, 'A')} at 0.4 V, fall ramp ${secs(p.driverFallTime)}, '
        'SCL low ${(p.sclLowFraction * 100).toStringAsFixed(0)} %${p.seriesR > 0 ? ', series ${ohm(p.seriesR)}' : ''}');
  } else if (c.protocol == Protocol.rgmii) {
    final p = c.rgmii;
    b.writeln('RGMII ${p.speed.label}, VDD ${p.voltage} V, tr/tf ${secs(p.riseTime)} / ${secs(p.fallTime)}');
    b.writeln('Driver ${ohm(p.driverImpedance)} + series ${ohm(p.seriesR)}; receiver ${eng(p.receiverCap, 'F')}');
    b.writeln('Clock delay TX ${secs(p.txClockDelay)}, RX ${secs(p.rxClockDelay)}; clock trace '
        '${mm(p.clockExtraLength)} longer than data; TskewT ±${secs(p.txSkew)}, '
        'setup ${secs(p.setupTime)}, hold ${secs(p.holdTime)}');
  } else if (c.protocol == Protocol.ddr) {
    final p = c.ddr;
    b.writeln('${p.standard.label}-${p.rate}, VDDQ ${p.vddq} V, ${p.training == DdrTraining.perBit ? 'per-bit deskew' : 'per-byte training'}');
    b.writeln('Ron controller ${ohm(p.ctrlRon)} / DRAM ${ohm(p.dramRon)}; ODT write ${ohm(p.odtWrite)} / read ${ohm(p.odtRead)}; '
        'pin C ${eng(p.ioCap, 'F')}; edge ${secs(p.edge)}');
    b.writeln(p.standard.caTopology == CaTopology.flyBy
        ? 'CA fly-by: ${p.devices} devices, lead-in ${mm(p.leadIn)}, spacing ${mm(p.spacing)}, stub ${mm(p.stub)}, '
            '${eng(p.deviceCap, 'F')}/device, VTT ${ohm(p.vttR)}, CA − CK ${mm(p.caClkMismatch)}${p.twoT ? ', 2T' : ''}'
        : 'CA point to point: ${mm(p.leadIn)}, ${p.devices} die(s), CA ODT ${ohm(p.caOdt)}');
    b.writeln('Targets ${ohm(p.targetZ0)} single-ended / ${ohm(p.targetZdiff)} differential');
  } else {
    final p = c.usb2;
    b.writeln('USB 2.0 ${p.speed.label}; tr/tf ${secs(p.riseTime)} / ${secs(p.fallTime)}');
    b.writeln('Driver ${ohm(p.driverImpedance)} + series ${ohm(p.seriesR)} per leg; '
        'RX termination ${p.rxTermEnabled ? ohm(p.rxTermR) : 'off'}; Cin ${eng(p.receiverCap, 'F')}');
    b.writeln('Target Zdiff ${ohm(p.targetZdiff)}');
  }

  h('PCB parameters');
  final s = c.pcb.stackup;
  b.writeln('${s.layerCount}-layer stackup, Dk ${s.dk}, Df ${s.df}, roughness '
      '${(s.roughnessRms * 1e6).toStringAsFixed(2)} µm rms; routed on L${s.signalLayer + 1}');
  for (var i = 0; i < s.layers.length; i++) {
    b.writeln('  L${i + 1} ${s.layers[i].role.label.padRight(6)} Cu ${milStr(s.layers[i].copperThickness)}');
    if (i < s.dielectrics.length) b.writeln('     dielectric ${milStr(s.dielectrics[i])} (${mm(s.dielectrics[i])})');
  }
  b.writeln('Trace width ${milStr(c.pcb.traceWidth)} (${mm(c.pcb.traceWidth)}), length ${mm(c.pcb.traceLength)}');
  if (c.protocol.differential) {
    b.writeln('Pair spacing ${milStr(c.pcb.traceSpacing)}, D− mismatch ${mm(c.pcb.lengthMismatch)}');
  }
  b.writeln('Structure: ${r.impedance.structure}; ${r.impedance.method}');
  if (r.impedance.widthForTarget != null) {
    b.writeln('Width for ${ohm(r.impedance.target)}: ${milStr(r.impedance.widthForTarget!)}');
  }

  if (c.pcb.elements.isNotEmpty) {
    b.writeln('Channel elements:');
    for (final e in [...c.pcb.elements]..sort((a, b) => a.position.compareTo(b.position))) {
      b.writeln('  ${e.type.label} at ${mm(e.position)}');
    }
  }
  if (c.pcb.crosstalk.enabled) {
    b.writeln('Crosstalk: aggressor at ${mm(c.pcb.crosstalk.spacing)} over ${mm(c.pcb.crosstalk.coupledLength)}');
  }
  if (c.protocol.serdes && c.serdes.useTouchstone && c.serdes.sparams != null) {
    b.writeln('Channel: Touchstone ${c.serdes.sparams!.name}');
  }
  if (c.protocol.spiFamily && c.spiCfg.useIbis) {
    b.writeln('IBIS: driver ${c.spiCfg.ibisDriver?.name}, receiver ${c.spiCfg.ibisReceiver?.name} '
        '(${c.spiCfg.ibisDriver?.file}, ${c.spiCfg.ibisCorner.name})');
  }

  h('Simulation settings');
  b.writeln('${c.sim.numBits} bits, pattern ${c.sim.pattern.label}'
      '${c.sim.pattern == DataPattern.custom ? ' (${c.sim.customPattern})' : ''}, '
      '${c.sim.lossy ? 'lossy' : 'lossless'} line');
  b.writeln('Time step ${secs(r.dt)}, ${r.sampleCount} samples, duration ${secs(r.duration)}, '
      'computed in ${r.computeMillis} ms');

  h('Electrical metrics');
  for (final m in r.metrics) {
    b.writeln('[${m.level.short}] ${m.label.padRight(44)} ${formatMetric(m).padLeft(12)}  ${m.status.label}'
        '${m.note == null ? '' : '\n       ${m.note}'}');
  }

  h('Findings and recommendations');
  for (final f in r.findings) {
    b.writeln('* [${f.status.label}] ${f.title}');
    b.writeln('  Why: ${f.reason}');
    b.writeln('  Action: ${f.recommendation}');
  }

  if (r.checks.isNotEmpty) {
    h('Compliance-style checks (reference only)');
    for (final k in r.checks) {
      b.writeln('[${k.pass == null ? 'n/a ' : (k.pass! ? 'PASS' : 'FAIL')}] ${k.name}: ${k.measured} (req. ${k.requirement}; ${k.source})');
    }
  }

  h('Assumptions and limitations');
  for (final a in r.assumptions) {
    b.writeln('- $a');
  }
  b.writeln('- Not modelled: IBIS-AMI, V-T waveform tables, package RLC, full-wave via/connector fields.');
  return b.toString();
}
