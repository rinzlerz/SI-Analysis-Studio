import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utilities/units.dart';
import '../../simulation/common/format.dart';
import '../../simulation/model/config.dart';
import '../../simulation/waveform_engine/channel_builder.dart';
import '../../shared/widgets/eng_field.dart';

/// Editor for discontinuities along the route (vias, AC caps, connector /
/// package segments, shunt capacitance) – PRD Phase 3.
class ChannelElementsEditor extends StatelessWidget {
  const ChannelElementsEditor({
    super.key,
    required this.pcb,
    required this.geometryUnit,
    required this.lengthUnit,
    required this.differential,
    required this.onChanged,
  });

  final PcbConfig pcb;
  final UnitSpec geometryUnit;
  final UnitSpec lengthUnit;
  final bool differential;
  final VoidCallback onChanged;

  String _summary(ChannelElement e) {
    final at = '@ ${formatInput(lengthUnit.toDisplay(e.position), maxDecimals: 2)} ${lengthUnit.label}';
    return switch (e.type) {
      ChannelElementType.via => () {
          final v = viaParams(e, pcb.stackup.dk);
          return 'Via $at · C ${eng(v.c, 'F')} · L ${eng(v.l, 'H')} · stub ${mm(e.stubLength)}'
              '${v.stubResonance.isFinite ? ' (f₀ ${eng(v.stubResonance, 'Hz')})' : ''}';
        }(),
      ChannelElementType.acCap => 'AC cap $at · ${eng(e.capacitance, 'F')} · ESL ${eng(e.esl, 'H')}',
      ChannelElementType.segment => 'Segment $at · ${ohm(e.z)}${differential ? ' diff' : ''} · ${secs(e.delay)}',
      ChannelElementType.shuntCap => 'Shunt C $at · ${eng(e.capacitance, 'F')}',
    };
  }

  IconData _icon(ChannelElementType t) => switch (t) {
        ChannelElementType.via => Icons.radio_button_checked,
        ChannelElementType.acCap => Icons.battery_charging_full,
        ChannelElementType.segment => Icons.cable,
        ChannelElementType.shuntCap => Icons.shield_outlined,
      };

  Future<void> _edit(BuildContext context, ChannelElement? existing) async {
    var type = existing?.type;
    if (type == null) {
      type = await showModalBottomSheet<ChannelElementType>(
        context: context,
        backgroundColor: AppColors.surface,
        builder: (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final t in ChannelElementType.values)
              ListTile(leading: Icon(_icon(t)), title: Text(t.label), onTap: () => Navigator.pop(ctx, t)),
          ]),
        ),
      );
      if (type == null) return;
    }
    if (!context.mounted) return;
    final draft = existing?.copy() ??
        ChannelElement(
          type: type,
          position: pcb.traceLength / 2,
          z: differential ? 90 : 50,
          capacitance: type == ChannelElementType.shuntCap ? 0.5e-12 : 100e-9,
        );
    final saved = await showModalBottomSheet<ChannelElement>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      builder: (ctx) => _ElementSheet(
        element: draft,
        geometryUnit: geometryUnit,
        lengthUnit: lengthUnit,
        maxPosition: pcb.traceLength,
        differential: differential,
      ),
    );
    if (saved == null) return;
    if (existing == null) {
      pcb.elements.add(saved);
    } else {
      final i = pcb.elements.indexOf(existing);
      if (i >= 0) pcb.elements[i] = saved;
    }
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final els = [...pcb.elements]..sort((a, b) => a.position.compareTo(b.position));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const Expanded(
          child: Text('Channel discontinuities (L3)',
              style: TextStyle(color: AppColors.textDim, fontWeight: FontWeight.w600)),
        ),
        TextButton.icon(onPressed: () => _edit(context, null), icon: const Icon(Icons.add), label: const Text('Add')),
      ]),
      if (els.isEmpty)
        const Text('Plain trace. Add vias, AC-coupling caps, connector/package segments or ESD/test-pad capacitance.',
            style: TextStyle(color: AppColors.textDim, fontSize: 12)),
      for (final e in els)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(_icon(e.type), size: 20, color: AppColors.accent),
          title: Text(_summary(e), style: const TextStyle(fontSize: 12.5)),
          onTap: () => _edit(context, e),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            onPressed: () {
              pcb.elements.remove(e);
              onChanged();
            },
          ),
        ),
    ]);
  }
}

class _ElementSheet extends StatefulWidget {
  const _ElementSheet({
    required this.element,
    required this.geometryUnit,
    required this.lengthUnit,
    required this.maxPosition,
    required this.differential,
  });

