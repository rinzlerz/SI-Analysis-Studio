/// Pre-layout routing guidelines (PRD "layout planning" extension).
///
/// From the stackup and the protocol settings, derives the limits a layout
/// engineer needs before routing: trace width per layer for the impedance
/// target (and the width window for ±10 %), propagation delay, maximum
/// length (timing, loss or bus-capacitance budget), length matching,
/// spacing for crosstalk, via / stub limits and termination.
///
/// Every number comes from the same closed-form models the simulator uses
/// (impedance, coupled lines, conductor + dielectric loss); timing budgets
/// are first-order and should be confirmed with a full analysis.
library;

import 'dart:math' as math;

import '../common/format.dart';
import '../common/physics.dart';
import '../impedance/coupled_lines.dart';
import '../impedance/impedance.dart';
import '../integration/design_rules.dart';
import '../model/bus_lengths.dart';
import '../model/config.dart';
import '../transmission_line/line_params.dart';

/// One guideline line: what, the limit, and why.
class GuidelineItem {
  GuidelineItem(this.label, this.value, this.basis, {this.important = false});
  final String label;
  final String value;
  final String basis;

  /// Shown highlighted: the limits that matter most for this protocol.
  final bool important;
}

class GuidelineSection {
  GuidelineSection(this.title, this.items, {this.icon = 'rule'});
  final String title;
  final String icon;
  final List<GuidelineItem> items;
}

/// Trace width on one routing layer.
class LayerWidth {
  LayerWidth({
    required this.index,
    required this.name,
    required this.structure,
    required this.width,
    required this.widthMin,
    required this.widthMax,
    required this.tpd,
    this.error,
    this.primary = false,
  });
  final int index;
  final String name;
  final String structure;

  /// Width for the target impedance (m); null when not achievable.
  final double? width;

  /// Width window giving the target ±10 % (m).
  final double? widthMin, widthMax;

  /// Propagation delay (s/m).
  final double? tpd;
  final String? error;
  final bool primary;
}

/// What the top-view figure shows.
enum FigureKind { diffPair, bus, i2c }

/// Board cross-section along a via, for the via-stub figure.
class ViaPlan {
  ViaPlan({
    required this.thickness,
    required this.layerTop,
    required this.layerT,
    required this.roles,
    required this.exitLayer,
    required this.stub,
    required this.stubMax,
  });
  final double thickness;

  /// Depth of the top of each copper layer from the board top (m).
  final List<double> layerTop;
  final List<double> layerT;
  final List<LayerRole> roles;

  /// Layer where the signal leaves the via (entering from the top).
  final int exitLayer;

  /// Unused via barrel below the exit layer (m).
  final double stub;
  final double? stubMax;
}

/// Numbers the diagrams are drawn from.
class GuidelineFigures {
  GuidelineFigures({
    required this.kind,
    required this.geometry,
    required this.width,
    required this.gap,
    required this.target,
    required this.signalNames,
    required this.currentLength,
    this.lineLengths,
    this.lineOut,
    this.groupStarts = const [],
    this.leftLabel = 'Driver',
    this.rightLabel = 'Receiver',
    this.acCaps = false,
    this.spacing,
    this.lengthMax,
    this.matching,
    this.matchingLabel = '',
    this.seriesR,
    this.criticalLength,
    this.rpMin,
    this.rpMax,
    this.via,
  });
  final FigureKind kind;
  final TraceGeometry geometry;
  final double width;
  final double? gap;
  final double target;
  final List<String> signalNames;
  final double currentLength;

  /// Per-signal lengths aligned with [signalNames] (null = one length).
  final List<double>? lineLengths;

  /// True for lines outside the matching budget (aligned with [signalNames]).
  final List<bool>? lineOut;

  /// Indices in [signalNames] where a new signal group starts (e.g. RX).
  final List<int> groupStarts;
  final String leftLabel, rightLabel;
  final bool acCaps;
  final double? spacing;
  final double? lengthMax;
  final double? matching;
  final String matchingLabel;

  /// Series resistor when the current length needs termination.
  final double? seriesR;
  final double? criticalLength;
  final double? rpMin, rpMax;
  final ViaPlan? via;
}

class LayoutGuidelines {
  LayoutGuidelines({
    required this.config,
    required this.title,
    required this.summary,
    required this.layers,
    required this.sections,
    required this.constraints,
    required this.assumptions,
    this.figures,
  });

  /// Data for the cross-section, top-view, via and length figures.
  final GuidelineFigures? figures;
  final AnalysisConfig config;
  final String title;
  final String summary;
  final List<LayerWidth> layers;
  final List<GuidelineSection> sections;

