import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../simulation/common/format.dart';
import '../../simulation/metrics/waveform_metrics.dart';
import '../../simulation/model/result.dart';

enum ViewerMode { pan, cursor }

enum ZoomAxis { x, y, xy }

const double _left = 52;
const double _right = 10;
const double _top = 10;
const double _bottom = 26;

/// Interactive oscilloscope-style viewer for simulated waveforms.
///
/// * Pinch to zoom (axis selectable: X, Y or XY), drag to pan.
/// * Cursor mode: tap/drag to place cursors A and B; read-outs show time,
///   delta-time, and the voltage of every visible trace at each cursor.
/// * Measurements on the visible window: Vmax, Vmin, Vpp, 10-90 % rise and
///   fall time, overshoot / undershoot relative to estimated levels.
/// * Large datasets are drawn with per-pixel min/max decimation.
class WaveformViewer extends StatefulWidget {
  const WaveformViewer({
    super.key,
    required this.dt,
    required this.sampleCount,
    required this.traces,
    this.chartHeight,
    this.onFullscreen,
    this.onExportCsv,
    this.colors,
  });

  /// Optional colour per trace id (comparison overlays).
  final Map<String, Color>? colors;

  final double dt;
  final int sampleCount;
  final List<WaveformTrace> traces;

  /// Fixed chart height; null lets the chart expand (fullscreen use).
  final double? chartHeight;
  final VoidCallback? onFullscreen;

  /// Called with the visible trace ids and the visible time window.
  final void Function(List<WaveformTrace> visible, double t0, double t1)? onExportCsv;

  @override
  State<WaveformViewer> createState() => _WaveformViewerState();
}

class _WaveformViewerState extends State<WaveformViewer> {
  late Set<String> _visible;
  double _x0 = 0, _x1 = 1, _y0 = -1, _y1 = 1;
  ViewerMode _mode = ViewerMode.pan;
  ZoomAxis _axis = ZoomAxis.x;
  double? _cA;
  double? _cB;
  int _dragCursor = 0; // 0 none, 1 A, 2 B
  String? _measureId;

  // Gesture start state.
  Offset _f0 = Offset.zero;
  double _sx0 = 0, _sx1 = 1, _sy0 = 0, _sy1 = 1;
  Size _size = Size.zero;

  double get _tMax => widget.dt * math.max(1, widget.sampleCount - 1);

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void didUpdateWidget(covariant WaveformViewer old) {
    super.didUpdateWidget(old);
    if (old.traces != widget.traces || old.dt != widget.dt) _reset();
  }

  void _reset() {
    _visible = widget.traces.where((t) => t.visibleByDefault).map((t) => t.id).toSet();
    _measureId = widget.traces.where((t) => t.kind == TraceKind.rx).map((t) => t.id).firstOrNull ??
        widget.traces.firstOrNull?.id;
    _cA = null;
    _cB = null;
    _fitAll();
  }

  void _fitAll() {
    _x0 = 0;
    _x1 = _tMax;
    _fitY();
  }

