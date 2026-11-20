import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/app_info.dart';
import '../../shared/export/pdf_text.dart';
import '../../simulation/common/format.dart';
import '../../simulation/engine.dart';
import '../../simulation/guidelines/figures.dart';
import '../../simulation/guidelines/guidelines.dart';

/// One-to-two page PDF of the layout guidelines, for design reviews and the
/// layout engineer's desk.
Future<Uint8List> buildGuidelinesPdf(LayoutGuidelines g) async {
  // ignore: prefer_const_constructors
  final small = pw.TextStyle(fontSize: 8.5);
  // ignore: prefer_const_constructors
  final dim = pw.TextStyle(fontSize: 7.5, color: PdfColors.grey700);
  // ignore: prefer_const_constructors
  final bold = pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold);
  final c = g.config;
  final st = c.pcb.stackup;
  // Height from the figure's aspect ratio at ~480 pt wide, capped.
  pw.Widget fig(Figure f, double maxHeight) => pw.Container(
        height: (480 * f.height / f.width).clamp(40.0, maxHeight),
        margin: const pw.EdgeInsets.symmetric(vertical: 4),
        child: pw.SvgImage(svg: figureToSvg(f, background: 0xFFFFFFFF, textMap: pdfSafe)),
      );
  final figs = g.figures;
  final doc = pw.Document(title: pdfSafe('SI Studio - ${g.title}'), author: appName);
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(32),
    footer: (ctx) => pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Text(pdfSafe('$appName $appVersion - preliminary guidance; the chip vendor\'s layout guide takes priority - page ${ctx.pageNumber}/${ctx.pagesCount}'),
          style: dim),
    ),
    build: (ctx) => <pw.Widget>[
      pw.Header(level: 0, text: pdfSafe(g.title)),
      pw.Text(pdfSafe(g.summary), style: bold),
      pw.SizedBox(height: 6),
      pw.Text(
          pdfSafe('Settings: ${c.protocol.label} ${c.protocolDetail}. Stackup: ${st.layerCount} layers, '
              '${(st.totalThickness * 1e3).toStringAsFixed(2)} mm, Dk ${st.dk}, Df ${st.df}. '
              'Target ${ohm(c.targetImpedance)}${c.protocol.differential ? ' differential, gap ${guideLength(c.pcb.traceSpacing)}' : ''}.'),
          style: small),
      if (figs != null) ...[
        if (lengthGaugeFigure(figs, FigPalette.light) case final gauge?) fig(gauge, 55),
        pw.Header(level: 1, text: 'Diagrams'),
        fig(crossSectionFigure(figs, FigPalette.light), 170),
        fig(topViewFigure(figs, FigPalette.light), 420),
        if (flyByFigure(figs, FigPalette.light) case final fb?) fig(fb, 230),
        if (viaStubFigure(figs, FigPalette.light) case final via?) fig(via, 200),
      ],
      pw.Header(level: 1, text: 'Trace width per routing layer'),
      pw.TableHelper.fromTextArray(
        headers: ['Layer', 'Structure', 'Width', 'Width window (+/-10 %)', 'Delay'],
        data: [
          for (final l in g.layers)
            [
              pdfSafe('${l.name}${l.primary ? ' (routing)' : ''}'),
              l.structure,
              l.width == null ? pdfSafe(l.error ?? 'not achievable') : pdfSafe(guideLength(l.width!)),
              l.widthMin == null || l.widthMax == null
                  ? '-'
                  : pdfSafe('${(l.widthMin! * 1e3).toStringAsFixed(3)} - ${(l.widthMax! * 1e3).toStringAsFixed(3)} mm'),
              l.tpd == null ? '-' : '${(l.tpd! * 1e9).toStringAsFixed(2)} ps/mm',
            ],
        ],
        cellStyle: small,
        headerStyle: bold,
      ),
      for (final s in g.sections) ...[
        pw.Header(level: 1, text: pdfSafe(s.title)),
        pw.TableHelper.fromTextArray(
          headers: ['Item', 'Limit', 'Basis'],
          columnWidths: {0: const pw.FlexColumnWidth(2), 1: const pw.FlexColumnWidth(3), 2: const pw.FlexColumnWidth(4)},
          data: [
            for (final i in s.items) [pdfSafe('${i.important ? '* ' : ''}${i.label}'), pdfSafe(i.value), pdfSafe(i.basis)],
          ],
          cellStyle: small,
          headerStyle: bold,
        ),
      ],
      pw.SizedBox(height: 6),
      pw.Text('* = most important limits for this interface.', style: dim),
      pw.Header(level: 1, text: 'Assumptions'),
      for (final a in g.assumptions) pw.Bullet(text: pdfSafe(a), style: small),
    ],
  ));
  return doc.save();
}
