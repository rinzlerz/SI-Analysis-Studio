/// Guideline diagrams as simple vector shapes (pure Dart).
///
/// One description drives three outputs: the Flutter painter in the app,
/// SVG for the PDF export, and SVG previews during development.
library;

import 'dart:math' as math;

import '../common/format.dart';
import '../impedance/impedance.dart';
import '../model/config.dart';
import 'guidelines.dart';

// ---------------------------------------------------------------------------
// Shapes
// ---------------------------------------------------------------------------

enum Anchor { start, middle, end }

sealed class FigShape {}

class FigRect extends FigShape {
  FigRect(this.x, this.y, this.w, this.h, {this.fill, this.stroke, this.strokeWidth = 1, this.radius = 0});
  final double x, y, w, h;
  final int? fill, stroke;
  final double strokeWidth, radius;
}

class FigLine extends FigShape {
  FigLine(this.x1, this.y1, this.x2, this.y2, this.color, {this.width = 1, this.dash = false});
  final double x1, y1, x2, y2;
  final int color;
  final double width;
  final bool dash;
}

class FigPath extends FigShape {
  FigPath(this.points, this.color, {this.width = 1, this.fill, this.closed = false});
  final List<(double, double)> points;
  final int color;
  final double width;
  final int? fill;
  final bool closed;
}

class FigCircle extends FigShape {
  FigCircle(this.cx, this.cy, this.r, {this.fill, this.stroke, this.strokeWidth = 1});
  final double cx, cy, r;
  final int? fill, stroke;
  final double strokeWidth;
}

class FigText extends FigShape {
  FigText(this.x, this.y, this.text, this.color, {this.size = 12, this.anchor = Anchor.middle, this.bold = false});
  final double x, y;
  final String text;
  final int color;
  final double size;
  final Anchor anchor;
  final bool bold;
}

/// A finished figure: canvas size plus shapes in drawing order.
class Figure {
  Figure(this.title, this.width, this.height, this.shapes);
  final String title;
  final double width, height;
  final List<FigShape> shapes;
}

/// Colours for dark (app) and light (PDF) backgrounds, as 0xAARRGGBB.
class FigPalette {
  const FigPalette({
    required this.background,
    required this.text,
    required this.dim,
    required this.copper,
    required this.copperEdge,
    required this.dielectric,
    required this.plane,
    required this.accent,
    required this.good,
    required this.warn,
    required this.bad,
    required this.box,
    required this.boxEdge,
  });
  final int? background;
  final int text, dim, copper, copperEdge, dielectric, plane, accent, good, warn, bad, box, boxEdge;

  static const dark = FigPalette(
    background: null,
    text: 0xFFE6EDF3,
    dim: 0xFF8B9BAB,
    copper: 0xFFD08A45,
    copperEdge: 0xFFF2B27A,
    dielectric: 0xFF1F3A2E,
    plane: 0xFFB8743A,
    accent: 0xFF2DD4BF,
    good: 0xFF3FB950,
    warn: 0xFFD29922,
    bad: 0xFFF85149,
    box: 0xFF1A232E,
    boxEdge: 0xFF3A4A5C,
  );

  static const light = FigPalette(
    background: 0xFFFFFFFF,
    text: 0xFF1B2430,
    dim: 0xFF5B6B7B,
    copper: 0xFFC77B35,
    copperEdge: 0xFF9A5A22,
    dielectric: 0xFFDCEBDD,
    plane: 0xFFB06A2E,
    accent: 0xFF0F8F80,
    good: 0xFF1F883D,
    warn: 0xFFB07A00,
    bad: 0xFFCF222E,
    box: 0xFFF2F5F8,
    boxEdge: 0xFF8A99A8,
  );
}

String _l(double m) {
  if (m >= 25e-3) return '${(m * 1e3).toStringAsFixed(0)} mm';
  if (m >= 1e-3) return '${(m * 1e3).toStringAsFixed(2)} mm';
  return '${(m * 1e3).toStringAsFixed(3)} mm';
}