  void _fitY() {
    var lo = double.infinity;
    var hi = -double.infinity;
    final i0 = math.max(0, (_x0 / widget.dt).floor());
    final i1 = math.min(widget.sampleCount, (_x1 / widget.dt).ceil() + 1);
    for (final t in widget.traces) {
      if (!_visible.contains(t.id)) continue;
      for (var i = i0; i < i1 && i < t.values.length; i++) {
        final v = t.values[i];
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
    }
    if (!lo.isFinite || !hi.isFinite) {
      lo = -1;
      hi = 1;
    }
    if (hi - lo < 1e-6) {
      hi += 0.5;
      lo -= 0.5;
    }
    final pad = (hi - lo) * 0.08;
    _y0 = lo - pad;
    _y1 = hi + pad;
  }

  double _timeAt(double px) {
    final w = _size.width - _left - _right;
    return _x0 + (px - _left) / w * (_x1 - _x0);
  }

  double _pxOfTime(double t) {
    final w = _size.width - _left - _right;
    return _left + (t - _x0) / (_x1 - _x0) * w;
  }

  void _onScaleStart(ScaleStartDetails d) {
    _f0 = d.localFocalPoint;
    _sx0 = _x0;
    _sx1 = _x1;
    _sy0 = _y0;
    _sy1 = _y1;
    _dragCursor = 0;
    if (_mode == ViewerMode.cursor && d.pointerCount == 1) {
      _placeCursor(d.localFocalPoint.dx, start: true);
    }
  }

  void _placeCursor(double px, {bool start = false}) {
    final t = _timeAt(px).clamp(0.0, _tMax);
    setState(() {
      if (start) {
        final da = _cA == null ? double.infinity : (_pxOfTime(_cA!) - px).abs();
        final db = _cB == null ? double.infinity : (_pxOfTime(_cB!) - px).abs();
        if (_cA == null) {
          _dragCursor = 1;
        } else if (_cB == null && da > 30) {
          _dragCursor = 2;
        } else {
          _dragCursor = da <= db ? 1 : 2;
        }
      }
      if (_dragCursor == 1) _cA = t;
      if (_dragCursor == 2) _cB = t;
    });
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_mode == ViewerMode.cursor && d.pointerCount == 1 && _dragCursor != 0) {
      _placeCursor(d.localFocalPoint.dx);
      return;
    }
    final w = _size.width - _left - _right;
    final h = _size.height - _top - _bottom;
    if (w <= 0 || h <= 0) return;
    final zoomX = _axis != ZoomAxis.y;
    final zoomY = _axis != ZoomAxis.x;
    final sx = zoomX ? d.horizontalScale : 1.0;
    final sy = zoomY ? d.verticalScale : 1.0;
    final minSpan = widget.dt * 8;
    final spanX = ((_sx1 - _sx0) / (sx <= 0 ? 1 : sx)).clamp(minSpan, _tMax * 2);
    final fx = _sx0 + (_f0.dx - _left) / w * (_sx1 - _sx0);
    var nx0 = fx - (d.localFocalPoint.dx - _left) / w * spanX;
    final margin = spanX * 0.5;
    nx0 = nx0.clamp(-margin, math.max(-margin, _tMax + margin - spanX));
    double ny0 = _y0, ny1 = _y1;
    if (zoomY) {
      final spanY = ((_sy1 - _sy0) / (sy <= 0 ? 1 : sy)).clamp(1e-6, 1e4);
      final fy = _sy1 - (_f0.dy - _top) / h * (_sy1 - _sy0);
      ny1 = fy + (d.localFocalPoint.dy - _top) / h * spanY;
      ny0 = ny1 - spanY;
    }
    setState(() {
      _x0 = nx0;
      _x1 = nx0 + spanX;
      _y0 = ny0;
      _y1 = ny1;
    });
  }

