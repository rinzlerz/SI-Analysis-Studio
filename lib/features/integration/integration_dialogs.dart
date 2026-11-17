import 'package:flutter/material.dart';

import '../../core/state/app_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../simulation/comparison/sweep.dart';
import '../../simulation/engine.dart';
import '../../simulation/integration/design_rules.dart';
import '../../simulation/integration/kicad.dart';
import '../../shared/export/export_service.dart';
import '../../shared/files/file_loader.dart';
import '../../shared/widgets/eng_field.dart';
import '../../core/utilities/units.dart';
import '../compare/compare_screen.dart';

/// KiCad .kicad_pcb import into the current analysis (PRD Phase 4).
Future<void> importFromKicad(BuildContext context, AppController c) async {
  final messenger = ScaffoldMessenger.of(context);
  KicadBoard board;
  try {
    final f = await pickTextFile(['kicad_pcb']);
    if (f == null) return;
    board = parseKicadPcb(f.text);
  } on KicadError catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('KiCad import: ${e.message}')));
    return;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not read the board: $e')));
    return;
  }
  if (!context.mounted) return;
  final diff = c.draft.protocol.differential;
  final notes = await showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    builder: (ctx) => _KicadSheet(board: board, controller: c, differential: diff),
  );
  if (notes == null) return;
  c.draftRevision++;
  c.touch();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Imported from KiCad'),
      content: SingleChildScrollView(child: Text([...notes, ...board.notes].map((n) => '• $n').join('\n'))),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
    ),
  );
}

class _KicadSheet extends StatefulWidget {
  const _KicadSheet({required this.board, required this.controller, required this.differential});
  final KicadBoard board;
  final AppController controller;
  final bool differential;

  @override
  State<_KicadSheet> createState() => _KicadSheetState();
}

class _KicadSheetState extends State<_KicadSheet> {
  bool _useStackup = true;
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final b = widget.board;
    final nets = b.routedNets.where((n) => n.name.toLowerCase().contains(_filter.toLowerCase())).toList();
    final pairs = b.pairs.where((p) => p.base.toLowerCase().contains(_filter.toLowerCase())).toList();
    void apply({KicadNet? net, KicadDiffPair? pair}) {
      final notes = applyKicadNet(widget.controller.draft, b, net: net, pair: pair, useStackup: _useStackup);
      Navigator.pop(context, notes);
    }

    String len(double m) => '${(m * 1e3).toStringAsFixed(2)} mm';
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.8,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Import from KiCad', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                b.stackup == null
                    ? 'No usable stackup in the board file.'
                    : 'Stackup: ${b.copperNames.join(' / ')} · Dk ${b.stackup!.dk} · ${(b.stackup!.totalThickness * 1e3).toStringAsFixed(2)} mm',
                style: const TextStyle(color: AppColors.textDim, fontSize: 12),
              ),
            ),
            if (b.stackup != null)
              SwitchListTile(
                title: const Text('Use the board stackup'),
                value: _useStackup,
                onChanged: (v) => setState(() => _useStackup = v),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                decoration: const InputDecoration(labelText: 'Filter nets', prefixIcon: Icon(Icons.search)),
                onChanged: (v) => setState(() => _filter = v),
              ),
            ),
            Expanded(
              child: ListView(children: [
                if (widget.differential && pairs.isNotEmpty)
                  const ListTile(dense: true, title: Text('Differential pairs', style: TextStyle(color: AppColors.textDim))),
                if (widget.differential)
                  for (final p in pairs)
                    ListTile(
                      leading: const Icon(Icons.compare_arrows),
                      title: Text(p.base),
                      subtitle: Text('P ${len(p.p.length)} · N ${len(p.n.length)} · Δ ${len(p.mismatch)} · '
                          'W ${len(p.p.width)} · ${p.p.vias} via(s)'),
                      onTap: () => apply(pair: p),
                    ),
                const ListTile(dense: true, title: Text('Nets (longest first)', style: TextStyle(color: AppColors.textDim))),
                for (final n in nets.take(200))
                  ListTile(
                    dense: true,
                    title: Text(n.name),
                    subtitle: Text('${len(n.length)} · W ${len(n.width)} · ${n.mainLayer ?? '?'} · ${n.vias} via(s)'),
                    onTap: () => apply(net: n),
                  ),
                if (b.stackup != null)
                  ListTile(
                    leading: const Icon(Icons.layers_outlined),
                    title: const Text('Stackup only'),
                    onTap: () => Navigator.pop(context, applyKicadNet(widget.controller.draft, b)),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Exports KiCad custom design rules + a CSV constraint table derived from
/// the analysis.
Future<void> exportDesignRules(BuildContext context, SimulationResult r) async {
  final diff = r.config.protocol.differential;
  final ctrl = TextEditingController(
      text: switch (r.config.protocol) {
    Protocol.spi => 'SCLK',
    Protocol.qspi => '/QSPI_*',
    Protocol.i2c => '/I2C_*',
    Protocol.rgmii => '/RGMII_*',
    Protocol.usb2 => '/USB_D',
    Protocol.usb3 => '/USB3_TX',
    Protocol.pcie => '/PCIE_TX0',
    Protocol.hdmi => '/HDMI_D0',
  });
  final net = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Export design rules'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: diff ? 'Differential pair name (KiCad inDiffPair pattern)' : 'Net name',
          ),
        ),
        const SizedBox(height: 8),
        const Text('Creates a KiCad custom-rules file (.kicad_dru) and a CSV constraint table for other tools.',
            style: TextStyle(color: AppColors.textDim, fontSize: 12)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Export')),
      ],
    ),
  );
  ctrl.dispose();
  if (net == null || net.isEmpty) return;
  final k = constraintsFrom(r, net);
  try {
    await ExportService.shareTexts({
      'si_rules.kicad_dru': (kicadRules([k]), 'text/plain'),
      'si_constraints.csv': (constraintsCsv([k]), 'text/csv'),
    }, 'SI Studio design rules – $net');
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $e')));
  }
}

