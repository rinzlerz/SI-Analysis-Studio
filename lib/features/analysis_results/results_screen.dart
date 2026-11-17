import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/state/app_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/analysis_record.dart';
import '../../simulation/common/format.dart';
import '../../simulation/engine.dart';
import '../../shared/export/export_service.dart';
import '../../shared/export/pdf_report.dart';
import '../../shared/widgets/common.dart';
import '../waveform/eye_diagram_view.dart';
import '../waveform/propagation_animation.dart';
import '../waveform/waveform_viewer.dart';
import 'report.dart';
import '../integration/integration_dialogs.dart';

const String _eyeView = '__eye__';
const String _animView = '__anim__';
bool _isEye(String v) => v.startsWith(_eyeView);

/// PRD 9.4 – structured results: summary (top), waveform viewer (middle),
/// metrics / violations / recommendations (bottom).
class ResultsScreen extends StatefulWidget {
  const ResultsScreen({super.key, required this.controller, required this.result, required this.record});

  final AppController controller;
  final SimulationResult result;
  final AnalysisRecord record;

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  late String _view;
  bool _issuesOnly = false;
  final _findingsKey = GlobalKey();

  static int _rank(SiStatus s) => switch (s) {
        SiStatus.critical => 0,
        SiStatus.warning => 1,
        SiStatus.info => 2,
        SiStatus.good => 3,
      };

  List<Finding> get _sortedFindings => [...r.findings]..sort((a, b) => _rank(a.status).compareTo(_rank(b.status)));

