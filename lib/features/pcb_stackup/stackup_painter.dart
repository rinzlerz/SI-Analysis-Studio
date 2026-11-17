import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utilities/units.dart';
import '../../simulation/impedance/impedance.dart';
import '../../simulation/model/config.dart';

/// Cross-section drawing of the stackup with the routed trace(s) and the
/// reference plane(s) highlighted. Layer heights are proportional with a
/// minimum so thin copper stays visible.
class StackupView extends StatelessWidget {
  const StackupView({
    super.key,
    required this.stackup,
    required this.unit,
    this.traceWidth,
    this.traceSpacing,
    this.differential = false,
    this.height = 220,
  });

  final StackupConfig stackup;
  final UnitSpec unit;
  final double? traceWidth;
  final double? traceSpacing;
  final bool differential;
  final double height;

  @override
  Widget build(BuildContext context) {
    TraceGeometry? geom;
    try {
      geom = geometryFromStackup(stackup);
    } catch (_) {
      geom = null;
    }
    return SizedBox(
      height: height,
      child: CustomPaint(
        size: Size.infinite,
        painter: _StackupPainter(
          stackup: stackup,
          unit: unit,
          geom: geom,
          traceWidth: traceWidth,
          traceSpacing: traceSpacing,
          differential: differential,
        ),
      ),
    );
  }
}

class _StackupPainter extends CustomPainter {
  _StackupPainter({
    required this.stackup,
    required this.unit,
    required this.geom,
    required this.traceWidth,
    required this.traceSpacing,
    required this.differential,
  });

  final StackupConfig stackup;
  final UnitSpec unit;
  final TraceGeometry? geom;
  final double? traceWidth;
  final double? traceSpacing;
  final bool differential;

  @override
  void paint(Canvas canvas, Size size) {
    final s = stackup;
    const left = 34.0;
    const labelW = 150.0;
    final boardW = math.max(80.0, size.width - left - labelW - 8);
    // Height allocation.
    const minCu = 5.0;
    const minDiel = 12.0;
    final total = s.totalThickness;
    final avail = size.height - 4;
    final fixed = s.layers.length * minCu + s.dielectrics.length * minDiel;
    final scale = math.max(0.0, avail - fixed) / total;
    var y = 2.0;
    const label = TextStyle(color: AppColors.textDim, fontSize: 10.5);
    const strong = TextStyle(color: AppColors.text, fontSize: 10.5, fontWeight: FontWeight.w600);
    String th(double m) => '${formatInput(unit.toDisplay(m), maxDecimals: 2)} ${unit.label}';
    final refs = {geom?.referenceAbove, geom?.referenceBelow}..remove(null);

    for (var i = 0; i < s.layers.length; i++) {
      final layer = s.layers[i];
      final hCu = minCu + layer.copperThickness * scale;
      final isSig = i == s.signalLayer;
      final color = switch (layer.role) {
        LayerRole.signal => AppColors.copper.withValues(alpha: isSig ? 1 : 0.45),
        LayerRole.ground => AppColors.ground,
        LayerRole.power => AppColors.power,
      };
      final rect = Rect.fromLTWH(left, y, boardW, hCu);
      if (layer.role == LayerRole.signal) {
        // Signal layers: draw short trace stubs, plus the routed trace(s).
        final p = Paint()..color = color;
        if (isSig && traceWidth != null) {
          final wPx = math.max(6.0, math.min(boardW * 0.25, traceWidth! * scale * 0.6 + 10));
          final cx = left + boardW / 2;
          if (differential) {
            final sPx = math.max(4.0, math.min(boardW * 0.2, (traceSpacing ?? traceWidth!) * scale * 0.6 + 6));
            canvas.drawRect(Rect.fromLTWH(cx - sPx / 2 - wPx, y, wPx, hCu), p);
            canvas.drawRect(Rect.fromLTWH(cx + sPx / 2, y, wPx, hCu), p);
          } else {
            canvas.drawRect(Rect.fromLTWH(cx - wPx / 2, y, wPx, hCu), p);
          }
        } else {
          for (var k = 0; k < 4; k++) {
            canvas.drawRect(Rect.fromLTWH(left + boardW * (0.1 + 0.22 * k), y, boardW * 0.08, hCu), p);
          }
        }
      } else {
        canvas.drawRect(rect, Paint()..color = color.withValues(alpha: refs.contains(i) ? 1 : 0.55));
        if (refs.contains(i)) {
          canvas.drawRect(
              rect.inflate(1),
              Paint()
                ..color = AppColors.accent
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.2);
        }
      }
      _text(canvas, 'L${i + 1}', Offset(4, y + hCu / 2 - 6), isSig ? strong.copyWith(color: AppColors.copper) : label);
      final roleTxt = '${layer.role.label}${isSig ? ' (routed)' : ''}${refs.contains(i) ? ' (ref)' : ''}';
      _text(canvas, '$roleTxt · ${(layer.copperThickness / 34.79e-6).toStringAsFixed(2)} oz',
          Offset(left + boardW + 8, y + hCu / 2 - 6), isSig || refs.contains(i) ? strong : label);
      y += hCu;
      if (i < s.dielectrics.length) {
        final hD = minDiel + s.dielectrics[i] * scale;
        canvas.drawRect(Rect.fromLTWH(left, y, boardW, hD), Paint()..color = AppColors.dielectric.withValues(alpha: 0.55));
        _text(canvas, '${th(s.dielectrics[i])}  Dk ${s.dk}', Offset(left + boardW + 8, y + hD / 2 - 6), label);
        y += hD;
      }
    }
  }

  void _text(Canvas c, String s, Offset at, TextStyle style) {
    final tp = TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr, maxLines: 1)
      ..layout(maxWidth: 160);
    tp.paint(c, at);
  }

  @override
  bool shouldRepaint(covariant _StackupPainter old) => true;
}