  /// Mouse wheel / trackpad scroll (desktop browsers): zoom time around the
  /// pointer; with Shift held, pan in time.
  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final w = _size.width - _left - _right;
    if (w <= 0) return;
    final span = _x1 - _x0;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (shift || e.scrollDelta.dx.abs() > e.scrollDelta.dy.abs()) {
      final d = (shift ? e.scrollDelta.dy : e.scrollDelta.dx) / w * span;
      final margin = span * 0.5;
      final nx0 = (_x0 + d).clamp(-margin, math.max(-margin, _tMax + margin - span)).toDouble();
      setState(() {
        _x0 = nx0;
        _x1 = nx0 + span;
      });
      return;
    }
    final factor = math.pow(1.0015, e.scrollDelta.dy).toDouble();
    final minSpan = widget.dt * 8;
    final newSpan = (span * factor).clamp(minSpan, _tMax * 2).toDouble();
    final ft = _timeAt(e.localPosition.dx);
    final frac = ((e.localPosition.dx - _left) / w).clamp(0.0, 1.0);
    var nx0 = ft - frac * newSpan;
    final margin = newSpan * 0.5;
    nx0 = nx0.clamp(-margin, math.max(-margin, _tMax + margin - newSpan)).toDouble();
    setState(() {
      _x0 = nx0;
      _x1 = nx0 + newSpan;
    });
  }

  double _valueAt(WaveformTrace t, double time) {
    final x = time / widget.dt;
    final i = x.floor();
    if (i < 0) return t.values.first;
    if (i >= t.values.length - 1) return t.values.last;
    final f = x - i;
    return t.values[i] * (1 - f) + t.values[i + 1] * f;
  }

  Color _color(WaveformTrace t) => widget.colors?[t.id] ?? AppColors.traceKind(t.kind, widget.traces.indexOf(t));

  @override
  Widget build(BuildContext context) {
    final chart = LayoutBuilder(builder: (context, c) {
      _size = Size(c.maxWidth, c.maxHeight);
      return Listener(
        onPointerSignal: _onPointerSignal,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onDoubleTap: () => setState(_fitAll),
          child: CustomPaint(
            size: _size,
            painter: _ScopePainter(
              dt: widget.dt,
              traces: [
                for (final t in widget.traces)
                  if (_visible.contains(t.id)) t
              ],
              colors: {for (final t in widget.traces) t.id: _color(t)},
              x0: _x0,
              x1: _x1,
              y0: _y0,
              y1: _y1,
              cursorA: _cA,
              cursorB: _cB,
            ),
          ),
        ),
      );
    });
    final chartBox = Container(
      decoration: BoxDecoration(
        color: const Color(0xFF070A0E),
        border: Border.all(color: AppColors.outline),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: chart,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: widget.chartHeight == null ? MainAxisSize.max : MainAxisSize.min,
      children: [
        _toolbar(),
        const SizedBox(height: 6),
        if (widget.chartHeight != null)
          SizedBox(height: widget.chartHeight, child: chartBox)
        else
          Expanded(child: chartBox),
        const SizedBox(height: 6),
        if (widget.chartHeight != null) ...[
          _legend(),
          if (_cA != null || _cB != null) _cursorReadout(),
          _measurements(),
        ] else
          // Full-screen: keep the chart dominant; legend/read-outs scroll.
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 120),
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _legend(),
                if (_cA != null || _cB != null) _cursorReadout(),
              ]),
            ),
          ),
      ],
    );
  }

  Widget _toolbar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        SegmentedButton<ViewerMode>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const [
            ButtonSegment(value: ViewerMode.pan, icon: Icon(Icons.pan_tool_alt, size: 16), label: Text('Pan')),
            ButtonSegment(value: ViewerMode.cursor, icon: Icon(Icons.straighten, size: 16), label: Text('Cursor')),
          ],
          selected: {_mode},
          onSelectionChanged: (s) => setState(() => _mode = s.first),
        ),
        const SizedBox(width: 8),
        SegmentedButton<ZoomAxis>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const [
            ButtonSegment(value: ZoomAxis.x, label: Text('X')),
            ButtonSegment(value: ZoomAxis.y, label: Text('Y')),
            ButtonSegment(value: ZoomAxis.xy, label: Text('XY')),
          ],
          selected: {_axis},
          onSelectionChanged: (s) => setState(() => _axis = s.first),
        ),
        IconButton(
          tooltip: 'Fit (double-tap chart)',
          icon: const Icon(Icons.fit_screen),
          onPressed: () => setState(_fitAll),
        ),
        IconButton(
          tooltip: 'Fit vertical to window',
          icon: const Icon(Icons.height),
          onPressed: () => setState(_fitY),
        ),
        IconButton(
          tooltip: 'Zoom in (X)',
          icon: const Icon(Icons.zoom_in),
          onPressed: () => _zoomStep(0.5),
        ),
        IconButton(
          tooltip: 'Zoom out (X)',
          icon: const Icon(Icons.zoom_out),
          onPressed: () => _zoomStep(2),
        ),
        if (_cA != null || _cB != null)
          IconButton(
            tooltip: 'Clear cursors',
            icon: const Icon(Icons.clear),
            onPressed: () => setState(() {
              _cA = null;
              _cB = null;
            }),
          ),
        if (widget.onExportCsv != null)
          IconButton(
            tooltip: 'Export visible window as CSV',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: () => widget.onExportCsv!([
              for (final t in widget.traces)
                if (_visible.contains(t.id)) t
            ], math.max(0, _x0), math.min(_tMax, _x1)),
          ),
        if (widget.onFullscreen != null)
          IconButton(
            tooltip: 'Full screen (landscape)',
            icon: const Icon(Icons.fullscreen),
            onPressed: widget.onFullscreen,
          ),
      ]),
    );
  }

  void _zoomStep(double factor) {
    setState(() {
      final c = (_x0 + _x1) / 2;
      final span = ((_x1 - _x0) * factor).clamp(widget.dt * 8, _tMax * 2);
      _x0 = c - span / 2;
      _x1 = c + span / 2;
    });
  }

  Widget _legend() {
    return Wrap(spacing: 6, runSpacing: 4, children: [
      for (final t in widget.traces)
        FilterChip(
          visualDensity: VisualDensity.compact,
          showCheckmark: false,
          selected: _visible.contains(t.id),
          avatar: Container(
            width: 12,
            height: 3,
            color: _visible.contains(t.id) ? _color(t) : AppColors.textDim,
          ),
          label: Text(t.label, style: const TextStyle(fontSize: 12)),
          onSelected: (on) => setState(() {
            if (on) {
              _visible.add(t.id);
            } else {
              _visible.remove(t.id);
            }
          }),
        ),
    ]);
  }

  Widget _cursorReadout() {
    final vis = [
      for (final t in widget.traces)
        if (_visible.contains(t.id)) t
    ];
    final rows = <TableRow>[
      TableRow(children: [
        const _Cell('Trace', header: true),
        _Cell(_cA == null ? 'A' : 'A @ ${secs(_cA!)}', header: true),
        _Cell(_cB == null ? 'B' : 'B @ ${secs(_cB!)}', header: true),
        const _Cell('ΔV (B−A)', header: true),
      ]),
      for (final t in vis)
        TableRow(children: [
          _Cell(t.label, color: _color(t)),
          _Cell(_cA == null ? '—' : volts(_valueAt(t, _cA!))),
          _Cell(_cB == null ? '—' : volts(_valueAt(t, _cB!))),
          _Cell(_cA == null || _cB == null ? '—' : volts(_valueAt(t, _cB!) - _valueAt(t, _cA!))),
        ]),
    ];
    final dtAB = (_cA != null && _cB != null) ? (_cB! - _cA!) : null;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (dtAB != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'Δt = ${secs(dtAB)}   1/Δt = ${dtAB.abs() > 0 ? eng(1 / dtAB.abs(), 'Hz') : '—'}',
              style: kNumStyle.copyWith(color: AppColors.accent, fontSize: 13),
            ),
          ),
        Table(
          columnWidths: const {0: FlexColumnWidth(1.6)},
          children: rows,
        ),
      ]),
    );
  }

  Widget _measurements() {
    final vis = [
      for (final t in widget.traces)
        if (_visible.contains(t.id)) t
    ];
    if (vis.isEmpty) return const SizedBox.shrink();
    final sel = vis.firstWhere((t) => t.id == _measureId, orElse: () => vis.first);
    final t0 = math.max(0.0, _x0);
    final t1 = math.min(_tMax, _x1);
    final m = measureWindow(sel.values, widget.dt, t0, t1);
    final lv = _levels(sel, t0, t1);
    final over = lv == null ? double.nan : math.max(0.0, m.vMax - lv.$2);
    final under = lv == null ? double.nan : math.max(0.0, lv.$1 - m.vMin);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Measure (visible window): ', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
          Expanded(
            child: DropdownButton<String>(
              isExpanded: true,
              isDense: true,
              value: sel.id,
              underline: const SizedBox.shrink(),
              dropdownColor: AppColors.surfaceHigh,
              items: [
                for (final t in vis)
                  DropdownMenuItem(value: t.id, child: Text(t.label, style: TextStyle(color: _color(t), fontSize: 13))),
              ],
              onChanged: (v) => setState(() => _measureId = v),
            ),
          ),
        ]),
        const SizedBox(height: 4),
        Wrap(spacing: 14, runSpacing: 4, children: [
          _Meas('Vmax', volts(m.vMax)),
          _Meas('Vmin', volts(m.vMin)),
          _Meas('Vpp', volts(m.vpp)),
          _Meas('Rise 10-90', secs(m.riseTime)),
          _Meas('Fall 90-10', secs(m.fallTime)),
          _Meas('Overshoot', volts(over)),
          _Meas('Undershoot', volts(under)),
        ]),
        const Text('Over/undershoot relative to the high/low levels estimated in the window.',
            style: TextStyle(color: AppColors.textDim, fontSize: 10)),
      ]),
    );
  }

  /// Median of samples in the lower and upper halves of the window range.
  (double, double)? _levels(WaveformTrace t, double t0, double t1) {
    final i0 = math.max(0, (t0 / widget.dt).floor());
    final i1 = math.min(t.values.length, (t1 / widget.dt).ceil() + 1);
    if (i1 - i0 < 4) return null;
    var lo = double.infinity, hi = -double.infinity;
    for (var i = i0; i < i1; i++) {
      lo = math.min(lo, t.values[i]);
      hi = math.max(hi, t.values[i]);
    }
    final mid = (lo + hi) / 2;
    final step = math.max(1, (i1 - i0) ~/ 20000);
    final low = <double>[];
    final high = <double>[];
    for (var i = i0; i < i1; i += step) {
      (t.values[i] < mid ? low : high).add(t.values[i]);
    }
    if (low.isEmpty || high.isEmpty) return null;
    low.sort();
    high.sort();
    return (low[low.length ~/ 2], high[high.length ~/ 2]);
  }
}

