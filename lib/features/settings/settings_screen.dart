import 'package:flutter/material.dart';

import '../about/about_screen.dart';
import '../library/library_screen.dart';
import '../../core/state/app_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utilities/units.dart';
import '../../data/models/app_settings.dart';
import '../../simulation/engine.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/eng_field.dart';
import '../pcb_stackup/stackup_editor.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings _s;
  final Set<String> _invalid = {};
  bool _dirty = false;
  int _rev = 0;

  @override
  void initState() {
    super.initState();
    _s = widget.controller.settings.copy();
  }

  void _edit(VoidCallback f) => setState(() {
        f();
        _dirty = true;
      });

  void Function(bool) _valid(String k) => (ok) => setState(() => ok ? _invalid.remove(k) : _invalid.add(k));

  Future<void> _save() async {
    await widget.controller.updateSettings(_s);
    if (!mounted) return;
    setState(() => _dirty = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Settings saved. New analyses use the updated defaults.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = _s.thresholds;
    Widget th(String key, String label, double value, ValueChanged<double> set,
            {UnitSpec unit = Units.percent, double max = 100, String? tip}) =>
        EngField(
          key: ValueKey('$key$_rev'),
          label: label,
          value: value,
          unit: unit,
          min: 0,
          max: max,
          tooltip: tip,
          onValidity: _valid(key),
          onChanged: (v) => _edit(() => set(v)),
        );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          TextButton.icon(
            onPressed: _dirty && _invalid.isEmpty ? _save : null,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save'),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        Card(
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: ListTile(
            leading: const Icon(Icons.library_books_outlined),
            title: const Text('Libraries'),
            subtitle: const Text('Reusable stackups, driver presets, IBIS models and S-parameter channels',
                style: TextStyle(fontSize: 12, color: AppColors.textDim)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => LibraryScreen(controller: widget.controller))),
          ),
        ),
        Card(
          margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About SI Studio'),
            subtitle: const Text('Version, limitations, privacy and licences',
                style: TextStyle(fontSize: 12, color: AppColors.textDim)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AboutScreen())),
          ),
        ),
        SectionCard(
          title: 'Units',
          leading: const Icon(Icons.straighten),
          child: Column(children: [
            LabeledDropdown<GeometryUnit>(
              label: 'Trace width, spacing & dielectric',
              value: _s.geometryUnit,
              items: GeometryUnit.values,
              itemLabel: (u) => u.spec.label,
              onChanged: (u) => _edit(() => _s.geometryUnit = u),
            ),
            LabeledDropdown<LengthUnit>(
              label: 'Trace length',
              value: _s.lengthUnit,
              items: LengthUnit.values,
              itemLabel: (u) => u.spec.label,
              onChanged: (u) => _edit(() => _s.lengthUnit = u),
            ),
          ]),
        ),
        SectionCard(
          title: 'Default PCB stackup',
          subtitle: 'Used for every new analysis',
          leading: const Icon(Icons.layers_outlined),
          initiallyExpanded: false,
          child: StackupEditor(
            key: ValueKey('stack$_rev'),
            stackup: _s.defaultStackup,
            unit: _s.geometryUnit.spec,
            onValidity: (k, v) => _valid('st_$k')(v),
            onChanged: () => _edit(() {}),
          ),
        ),
        SectionCard(
          title: 'Analysis thresholds',
          subtitle: 'Explicit limits for Good / Warning / Critical (PRD 8.2)',
          leading: const Icon(Icons.rule),
          initiallyExpanded: false,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Values ≤ Good limit are Good, ≤ Warning limit are Warning, above are Critical. '
                'Eye limits are minimums. USB 2.0 analyses override impedance limits with 10 % / 15 %.',
                style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            FieldRow(children: [
              th('zg', 'Impedance dev. Good', t.impedanceGoodPct, (v) => t.impedanceGoodPct = v),
              th('zw', 'Impedance dev. Warning', t.impedanceWarnPct, (v) => t.impedanceWarnPct = v),
            ]),
            FieldRow(children: [
              th('gg', '|Γ| Good', t.reflectionGood, (v) => t.reflectionGood = v, unit: Units.none, max: 1),
              th('gw', '|Γ| Warning', t.reflectionWarn, (v) => t.reflectionWarn = v, unit: Units.none, max: 1),
            ]),
            FieldRow(children: [
              th('og', 'Overshoot Good', t.overshootGoodPct, (v) => t.overshootGoodPct = v),
              th('ow', 'Overshoot Warning', t.overshootWarnPct, (v) => t.overshootWarnPct = v),
            ]),
            th('rb', 'Ring-back warning margin (% VDD)', t.ringbackWarnPctVdd, (v) => t.ringbackWarnPctVdd = v,
                tip: 'Ring-back closer than this to VIH/VIL is a Warning; re-entering the threshold band is Critical.'),
            FieldRow(children: [
              th('sg', 'Skew Good (% UI)', t.skewGoodPctUi, (v) => t.skewGoodPctUi = v),
              th('sw', 'Skew Warning (% UI)', t.skewWarnPctUi, (v) => t.skewWarnPctUi = v),
            ]),
            th('tm', 'Timing slack warning (% SCLK period)', t.timingWarnPctPeriod, (v) => t.timingWarnPctPeriod = v,
                tip: 'Setup/hold slack below this is a Warning; negative slack is Critical.'),
            FieldRow(children: [
              th('ehg', 'Eye height Good (≥ % ideal)', t.eyeHeightGoodPct, (v) => t.eyeHeightGoodPct = v),
              th('ehw', 'Eye height Warning (≥ %)', t.eyeHeightWarnPct, (v) => t.eyeHeightWarnPct = v),
            ]),
            FieldRow(children: [
              th('ewg', 'Eye width Good (≥ % UI)', t.eyeWidthGoodPctUi, (v) => t.eyeWidthGoodPctUi = v),
              th('eww', 'Eye width Warning (≥ % UI)', t.eyeWidthWarnPctUi, (v) => t.eyeWidthWarnPctUi = v),
            ]),
            FieldRow(children: [
              th('xtg', 'Crosstalk Good (% swing)', t.xtalkGoodPct, (v) => t.xtalkGoodPct = v),
              th('xtw', 'Crosstalk Warning (% swing)', t.xtalkWarnPct, (v) => t.xtalkWarnPct = v),
            ]),
            FieldRow(children: [
              th('ilg', 'Line loss Good', t.lossGoodDb, (v) => t.lossGoodDb = v, unit: Units.db, max: 60),
              th('ilw', 'Line loss Warning', t.lossWarnDb, (v) => t.lossWarnDb = v, unit: Units.db, max: 60),
            ]),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => _edit(() {
                  _s.thresholds = SiThresholds();
                  _rev++;
                }),
                child: const Text('Restore default thresholds'),
              ),
            ),
          ]),
        ),
        const SectionCard(
          title: 'About the simulation model',
          leading: Icon(Icons.info_outline),
          initiallyExpanded: false,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            KeyValue('Model version', simulationModelVersion),
            KeyValue('Microstrip Z0', 'Hammerstad–Jensen (thickness-corrected)'),
            KeyValue('Stripline Z0', 'Wheeler; offset: parallel combination'),
            KeyValue('Differential Z', 'IPC-2141 coupling approximation'),
            KeyValue('Time domain', 'Method of characteristics (Branin) with trapezoidal C'),
            KeyValue('Loss', 'Skin effect (+ Hammerstad-Groiss roughness) + dielectric, causal minimum-phase'),
            KeyValue('SerDes EQ', 'TX 3-tap FIR / PCIe presets, behavioural CTLE, ideal-decision DFE'),
            KeyValue('Animation', 'v(x,t) rebuilt from simulated incident/reflected waves'),
            KeyValue('Level 3', 'IBIS buffers (V-I + ramp), Touchstone channels, coupled-line crosstalk, vias / AC caps / connectors, eye mask & bathtub'),
            KeyValue('Diff. impedance', 'Kirschning-Jansen (microstrip) / Cohn (stripline) coupled lines'),
            KeyValue('Not modelled', 'IBIS-AMI, V-T waveform tables, package RLC, full-wave via fields'),
            SizedBox(height: 8),
            Text('Results are preliminary and do not imply protocol compliance.',
                style: TextStyle(color: AppColors.warning, fontSize: 12)),
          ]),
        ),
      ]),
    );
  }
}