/// Horizontal or vertical dimension line with end ticks and a label.
void _dim(List<FigShape> out, double x1, double y1, double x2, double y2, String label, int color,
    {double size = 11, bool labelLeft = false, bool labelBelow = false}) {
  final horizontal = (y2 - y1).abs() < (x2 - x1).abs();
  out.add(FigLine(x1, y1, x2, y2, color, width: 1.2));
  const t = 5.0;
  if (horizontal) {
    out.add(FigLine(x1, y1 - t, x1, y1 + t, color, width: 1.2));
    out.add(FigLine(x2, y2 - t, x2, y2 + t, color, width: 1.2));
    out.add(FigText((x1 + x2) / 2, labelBelow ? y1 + 13 : y1 - 10, label, color, size: size));
  } else {
    out.add(FigLine(x1 - t, y1, x1 + t, y1, color, width: 1.2));
    out.add(FigLine(x2 - t, y2, x2 + t, y2, color, width: 1.2));
    out.add(FigText(labelLeft ? x1 - 9 : x1 + 9, (y1 + y2) / 2, label, color,
        size: size, anchor: labelLeft ? Anchor.end : Anchor.start));
  }
}

// ---------------------------------------------------------------------------
// 1. Cross-section of the routing layer
// ---------------------------------------------------------------------------

Figure crossSectionFigure(GuidelineFigures f, FigPalette c) {
  const width = 560.0;
  final s = <FigShape>[];
  final g = f.geometry;
  final strip = g.structure == LineStructure.stripline;
  final diff = f.gap != null;
  // Schematic scale: keep W:S:H proportions, clamped to stay legible.
  const hPx = 70.0;
  final unit = hPx / g.h1;
  double px(double m, double lo, double hi) => (m * unit).clamp(lo, hi);
  final wPx = px(f.width, 28, 140);
  final sPx = diff ? px(f.gap!, 16, 120) : 0.0;
  final tPx = px(g.t, 7, 14);
  final h2Px = strip ? (g.h2! / g.h1 * hPx).clamp(30.0, 110.0) : 0.0;
  const planeT = 10.0;
  const left = 110.0, right = width - 20;
  // Layout from the top down.
  final double traceTop, dielTop;
  if (strip) {
    dielTop = 62.0 + planeT;
    traceTop = dielTop + h2Px;
  } else {
    traceTop = 78.0;
    dielTop = traceTop + tPx;
  }
  final traceBottom = traceTop + tPx;
  final bottomPlaneY = traceBottom + hPx;
  final height = bottomPlaneY + planeT + (diff || strip ? 36 : 16);
  s.add(FigRect(left, dielTop, right - left, bottomPlaneY - dielTop, fill: c.dielectric));
  s.add(FigRect(left, bottomPlaneY, right - left, planeT, fill: c.plane, stroke: c.copperEdge, strokeWidth: 0.8));
  s.add(FigText(right - 6, bottomPlaneY + planeT / 2, 'reference plane (GND)', c.text, size: 10, anchor: Anchor.end));
  if (strip) {
    s.add(FigRect(left, dielTop - planeT, right - left, planeT, fill: c.plane, stroke: c.copperEdge, strokeWidth: 0.8));
    s.add(FigText(right - 6, dielTop - planeT / 2, 'reference plane', c.text, size: 10, anchor: Anchor.end));
  }
  s.add(FigText(right - 8, bottomPlaneY - 12, 'Dk ${g.er}', c.dim, size: 11, anchor: Anchor.end));
  final totalW = diff ? 2 * wPx + sPx : wPx;
  final x0 = (left + right) / 2 - totalW / 2 - 30;
  final xs = diff ? [x0, x0 + wPx + sPx] : [x0];
  for (final x in xs) {
    s.add(FigRect(x, traceTop, wPx, tPx, fill: c.copper, stroke: c.copperEdge, strokeWidth: 1));
  }
  // W above the trace on microstrip; below it on stripline (little room above).
  if (strip) {
    _dim(s, xs.first, traceBottom + 14, xs.first + wPx, traceBottom + 14, 'W ${_l(f.width)}', c.accent, labelBelow: true);
    if (diff) {
      _dim(s, xs.first + wPx, traceBottom + 44, xs.last, traceBottom + 44, 'S ${_l(f.gap!)}', c.accent, labelBelow: true);
    }
  } else {
    _dim(s, xs.first, traceTop - 16, xs.first + wPx, traceTop - 16, 'W ${_l(f.width)}', c.accent);
    if (diff) {
      _dim(s, xs.first + wPx, traceBottom + 14, xs.last, traceBottom + 14, 'S ${_l(f.gap!)}', c.accent, labelBelow: true);
    }
  }
  const hx = left - 14;
  _dim(s, hx, traceBottom, hx, bottomPlaneY, 'H ${_l(g.h1)}', c.accent, labelLeft: true);
  if (strip) {
    _dim(s, hx, dielTop, hx, traceTop, 'H2 ${_l(g.h2!)}', c.accent, labelLeft: true);
  }
  final tx = (diff ? xs.last : xs.first) + wPx + 10;
  s.add(FigText(tx, traceTop + tPx / 2, 'T ${_l(g.t)}', c.dim, size: 10, anchor: Anchor.start));
  s.add(FigText(16, 16, '${g.structure.label} · ${ohm(f.target)}${diff ? ' differential' : ''}', c.text,
      size: 13, anchor: Anchor.start, bold: true));
  s.add(FigText(16, 34, 'Not to scale – dimensions from the stackup', c.dim, size: 10, anchor: Anchor.start));
  return Figure('Cross-section', width, height, s);
}

