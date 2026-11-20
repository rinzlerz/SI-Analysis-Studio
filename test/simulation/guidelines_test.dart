// Layout guideline sheet.
import 'package:flutter_test/flutter_test.dart';
import 'package:si_studio/simulation/engine.dart';
import 'package:si_studio/simulation/guidelines/guidelines.dart';
import 'package:si_studio/simulation/impedance/impedance.dart';

void main() {
  test('every protocol gives a width per routing layer that hits the target', () {
    for (final p in Protocol.values) {
      final c = AnalysisConfig.defaults(protocol: p);
      final g = computeGuidelines(c);
      expect(g.sections, isNotEmpty, reason: p.name);
      expect(g.summary.isNotEmpty, isTrue);
      final routable = g.layers.where((l) => l.width != null).toList();
      expect(routable, isNotEmpty, reason: p.name);
      for (final l in routable) {
        final s = c.pcb.stackup.copy()..signalLayer = l.index;
        final geo = geometryFromStackup(s);
        final imp = computeImpedance(geo, l.width!,
            spacing: p.differential ? c.pcb.traceSpacing : null, diffModel: DiffModel.coupled);
        final z = p.differential ? imp.zDiff! : imp.z0;
        expect((z - c.targetImpedance).abs() / c.targetImpedance, lessThan(0.01), reason: '${p.name} ${l.name}');
        expect(l.widthMin! < l.width! && l.width! < l.widthMax!, isTrue);
      }
      expect(guidelinesText(g).contains(g.title), isTrue);
    }
  });

  test('SPI maximum length shrinks as the clock rises', () {
    double? lmax(double f) => computeGuidelines(AnalysisConfig.defaults(protocol: Protocol.spi)..spi.clockHz = f).constraints.lengthMax;
    expect(lmax(10e6)!, greaterThan(lmax(40e6)!));
  });

  test('QSPI at 104 MHz SDR flags read timing; DQS removes the length limit', () {
    final q = computeGuidelines(AnalysisConfig.defaults(protocol: Protocol.qspi));
    expect(q.summary.contains('sample delay'), isTrue);
    final d = computeGuidelines(AnalysisConfig.defaults(protocol: Protocol.qspi)
      ..qspi.dtr = true
      ..qspi.useDqs = true);
    expect(d.constraints.lengthMax, isNull);
  });

  test('I2C length budget follows the bus capacitance', () {
    final light = computeGuidelines(AnalysisConfig.defaults(protocol: Protocol.i2c)).constraints.lengthMax!;
    final heavy = computeGuidelines(AnalysisConfig.defaults(protocol: Protocol.i2c)..i2c.deviceCount = 20).constraints.lengthMax!;
    expect(heavy, lessThan(light));
  });

  test('RGMII without clock delay asks for RGMII-ID', () {
    final g = computeGuidelines(AnalysisConfig.defaults(protocol: Protocol.rgmii)..rgmii.txClockDelay = 0);
    final text = guidelinesText(g);
    expect(text.contains('RGMII-ID'), isTrue);
  });

  test('faster SerDes needs shorter via stubs and shorter routes', () {
    LayoutGuidelines pcie(PcieGen gen) {
      final c = AnalysisConfig.defaults(protocol: Protocol.pcie);
      c.pcie.gen = gen;
      c.pcie.applyGenDefaults();
      c.applySerdesLossLimits();
      return computeGuidelines(c);
    }

    String stub(LayoutGuidelines g) =>
        g.sections.expand((s) => s.items).firstWhere((i) => i.label == 'Maximum via stub').value;
    double mm(String v) => double.parse(v.split(' ').first);
    expect(mm(stub(pcie(PcieGen.gen5))), lessThan(mm(stub(pcie(PcieGen.gen2)))));
  });
}
