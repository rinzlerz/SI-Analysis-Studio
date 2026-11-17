import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utilities/units.dart';
import '../../simulation/common/format.dart';
import '../../simulation/impedance/impedance.dart';
import '../../simulation/model/config.dart';
import '../../shared/widgets/eng_field.dart';
import 'stackup_painter.dart';

/// Simplified mobile stackup editor (PRD 5). Edits [stackup] in place and
/// calls [onChanged] after every valid change.
class StackupEditor extends StatefulWidget {
  const StackupEditor({
    super.key,
    required this.stackup,
    required this.unit,
    required this.onChanged,
    this.onValidity,
    this.traceWidth,
    this.traceSpacing,
    this.differential = false,
  });

  final StackupConfig stackup;
  final UnitSpec unit;
  final VoidCallback onChanged;
  final void Function(String key, bool valid)? onValidity;
  final double? traceWidth;
  final double? traceSpacing;
  final bool differential;

  @override
  State<StackupEditor> createState() => _StackupEditorState();
}

class _StackupEditorState extends State<StackupEditor> {
  int _rev = 0;
  bool _showLayers = false;

  StackupConfig get s => widget.stackup;

  void _changed() {
    setState(() {});
    widget.onChanged();
  }

  void _applyPreset(int count) {
    final p = StackupConfig.preset(count);
    s.layers = p.layers;
    s.dielectrics = p.dielectrics;
    s.dk = p.dk;
    s.df = p.df;
    s.signalLayer = p.signalLayer;
    s.roughnessRms = p.roughnessRms;
    _rev++;
    _changed();
  }

