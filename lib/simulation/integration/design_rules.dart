/// Design-rule export from an analysis (PRD Phase 4: PCB tool integration).
///
/// * KiCad custom rules (.kicad_dru, KiCad 6+ syntax):
///     (rule "name" (condition "A.NetName == 'X'")
///       (constraint track_width (min ..) (opt ..) (max ..))
///       (constraint length (max ..)) (constraint skew (max ..))
///       (constraint diff_pair_gap (opt ..)) (constraint via_count (max ..)))
/// * Tool-neutral CSV constraint table (for Altium / Cadence / Mentor
///   constraint managers).
///
/// Values come from the analysis: width for the impedance target (±10 %
/// impedance window), maximum length from the timing slack / loss limit,
/// maximum intra-pair skew from the skew threshold.
library;

import 'dart:math' as math;

import '../impedance/impedance.dart';
import '../model/config.dart';
import '../model/result.dart';

class RouteConstraints {
  RouteConstraints({
    required this.net,
    required this.isPair,
    this.widthMin,
    this.widthOpt,
    this.widthMax,
    this.gap,
    this.lengthMax,
    this.skewMax,
    this.viaMax,
    this.notes = const [],
  });

  final String net;
  final bool isPair;
  final double? widthMin, widthOpt, widthMax, gap, lengthMax, skewMax;
  final int? viaMax;
  final List<String> notes;
}

double? _metric(SimulationResult r, String id) {
  for (final m in r.metrics) {
    if (m.id == id && m.value.isFinite) return m.value;
  }
  return null;
}

/// Derives routing constraints for [net] from [r].
RouteConstraints constraintsFrom(SimulationResult r, String net) {
  final c = r.config;
  final pcb = c.pcb;
  final diff = c.protocol.differential;
  final notes = <String>[];
  double? wOpt, wMin, wMax;
  try {
    final g = geometryFromStackup(pcb.stackup);
    final target = c.targetImpedance;
    final sp = diff ? pcb.traceSpacing : null;
    wOpt = solveWidthForTarget(g, target, spacing: sp, diffModel: pcb.diffModel);
    // Width window for +/-10 % impedance (wider -> lower Z).
    wMax = solveWidthForTarget(g, target * 0.9, spacing: sp, diffModel: pcb.diffModel);
    wMin = solveWidthForTarget(g, target * 1.1, spacing: sp, diffModel: pcb.diffModel);
    notes.add('Width window gives ${target.toStringAsFixed(0)} Ω ±10 % on L${pcb.stackup.signalLayer + 1}.');
  } catch (_) {
    notes.add('Width not derived (stackup error).');
  }
  final tpd = r.metrics.where((m) => m.id == 'tpd').map((m) => m.value * 1e-9).firstOrNull; // s/m
  double? lMax;
  if (c.protocol.spiFamily && tpd != null) {
    final slack = [_metric(r, 'su_miso'), _metric(r, 'su_mosi')].whereType<double>().fold<double>(double.infinity, math.min);
    if (slack.isFinite) {
      // MISO path traverses the trace twice.
      lMax = math.max(0, pcb.traceLength + slack / (2 * tpd));
      notes.add('Max length keeps read setup slack ≥ 0 at ${(c.spiCfg.clockHz / 1e6).toStringAsFixed(1)} MHz.');
    }
  } else if (c.protocol == Protocol.i2c) {
    final i = c.i2c;
    final cPerM = math.sqrt(r.impedance.eeff) / 299792458.0 / r.impedance.z0;
    final budget = 0.8 * i.mode.cbMax - i.deviceCount * i.pinCap - i.extraCap;
    if (budget > 0) {
      lMax = budget / cPerM;
      notes.add('Max length keeps bus capacitance ≤ 80 % of ${(i.mode.cbMax * 1e12).toStringAsFixed(0)} pF.');
    }
  } else if (c.protocol.differential) {
    final il = _metric(r, 'il');
    if (il != null && il > 0 && !(c.protocol.serdes && c.serdes.useTouchstone)) {
      lMax = pcb.traceLength * c.thresholds.lossWarnDb / il;
      notes.add('Max length keeps trace loss at Nyquist ≤ ${c.thresholds.lossWarnDb} dB (loss ∝ length).');
    }
  }
  double? skew;
  if (diff && tpd != null) {
    final rate = switch (c.protocol) {
      Protocol.usb2 => c.usb2.speed.bitRate,
      Protocol.usb3 || Protocol.pcie || Protocol.hdmi => c.serdesRate,
      _ => 0.0,
    };
    if (rate > 0) {
      skew = c.thresholds.skewGoodPctUi / 100 / rate / tpd;
      notes.add('Max skew = ${c.thresholds.skewGoodPctUi} % UI.');
    }
  }
  int? viaMax;
  if (c.protocol.serdes && c.serdes.gen.index >= 3 && c.protocol == Protocol.pcie) {
    viaMax = 2;
    notes.add('Via count ≤ 2 is a common Gen4/Gen5 guideline (not a spec limit).');
  }
  return RouteConstraints(
    net: net,
    isPair: diff,
    widthMin: wMin,
    widthOpt: wOpt,
    widthMax: wMax,
    gap: diff ? pcb.traceSpacing : null,
    lengthMax: lMax,
    skewMax: skew,
    viaMax: viaMax,
    notes: notes,
  );
}