  void _editAndRerun() {
    widget.controller.loadIntoDraft(widget.record);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _exportSheet() async {
    final v = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('Export & share', style: TextStyle(fontWeight: FontWeight.w600))),
          ListTile(
            leading: const Icon(Icons.picture_as_pdf_outlined),
            title: const Text('PDF report'),
            subtitle: const Text('Waveforms, eye, metrics, findings and assumptions'),
            onTap: () => Navigator.pop(ctx, 'pdf'),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Text report'),
            subtitle: const Text('Plain-text summary, easy to paste into email or chat'),
            onTap: () => Navigator.pop(ctx, 'report'),
          ),
          ListTile(
            leading: const Icon(Icons.table_chart_outlined),
            title: const Text('Waveforms (CSV)'),
            subtitle: const Text('Samples of the waveform view on screen'),
            onTap: () => Navigator.pop(ctx, 'csv'),
          ),
          ListTile(
            leading: const Icon(Icons.data_object),
            title: const Text('Analysis file (JSON)'),
            subtitle: const Text('Re-import or archive the full configuration'),
            onTap: () => Navigator.pop(ctx, 'json'),
          ),
          ListTile(
            leading: const Icon(Icons.rule_folder_outlined),
            title: const Text('Design rules (KiCad / CSV)'),
            subtitle: const Text('Width, gap, length and skew limits for your PCB tool'),
            onTap: () => Navigator.pop(ctx, 'rules'),
          ),
        ]),
      ),
    );
    if (v != null && mounted) _menu(v);
  }

  void _menu(String v) {
    switch (v) {
      case 'csv':
        final tr = r.views.containsKey(_view) ? _tracesFor(_view) : _tracesFor(r.views.keys.first);
        _exportCsv(tr, 0, r.duration);
      case 'json':
        _guard(() => ExportService.shareJson(widget.record));
      case 'pdf':
        _guard(() async => ExportService.sharePdf(widget.record.name, await buildPdfReport(widget.record.name, r)));
      case 'report':
        _guard(() => ExportService.shareReport(widget.record, r, buildTextReport(widget.record.name, r)));
      case 'rules':
        exportDesignRules(context, r);
      case 'rename':
        _rename();
    }
  }

  SimulationResult get r => widget.result;

  @override
  void initState() {
    super.initState();
    _view = r.views.keys.first;
  }

  List<WaveformTrace> _tracesFor(String view) =>
      [for (final id in r.views[view] ?? const <String>[]) if (r.trace(id) != null) r.trace(id)!];

  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
      if (ExportService.downloads && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved to your Downloads folder.')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  void _exportCsv(List<WaveformTrace> traces, double t0, double t1) => _guard(() => ExportService.shareCsv(
        name: widget.record.name,
        dt: r.dt,
        traces: traces,
        t0: t0,
        t1: t1,
      ));

  Future<void> _rename() async {
    final ctrl = TextEditingController(text: widget.record.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename analysis'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    ctrl.dispose();
    if (name != null && name.isNotEmpty) {
      await widget.controller.rename(widget.record, name);
      setState(() {});
    }
  }

  void _openFullscreen() {
    if (_isEye(_view) || _view == _animView) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => WaveformFullscreen(
        title: '${widget.record.name} · $_view',
        dt: r.dt,
        sampleCount: r.sampleCount,
        traces: _tracesFor(_view),
        onExportCsv: _exportCsv,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.record.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(tooltip: 'Edit inputs and re-run', icon: const Icon(Icons.edit_note), onPressed: _editAndRerun),
          IconButton(tooltip: 'Export & share', icon: const Icon(Icons.ios_share), onPressed: _exportSheet),
          PopupMenuButton<String>(
            onSelected: _menu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: ListTile(leading: Icon(Icons.drive_file_rename_outline), title: Text('Rename'))),
              PopupMenuItem(value: 'rules', child: ListTile(leading: Icon(Icons.rule_folder_outlined), title: Text('Export design rules'))),
            ],
          ),
        ],
      ),
      body: LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth > 760 && box.maxWidth > box.maxHeight;
        if (wide) {
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              flex: 3,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: _viewerBlock(chartHeight: null),
              ),
            ),
            Expanded(
              flex: 2,
              child: ListView(children: [_summary(), ..._details()]),
            ),
          ]);
        }
        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            _summary(),
            Padding(padding: const EdgeInsets.fromLTRB(12, 6, 12, 6), child: _viewerBlock(chartHeight: 300)),
            ..._details(),
          ],
        );
      }),
    );
  }

  Widget _summary() {
    final c = r.config;
    final proto = '${c.protocol.label} · ${c.protocolDetail}'
        '${c.protocol.spiFamily ? ' · ${c.spiCfg.termination.label}' : ''}';
    final crit = r.findings.where((f) => f.status == SiStatus.critical).length;
    final warn = r.findings.where((f) => f.status == SiStatus.warning).length;
    final status = r.overallStatus;
    final color = AppColors.status(status);
    final headline = crit > 0
        ? '$crit critical issue${crit == 1 ? '' : 's'}${warn > 0 ? ' · $warn warning${warn == 1 ? '' : 's'}' : ''}'
        : warn > 0
            ? '$warn warning${warn == 1 ? '' : 's'} – layout is marginal'
            : 'No SI issues found';
    final verdict = switch (status) {
      SiStatus.good => 'This layout should give good signal integrity.',
      SiStatus.warning => 'Workable, but review the warnings before release.',
      SiStatus.critical => 'This layout is likely to fail. Fix the critical issues first.',
      SiStatus.info => 'See the details below.',
    };
    final top = _sortedFindings.where((f) => f.status == SiStatus.critical || f.status == SiStatus.warning).take(3).toList();
    final levels = r.metrics.map((m) => m.level).toSet();
    final modelText = [
      if (levels.contains(ModelLevel.analytical)) 'L1 analytical',
      if (levels.contains(ModelLevel.behavioral)) 'L2 behavioural',
      if (levels.contains(ModelLevel.advanced)) 'L3 advanced',
    ].join(' + ');
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withValues(alpha: 0.6)),
      ),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [color.withValues(alpha: 0.14), Colors.transparent],
          ),
        ),
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(
              switch (status) {
                SiStatus.good => Icons.check_circle,
                SiStatus.warning => Icons.warning_amber_rounded,
                SiStatus.critical => Icons.error,
                SiStatus.info => Icons.info_outline,
              },
              color: color,
              size: 34,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(headline, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color)),
                const SizedBox(height: 2),
                Text(verdict, style: const TextStyle(fontSize: 13)),
              ]),
            ),
          ]),
          if (top.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final f in top)
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () {
                  final ctx = _findingsKey.currentContext;
                  if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 350));
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Icon(Icons.circle, size: 8, color: AppColors.status(f.status)),
                    const SizedBox(width: 8),
                    Expanded(child: Text(f.title, style: const TextStyle(fontSize: 13.5))),
                    const Icon(Icons.chevron_right, size: 18, color: AppColors.textDim),
                  ]),
                ),
              ),
          ],
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 6, children: [
            OutlinedButton.icon(onPressed: _editAndRerun, icon: const Icon(Icons.edit_note, size: 18), label: const Text('Edit & re-run')),
            OutlinedButton.icon(
              onPressed: () => _menu('pdf'),
              icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
              label: const Text('PDF report'),
            ),
            OutlinedButton.icon(onPressed: _exportSheet, icon: const Icon(Icons.ios_share, size: 18), label: const Text('Share')),
          ]),
          const Divider(height: 22),
          Text(proto, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          KeyValue('Routing', '${r.impedance.structure} · ${mm(c.pcb.traceLength)} · W ${milStr(c.pcb.traceWidth)}'),
          KeyValue(r.impedance.targetIsDiff ? 'Zdiff / target' : 'Z0 / target',
              '${ohm(r.impedance.relevant)} / ${ohm(r.impedance.target)} (${pct(r.impedance.deviationPct)})'),
          KeyValue('Simulation', '${c.sim.lossy ? 'Lossy' : 'Lossless'} · ${secs(r.duration)} · ${r.computeMillis} ms'),
          KeyValue('Model', '$simulationModelVersion · $modelText'),
        ]),
      ),
    );
  }

  Widget _viewerBlock({required double? chartHeight}) {
    final views = [
      ...r.views.keys,
      for (var i = 0; i < r.eyes.length; i++) '$_eyeView$i',
      if (r.animation != null) _animView,
    ];
    String label(String v) {
      if (v == _animView) return 'Propagation animation';
      if (_isEye(v)) {
        final e = r.eyes[int.parse(v.substring(_eyeView.length))];
        return r.eyes.length > 1 ? 'Eye: ${e.traceLabel}' : 'Eye diagram';
      }
      return v;
    }

    final chips = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (final v in views)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              label: Text(label(v)),
              selected: _view == v,
              onSelected: (_) => setState(() => _view = v),
            ),
          ),
      ]),
    );
    final Widget body;
    final bool scrollable;
    if (_isEye(_view)) {
      body = EyeDiagramView(eye: r.eyes[int.parse(_view.substring(_eyeView.length))], height: chartHeight ?? 360);
      scrollable = true;
    } else if (_view == _animView) {
      final a = r.animation!;
      body = PropagationAnimation(
        key: const ValueKey('anim'),
        source: a,
        dt: r.dt,
        sampleCount: r.sampleCount,
        incident: r.trace(a.incidentId)!.values,
        reflected: r.trace(a.reflectedId)!.values,
        tx: r.trace(a.txId)!.values,
        rx: r.trace(a.rxId)!.values,
        lengthLabel: mm(r.config.pcb.traceLength),
      );
      scrollable = true;
    } else {
      body = WaveformViewer(
        key: ValueKey(_view),
        dt: r.dt,
        sampleCount: r.sampleCount,
        traces: _tracesFor(_view),
        chartHeight: chartHeight,
        onFullscreen: _openFullscreen,
        onExportCsv: _exportCsv,
      );
      scrollable = false;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: chartHeight == null ? MainAxisSize.max : MainAxisSize.min,
      children: [
        chips,
        const SizedBox(height: 6),
        if (chartHeight == null && !scrollable)
          Expanded(child: body)
        else if (chartHeight == null)
          Expanded(child: SingleChildScrollView(child: body))
        else
          body,
      ],
    );
  }

  List<Widget> _details() {
    final findings = _sortedFindings;
    final metrics = _issuesOnly
        ? r.metrics.where((m) => m.status == SiStatus.warning || m.status == SiStatus.critical).toList()
        : r.metrics;
    return [
      SectionCard(
        key: _findingsKey,
        title: 'Findings & recommendations',
        subtitle: '${findings.where((f) => f.status == SiStatus.critical).length} critical · '
            '${findings.where((f) => f.status == SiStatus.warning).length} warning',
        leading: const Icon(Icons.rule),
        child: Column(children: [for (final f in findings) _FindingTile(f)]),
      ),
      if (r.checks.isNotEmpty)
        SectionCard(
          title: 'Compliance-style checks',
          subtitle: '${r.checks.where((k) => k.pass == false).length} fail · reference only, not certification',
          leading: const Icon(Icons.fact_check),
          child: Column(children: [for (final k in r.checks) _CheckTile(k)]),
        ),
      SectionCard(
        title: 'SI metrics',
        subtitle: '${r.metrics.length} metrics · badge = model level (L1 analytical, L2 time-domain, L3 advanced)',
        leading: const Icon(Icons.analytics_outlined),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Align(
            alignment: Alignment.centerLeft,
            child: FilterChip(
              label: const Text('Only warnings & critical'),
              selected: _issuesOnly,
              onSelected: (v) => setState(() => _issuesOnly = v),
            ),
          ),
          if (metrics.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Text('All metrics are within limits.', style: TextStyle(color: AppColors.good)),
            ),
          for (final m in metrics) _MetricTile(m),
        ]),
      ),
      SectionCard(
        title: 'Impedance calculation',
        leading: const Icon(Icons.calculate_outlined),
        initiallyExpanded: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          KeyValue('Structure', r.impedance.structure),
          KeyValue('Method', r.impedance.method),
          KeyValue('Single-ended Z0', ohm(r.impedance.z0)),
          if (r.impedance.zDiff != null) KeyValue('Differential Zdiff', ohm(r.impedance.zDiff!)),
          KeyValue('εeff', r.impedance.eeff.toStringAsFixed(3)),
          KeyValue('Target', ohm(r.impedance.target)),
          KeyValue('Deviation', pct(r.impedance.deviationPct)),
          if (r.impedance.widthForTarget != null)
            KeyValue('Width for target', '${milStr(r.impedance.widthForTarget!)} (${mm(r.impedance.widthForTarget!)})'),
        ]),
      ),
      SectionCard(
        title: 'Assumptions & limitations',
        leading: const Icon(Icons.fact_check_outlined),
        initiallyExpanded: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final a in r.assumptions)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text('• $a', style: const TextStyle(fontSize: 12.5, color: AppColors.textDim)),
            ),
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              'SI Studio is a preliminary analysis tool. It does not claim protocol compliance or '
              'guaranteed PCB performance. Confirm critical channels with a full-wave or vendor-model simulation '
              'and lab measurement.',
              style: TextStyle(fontSize: 12.5, color: AppColors.warning),
            ),
          ),
        ]),
      ),
    ];
  }
}

