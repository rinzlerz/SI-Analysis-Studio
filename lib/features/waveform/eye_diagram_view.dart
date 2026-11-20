import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../simulation/common/format.dart';
import '../../simulation/model/result.dart';
import 'waveform_viewer.dart' show niceStep, tickLabel;

/// Eye diagram folded from the simulated receiver waveform (2 UI window).
class EyeDiagramView extends StatelessWidget {
  const EyeDiagramView({super.key, required this.eye, this.height});

  final EyeResult eye;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      decoration: BoxDecoration(
        color: const Color(0xFF070A0E),
        border: Border.all(color: AppColors.outline),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: CustomPaint(painter: _EyePainter(eye), size: Size.infinite),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text(
        '${eye.traceLabel} · ${eye.segmentCount} UI overlaid · deterministic only (no RJ / crosstalk)',
        style: const TextStyle(color: AppColors.textDim, fontSize: 12),
      ),
      const SizedBox(height: 6),
      SizedBox(height: height ?? 300, child: box),
      const SizedBox(height: 8),
      if (eye.bathtubLog10Ber != null) ...[
        const Text('Bathtub (simulated DJ ⊗ user RJ), log10 BER vs sampling offset',
            style: TextStyle(color: AppColors.textDim, fontSize: 12)),
        const SizedBox(height: 4),
        Container(
          height: 130,
          decoration: BoxDecoration(
            color: const Color(0xFF070A0E),
            border: Border.all(color: AppColors.outline),
            borderRadius: BorderRadius.circular(8),
          ),
          child: CustomPaint(size: Size.infinite, painter: _BathtubPainter(eye)),
        ),
        const SizedBox(height: 8),
      ],
      Wrap(spacing: 14, runSpacing: 4, children: [
        if (eye.maskHits != null) _kv('Mask hits', '${eye.maskHits}'),
        if (eye.eyeWidthAtBer != null) _kv('Width @1e-12', secs(eye.eyeWidthAtBer!)),
        _kv('Eye height', volts(eye.eyeHeight)),
        _kv('Eye width', secs(eye.eyeWidth)),
        _kv('DJ pk-pk', secs(eye.jitterPkPk)),
        _kv('Crossing', pct(eye.crossingPct)),
        _kv('V margin', volts(eye.verticalMargin)),
        _kv('H margin', secs(eye.horizontalMargin)),
      ]),
    ]);
  }

  Widget _kv(String k, String v) => RichText(
        text: TextSpan(children: [
          TextSpan(text: '$k ', style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
          TextSpan(text: v, style: kNumStyle.copyWith(fontSize: 12, color: AppColors.text)),
        ]),
      );
}

class _EyePainter extends CustomPainter {
  _EyePainter(this.eye);
  final EyeResult eye;

