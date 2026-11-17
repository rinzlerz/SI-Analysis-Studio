import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/theme/app_theme.dart';
import '../../simulation/common/format.dart';
import '../../simulation/model/result.dart';

/// Signal-propagation animation (PRD 7.5).
///
/// The voltage along the line is rebuilt from the simulated forward
/// (incident) wave a(t) and backward (reflected) wave b(t) at the driver:
///   v(x, t) = a(t − τx) + b(t + τx),   τx = (x / L) · T
/// which is exact for a lossless line and approximate for lossy lines.
/// Timing is therefore locked to the calculated propagation delay T and the
/// reflections computed by the simulation engine.
class PropagationAnimation extends StatefulWidget {
  const PropagationAnimation({
    super.key,
    required this.source,
    required this.dt,
    required this.sampleCount,
    required this.incident,
    required this.reflected,
    required this.tx,
    required this.rx,
    required this.lengthLabel,
  });

  final AnimationSource source;
  final double dt;
  final int sampleCount;
  final Float32List incident;
  final Float32List reflected;
  final Float32List tx;
  final Float32List rx;
  final String lengthLabel;

  @override
  State<PropagationAnimation> createState() => _PropagationAnimationState();
}

class _PropagationAnimationState extends State<PropagationAnimation> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  bool _playing = false;
  double _speed = 1;
  late double _t0, _t1, _t;
  late double _vMin, _vMax;

  double get _tMax => widget.dt * (widget.sampleCount - 1);
  double get _delay => widget.source.delay;

  /// Simulation seconds per real second at 1x: one one-way delay in 1.5 s.
  double get _rate => _delay / 1.5;

  @override
  void initState() {
    super.initState();
    _t0 = widget.source.startTime.clamp(0.0, _tMax);
    _t1 = math.min(_tMax - _delay, _t0 + math.max(12 * _delay, 20 * widget.dt));
    if (_t1 <= _t0) _t1 = _tMax;
    _t = _t0;
    _computeRange();
    _ticker = createTicker(_onTick);
  }

  void _computeRange() {
    var lo = double.infinity, hi = -double.infinity;
    for (var k = 0; k <= 60; k++) {
      final t = _t0 + (_t1 - _t0) * k / 60;
      for (var j = 0; j <= 30; j++) {
        final v = _v(j / 30, t);
        lo = math.min(lo, v);
        hi = math.max(hi, v);
      }
      lo = math.min(lo, _at(widget.rx, t));
      hi = math.max(hi, _at(widget.rx, t));
    }
    if (hi - lo < 1e-6) {
      hi += 0.5;
      lo -= 0.5;
    }
    final pad = (hi - lo) * 0.1;
    _vMin = lo - pad;
    _vMax = hi + pad;
  }

  double _at(Float32List a, double t) {
    final x = (t / widget.dt).clamp(0.0, (a.length - 1).toDouble());
    final i = x.floor();
    if (i >= a.length - 1) return a.last;
    final f = x - i;
    return a[i] * (1 - f) + a[i + 1] * f;
  }

  /// Voltage at fractional position [x] (0 = driver, 1 = receiver).
  double _v(double x, double t) => _at(widget.incident, t - x * _delay) + _at(widget.reflected, t + x * _delay);

  void _onTick(Duration elapsed) {
    final realDt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    setState(() {
      _t += realDt * _rate * _speed;
      if (_t > _t1) _t = _t0;
    });
  }

  void _toggle() {
    setState(() {
      _playing = !_playing;
      if (_playing) {
        _last = Duration.zero;
        _ticker.start();
      } else {
        _ticker.stop();
      }
    });
  }

  void _step(double frac) {
    if (_playing) _toggle();
    setState(() => _t = (_t + frac * _delay).clamp(_t0, _t1));
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tRel = _t - _t0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text(
        '${widget.source.label} along the ${widget.lengthLabel} trace · one-way delay T = ${secs(_delay)}',
        style: const TextStyle(color: AppColors.textDim, fontSize: 12),
      ),
      const SizedBox(height: 6),
      Container(
        height: 190,
        decoration: BoxDecoration(
          color: const Color(0xFF070A0E),
          border: Border.all(color: AppColors.outline),
          borderRadius: BorderRadius.circular(8),
        ),
        child: CustomPaint(
          size: Size.infinite,
          painter: _LinePainter(profile: _profile(), vMin: _vMin, vMax: _vMax, label: widget.source.label),
        ),
      ),
      const SizedBox(height: 6),
      Container(
        height: 120,
        decoration: BoxDecoration(
          color: const Color(0xFF070A0E),
          border: Border.all(color: AppColors.outline),
          borderRadius: BorderRadius.circular(8),
        ),
        child: CustomPaint(
          size: Size.infinite,
          painter: _EndsPainter(
            tx: widget.tx,
            rx: widget.rx,
            dt: widget.dt,
            t0: _t0,
            t1: _t1,
            t: _t,
            vMin: _vMin,
            vMax: _vMax,
          ),
        ),
      ),
      Row(children: [
        IconButton(
          tooltip: _playing ? 'Pause' : 'Play',
          icon: Icon(_playing ? Icons.pause_circle : Icons.play_circle, size: 32, color: AppColors.accent),
          onPressed: _toggle,
        ),
        IconButton(tooltip: 'Back T/20', icon: const Icon(Icons.fast_rewind), onPressed: () => _step(-0.05)),
        IconButton(tooltip: 'Forward T/20', icon: const Icon(Icons.fast_forward), onPressed: () => _step(0.05)),
        Expanded(
          child: Slider(
            value: _t.clamp(_t0, _t1),
            min: _t0,
            max: _t1,
            onChanged: (v) {
              if (_playing) _toggle();
              setState(() => _t = v);
            },
          ),
        ),
        DropdownButton<double>(
          value: _speed,
          underline: const SizedBox.shrink(),
          dropdownColor: AppColors.surfaceHigh,
          items: const [
            DropdownMenuItem(value: 0.25, child: Text('0.25×')),
            DropdownMenuItem(value: 0.5, child: Text('0.5×')),
            DropdownMenuItem(value: 1.0, child: Text('1×')),
            DropdownMenuItem(value: 2.0, child: Text('2×')),
            DropdownMenuItem(value: 4.0, child: Text('4×')),
          ],
          onChanged: (v) => setState(() => _speed = v ?? 1),
        ),
      ]),
      Text(
        't = ${secs(tRel)} (${(tRel / _delay).toStringAsFixed(2)} T) · round trips ${(tRel / (2 * _delay)).toStringAsFixed(2)} · '
        'V(TX) ${volts(_at(widget.tx, _t))} · V(RX) ${volts(_at(widget.rx, _t))}',
        style: kNumStyle.copyWith(fontSize: 12, color: AppColors.text),
      ),
      const SizedBox(height: 4),
      const Text(
        'Profile rebuilt from the simulated incident/reflected waves at the driver: exact for a lossless line, '
        'approximate when loss is enabled. 1× plays one line delay in 1.5 s.',
        style: TextStyle(fontSize: 11, color: AppColors.textDim),
      ),
    ]);
  }

  List<double> _profile() => [for (var j = 0; j <= 120; j++) _v(j / 120, _t)];
}