// ---------------------------------------------------------------------------
// 2. Top view of the routing rules
// ---------------------------------------------------------------------------

Figure topViewFigure(GuidelineFigures f, FigPalette c) {
  return switch (f.kind) {
    FigureKind.diffPair => _topDiff(f, c),
    FigureKind.bus => _topBus(f, c),
    FigureKind.i2c => _topI2c(f, c),
  };
}

void _chip(List<FigShape> s, double x, double y, double w, double h, String label, FigPalette c) {
  s.add(FigRect(x, y, w, h, fill: c.box, stroke: c.boxEdge, strokeWidth: 1.2, radius: 6));
  s.add(FigText(x + w / 2, y + h / 2, label, c.text, size: 11, bold: true));
}

void _lengthArrow(List<FigShape> s, double x1, double x2, double y, GuidelineFigures f, FigPalette c, {String prefix = ''}) {
  final lmax = f.lengthMax;
  final over = lmax != null && f.currentLength > lmax;
  final label = lmax == null
      ? '${prefix}length: no hard limit (now ${_l(f.currentLength)})'
      : '$prefix≤ ${_l(lmax)}   (now ${_l(f.currentLength)})';
  s.add(FigLine(x1, y, x2, y, over ? c.bad : c.dim, width: 1.2));
  s.add(FigPath([(x1 + 7, y - 4), (x1, y), (x1 + 7, y + 4)], over ? c.bad : c.dim, width: 1.2));
  s.add(FigPath([(x2 - 7, y - 4), (x2, y), (x2 - 7, y + 4)], over ? c.bad : c.dim, width: 1.2));
  s.add(FigText((x1 + x2) / 2, y - 10, label, over ? c.bad : c.text, size: 11, bold: true));
}