class _Cell extends StatelessWidget {
  const _Cell(this.text, {this.header = false, this.color});
  final String text;
  final bool header;
  final Color? color;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
        child: Text(text,
            overflow: TextOverflow.ellipsis,
            style: kNumStyle.copyWith(
                fontSize: 12,
                color: color ?? (header ? AppColors.textDim : AppColors.text),
                fontWeight: header ? FontWeight.w600 : FontWeight.normal)),
      );
}

class _Meas extends StatelessWidget {
  const _Meas(this.k, this.v);
  final String k;
  final String v;
  @override
  Widget build(BuildContext context) => RichText(
        text: TextSpan(children: [
          TextSpan(text: '$k ', style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
          TextSpan(text: v, style: kNumStyle.copyWith(fontSize: 12, color: AppColors.text)),
        ]),
      );
}

// ---------------------------------------------------------------------------

double niceStep(double span, int target) {
  if (span <= 0) return 1;
  final raw = span / target;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final n = raw / mag;
  final s = n < 1.5 ? 1 : (n < 3 ? 2 : (n < 7 ? 5 : 10));
  return s * mag;
}

({double scale, String unit}) timeUnit(double span) {
  if (span < 2e-9) return (scale: 1e12, unit: 'ps');
  if (span < 2e-6) return (scale: 1e9, unit: 'ns');
  if (span < 2e-3) return (scale: 1e6, unit: 'µs');
  return (scale: 1e3, unit: 'ms');
}

String tickLabel(double v, double step) {
  final dec = step >= 1 ? 0 : math.min(4, (-math.log(step) / math.ln10).ceil());
  return v.toStringAsFixed(dec);
}

class _ScopePainter extends CustomPainter {
  _ScopePainter({
    required this.dt,
    required this.traces,
    required this.colors,
    required this.x0,
    required this.x1,
    required this.y0,
    required this.y1,
    required this.cursorA,
    required this.cursorB,
  });

