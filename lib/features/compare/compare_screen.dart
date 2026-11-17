import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/state/app_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/analysis_record.dart';
import '../../simulation/common/format.dart';
import '../../simulation/comparison/sweep.dart';
import '../../simulation/engine.dart';
import '../../shared/export/export_service.dart';
import '../../shared/widgets/common.dart';
import '../analysis_results/report.dart';
import '../analysis_results/results_screen.dart';
import '../waveform/waveform_viewer.dart';

class CompareCase {
  CompareCase(this.label, this.config);
  final String label;
  final AnalysisConfig config;
}

/// Side-by-side comparison of routing configurations and parameter sweeps
/// (PRD Phase 4).
class CompareScreen extends StatefulWidget {
  const CompareScreen({super.key, required this.controller, required this.cases, this.param, this.values});

  final AppController controller;
  final List<CompareCase> cases;

  /// Set for a parameter sweep (values aligned with [cases]).
  final SweepParam? param;
  final List<double>? values;

  @override
  State<CompareScreen> createState() => _CompareScreenState();
}

const _palette = [
  Color(0xFFFFD60A),
  Color(0xFF2DD4BF),
  Color(0xFFFF4FD8),
  Color(0xFF5AA9FF),
  Color(0xFF7EE787),
  Color(0xFFFF9F43),
  Color(0xFFB392F0),
  Color(0xFFF85149),
];