Figure _topDiff(GuidelineFigures f, FigPalette c) {
  const width = 640.0, height = 262.0;
  final s = <FigShape>[];
  const xL = 110.0, xR = 540.0;
  const trace = 5.0, gap = 7.0;
  const yA = 100.0; // pair A, upper line centre
  final yA2 = yA + trace + gap;
  final yB = yA2 + 64; // pair B
  final yB2 = yB + trace + gap;
  _chip(s, 20, yA - 40, 80, 150, f.leftLabel, c);
  _chip(s, xR + 10, yA - 40, 80, 150, f.rightLabel, c);
  _lengthArrow(s, xL, xR, 40, f, c);
  // Pair A with a small serpentine on the lower (shorter) leg.
  s.add(FigLine(xL, yA, xR, yA, c.copper, width: trace));
  final serp = <(double, double)>[(xL, yA2)];
  const sx = 430.0;
  serp.add((sx, yA2));
  for (var i = 0; i < 3; i++) {
    final x = sx + i * 14;
    serp.addAll([(x, yA2 + 9), (x + 7, yA2 + 9), (x + 7, yA2), (x + 14, yA2)]);
  }
  serp.add((xR, yA2));
  s.add(FigPath(serp, c.copper, width: trace));
  if (f.matching != null) {
    s.add(FigText(sx + 21, yA2 + 24, '${f.matchingLabel} ± ${_l(f.matching!)}', c.accent, size: 11, bold: true));
  }
  s.add(FigText(xL + 4, yA - 12, f.signalNames.isNotEmpty ? f.signalNames.first : '+', c.dim, size: 10, anchor: Anchor.start));
  s.add(FigText(xL + 4, yA2 + 14, f.signalNames.length > 1 ? f.signalNames[1] : '−', c.dim, size: 10, anchor: Anchor.start));
  // AC caps on pair A.
  if (f.acCaps) {
    const cx = 180.0;
    for (final y in [yA, yA2]) {
      s.add(FigRect(cx - 9, y - 5, 18, 10, fill: c.box, stroke: c.copperEdge, strokeWidth: 1.2, radius: 2));
    }
    s.add(FigText(cx, yA - 14, 'AC caps', c.dim, size: 10));
  }
  // Via pair with GND return vias.
  const vx = 300.0;
  for (final y in [yA, yA2]) {
    s.add(FigCircle(vx, y, 7, fill: c.box, stroke: c.copperEdge, strokeWidth: 2));
  }
  for (final (dx, y) in [(-18.0, yA - 10), (18.0, yA - 10), (-18.0, yA2 + 10), (18.0, yA2 + 10)]) {
    s.add(FigCircle(vx + dx, y, 4, fill: c.good));
  }
  s.add(FigText(vx, yA - 26, 'via pair + GND return vias', c.dim, size: 10));
  // Pair B and spacing.
  s.add(FigLine(xL, yB, xR, yB, c.copper, width: trace));
  s.add(FigLine(xL, yB2, xR, yB2, c.copper, width: trace));
  s.add(FigText(xL + 4, yB2 + 16, 'neighbouring pair', c.dim, size: 10, anchor: Anchor.start));
  if (f.spacing != null) {
    _dim(s, 240, yA2 + trace / 2, 240, yB - trace / 2, '≥ ${_l(f.spacing!)}', c.accent);
  }
  if (f.gap != null) {
    s.add(FigText(xR - 4, yA - 12, 'gap ${_l(f.gap!)} constant', c.dim, size: 10, anchor: Anchor.end));
  }
  s.add(FigText(20, height - 12, 'Top view (schematic): keep the pair coupled, match P/N near the mismatch, '
      'return vias at every layer change.', c.dim, size: 10, anchor: Anchor.start));
  return Figure('Routing rules', width, height, s);
}

Figure _topBus(GuidelineFigures f, FigPalette c) {
  const width = 640.0;
  final s = <FigShape>[];
  const xL = 110.0, xR = 540.0;
  final names = f.signalNames.isEmpty ? ['CLK', 'D0', 'D1', 'CS'] : f.signalNames;
  const y0 = 100.0, pitch = 34.0, groupGap = 22.0;
  // Line positions, with a gap before each new group (e.g. TX / RX).
  final ys = <double>[];
  var y = y0;
  for (var i = 0; i < names.length; i++) {
    if (i > 0) y += pitch + (f.groupStarts.contains(i) ? groupGap : 0);
    ys.add(y);
  }
  final yLast = ys.last;
  final height = yLast + 28 + 50;
  _chip(s, 20, y0 - 28, 80, yLast - y0 + 56, f.leftLabel, c);
  _chip(s, xR + 10, y0 - 28, 80, yLast - y0 + 56, f.rightLabel, c);
  _lengthArrow(s, xL, xR, 50, f, c, prefix: f.lineLengths != null ? 'longest line ' : 'each line ');
  final hasR = f.seriesR != null;
  for (var i = 0; i < names.length; i++) {
    final y = ys[i];
    if (hasR) {
      s.add(FigLine(xL, y, xL + 20, y, c.copper, width: 4));
      s.add(FigRect(xL + 20, y - 6, 26, 12, fill: c.box, stroke: c.accent, strokeWidth: 1.4, radius: 2));
      s.add(FigLine(xL + 46, y, xR, y, c.copper, width: 4));
    } else {
      s.add(FigLine(xL, y, xR, y, c.copper, width: 4));
    }
    s.add(FigText(xL + (hasR ? 54 : 6), y - 9, names[i], c.dim, size: 10, anchor: Anchor.start));
    final ll = f.lineLengths;
    if (ll != null && i < ll.length) {
      final out = f.lineOut != null && i < f.lineOut!.length && f.lineOut![i];
      if (out) s.add(FigLine(xL + (hasR ? 46 : 0), y, xR, y, c.bad, width: 4));
      s.add(FigText(xR - 26, y - 9, '${_l(ll[i])}${out ? '  out of match' : ''}', out ? c.bad : c.dim,
          size: 10, bold: out, anchor: Anchor.end));
    }
  }
  if (hasR) {
    s.add(FigText(xL + 33, yLast + 24, 'Rs ≈ ${ohm(f.seriesR!)}', c.accent, size: 11, bold: true));
  }
  if (f.spacing != null) {
    _dim(s, 330, ys[0] + 2, 330, ys[1] - 2, '≥ ${_l(f.spacing!)}', c.accent);
  }
  if (f.matching != null) {
    // One bracket per group.
    final starts = [0, ...f.groupStarts.where((g) => g > 0 && g < names.length)]..sort();
    const bx = xR - 18;
    for (var k = 0; k < starts.length; k++) {
      final a = ys[starts[k]];
      final b = ys[k + 1 < starts.length ? starts[k + 1] - 1 : names.length - 1];
      s.add(FigPath([(bx - 6, a - 4), (bx, a - 4), (bx, b + 4), (bx - 6, b + 4)], c.accent, width: 1.4));
    }
    s.add(FigText(bx - 10, yLast + 22, '${f.matchingLabel} ± ${_l(f.matching!)}${starts.length > 1 ? ' per group' : ''}', c.accent,
        size: 11, bold: true, anchor: Anchor.end));
  }
  final note = f.seriesR != null
      ? 'Series resistors close to the driver (line longer than ${_l(f.criticalLength ?? 0)}).'
      : (f.criticalLength != null ? 'No termination needed below ${_l(f.criticalLength!)}.' : '');
  s.add(FigText(20, height - 12, 'Top view (schematic): point to point, no stubs. $note', c.dim, size: 10, anchor: Anchor.start));
  return Figure('Routing rules', width, height, s);
}

