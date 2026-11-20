/// SI Studio simulation engine entry point (pure Dart, no Flutter imports).
///
/// The engine is deterministic: the same [AnalysisConfig] always produces the
/// same result, so saved analyses store only their configuration.
library;

import 'impedance/impedance.dart';
import 'model/config.dart';
import 'model/result.dart';
import 'protocols/ddr_sim.dart';
import 'protocols/i2c_sim.dart';
import 'protocols/rgmii_sim.dart';
import 'protocols/serdes_sim.dart';
import 'protocols/spi_sim.dart';
import 'protocols/usb2_sim.dart';
import 'validation.dart';
import 'waveform_engine/line_solver.dart';
import 'waveform_engine/link_context.dart';
import 'waveform_engine/stimulus.dart';

export 'model/config.dart';
export 'model/result.dart';
export 'validation.dart' show ValidationIssue, validateConfig;
export 'waveform_engine/link_context.dart' show SimulationError;

/// Runs a complete analysis. Throws [SimulationError] with a user-readable
/// message for invalid configurations.
SimulationResult runAnalysis(AnalysisConfig cfg) {
  final issues = validateConfig(cfg).where((i) => i.blocking).toList();
  if (issues.isNotEmpty) {
    throw SimulationError(issues.map((i) => '• ${i.field}: ${i.message}').join('\n'));
  }
  try {
    final result = switch (cfg.protocol) {
      Protocol.spi || Protocol.qspi => simulateSpi(cfg),
      Protocol.i2c => simulateI2c(cfg),
      Protocol.rgmii => simulateRgmii(cfg),
      Protocol.usb2 => simulateUsb2(cfg),
      Protocol.usb3 || Protocol.pcie || Protocol.hdmi => simulateSerdes(cfg),
      Protocol.ddr => simulateDdr(cfg),
    };
    final warnings = validateConfig(cfg).where((i) => !i.blocking);
    if (warnings.isNotEmpty) {
      result.assumptions.insertAll(0, warnings.map((w) => 'Input warning – ${w.field}: ${w.message}'));
    }
    return result;
  } on SolverError catch (e) {
    throw SimulationError(e.message);
  } on PatternError catch (e) {
    throw SimulationError(e.message);
  }
}

/// Isolate-friendly entry point (argument and result are sendable).
SimulationResult runAnalysisFromJson(Map<String, Object?> json) =>
    runAnalysis(AnalysisConfig.fromJson(json));

/// Sets the trace width that meets the protocol impedance target on the
/// configured stackup (rounded to 0.01 mm). Returns false if unreachable.
bool applyTargetWidth(AnalysisConfig cfg) {
  try {
    final g = geometryFromStackup(cfg.pcb.stackup);
    final diff = cfg.protocol.differential;
    final target = cfg.targetImpedance;
    final w = solveWidthForTarget(g, target,
        spacing: diff ? cfg.pcb.traceSpacing : null, diffModel: cfg.pcb.diffModel);
    if (w == null) return false;
    cfg.pcb.traceWidth = (w * 1e5).round() / 1e5;
    return true;
  } on StackupError {
    return false;
  }
}