  @override
  void paint(Canvas canvas, Size size) {
    const l = 52.0, r = 10.0, t = 10.0, b = 26.0;
    final plot = Rect.fromLTRB(l, t, size.width - r, size.height - b);
    if (plot.width < 10 || plot.height < 10) return;
    final pad = (eye.vMax - eye.vMin) * 0.08 + 1e-6;
    final y0 = eye.vMin - pad, y1 = eye.vMax + pad;
    double px(double u) => plot.left + (u + 1) / 2 * plot.width; // u in [-1, 1] UI
    double py(double v) => plot.bottom - (v - y0) / (y1 - y0) * plot.height;
    final grid = Paint()..color = AppColors.grid;
    const ts = TextStyle(color: AppColors.textDim, fontSize: 10);

    // Time axis in ps/ns relative to eye centre.
    final uiScale = eye.ui < 2e-9 ? 1e12 : 1e9;
    final unit = eye.ui < 2e-9 ? 'ps' : 'ns';
    final span = 2 * eye.ui * uiScale;
    final step = niceStep(span, 6);
    for (var v = -(span / 2 / step).floor() * step; v <= span / 2 + 1e-9; v += step) {
      final x = px(v / (eye.ui * uiScale));
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), grid);
      _text(canvas, tickLabel(v, step), Offset(x, plot.bottom + 3), ts, center: true);
    }
    _text(canvas, unit, Offset(plot.right - 12, plot.bottom + 13), ts);
    final mv = (y1 - y0) < 1.5;
    final vs = mv ? 1e3 : 1.0;
    final vStep = niceStep((y1 - y0) * vs, 6) / vs;
    for (var v = (y0 / vStep).ceil() * vStep; v <= y1; v += vStep) {
      final y = py(v);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      _text(canvas, tickLabel(v * vs, vStep * vs), Offset(plot.left - 4, y - 6), ts, right: true);
    }
    _text(canvas, mv ? 'mV' : 'V', const Offset(4, 10), ts);

    canvas.save();
    canvas.clipRect(plot);
    final n = eye.pointsPerSegment;
    final alpha = (40 / math.sqrt(eye.segmentCount.toDouble())).clamp(0.06, 0.6);
    final p = Paint()
      ..color = AppColors.traces[1].withValues(alpha: alpha)
      ..strokeWidth = 1.3
      ..style = PaintingStyle.stroke;
    for (var s = 0; s < eye.segmentCount; s++) {
      final path = Path();
      for (var i = 0; i < n; i++) {
        final x = px(-1 + 2 * i / (n - 1));
        final y = py(eye.segments[s * n + i]);
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, p);
    }
    // Mask (hexagon) overlay.
    if (eye.maskHeight != null && eye.maskWidth != null) {
      final w = eye.maskWidth! / eye.ui, h = eye.maskHeight!;
      final pts = eye.maskRect
          ? [
              Offset(px(-w / 2), py(h / 2)),
              Offset(px(w / 2), py(h / 2)),
              Offset(px(w / 2), py(-h / 2)),
              Offset(px(-w / 2), py(-h / 2)),
            ]
          : [
        Offset(px(-w / 2), py(0)),
        Offset(px(-w / 4), py(h / 2)),
        Offset(px(w / 4), py(h / 2)),
        Offset(px(w / 2), py(0)),
        Offset(px(w / 4), py(-h / 2)),
        Offset(px(-w / 4), py(-h / 2)),
      ];
      final path = Path()..addPolygon(pts, true);
      final bad = (eye.maskHits ?? 0) > 0;
      canvas.drawPath(path, Paint()..color = (bad ? AppColors.critical : AppColors.good).withValues(alpha: 0.18));
      canvas.drawPath(
          path,
          Paint()
            ..color = bad ? AppColors.critical : AppColors.good
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
    }
    // Eye opening markers at the centre.
    if (eye.eyeHeight > 0) {
      final mk = Paint()
        ..color = AppColors.traces[0]
        ..strokeWidth = 1.5;
      final xc = px(0);
      canvas.drawLine(Offset(xc, py(eye.eyeTop)), Offset(xc, py(eye.eyeBottom)), mk);
      canvas.drawLine(Offset(xc - 6, py(eye.eyeTop)), Offset(xc + 6, py(eye.eyeTop)), mk);
      canvas.drawLine(Offset(xc - 6, py(eye.eyeBottom)), Offset(xc + 6, py(eye.eyeBottom)), mk);
      final yc = py((eye.eyeTop + eye.eyeBottom) / 2);
      final hw = eye.eyeWidth / eye.ui / 2; // in UI
      canvas.drawLine(Offset(px(-hw), yc), Offset(px(hw), yc), mk);
      _text(canvas, 'H ${volts(eye.eyeHeight)}', Offset(xc + 8, py(eye.eyeTop) + 2),
          TextStyle(color: AppColors.traces[0], fontSize: 11));
      _text(canvas, 'W ${secs(eye.eyeWidth)}', Offset(px(hw) - 70, yc + 4),
          TextStyle(color: AppColors.traces[0], fontSize: 11));
    }
    canvas.restore();
    canvas.drawRect(
        plot,
        Paint()
          ..color = AppColors.gridMajor
          ..style = PaintingStyle.stroke);
  }

  void _text(Canvas c, String s, Offset at, TextStyle style, {bool center = false, bool right = false}) {
    final tp = TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr)..layout();
    var o = at;
    if (center) o = Offset(at.dx - tp.width / 2, at.dy);
    if (right) o = Offset(at.dx - tp.width, at.dy);
    tp.paint(c, o);
  }

  @override
  bool shouldRepaint(covariant _EyePainter old) => old.eye != eye;
}

class _BathtubPainter extends CustomPainter {
  _BathtubPainter(this.eye);
  final EyeResult eye;

  @override
  void paint(Canvas canvas, Size size) {
    const l = 40.0, r = 10.0, t = 8.0, b = 20.0;
    final plot = Rect.fromLTRB(l, t, size.width - r, size.height - b);
    final ph = eye.bathtubPhase!, lb = eye.bathtubLog10Ber!;
    const yMin = -16.0, yMax = 0.0;
    double px(double x) => plot.left + (x / eye.ui + 0.5) * plot.width;
    double py(double v) => plot.top + (yMax - v.clamp(yMin, yMax)) / (yMax - yMin) * plot.height;
    final grid = Paint()..color = AppColors.grid;
    const ts = TextStyle(color: AppColors.textDim, fontSize: 9);
    for (var v = -16; v <= 0; v += 4) {
      canvas.drawLine(Offset(plot.left, py(v.toDouble())), Offset(plot.right, py(v.toDouble())), grid);
      final tp = TextPainter(text: TextSpan(text: '1e$v', style: ts), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset(2, py(v.toDouble()) - 6));
    }
    final target = math.log(eye.targetBer ?? 1e-12) / math.ln10;
    canvas.drawLine(Offset(plot.left, py(target)), Offset(plot.right, py(target)),
        Paint()..color = AppColors.warning.withValues(alpha: 0.7));
    final path = Path()..moveTo(px(ph.first), py(lb.first));
    for (var i = 1; i < ph.length; i++) {
      path.lineTo(px(ph[i]), py(lb[i]));
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = AppColors.traces[0]
          ..strokeWidth = 1.6
          ..style = PaintingStyle.stroke);
    final lbl = TextPainter(
        text: TextSpan(text: '±UI/2 (${secs(eye.ui / 2)})', style: ts), textDirection: TextDirection.ltr)
      ..layout();
    lbl.paint(canvas, Offset(plot.right - lbl.width, plot.bottom + 4));
  }

  @override
  bool shouldRepaint(covariant _BathtubPainter old) => old.eye != eye;
}

/// Renders the eye diagram to a PNG for reports.
Future<Uint8List> renderEyePng(EyeResult eye, {int width = 1000, int height = 560}) async {
  final rec = ui.PictureRecorder();
  final size = Size(width.toDouble(), height.toDouble());
  final canvas = Canvas(rec, Offset.zero & size);
  canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF070A0E));
  _EyePainter(eye).paint(canvas, size);
  final img = await rec.endRecording().toImage(width, height);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}
