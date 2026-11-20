import 'package:flutter/material.dart';

import '../../core/state/app_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../simulation/common/format.dart';
import '../../simulation/engine.dart';
import '../../simulation/guidelines/guidelines.dart';
import '../../simulation/integration/design_rules.dart';
import '../../shared/export/export_service.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/eng_field.dart';
import '../../simulation/guidelines/figures.dart';
import 'figure_view.dart';
import 'guidelines_pdf.dart';

/// Pre-layout routing guidelines for a protocol on the current stackup.
class GuidelinesScreen extends StatefulWidget {
  const GuidelinesScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<GuidelinesScreen> createState() => _GuidelinesScreenState();
}

class _GuidelinesScreenState extends State<GuidelinesScreen> {
  late Protocol _protocol = widget.controller.draft.protocol;
  int? _layer;
  bool _showAssumptions = false;

  AnalysisConfig get _config {
    final d = widget.controller.draft;
    final c = _protocol == d.protocol ? d.copy() : AnalysisConfig.defaults(protocol: _protocol, stackup: d.pcb.stackup);
    if (_layer != null) c.pcb.stackup.signalLayer = _layer!;
    return c;
  }

  Future<void> _export(LayoutGuidelines g, String what) async {
    final messenger = ScaffoldMessenger.of(context);
    final base = 'SI_${_protocol.name}_layout_guidelines';
    try {
      switch (what) {
        case 'pdf':
          await ExportService.sharePdf(base, await buildGuidelinesPdf(g));
        case 'rules':
          await ExportService.shareTexts({
            '$base.kicad_dru': (kicadRules([g.constraints]), 'text/plain'),
            '$base.csv': (constraintsCsv([g.constraints]), 'text/csv'),
          }, g.title);
        case 'text':
          await ExportService.shareText('$base.txt', guidelinesText(g), 'text/plain');
      }
      if (ExportService.downloads) {
        messenger.showSnackBar(const SnackBar(content: Text('Saved to your Downloads folder.')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = _config;
    final g = computeGuidelines(cfg);
    final sameAsDraft = _protocol == widget.controller.draft.protocol;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Layout guidelines'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Export',
            icon: const Icon(Icons.ios_share),
            onSelected: (v) => _export(g, v),
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'pdf',
                  child: ListTile(leading: Icon(Icons.picture_as_pdf_outlined), title: Text('PDF'), subtitle: Text('For design reviews'))),
              PopupMenuItem(
                  value: 'rules',
                  child: ListTile(
                      leading: Icon(Icons.rule_folder_outlined),
                      title: Text('KiCad rules + CSV'),
                      subtitle: Text('Width, gap, length, skew, vias'))),
              PopupMenuItem(value: 'text', child: ListTile(leading: Icon(Icons.description_outlined), title: Text('Text'))),
            ],
          ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                LabeledDropdown<Protocol>(
                  label: 'Interface',
                  value: _protocol,
                  items: Protocol.values,
                  itemLabel: (p) => p.label,
                  onChanged: (p) => setState(() => _protocol = p),
                ),
                const SizedBox(height: 4),
                Text(
                  sameAsDraft
                      ? 'Uses the stackup and ${_protocol.label} settings from New Analysis – change them there to update this sheet.'
                      : 'Uses the stackup from New Analysis with default ${_protocol.label} settings.',
                  style: const TextStyle(color: AppColors.textDim, fontSize: 12),
                ),
              ]),
            ),
            Card(
              margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              color: AppColors.accent.withValues(alpha: 0.10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: AppColors.accent.withValues(alpha: 0.5)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.route, color: AppColors.accent),
                  const SizedBox(width: 10),
                  Expanded(child: Text(g.summary, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600))),
                ]),
              ),
            ),
            if (g.figures != null) ..._diagrams(g),
            SectionCard(
              title: 'Trace width per layer',
              subtitle: 'For ${ohm(cfg.targetImpedance)}${cfg.protocol.differential ? ' differential, gap ${guideLength(cfg.pcb.traceSpacing)}' : ''} · '
                  'tap a layer to plan the route on it',
              leading: const Icon(Icons.layers_outlined),
              child: Column(children: [
                for (final l in g.layers)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    selected: l.primary,
                    selectedColor: AppColors.accent,
                    leading: Icon(l.primary ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                        color: l.primary ? AppColors.accent : AppColors.textDim),
                    title: Text('${l.name} · ${l.structure}'),
                    subtitle: Text(
                      l.width == null
                          ? (l.error ?? 'Target not reachable on this layer')
                          : '${guideLength(l.width!)}'
                              '${l.widthMin != null && l.widthMax != null ? '   ±10 %: ${(l.widthMin! * 1e3).toStringAsFixed(3)}–${(l.widthMax! * 1e3).toStringAsFixed(3)} mm' : ''}'
                              '${l.tpd != null ? '   ${(l.tpd! * 1e9).toStringAsFixed(2)} ps/mm' : ''}',
                      style: TextStyle(color: l.width == null ? AppColors.warning : null, fontSize: 12.5),
                    ),
                    onTap: l.width == null ? null : () => setState(() => _layer = l.index),
                  ),
              ]),
            ),
            for (final s in g.sections)
              SectionCard(
                title: s.title,
                leading: Icon(switch (s.icon) {
                  'width' => Icons.straighten,
                  'length' => Icons.timeline,
                  'spacing' => Icons.space_bar,
                  'via' => Icons.radio_button_unchecked,
                  _ => Icons.info_outline,
                }),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (final i in s.items) _item(i),
                ]),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: TextButton.icon(
                onPressed: () => setState(() => _showAssumptions = !_showAssumptions),
                icon: Icon(_showAssumptions ? Icons.expand_less : Icons.expand_more),
                label: const Text('Assumptions'),
              ),
            ),
            if (_showAssumptions)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final a in g.assumptions)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text('• $a', style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
                    ),
                ]),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Text(
                'Preliminary guidance from closed-form models. Your chip vendor\'s layout guide takes priority; '
                'confirm the routed result with a full analysis.',
                style: TextStyle(color: AppColors.textDim, fontSize: 11.5),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  List<Widget> _diagrams(LayoutGuidelines g) {
    final f = g.figures!;
    const pal = FigPalette.dark;
    final gauge = lengthGaugeFigure(f, pal);
    final via = viaStubFigure(f, pal);
    Widget caption(String t) => Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 10),
          child: Text(t, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textDim, fontSize: 11.5)),
        );
    return [
      if (gauge != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: FigureView(gauge, maxHeight: 90),
        ),
      SectionCard(
        title: 'Diagrams',
        subtitle: 'Drawn from this sheet\'s numbers – they update with the stackup and interface',
        leading: const Icon(Icons.draw_outlined),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          FigureView(crossSectionFigure(f, pal), maxHeight: 260),
          caption('Cross-section of the routing layer'),
          FigureView(topViewFigure(f, pal), maxHeight: 300),
          caption(f.kind == FigureKind.i2c ? 'Bus topology and pull-ups' : 'Routing rules (top view)'),
          if (via != null) ...[
            FigureView(via, maxHeight: 290),
            caption('Via stub: the unused barrel below the exit layer resonates at high data rates'),
          ],
        ]),
      ),
    ];
  }

  Widget _item(GuidelineItem i) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (i.important)
            const Padding(padding: EdgeInsets.only(top: 3, right: 6), child: Icon(Icons.star_rounded, size: 14, color: AppColors.accent)),
          Expanded(child: Text(i.label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5))),
        ]),
        const SizedBox(height: 2),
        Text(i.value,
            style: kNumStyle.copyWith(fontSize: 13.5, color: i.important ? AppColors.accent : AppColors.text)),
        const SizedBox(height: 2),
        Text(i.basis, style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
      ]),
    );
  }
}
