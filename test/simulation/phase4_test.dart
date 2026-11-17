// Phase 4: KiCad import, design-rule export, sweeps and libraries.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:si_studio/data/models/library_item.dart';
import 'package:si_studio/simulation/comparison/sweep.dart';
import 'package:si_studio/simulation/engine.dart';
import 'package:si_studio/simulation/integration/design_rules.dart';
import 'package:si_studio/simulation/integration/kicad.dart';

const String board = '''
(kicad_pcb (version 20240108) (generator "pcbnew")
  (general (thickness 1.6))
  (layers
    (0 "F.Cu" signal)
    (1 "In1.Cu" signal)
    (2 "In2.Cu" power)
    (31 "B.Cu" signal)
  )
  (setup
    (stackup
      (layer "F.SilkS" (type "Top Silk Screen"))
      (layer "F.Mask" (type "Top Solder Mask") (thickness 0.01))
      (layer "F.Cu" (type "copper") (thickness 0.035))
      (layer "dielectric 1" (type "prepreg") (thickness 0.2) (material "FR4") (epsilon_r 4.4) (loss_tangent 0.02))
      (layer "In1.Cu" (type "copper") (thickness 0.035))
      (layer "dielectric 2" (type "core") (thickness 1.065) (material "FR4") (epsilon_r 4.6) (loss_tangent 0.02))
      (layer "In2.Cu" (type "copper") (thickness 0.035))
      (layer "dielectric 3" (type "prepreg") (thickness 0.2) (material "FR4") (epsilon_r 4.4) (loss_tangent 0.02))
      (layer "B.Cu" (type "copper") (thickness 0.035))
      (layer "B.Mask" (type "Bottom Solder Mask") (thickness 0.01))
    )
  )
  (net 0 "")
  (net 1 "GND")
  (net 2 "SCLK")
  (net 3 "USB_D_P")
  (net 4 "USB_D_N")
  (net 5 "+3V3")
  (segment (start 0 0) (end 30 0) (width 0.36) (layer "F.Cu") (net 2) (uuid "a"))
  (segment (start 30 0) (end 30 40) (width 0.36) (layer "F.Cu") (net 2) (uuid "b"))
  (arc (start 30 40) (mid 32.9289 47.0711) (end 40 50) (width 0.36) (layer "F.Cu") (net 2) (uuid "c"))
  (via (at 40 50) (size 0.6) (drill 0.3) (layers "F.Cu" "B.Cu") (net 2) (uuid "d"))
  (segment (start 0 10) (end 50 10) (width 0.3) (layer "F.Cu") (net 3) (uuid "e"))
  (segment (start 0 10.5) (end 52 10.5) (width 0.3) (layer "F.Cu") (net 4) (uuid "f"))
  (zone (net 1) (net_name "GND") (layer "In1.Cu") (uuid "z1"))
  (zone (net 5) (net_name "+3V3") (layer "In2.Cu") (uuid "z2"))
)
''';

