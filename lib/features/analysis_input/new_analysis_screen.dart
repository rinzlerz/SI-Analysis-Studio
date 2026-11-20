import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/state/app_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utilities/units.dart';
import '../../simulation/common/format.dart';
import '../../simulation/engine.dart';
import '../../simulation/equalization/equalization.dart';
import '../../simulation/impedance/impedance.dart';
import '../../simulation/model/bus_lengths.dart';
import '../../simulation/transmission_line/line_params.dart';
import '../../simulation/waveform_engine/stimulus.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/eng_field.dart';
import '../analysis_results/results_screen.dart';
import '../pcb_stackup/stackup_editor.dart';
import '../../shared/files/file_loader.dart';
import '../../simulation/ibis/ibis.dart';
import '../../simulation/sparams/touchstone.dart';
import 'channel_editor.dart';
import '../../data/models/library_item.dart';
import '../../shared/widgets/dialogs.dart';
import '../../shared/share_actions.dart';
import '../guidelines/guidelines_screen.dart';
import '../integration/integration_dialogs.dart';

/// PRD 9.3 – guided configuration in expandable sections A–F.
class NewAnalysisScreen extends StatefulWidget {
  const NewAnalysisScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<NewAnalysisScreen> createState() => _NewAnalysisScreenState();
}