String _mm(double m) => '${(m * 1e3).toStringAsFixed(3)}mm';

/// KiCad custom design rules (paste into Board Setup → Custom Rules or save
/// as `board.kicad_dru`).
String kicadRules(List<RouteConstraints> list, {String generator = 'SI Studio'}) {
  final b = StringBuffer('(version 1)\n');
  for (final k in list) {
    final cond = k.isPair ? "A.inDiffPair('${k.net}')" : "A.NetName == '${k.net}'";
    b.writeln('');
    for (final n in k.notes) {
      b.writeln('# $n');
    }
    b.writeln('(rule "SI ${k.net}"');
    b.writeln('  (condition "$cond")');
    if (k.widthOpt != null) {
      b.write('  (constraint track_width');
      if (k.widthMin != null) b.write(' (min ${_mm(k.widthMin!)})');
      b.write(' (opt ${_mm(k.widthOpt!)})');
      if (k.widthMax != null) b.write(' (max ${_mm(k.widthMax!)})');
      b.writeln(')');
    }
    if (k.gap != null) b.writeln('  (constraint diff_pair_gap (opt ${_mm(k.gap!)}))');
    if (k.lengthMax != null) b.writeln('  (constraint length (max ${_mm(k.lengthMax!)}))');
    if (k.skewMax != null) b.writeln('  (constraint skew (max ${_mm(k.skewMax!)}))');
    if (k.viaMax != null) b.writeln('  (constraint via_count (max ${k.viaMax}))');
    b.writeln(')');
  }
  return b.toString().replaceFirst('(version 1)\n', '(version 1)\n# Generated by $generator – review before use.\n');
}

/// Tool-neutral constraint table.
String constraintsCsv(List<RouteConstraints> list) {
  final b = StringBuffer('net,type,width_min_mm,width_opt_mm,width_max_mm,pair_gap_mm,length_max_mm,skew_max_mm,via_max\n');
  String f(double? v) => v == null ? '' : (v * 1e3).toStringAsFixed(4);
  for (final k in list) {
    b.writeln([
      k.net,
      k.isPair ? 'diff_pair' : 'net',
      f(k.widthMin),
      f(k.widthOpt),
      f(k.widthMax),
      f(k.gap),
      f(k.lengthMax),
      f(k.skewMax),
      k.viaMax?.toString() ?? '',
    ].join(','));
  }
  return b.toString();
}