  @override
  Widget build(BuildContext context) {
    String geomText;
    Color geomColor = AppColors.textDim;
    try {
      final g = geometryFromStackup(s);
      final ref = [
        if (g.referenceAbove != null) 'L${g.referenceAbove! + 1}',
        if (g.referenceBelow != null) 'L${g.referenceBelow! + 1}',
      ].join(' & ');
      geomText = g.structure == LineStructure.microstrip
          ? 'Microstrip on L${s.signalLayer + 1}: h = ${_fmt(g.h1)} to $ref, t = ${_fmt(g.t)}'
          : 'Stripline on L${s.signalLayer + 1}: h1 = ${_fmt(g.h1)}, h2 = ${_fmt(g.h2!)} ($ref), t = ${_fmt(g.t)}';
      if (g.notes.any((n) => n.contains('one side only'))) {
        geomText += '\n⚠ Plane on one side only – modelled as microstrip.';
        geomColor = AppColors.warning;
      }
    } on StackupError catch (e) {
      geomText = '⚠ ${e.message}';
      geomColor = AppColors.critical;
    }
    final signalLayers = [
      for (var i = 0; i < s.layers.length; i++)
        if (s.layers[i].role == LayerRole.signal) i,
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: LabeledDropdown<int>(
            label: 'Layer count (preset)',
            value: s.layerCount,
            items: const [2, 4, 6, 8],
            itemLabel: (n) => '$n layers',
            onChanged: _applyPreset,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: LabeledDropdown<int>(
            label: 'Routed signal layer',
            value: s.signalLayer,
            items: List<int>.generate(s.layers.length, (i) => i),
            enabled: (i) => s.layers[i].role == LayerRole.signal,
            itemLabel: (i) => 'L${i + 1} ${s.layers[i].role.label}',
            onChanged: (i) {
              s.signalLayer = i;
              _changed();
            },
          ),
        ),
      ]),
      const SizedBox(height: 4),
      StackupView(
        stackup: s,
        unit: widget.unit,
        traceWidth: widget.traceWidth,
        traceSpacing: widget.traceSpacing,
        differential: widget.differential,
        height: (60 + s.layers.length * 26).toDouble().clamp(140, 300),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(geomText, style: TextStyle(color: geomColor, fontSize: 12.5)),
      ),
      if (signalLayers.isEmpty)
        const Text('No signal layer: set at least one layer role to Signal.',
            style: TextStyle(color: AppColors.critical, fontSize: 12)),
      FieldRow(children: [
        EngField(
          key: ValueKey('dk$_rev'),
          label: 'Dielectric constant Dk',
          value: s.dk,
          unit: Units.none,
          min: 1,
          max: 15,
          tooltip: 'Relative permittivity of the laminate at the frequency of interest (FR-4 ≈ 4.0–4.5 at 1 GHz).',
          onValidity: (v) => widget.onValidity?.call('dk', v),
          onChanged: (v) {
            s.dk = v;
            _changed();
          },
        ),
        EngField(
          key: ValueKey('df$_rev'),
          label: 'Dissipation factor Df',
          value: s.df,
          unit: Units.none,
          min: 0,
          max: 0.1,
          tooltip: 'Loss tangent tan δ (FR-4 ≈ 0.015–0.025; low-loss laminates 0.002–0.008).',
          onValidity: (v) => widget.onValidity?.call('df', v),
          onChanged: (v) {
            s.df = v;
            _changed();
          },
        ),
      ]),
      EngField(
        key: ValueKey('rq$_rev'),
        label: 'Copper roughness (rms)',
        value: s.roughnessRms,
        unit: const UnitSpec('µm', 1e-6),
        min: 0,
        max: 10e-6,
        decimals: 2,
        tooltip: 'Surface roughness for the conductor-loss correction (Hammerstad-Groiss). '
            'HVLP ≈ 0.3–0.5 µm, VLP ≈ 0.7 µm, standard ED copper ≈ 1–2 µm. 0 = smooth.',
        onValidity: (v) => widget.onValidity?.call('rq', v),
        onChanged: (v) {
          s.roughnessRms = v;
          _changed();
        },
      ),
      TextButton.icon(
        onPressed: () => setState(() => _showLayers = !_showLayers),
        icon: Icon(_showLayers ? Icons.expand_less : Icons.expand_more),
        label: Text(_showLayers ? 'Hide layer details' : 'Edit layers, copper and dielectric thickness'),
      ),
      if (_showLayers) ..._layerEditors(),
    ]);
  }

  String _fmt(double m) => '${formatInput(widget.unit.toDisplay(m), maxDecimals: 2)} ${widget.unit.label} (${mm(m)})';

  List<Widget> _layerEditors() {
    final out = <Widget>[];
    for (var i = 0; i < s.layers.length; i++) {
      final layer = s.layers[i];
      out.add(Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 34,
          child: Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Text('L${i + 1}', style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ),
        Expanded(
          child: LabeledDropdown<LayerRole>(
            label: 'Role',
            value: layer.role,
            items: LayerRole.values,
            itemLabel: (r) => r.label,
            onChanged: (r) {
              layer.role = r;
              if (s.layers[s.signalLayer].role != LayerRole.signal) {
                final firstSig = s.layers.indexWhere((l) => l.role == LayerRole.signal);
                if (firstSig >= 0) s.signalLayer = firstSig;
              }
              _changed();
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: EngField(
            key: ValueKey('cu$i-$_rev'),
            label: 'Copper',
            value: layer.copperThickness,
            unit: Units.oz,
            min: 0.1 * Units.oz.factor,
            max: 6 * Units.oz.factor,
            decimals: 2,
            tooltip: 'Finished copper thickness in oz/ft² (1 oz ≈ 34.8 µm ≈ 1.37 mil). Outer layers include plating.',
            onValidity: (v) => widget.onValidity?.call('cu$i', v),
            onChanged: (v) {
              layer.copperThickness = v;
              _changed();
            },
          ),
        ),
      ]));
      if (i < s.dielectrics.length) {
        out.add(Padding(
          padding: const EdgeInsets.only(left: 34),
          child: EngField(
            key: ValueKey('d$i-${widget.unit.label}-$_rev'),
            label: 'Dielectric L${i + 1}–L${i + 2}',
            value: s.dielectrics[i],
            unit: widget.unit,
            min: 0.01e-3,
            max: 5e-3,
            minExclusive: true,
            decimals: 3,
            tooltip: 'Prepreg/core thickness between the copper surfaces of the two layers.',
            onValidity: (v) => widget.onValidity?.call('d$i', v),
            onChanged: (v) {
              s.dielectrics[i] = v;
              _changed();
            },
          ),
        ));
      }
    }
    out.add(Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text('Total thickness ${_fmt(s.totalThickness)}',
          style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
    ));
    return out;
  }
}