class _NewAnalysisScreenState extends State<NewAnalysisScreen> {
  final Set<String> _invalid = {};
  int _seenRevision = -1;
  late final TextEditingController _patternCtrl;
  String? _patternError;
  List<IbisModel> _ibisModels = [];
  String? _spText;

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _loadTouchstone() async {
    try {
      final f = await pickTextFile(['s2p', 's4p']);
      if (f == null) return;
      final ports = f.name.toLowerCase().endsWith('.s4p') ? 4 : 2;
      final mapping = cfg.serdes.sparams?.mapping ?? PortMapping.inOut12_34;
      final sp = parseTouchstone(f.text, ports: ports, name: f.name, mapping: mapping);
      _spText = f.text;
      _set(() {
        cfg.serdes.sparams = sp;
        cfg.serdes.useTouchstone = true;
      });
      _snack('Loaded ${f.name}: ${sp.freq.length} points up to ${eng(sp.fMax, 'Hz')}.');
    } on TouchstoneError catch (e) {
      _snack('Touchstone error: ${e.message}');
    } on FormatException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('Could not load file: $e');
    }
  }

  void _setMapping(PortMapping m) {
    final sp = cfg.serdes.sparams;
    if (sp == null || sp.ports != 4) return;
    if (_spText == null) {
      _snack('Reload the .s4p file to apply a different port mapping.');
      return;
    }
    _set(() => cfg.serdes.sparams = parseTouchstone(_spText!, ports: 4, name: sp.name, mapping: m));
  }

  Future<void> _loadIbis() async {
    try {
      final f = await pickTextFile(['ibs']);
      if (f == null) return;
      final models = parseIbis(f.text, file: f.name);
      final drivers = models.where((m) => m.canDrive).toList();
      if (drivers.isEmpty) {
        _snack('No driver model ([Pullup]/[Pulldown]/[Ramp]) found in ${f.name}.');
        return;
      }
      _ibisModels = models;
      _set(() {
        cfg.spiCfg.useIbis = true;
        cfg.spiCfg.ibisDriver = drivers.first;
        cfg.spiCfg.ibisReceiver = models.firstWhere((m) => m.isInput, orElse: () => models.first);
      });
      _snack('Loaded ${models.length} model(s) from ${f.name}.');
    } on IbisError catch (e) {
      _snack('IBIS error: ${e.message}');
    } on FormatException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('Could not load file: $e');
    }
  }

  AppController get c => widget.controller;
  AnalysisConfig get cfg => c.draft;

  @override
  void initState() {
    super.initState();
    _patternCtrl = TextEditingController(text: cfg.sim.customPattern);
  }

  @override
  void dispose() {
    _patternCtrl.dispose();
    super.dispose();
  }

  void Function(bool) _valid(String key) => (ok) => setState(() {
        if (ok) {
          _invalid.remove(key);
        } else {
          _invalid.add(key);
        }
      });

  void _set(VoidCallback f) {
    setState(f);
    c.touch();
  }

  Key _k(String name) => ValueKey('${c.draftRevision}-$name');

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (_seenRevision != c.draftRevision) {
          _seenRevision = c.draftRevision;
          _invalid.clear();
          _patternCtrl.text = cfg.sim.customPattern;
          _patternError = null;
        }
        final warnings = validateConfig(cfg).where((i) => !i.blocking).toList();
        return Scaffold(
          appBar: AppBar(
            title: Text(c.draftName == null ? 'New Analysis' : 'Edit: ${c.draftName}', overflow: TextOverflow.ellipsis),
            actions: [
              PopupMenuButton<String>(
                tooltip: 'Tools',
                icon: const Icon(Icons.more_vert),
                onSelected: (v) async {
                  switch (v) {
                    case 'kicad':
                      await importFromKicad(context, c);
                    case 'sweep':
                      await startSweep(context, c);
                    case 'link':
                      await shareAnalysis(context, cfg, name: c.draftName);
                    case 'guide':
                      await Navigator.of(context)
                          .push(MaterialPageRoute<void>(builder: (_) => GuidelinesScreen(controller: c)));
                    case 'reset':
                      await _confirmReset();
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'guide',
                    child: ListTile(
                      leading: Icon(Icons.route),
                      title: Text('Layout guidelines'),
                      subtitle: Text('Routing limits for this stackup'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'kicad',
                    child: ListTile(
                      leading: Icon(Icons.developer_board),
                      title: Text('Import from KiCad'),
                      subtitle: Text('Stackup + net length, width and vias'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'sweep',
                    child: ListTile(
                      leading: Icon(Icons.stacked_line_chart),
                      title: Text('Parameter sweep'),
                      subtitle: Text('Compare several values of one input'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'link',
                    child: ListTile(
                      leading: Icon(Icons.link),
                      title: Text('Share these inputs'),
                      subtitle: Text('Link that opens this analysis for anyone'),
                    ),
                  ),
                  PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'reset',
                    child: ListTile(leading: Icon(Icons.restart_alt), title: Text('Reset to defaults')),
                  ),
                ],
              ),
            ],
          ),
          bottomNavigationBar: _runBar(warnings),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              _protocolSection(),
              _protocolConfigSection(),
              _pcbSection(),
              _driverSection(),
              _simSection(),
              if (warnings.isNotEmpty) _warningsCard(warnings),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------- A
  Widget _protocolSection() {
    return SectionCard(
      title: 'A · Protocol',
      subtitle: cfg.protocol.label,
      leading: const Icon(Icons.settings_input_component_outlined),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _groupLabel('High-speed serial (differential)'),
        for (final p in Protocol.values.where((p) => p.differential)) _protocolRow(p),
        _groupLabel('Board-level buses (single-ended)'),
        for (final p in Protocol.values.where((p) => !p.differential)) _protocolRow(p),
      ]),
    );
  }

  Widget _groupLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 8, 2, 4),
        child: Text(text.toUpperCase(),
            style: const TextStyle(color: AppColors.textDim, fontSize: 11, letterSpacing: 1.1, fontWeight: FontWeight.w600)),
      );

  Widget _protocolRow(Protocol p) {
    final selected = cfg.protocol == p;
    final tag = p.tag;
    final desc = p.description;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: selected ? AppColors.accent.withValues(alpha: 0.12) : AppColors.surfaceHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: selected ? AppColors.accent : AppColors.outline, width: selected ? 1.5 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: selected ? null : () => c.setProtocol(p),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              Container(
                width: 54,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? AppColors.accent : AppColors.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: selected ? AppColors.accent : AppColors.outline),
                ),
                child: Text(tag,
                    style: TextStyle(
                      fontSize: tag.length > 4 ? 11 : 12,
                      fontWeight: FontWeight.w800,
                      color: selected ? Colors.black : AppColors.textDim,
                    )),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                        color: selected ? AppColors.accent : AppColors.text,
                      )),
                  const SizedBox(height: 2),
                  Text(desc, style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
                ]),
              ),
              const SizedBox(width: 8),
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: selected ? AppColors.accent : AppColors.textDim,
              ),
            ]),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- B
  Widget _protocolConfigSection() {
    return SectionCard(
      title: 'B · Protocol configuration',
      subtitle: cfg.protocolDetail,
      leading: const Icon(Icons.tune),
      child: switch (cfg.protocol) {
        Protocol.spi || Protocol.qspi => _spiConfig(),
        Protocol.i2c => _i2cConfig(),
        Protocol.rgmii => _rgmiiConfig(),
        Protocol.usb2 => _usbConfig(),
        Protocol.usb3 || Protocol.pcie || Protocol.hdmi => _serdesConfig(),
      },
    );
  }

  Widget _spiConfig() {
    final p = cfg.spiCfg;
    final isQ = cfg.protocol == Protocol.qspi;
    final presetV = [1.8, 3.3].contains(p.voltage) ? p.voltage : -1.0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (isQ) ..._qspiExtras(p),
      FieldRow(children: [
        EngField(
          key: _k('clk'),
          label: isQ ? 'Clock frequency' : 'SCLK frequency',
          value: p.clockHz,
          unit: Units.mhz,
          min: 1e3,
          max: 200e6,
          tooltip: isQ
              ? 'Flash clock. SDR: one bit per clock per IO; DTR: one bit per edge.'
              : 'Serial clock frequency. The data window is half a clock period.',
          onValidity: _valid('clk'),
          onChanged: (v) => _set(() => p.clockHz = v),
        ),
        LabeledDropdown<int>(
          label: 'SPI mode (CPOL/CPHA)',
          value: p.mode,
          items: const [0, 1, 2, 3],
          itemLabel: (m) => 'Mode $m (CPOL ${m >> 1}, CPHA ${m & 1})',
          onChanged: (m) => _set(() => p.mode = m),
        ),
      ]),
      FieldRow(children: [
        LabeledDropdown<double>(
          label: 'Signal voltage',
          value: presetV,
          items: const [1.8, 3.3, -1.0],
          itemLabel: (v) => v < 0 ? 'Custom' : '$v V',
          onChanged: (v) => _set(() {
            if (v > 0) {
              p.voltage = v;
            } else if ([1.8, 3.3].contains(p.voltage)) {
              p.voltage = 2.5;
            }
          }),
        ),
        EngField(
          key: _k('vdd'),
          label: 'VDD',
          value: p.voltage,
          unit: Units.volt,
          min: 0.5,
          max: 5.5,
          enabled: presetV < 0,
          onValidity: _valid('vdd'),
          onChanged: (v) => _set(() => p.voltage = v),
        ),
      ]),
      FieldRow(children: [
        EngField(
          key: _k('tr'),
          label: 'Rise time (10–90 %)',
          value: p.riseTime,
          unit: Units.ns,
          min: 10e-12,
          max: 1e-6,
          tooltip: 'Driver output edge rate. Faster edges make shorter traces behave as transmission lines.',
          onValidity: _valid('tr'),
          onChanged: (v) => _set(() => p.riseTime = v),
        ),
        EngField(
          key: _k('tf'),
          label: 'Fall time (90–10 %)',
          value: p.fallTime,
          unit: Units.ns,
          min: 10e-12,
          max: 1e-6,
          onValidity: _valid('tf'),
          onChanged: (v) => _set(() => p.fallTime = v),
        ),
      ]),
      EngField(
        key: _k('z0t'),
        label: 'Target impedance Z0',
        value: p.targetZ0,
        unit: Units.ohm,
        min: 10,
        max: 150,
        tooltip: 'Single-ended impedance target for the routing (typically 50 Ω).',
        onValidity: _valid('z0t'),
        onChanged: (v) => _set(() => p.targetZ0 = v),
      ),
      const Padding(
        padding: EdgeInsets.only(top: 8, bottom: 2),
        child: Text('Device timing', style: TextStyle(color: AppColors.textDim, fontWeight: FontWeight.w600)),
      ),
      FieldRow(children: [
        EngField(
          key: _k('tco'),
          label: isQ ? 'Flash clock-to-output tV' : 'Peripheral tCO (MISO)',
          value: p.slaveTco,
          unit: Units.ns,
          min: 0,
          max: 1e-6,
          tooltip: 'Clock-to-output delay of the peripheral: SCLK edge at its pin to MISO valid. From the device datasheet.',
          onValidity: _valid('tco'),
          onChanged: (v) => _set(() => p.slaveTco = v),
        ),
        EngField(
          key: _k('tsu'),
          label: 'Input setup time',
          value: p.setupTime,
          unit: Units.ns,
          min: 0,
          max: 1e-6,
          tooltip: 'Receiver setup requirement (applied at both controller and peripheral).',
          onValidity: _valid('tsu'),
          onChanged: (v) => _set(() => p.setupTime = v),
        ),
        EngField(
          key: _k('th'),
          label: 'Input hold time',
          value: p.holdTime,
          unit: Units.ns,
          min: 0,
          max: 1e-6,
          onValidity: _valid('th'),
          onChanged: (v) => _set(() => p.holdTime = v),
        ),
      ]),
      FieldRow(children: [
        EngField(
          key: _k('vih'),
          label: 'VIH',
          value: p.vihFraction * 100,
          unit: const UnitSpec('% VDD', 1),
          min: 1,
          max: 99,
          tooltip: 'Input-high threshold as a percentage of VDD (CMOS typically 70 %).',
          onValidity: _valid('vih'),
          onChanged: (v) => _set(() => p.vihFraction = v / 100),
        ),
        EngField(
          key: _k('vil'),
          label: 'VIL',
          value: p.vilFraction * 100,
          unit: const UnitSpec('% VDD', 1),
          min: 1,
          max: 99,
          tooltip: 'Input-low threshold as a percentage of VDD (CMOS typically 30 %).',
          onValidity: _valid('vil'),
          onChanged: (v) => _set(() => p.vilFraction = v / 100),
        ),
      ]),
    ]);
  }

  // ---------------------------------------------------------------- QSPI
  List<Widget> _qspiExtras(SpiConfig p) {
    final lu = c.settings.lengthUnit.spec;
    return [
      FieldRow(children: [
        LabeledDropdown<int>(
          label: 'Bus width',
          value: p.ioWidth,
          items: const [4, 8],
          itemLabel: (w) => w == 8 ? 'Octal (x8)' : 'Quad (x4)',
          onChanged: (w) => _set(() => p.ioWidth = w),
        ),
        LabeledDropdown<bool>(
          label: 'Transfer mode',
          value: p.dtr,
          items: const [false, true],
          itemLabel: (d) => d ? 'DTR (both edges)' : 'SDR (one edge)',
          onChanged: (d) => _set(() {
            p.dtr = d;
            if (d) {
              // DTR devices specify sub-ns input setup / hold.
              p.setupTime = p.setupTime > 1e-9 ? 0.6e-9 : p.setupTime;
              p.holdTime = p.holdTime > 1e-9 ? 0.6e-9 : p.holdTime;
            } else {
              p.useDqs = false;
            }
            c.draftRevision++;
          }),
        ),
      ]),
      if (p.dtr)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Read data strobe (DQS)'),
          subtitle: const Text('Octal DDR flash: reads are captured with the flash DQS instead of the controller clock',
              style: TextStyle(fontSize: 12, color: AppColors.textDim)),
          value: p.useDqs,
          onChanged: (v) => _set(() => p.useDqs = v),
        ),
      FieldRow(children: [
        if (!p.perSignalLengths)
        EngField(
          key: _k('dcm-${c.settings.lengthUnit.name}'),
          label: 'IO length − CLK length',
          value: p.dataClockMismatch,
          unit: lu,
          min: -0.5,
          max: 0.5,
          decimals: 3,
          tooltip: 'Positive when the IO traces are longer than the clock. Affects write setup/hold and read timing.',
          onValidity: _valid('dcm'),
          onChanged: (v) => _set(() => p.dataClockMismatch = v),
        ),
        EngField(
          key: _k('rsd'),
          label: p.useDqs && p.dtr ? 'DQS capture adjust' : 'Read sample delay',
          value: p.readSampleDelay,
          unit: Units.ns,
          min: 0,
          max: 50e-9,
          decimals: 3,
          tooltip: 'Controller read capture delay after the nominal sampling edge (often called sample delay, '
              'read capture delay or dummy-cycle fine tuning). The results recommend a value.',
          onValidity: _valid('rsd'),
          onChanged: (v) => _set(() => p.readSampleDelay = v),
        ),
      ]),
      const Divider(height: 18),
    ];
  }

  // ---------------------------------------------------------------- I2C
  Widget _i2cConfig() {
    final p = cfg.i2c;
    double? cTrace;
    try {
      final g = geometryFromStackup(cfg.pcb.stackup);
      final imp = computeImpedance(g, cfg.pcb.traceWidth);
      cTrace = math.sqrt(imp.eeff) / 299792458.0 / imp.z0 * cfg.pcb.traceLength;
    } catch (_) {}
    final cb = cTrace == null ? null : cTrace + p.deviceCount * p.pinCap + p.extraCap;
    final volMax = p.voltage > 2 ? 0.4 : 0.2 * p.voltage;
    final rpMin = (p.voltage - volMax) / p.sinkCurrent;
    final rpMax = cb == null ? null : p.mode.trMax / (0.8473 * cb);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LabeledDropdown<I2cMode>(
        label: 'Speed mode',
        value: p.mode,
        items: I2cMode.values,
        itemLabel: (m) => m.label,
        onChanged: (m) => _set(() {
          p.mode = m;
          p.applyModeDefaults();
          c.draftRevision++;
        }),
      ),
      FieldRow(children: [
        EngField(
          key: _k('i2cf'),
          label: 'SCL frequency',
          value: p.clockHz,
          unit: Units.khz,
          min: 1e3,
          max: 1e6,
          tooltip: 'Maximum ${eng(p.mode.fMax, 'Hz')} in ${p.mode.label}.',
          onValidity: _valid('i2cf'),
          onChanged: (v) => _set(() => p.clockHz = v),
        ),
        EngField(
          key: _k('i2cv'),
          label: 'Bus voltage VDD',
          value: p.voltage,
          unit: Units.volt,
          min: 1.0,
          max: 5.5,
          onValidity: _valid('i2cv'),
          onChanged: (v) => _set(() => p.voltage = v),
        ),
      ]),
      const Padding(
        padding: EdgeInsets.only(top: 8, bottom: 2),
        child: Text('Bus loading', style: TextStyle(color: AppColors.textDim, fontWeight: FontWeight.w600)),
      ),
      FieldRow(children: [
        EngField(
          key: _k('i2cn'),
          label: 'Devices on the bus',
          value: p.deviceCount.toDouble(),
          unit: Units.none,
          integer: true,
          min: 2,
          max: 127,
          tooltip: 'Including the controller.',
          onValidity: _valid('i2cn'),
          onChanged: (v) => _set(() => p.deviceCount = v.round()),
        ),
        EngField(
          key: _k('i2ccp'),
          label: 'Capacitance per pin',
          value: p.pinCap,
          unit: Units.pf,
          min: 0,
          max: 50e-12,
          tooltip: 'From the device data sheets (C_I/O); the I²C specification allows up to 10 pF.',
          onValidity: _valid('i2ccp'),
          onChanged: (v) => _set(() => p.pinCap = v),
        ),
        EngField(
          key: _k('i2ccx'),
          label: 'Other capacitance',
          value: p.extraCap,
          unit: Units.pf,
          min: 0,
          max: 5e-9,
          tooltip: 'Connectors, cables, ESD protection, test points.',
          onValidity: _valid('i2ccx'),
          onChanged: (v) => _set(() => p.extraCap = v),
        ),
      ]),
      EngField(
        key: _k('i2cduty'),
        label: 'SCL low time (% of period)',
        value: p.sclLowFraction * 100,
        unit: Units.percent,
        min: 30,
        max: 70,
        decimals: 1,
        tooltip: 'Controller SCL duty cycle. Fast-mode needs tLOW ≥ 1.3 µs, so 400 kHz controllers use ≈ 55–60 % low.',
        onValidity: _valid('i2cduty'),
        onChanged: (v) => _set(() => p.sclLowFraction = v / 100),
      ),
      Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          KeyValue('Bus capacitance Cb', cb == null ? '—' : '${eng(cb, 'F')} of ${eng(p.mode.cbMax, 'F')} max'),
          KeyValue('Allowed pull-up', rpMax == null ? '—' : (rpMin <= rpMax ? '${ohm(rpMin)} – ${ohm(rpMax)}' : 'none (bus too heavy)')),
          KeyValue('Spec limits', 'tr ≤ ${secs(p.mode.trMax)} · tf ≤ ${secs(p.mode.tfMax)} · '
              'tLOW ≥ ${secs(p.mode.tLowMin)} · tHIGH ≥ ${secs(p.mode.tHighMin)}'),
        ]),
      ),
    ]);
  }

  Widget _i2cDriver() {
    final p = cfg.i2c;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      FieldRow(children: [
        EngField(
          key: _k('i2crp'),
          label: 'Pull-up resistor',
          value: p.pullupR,
          unit: Units.kohm,
          min: 50,
          max: 1e6,
          decimals: 3,
          tooltip: 'One pull-up per line (SCL and SDA). Section B shows the allowed range.',
          onValidity: _valid('i2crp'),
          onChanged: (v) => _set(() => p.pullupR = v),
        ),
        LabeledDropdown<bool>(
          label: 'Pull-up location',
          value: p.pullupAtTarget,
          items: const [false, true],
          itemLabel: (far) => far ? 'At the far target' : 'At the controller',
          onChanged: (far) => _set(() => p.pullupAtTarget = far),
        ),
      ]),
      FieldRow(children: [
        EngField(
          key: _k('i2ciol'),
          label: 'Driver sink current at 0.4 V',
          value: p.sinkCurrent,
          unit: Units.ma,
          min: 0.5e-3,
          max: 100e-3,
          decimals: 2,
          tooltip: 'I²C devices guarantee 3 mA (Standard/Fast) or 20 mA (Fast-mode Plus). Sets the on-resistance.',
          onValidity: _valid('i2ciol'),
          onChanged: (v) => _set(() => p.sinkCurrent = v),
        ),
        EngField(
          key: _k('i2ctf'),
          label: 'Driver fall ramp',
          value: p.driverFallTime,
          unit: Units.ns,
          min: 1e-9,
          max: 1e-6,
          tooltip: 'Output slope control (VDD → 0). The 70–30 % fall time is about 0.4 × this ramp.',
          onValidity: _valid('i2ctf'),
          onChanged: (v) => _set(() => p.driverFallTime = v),
        ),
      ]),
      EngField(
        key: _k('i2crs'),
        label: 'Series resistor at the controller (optional)',
        value: p.seriesR,
        unit: Units.ohm,
        min: 0,
        max: 1000,
        tooltip: 'Some designs add 33–300 Ω series resistors for protection or to damp ringing. 0 = none.',
        onValidity: _valid('i2crs'),
        onChanged: (v) => _set(() => p.seriesR = v),
      ),
    ]);
  }

  // ---------------------------------------------------------------- RGMII
  Widget _rgmiiConfig() {
    final p = cfg.rgmii;
    final lu = c.settings.lengthUnit.spec;
    String delayLabel(double d) => d == 0 ? 'Off' : (d == 2e-9 ? 'Internal 2 ns (RGMII-ID)' : 'Custom ${secs(d)}');
    List<double> delayItems(double d) => [0.0, 2e-9, if (d != 0 && d != 2e-9) d];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      FieldRow(children: [
        LabeledDropdown<RgmiiSpeed>(
          label: 'Link speed',
          value: p.speed,
          items: RgmiiSpeed.values,
          itemLabel: (s) => s.label,
          onChanged: (s) => _set(() => p.speed = s),
        ),
        LabeledDropdown<double>(
          label: 'I/O voltage',
          value: [1.8, 2.5, 3.3].contains(p.voltage) ? p.voltage : 2.5,
          items: const [1.8, 2.5, 3.3],
          itemLabel: (v) => '$v V',
          onChanged: (v) => _set(() => p.voltage = v),
        ),
      ]),
      const Padding(
        padding: EdgeInsets.only(top: 8, bottom: 2),
        child: Text('Clock delay (the key RGMII setting)', style: TextStyle(color: AppColors.textDim, fontWeight: FontWeight.w600)),
      ),
      FieldRow(children: [
        LabeledDropdown<double>(
          label: 'TX clock delay (MAC TX or PHY TX)',
          value: p.txClockDelay,
          items: delayItems(p.txClockDelay),
          itemLabel: delayLabel,
          onChanged: (v) => _set(() {
            p.txClockDelay = v;
            c.draftRevision++;
          }),
        ),
        LabeledDropdown<double>(
          label: 'RX clock delay (PHY RX or MAC RX)',
          value: p.rxClockDelay,
          items: delayItems(p.rxClockDelay),
          itemLabel: delayLabel,
          onChanged: (v) => _set(() {
            p.rxClockDelay = v;
            c.draftRevision++;
          }),
        ),
      ]),
      FieldRow(children: [
        EngField(
          key: _k('rgtxd'),
          label: 'TX delay (custom)',
          value: p.txClockDelay,
          unit: Units.ns,
          min: 0,
          max: 16e-9,
          decimals: 3,
          tooltip: 'Exactly one side (MAC or PHY) should add ≈ 1.5–2 ns per direction.',
          onValidity: _valid('rgtxd'),
          onChanged: (v) => _set(() => p.txClockDelay = v),
        ),
        EngField(
          key: _k('rgrxd'),
          label: 'RX delay (custom)',
          value: p.rxClockDelay,
          unit: Units.ns,
          min: 0,
          max: 16e-9,
          decimals: 3,
          onValidity: _valid('rgrxd'),
          onChanged: (v) => _set(() => p.rxClockDelay = v),
        ),
      ]),
      if (!p.perSignalLengths)
      EngField(
        key: _k('rgclk-${c.settings.lengthUnit.name}'),
        label: 'Clock length − data length',
        value: p.clockExtraLength,
        unit: lu,
        min: -0.5,
        max: 1,
        decimals: 3,
        tooltip: 'Positive when the clock trace is longer (adds PCB delay, ≈ 6–7 ps/mm). Use when no internal delay is available.',
        onValidity: _valid('rgclk'),
        onChanged: (v) => _set(() => p.clockExtraLength = v),
      ),
      const Padding(
        padding: EdgeInsets.only(top: 8, bottom: 2),
        child: Text('Timing budget (RGMII v2.0)', style: TextStyle(color: AppColors.textDim, fontWeight: FontWeight.w600)),
      ),
      FieldRow(children: [
        EngField(
          key: _k('rgsk'),
          label: 'TX skew ± TskewT',
          value: p.txSkew,
          unit: Units.ns,
          min: 0,
          max: 5e-9,
          decimals: 3,
          onValidity: _valid('rgsk'),
          onChanged: (v) => _set(() => p.txSkew = v),
        ),
        EngField(
          key: _k('rgsu'),
          label: 'RX setup TsetupR',
          value: p.setupTime,
          unit: Units.ns,
          min: 0,
          max: 5e-9,
          decimals: 3,
          onValidity: _valid('rgsu'),
          onChanged: (v) => _set(() => p.setupTime = v),
        ),
        EngField(
          key: _k('rgho'),
          label: 'RX hold TholdR',
          value: p.holdTime,
          unit: Units.ns,
          min: 0,
          max: 5e-9,
          decimals: 3,
          onValidity: _valid('rgho'),
          onChanged: (v) => _set(() => p.holdTime = v),
        ),
      ]),
      EngField(
        key: _k('rgz0'),
        label: 'Target impedance Z0',
        value: p.targetZ0,
        unit: Units.ohm,
        min: 10,
        max: 150,
        onValidity: _valid('rgz0'),
        onChanged: (v) => _set(() => p.targetZ0 = v),
      ),
    ]);
  }

  Widget _rgmiiDriver() {
    final p = cfg.rgmii;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      FieldRow(children: [
        EngField(
          key: _k('rgtr'),
          label: 'Rise time (10–90 %)',
          value: p.riseTime,
          unit: Units.ns,
          min: 50e-12,
          max: 5e-9,
          decimals: 3,
          onValidity: _valid('rgtr'),
          onChanged: (v) => _set(() => p.riseTime = v),
        ),
        EngField(
          key: _k('rgtf'),
          label: 'Fall time (90–10 %)',
          value: p.fallTime,
          unit: Units.ns,
          min: 50e-12,
          max: 5e-9,
          decimals: 3,
          onValidity: _valid('rgtf'),
          onChanged: (v) => _set(() => p.fallTime = v),
        ),
      ]),
      FieldRow(children: [
        EngField(
          key: _k('rgrd'),
          label: 'Driver impedance',
          value: p.driverImpedance,
          unit: Units.ohm,
          min: 1,
          max: 200,
          tooltip: 'MAC / PHY output impedance (often set by a drive-strength register).',
          onValidity: _valid('rgrd'),
          onChanged: (v) => _set(() => p.driverImpedance = v),
        ),
        EngField(
          key: _k('rgrs'),
          label: 'Series resistor',
          value: p.seriesR,
          unit: Units.ohm,
          min: 0,
          max: 200,
          tooltip: 'Source termination at each RGMII output (typically 22–33 Ω). 0 = none.',
          onValidity: _valid('rgrs'),
          onChanged: (v) => _set(() => p.seriesR = v),
        ),
        EngField(
          key: _k('rgcin'),
          label: 'Receiver capacitance',
          value: p.receiverCap,
          unit: Units.pf,
          min: 0,
          max: 50e-12,
          onValidity: _valid('rgcin'),
          onChanged: (v) => _set(() => p.receiverCap = v),
        ),
      ]),
    ]);
  }

  Widget _usbConfig() {
    final p = cfg.usb2;
    final hs = p.speed == Usb2Speed.highSpeed;
    final edgeUnit = hs ? Units.ps : Units.ns;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LabeledDropdown<Usb2Speed>(
        label: 'Speed mode',
        value: p.speed,
        items: Usb2Speed.values,
        itemLabel: (s) => s.label,
        onChanged: (s) => _set(() {
          p.speed = s;
          p.applySpeedDefaults();
          cfg.sim.numBits = s == Usb2Speed.highSpeed ? 127 : 64;
          c.draftRevision++;
        }),
      ),
      KeyValue('Data rate / UI', '${eng(p.speed.bitRate, 'bps')} · UI ${secs(1 / p.speed.bitRate)}'),
      const KeyValue('Signalling', 'Differential (D+ / D−)'),
      FieldRow(children: [
        EngField(
          key: _k('utr'),
          label: 'Rise time (10–90 %)',
          value: p.riseTime,
          unit: edgeUnit,
          min: 50e-12,
          max: 50e-9,
          tooltip: hs ? 'USB 2.0 HS: ≥ 500 ps.' : 'USB 2.0 FS: 4–20 ns.',
          onValidity: _valid('utr'),
          onChanged: (v) => _set(() => p.riseTime = v),
        ),
        EngField(
          key: _k('utf'),
          label: 'Fall time (90–10 %)',
          value: p.fallTime,
          unit: edgeUnit,
          min: 50e-12,
          max: 50e-9,
          onValidity: _valid('utf'),
          onChanged: (v) => _set(() => p.fallTime = v),
        ),
      ]),
      EngField(
        key: _k('zdt'),
        label: 'Target differential impedance',
        value: p.targetZdiff,
        unit: Units.ohm,
        min: 50,
        max: 150,
        tooltip: 'USB 2.0 specifies 90 Ω ±15 % differential.',
        onValidity: _valid('zdt'),
        onChanged: (v) => _set(() => p.targetZdiff = v),
      ),
    ]);
  }


  Widget _serdesConfig() {
    final p = cfg.serdes;
    final isPcie = cfg.protocol == Protocol.pcie;
    final isHdmi = cfg.protocol == Protocol.hdmi;
    final rate = cfg.serdesRate;
    final sp = p.sparams;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('PCB trace model'), icon: Icon(Icons.layers_outlined)),
            ButtonSegment(value: true, label: Text('S-parameters (L3)'), icon: Icon(Icons.insert_chart_outlined)),
          ],
          selected: {p.useTouchstone},
          onSelectionChanged: (v) => _set(() => p.useTouchstone = v.first),
        ),
      ),
      if (p.useTouchstone) ...[
        Row(children: [
          Expanded(
            child: Text(
              sp == null
                  ? 'No Touchstone file loaded.'
                  : '${sp.name} · ${sp.ports}-port · ${sp.freq.length} pts · up to ${eng(sp.fMax, 'Hz')} · '
                      'IL @ Nyquist ${(-sp.s21Db(rate / 2)).toStringAsFixed(1)} dB',
              style: TextStyle(color: sp == null ? AppColors.warning : AppColors.text, fontSize: 12.5),
            ),
          ),
          TextButton.icon(onPressed: _loadTouchstone, icon: const Icon(Icons.upload_file), label: const Text('Load .s2p/.s4p')),
        ]),
        Wrap(spacing: 4, children: [
          TextButton.icon(
            icon: const Icon(Icons.library_books_outlined, size: 18),
            label: const Text('From library'),
            onPressed: () async {
              final i = await pickLibraryItem(context, c, LibraryKind.sparam);
              final s = i == null ? null : ChannelSParams.fromJson(i.data);
              if (s == null) return;
              _spText = null;
              _set(() {
                p.sparams = s;
                p.useTouchstone = true;
              });
            },
          ),
          if (sp != null)
            TextButton.icon(
              icon: const Icon(Icons.bookmark_add_outlined, size: 18),
              label: const Text('Save to library'),
              onPressed: () async {
                await c.saveToLibrary(LibraryKind.sparam, sp.name, sp.toJson());
                _snack('Saved ${sp.name} to the library.');
              },
            ),
        ]),
        if (sp != null && sp.ports == 4)
          LabeledDropdown<PortMapping>(
            label: '4-port mapping',
            value: sp.mapping,
            items: PortMapping.values,
            itemLabel: (m) => m.label,
            onChanged: _setMapping,
          ),
        const Text('The channel is taken from the file (TX/RX terminated in its reference impedance). '
            'Touchstone v1 format; 2-port = S21, 4-port = SDD21.',
            style: TextStyle(color: AppColors.textDim, fontSize: 11.5)),
        const Divider(height: 18),
      ],
      if (isPcie)
        FieldRow(children: [
          LabeledDropdown<PcieGen>(
            label: 'PCIe generation',
            value: p.gen,
            items: PcieGen.values,
            itemLabel: (g) => '${g.label} · ${eng(g.rate, 'T/s')} · ${g.encoding}',
            onChanged: (g) => _set(() {
              p.gen = g;
              p.applyGenDefaults();
              cfg.applySerdesLossLimits();
              applyTargetWidth(cfg);
              c.draftRevision++;
            }),
          ),
          LabeledDropdown<int>(
            label: 'Lane configuration',
            value: p.lanes,
            items: const [1, 2, 4, 8, 16],
            itemLabel: (l) => 'x$l',
            onChanged: (l) => _set(() => p.lanes = l),
          ),
        ]),
      if (isHdmi) ...[
        LabeledDropdown<HdmiMode>(
          label: 'HDMI link rate (per lane)',
          value: p.hdmiMode,
          items: HdmiMode.values,
          itemLabel: (m) => m.label,
          onChanged: (m) => _set(() {
            p.hdmiMode = m;
            p.applyHdmiDefaults();
            cfg.applySerdesLossLimits();
            applyTargetWidth(cfg);
            c.draftRevision++;
          }),
        ),
        KeyValue('Lanes', p.hdmiMode == HdmiMode.frl12 ? '4 FRL lanes' : '3 TMDS data pairs + TMDS clock'),
      ],
      KeyValue('Data rate / UI', '${eng(rate, isPcie ? 'T/s' : 'b/s')} · UI ${secs(1 / rate)} · '
          'Nyquist ${eng(rate / 2, 'Hz')}'),
      KeyValue('Encoding',
          isPcie ? p.gen.encoding : (isHdmi ? '${p.hdmiMode.encoding} (not applied to the pattern)' : '8b/10b (not applied to the pattern)')),
      if ((isPcie || isHdmi) && p.lanes > 1)
        EngField(
          key: _k('lanemm-${c.settings.lengthUnit.name}'),
          label: 'Lane-to-lane length spread',
          value: p.laneMismatch,
          unit: c.settings.lengthUnit.spec,
          min: 0,
          max: 1,
          decimals: 3,
          tooltip: 'Longest minus shortest lane length; checked against the receiver deskew tolerance.',
          onValidity: _valid('lanemm'),
          onChanged: (v) => _set(() => p.laneMismatch = v),
        ),
      FieldRow(children: [
        EngField(
          key: _k('str'),
          label: 'TX rise time (10–90 %)',
          value: p.riseTime,
          unit: Units.ps,
          min: 2e-12,
          max: 1e-9,
          tooltip: 'Transmitter edge rate. Sets the simulation time step (edge/20).',
          onValidity: _valid('str'),
          onChanged: (v) => _set(() => p.riseTime = v),
        ),
        EngField(
          key: _k('szdt'),
          label: 'Target differential impedance',
          value: p.targetZdiff,
          unit: Units.ohm,
          min: 50,
          max: 150,
          tooltip: isPcie ? 'PCIe: 85 Ω (100 Ω ±15 % also common).' : 'USB 3.0: 90 Ω ±15 %.',
          onValidity: _valid('szdt'),
          onChanged: (v) => _set(() => p.targetZdiff = v),
        ),
      ]),
      const Padding(
        padding: EdgeInsets.only(top: 8, bottom: 2),
        child: Text('Reference RX eye minimum (classification)',
            style: TextStyle(color: AppColors.textDim, fontWeight: FontWeight.w600)),
      ),
      FieldRow(children: [
        EngField(
          key: _k('mh'),
          label: 'Eye height minimum',
          value: p.maskHeight,
          unit: const UnitSpec('mV', 1e-3),
          min: 1e-3,
          max: 1,
          tooltip: 'Minimum eye height at the receiver decision point. Defaults are typical spec values '
              '(after reference equalisation); check your spec revision.',
          onValidity: _valid('mh'),
          onChanged: (v) => _set(() => p.maskHeight = v),
        ),
        EngField(
          key: _k('mw'),
          label: 'Eye width minimum',
          value: p.maskWidthUi,
          unit: const UnitSpec('UI', 1),
          min: 0.01,
          max: 0.99,
          onValidity: _valid('mw'),
          onChanged: (v) => _set(() => p.maskWidthUi = v),
        ),
      ]),
    ]);
  }

  Widget _serdesDriver() {
    final p = cfg.serdes;
    final presets = cfg.protocol == Protocol.pcie && p.gen.usesPresets;
    final taps = txTapsFor(cfg.protocol, p);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Transmitter', style: TextStyle(color: AppColors.textDim, fontWeight: FontWeight.w600)),
      FieldRow(children: [
        EngField(
          key: _k('swing'),
          label: 'TX swing (diff p-p)',
          value: p.txSwingPp,
          unit: Units.volt,
          min: 0.05,
          max: 2,
          tooltip: 'Launched differential peak-to-peak voltage into a matched load (typ. 0.8–1.2 V).',
          onValidity: _valid('swing'),
          onChanged: (v) => _set(() => p.txSwingPp = v),
        ),
        EngField(
          key: _k('ztx'),
          label: 'TX impedance (per leg)',
          value: p.txImpedance,
          unit: Units.ohm,
          min: 1,
          max: 500,
          onValidity: _valid('ztx'),
          onChanged: (v) => _set(() => p.txImpedance = v),
        ),
      ]),
      if (presets)
        LabeledDropdown<int>(
          label: 'TX preset',
          value: p.preset,
          items: List<int>.generate(11, (i) => i),
          itemLabel: (i) =>
              'P$i · preshoot ${pciePresets[i].$1} dB · de-emph ${pciePresets[i].$2} dB',
          onChanged: (i) => _set(() => p.preset = i),
        )
      else
        EngField(
          key: _k('deemph'),
          label: 'TX de-emphasis',
          value: p.deEmphasisDb,
          unit: Units.db,
          min: -12,
          max: 0,
          tooltip: 'USB 3.0: -3.5 dB typ. PCIe Gen1: -3.5 dB; Gen2: -3.5 or -6 dB.',
          onValidity: _valid('deemph'),
          onChanged: (v) => _set(() => p.deEmphasisDb = v),
        ),
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text('FIR taps: $taps', style: kNumStyle.copyWith(color: AppColors.textDim, fontSize: 12)),
      ),
      const Divider(height: 16),
      const Text('Receiver', style: TextStyle(color: AppColors.textDim, fontWeight: FontWeight.w600)),
      FieldRow(children: [
        EngField(
          key: _k('zrx'),
          label: 'RX termination (per leg)',
          value: p.rxTermination,
          unit: Units.ohm,
          min: 1,
          max: 500,
          tooltip: 'Receiver termination to AC ground (typ. 50 Ω per leg = 100 Ω differential).',
          onValidity: _valid('zrx'),
          onChanged: (v) => _set(() => p.rxTermination = v),
        ),
        EngField(
          key: _k('scin'),
          label: 'RX capacitance (per leg)',
          value: p.receiverCap,
          unit: Units.pf,
          min: 0,
          max: 5e-12,
          onValidity: _valid('scin'),
          onChanged: (v) => _set(() => p.receiverCap = v),
        ),
      ]),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('CTLE (continuous-time linear equaliser)'),
        subtitle: const Text('Behavioural 1-zero / 2-pole model', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
        value: p.ctleEnabled,
        onChanged: (v) => _set(() => p.ctleEnabled = v),
      ),
      if (p.ctleEnabled) ...[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Auto-optimise CTLE gain'),
          subtitle: const Text('Sweeps 0 to −12 dB and keeps the largest eye',
              style: TextStyle(color: AppColors.textDim, fontSize: 12)),
          value: p.ctleAuto,
          onChanged: (v) => _set(() => p.ctleAuto = v),
        ),
        if (!p.ctleAuto)
          EngField(
            key: _k('ctledc'),
            label: 'CTLE DC gain',
            value: p.ctleDcGainDb,
            unit: Units.db,
            min: -20,
            max: 0,
            tooltip: 'DC attenuation relative to the high-frequency gain (peaking = −DC gain).',
            onValidity: _valid('ctledc'),
            onChanged: (v) => _set(() => p.ctleDcGainDb = v),
          ),
      ],
      FieldRow(children: [
        LabeledDropdown<int>(
          label: 'DFE taps',
          value: p.dfeTaps,
          items: const [0, 1, 2, 3, 4, 5],
          itemLabel: (n) => n == 0 ? 'Off' : '$n tap${n > 1 ? 's' : ''}',
          onChanged: (n) => _set(() => p.dfeTaps = n),
        ),
        EngField(
          key: _k('rj'),
          label: 'Random jitter (rms)',
          value: p.rjRms,
          unit: Units.ps,
          min: 0,
          max: 50e-12,
          tooltip: 'Optional TX/refclk random jitter for the total-jitter estimate (0 = not included).',
          onValidity: _valid('rj'),
          onChanged: (v) => _set(() => p.rjRms = v),
        ),
      ]),
    ]);
  }

  // ---------------------------------------------------------------- C
  /// Optional per-signal routed lengths (SPI, QSPI/OSPI, RGMII).
  Widget _signalLengths() {
    final cfg = c.draft;
    final lu = c.settings.lengthUnit.spec;
    final on = perSignalOn(cfg);
    void toggle(bool v) => _set(() {
          setPerSignal(cfg, v);
          if (!v) _invalid.removeWhere((k) => k.startsWith('sl-'));
        });
    final children = <Widget>[
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Per-signal lengths'),
        subtitle: Text(
            on
                ? 'Each line is timed with its own length; the longest and shortest data line set the worst case'
                : 'Enter the routed length of every ${cfg.protocol == Protocol.rgmii ? 'TX / RX' : 'bus'} line instead of one length',
            style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
        value: on,
        onChanged: toggle,
      ),
    ];
    if (on) {
      for (final g in groupLengths(cfg)) {
        final sigs = g.group.all;
        children.add(Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: Row(children: [
            Text(g.group.label, style: const TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            if (g.group.data.length > 1)
              Text(
                'data spread ${formatInput(lu.toDisplay(g.spread), maxDecimals: 2)} ${lu.label}'
                '${g.spread > 1e-9 ? ' (${g.shortest.name}–${g.longest.name})' : ''}',
                style: TextStyle(fontSize: 12, color: g.spread > 2.5e-3 ? AppColors.warning : AppColors.textDim),
              ),
          ]),
        ));
        for (var i = 0; i < sigs.length; i += 3) {
          children.add(FieldRow(children: [
            for (var j = i; j < i + 3; j++)
              if (j < sigs.length)
                EngField(
                  key: _k('sl-${sigs[j].name}-${lu.label}'),
                  label: sigs[j].name,
                  value: g.of(sigs[j]),
                  unit: lu,
                  min: 0.1e-3,
                  max: 2,
                  decimals: 3,
                  onValidity: _valid('sl-${sigs[j].name}'),
                  onChanged: (v) => _set(() => setSignalLength(cfg, sigs[j].name, v)),
                )
              else
                const SizedBox.shrink(),
          ]));
        }
      }
      children.add(Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          icon: const Icon(Icons.restart_alt, size: 18),
          label: const Text('Reset all to the trace length'),
          onPressed: () => _set(() {
            for (final s in busSignals(cfg)) {
              setSignalLength(cfg, s.name, defaultSignalLength(cfg, s));
            }
            c.draftRevision++;
          }),
        ),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  Widget _pcbSection() {
    final pcb = cfg.pcb;
    final gu = c.settings.geometryUnit.spec;
    final lu = c.settings.lengthUnit.spec;
    final diff = cfg.protocol.differential;
    return SectionCard(
      title: 'C · PCB stackup & trace geometry',
      subtitle: '${pcb.stackup.layerCount}-layer · L${pcb.stackup.signalLayer + 1} · '
          'W ${formatInput(gu.toDisplay(pcb.traceWidth), maxDecimals: 2)} ${gu.label} · '
          'L ${formatInput(lu.toDisplay(pcb.traceLength), maxDecimals: 2)} ${lu.label}',
      leading: const Icon(Icons.layers_outlined),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        StackupEditor(
          key: _k('stack'),
          stackup: pcb.stackup,
          unit: gu,
          traceWidth: pcb.traceWidth,
          traceSpacing: pcb.traceSpacing,
          differential: diff,
          onValidity: (k, v) => _valid('st_$k')(v),
          onChanged: () => _set(() {}),
        ),
        Wrap(spacing: 4, children: [
          TextButton.icon(
            icon: const Icon(Icons.library_books_outlined, size: 18),
            label: const Text('Stackup library'),
            onPressed: () async {
              final i = await pickLibraryItem(context, c, LibraryKind.stackup);
              if (i == null) return;
              _set(() {
                pcb.stackup = StackupConfig.fromJson(i.data);
                c.draftRevision++;
              });
            },
          ),
          TextButton.icon(
            icon: const Icon(Icons.bookmark_add_outlined, size: 18),
            label: const Text('Save to library'),
            onPressed: () async {
              final n = await askName(context, title: 'Save stackup', initial: '${pcb.stackup.layerCount}-layer stackup');
              if (n == null) return;
              await c.saveToLibrary(LibraryKind.stackup, n, pcb.stackup.toJson());
              _snack('Saved "$n" to the stackup library.');
            },
          ),
        ]),
        const Divider(height: 20),
        FieldRow(children: [
          EngField(
            key: _k('w-${gu.label}'),
            label: 'Trace width',
            value: pcb.traceWidth,
            unit: gu,
            min: 0.01e-3,
            max: 10e-3,
            decimals: 3,
            tooltip: 'Width of each trace. Wider traces lower Z0 and conductor loss.',
            onValidity: _valid('w'),
            onChanged: (v) => _set(() => pcb.traceWidth = v),
          ),
          if (diff)
            EngField(
              key: _k('s-${gu.label}'),
              label: 'Pair spacing (edge-edge)',
              value: pcb.traceSpacing,
              unit: gu,
              min: 0.01e-3,
              max: 10e-3,
              decimals: 3,
              tooltip: 'Gap between the two traces of the pair. Tighter coupling lowers Zdiff.',
              onValidity: _valid('s'),
              onChanged: (v) => _set(() => pcb.traceSpacing = v),
            ),
        ]),
        FieldRow(children: [
          EngField(
            key: _k('len-${lu.label}'),
            label: 'Trace length',
            value: pcb.traceLength,
            unit: lu,
            min: 0.1e-3,
            max: 2,
            decimals: 3,
            tooltip: perSignalOn(cfg)
                ? 'Reference length for crosstalk and channel elements. Timing uses the per-signal lengths below.'
                : 'Routed length from driver pin to receiver pin.',
            onValidity: _valid('len'),
            onChanged: (v) => _set(() => pcb.traceLength = v),
          ),
          if (diff)
            EngField(
              key: _k('mm-${lu.label}'),
              label: 'D− length mismatch',
              value: pcb.lengthMismatch,
              unit: lu,
              min: 0,
              max: 0.5,
              decimals: 3,
              tooltip: 'How much longer D− is than D+. Produces intra-pair skew.',
              onValidity: _valid('mm'),
              onChanged: (v) => _set(() => pcb.lengthMismatch = v),
            ),
        ]),
        if (diff)
          LabeledDropdown<DiffModel>(
            label: 'Differential impedance model',
            value: pcb.diffModel,
            items: DiffModel.values,
            itemLabel: (m) => m.label,
            onChanged: (m) => _set(() => pcb.diffModel = m),
          ),
        if (supportsSignalLengths(cfg.protocol)) _signalLengths(),
        _impedancePreview(),
        const Divider(height: 24),
        if (cfg.protocol.serdes && cfg.serdes.useTouchstone)
          const Text('Channel discontinuities and crosstalk are not applied: the S-parameter file defines the channel.',
              style: TextStyle(color: AppColors.textDim, fontSize: 12))
        else ...[
          ChannelElementsEditor(
            key: _k('elements'),
            pcb: pcb,
            geometryUnit: gu,
            lengthUnit: lu,
            differential: diff,
            onChanged: () => _set(() {}),
          ),
          const Divider(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Crosstalk analysis (L3)'),
            subtitle: const Text('Parallel aggressor trace on the same layer',
                style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            value: pcb.crosstalk.enabled,
            onChanged: (v) => _set(() => pcb.crosstalk.enabled = v),
          ),
          if (pcb.crosstalk.enabled)
            FieldRow(children: [
              EngField(
                key: _k('xts-${gu.label}'),
                label: 'Aggressor spacing (edge-edge)',
                value: pcb.crosstalk.spacing,
                unit: gu,
                min: 0.02e-3,
                max: 10e-3,
                decimals: 3,
                tooltip: 'Gap between the aggressor and the victim trace. The 3W rule (S ≥ 2W gap) is a common guideline.',
                onValidity: _valid('xts'),
                onChanged: (v) => _set(() => pcb.crosstalk.spacing = v),
              ),
              EngField(
                key: _k('xtl-${lu.label}'),
                label: 'Parallel (coupled) length',
                value: pcb.crosstalk.coupledLength,
                unit: lu,
                min: 0.5e-3,
                max: 1,
                decimals: 3,
                onValidity: _valid('xtl'),
                onChanged: (v) => _set(() => pcb.crosstalk.coupledLength = v),
              ),
            ]),
        ],
      ]),
    );
  }

  Widget _impedancePreview() {
    final pcb = cfg.pcb;
    final diff = cfg.protocol.differential;
    try {
      final g = geometryFromStackup(pcb.stackup);
      if (pcb.traceWidth <= 0) return const SizedBox.shrink();
      final imp = computeImpedance(g, pcb.traceWidth,
          spacing: diff ? pcb.traceSpacing : null, diffModel: pcb.diffModel);
      final target = cfg.targetImpedance;
      final z = diff ? imp.zDiff! : imp.z0;
      final dev = (z - target) / target * 100;
      final lp = LineParams(
          z0: z, eeff: diff && imp.eeffOdd != null ? imp.eeffOdd! : imp.eeff, length: pcb.traceLength, width: pcb.traceWidth, geometry: g, tanD: pcb.stackup.df);
      final st = dev.abs() <= cfg.thresholds.impedanceGoodPct
          ? SiStatus.good
          : (dev.abs() <= cfg.thresholds.impedanceWarnPct ? SiStatus.warning : SiStatus.critical);
      return Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.outline),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Text('Live impedance (L1 analytical)', style: TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            StatusChip(st, dense: true),
          ]),
          const SizedBox(height: 6),
          KeyValue(g.structure.label, imp.method.split(';').first),
          KeyValue('Single-ended Z0', ohm(imp.z0)),
          if (diff) KeyValue('Differential Zdiff', ohm(imp.zDiff!)),
          KeyValue('Target / deviation', '${ohm(target)} / ${pct(dev)}'),
          KeyValue('εeff · delay', '${imp.eeff.toStringAsFixed(3)} · ${(lp.tpdPerMetre * 1e9).toStringAsFixed(2)} ps/mm · ${secs(lp.delay)}'),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              icon: const Icon(Icons.auto_fix_high, size: 18),
              label: Text('Set width for ${ohm(target)}'),
              onPressed: () {
                final ok = applyTargetWidth(cfg);
                if (!ok) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Target not reachable by width on this stackup.')),
                  );
                }
                _set(() {});
              },
            ),
          ),
        ]),
      );
    } on StackupError catch (e) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(e.message, style: const TextStyle(color: AppColors.critical)),
      );
    }
  }

  // ---------------------------------------------------------------- D
  Widget _driverSection() {
    return SectionCard(
      title: 'D · Driver, receiver & termination',
      subtitle: switch (cfg.protocol) {
        Protocol.spi || Protocol.qspi => 'R_drv ${ohm(cfg.spiCfg.driverImpedance)} · ${cfg.spiCfg.termination.label}',
        Protocol.i2c => 'Pull-up ${ohm(cfg.i2c.pullupR)} · sink ${eng(cfg.i2c.sinkCurrent, 'A')}',
        Protocol.rgmii => 'R_drv ${ohm(cfg.rgmii.driverImpedance)} + ${ohm(cfg.rgmii.seriesR)} series',
        Protocol.usb2 =>
          'R_drv ${ohm(cfg.usb2.driverImpedance)} · RX term ${cfg.usb2.rxTermEnabled ? ohm(cfg.usb2.rxTermR) : 'off'}',
        _ => 'TX ${volts(cfg.serdes.txSwingPp)} p-p · '
            '${cfg.serdes.ctleEnabled ? 'CTLE' : 'no CTLE'}${cfg.serdes.dfeTaps > 0 ? ' + ${cfg.serdes.dfeTaps}-tap DFE' : ''}',
      },
      leading: const Icon(Icons.memory),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 4, children: [
          TextButton.icon(
            icon: const Icon(Icons.library_books_outlined, size: 18),
            label: const Text('Load preset'),
            onPressed: () async {
              final i = await pickLibraryItem(context, c, LibraryKind.driver,
                  filter: (i) => i.data['protocol'] == cfg.protocol.name);
              if (i == null) return;
              _set(() {
                applyDriverPreset(cfg, i.data);
                c.draftRevision++;
              });
            },
          ),
          TextButton.icon(
            icon: const Icon(Icons.bookmark_add_outlined, size: 18),
            label: const Text('Save preset'),
            onPressed: () async {
              final n = await askName(context, title: 'Save driver / receiver preset', initial: '${cfg.protocol.label} preset');
              if (n == null) return;
              await c.saveToLibrary(LibraryKind.driver, n, driverPresetFrom(cfg));
              _snack('Saved preset "$n".');
            },
          ),
        ]),
        switch (cfg.protocol) {
          Protocol.spi || Protocol.qspi => _spiDriver(),
          Protocol.i2c => _i2cDriver(),
          Protocol.rgmii => _rgmiiDriver(),
          Protocol.usb2 => _usbDriver(),
          Protocol.usb3 || Protocol.pcie || Protocol.hdmi => _serdesDriver(),
        },
      ]),
    );
  }

  Widget _ibisBlock() {
    final p = cfg.spiCfg;
    final drivers = <IbisModel>[
      ..._ibisModels.where((m) => m.canDrive),
      if (_ibisModels.isEmpty && p.ibisDriver != null) p.ibisDriver!,
    ];
    final receivers = <IbisModel>[
      ..._ibisModels,
      if (_ibisModels.isEmpty && p.ibisReceiver != null) p.ibisReceiver!,
    ];
    final drv = drivers.where((m) => m.name == p.ibisDriver?.name).firstOrNull;
    final rx = receivers.where((m) => m.name == p.ibisReceiver?.name).firstOrNull;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: Text(
            drv == null ? 'No IBIS file loaded.' : 'File: ${drv.file}',
            style: TextStyle(color: drv == null ? AppColors.warning : AppColors.text, fontSize: 12.5),
          ),
        ),
        TextButton.icon(onPressed: _loadIbis, icon: const Icon(Icons.upload_file), label: const Text('Load .ibs')),
      ]),
      Wrap(spacing: 4, children: [
        TextButton.icon(
          icon: const Icon(Icons.library_books_outlined, size: 18),
          label: const Text('From library'),
          onPressed: () async {
            final i = await pickLibraryItem(context, c, LibraryKind.ibis);
            final m = i == null ? null : IbisModel.fromJson(i.data);
            if (m == null) return;
            _set(() {
              if (m.canDrive) {
                p.ibisDriver = m;
              } else {
                p.ibisReceiver = m;
              }
              p.ibisReceiver ??= m;
              p.useIbis = true;
            });
          },
        ),
        if (drv != null)
          TextButton.icon(
            icon: const Icon(Icons.bookmark_add_outlined, size: 18),
            label: const Text('Save models to library'),
            onPressed: () async {
              await c.saveToLibrary(LibraryKind.ibis, '${drv.name} (${drv.file})', drv.toJson());
              if (rx != null && rx.name != drv.name) {
                await c.saveToLibrary(LibraryKind.ibis, '${rx.name} (${rx.file})', rx.toJson());
              }
              _snack('IBIS model(s) saved to the library.');
            },
          ),
      ]),
      if (drv != null) ...[
        LabeledDropdown<String>(
          label: 'Driver model (controller & peripheral)',
          value: drv.name,
          items: [for (final m in drivers) m.name],
          itemLabel: (n) => '$n (${drivers.firstWhere((m) => m.name == n).type})',
          onChanged: (n) => _set(() => p.ibisDriver = drivers.firstWhere((m) => m.name == n)),
        ),
        if (rx != null)
          LabeledDropdown<String>(
            label: 'Receiver model',
            value: rx.name,
            items: [for (final m in receivers) m.name],
            itemLabel: (n) => '$n (${receivers.firstWhere((m) => m.name == n).type})',
            onChanged: (n) => _set(() => p.ibisReceiver = receivers.firstWhere((m) => m.name == n)),
          ),
        LabeledDropdown<IbisCorner>(
          label: 'Corner',
          value: p.ibisCorner,
          items: IbisCorner.values,
          itemLabel: (c) => c.label,
          onChanged: (c) => _set(() => p.ibisCorner = c),
        ),
        KeyValue('VDD / C_comp', '${volts(drv.vccOf(p.ibisCorner))} / ${eng(drv.cCompOf(p.ibisCorner), 'F')}'),
        KeyValue('Output R (small-signal)',
            'pull-down ${ohm(drv.pulldownResistance(p.ibisCorner))}, pull-up ${ohm(drv.pullupResistance(p.ibisCorner))}'),
        KeyValue('Ramp (0–100 %)',
            'rise ${secs(drv.rampTime(p.ibisCorner, rising: true))}, fall ${secs(drv.rampTime(p.ibisCorner, rising: false))}'),
        if (rx != null && (rx.vinh != null || rx.vinl != null))
          KeyValue('Receiver Vinh / Vinl', '${rx.vinh == null ? '—' : volts(rx.vinh!)} / ${rx.vinl == null ? '—' : volts(rx.vinl!)}'),
        const Text('VDD, edge rates, driver impedance, receiver capacitance and thresholds come from the IBIS models; '
            'the linear driver fields below are ignored. Series/parallel termination still applies.',
            style: TextStyle(color: AppColors.textDim, fontSize: 11.5)),
      ],
      const Divider(height: 18),
    ]);
  }

  Widget _spiDriver() {
    final p = cfg.spiCfg;
    final t = p.termination;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Linear driver'), icon: Icon(Icons.linear_scale)),
            ButtonSegment(value: true, label: Text('IBIS models (L3)'), icon: Icon(Icons.memory)),
          ],
          selected: {p.useIbis},
          onSelectionChanged: (v) => _set(() => p.useIbis = v.first),
        ),
      ),
      if (p.useIbis) _ibisBlock(),
      EngField(
        key: _k('rdrv'),
        label: 'Driver output impedance',
        value: p.driverImpedance,
        unit: Units.ohm,
        min: 0.1,
        max: 1000,
        tooltip: 'Output resistance of the CMOS driver (IBIS typ. 15–50 Ω).',
        onValidity: _valid('rdrv'),
        onChanged: (v) => _set(() => p.driverImpedance = v),
      ),
      LabeledDropdown<TerminationScheme>(
        label: 'Termination scheme',
        value: t,
        items: TerminationScheme.values,
        itemLabel: (s) => s.label,
        onChanged: (s) => _set(() => p.termination = s),
      ),
      if (t.hasSeries)
        EngField(
          key: _k('rser'),
          label: 'Series resistor (at driver)',
          value: p.seriesR,
          unit: Units.ohm,
          min: 0,
          max: 1000,
          tooltip: 'Source termination. Ideal value ≈ Z0 − driver impedance.',
          onValidity: _valid('rser'),
          onChanged: (v) => _set(() => p.seriesR = v),
        ),
      if (t.hasParallel)
        FieldRow(children: [
          EngField(
            key: _k('rpar'),
            label: 'Parallel resistor (at receiver)',
            value: p.parallelR,
            unit: Units.ohm,
            min: 1,
            max: 100000,
            tooltip: 'Load termination to VTT. Ideal value ≈ Z0. Draws DC current.',
            onValidity: _valid('rpar'),
            onChanged: (v) => _set(() => p.parallelR = v),
          ),
          EngField(
            key: _k('vtt'),
            label: 'Termination voltage VTT',
            value: p.vtt,
            unit: Units.volt,
            min: 0,
            max: 5.5,
            tooltip: '0 V = to GND; VDD/2 = Thevenin-equivalent split termination.',
            onValidity: _valid('vtt'),
            onChanged: (v) => _set(() => p.vtt = v),
          ),
        ]),
      if (t.hasAc)
        FieldRow(children: [
          EngField(
            key: _k('acr'),
            label: 'AC termination R',
            value: p.acR,
            unit: Units.ohm,
            min: 1,
            max: 10000,
            tooltip: 'R in series with C to GND at the receiver; R ≈ Z0.',
            onValidity: _valid('acr'),
            onChanged: (v) => _set(() => p.acR = v),
          ),
          EngField(
            key: _k('acc'),
            label: 'AC termination C',
            value: p.acC,
            unit: Units.pf,
            min: 1e-12,
            max: 100e-9,
            tooltip: 'Choose RC ≥ 3 × round-trip delay; no DC current.',
            onValidity: _valid('acc'),
            onChanged: (v) => _set(() => p.acC = v),
          ),
        ]),
      FieldRow(children: [
        EngField(
          key: _k('cin'),
          label: 'Receiver capacitance',
          value: p.receiverCap,
          unit: Units.pf,
          min: 0,
          max: 1e-9,
          tooltip: 'Input pin capacitance of the receiver (C_comp + package).',
          onValidity: _valid('cin'),
          onChanged: (v) => _set(() => p.receiverCap = v),
        ),
        EngField(
          key: _k('rin'),
          label: 'Receiver input resistance',
          value: p.receiverRin,
          unit: Units.kohm,
          min: 1,
          max: 1e9,
          tooltip: 'DC input resistance to GND (CMOS inputs are effectively open: use ≥ 1 MΩ).',
          onValidity: _valid('rin'),
          onChanged: (v) => _set(() => p.receiverRin = v),
        ),
      ]),
    ]);
  }

  Widget _usbDriver() {
    final p = cfg.usb2;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      FieldRow(children: [
        EngField(
          key: _k('urdrv'),
          label: 'Driver impedance (per leg)',
          value: p.driverImpedance,
          unit: Units.ohm,
          min: 0.1,
          max: 1000,
          tooltip: 'HS: 45 Ω ±10 % source termination. FS: driver output resistance.',
          onValidity: _valid('urdrv'),
          onChanged: (v) => _set(() => p.driverImpedance = v),
        ),
        EngField(
          key: _k('urser'),
          label: 'Series resistor (per leg)',
          value: p.seriesR,
          unit: Units.ohm,
          min: 0,
          max: 200,
          tooltip: 'External series resistor. FS designs often use 22–27 Ω; HS normally none.',
          onValidity: _valid('urser'),
          onChanged: (v) => _set(() => p.seriesR = v),
        ),
      ]),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Receiver termination to GND (per leg)'),
        subtitle: const Text('HS on-die 45 Ω termination', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
        value: p.rxTermEnabled,
        onChanged: (v) => _set(() => p.rxTermEnabled = v),
      ),
      if (p.rxTermEnabled)
        EngField(
          key: _k('urxt'),
          label: 'Receiver termination',
          value: p.rxTermR,
          unit: Units.ohm,
          min: 1,
          max: 10000,
          onValidity: _valid('urxt'),
          onChanged: (v) => _set(() => p.rxTermR = v),
        ),
      FieldRow(children: [
        EngField(
          key: _k('ucin'),
          label: 'Receiver capacitance (per leg)',
          value: p.receiverCap,
          unit: Units.pf,
          min: 0,
          max: 200e-12,
          tooltip: 'Pin + ESD + package capacitance of the receiver.',
          onValidity: _valid('ucin'),
          onChanged: (v) => _set(() => p.receiverCap = v),
        ),
        EngField(
          key: _k('urin'),
          label: 'Receiver input resistance',
          value: p.receiverRin,
          unit: Units.kohm,
          min: 1,
          max: 1e9,
          onValidity: _valid('urin'),
          onChanged: (v) => _set(() => p.receiverRin = v),
        ),
      ]),
    ]);
  }

  // ---------------------------------------------------------------- E
  Widget _simSection() {
    final s = cfg.sim;
    final edge = switch (cfg.protocol) {
      Protocol.spi || Protocol.qspi =>
        cfg.spiCfg.riseTime < cfg.spiCfg.fallTime ? cfg.spiCfg.riseTime : cfg.spiCfg.fallTime,
      Protocol.i2c => cfg.i2c.driverFallTime / 4, // I2C uses ramp/40
      Protocol.rgmii => cfg.rgmii.riseTime < cfg.rgmii.fallTime ? cfg.rgmii.riseTime : cfg.rgmii.fallTime,
      Protocol.usb2 => cfg.usb2.riseTime < cfg.usb2.fallTime ? cfg.usb2.riseTime : cfg.usb2.fallTime,
      Protocol.usb3 || Protocol.pcie || Protocol.hdmi => cfg.serdes.riseTime / 2, // SerDes uses edge/20
    };
    final dur = switch (cfg.protocol) {
      Protocol.spi => (s.numBits + 3) / cfg.spiCfg.clockHz,
      Protocol.qspi => ((cfg.qspi.dtr ? (s.numBits + 1) ~/ 2 : s.numBits) + 3) / cfg.qspi.clockHz,
      Protocol.i2c => (s.numBits + 4) / cfg.i2c.clockHz,
      Protocol.rgmii => (s.numBits + 4) / cfg.rgmii.speed.clockHz / (cfg.rgmii.speed.ddr ? 2 : 1),
      Protocol.usb2 => (s.numBits + 8) / cfg.usb2.speed.bitRate,
      Protocol.usb3 || Protocol.pcie || Protocol.hdmi => (s.numBits + 10) / cfg.serdesRate,
    };
    return SectionCard(
      title: 'E · Simulation configuration',
      subtitle: '${s.numBits} bits · ${s.pattern.label} · ${s.lossy ? 'lossy' : 'lossless'}',
      leading: const Icon(Icons.timeline),
      initiallyExpanded: false,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Lossy line'), icon: Icon(Icons.waves)),
              ButtonSegment(value: false, label: Text('Lossless line'), icon: Icon(Icons.horizontal_rule)),
            ],
            selected: {s.lossy},
            onSelectionChanged: (v) => _set(() => s.lossy = v.first),
          ),
        ),
        FieldRow(children: [
          EngField(
            key: _k('bits'),
            label: switch (cfg.protocol) {
              Protocol.spi || Protocol.qspi => 'Bits per frame',
              Protocol.i2c => 'Data bits (incl. ACK)',
              _ => 'Number of bits',
            },
            value: s.numBits.toDouble(),
            unit: Units.none,
            integer: true,
            min: switch (cfg.protocol) {
              Protocol.spi || Protocol.qspi || Protocol.i2c => 1,
              Protocol.rgmii => 4,
              Protocol.usb2 => 8,
              _ => 32,
            }.toDouble(),
            max: switch (cfg.protocol) {
              Protocol.spi || Protocol.qspi => 256,
              Protocol.i2c => 36,
              Protocol.rgmii => 512,
              Protocol.usb2 => 2048,
              _ => 1024,
            }.toDouble(),
            tooltip: cfg.protocol == Protocol.i2c
                ? 'I²C: 9 bits = one byte + acknowledge.'
                : 'USB/SerDes: 127 bits = one full PRBS7 period (recommended for the eye diagram).',
            onValidity: _valid('bits'),
            onChanged: (v) => _set(() => s.numBits = v.round()),
          ),
          LabeledDropdown<DataPattern>(
            label: 'Data pattern',
            value: s.pattern,
            items: DataPattern.values,
            itemLabel: (p) => p.label,
            onChanged: (p) => _set(() => s.pattern = p),
          ),
        ]),
        if (s.pattern == DataPattern.custom)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: TextField(
              controller: _patternCtrl,
              decoration: InputDecoration(
                labelText: 'Custom pattern (hex, or 0b… binary; MSB first, repeats)',
                errorText: _patternError,
              ),
              style: kNumStyle,
              onChanged: (t) {
                String? err;
                try {
                  parseCustomPattern(t);
                } on PatternError catch (e) {
                  err = e.message;
                }
                setState(() => _patternError = err);
                _valid('pattern')(err == null);
                if (err == null) _set(() => s.customPattern = t.trim());
              },
            ),
          ),
        EngField(
          key: _k('dt'),
          label: 'Time resolution (0 = auto)',
          value: s.timeStepTarget,
          unit: Units.ps,
          min: 0,
          max: 1e-9,
          tooltip: 'Auto uses min(edge/40, line delay). The step never exceeds the line delay.',
          onValidity: _valid('dt'),
          onChanged: (v) => _set(() => s.timeStepTarget = v),
        ),
        Text(
          'Duration: automatic (≈ ${secs(dur)} + flight time and settling). '
          'Auto time step ≈ ${secs(edge / 40)}.',
          style: const TextStyle(color: AppColors.textDim, fontSize: 12),
        ),
      ]),
    );
  }

  // ---------------------------------------------------------------- F
  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset to defaults?'),
        content: Text('All ${cfg.protocol.label} inputs go back to their default values. Saved analyses are not affected.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset')),
        ],
      ),
    );
    if (ok == true) {
      c.newDraft(cfg.protocol);
      _snack('Inputs reset to ${cfg.protocol.label} defaults.');
    }
  }

  Widget _warningsCard(List<ValidationIssue> warnings) {
    return Card(
      color: AppColors.warning.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: AppColors.warning.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Row(children: [
            Icon(Icons.warning_amber_rounded, color: AppColors.warning, size: 20),
            SizedBox(width: 8),
            Text('Check before running', style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.warning)),
          ]),
          const SizedBox(height: 6),
          for (final w in warnings)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text.rich(TextSpan(children: [
                TextSpan(text: '${w.field}: ', style: const TextStyle(fontWeight: FontWeight.w600)),
                TextSpan(text: w.message, style: const TextStyle(color: AppColors.textDim)),
              ]), style: const TextStyle(fontSize: 12.5)),
            ),
          const Text('These do not block the analysis.', style: TextStyle(fontSize: 11.5, color: AppColors.textDim)),
        ]),
      ),
    );
  }

  /// Always-visible run bar: status of the inputs plus the Generate button.
  Widget _runBar(List<ValidationIssue> warnings) {
    final blocked = _invalid.isNotEmpty;
    final (IconData icon, Color color, String text) = blocked
        ? (Icons.error_outline, AppColors.critical, '${_invalid.length} field${_invalid.length == 1 ? '' : 's'} to fix (shown in red)')
        : warnings.isNotEmpty
            ? (Icons.warning_amber_rounded, AppColors.warning, '${warnings.length} warning${warnings.length == 1 ? '' : 's'} – see the end of the form')
            : (Icons.check_circle_outline, AppColors.good, 'Inputs look valid · ${cfg.protocol.label}');
    return Material(
      color: AppColors.surface,
      child: SafeArea(
        top: false,
        child: Container(
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.outline))),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(child: Text(text, style: TextStyle(fontSize: 12.5, color: color), overflow: TextOverflow.ellipsis)),
            ]),
            const SizedBox(height: 8),
            SizedBox(
              height: 52,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.black,
                  disabledBackgroundColor: AppColors.surfaceHigh,
                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                onPressed: blocked || c.running ? null : _generate,
                icon: c.running
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5))
                    : const Icon(Icons.bolt),
                label: Text(c.running ? 'Simulating…' : 'Generate Quick SI Analysis'),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _generate() async {
    FocusScope.of(context).unfocus();
    try {
      final r = await c.runDraft();
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ResultsScreen(controller: c, result: r.result, record: r.record),
      ));
    } on SimulationError catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Cannot run analysis'),
          content: SingleChildScrollView(child: Text(e.message)),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Simulation failed: $e')));
    }
  }
}
