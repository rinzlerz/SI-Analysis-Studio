/// Simulation results: waveforms, metrics, findings.
library;

import 'dart:typed_data';

import 'config.dart';

enum SiStatus { good, warning, critical, info }

extension SiStatusInfo on SiStatus {
  String get label => switch (this) {
        SiStatus.good => 'Good',
        SiStatus.warning => 'Warning',
        SiStatus.critical => 'Critical',
        SiStatus.info => 'Info',
      };
  int get rank => switch (this) {
        SiStatus.info => 0,
        SiStatus.good => 1,
        SiStatus.warning => 2,
        SiStatus.critical => 3,
      };
}

SiStatus worst(Iterable<SiStatus> s) =>
    s.fold(SiStatus.good, (a, b) => b.rank > a.rank ? b : a);

/// PRD section 14 modelling levels.
enum ModelLevel { analytical, behavioral, advanced }

extension ModelLevelInfo on ModelLevel {
  String get label => switch (this) {
        ModelLevel.analytical => 'L1 Analytical',
        ModelLevel.behavioral => 'L2 Behavioural',
        ModelLevel.advanced => 'L3 Advanced',
      };
  String get short => switch (this) {
        ModelLevel.analytical => 'L1',
        ModelLevel.behavioral => 'L2',
        ModelLevel.advanced => 'L3',
      };
}

enum TraceKind { ideal, tx, rx, incident, reflected, commonMode, other }

class WaveformTrace {
  WaveformTrace({
    required this.id,
    required this.label,
    required this.group,
    required this.kind,
    required this.values,
    this.visibleByDefault = true,
  });

  final String id;
  final String label;

  /// Groups traces into selectable views (e.g. "SCLK", "Differential").
  final String group;
  final TraceKind kind;

  /// Samples on the shared time base (single precision to save memory).
  final Float32List values;
  final bool visibleByDefault;
}

class Metric {
  Metric({
    required this.id,
    required this.label,
    required this.value,
    required this.unit,
    required this.status,
    required this.level,
    this.target,
    this.note,
  });

  final String id;
  final String label;

  /// Value in base SI units (or dimensionless / dB / % as [unit] says).
  final double value;

  /// Unit hint: 'ohm', 's', 'V', '%', 'dB', 'm', '' (ratio).
  final String unit;
  final SiStatus status;
  final ModelLevel level;
  final double? target;
  final String? note;

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'value': value.isFinite ? value : value.toString(),
        'unit': unit,
        'status': status.name,
        'level': level.name,
        'target': target,
        'note': note,
      };

  factory Metric.fromJson(Map<String, Object?> j) {
    final v = j['value'];
    return Metric(
      id: '${j['id']}',
      label: '${j['label']}',
      value: v is num ? v.toDouble() : (double.tryParse('$v') ?? double.nan),
      unit: '${j['unit'] ?? ''}',
      status: SiStatus.values.firstWhere((s) => s.name == j['status'], orElse: () => SiStatus.info),
      level: ModelLevel.values.firstWhere((s) => s.name == j['level'],
          orElse: () => ModelLevel.analytical),
      target: (j['target'] as num?)?.toDouble(),
      note: j['note'] as String?,
    );
  }
}

class Finding {
  Finding({
    required this.status,
    required this.title,
    required this.reason,
    required this.recommendation,
  });

  final SiStatus status;
  final String title;

  /// Electrical explanation of the finding.
  final String reason;

  /// Suggested corrective action.
  final String recommendation;

  Map<String, Object?> toJson() => {
        'status': status.name,
        'title': title,
        'reason': reason,
        'recommendation': recommendation,
      };

  factory Finding.fromJson(Map<String, Object?> j) => Finding(
        status: SiStatus.values.firstWhere((s) => s.name == j['status'], orElse: () => SiStatus.info),
        title: '${j['title']}',
        reason: '${j['reason']}',
        recommendation: '${j['recommendation']}',
      );
}

/// Folded eye data and deterministic eye metrics.
class EyeResult {
  EyeResult({
    required this.ui,
    required this.segments,
    required this.pointsPerSegment,
    required this.eyeHeight,
    required this.eyeWidth,
    required this.crossingPct,
    required this.jitterPkPk,
    required this.idealEyeHeight,
    required this.vMin,
    required this.vMax,
    required this.traceLabel,
    required this.eyeTop,
    required this.eyeBottom,
    this.phaseDelay = 0,
    Float64List? crossingOffsets,
  }) : crossingOffsets = crossingOffsets ?? Float64List(0);