void main() {
  group('KiCad import', () {
    test('S-expression parser handles quotes and nesting', () {
      final t = parseSexpr('(a "b c" (d 1 2) (e "x\\"y"))');
      expect(t[0], 'a');
      expect(t[1], 'b c');
      expect((t[2] as List)[2], '2');
      expect((t[3] as List)[1], 'x"y');
    });

    test('stackup, planes, nets, arcs, vias and pairs', () {
      final b = parseKicadPcb(board);
      expect(b.copperNames, ['F.Cu', 'In1.Cu', 'In2.Cu', 'B.Cu']);
      final s = b.stackup!;
      expect(s.layers[1].role, LayerRole.ground);
      expect(s.layers[2].role, LayerRole.power);
      expect(s.layers[0].role, LayerRole.signal);
      expect(s.dielectrics[0], closeTo(0.2e-3, 1e-12));
      expect(s.dielectrics[1], closeTo(1.065e-3, 1e-12));
      expect(s.dk, closeTo(4.47, 0.01));
      final sclk = b.nets['SCLK']!;
      // 30 + 40 + quarter circle of radius 10 (15.708 mm).
      expect(sclk.length * 1e3, closeTo(70 + math.pi * 10 / 2, 0.01));
      expect(sclk.width, closeTo(0.36e-3, 1e-12));
      expect(sclk.vias, 1);
      expect(b.pairs.length, 1);
      expect(b.pairs.first.base, 'USB_D');
      expect(b.pairs.first.mismatch * 1e3, closeTo(2, 1e-9));
    });

    test('applying a net fills the analysis', () {
      final b = parseKicadPcb(board);
      final c = AnalysisConfig.defaults(protocol: Protocol.spi);
      final notes = applyKicadNet(c, b, net: b.nets['SCLK']);
      expect(notes, isNotEmpty);
      expect(c.pcb.traceLength * 1e3, closeTo(85.708, 0.01));
      expect(c.pcb.traceWidth, closeTo(0.36e-3, 1e-12));
      expect(c.pcb.stackup.layerCount, 4);
      final vias = c.pcb.elements.where((e) => e.type == ChannelElementType.via).toList();
      expect(vias.length, 1);
      // Routed only on F.Cu with a through via: stub = F.Cu -> B.Cu span.
      expect(vias.first.stubLength * 1e3, closeTo(0.2 + 0.035 + 1.065 + 0.035 + 0.2, 1e-6));
      expect(runAnalysis(c).metrics, isNotEmpty);
    });

    test('applying a pair sets length and mismatch', () {
      final b = parseKicadPcb(board);
      final c = AnalysisConfig.defaults(protocol: Protocol.usb2);
      applyKicadNet(c, b, pair: b.pairs.first);
      expect(c.pcb.traceLength * 1e3, closeTo(50, 1e-9));
      expect(c.pcb.lengthMismatch * 1e3, closeTo(2, 1e-9));
    });

    test('rejects non-KiCad text', () {
      expect(() => parseKicadPcb('(foo)'), throwsA(isA<KicadError>()));
    });
  });

  group('Design-rule export', () {
    test('SPI constraints and KiCad rule syntax', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.spi);
      final r = runAnalysis(c);
      final k = constraintsFrom(r, 'SCLK');
      expect(k.widthOpt, isNotNull);
      expect(k.widthMin!, lessThan(k.widthOpt!));
      expect(k.widthMax!, greaterThan(k.widthOpt!));
      expect(k.lengthMax!, greaterThan(c.pcb.traceLength));
      final rules = kicadRules([k]);
      expect(rules.startsWith('(version 1)'), isTrue);
      expect(rules.contains("(condition \"A.NetName == 'SCLK'\")"), isTrue);
      expect(rules.contains('(constraint track_width (min '), isTrue);
      expect(rules.contains('(constraint length (max '), isTrue);
      expect('('.allMatches(rules).length, ')'.allMatches(rules).length);
    });

    test('differential pairs get gap and skew constraints', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.usb2);
      final k = constraintsFrom(runAnalysis(c), 'USB_D');
      expect(k.isPair, isTrue);
      expect(k.gap, c.pcb.traceSpacing);
      expect(k.skewMax!, greaterThan(0));
      final rules = kicadRules([k]);
      expect(rules.contains("A.inDiffPair('USB_D')"), isTrue);
      expect(rules.contains('diff_pair_gap'), isTrue);
      final csv = constraintsCsv([k]);
      expect(csv.split('\n')[1].startsWith('USB_D,diff_pair,'), isTrue);
    });
  });

  group('Sweeps and libraries', () {
    test('trace-length sweep increases delay monotonically', () {
      final base = AnalysisConfig.defaults(protocol: Protocol.spi);
      final vals = sweepValues(0.05, 0.2, 4);
      expect(vals, [0.05, 0.1, 0.15000000000000002, 0.2]);
      final delays = [
        for (final v in vals) runAnalysis(SweepParam.traceLength.apply(base, v)).metrics.firstWhere((m) => m.id == 'delay').value,
      ];
      for (var i = 1; i < delays.length; i++) {
        expect(delays[i], greaterThan(delays[i - 1]));
      }
      expect(SweepParam.traceLength.read(base), base.pcb.traceLength);
    });

    test('series-R sweep enables series termination and reduces overshoot', () {
      final base = AnalysisConfig.defaults(protocol: Protocol.spi)
        ..spi.termination = TerminationScheme.none
        ..pcb.traceLength = 0.2;
      final r0 = runAnalysis(SweepParam.seriesR.apply(base, 0));
      final r1 = runAnalysis(SweepParam.seriesR.apply(base, 25));
      expect(SweepParam.seriesR.apply(base, 25).spi.termination, TerminationScheme.series);
      double os(SimulationResult r) => r.metrics.firstWhere((m) => m.id == 'overshoot').value;
      expect(os(r1), lessThan(os(r0)));
    });

    test('applicability rules', () {
      final spi = AnalysisConfig.defaults(protocol: Protocol.spi);
      expect(SweepParam.clock.applies(spi), isTrue);
      expect(SweepParam.traceSpacing.applies(spi), isFalse);
      final usb = AnalysisConfig.defaults(protocol: Protocol.usb2);
      expect(SweepParam.lengthMismatch.applies(usb), isTrue);
      expect(SweepParam.viaStub.applies(usb), isFalse);
    });

    test('driver presets apply only buffer fields of the same protocol', () {
      final a = AnalysisConfig.defaults(protocol: Protocol.spi)
        ..spi.driverImpedance = 33
        ..spi.clockHz = 5e6;
      final preset = driverPresetFrom(a);
      final b = AnalysisConfig.defaults(protocol: Protocol.spi);
      expect(applyDriverPreset(b, preset), isTrue);
      expect(b.spi.driverImpedance, 33);
      expect(b.spi.clockHz, isNot(5e6));
      final u = AnalysisConfig.defaults(protocol: Protocol.usb2);
      expect(applyDriverPreset(u, preset), isFalse);
    });

    test('library items round-trip and built-ins exist', () {
      final item = LibraryItem(kind: LibraryKind.stackup, name: 'Mine', data: StackupConfig.preset(6).toJson());
      final back = LibraryItem.fromRow(item.toRow());
      expect(back.name, 'Mine');
      expect(StackupConfig.fromJson(back.data).layerCount, 6);
      expect(LibraryItem.fromExportJson(item.toExportJson())!.kind, LibraryKind.stackup);
      expect(builtInLibrary().where((i) => i.kind == LibraryKind.stackup).length, 4);
    });
  });
}