class _CheckTile extends StatelessWidget {
  const _CheckTile(this.k);
  final ComplianceCheck k;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (k.pass) {
      true => (Icons.check_circle, AppColors.good),
      false => (Icons.cancel, AppColors.critical),
      null => (Icons.remove_circle_outline, AppColors.info),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(k.name, style: const TextStyle(fontSize: 13.5)),
            Text('${k.requirement} · ${k.source}', style: const TextStyle(fontSize: 11.5, color: AppColors.textDim)),
          ]),
        ),
        const SizedBox(width: 8),
        Text(k.measured, style: kNumStyle.copyWith(fontSize: 12.5, color: color == AppColors.info ? AppColors.text : color)),
      ]),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile(this.m);
  final Metric m;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: LevelBadge(m.level)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(m.label, style: const TextStyle(fontSize: 13.5)),
            if (m.note != null)
              Text(m.note!, style: const TextStyle(fontSize: 11.5, color: AppColors.textDim)),
          ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(formatMetric(m),
              style: kNumStyle.copyWith(fontSize: 13.5, color: AppColors.status(m.status) == AppColors.info ? AppColors.text : AppColors.status(m.status))),
          if (m.status != SiStatus.info) StatusChip(m.status, dense: true),
        ]),
      ]),
    );
  }
}