  /// Threshold-crossing times relative to the mean crossing (s), used for
  /// the bathtub analysis.
  final Float64List crossingOffsets;

  // Level 3 advanced eye analysis (filled by analyseEye).
  double? maskHeight;
  double? maskWidth;
  int? maskHits;
  int? maskSamples;

  /// Bathtub: sampling offset from the eye centre (s) and log10(BER).
  Float64List? bathtubPhase;
  Float64List? bathtubLog10Ber;
  double? eyeWidthAtBer;
  double? targetBer;

  /// Delay from the transmitted bit grid to the eye-centre phase (s).
  final double phaseDelay;

  /// Lowest '1' and highest '0' sample at the eye centre (V).
  final double eyeTop;
  final double eyeBottom;

  /// Unit interval (s).
  final double ui;

  /// Concatenated segments, each spanning 2 UI centred on the eye centre.
  final Float64List segments;
  final int pointsPerSegment;
  int get segmentCount => segments.length ~/ pointsPerSegment;
  final double eyeHeight;
  final double eyeWidth;
  final double crossingPct;
  final double jitterPkPk;
  final double idealEyeHeight;
  final double vMin;
  final double vMax;
  final String traceLabel;

  double get verticalMargin => eyeHeight / 2;
  double get horizontalMargin => eyeWidth / 2;
}

class ImpedanceSummary {
  ImpedanceSummary({
    required this.structure,
    required this.z0,
    required this.zDiff,
    required this.eeff,
    required this.target,
    required this.targetIsDiff,
    required this.method,
    required this.widthForTarget,
  });

  final String structure;
  final double z0;
  final double? zDiff;
  final double eeff;
  final double target;
  final bool targetIsDiff;
  final String method;
  final double? widthForTarget;

  double get relevant => targetIsDiff ? zDiff! : z0;
  double get deviationPct => (relevant - target) / target * 100;
}

/// Data for the signal-propagation animation: the forward (incident) and
/// backward (reflected) waves at the driver allow v(x, t) to be rebuilt
/// along a lossless line: v(x,t) = a(t - x/v) + b(t + x/v).
class AnimationSource {
  AnimationSource({
    required this.label,
    required this.incidentId,
    required this.reflectedId,
    required this.txId,
    required this.rxId,
    required this.delay,
    required this.startTime,
  });

  final String label;
  final String incidentId;
  final String reflectedId;
  final String txId;
  final String rxId;

  /// One-way line delay (s).
  final double delay;

  /// Suggested start time (just before the first edge) (s).
  final double startTime;
}

/// One compliance-style check (PRD Phase 3). These are reference checks
/// against spec-derived or configured limits, not certification.
class ComplianceCheck {
  ComplianceCheck({
    required this.name,
    required this.requirement,
    required this.measured,
    required this.pass,
    required this.source,
  });

  final String name;
  final String requirement;
  final String measured;

  /// null = not applicable / not evaluated.
  final bool? pass;

  /// "spec reference" or "configured limit".
  final String source;

  Map<String, Object?> toJson() =>
      {'name': name, 'requirement': requirement, 'measured': measured, 'pass': pass, 'source': source};
}

class SimulationResult {
  SimulationResult({
    required this.config,
    required this.dt,
    required this.sampleCount,
    required this.traces,
    required this.views,
    required this.metrics,
    required this.findings,
    required this.assumptions,
    required this.impedance,
    required this.eyes,
    required this.computeMillis,
    this.animation,
    List<ComplianceCheck>? checks,
  }) : checks = checks ?? [];

  final List<ComplianceCheck> checks;

  final AnalysisConfig config;
  final double dt;
  final int sampleCount;
  final List<WaveformTrace> traces;

  /// Named waveform views: view name -> trace ids.
  final Map<String, List<String>> views;
  final List<Metric> metrics;
  final List<Finding> findings;
  final List<String> assumptions;
  final ImpedanceSummary impedance;
  /// Eye diagrams (e.g. raw receiver and post-equalisation).
  final List<EyeResult> eyes;
  EyeResult? get eye => eyes.isEmpty ? null : eyes.first;
  final AnimationSource? animation;
  final int computeMillis;

  double get duration => dt * (sampleCount - 1);

  SiStatus get overallStatus => worst([
        ...metrics.where((m) => m.status != SiStatus.info).map((m) => m.status),
        ...findings.map((f) => f.status == SiStatus.info ? SiStatus.good : f.status),
      ]);

  WaveformTrace? trace(String id) {
    for (final t in traces) {
      if (t.id == id) return t;
    }
    return null;
  }
}
