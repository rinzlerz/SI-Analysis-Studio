import 'package:flutter/material.dart';

import '../../simulation/guidelines/figures.dart';

/// Draws a guideline [Figure] scaled to the available width.
class FigureView extends StatelessWidget {
  const FigureView(this.figure, {super.key, this.maxHeight = 320});
  final Figure figure;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      var w = box.maxWidth;
      var h = w * figure.height / figure.width;
      if (h > maxHeight) {
        h = maxHeight;
        w = h * figure.width / figure.height;
      }
      return Center(child: SizedBox(width: w, height: h, child: CustomPaint(painter: _FigurePainter(figure))));
    });
  }
}

class _FigurePainter extends CustomPainter {
  _FigurePainter(this.figure);
  final Figure figure;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / figure.width;
    canvas.save();
    canvas.scale(k);
    for (final s in figure.shapes) {
      switch (s) {
        case FigRect():
          final r = Rect.fromLTWH(s.x, s.y, s.w, s.h);
          final rr = RRect.fromRectAndRadius(r, Radius.circular(s.radius));
          if (s.fill != null) canvas.drawRRect(rr, Paint()..color = Color(s.fill!));
          if (s.stroke != null) {
            canvas.drawRRect(
                rr,
                Paint()
                  ..color = Color(s.stroke!)
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = s.strokeWidth);
          }
        case FigLine():
          final p = Paint()
            ..color = Color(s.color)
            ..strokeWidth = s.width
            ..strokeCap = StrokeCap.round;
          if (!s.dash) {
            canvas.drawLine(Offset(s.x1, s.y1), Offset(s.x2, s.y2), p);
          } else {
            final d = Offset(s.x2 - s.x1, s.y2 - s.y1);
            final len = d.distance;
            final u = d / len;
            for (var t = 0.0; t < len; t += 9) {
              canvas.drawLine(Offset(s.x1, s.y1) + u * t, Offset(s.x1, s.y1) + u * (t + 5 > len ? len : t + 5), p);
            }
          }
        case FigPath():
          final path = Path()..moveTo(s.points.first.$1, s.points.first.$2);
          for (final pt in s.points.skip(1)) {
            path.lineTo(pt.$1, pt.$2);
          }
          if (s.closed) path.close();
          if (s.fill != null) canvas.drawPath(path, Paint()..color = Color(s.fill!));
          canvas.drawPath(
              path,
              Paint()
                ..color = Color(s.color)
                ..style = PaintingStyle.stroke
                ..strokeWidth = s.width
                ..strokeJoin = StrokeJoin.round
                ..strokeCap = StrokeCap.round);
        case FigCircle():
          final c = Offset(s.cx, s.cy);
          if (s.fill != null) canvas.drawCircle(c, s.r, Paint()..color = Color(s.fill!));
          if (s.stroke != null) {
            canvas.drawCircle(
                c,
                s.r,
                Paint()
                  ..color = Color(s.stroke!)
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = s.strokeWidth);
          }
        case FigText():
          final tp = TextPainter(
            text: TextSpan(
              text: s.text,
              style: TextStyle(color: Color(s.color), fontSize: s.size, fontWeight: s.bold ? FontWeight.w700 : FontWeight.w400),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          final dx = switch (s.anchor) {
            Anchor.start => s.x,
            Anchor.middle => s.x - tp.width / 2,
            Anchor.end => s.x - tp.width,
          };
          tp.paint(canvas, Offset(dx, s.y - tp.height / 2));
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FigurePainter old) => old.figure != figure;
}