class _LinePainter extends CustomPainter {
  _LinePainter({required this.profile, required this.vMin, required this.vMax, required this.label});
  final List<double> profile;
  final double vMin, vMax;
  final String label;

  @override
  void paint(Canvas canvas, Size size) {
    const boxW = 44.0;
    final left = boxW + 10;
    final right = size.width - boxW - 10;
    final top = 18.0;
    final base = size.height - 34;
    double y(double v) => base - (v - vMin) / (vMax - vMin) * (base - top);
    double x(int j) => left + (right - left) * j / (profile.length - 1);

    // Zero line.
    final zeroY = y(0).clamp(top, base);
    canvas.drawLine(Offset(left, zeroY), Offset(right, zeroY), Paint()..color = AppColors.gridMajor);

    // Profile fill and curve.
    final path = Path()..moveTo(x(0), y(profile.first));
    for (var j = 1; j < profile.length; j++) {
      path.lineTo(x(j), y(profile[j]));
    }
    final fill = Path.from(path)
      ..lineTo(right, zeroY)
      ..lineTo(left, zeroY)
      ..close();
    canvas.drawPath(fill, Paint()..color = AppColors.traces[0].withValues(alpha: 0.12));
    canvas.drawPath(
        path,
        Paint()
          ..color = AppColors.traces[0]
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke);

    // PCB trace coloured by local voltage.
    final traceY = size.height - 16;
    for (var j = 0; j < profile.length - 1; j++) {
      final f = ((profile[j] - vMin) / (vMax - vMin)).clamp(0.0, 1.0);
      final c = Color.lerp(AppColors.copper.withValues(alpha: 0.35), AppColors.traces[0], f)!;
      canvas.drawLine(Offset(x(j), traceY), Offset(x(j + 1), traceY), Paint()
        ..color = c
        ..strokeWidth = 6);
    }
    void box(double l, String t) {
      final r = RRect.fromRectAndRadius(Rect.fromLTWH(l, traceY - 14, boxW, 28), const Radius.circular(4));
      canvas.drawRRect(r, Paint()..color = AppColors.surfaceHigh);
      canvas.drawRRect(
          r,
          Paint()
            ..color = AppColors.outline
            ..style = PaintingStyle.stroke);
      final tp = TextPainter(
          text: TextSpan(text: t, style: const TextStyle(color: AppColors.text, fontSize: 11, fontWeight: FontWeight.w700)),
          textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(canvas, Offset(l + (boxW - tp.width) / 2, traceY - tp.height / 2));
    }

    box(4, 'TX');
    box(size.width - boxW - 4, 'RX');
    final tp = TextPainter(
        text: TextSpan(text: '$label  ${volts(vMax)}', style: const TextStyle(color: AppColors.textDim, fontSize: 10)),
        textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(canvas, const Offset(6, 2));
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) => true;
}

class _EndsPainter extends CustomPainter {
  _EndsPainter({
    required this.tx,
    required this.rx,
    required this.dt,
    required this.t0,
    required this.t1,
    required this.t,
    required this.vMin,
    required this.vMax,
  });
  final Float32List tx, rx;
  final double dt, t0, t1, t, vMin, vMax;

  @override
  void paint(Canvas canvas, Size size) {
    const l = 8.0, r = 8.0, tp = 14.0, b = 8.0;
    final w = size.width - l - r, h = size.height - tp - b;
    double px(double time) => l + (time - t0) / (t1 - t0) * w;
    double py(double v) => tp + h - (v - vMin) / (vMax - vMin) * h;
    void trace(Float32List a, Color c) {
      final i0 = math.max(0, (t0 / dt).floor());
      final i1 = math.min(a.length - 1, (t1 / dt).ceil());
      final step = math.max(1, (i1 - i0) ~/ (w * 2).ceil());
      final path = Path()..moveTo(px(i0 * dt), py(a[i0]));
      for (var i = i0 + step; i <= i1; i += step) {
        path.lineTo(px(i * dt), py(a[i]));
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = c
            ..strokeWidth = 1.5
            ..style = PaintingStyle.stroke);
    }

    trace(tx, AppColors.traces[3]);
    trace(rx, AppColors.traces[0]);
    final x = px(t);
    canvas.drawLine(Offset(x, tp), Offset(x, tp + h), Paint()..color = AppColors.accent);
    final label = TextPainter(
        text: TextSpan(children: [
          TextSpan(text: 'TX pin  ', style: TextStyle(color: AppColors.traces[3], fontSize: 10)),
          TextSpan(text: 'RX pin', style: TextStyle(color: AppColors.traces[0], fontSize: 10)),
        ]),
        textDirection: TextDirection.ltr)
      ..layout();
    label.paint(canvas, const Offset(8, 1));
  }

  @override
  bool shouldRepaint(covariant _EndsPainter old) => old.t != t;
}