class _CompareScreenState extends State<CompareScreen> {
  late final List<SimulationResult?> _results = List.filled(widget.cases.length, null);
  late final List<String?> _errors = List.filled(widget.cases.length, null);
  int _done = 0;
  String? _view;
  String? _chartMetric;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    for (var i = 0; i < widget.cases.length; i++) {
      try {
        _results[i] = await widget.controller.runConfig(widget.cases[i].config);
      } on SimulationError catch (e) {
        _errors[i] = e.message;
      } catch (e) {
        _errors[i] = '$e';
      }
      if (!mounted) return;
      setState(() => _done = i + 1);
    }
    final ok = _results.whereType<SimulationResult>().toList();
    if (ok.isNotEmpty) {
      final common = ok.first.views.keys.where((v) => ok.every((r) => r.views.containsKey(v))).toList();
      setState(() {
        _view = common.isEmpty ? null : common.first;
        _chartMetric = _metricIds().firstOrNull;
      });
    }
  }

  List<String> _metricIds() {
    final ok = _results.whereType<SimulationResult>();
    final ids = <String>[];
    for (final id in keyMetricIds) {
      if (ok.any((r) => r.metrics.any((m) => m.id == id))) ids.add(id);
    }
    for (final r in ok) {
      for (final m in r.metrics) {
        if (!ids.contains(m.id) && (m.id.startsWith('via') || m.id.startsWith('xt_'))) ids.add(m.id);
      }
    }
    return ids;
  }

  Metric? _m(SimulationResult? r, String id) {
    if (r == null) return null;
    for (final m in r.metrics) {
      if (m.id == id) return m;
    }
    return null;
  }

  String _label(String id) {
    for (final r in _results.whereType<SimulationResult>()) {
      final m = _m(r, id);
      if (m != null) return m.label;
    }
    return id;
  }

  String _caseLabel(int i) {
    final p = widget.param, v = widget.values;
    if (p == null || v == null) return widget.cases[i].label;
    return switch (p.unit) {
      'm' => mm(v[i]),
      'ohm' => ohm(v[i]),
      'F' => eng(v[i], 'F'),
      'Hz' => eng(v[i], 'Hz'),
      's' => secs(v[i]),
      _ => v[i].toStringAsPrecision(3),
    };
  }

  @override
  Widget build(BuildContext context) {
    final running = _done < widget.cases.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.param == null ? 'Compare configurations' : 'Sweep: ${widget.param!.label}'),
        actions: [
          if (!running)
            IconButton(tooltip: 'Export comparison (CSV)', icon: const Icon(Icons.table_chart_outlined), onPressed: _exportCsv),
        ],
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        if (running)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              LinearProgressIndicator(value: _done / widget.cases.length),
              const SizedBox(height: 8),
              Text('Simulating ${_done + 1} of ${widget.cases.length}…', style: const TextStyle(color: AppColors.textDim)),
            ]),
          ),
        _legend(),
        if (widget.param != null && !running) _sweepChart(),
        if (!running) _table(),
        if (!running && _view != null) _overlay(),
      ]),
    );
  }

  Widget _legend() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Wrap(spacing: 8, runSpacing: 6, children: [
        for (var i = 0; i < widget.cases.length; i++)
          ActionChip(
            avatar: CircleAvatar(backgroundColor: _palette[i % _palette.length], radius: 6),
            label: Text(_caseLabel(i), style: const TextStyle(fontSize: 12)),
            onPressed: () => _caseMenu(i),
          ),
      ]),
    );
  }

  Future<void> _caseMenu(int i) async {
    final r = _results[i];
    final v = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(_caseLabel(i), style: const TextStyle(fontWeight: FontWeight.w600))),
          if (r != null)
            ListTile(leading: const Icon(Icons.open_in_new), title: const Text('Open full results'), onTap: () => Navigator.pop(ctx, 'open')),
          ListTile(leading: const Icon(Icons.edit_note), title: const Text('Edit in New Analysis'), onTap: () => Navigator.pop(ctx, 'edit')),
          if (_errors[i] != null) ListTile(title: Text(_errors[i]!, style: const TextStyle(color: AppColors.critical))),
        ]),
      ),
    );
    if (!mounted) return;
    if (v == 'open' && r != null) {
      final rec = AnalysisRecord.fromResult('${widget.param == null ? '' : '${widget.param!.label} = '}${_caseLabel(i)}', r);
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ResultsScreen(controller: widget.controller, result: r, record: rec),
      ));
    } else if (v == 'edit') {
      widget.controller.setDraft(widget.cases[i].config, name: _caseLabel(i));
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  Widget _table() {
    final ids = _metricIds();
    const cellW = 116.0, labelW = 190.0;
    Widget cell(String text, {Color? color, bool head = false, double w = cellW}) => Container(
          width: w,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.outline))),
          child: Text(text,
              style: (head ? const TextStyle(fontWeight: FontWeight.w600, fontSize: 12) : kNumStyle.copyWith(fontSize: 12))
                  .copyWith(color: color)),
        );
    final rows = <Widget>[
      Row(children: [
        cell('Metric', head: true, w: labelW),
        for (var i = 0; i < widget.cases.length; i++) cell(_caseLabel(i), head: true, color: _palette[i % _palette.length]),
      ]),
      Row(children: [
        cell('Overall status', w: labelW),
        for (var i = 0; i < widget.cases.length; i++)
          cell(_results[i]?.overallStatus.label ?? 'error',
              color: _results[i] == null ? AppColors.critical : AppColors.status(_results[i]!.overallStatus)),
      ]),
      Row(children: [
        cell('Critical / warning findings', w: labelW),
        for (var i = 0; i < widget.cases.length; i++)
          cell(_results[i] == null
              ? '—'
              : '${_results[i]!.findings.where((f) => f.status == SiStatus.critical).length} / '
                  '${_results[i]!.findings.where((f) => f.status == SiStatus.warning).length}'),
      ]),
      for (final id in ids)
        Row(children: [
          cell(_label(id), w: labelW),
          for (var i = 0; i < widget.cases.length; i++)
            () {
              final m = _m(_results[i], id);
              return cell(m == null ? '—' : formatMetric(m),
                  color: m == null || m.status == SiStatus.info ? null : AppColors.status(m.status));
            }(),
        ]),
    ];
    return SectionCard(
      title: 'Metrics side by side',
      subtitle: 'Colours follow each metric\'s status; tap a configuration chip for details',
      leading: const Icon(Icons.compare_arrows),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
      ),
    );
  }

  Widget _sweepChart() {
    final ids = _metricIds();
    if (ids.isEmpty || _chartMetric == null) return const SizedBox.shrink();
    final xs = <double>[], ys = <double>[];
    final st = <SiStatus>[];
    for (var i = 0; i < widget.cases.length; i++) {
      final m = _m(_results[i], _chartMetric!);
      if (m == null || !m.value.isFinite) continue;
      xs.add(widget.values![i]);
      ys.add(m.value);
      st.add(m.status);
    }
    final unit = _m(_results.whereType<SimulationResult>().first, _chartMetric!)?.unit ?? '';
    return SectionCard(
      title: 'Metric vs ${widget.param!.label}',
      leading: const Icon(Icons.show_chart),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DropdownButton<String>(
          value: _chartMetric,
          isExpanded: true,
          dropdownColor: AppColors.surfaceHigh,
          items: [for (final id in ids) DropdownMenuItem(value: id, child: Text(_label(id)))],
          onChanged: (v) => setState(() => _chartMetric = v),
        ),
        SizedBox(
          height: 200,
          child: CustomPaint(
            size: Size.infinite,
            painter: _SweepPainter(xs: xs, ys: ys, status: st, xUnit: widget.param!.unit, yUnit: unit),
          ),
        ),
      ]),
    );
  }

  Widget _overlay() {
    final ok = [
      for (var i = 0; i < _results.length; i++)
        if (_results[i] != null) i,
    ];
    final common = _results[ok.first]!.views.keys.where((v) => ok.every((i) => _results[i]!.views.containsKey(v))).toList();
    final view = _view!;
    // Receiver trace of the chosen view for each configuration, resampled on a
    // common time base (coarsest time step, shortest duration).
    final dtC = ok.map((i) => _results[i]!.dt).reduce(math.max);
    final dur = ok.map((i) => _results[i]!.duration).reduce(math.min);
    final n = math.max(2, (dur / dtC).floor() + 1);
    final traces = <WaveformTrace>[];
    final colors = <String, Color>{};
    for (final i in ok) {
      final r = _results[i]!;
      final ids = r.views[view]!;
      WaveformTrace? src;
      for (final id in ids) {
        final t = r.trace(id);
        if (t != null && t.kind == TraceKind.rx) {
          src = t;
          break;
        }
      }
      src ??= r.trace(ids.last);
      if (src == null) continue;
      final out = Float32List(n);
      for (var k = 0; k < n; k++) {
        final x = k * dtC / r.dt;
        final j = x.floor();
        if (j >= src.values.length - 1) {
          out[k] = src.values.last;
        } else {
          final f = x - j;
          out[k] = src.values[j] * (1 - f) + src.values[j + 1] * f;
        }
      }
      final id = 'c$i';
      colors[id] = _palette[i % _palette.length];
      traces.add(WaveformTrace(id: id, label: '${_caseLabel(i)} · ${src.label}', group: 'Compare', kind: TraceKind.other, values: out));
    }
    return SectionCard(
      title: 'Receiver waveform overlay',
      subtitle: 'Resampled to ${secs(dtC)}',
      leading: const Icon(Icons.stacked_line_chart),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (common.length > 1)
          Wrap(spacing: 6, children: [
            for (final v in common) ChoiceChip(label: Text(v), selected: v == view, onSelected: (_) => setState(() => _view = v)),
          ]),
        const SizedBox(height: 6),
        WaveformViewer(
          key: ValueKey('cmp-$view'),
          dt: dtC,
          sampleCount: n,
          traces: traces,
          colors: colors,
          chartHeight: 300,
        ),
      ]),
    );
  }

  Future<void> _exportCsv() async {
    final ids = _metricIds();
    final b = StringBuffer('metric,unit,${[for (var i = 0; i < widget.cases.length; i++) '"${_caseLabel(i)}"'].join(',')}\n');
    b.writeln('overall,,${[for (final r in _results) r?.overallStatus.name ?? 'error'].join(',')}');
    for (final id in ids) {
      final unit = _results.whereType<SimulationResult>().map((r) => _m(r, id)?.unit).whereType<String>().firstOrNull ?? '';
      b.writeln('"${_label(id)}",$unit,${[for (final r in _results) _m(r, id)?.value.toString() ?? ''].join(',')}');
    }
    try {
      await ExportService.shareText('si_comparison.csv', b.toString(), 'text/csv');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }
}

