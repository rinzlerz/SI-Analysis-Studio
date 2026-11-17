import 'dart:convert';

import '../../simulation/model/config.dart';
import '../../simulation/model/result.dart';

/// A saved analysis. The waveforms are not stored: the engine is
/// deterministic, so they are regenerated from [config] (PRD 10).
class AnalysisRecord {
  AnalysisRecord({
    this.id,
    required this.name,
    required this.protocol,
    required this.created,
    required this.updated,
    required this.status,
    required this.config,
    required this.metrics,
    required this.findings,
    required this.modelVersion,
  });

  int? id;
  String name;
  Protocol protocol;
  DateTime created;
  DateTime updated;
  SiStatus status;
  AnalysisConfig config;
  List<Metric> metrics;
  List<Finding> findings;
  String modelVersion;

  factory AnalysisRecord.fromResult(String name, SimulationResult r) {
    final now = DateTime.now();
    return AnalysisRecord(
      name: name,
      protocol: r.config.protocol,
      created: now,
      updated: now,
      status: r.overallStatus,
      config: r.config.copy(),
      metrics: r.metrics,
      findings: r.findings,
      modelVersion: simulationModelVersion,
    );
  }

  Map<String, Object?> toRow() => {
        if (id != null) 'id': id,
        'name': name,
        'protocol': protocol.name,
        'created': created.millisecondsSinceEpoch,
        'updated': updated.millisecondsSinceEpoch,
        'status': status.name,
        'config': jsonEncode(config.toJson()),
        'summary': jsonEncode({
          'metrics': metrics.map((m) => m.toJson()).toList(),
          'findings': findings.map((f) => f.toJson()).toList(),
        }),
        'model_version': modelVersion,
      };

  factory AnalysisRecord.fromRow(Map<String, Object?> row) {
    final summary = jsonDecode('${row['summary'] ?? '{}'}') as Map<String, dynamic>;
    return AnalysisRecord(
      id: row['id'] as int?,
      name: '${row['name']}',
      protocol: Protocol.values.firstWhere((p) => p.name == row['protocol'], orElse: () => Protocol.spi),
      created: DateTime.fromMillisecondsSinceEpoch((row['created'] as num?)?.toInt() ?? 0),
      updated: DateTime.fromMillisecondsSinceEpoch((row['updated'] as num?)?.toInt() ?? 0),
      status: SiStatus.values.firstWhere((s) => s.name == row['status'], orElse: () => SiStatus.info),
      config: AnalysisConfig.fromJson((jsonDecode('${row['config']}') as Map).cast<String, Object?>()),
      metrics: ((summary['metrics'] as List?) ?? const [])
          .map((e) => Metric.fromJson((e as Map).cast<String, Object?>()))
          .toList(),
      findings: ((summary['findings'] as List?) ?? const [])
          .map((e) => Finding.fromJson((e as Map).cast<String, Object?>()))
          .toList(),
      modelVersion: '${row['model_version'] ?? simulationModelVersion}',
    );
  }

  /// Full export (configuration + results) for the JSON export.
  Map<String, Object?> toExportJson() => {
        'app': 'SI Studio',
        'name': name,
        'protocol': protocol.label,
        'created': created.toIso8601String(),
        'status': status.name,
        'simulationModelVersion': modelVersion,
        'config': config.toJson(),
        'metrics': metrics.map((m) => m.toJson()).toList(),
        'findings': findings.map((f) => f.toJson()).toList(),
      };
}
