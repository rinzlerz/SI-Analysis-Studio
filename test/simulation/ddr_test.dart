// DDR3 / DDR4 / LPDDR4 memory interface model.
import 'package:flutter_test/flutter_test.dart';
import 'package:si_studio/simulation/engine.dart';
import 'package:si_studio/simulation/guidelines/figures.dart';
import 'package:si_studio/simulation/guidelines/guidelines.dart';
import 'package:si_studio/simulation/model/bus_lengths.dart';
import 'package:si_studio/simulation/model/result_codec.dart';

Metric metric(SimulationResult r, String id) => r.metrics.firstWhere((m) => m.id == id);
bool has(SimulationResult r, String id) => r.metrics.any((m) => m.id == id);

AnalysisConfig ddr(DdrStandard s, {int? rate}) {
  final c = AnalysisConfig.defaults(protocol: Protocol.ddr);
  c.ddr.standard = s;
  c.ddr.applyStandardDefaults();
  if (rate != null) c.ddr.rate = rate;
  return c;
}

void main() {
  test('every standard simulates and a short, matched lane passes', () {
    for (final s in DdrStandard.values) {
      final c = ddr(s);
      expect(validateConfig(c).where((i) => i.blocking), isEmpty, reason: s.name);
      final r = runAnalysis(c);
      expect(r.overallStatus, isNot(SiStatus.critical), reason: s.name);
      expect(r.eyes.length, 3, reason: s.name);
      expect(r.eyes.every((e) => e.maskRect && e.maskHits == 0), isTrue, reason: s.name);
      expect(metric(r, 'wr_margin').value, greaterThan(0), reason: s.name);
      expect(metric(r, 'rd_margin').value, greaterThan(0), reason: s.name);
      expect(has(r, 'flyby_skew'), s.caTopology == CaTopology.flyBy && c.ddr.devices > 1, reason: s.name);
      expect(r.checks.where((k) => k.pass == false), isEmpty, reason: s.name);
      expect(s.dramOdtOptions.contains(metric(r, 'odt_wr_best').value), isTrue, reason: s.name);
      // Default width hits the 40 Ω target on the default stackup.
      expect(metric(r, 'z0').value, closeTo(40, 2), reason: s.name);
    }
  });

  test('reference masks follow the speed bin', () {
    final lo = ddrReferenceMasks(DdrStandard.ddr4, 2400), hi = ddrReferenceMasks(DdrStandard.ddr4, 3200);
    expect(hi.dq.height, lessThan(lo.dq.height));
    expect(hi.ca.setup!, lessThan(lo.ca.setup!));
    expect(ddrReferenceMasks(DdrStandard.lpddr4, 3200).dq.width, closeTo(0.22 / 3200e6, 1e-15));
    final c = ddr(DdrStandard.ddr4)..ddr.dqMaskV = 0.2;
    expect(c.ddr.dqMask.height, 0.2);
    expect(c.ddr.dqMask.source, 'user-defined');
  });

  test('DQ skew in the byte costs eye margin unless the controller deskews per bit', () {
    final c = ddr(DdrStandard.ddr4, rate: 3200);
    final base = runAnalysis(c);
    setPerSignal(c, true);
    setSignalLength(c, 'DQ5', c.pcb.traceLength + 12e-3);
    final r = runAnalysis(c);
    final skew = metric(r, 'dq_spread').value;
    expect(skew, greaterThan(60e-12));
    expect(metric(r, 'wr_margin').value, closeTo(metric(base, 'wr_margin').value - skew, 15e-12));
    expect((metric(r, 'dq_spread').note ?? '').contains('DQ5'), isTrue);
    c.ddr.training = DdrTraining.perBit;
    final pb = runAnalysis(c);
    expect(metric(pb, 'wr_margin').value, greaterThan(metric(r, 'wr_margin').value + 0.8 * skew));
  });

  test('a long lane at a high rate loses margin, and a failing eye is flagged', () {
    final c = ddr(DdrStandard.ddr4, rate: 3200);
    final short = runAnalysis(c);
    c.pcb.traceLength = 150e-3;
    final long = runAnalysis(c);
    expect(metric(long, 'wr_height').value, lessThan(metric(short, 'wr_height').value));
    c.ddr.dqMaskT = 0.9 * c.ddr.ui; // impossible mask
    final bad = runAnalysis(c);
    expect(metric(bad, 'wr_margin').status, SiStatus.critical);
    expect(bad.findings.any((f) => f.title == 'Write eye fails the receiver mask'), isTrue);
    expect(bad.checks.firstWhere((k) => k.name.startsWith('Write eye')).pass, isFalse);
  });

  test('fly-by: a mismatched VTT resistor and long stubs hurt CA timing', () {
    final good = ddr(DdrStandard.ddr4, rate: 2400)..ddr.devices = 8;
    final bad = good.copy()
      ..ddr.vttR = 120
      ..ddr.stub = 8e-3;
    final rg = runAnalysis(good), rb = runAnalysis(bad);
    double worstCa(SimulationResult r) => [metric(r, 'ca_su').value, metric(r, 'ca_ho').value].reduce((a, b) => a < b ? a : b);
    expect(worstCa(rb), lessThan(worstCa(rg)));
    expect(metric(rg, 'flyby_skew').value, greaterThan(0.5e-9)); // 7 spacings, loaded
    expect(metric(rb, 'z_loaded').status, SiStatus.warning);
  });

  test('CK shorter than DQS at the first DRAM is flagged', () {
    final c = ddr(DdrStandard.ddr4)..ddr.leadIn = 25e-3;
    final r = runAnalysis(c);
    expect(r.findings.any((f) => f.title == 'CK shorter than DQS at the first DRAM'), isTrue);
    expect(r.checks.firstWhere((k) => k.name.startsWith('CK arrives')).pass, isFalse);
  });

  test('validation, JSON round trip and result codec', () {
    final c = ddr(DdrStandard.ddr3)
      ..ddr.devices = 0
      ..ddr.stub = 0;
    final issues = validateConfig(c).where((i) => i.blocking).map((i) => i.field).toList();
    expect(issues.contains('Devices'), isTrue);
    expect(issues.contains('Stub length'), isTrue);
    final d = ddr(DdrStandard.lpddr4x)
      ..ddr.caMaskV = 0.12
      ..ddr.training = DdrTraining.perBit;
    setPerSignal(d, true);
    setSignalLength(d, 'DQS', 0.05);
    final back = AnalysisConfig.fromJson(d.toJson());
    expect(back.protocol, Protocol.ddr);
    expect(back.ddr.standard, DdrStandard.lpddr4x);
    expect(back.ddr.caMaskV, 0.12);
    expect(back.ddr.training, DdrTraining.perBit);
    expect(back.ddr.signalLengths['DQS'], 0.05);
    final r = runAnalysis(ddr(DdrStandard.ddr4));
    final again = decodeResult(encodeResult(r));
    expect(again.eyes.first.maskRect, isTrue);
    expect(again.metrics.length, r.metrics.length);
  });

  test('guideline sheet: DDR rules and the fly-by figure', () {
    final g = computeGuidelines(ddr(DdrStandard.ddr4));
    final items = g.sections.expand((s) => s.items).map((i) => i.label).toList();
    for (final l in ['Byte lane: DQ0–7 / DM to DQS', 'CK vs DQS at each DRAM', 'VTT termination', 'DQS± and CK± pairs']) {
      expect(items.contains(l), isTrue, reason: l);
    }
    expect(g.figures!.flyBy, isNotNull);
    expect(guidelineFigures(g, FigPalette.light).any((f) => f.title == 'Fly-by'), isTrue);
    final lp = computeGuidelines(ddr(DdrStandard.lpddr4));
    expect(lp.figures!.flyBy, isNull);
    expect(lp.sections.expand((s) => s.items).any((i) => i.label == 'CA topology'), isTrue);
  });
}