class _SweepPainter extends CustomPainter {
  _SweepPainter({required this.xs, required this.ys, required this.status, required this.xUnit, required this.yUnit});
  final List<double> xs, ys;
  final List<SiStatus> status;
  final String xUnit, yUnit;

  String _fx(double v) => switch (xUnit) {
        'm' => '${(v * 1e3).toStringAsFixed(1)} mm',
        'ohm' => '${v.toStringAsFixed(0)} Ω',
        'F' => eng(v, 'F'),
        'Hz' => eng(v, 'Hz'),
        's' => secs(v),
        _ => v.toStringAsPrecision(3),
      };

  String _fy(double v) => switch (yUnit) {
        's' => secs(v),
        'V' => volts(v),
        'ohm' => ohm(v),
        'dB' => '${v.toStringAsFixed(2)} dB',
        '%' => pct(v),
        'Hz' => eng(v, 'Hz'),
        _ => v.toStringAsPrecision(3),
      };

  @override
  void paint(Canvas canvas, Size size) {
    if (xs.isEmpty) return;
    const l = 70.0, r = 12.0, t = 10.0, b = 26.0;
    final plot = Rect.fromLTRB(l, t, size.width - r, size.height - b);
    var x0 = xs.reduce(math.min), x1 = xs.reduce(math.max);
    var y0 = ys.reduce(math.min), y1 = ys.reduce(math.max);
    if (x1 - x0 < 1e-30) {
      x0 -= 1;
      x1 += 1;
    }
    if (y1 - y0 < 1e-30) {
      final d = y0.abs() * 0.1 + 1e-12;
      y0 -= d;
      y1 += d;
    }
    final pad = (y1 - y0) * 0.1;
    y0 -= pad;
    y1 += pad;
    double px(double x) => plot.left + (x - x0) / (x1 - x0) * plot.width;
    double py(double y) => plot.bottom - (y - y0) / (y1 - y0) * plot.height;
    final grid = Paint()..color = AppColors.grid;
    const ts = TextStyle(color: AppColors.textDim, fontSize: 10);
    void text(String s, Offset o, {bool right = false, bool center = false}) {
      final tp = TextPainter(text: TextSpan(text: s, style: ts), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset(right ? o.dx - tp.width : (center ? o.dx - tp.width / 2 : o.dx), o.dy));
    }

    for (var k = 0; k <= 4; k++) {
      final y = y0 + (y1 - y0) * k / 4;
      canvas.drawLine(Offset(plot.left, py(y)), Offset(plot.right, py(y)), grid);
      text(_fy(y), Offset(plot.left - 4, py(y) - 6), right: true);
    }
    for (var k = 0; k < xs.length; k++) {
      text(_fx(xs[k]), Offset(px(xs[k]), plot.bottom + 4), center: true);
    }
    final path = Path()..moveTo(px(xs.first), py(ys.first));
    for (var k = 1; k < xs.length; k++) {
      path.lineTo(px(xs[k]), py(ys[k]));
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = AppColors.accent
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke);
    for (var k = 0; k < xs.length; k++) {
      canvas.drawCircle(Offset(px(xs[k]), py(ys[k])), 5,
          Paint()..color = status[k] == SiStatus.info ? AppColors.text : AppColors.status(status[k]));
    }
    canvas.drawRect(
        plot,
        Paint()
          ..color = AppColors.gridMajor
          ..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(covariant _SweepPainter old) => old.xs != xs || old.ys != ys;
}
