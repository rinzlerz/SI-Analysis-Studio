import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../data/models/analysis_record.dart';
import '../../platform/file_saver.dart' as saver;
import '../../simulation/model/result.dart';

/// Exports through Android's share sheet (save to Files, Drive, e-mail ...)
/// or as browser downloads on the web, PRD 11.
class ExportService {
  static const int maxCsvRows = 200000;

  /// True on the web: exports go to the Downloads folder.
  static const bool downloads = saver.exportsDownload;

  static String _safe(String name) =>
      name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_').replaceAll(RegExp(r'_+'), '_');

  static Future<void> _saveText(String fileName, String content, String mime, String subject) =>
      saver.saveFiles({fileName: (Uint8List.fromList(utf8.encode(content)), mime)}, subject);

  /// Builds CSV text for [traces] between [t0] and [t1] (seconds).
  static String buildCsv(double dt, List<WaveformTrace> traces, double t0, double t1) {
    final n = traces.isEmpty ? 0 : traces.map((t) => t.values.length).reduce(math.min);
    final i0 = math.max(0, (t0 / dt).floor());
    final i1 = math.min(n - 1, (t1 / dt).ceil());
    final count = math.max(0, i1 - i0 + 1);
    final step = math.max(1, (count / maxCsvRows).ceil());
    final b = StringBuffer();
    b.writeln('# SI Studio waveform export; time step ${dt * step} s${step > 1 ? ' (decimated x$step)' : ''}');
    b.writeln(['time_s', ...traces.map((t) => '"${t.label} (V)"')].join(','));
    for (var i = i0; i <= i1; i += step) {
      b.write((i * dt).toStringAsExponential(9));
      for (final t in traces) {
        b.write(',');
        b.write(t.values[i].toStringAsFixed(6));
      }
      b.writeln();
    }
    return b.toString();
  }

  static Future<void> shareCsv({
    required String name,
    required double dt,
    required List<WaveformTrace> traces,
    required double t0,
    required double t1,
  }) =>
      _saveText('${_safe(name)}_waveforms.csv', buildCsv(dt, traces, t0, t1), 'text/csv', 'SI Studio waveforms – $name');

  static Future<void> shareJson(AnalysisRecord record) => _saveText(
      '${_safe(record.name)}.json',
      const JsonEncoder.withIndent('  ').convert(record.toExportJson()),
      'application/json',
      'SI Studio analysis – ${record.name}');

  static Future<void> shareText(String fileName, String text, String mime) => _saveText(_safe(fileName), text, mime, fileName);

  /// Shares several text files at once (name -> (content, mime)).
  static Future<void> shareTexts(Map<String, (String, String)> files, String subject) => saver.saveFiles(
      {for (final e in files.entries) _safe(e.key): (Uint8List.fromList(utf8.encode(e.value.$1)), e.value.$2)}, subject);

  static Future<void> sharePdf(String name, Uint8List bytes) =>
      saver.saveFiles({'${_safe(name)}_report.pdf': (bytes, 'application/pdf')}, 'SI Studio report – $name');

  /// Plain-text engineering report (configuration, metrics, findings,
  /// assumptions).
  static Future<void> shareReport(AnalysisRecord record, SimulationResult r, String reportText) =>
      _saveText('${_safe(record.name)}_report.txt', reportText, 'text/plain', 'SI Studio report – ${record.name}');
}