/// Parameter-sweep setup; opens the comparison screen.
Future<void> startSweep(BuildContext context, AppController c) async {
  final base = c.draft.copy();
  final params = SweepParam.values.where((p) => p.applies(base)).toList();
  final res = await showModalBottomSheet<(SweepParam, List<double>)>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    builder: (ctx) => _SweepSheet(base: base, params: params, controller: c),
  );
  if (res == null || !context.mounted) return;
  final (param, values) = res;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => CompareScreen(
      controller: c,
      cases: [for (final v in values) CompareCase('${param.label} $v', param.apply(base, v))],
      param: param,
      values: values,
    ),
  ));
}

class _SweepSheet extends StatefulWidget {
  const _SweepSheet({required this.base, required this.params, required this.controller});
  final AnalysisConfig base;
  final List<SweepParam> params;
  final AppController controller;

  @override
  State<_SweepSheet> createState() => _SweepSheetState();
}

class _SweepSheetState extends State<_SweepSheet> {
  late SweepParam _p = widget.params.first;
  late double _from, _to;
  int _steps = 5;
  final _invalid = <String>{};

  @override
  void initState() {
    super.initState();
    _reset();
  }

  void _reset() {
    final v = _p.read(widget.base);
    final base = v > 0
        ? v
        : switch (_p.unit) { 'ohm' => 22.0, 'm' => 0.5e-3, 's' => 2e-9, _ => 1e-12 };
    _from = _p == SweepParam.seriesR || _p == SweepParam.lengthMismatch || _p == SweepParam.viaStub || _p == SweepParam.clockDelay
        ? 0
        : base * 0.5;
    _to = _p == SweepParam.clockDelay ? 4e-9 : base * 2;
  }

  UnitSpec get _unit => switch (_p.unit) {
        'ohm' => _p == SweepParam.pullupR ? Units.kohm : Units.ohm,
        'F' => Units.pf,
        'Hz' => widget.base.protocol == Protocol.i2c ? Units.khz : Units.mhz,
        's' => Units.ns,
        _ => (_p == SweepParam.traceLength || _p == SweepParam.lengthMismatch)
            ? widget.controller.settings.lengthUnit.spec
            : widget.controller.settings.geometryUnit.spec,
      };

  void Function(bool) _v(String k) => (ok) => setState(() => ok ? _invalid.remove(k) : _invalid.add(k));

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Parameter sweep', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text('Runs the current analysis once per value and compares the results side by side.',
              style: TextStyle(color: AppColors.textDim, fontSize: 12)),
          LabeledDropdown<SweepParam>(
            label: 'Parameter',
            value: _p,
            items: widget.params,
            itemLabel: (p) => p.label,
            onChanged: (p) => setState(() {
              _p = p;
              _reset();
            }),
          ),
          FieldRow(children: [
            EngField(
              key: ValueKey('from-${_p.name}'),
              label: 'From',
              value: _from,
              unit: _unit,
              min: 0,
              decimals: 3,
              onValidity: _v('from'),
              onChanged: (v) => setState(() => _from = v),
            ),
            EngField(
              key: ValueKey('to-${_p.name}'),
              label: 'To',
              value: _to,
              unit: _unit,
              min: 0,
              decimals: 3,
              onValidity: _v('to'),
              onChanged: (v) => setState(() => _to = v),
            ),
          ]),
          LabeledDropdown<int>(
            label: 'Steps',
            value: _steps,
            items: const [2, 3, 4, 5, 6, 8],
            itemLabel: (n) => '$n configurations',
            onChanged: (n) => setState(() => _steps = n),
          ),
          Text('Current value: ${formatInput(_unit.toDisplay(_p.read(widget.base)), maxDecimals: 3)} ${_unit.label}',
              style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: const Text('Run sweep'),
            onPressed: _invalid.isEmpty && _to != _from
                ? () => Navigator.pop(context, (_p, sweepValues(_from, _to, _steps)))
                : null,
          ),
        ]),
      ),
    );
  }
}