Figure _topI2c(GuidelineFigures f, FigPalette c) {
  const width = 640.0, height = 292.0;
  final s = <FigShape>[];
  const xL = 110.0, xR = 600.0;
  const ySda = 170.0, yScl = 200.0;
  _chip(s, 20, ySda - 30, 80, 70, f.leftLabel, c);
  _lengthArrow(s, xL, xR, 52, f, c, prefix: 'total bus ');
  // VDD rail and pull-ups.
  const yV = 92.0;
  s.add(FigLine(126, yV, 210, yV, c.warn, width: 2));
  s.add(FigText(218, yV, 'VDD', c.warn, size: 10, anchor: Anchor.start));
  for (final (x, y) in [(140.0, ySda), (180.0, yScl)]) {
    s.add(FigLine(x, yV, x, yV + 14, c.dim, width: 1.4));
    s.add(FigRect(x - 6, yV + 14, 12, 30, fill: c.box, stroke: c.accent, strokeWidth: 1.4, radius: 2));
    s.add(FigLine(x, yV + 44, x, y, c.dim, width: 1.4));
    s.add(FigCircle(x, y, 3, fill: c.dim));
  }
  final rp = f.rpMin == null
      ? ''
      : (f.rpMax == null ? 'Rp ≥ ${eng(f.rpMin!, 'Ω')}' : 'Rp ${eng(f.rpMin!, 'Ω')} – ${eng(f.rpMax!, 'Ω')}');
  s.add(FigText(196, yV + 30, rp, c.accent, size: 11, bold: true, anchor: Anchor.start));
  s.add(FigLine(xL, ySda, xR, ySda, c.copper, width: 3));
  s.add(FigLine(xL, yScl, xR, yScl, c.copper, width: 3));
  s.add(FigText(xR, ySda - 9, 'SDA', c.dim, size: 10, anchor: Anchor.end));
  s.add(FigText(xR, yScl + 14, 'SCL', c.dim, size: 10, anchor: Anchor.end));
  for (var i = 0; i < 3; i++) {
    final x = 300.0 + i * 100;
    s.add(FigLine(x, ySda, x, 236, c.copper, width: 2));
    s.add(FigLine(x + 12, yScl, x + 12, 236, c.copper, width: 2));
    s.add(FigCircle(x, ySda, 3.5, fill: c.copperEdge));
    s.add(FigCircle(x + 12, yScl, 3.5, fill: c.copperEdge));
    _chip(s, x - 18, 236, 48, 26, 'T${i + 1}', c);
  }
  s.add(FigText(20, height - 14, 'One pull-up pair per bus; every branch and device pin adds to the bus capacitance.',
      c.dim, size: 10, anchor: Anchor.start));
  return Figure('Bus topology', width, height, s);
}

