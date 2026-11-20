// Per-signal routed lengths for SPI, QSPI/OSPI and RGMII.
import 'package:flutter_test/flutter_test.dart';
import 'package:si_studio/simulation/engine.dart';
import 'package:si_studio/simulation/guidelines/guidelines.dart';
import 'package:si_studio/simulation/integration/kicad.dart';
import 'package:si_studio/simulation/model/bus_lengths.dart';

Metric metric(SimulationResult r, String id) => r.metrics.firstWhere((m) => m.id == id);
bool has(SimulationResult r, String id) => r.metrics.any((m) => m.id == id);

void main() {
  test('signal lists per protocol', () {
    expect(busSignals(AnalysisConfig.defaults(protocol: Protocol.spi)).map((s) => s.name).toList(), ['SCLK', 'MOSI', 'MISO', 'CS']);
    final q = AnalysisConfig.defaults(protocol: Protocol.qspi)..qspi.ioWidth = 8;
    expect(busSignals(q).length, 10);
    q.qspi
      ..dtr = true
      ..useDqs = true;
    expect(busSignals(q).last.name, 'DQS');
    final r = busGroups(AnalysisConfig.defaults(protocol: Protocol.rgmii));
    expect(r.map((g) => g.label).toList(), ['TX', 'RX']);
    expect(r[0].data.map((s) => s.name).toList(), ['TXD0', 'TXD1', 'TXD2', 'TXD3', 'TX_CTL']);
    expect(supportsSignalLengths(Protocol.usb3), isFalse);
  });

  test('turning per-signal on with the default lengths changes nothing', () {
    for (final p in [Protocol.spi, Protocol.qspi, Protocol.rgmii]) {
      final c = AnalysisConfig.defaults(protocol: p);
      if (p == Protocol.qspi) c.qspi.dataClockMismatch = 5e-3;
      if (p == Protocol.rgmii) c.rgmii.clockExtraLength = 10e-3;
      final off = runAnalysis(c);
      setPerSignal(c, true);
      expect(perSignalOn(c), isTrue);
      final on = runAnalysis(c);
      for (final id in ['su_mosi', 'ho_mosi', 'su_miso', 'ho_miso', 'su_tx', 'ho_tx', 'su_rx', 'ho_rx']) {
        if (!has(off, id)) continue;
        final v = metric(off, id).value;
        if (!v.isFinite) {
          expect(metric(on, id).value, v, reason: '${p.name} $id');
          continue;
        }
        expect(metric(on, id).value, closeTo(metric(off, id).value, 1e-12), reason: '${p.name} $id');
      }
    }
  });

  test('SPI: a longer MISO trace reduces read setup slack', () {
    final c = AnalysisConfig.defaults(protocol: Protocol.spi)..spi.clockHz = 50e6;
    final base = runAnalysis(c);
    setPerSignal(c, true);
    setSignalLength(c, 'MISO', c.pcb.traceLength + 150e-3);
    final r = runAnalysis(c);
    expect(metric(r, 'su_miso').value, lessThan(metric(base, 'su_miso').value - 0.5e-9));
    expect(metric(r, 'su_mosi').value, closeTo(metric(base, 'su_mosi').value, 1e-12));
    expect(r.assumptions.any((a) => a.contains('MISO')), isTrue);
  });

  test('QSPI: IO spread is reported and checked on the longest and shortest line', () {
    final c = AnalysisConfig.defaults(protocol: Protocol.qspi);
    final base = runAnalysis(c);
    expect(has(base, 'io_spread'), isFalse);
    setPerSignal(c, true);
    setSignalLength(c, 'IO2', c.pcb.traceLength + 40e-3);
    setSignalLength(c, 'IO1', c.pcb.traceLength - 20e-3);
    final r = runAnalysis(c);
    final sp = metric(r, 'io_spread');
    expect(sp.value, greaterThan(300e-12));
    expect((sp.note ?? '').contains('IO1'), isTrue);
    expect((sp.note ?? '').contains('IO2'), isTrue);
    expect((metric(r, 'dcskew').note ?? '').contains('IO2'), isTrue);
    // The longest IO reduces write setup slack at the flash.
    expect(metric(r, 'su_mosi').value, lessThan(metric(base, 'su_mosi').value));
  });

  test('RGMII: a long TX data line hurts TX only and is named', () {
    final c = AnalysisConfig.defaults(protocol: Protocol.rgmii);
    final base = runAnalysis(c);
    setPerSignal(c, true);
    setSignalLength(c, 'TXD2', c.pcb.traceLength + 60e-3);
    final r = runAnalysis(c);
    final sp = metric(r, 'spread_tx');
    expect(sp.status, SiStatus.warning);
    expect((sp.note ?? '').contains('TXD2'), isTrue);
    expect(has(r, 'spread_rx'), isFalse);
    expect(metric(r, 'su_tx').value, lessThan(metric(base, 'su_tx').value - 0.2e-9));
    expect(metric(r, 'su_rx').value, closeTo(metric(base, 'su_rx').value, 5e-12));
    final f = r.findings.where((f) => f.title.startsWith('TX timing'));
    expect(f, isNotEmpty);
    expect(f.first.reason.contains('TXD2'), isTrue);
  });

  test('validation and JSON round trip', () {
    final c = AnalysisConfig.defaults(protocol: Protocol.rgmii);
    setPerSignal(c, true);
    setSignalLength(c, 'RXC', 0);
    expect(validateConfig(c).any((i) => i.field == 'RXC length' && i.blocking), isTrue);
    setSignalLength(c, 'RXC', 80e-3);
    final back = AnalysisConfig.fromJson(c.toJson());
    expect(perSignalOn(back), isTrue);
    expect(back.rgmii.signalLengths['RXC'], 80e-3);
    final q = AnalysisConfig.defaults(protocol: Protocol.qspi);
    expect(q.toJson().toString().contains('lens'), isFalse);
  });

  KicadBoard board(Map<String, double> nets) => KicadBoard(
        copperNames: const ['F.Cu', 'B.Cu'],
        stackup: null,
        nets: {for (final e in nets.entries) e.key: KicadNet(e.key)..length = e.value},
        pairs: const [],
        notes: const [],
      );

  test('KiCad bus import matches net names to signals', () {
    final c = AnalysisConfig.defaults(protocol: Protocol.spi);
    final b = board({
      '/SPI1_SCK': 0.042, '/SPI1_MOSI': 0.045, '/SPI1_MISO': 0.047, '/SPI1_CS': 0.040,
      '/SPI2_SCK': 0.1, 'SYS_CLK': 0.2, 'GND': 0.5,
    });
    final m = matchBusNets(c, b);
    expect(m['SCLK']!.name, '/SPI1_SCK');
    expect(m['CS']!.name, '/SPI1_CS');
    final notes = applyKicadBus(c, b, m);
    expect(perSignalOn(c), isTrue);
    expect(c.spi.signalLengths['MISO'], 0.047);
    expect(c.pcb.traceLength, 0.042);
    expect(notes.any((n) => n.contains('MISO ← /SPI1_MISO')), isTrue);

    final r = AnalysisConfig.defaults(protocol: Protocol.rgmii);
    final rb = board({
      'ETH_TXC': 0.05, 'ETH_TXD0': 0.051, 'ETH_TXD1': 0.052, 'ETH_TXD2': 0.05, 'ETH_TXD3': 0.049, 'ETH_TX_CTL': 0.05,
      'ETH_RX_CLK': 0.06, 'ETH_RXD0': 0.06, 'ETH_RXD1': 0.06, 'ETH_RXD2': 0.061, 'ETH_RXD3': 0.06, 'ETH_RX_DV': 0.06,
    });
    final rm = matchBusNets(r, rb);
    expect(rm.length, 12);
    expect(rm['RXC']!.name, 'ETH_RX_CLK');
    expect(rm['RX_CTL']!.name, 'ETH_RX_DV');
    expect(rm['TXD1']!.name, 'ETH_TXD1');
  });

  test('guideline sheet flags out-of-match lines', () {
    final c = AnalysisConfig.defaults(protocol: Protocol.rgmii);
    setPerSignal(c, true);
    setSignalLength(c, 'TXD2', c.pcb.traceLength + 20e-3);
    final g = computeGuidelines(c);
    final f = g.figures!;
    expect(f.signalNames.length, 12);
    expect(f.groupStarts, [6]);
    expect(f.lineOut![f.signalNames.indexOf('TXD2')], isTrue);
    expect(f.lineOut!.where((b) => b).length, 1);
    expect(f.currentLength, closeTo(c.pcb.traceLength + 20e-3, 1e-12));
    final item = g.sections.expand((s) => s.items).firstWhere((i) => i.label == 'Your per-signal lengths');
    expect(item.important, isTrue);
    expect(item.value.contains('TXD2'), isTrue);
  });
}
