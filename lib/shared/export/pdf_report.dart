import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../features/analysis_results/report.dart';
import '../../features/waveform/eye_diagram_view.dart';
import '../../features/waveform/waveform_viewer.dart';
import '../../simulation/common/format.dart';
import '../../simulation/engine.dart';

/// The built-in PDF fonts cover ASCII only; map engineering symbols.
String pdfSafe(String s) {
  const map = {
    'Ω': 'ohm',
    'µ': 'u',
    'μ': 'u',
    'Γ': 'G',
    'ε': 'e',
    '≤': '<=',
    '≥': '>=',
    '≈': '~',
    '±': '+/-',
    '×': 'x',
    '−': '-',
    '–': '-',
    '—': '-',
    '·': '-',
    '→': '->',
    '⊗': '(x)',
    '₀': '0',
    '…': '...',
    '’': "'",
    '“': '"',
    '”': '"',
    '⚠': '!',
    '√': 'sqrt',
    'τ': 'tau',
    'π': 'pi',
    'α': 'alpha',
    'δ': 'delta',
    'Δ': 'd',
  };
  final b = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    if (map.containsKey(ch)) {
      b.write(map[ch]);
    } else if (r < 128) {
      b.write(ch);
    } else {
      b.write('?');
    }
  }
  return b.toString();
}

/// Builds the SI analysis report PDF (PRD 11): project information,
/// protocol / PCB configuration, waveform and eye images, metrics,
/// violations, recommendations, compliance-style checks, assumptions.
Future<Uint8List> buildPdfReport(String name, SimulationResult r) async {
  final views = r.views.entries.toList();
  final waveImg = views.isEmpty
      ? null
      : await renderWaveformPng(
          dt: r.dt,
          traces: [for (final id in views.first.value) if (r.trace(id) != null) r.trace(id)!],
        );
  final eyeImg = r.eye == null ? null : await renderEyePng(r.eye!);
  final text = buildTextReport(name, r);
  final cfgSection = text.split('\n');

  // pdf's TextStyle cannot be const-evaluated (asserts in its initializer).
  // ignore: prefer_const_constructors
  final small = pw.TextStyle(fontSize: 8.5);
  // ignore: prefer_const_constructors
  final bold = pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold);
  final doc = pw.Document(title: pdfSafe('SI Studio - $name'), author: 'SI Studio');
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(32),
    build: (context) => <pw.Widget>[
      pw.Header(level: 0, text: pdfSafe('SI Studio - Quick SI Analysis Report')),
      pw.Paragraph(
        text: pdfSafe('Analysis: $name\nOverall status: ${r.overallStatus.label}\n'
            'Simulation model $simulationModelVersion (L1 analytical / L2 behavioural / L3 advanced). '
            'Preliminary engineering analysis - not a protocol-compliance certification.'),
        style: small,
      ),
      pw.Header(level: 1, text: 'Configuration'),
      ..._configLines(cfgSection).map((l) => pw.Text(pdfSafe(l), style: small)),
      if (waveImg != null) ...[
        pw.Header(level: 1, text: pdfSafe('Waveforms - ${views.first.key}')),
        pw.Image(pw.MemoryImage(waveImg), height: 230),
      ],
      if (eyeImg != null) ...[
        pw.Header(level: 1, text: pdfSafe('Eye diagram - ${r.eye!.traceLabel}')),
        pw.Image(pw.MemoryImage(eyeImg), height: 240),
      ],
      pw.Header(level: 1, text: 'Electrical metrics'),
      pw.TableHelper.fromTextArray(
        headers: ['Level', 'Metric', 'Value', 'Status'],
        data: [
          for (final m in r.metrics) [m.level.short, pdfSafe(m.label), pdfSafe(formatMetric(m)), m.status.label],
        ],
        cellStyle: small,
        headerStyle: bold,
      ),
      pw.Header(level: 1, text: 'Findings and recommendations'),
      for (final f in r.findings) ...[
        pw.Text(pdfSafe('[${f.status.label}] ${f.title}'), style: bold),
        pw.Paragraph(text: pdfSafe('Why: ${f.reason}\nAction: ${f.recommendation}'), style: small),
      ],
      if (r.checks.isNotEmpty) ...[
        pw.Header(level: 1, text: 'Compliance-style checks (reference only)'),
        pw.TableHelper.fromTextArray(
          headers: ['Check', 'Requirement', 'Measured', 'Result', 'Source'],
          data: [
            for (final k in r.checks)
              [
                pdfSafe(k.name),
                pdfSafe(k.requirement),
                pdfSafe(k.measured),
                k.pass == null ? 'n/a' : (k.pass! ? 'PASS' : 'FAIL'),
                k.source,
              ],
          ],
          cellStyle: small,
          headerStyle: bold,
        ),
      ],
      pw.Header(level: 1, text: 'Assumptions and limitations'),
      for (final a in r.assumptions) pw.Bullet(text: pdfSafe(a), style: small),
      pw.SizedBox(height: 8),
      pw.Text(
          pdfSafe('Generated ${DateTime.now().toIso8601String()} - time step ${secs(r.dt)}, ${r.sampleCount} samples.'),
          // ignore: prefer_const_constructors
          style: pw.TextStyle(fontSize: 7.5, color: PdfColors.grey700)),
    ],
  ));
  return doc.save();
}

/// Protocol / PCB / simulation sections of the text report.
List<String> _configLines(List<String> lines) {
  final out = <String>[];
  var on = false;
  for (final l in lines) {
    if (l == 'Protocol configuration') on = true;
    if (l == 'Electrical metrics') break;
    if (on && !RegExp(r'^-+$').hasMatch(l)) out.add(l);
  }
  return out;
}
