import 'package:flutter/material.dart';

import '../../core/state/app_controller.dart';
import '../../simulation/engine.dart';
import '../analysis_results/results_screen.dart';

/// One-tap example analyses for first-time users and testers.
class ExampleAnalysis {
  const ExampleAnalysis(this.title, this.description, this.icon, this.protocol, this.setup);
  final String title;
  final String description;
  final IconData icon;
  final Protocol protocol;
  final void Function(AnalysisConfig c) setup;
}

final List<ExampleAnalysis> exampleAnalyses = [
  ExampleAnalysis(
    'Unterminated SPI clock',
    'SPI flash at 50 MHz over 200 mm with no series resistor: ringing and timing',
    Icons.show_chart,
    Protocol.spi,
    (c) {
      c.spi.clockHz = 50e6;
      c.spi.termination = TerminationScheme.none;
      c.spi.riseTime = 0.7e-9;
      c.spi.fallTime = 0.7e-9;
      c.pcb.traceLength = 200e-3;
    },
  ),
  ExampleAnalysis(
    'Overloaded I²C bus',
    '12 devices, a cable and 10 kΩ pull-ups at 400 kHz: slow edges, pull-up advice',
    Icons.cable,
    Protocol.i2c,
    (c) {
      c.i2c.deviceCount = 12;
      c.i2c.extraCap = 150e-12;
      c.i2c.pullupR = 10e3;
    },
  ),
  ExampleAnalysis(
    'RGMII without clock delay',
    'Gigabit Ethernet with the TX internal delay switched off',
    Icons.lan_outlined,
    Protocol.rgmii,
    (c) => c.rgmii.txClockDelay = 0,
  ),
  ExampleAnalysis(
    'QSPI flash read at 104 MHz',
    'Read data returns too late for the controller: recommended sample delay',
    Icons.memory,
    Protocol.qspi,
    (c) {},
  ),
  ExampleAnalysis(
    'PCIe Gen 4 over 450 mm',
    'Long standard FR-4 route (Df 0.02) at 16 GT/s: loss, equalisation and the eye',
    Icons.speed,
    Protocol.pcie,
    (c) {
      c.pcie.gen = PcieGen.gen4;
      c.pcie.applyGenDefaults();
      c.applySerdesLossLimits();
      c.pcb.traceLength = 450e-3;
      c.pcb.stackup.df = 0.02;
    },
  ),
];

/// Loads [e] into the editor, runs it and opens the results.
Future<void> runExample(BuildContext context, AppController c, ExampleAnalysis e) async {
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  c.newDraft(e.protocol);
  final cfg = c.draft;
  e.setup(cfg);
  if (cfg.protocol.differential) applyTargetWidth(cfg);
  c.setDraft(cfg, name: 'Example · ${e.title}');
  try {
    final r = await c.runDraft();
    await nav.push(MaterialPageRoute<void>(
      builder: (_) => ResultsScreen(controller: c, result: r.result, record: r.record),
    ));
  } catch (err) {
    messenger.showSnackBar(SnackBar(content: Text('Example failed: $err')));
  }
}