// ---------------------------------------------------------------------------
// 3. Via stub
// ---------------------------------------------------------------------------

Figure? viaStubFigure(GuidelineFigures f, FigPalette c) {
  final v = f.via;
  if (v == null) return null;
  const width = 560.0, height = 280.0;
  final s = <FigShape>[];
  const top = 50.0, boardH = 180.0;
  const left = 80.0, right = 520.0;
  final k = boardH / v.thickness;
  s.add(FigRect(left, top, right - left, boardH, fill: c.dielectric));
  const vx = 300.0, viaW = 16.0;
  for (var i = 0; i < v.layerTop.length; i++) {
    final y = top + v.layerTop[i] * k;
    final h = math.max(3.0, v.layerT[i] * k);
    final plane = v.roles[i].isPlane;
    if (plane) {
      // Plane with an anti-pad around the via.
      s.add(FigRect(left, y, vx - viaW - 10 - left, h, fill: c.plane));
      s.add(FigRect(vx + viaW + 10, y, right - vx - viaW - 10, h, fill: c.plane));
    }
    s.add(FigText(left - 8, y + h / 2, 'L${i + 1}${plane ? ' plane' : ''}', plane ? c.dim : c.text, size: 10, anchor: Anchor.end));
  }
  final yTop = top;
  final yExit = top + (v.layerTop[v.exitLayer] + v.layerT[v.exitLayer]) * k;
  final yBot = top + boardH;
  // Barrel: used part and stub.
  s.add(FigRect(vx - viaW / 2, yTop, viaW, yExit - yTop, fill: c.copper, stroke: c.copperEdge));
  final over = v.stubMax != null && v.stub > v.stubMax!;
  if (v.stub > 1e-6) {
    s.add(FigRect(vx - viaW / 2, yExit, viaW, yBot - yExit, fill: over ? c.bad : c.warn, stroke: c.copperEdge));
  }
  // Signal in (top) and out (exit layer).
  s.add(FigLine(left + 20, yTop + 2, vx - viaW / 2, yTop + 2, c.copper, width: 5));
  s.add(FigLine(vx + viaW / 2, yExit - 2, right - 20, yExit - 2, c.copper, width: 5));
  s.add(FigText(left + 24, yTop - 10, 'signal in (L1)', c.dim, size: 10, anchor: Anchor.start));
  s.add(FigText(right - 24, yExit - 12, 'routed on L${v.exitLayer + 1}', c.dim, size: 10, anchor: Anchor.end));
  if (v.stub > 1e-6) {
    _dim(s, vx + 34, yExit, vx + 34, yBot, 'stub ${_l(v.stub)}', over ? c.bad : c.warn);
  }
  final verdict = v.stubMax == null
      ? ''
      : v.stub <= 1e-6
          ? 'No stub: the whole via barrel carries the signal.'
          : over
              ? 'Stub longer than ${_l(v.stubMax!)} – back-drill or use a blind via.'
              : 'Stub within the ${_l(v.stubMax!)} limit.';
  s.add(FigText(left, 22, 'Via from L1 to L${v.exitLayer + 1} · board ${_l(v.thickness)}', c.text,
      size: 13, anchor: Anchor.start, bold: true));
  s.add(FigText(left, height - 16, verdict, over ? c.bad : c.text, size: 11, anchor: Anchor.start, bold: over));
  return Figure('Via stub', width, height, s);
}

// ---------------------------------------------------------------------------
// 4. Length gauge
// ---------------------------------------------------------------------------

Figure? lengthGaugeFigure(GuidelineFigures f, FigPalette c) {
  final lmax = f.lengthMax;
  if (lmax == null) return null;
  const width = 560.0, height = 90.0;
  final s = <FigShape>[];
  const x0 = 20.0, x1 = 540.0, y = 46.0, h = 14.0;
  final span = math.max(lmax * 1.3, f.currentLength * 1.1);
  double px(double m) => x0 + (m / span).clamp(0.0, 1.0) * (x1 - x0);
  s.add(FigRect(x0, y, px(lmax) - x0, h, fill: c.good, radius: 3));
  s.add(FigRect(px(lmax), y, x1 - px(lmax), h, fill: c.bad, radius: 3));
  s.add(FigLine(px(lmax), y - 6, px(lmax), y + h + 6, c.text, width: 1.5));
  s.add(FigText(px(lmax), y + h + 18, 'max ${_l(lmax)}', c.text, size: 11, bold: true));
  final xc = px(f.currentLength);
  final ok = f.currentLength <= lmax;
  s.add(FigPath([(xc - 7, y - 14), (xc + 7, y - 14), (xc, y - 3)], ok ? c.text : c.bad, fill: ok ? c.text : c.bad, closed: true));
  s.add(FigText(xc, y - 24, 'now ${_l(f.currentLength)}', ok ? c.text : c.bad, size: 11, bold: true));
  return Figure('Length budget', width, height, s);
}