  final double dt;
  final List<WaveformTrace> traces;
  final Map<String, Color> colors;
  final double x0, x1, y0, y1;
  final double? cursorA, cursorB;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(_left, _top, size.width - _right, size.height - _bottom);
    if (plot.width <= 4 || plot.height <= 4) return;
    double px(double t) => plot.left + (t - x0) / (x1 - x0) * plot.width;
    double py(double v) => plot.bottom - (v - y0) / (y1 - y0) * plot.height;

    final grid = Paint()
      ..color = AppColors.grid
      ..strokeWidth = 1;
    const axisText = TextStyle(color: AppColors.textDim, fontSize: 10, fontFeatures: [FontFeature.tabularFigures()]);

    // Time grid.
    final tu = timeUnit(x1 - x0);
    final tStep = niceStep((x1 - x0) * tu.scale, math.max(2, (plot.width / 90).floor())) / tu.scale;
    var t = (x0 / tStep).ceil() * tStep;
    while (t <= x1) {
      final x = px(t);
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), grid);
      _text(canvas, tickLabel(t * tu.scale, tStep * tu.scale), Offset(x, plot.bottom + 3), axisText, center: true);
      t += tStep;
    }
    _text(canvas, tu.unit, Offset(plot.right - 2, plot.bottom + 13), axisText, right: true);

    // Voltage grid.
    final mv = (y1 - y0) < 1.0;
    final vScale = mv ? 1e3 : 1.0;
    final vStep = niceStep((y1 - y0) * vScale, math.max(2, (plot.height / 40).floor())) / vScale;
    var v = (y0 / vStep).ceil() * vStep;
    while (v <= y1) {
      final y = py(v);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y),
          (v.abs() < vStep * 1e-6) ? (Paint()..color = AppColors.gridMajor) : grid);
      _text(canvas, tickLabel(v * vScale, vStep * vScale), Offset(plot.left - 4, y - 6), axisText, right: true);
      v += vStep;
    }
    _text(canvas, mv ? 'mV' : 'V', Offset(4, plot.top), axisText);

    canvas.save();
    canvas.clipRect(plot);
    for (final tr in traces) {
      final paint = Paint()
        ..color = colors[tr.id] ?? AppColors.traces[0]
        ..strokeWidth = tr.kind == TraceKind.ideal ? 1.2 : 1.6
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true;
      final n = tr.values.length;
      final i0 = math.max(0, (x0 / dt).floor());
      final i1 = math.min(n - 1, (x1 / dt).ceil());
      if (i1 <= i0) continue;
      final count = i1 - i0;
      final path = Path();
      final cols = plot.width.floor();
      if (count > 2 * cols) {
        // Min/max decimation per pixel column.
        final per = count / cols;
        var first = true;
        for (var c = 0; c < cols; c++) {
          final a = i0 + (c * per).floor();
          final b = math.min(i1 + 1, i0 + ((c + 1) * per).floor() + 1);
          var lo = double.infinity, hi = -double.infinity;
          for (var i = a; i < b; i++) {
            final s = tr.values[i];
            if (s < lo) lo = s;
            if (s > hi) hi = s;
          }
          if (!lo.isFinite) continue;
          final x = plot.left + c + 0.5;
          if (first) {
            path.moveTo(x, py(hi));
            first = false;
          } else {
            path.lineTo(x, py(hi));
          }
          path.lineTo(x, py(lo));
        }
      } else {
        path.moveTo(px(i0 * dt), py(tr.values[i0]));
        for (var i = i0 + 1; i <= i1; i++) {
          path.lineTo(px(i * dt), py(tr.values[i]));
        }
      }
      if (tr.kind == TraceKind.ideal) {
        paint.color = paint.color.withValues(alpha: 0.75);
      }
      canvas.drawPath(path, paint);
    }
    // Cursors.
    void cursor(double? tc, String label, Color c) {
      if (tc == null) return;
      final x = px(tc);
      final p = Paint()
        ..color = c
        ..strokeWidth = 1;
      for (var y = plot.top; y < plot.bottom; y += 8) {
        canvas.drawLine(Offset(x, y), Offset(x, math.min(y + 4, plot.bottom)), p);
      }
      _text(canvas, label, Offset(x + 3, plot.top + 2), TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.bold));
    }

    cursor(cursorA, 'A', AppColors.accent);
    cursor(cursorB, 'B', const Color(0xFFFF9F43));
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
  bool shouldRepaint(covariant _ScopePainter o) =>
      o.x0 != x0 ||
      o.x1 != x1 ||
      o.y0 != y0 ||
      o.y1 != y1 ||
      o.cursorA != cursorA ||
      o.cursorB != cursorB ||
      o.traces.length != traces.length ||
      !_sameIds(o.traces, traces);

  bool _sameIds(List<WaveformTrace> a, List<WaveformTrace> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || !identical(a[i].values, b[i].values)) return false;
    }
    return true;
  }
}

