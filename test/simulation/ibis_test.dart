// Phase 3: IBIS parsing and IBIS-driven SPI simulation.
import 'package:flutter_test/flutter_test.dart';
import 'package:si_studio/simulation/engine.dart';
import 'package:si_studio/simulation/ibis/ibis.dart';

const String ibisText = '''
[IBIS Ver]   3.2
[File Name]  test.ibs
|-------------------------------------------------------
[Component]  TEST_IO
[Manufacturer] Example
[Package]
| variable typ min max
R_pkg 0 NA NA
[Pin] signal_name model_name R_pin L_pin C_pin
1 IO1 io33
2 IN1 in33
|
[Model] io33
Model_type I/O
Vinl = 0.8V
Vinh = 2.0V
C_comp 2.0pF 1.5pF 2.5pF
[Voltage Range] 3.3V 3.0V 3.6V
[Pulldown]
| V      I(typ)   I(min)   I(max)
-3.3    -132mA   -100mA   -160mA
0        0        0        0
3.3      132mA    100mA    160mA
6.6      264mA    200mA    320mA
[Pullup]
-3.3     132mA    100mA    160mA
0        0        0        0
3.3     -132mA   -100mA   -160mA
6.6     -264mA   -200mA   -320mA
[GND Clamp]
-3.3    -500mA   -400mA   -600mA
-0.8    -50mA    -40mA    -60mA
-0.6     0        0        0
3.3      0        0        0
[POWER Clamp]
-3.3     500mA    400mA    600mA
-0.8     50mA     40mA     60mA
-0.6     0        0        0
3.3      0        0        0
[Ramp]
| variable typ min max
dV/dt_r 1.32/0.5n 1.2/0.7n 1.44/0.35n
dV/dt_f 1.32/0.5n 1.2/0.7n 1.44/0.35n
R_load = 50
|
[Model] in33
Model_type Input
Vinl = 0.8V
Vinh = 2.0V
C_comp 3.0pF NA NA
[Voltage Range] 3.3V 3.0V 3.6V
[GND Clamp]
-3.3    -500mA
-0.8    -50mA
-0.6     0
3.3      0
[POWER Clamp]
-3.3     500mA
-0.8     50mA
-0.6     0
3.3      0
[End]
''';

void main() {
  group('IBIS parsing', () {
    test('numbers with scale suffixes', () {
      expect(parseIbisNumber('10mA'), closeTo(0.01, 1e-15));
      expect(parseIbisNumber('2.5pF'), closeTo(2.5e-12, 1e-24));
      expect(parseIbisNumber('-3.3V'), -3.3);
      expect(parseIbisNumber('1M'), 1e6);
      expect(parseIbisNumber('0.5n'), closeTo(0.5e-9, 1e-21));
      expect(parseIbisNumber('NA'), isNull);
    });

    test('models, tables, ramp and thresholds', () {
      final models = parseIbis(ibisText, file: 'test.ibs');
      expect(models.length, 2);
      final io = models.first;
      expect(io.name, 'io33');
      expect(io.canDrive, isTrue);
      expect(io.vcc, [3.3, 3.0, 3.6]);
      expect(io.cCompOf(IbisCorner.typ), closeTo(2e-12, 1e-20));
      expect(io.pulldownResistance(IbisCorner.typ), closeTo(25, 1e-6));
      expect(io.pullupResistance(IbisCorner.typ), closeTo(25, 1e-6));
      expect(io.rampTime(IbisCorner.typ, rising: true), closeTo(0.5e-9 / 0.6, 1e-15));
      expect(io.vinh, 2.0);
      final inp = models[1];
      expect(inp.canDrive, isFalse);
      expect(inp.cCompOf(IbisCorner.max), closeTo(3e-12, 1e-20));
    });

    test('IBIS model survives JSON round trip', () {
      final m = parseIbis(ibisText).first;
      final back = IbisModel.fromJson(m.toJson())!;
      expect(back.pulldown.v, m.pulldown.v);
      expect(back.ramp!.dtR, m.ramp!.dtR);
    });
  });

  group('IBIS buffers in the SPI simulation', () {
    AnalysisConfig cfg({required bool ibis}) {
      final c = AnalysisConfig.defaults(protocol: Protocol.spi);
      c.spi.termination = TerminationScheme.none;
      c.spi.driverImpedance = 25;
      c.spi.riseTime = 0.5e-9 / 0.6 * 0.8;
      c.spi.fallTime = c.spi.riseTime;
      c.spi.clockHz = 10e6;
      c.pcb.traceLength = 0.25;
      if (ibis) {
        final models = parseIbis(ibisText);
        c.spi.useIbis = true;
        c.spi.ibisDriver = models[0];
        c.spi.ibisReceiver = models[1];
      }
      return c;
    }

    test('IBIS driver reaches the rails and drives valid edges', () {
      final r = runAnalysis(cfg(ibis: true));
      final rx = r.trace('cs_rx')!.values;
      expect(rx.first, closeTo(3.3, 0.01)); // CS idles high
      expect(r.trace('mosi_rx')!.values.first, closeTo(0, 0.01));
      expect(r.metrics.firstWhere((m) => m.id == 'su_mosi').value, greaterThan(0));
      expect(r.assumptions.any((a) => a.contains('IBIS driver')), isTrue);
    });

    test('receiver clamp diodes limit overshoot compared with an ideal receiver', () {
      double peak(SimulationResult r) => r.trace('sclk_rx')!.values.reduce((a, b) => a > b ? a : b);
      final linear = runAnalysis(cfg(ibis: false));
      final ibis = runAnalysis(cfg(ibis: true));
      expect(peak(linear), greaterThan(4.3));
      expect(peak(ibis), lessThan(peak(linear)));
      expect(peak(ibis), lessThan(3.3 + 1.3));
    });

    test('missing receiver model is a validation error', () {
      final c = cfg(ibis: true)..spi.ibisReceiver = null;
      expect(() => runAnalysis(c), throwsA(isA<SimulationError>()));
    });
  });
}