/// All figures for [g] (cross-section, top view, via stub, length gauge).
List<Figure> guidelineFigures(LayoutGuidelines g, FigPalette c) {
  final f = g.figures;
  if (f == null) return const [];
  return [
    crossSectionFigure(f, c),
    topViewFigure(f, c),
    if (viaStubFigure(f, c) case final v?) v,
    if (lengthGaugeFigure(f, c) case final l?) l,
  ];
}

// ---------------------------------------------------------------------------
// SVG output (PDF export and previews)
// ---------------------------------------------------------------------------

String _hex(int argb) => '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
String _op(int argb) {
  final a = (argb >> 24) & 0xFF;
  return a == 0xFF ? '' : ' opacity="${(a / 255).toStringAsFixed(3)}"';
}

String _esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// SVG text of [f]. [textMap] can replace characters the target cannot draw
/// (e.g. the ASCII-only PDF fonts).
String figureToSvg(Figure f, {int? background, String Function(String)? textMap}) {
  final b = StringBuffer('<svg xmlns="http://www.w3.org/2000/svg" width="${f.width}" height="${f.height}" '
      'viewBox="0 0 ${f.width} ${f.height}" font-family="Helvetica, Arial, sans-serif">');
  if (background != null) b.write('<rect x="0" y="0" width="${f.width}" height="${f.height}" fill="${_hex(background)}"/>');
  String n(double v) => v.toStringAsFixed(1);
  for (final s in f.shapes) {
    switch (s) {
      case FigRect():
        b.write('<rect x="${n(s.x)}" y="${n(s.y)}" width="${n(s.w)}" height="${n(s.h)}"'
            '${s.radius > 0 ? ' rx="${n(s.radius)}"' : ''}'
            ' fill="${s.fill == null ? 'none' : _hex(s.fill!)}"'
            '${s.stroke == null ? '' : ' stroke="${_hex(s.stroke!)}" stroke-width="${n(s.strokeWidth)}"'}/>');
      case FigLine():
        b.write('<line x1="${n(s.x1)}" y1="${n(s.y1)}" x2="${n(s.x2)}" y2="${n(s.y2)}" stroke="${_hex(s.color)}" '
            'stroke-width="${n(s.width)}" stroke-linecap="round"${s.dash ? ' stroke-dasharray="5,4"' : ''}${_op(s.color)}/>');
      case FigPath():
        final pts = s.points.map((p) => '${n(p.$1)},${n(p.$2)}').join(' ');
        b.write('<${s.closed ? 'polygon' : 'polyline'} points="$pts" fill="${s.fill == null ? 'none' : _hex(s.fill!)}" '
            'stroke="${_hex(s.color)}" stroke-width="${n(s.width)}" stroke-linejoin="round" stroke-linecap="round"/>');
      case FigCircle():
        b.write('<circle cx="${n(s.cx)}" cy="${n(s.cy)}" r="${n(s.r)}" fill="${s.fill == null ? 'none' : _hex(s.fill!)}"'
            '${s.stroke == null ? '' : ' stroke="${_hex(s.stroke!)}" stroke-width="${n(s.strokeWidth)}"'}/>');
      case FigText():
        final anchor = switch (s.anchor) { Anchor.start => 'start', Anchor.middle => 'middle', Anchor.end => 'end' };
        // Baseline at roughly the vertical centre.
        b.write('<text x="${n(s.x)}" y="${n(s.y + s.size * 0.35)}" font-size="${n(s.size)}" fill="${_hex(s.color)}" '
            'text-anchor="$anchor"${s.bold ? ' font-weight="bold"' : ''}>${_esc(textMap == null ? s.text : textMap(s.text))}</text>');
    }
  }
  b.write('</svg>');
  return b.toString();
}