class _FindingTile extends StatelessWidget {
  const _FindingTile(this.f);
  final Finding f;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.status(f.status);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: c, width: 3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(f.title, style: const TextStyle(fontWeight: FontWeight.w600))),
          StatusChip(f.status, dense: true),
        ]),
        const SizedBox(height: 6),
        Text(f.reason, style: const TextStyle(fontSize: 12.5, color: AppColors.textDim)),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.lightbulb_outline, size: 16, color: AppColors.accent),
          const SizedBox(width: 6),
          Expanded(child: Text(f.recommendation, style: const TextStyle(fontSize: 12.5))),
        ]),
      ]),
    );
  }
}

/// Landscape full-screen waveform inspection (PRD 7.3).
class WaveformFullscreen extends StatefulWidget {
  const WaveformFullscreen({
    super.key,
    required this.title,
    required this.dt,
    required this.sampleCount,
    required this.traces,
    this.onExportCsv,
  });

  final String title;
  final double dt;
  final int sampleCount;
  final List<WaveformTrace> traces;
  final void Function(List<WaveformTrace>, double, double)? onExportCsv;

  @override
  State<WaveformFullscreen> createState() => _WaveformFullscreenState();
}

class _WaveformFullscreenState extends State<WaveformFullscreen> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context)),
              Expanded(child: Text(widget.title, overflow: TextOverflow.ellipsis)),
            ]),
            Expanded(
              child: WaveformViewer(
                dt: widget.dt,
                sampleCount: widget.sampleCount,
                traces: widget.traces,
                onExportCsv: widget.onExportCsv,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