  /// Machine-readable limits for KiCad / CSV export.
  final RouteConstraints constraints;
  final List<String> assumptions;
}

String _mm(double m, [int d = 2]) => '${(m * 1e3).toStringAsFixed(d)} mm';
String _mil(double m) => '${(m / 25.4e-6).toStringAsFixed(1)} mil';
/// Length as "0.36 mm (14.1 mil)" or "150 mm (5.9 in)".
String guideLength(double m) => _len(m);

String _len(double m) {
  if (!m.isFinite) return 'no limit';
  if (m >= 25e-3) return '${(m * 1e3).toStringAsFixed(0)} mm (${(m / 25.4e-3).toStringAsFixed(1)} in)';
  return '${_mm(m, m < 0.01 ? 2 : 1)} (${_mil(m)})';
}

/// Computes routing guidelines for [cfg] (its protocol, stackup, routing
/// layer and protocol settings).
LayoutGuidelines computeGuidelines(AnalysisConfig cfg) {
  final p = cfg.protocol;
  final diff = p.differential;
  final st = cfg.pcb.stackup;
  final target = cfg.targetImpedance;
  final gap = cfg.pcb.traceSpacing;
  const model = DiffModel.coupled;
  final assumptions = <String>[];

  // ---- Width per signal layer ------------------------------------------------
  final layers = <LayerWidth>[];
  for (var i = 0; i < st.layers.length; i++) {
    if (st.layers[i].role != LayerRole.signal) continue;
    final s = st.copy()..signalLayer = i;
    try {
      final g = geometryFromStackup(s);
      double? w(double z) => solveWidthForTarget(g, z, spacing: diff ? gap : null, diffModel: model);
      final w0 = w(target);
      double? tpd;
      if (w0 != null) {
        final imp = computeImpedance(g, w0, spacing: diff ? gap : null, diffModel: model);
        tpd = math.sqrt(diff && imp.eeffOdd != null ? imp.eeffOdd! : imp.eeff) / c0;
      }
      layers.add(LayerWidth(
        index: i,
        name: 'L${i + 1}${i == 0 ? ' (top)' : (i == st.layers.length - 1 ? ' (bottom)' : '')}',
        structure: g.structure.label,
        width: w0,
        // Narrower trace -> higher impedance.
        widthMin: w(target * 1.1),
        widthMax: w(target * 0.9),
        tpd: tpd,
        primary: i == st.signalLayer,
      ));
    } on StackupError catch (e) {
      layers.add(LayerWidth(
          index: i, name: 'L${i + 1}', structure: '—', width: null, widthMin: null, widthMax: null, tpd: null, error: e.message));
    }
  }
  final primary = layers.where((l) => l.primary && l.width != null).firstOrNull ??
      layers.where((l) => l.width != null).firstOrNull;
  if (primary == null) {
    return LayoutGuidelines(
      config: cfg,
      title: '${p.label} layout guidelines',
      summary: 'No routing layer in this stackup can reach ${ohm(target)}${diff ? ' differential' : ''}. '
          'Check the dielectric heights, Dk${diff ? ' and the pair gap' : ''}.',
      layers: layers,
      sections: const [],
      constraints: RouteConstraints(net: _netName(p), isPair: diff),
      assumptions: assumptions,
    );
  }
  if (!primary.primary) {
    assumptions.add('The selected routing layer cannot reach the target; limits use ${primary.name}.');
  }
  final pst = st.copy()..signalLayer = primary.index;
  final g = geometryFromStackup(pst);
  final w = primary.width!;
  final tpd = primary.tpd!;
  final imp = computeImpedance(g, w, spacing: diff ? gap : null, diffModel: model);
  final line = LineParams(
    z0: diff ? imp.zOdd! : imp.z0,
    eeff: diff && imp.eeffOdd != null ? imp.eeffOdd! : imp.eeff,
    length: 1,
    width: w,
    geometry: g,
    tanD: st.df,
    roughness: st.roughnessRms,
  );
  double dbPerM(double f) => line.insertionLossDb(f);
  final cPerM = diff ? double.nan : tpd / imp.z0;

  // Crosstalk spacing: smallest edge-to-edge spacing with Kb <= limit
  // (two parallel traces of width w on the primary layer).
  double spacingFor(double kbLimit) {
    double kb(double s) => coupledLines(g, w, s).kBackward;
    var lo = 0.02e-3, hi = 0.05e-3;
    for (var i = 0; i < 40 && kb(hi) > kbLimit; i++) {
      hi *= 1.5;
    }
    if (kb(hi) > kbLimit) return double.nan;
    for (var i = 0; i < 50; i++) {
      final mid = (lo + hi) / 2;
      if (kb(mid) > kbLimit) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return hi;
  }

  final sections = <GuidelineSection>[];
  final h = g.h1;
  String spacingText(double s) =>
      s.isNaN ? 'n/a' : '${_len(s)} edge to edge (${(s / w).toStringAsFixed(1)} × W, ${(s / h).toStringAsFixed(1)} × H)';

  // ---- Impedance & geometry ------------------------------------------------------
  final geomItems = <GuidelineItem>[
    GuidelineItem('Impedance target', '${ohm(target)} ${diff ? 'differential' : 'single-ended'} ±10 %',
        diff ? 'Protocol / chip-vendor requirement for the pair' : 'Matches typical driver and termination values',
        important: true),
    GuidelineItem('Trace width on ${primary.name}', _len(w),
        '${g.structure.label}, H = ${_mm(h, 3)}, Dk ${st.dk}${diff ? ', pair gap ${_mm(gap, 3)}' : ''}',
        important: true),
    if (primary.widthMin != null && primary.widthMax != null)
      GuidelineItem('Width window for ±10 %', '${_len(primary.widthMin!)} – ${_len(primary.widthMax!)}',
          'Etching tolerance must stay inside this range'),
    if (diff) GuidelineItem('Pair gap (edge to edge)', _len(gap), 'Keep constant along the route, including at breakouts'),
    GuidelineItem('Propagation delay', '${(tpd * 1e9).toStringAsFixed(2)} ps/mm (${(tpd * 25.4e-3 * 1e12).toStringAsFixed(0)} ps/inch)',
        'εeff ${(math.pow(tpd * c0, 2)).toStringAsFixed(2)} on ${primary.name}; use it to convert time budgets to length'),
    if (!diff) GuidelineItem('Trace capacitance', '${(cPerM * 1e9).toStringAsFixed(3)} pF/mm', 'C = tpd / Z0'),
  ];
  sections.add(GuidelineSection('Impedance and geometry', geomItems, icon: 'width'));

  double? lengthMax;
  double? skewMax;
  int? viaMax;
  final routing = <GuidelineItem>[];
  final spacing = <GuidelineItem>[];
  final vias = <GuidelineItem>[];
  final notes = <GuidelineItem>[];
  String summary;
  double? figSpacing, figRs, figCritical, figRpMin, figRpMax, figStubMax;
  var figNames = <String>[];

  double critical(double tr) => tr / 6 / tpd;
  GuidelineItem termination(double tr, double rDrv, {String driver = 'driver'}) {
    final lc = critical(tr);
    final rs = math.max(0.0, imp.z0 - rDrv);
    figCritical = lc;
    if (cfg.pcb.traceLength > lc && rs > 1) figRs = rs;
    return GuidelineItem('Termination', 'None needed below ${_len(lc)}; longer: series R ≈ ${ohm(rs)} at the $driver',
        'Critical length = tr / 6 = ${secs(tr)} / 6; series R = Z0 − R_driver (${ohm(imp.z0)} − ${ohm(rDrv)})',
        important: true);
  }

  switch (p) {
    // ------------------------------------------------------------------ SPI / QSPI
    case Protocol.spi:
    case Protocol.qspi:
      final s = cfg.spiCfg;
      final isQ = p == Protocol.qspi;
      final tclk = 1 / s.clockHz;
      final tBit = isQ && s.dtr ? tclk / 2 : tclk;
      final tr = math.min(s.riseTime, s.fallTime);
      // SDR read (mode 0): data launched on one edge must arrive before the
      // opposite edge: round trip + tCO + setup + one edge <= T/2 (+ delay).
      final readWindow = (isQ && s.dtr ? tclk / 2 : tclk / 2) + s.readSampleDelay;
      final budget = readWindow - s.slaveTco - s.setupTime - tr;
      final dqs = isQ && s.dtr && s.useDqs;
      final lRead = dqs ? double.infinity : budget / (2 * tpd);
      lengthMax = lRead.isFinite && lRead > 0 ? lRead : null;
      final skewBudget = 0.1 * tBit / tpd;
      // Matching only matters once the budget is shorter than a few cm.
      skewMax = skewBudget <= 50e-3 ? skewBudget : null;
      routing.add(GuidelineItem(
        'Maximum length (read timing)',
        dqs
            ? 'not limited by round trip (DQS capture)'
            : budget > 0
                ? _len(lRead)
                : 'read fails at any length',
        dqs
            ? 'Read data is captured with the flash strobe, which travels with the data'
            : 'Round trip 2·L·tpd ≤ ${secs(readWindow)} window − tCO ${secs(s.slaveTco)} − setup ${secs(s.setupTime)} − edge ${secs(tr)}'
                '${s.readSampleDelay > 0 ? ' (window includes ${secs(s.readSampleDelay)} sample delay)' : ''}',
        important: true,
      ));
      if (!dqs && budget <= 0) {
        final need = s.slaveTco + s.setupTime + tr + 2 * tpd * cfg.pcb.traceLength - tclk / 2;
        routing.add(GuidelineItem('Fix for read timing',
            isQ ? 'Read sample delay ≈ ${secs(math.max(0.0, need))} (for ${_mm(cfg.pcb.traceLength, 0)} routing), or lower the clock'
                : 'Lower SCLK below ${eng(1 / (2 * (s.slaveTco + s.setupTime + tr)), 'Hz')} or use a delayed read sample',
            'The flash/peripheral output delay alone exceeds the half-period window'));
      }
      routing.add(GuidelineItem(
          isQ ? 'IO-to-CLK length matching' : 'Match SCLK / MOSI / MISO / CS',
          skewMax == null ? 'not critical (budget ± ${_len(skewBudget)})' : '± ${_len(skewMax)}',
          '10 % of the ${isQ && s.dtr ? 'DTR ' : ''}bit time (${secs(tBit)}) at ${(tpd * 1e9).toStringAsFixed(2)} ps/mm',
          important: isQ));
      routing.add(termination(tr, s.driverImpedance));
      routing.add(GuidelineItem('Topology', isQ ? 'Point to point: controller → one flash; no stubs or test-point branches on CLK'
          : 'Point to point; with several peripherals, daisy-chain SCLK (no star) and keep stubs < ${_len(critical(tr) / 3)}',
          'Stubs longer than ⅓ of the critical length cause visible reflections'));
      final sXt = spacingFor(0.03);
      figSpacing = sXt.isNaN ? null : sXt;
      figNames = isQ ? ['CLK', 'IO0', 'IO1', 'CS#'] : ['SCLK', 'MOSI', 'MISO', 'CS'];
      spacing.add(GuidelineItem('Spacing to other signals', spacingText(sXt), 'Backward crosstalk Kb ≤ 3 % between parallel traces',
          important: true));
      spacing.add(GuidelineItem('Clock isolation', '≥ ${_len(spacingFor(0.01))} from other clocks and analog lines', 'Kb ≤ 1 %'));
      viaMax = 4;
      vias.add(GuidelineItem('Vias per net', '≤ 4', 'Each via adds ~0.3–0.5 pF; at ${eng(s.clockHz, 'Hz')} a few vias are harmless'));
      vias.add(GuidelineItem('Reference changes', 'Add a GND stitching via within 1 mm of each signal via',
          'Keeps the return-current loop small when the signal changes layers'));
      summary = '${p.label} at ${eng(s.clockHz, 'Hz')}: route ${_len(w)} traces on ${primary.name}, '
          '${lengthMax != null ? 'keep each line shorter than ${_len(lengthMax)}' : (dqs ? 'length is not limited by read timing' : 'read timing needs a sample delay or a lower clock')}'
          '${skewMax != null ? ', match within ± ${_len(skewMax)}' : ''}.';

    // ------------------------------------------------------------------ I2C
    case Protocol.i2c:
      final s = cfg.i2c;
      final budgetC = 0.8 * s.mode.cbMax - s.deviceCount * s.pinCap - s.extraCap;
      lengthMax = budgetC > 0 ? budgetC / cPerM : null;
      final cb = cPerM * cfg.pcb.traceLength + s.deviceCount * s.pinCap + s.extraCap;
      final volMax = s.voltage > 2 ? 0.4 : 0.2 * s.voltage;
      final rpMin = (s.voltage - volMax) / s.sinkCurrent;
      final rpMax = s.mode.trMax / (0.8473 * cb);
      routing.add(GuidelineItem('Maximum total bus length', lengthMax == null ? 'none – pins and extras already use the budget' : _len(lengthMax),
          'Keeps Cb ≤ 80 % of ${eng(s.mode.cbMax, 'F')}: ${s.deviceCount} pins × ${eng(s.pinCap, 'F')}'
          '${s.extraCap > 0 ? ' + ${eng(s.extraCap, 'F')}' : ''} + ${(cPerM * 1e9).toStringAsFixed(3)} pF/mm of trace (all branches count)',
          important: true));
      routing.add(GuidelineItem('Pull-up range at ${_mm(cfg.pcb.traceLength, 0)} of trace',
          rpMin <= rpMax ? '${ohm(rpMin)} – ${ohm(rpMax)}' : 'none – bus too heavy',
          'Rp min = (VDD − VOL)/IOL; Rp max = tr / (0.8473 · Cb) with Cb = ${eng(cb, 'F')}',
          important: true));
      figRpMin = rpMin;
      figRpMax = rpMin <= rpMax ? rpMax : null;
      figSpacing = spacingFor(0.01);
      figNames = ['SCL', 'SDA'];
      routing.add(GuidelineItem('Pull-up placement', 'One pair of pull-ups per bus segment, near the controller or the middle of the bus',
          'Several pull-ups in parallel lower Rp below the minimum'));
      routing.add(GuidelineItem('Width', '≥ ${_len(0.1e-3)}; impedance is not critical', 'I²C edges are slow; width only matters for capacitance'));
      spacing.add(GuidelineItem('Spacing from fast signals', '≥ ${_len(spacingFor(0.01))} from clocks and switching nodes',
          'Kb ≤ 1 %: slow open-drain edges are easily disturbed (false clock edges)', important: true));
      spacing.add(GuidelineItem('SCL to SDA', 'May run together; keep ≥ ${_len(spacingFor(0.05))}', 'Kb ≤ 5 %'));
      vias.add(GuidelineItem('Vias', 'Not critical', 'Each via adds ~0.4 pF to Cb'));
      summary = 'I²C ${s.mode.label}: keep the total bus shorter than ${lengthMax == null ? '—' : _len(lengthMax)} and use pull-ups between '
          '${ohm(rpMin)} and ${rpMin <= rpMax ? ohm(rpMax) : '—'}.';

    // ------------------------------------------------------------------ RGMII
    case Protocol.rgmii:
      final s = cfg.rgmii;
      final tBit = (s.speed.ddr ? 0.5 : 1.0) / s.speed.clockHz;
      final tr = math.min(s.riseTime, s.fallTime);
      final d = s.txClockDelay;
      final setupM = d - s.setupTime - s.txSkew - tr / 2;
      final holdM = tBit - d - s.holdTime - s.txSkew - tr / 2;
      final margin = math.min(setupM, holdM);
      final electrical = margin > 0 ? margin / tpd : 0.0;
      skewMax = math.min(electrical > 0 ? electrical : double.infinity, 50e-12 / tpd);
      routing.add(GuidelineItem('Clock-to-data matching (per direction)', '± ${_len(skewMax)}',
          margin > 0
              ? 'Timing margin ${secs(margin)} with ${secs(d)} clock delay allows ${_len(electrical)}; capped at 50 ps (${_len(50e-12 / tpd)}) as good practice'
              : 'With ${secs(d)} clock delay there is no timing margin: enable the 2 ns internal delay (RGMII-ID)',
          important: true));
      routing.add(GuidelineItem('Clock delay', d >= 1.5e-9 && d <= 2.2e-9 ? 'Internal delay (RGMII-ID) on – exactly one side per direction'
          : 'Set 1.5–2 ns: internal RGMII-ID delay, or ${_len(1.8e-9 / tpd)} of extra clock trace',
          'The receiver needs data stable 1 ns before and after the delayed clock edge', important: true));
      routing.add(termination(tr, s.driverImpedance, driver: 'MAC TX and PHY RX outputs'));
      routing.add(GuidelineItem('Maximum length', '≈ ${_len(0.15)} practical (no hard timing limit)',
          'Clock and data travel together, so length cancels; longer runs mainly add ringing and crosstalk'));
      lengthMax = 0.15;
      figSpacing = spacingFor(0.03);
      figNames = ['TXC', 'TXD0', 'TXD1', 'TX_CTL'];
      spacing.add(GuidelineItem('Spacing within the group', spacingText(spacingFor(0.03)), 'Kb ≤ 3 %', important: true));
      spacing.add(GuidelineItem('TX group to RX group', '≥ ${_len(spacingFor(0.01))}', 'Kb ≤ 1 %; route the two directions apart'));
      viaMax = 2;
      vias.add(GuidelineItem('Vias per net', '≤ 2, same count on clock and data', 'Unequal via counts add skew (~10 ps per via)'));
      summary = 'RGMII ${s.speed.label}: ${_len(w)} traces, match clock and data within ± ${_len(skewMax)} per direction, '
          'and enable exactly one 2 ns clock delay per direction.';

    // ------------------------------------------------------------------ USB 2.0
    case Protocol.usb2:
      final u = cfg.usb2;
      final rate = u.speed.bitRate;
      final fN = rate / 2;
      final ui = 1 / rate;
      final lossM = dbPerM(fN);
      final thr = cfg.thresholds;
      final lossGoodL = thr.lossGoodDb / lossM;
      // Board route: connector, cable and the far board share the budget.
      const practical = 0.15;
      lengthMax = math.min(lossGoodL, practical);
      final trU = math.min(u.riseTime, u.fallTime);
      skewMax = math.min(0.05 * ui, 0.1 * trU) / tpd;
      routing.add(GuidelineItem('Maximum board route', '≈ ${_len(lengthMax)}',
          'Loss alone allows ${_len(lossGoodL)} (${lossM.toStringAsFixed(2)} dB/m at ${eng(fN, 'Hz')}, ${thr.lossGoodDb} dB budget); '
          'design guides keep the board route ≤ 150 mm (6 in) because the connector, cable and the other board share the eye budget',
          important: true));
      routing.add(GuidelineItem('Intra-pair (P/N) matching', '± ${_len(math.min(skewMax, 1.27e-3))}',
          'Electrical limit ${_len(skewMax)} (min of 5 % UI and 10 % of tr); typical design guides use ≤ 1.27 mm (50 mil)',
          important: true));
      skewMax = math.min(skewMax, 1.27e-3);
      routing.add(GuidelineItem('Stubs', 'None; connect ESD and test pads in line (no branches)', 'Stubs create reflections on the 90 Ω pair'));
      figSpacing = math.max(spacingFor(0.01), 3 * gap);
      figNames = ['D+', 'D−'];
      spacing.add(GuidelineItem('Pair to other signals', '≥ ${_len(math.max(spacingFor(0.01), 3 * gap))}', 'Kb ≤ 1 % and ≥ 3 × pair gap',
          important: true));
      viaMax = 2;
      vias.add(GuidelineItem('Vias per pair', '≤ 2 (both lines together)', 'Symmetric vias keep P and N matched'));
      summary = 'USB 2.0 ${u.speed.label}: ${_len(w)} / ${_len(gap)} gap on ${primary.name}, shorter than ${_len(lengthMax)}, '
          'P/N matched within ± ${_len(skewMax)}.';

    // ------------------------------------------------------------------ SerDes
    case Protocol.usb3:
    case Protocol.pcie:
    case Protocol.hdmi:
      final sd = cfg.serdes;
      final rate = cfg.serdesRate;
      final fN = rate / 2;
      final ui = 1 / rate;
      final lossM = dbPerM(fN);
      final thr = cfg.thresholds;
      final lossLimitL = thr.lossWarnDb / lossM;
      lengthMax = thr.lossGoodDb / lossM;
      skewMax = math.min(0.05 * ui, 0.2 * sd.riseTime) / tpd;
      final stubMax = c0 / (4 * math.sqrt(st.dk) * 3 * fN);
      final laneSkew = p == Protocol.pcie ? sd.gen.laneSkewLimit : (p == Protocol.hdmi ? sd.hdmiMode.laneSkewLimit : double.nan);
      routing.add(GuidelineItem('Maximum length (loss)', '${_len(lengthMax)} (absolute ${_len(lossLimitL)})',
          '${lossM.toStringAsFixed(2)} dB/m at Nyquist ${eng(fN, 'Hz')} (Df ${st.df}); board budget ${thr.lossGoodDb} dB '
          '(absolute ${thr.lossWarnDb} dB). Low-loss material (Df ≤ 0.010) roughly doubles it',
          important: true));
      routing.add(GuidelineItem('Intra-pair (P/N) matching', '± ${_len(math.min(skewMax, 0.127e-3 * 2))}',
          'Electrical limit ${_len(skewMax)} (min of 5 % UI and 20 % of tr); match close to the mismatch, e.g. with small serpentines',
          important: true));
      skewMax = math.min(skewMax, 0.254e-3);
      if (sd.lanes > 1 && laneSkew.isFinite) {
        routing.add(GuidelineItem('Lane-to-lane matching', '± ${_len(laneSkew / tpd)}', 'Receiver deskew tolerance ${secs(laneSkew)}'));
      }
      if (p != Protocol.hdmi) {
        routing.add(GuidelineItem('AC coupling capacitors', 'On TX lines, close to the transmitter or connector; void the plane under the pads',
            'Pads are wider than the trace and lower the impedance unless the reference is cut back'));
      }
      routing.add(GuidelineItem('Bends', '45° or arcs; no 90° corners; keep serpentines loose (gap ≥ 4 × W)',
          'Tight serpentines couple to themselves and speed up the signal'));
      figSpacing = math.max(spacingFor(0.01), 3 * gap);
      figStubMax = stubMax;
      figNames = p == Protocol.hdmi ? ['D0+', 'D0−'] : ['TX+', 'TX−'];
      spacing.add(GuidelineItem('Pair to pair', '≥ ${_len(math.max(spacingFor(0.01), 3 * gap))}', 'Kb ≤ 1 % and ≥ 3 × pair gap',
          important: true));
      spacing.add(GuidelineItem('TX pairs to RX pairs', '≥ ${_len(math.max(spacingFor(0.005), 5 * gap))} or on different layers',
          'NEXT between directions is the most harmful crosstalk'));
      viaMax = 2;
      vias.add(GuidelineItem('Vias per pair', '≤ 2, with GND return vias next to each pair via', 'Each via pair is an impedance discontinuity',
          important: true));
      vias.add(GuidelineItem('Maximum via stub', _len(stubMax),
          'Stub resonance c / (4·L·√Dk) ≥ 3 × Nyquist; board is ${_mm(st.totalThickness)} thick – back-drill or use blind vias for longer stubs',
          important: true));
      summary = '${p.label} ${eng(rate, p == Protocol.pcie ? 'T/s' : 'b/s')}: ${_len(w)} / ${_len(gap)} gap on ${primary.name}, '
          'shorter than ${_len(lengthMax)}, P/N within ± ${_len(skewMax)}, via stubs below ${_len(stubMax)}.';
  }

  // Per-signal lengths (SPI / QSPI / RGMII): check each data line against
  // its clock with the matching budget above.
  List<double>? lineLengths;
  List<bool>? lineOut;
  final groupStarts = <int>[];
  var currentLength = cfg.pcb.traceLength;
  if (perSignalOn(cfg)) {
    final gls = groupLengths(cfg);
    figNames = [for (final gl in gls) for (final sg in gl.group.all) sg.name];
    lineLengths = [for (final gl in gls) for (final sg in gl.group.all) gl.of(sg)];
    var at = 0;
    for (final gl in gls) {
      if (at > 0) groupStarts.add(at);
      at += gl.group.all.length;
    }
    final tol = skewMax;
    final out = <String>[];
    lineOut = [
      for (final gl in gls)
        for (final sg in gl.group.all)
          tol != null && sg.role == SignalRole.data && (gl.of(sg) - gl.clock).abs() > tol + 1e-9,
    ];
    for (final gl in gls) {
      for (final sg in gl.group.data) {
        final d = gl.of(sg) - gl.clock;
        if (tol != null && d.abs() > tol + 1e-9) {
          out.add('${sg.name} ${d > 0 ? '+' : '−'}${_len(d.abs())} vs ${gl.group.clock.name}');
        }
      }
    }
    currentLength = lineLengths.reduce(math.max);
    routing.insert(
        0,
        GuidelineItem(
          'Your per-signal lengths',
          tol == null
              ? 'Matching not critical at this speed; longest line ${_len(currentLength)}'
              : out.isEmpty
                  ? 'All data lines within ± ${_len(tol)} of their clock'
                  : '${out.length} out of match: ${out.join(', ')}',
          [for (final gl in gls) '${gl.group.label}: ${[for (final sg in gl.group.all) '${sg.name} ${_mm(gl.of(sg), 1)}'].join(', ')}']
              .join(' · '),
          important: out.isNotEmpty,
        ));
  }
  if (routing.isNotEmpty) sections.add(GuidelineSection('Length, matching and termination', routing, icon: 'length'));
  if (spacing.isNotEmpty) sections.add(GuidelineSection('Spacing and crosstalk', spacing, icon: 'spacing'));
  if (vias.isNotEmpty) sections.add(GuidelineSection('Vias and layer changes', vias, icon: 'via'));
  notes.addAll([
    GuidelineItem('Reference plane', 'Continuous plane under the whole route; never cross a split or gap',
        'A broken return path is one of the most common SI and EMI failures'),
    GuidelineItem('Board edge', '≥ ${_len(math.max(3 * h, 0.5e-3))} from the plane edge', 'Impedance rises near the plane edge'),
  ]);
  sections.add(GuidelineSection('General', notes, icon: 'info'));

  assumptions.addAll([
    'Widths from ${imp.method.split(';').first}; ±10 % window from the same model.',
    'Crosstalk spacing from the coupled-line backward coefficient Kb = (Ze − Zo) / (2 (Ze + Zo)) for two traces of width W.',
    'Loss: conductor (with roughness ${st.roughnessRms > 0 ? _mm(st.roughnessRms, 4) : 'off'}) + dielectric (Df ${st.df}) at Nyquist.',
    'Timing budgets are first-order; run a full analysis on the routed lengths to confirm.',
    'Design-guide values (e.g. P/N matching) are typical; your chip vendor\'s guide takes priority.',
  ]);

  final constraints = RouteConstraints(
    net: _netName(p),
    isPair: diff,
    widthMin: primary.widthMin,
    widthOpt: w,
    widthMax: primary.widthMax,
    gap: diff ? gap : null,
    lengthMax: lengthMax,
    skewMax: skewMax,
    viaMax: viaMax,
    notes: ['${p.label} layout guidelines from SI Studio', summary],
  );
  // Via plan: signal enters at the top, leaves at the routing layer (or at
  // the bottom when routed on an outer layer).
  ViaPlan? via;
  if (diff) {
    final tops = <double>[];
    var z = 0.0;
    for (var i = 0; i < st.layers.length; i++) {
      tops.add(z);
      z += st.layers[i].copperThickness;
      if (i < st.dielectrics.length) z += st.dielectrics[i];
    }
    final exit = primary.index == 0 ? st.layers.length - 1 : primary.index;
    final stub = math.max(0.0, st.totalThickness - (tops[exit] + st.layers[exit].copperThickness));
    via = ViaPlan(
      thickness: st.totalThickness,
      layerTop: tops,
      layerT: [for (final l in st.layers) l.copperThickness],
      roles: [for (final l in st.layers) l.role],
      exitLayer: exit,
      stub: stub,
      stubMax: figStubMax,
    );
  }
  final figures = GuidelineFigures(
    kind: diff ? FigureKind.diffPair : (p == Protocol.i2c ? FigureKind.i2c : FigureKind.bus),
    geometry: g,
    width: w,
    gap: diff ? gap : null,
    target: target,
    signalNames: figNames,
    currentLength: currentLength,
    lineLengths: lineLengths,
    lineOut: lineOut,
    groupStarts: groupStarts,
    leftLabel: switch (p) {
      Protocol.spi || Protocol.qspi || Protocol.i2c => 'Controller',
      Protocol.rgmii => 'MAC',
      Protocol.usb2 => 'USB host',
      Protocol.hdmi => 'Source',
      _ => 'TX',
    },
    rightLabel: switch (p) {
      Protocol.spi => 'Peripheral',
      Protocol.qspi => 'Flash',
      Protocol.i2c => 'Targets',
      Protocol.rgmii => 'PHY',
      Protocol.usb2 || Protocol.hdmi => 'Connector',
      _ => 'RX',
    },
    acCaps: p == Protocol.usb3 || p == Protocol.pcie,
    spacing: figSpacing != null && figSpacing.isFinite ? figSpacing : null,
    lengthMax: lengthMax,
    matching: skewMax,
    matchingLabel: diff ? 'P/N' : (p == Protocol.rgmii ? 'CLK–data' : (p == Protocol.i2c ? '' : 'match')),
    seriesR: figRs,
    criticalLength: figCritical,
    rpMin: figRpMin,
    rpMax: figRpMax,
    via: via,
  );
  return LayoutGuidelines(
    figures: figures,
    config: cfg,
    title: '${p.label} layout guidelines',
    summary: summary,
    layers: layers,
    sections: sections,
    constraints: constraints,
    assumptions: assumptions,
  );
}

String _netName(Protocol p) => switch (p) {
      Protocol.spi => '/SPI_*',
      Protocol.qspi => '/QSPI_*',
      Protocol.i2c => '/I2C_*',
      Protocol.rgmii => '/RGMII_*',
      Protocol.usb2 => '/USB_D',
      Protocol.usb3 => '/USB3_TX',
      Protocol.pcie => '/PCIE_TX0',
      Protocol.hdmi => '/HDMI_D0',
    };

/// Plain-text version for sharing / clipboard.
String guidelinesText(LayoutGuidelines g) {
  final b = StringBuffer('${g.title}\n${'=' * g.title.length}\n${g.summary}\n\n');
  b.writeln('Trace width for ${ohm(g.config.targetImpedance)}${g.config.protocol.differential ? ' differential' : ''} per layer:');
  for (final l in g.layers) {
    b.writeln('  ${l.name.padRight(14)} ${l.structure.padRight(11)} '
        '${l.width == null ? (l.error ?? 'not achievable') : '${_len(l.width!)}${l.widthMin != null && l.widthMax != null ? '  (±10 %: ${_mm(l.widthMin!, 3)}–${_mm(l.widthMax!, 3)})' : ''}'}'
        '${l.primary ? '  ← routing layer' : ''}');
  }
  for (final s in g.sections) {
    b.writeln('\n${s.title}');
    for (final i in s.items) {
      b.writeln('  • ${i.label}: ${i.value}\n      ${i.basis}');
    }
  }
  b.writeln('\nAssumptions');
  for (final a in g.assumptions) {
    b.writeln('  - $a');
  }
  b.writeln('\nGenerated by SI Studio – preliminary guidance, not a substitute for the chip vendor\'s layout guide.');
  return b.toString();
}
