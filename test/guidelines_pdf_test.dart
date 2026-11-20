// Builds real guideline PDFs with the pdf package (runs in CI on Flutter).
import 'package:flutter_test/flutter_test.dart';
import 'package:si_studio/features/guidelines/guidelines_pdf.dart';
import 'package:si_studio/simulation/engine.dart';
import 'package:si_studio/simulation/guidelines/guidelines.dart';

void main() {
  test('layout guideline PDF builds for every protocol', () async {
    for (final p in Protocol.values) {
      final bytes = await buildGuidelinesPdf(computeGuidelines(AnalysisConfig.defaults(protocol: p)));
      expect(bytes.length, greaterThan(2000), reason: p.name);
      // PDF signature.
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-', reason: p.name);
    }
  });
}