/// Renders traces to a PNG (dark scope style) for reports.
Future<Uint8List> renderWaveformPng({
  required double dt,
  required List<WaveformTrace> traces,
  double? t0,
  double? t1,
  int width = 1200,
  int height = 520,
}) async {
  var lo = double.infinity, hi = -double.infinity;
  final n = traces.isEmpty ? 0 : traces.first.values.length;
  final x0 = t0 ?? 0, x1 = t1 ?? dt * math.max(1, n - 1);
  final i0 = math.max(0, (x0 / dt).floor()), i1 = math.min(n, (x1 / dt).ceil() + 1);
  for (final t in traces) {
    for (var i = i0; i < i1 && i < t.values.length; i++) {
      lo = math.min(lo, t.values[i]);
      hi = math.max(hi, t.values[i]);
    }
  }
  if (!lo.isFinite) {
    lo = -1;
    hi = 1;
  }
  final pad = (hi - lo) * 0.08 + 1e-6;
  final rec = ui.PictureRecorder();
  final size = Size(width.toDouble(), height.toDouble());
  final canvas = Canvas(rec, Offset.zero & size);
  canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF070A0E));
  _ScopePainter(
    dt: dt,
    traces: traces,
    colors: {for (var i = 0; i < traces.length; i++) traces[i].id: AppColors.traceKind(traces[i].kind, i)},
    x0: x0,
    x1: x1,
    y0: lo - pad,
    y1: hi + pad,
    cursorA: null,
    cursorB: null,
  ).paint(canvas, size);
  // Legend.
  var lx = 60.0;
  for (var i = 0; i < traces.length; i++) {
    final c = AppColors.traceKind(traces[i].kind, i);
    canvas.drawRect(Rect.fromLTWH(lx, 14, 16, 3), Paint()..color = c);
    final tp = TextPainter(
        text: TextSpan(text: traces[i].label, style: const TextStyle(color: AppColors.text, fontSize: 12)),
        textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(canvas, Offset(lx + 20, 8));
    lx += tp.width + 40;
  }
  final img = await rec.endRecording().toImage(width, height);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}
