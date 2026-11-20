/// Per-signal routed lengths for parallel buses (SPI, QSPI/OSPI, RGMII).
///
/// When per-signal lengths are off, every helper here returns the lengths
/// implied by the single trace length and the protocol's mismatch field, so
/// the simulation is unchanged.
library;

import 'dart:math' as math;

import 'config.dart';

enum SignalRole { clock, data, select, strobe }

class BusSignal {
  const BusSignal(this.name, this.role);
  final String name;
  final SignalRole role;
}

/// One source-synchronous group: a clock and the data lines timed to it.
class BusGroup {
  const BusGroup(this.label, this.clock, this.data, [this.other = const []]);
  final String label;
  final BusSignal clock;
  final List<BusSignal> data;
  final List<BusSignal> other;
  List<BusSignal> get all => [clock, ...data, ...other];
}

bool supportsSignalLengths(Protocol p) =>
    p == Protocol.spi || p == Protocol.qspi || p == Protocol.rgmii || p == Protocol.ddr;

List<BusGroup> busGroups(AnalysisConfig c) {
  switch (c.protocol) {
    case Protocol.spi:
      return const [
        BusGroup('SPI', BusSignal('SCLK', SignalRole.clock),
            [BusSignal('MOSI', SignalRole.data), BusSignal('MISO', SignalRole.data)], [BusSignal('CS', SignalRole.select)]),
      ];
    case Protocol.qspi:
      final q = c.qspi;
      return [
        BusGroup(
          q.ioWidth == 8 ? 'Octal SPI' : 'Quad SPI',
          const BusSignal('CLK', SignalRole.clock),
          [for (var i = 0; i < q.ioWidth; i++) BusSignal('IO$i', SignalRole.data)],
          [const BusSignal('CS#', SignalRole.select), if (q.dtr && q.useDqs) const BusSignal('DQS', SignalRole.strobe)],
        ),
      ];
    case Protocol.rgmii:
      BusGroup g(String d) => BusGroup(
            d,
            BusSignal('${d}C', SignalRole.clock),
            [for (var i = 0; i < 4; i++) BusSignal('${d}D$i', SignalRole.data), BusSignal('${d}_CTL', SignalRole.data)],
          );
      return [g('TX'), g('RX')];
    case Protocol.ddr:
      return [
        BusGroup('Byte lane', const BusSignal('DQS', SignalRole.strobe),
            [for (var i = 0; i < 8; i++) BusSignal('DQ$i', SignalRole.data), const BusSignal('DM', SignalRole.data)]),
      ];
    default:
      return const [];
  }
}

List<BusSignal> busSignals(AnalysisConfig c) => [for (final g in busGroups(c)) ...g.all];

bool perSignalOn(AnalysisConfig c) => switch (c.protocol) {
      Protocol.spi || Protocol.qspi => c.spiCfg.perSignalLengths,
      Protocol.rgmii => c.rgmii.perSignalLengths,
      Protocol.ddr => c.ddr.perSignalLengths,
      _ => false,
    };

Map<String, double> _store(AnalysisConfig c) => switch (c.protocol) {
      Protocol.rgmii => c.rgmii.signalLengths,
      Protocol.ddr => c.ddr.signalLengths,
      _ => c.spiCfg.signalLengths,
    };

/// Length implied by the single-length inputs (trace length + mismatch).
double defaultSignalLength(AnalysisConfig c, BusSignal s) {
  final l = c.pcb.traceLength;
  return switch (c.protocol) {
    Protocol.qspi => s.role == SignalRole.data ? l + c.qspi.dataClockMismatch : l,
    Protocol.rgmii => s.role == SignalRole.clock ? l + c.rgmii.clockExtraLength : l,
    _ => l,
  };
}

/// Routed length of [s] used by the simulation.
double signalLength(AnalysisConfig c, BusSignal s) {
  if (!perSignalOn(c)) return defaultSignalLength(c, s);
  return _store(c)[s.name] ?? defaultSignalLength(c, s);
}

/// Turns per-signal lengths on or off. Turning on fills missing entries with
/// the current single-length values.
void setPerSignal(AnalysisConfig c, bool on) {
  if (!supportsSignalLengths(c.protocol)) return;
  final store = _store(c);
  if (on) {
    for (final s in busSignals(c)) {
      store.putIfAbsent(s.name, () => defaultSignalLength(c, s));
    }
  }
  if (c.protocol == Protocol.rgmii) {
    c.rgmii.perSignalLengths = on;
  } else if (c.protocol == Protocol.ddr) {
    c.ddr.perSignalLengths = on;
  } else {
    c.spiCfg.perSignalLengths = on;
  }
}

void setSignalLength(AnalysisConfig c, String name, double length) => _store(c)[name] = length;

class GroupLengths {
  GroupLengths(this.group, this.lengths);
  final BusGroup group;
  final Map<String, double> lengths;

  double get clock => lengths[group.clock.name]!;
  double of(BusSignal s) => lengths[s.name]!;
  BusSignal get shortest => group.data.reduce((a, b) => of(a) <= of(b) ? a : b);
  BusSignal get longest => group.data.reduce((a, b) => of(a) >= of(b) ? a : b);
  double get dataMin => of(shortest);
  double get dataMax => of(longest);
  double get spread => dataMax - dataMin;

  /// Largest |data − clock| length difference and the line that has it.
  ({BusSignal signal, double diff}) get worstToClock {
    var best = group.data.first;
    for (final s in group.data) {
      if ((of(s) - clock).abs() > (of(best) - clock).abs()) best = s;
    }
    return (signal: best, diff: of(best) - clock);
  }

  double get longestAny => lengths.values.reduce(math.max);
  double get shortestAny => lengths.values.reduce(math.min);
}

List<GroupLengths> groupLengths(AnalysisConfig c) => [
      for (final g in busGroups(c)) GroupLengths(g, {for (final s in g.all) s.name: signalLength(c, s)}),
    ];