  final ChannelElement element;
  final UnitSpec geometryUnit;
  final UnitSpec lengthUnit;
  final double maxPosition;
  final bool differential;

  @override
  State<_ElementSheet> createState() => _ElementSheetState();
}

class _ElementSheetState extends State<_ElementSheet> {
  final _invalid = <String>{};
  ChannelElement get e => widget.element;

  void Function(bool) _v(String k) => (ok) => setState(() => ok ? _invalid.remove(k) : _invalid.add(k));

  @override
  Widget build(BuildContext context) {
    final gu = widget.geometryUnit;
    final fields = <Widget>[
      EngField(
        label: 'Position from TX pin',
        value: e.position,
        unit: widget.lengthUnit,
        min: 0,
        max: widget.maxPosition,
        decimals: 3,
        onValidity: _v('pos'),
        onChanged: (v) => setState(() => e.position = v),
      ),
      ...switch (e.type) {
        ChannelElementType.via => [
            FieldRow(children: [
              EngField(label: 'Drill Ø', value: e.drill, unit: gu, min: 0.05e-3, max: 2e-3, decimals: 3,
                  onValidity: _v('d'), onChanged: (v) => setState(() => e.drill = v)),
              EngField(label: 'Pad Ø', value: e.pad, unit: gu, min: 0.1e-3, max: 3e-3, decimals: 3,
                  onValidity: _v('p'), onChanged: (v) => setState(() => e.pad = v)),
              EngField(label: 'Antipad Ø', value: e.antipad, unit: gu, min: 0.15e-3, max: 5e-3, decimals: 3,
                  onValidity: _v('a'), onChanged: (v) => setState(() => e.antipad = v)),
            ]),
            FieldRow(children: [
              EngField(
                  label: 'Barrel length (layer span)',
                  value: e.barrelLength,
                  unit: gu,
                  min: 0.02e-3,
                  max: 10e-3,
                  decimals: 3,
                  tooltip: 'Distance between the two routed layers.',
                  onValidity: _v('b'),
                  onChanged: (v) => setState(() => e.barrelLength = v)),
              EngField(
                  label: 'Unused stub length',
                  value: e.stubLength,
                  unit: gu,
                  min: 0,
                  max: 10e-3,
                  decimals: 3,
                  tooltip: 'Barrel beyond the exit layer; 0 for back-drilled, blind or buried vias.',
                  onValidity: _v('s'),
                  onChanged: (v) => setState(() => e.stubLength = v)),
            ]),
          ],
        ChannelElementType.acCap => [
            FieldRow(children: [
              EngField(label: 'Capacitance', value: e.capacitance, unit: const UnitSpec('nF', 1e-9), min: 1e-9, max: 10e-6,
                  onValidity: _v('c'), onChanged: (v) => setState(() => e.capacitance = v)),
              EngField(label: 'ESL', value: e.esl, unit: const UnitSpec('nH', 1e-9), min: 0, max: 5e-9,
                  onValidity: _v('l'), onChanged: (v) => setState(() => e.esl = v)),
              EngField(label: 'Pad capacitance', value: e.padCap, unit: Units.pf, min: 0, max: 5e-12,
                  onValidity: _v('pc'), onChanged: (v) => setState(() => e.padCap = v)),
            ]),
          ],
        ChannelElementType.segment => [
            FieldRow(children: [
              EngField(
                  label: widget.differential ? 'Differential impedance' : 'Impedance',
                  value: e.z,
                  unit: Units.ohm,
                  min: 10,
                  max: 200,
                  onValidity: _v('z'),
                  onChanged: (v) => setState(() => e.z = v)),
              EngField(
                  label: 'One-way delay',
                  value: e.delay,
                  unit: Units.ps,
                  min: 1e-12,
                  max: 5e-9,
                  tooltip: 'Electrical length of the connector, package trace or cable segment.',
                  onValidity: _v('t'),
                  onChanged: (v) => setState(() => e.delay = v)),
            ]),
          ],
        ChannelElementType.shuntCap => [
            EngField(
                label: 'Capacitance to ground',
                value: e.capacitance,
                unit: Units.pf,
                min: 1e-15,
                max: 1e-9,
                tooltip: 'ESD diode, test pad or connector pin capacitance.',
                onValidity: _v('c'),
                onChanged: (v) => setState(() => e.capacitance = v)),
          ],
      },
    ];
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(e.type.label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ...fields,
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _invalid.isEmpty ? () => Navigator.pop(context, e) : null,
            child: const Text('Save'),
          ),
        ]),
      ),
    );
  }
}
