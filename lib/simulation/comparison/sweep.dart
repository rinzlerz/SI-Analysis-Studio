/// Routing comparison and parameter sweeps (PRD Phase 4).
library;

import '../model/config.dart';

enum SweepParam {
  traceLength,
  traceWidth,
  traceSpacing,
  lengthMismatch,
  seriesR,
  driverImpedance,
  receiverCap,
  clock,
  dielectricHeight,
  viaStub,
  pullupR,
  clockDelay,
}

extension SweepParamInfo on SweepParam {
  String get label => switch (this) {
        SweepParam.traceLength => 'Trace length',
        SweepParam.traceWidth => 'Trace width',
        SweepParam.traceSpacing => 'Pair spacing',
        SweepParam.lengthMismatch => 'P/N length mismatch',
        SweepParam.seriesR => 'Series resistor',
        SweepParam.driverImpedance => 'Driver impedance',
        SweepParam.receiverCap => 'Receiver capacitance',
        SweepParam.clock => 'Clock frequency',
        SweepParam.dielectricHeight => 'Dielectric height to reference',
        SweepParam.viaStub => 'Via stub length (all vias)',
        SweepParam.pullupR => 'Pull-up resistor',
        SweepParam.clockDelay => 'Clock delay (TX and RX)',
      };

  /// SI unit of the swept value: 'm', 'ohm', 'F', 'Hz'.
  String get unit => switch (this) {
        SweepParam.seriesR || SweepParam.driverImpedance || SweepParam.pullupR => 'ohm',
        SweepParam.receiverCap => 'F',
        SweepParam.clock => 'Hz',
        SweepParam.clockDelay => 's',
        _ => 'm',
      };

  bool applies(AnalysisConfig c) => switch (this) {
        SweepParam.traceSpacing || SweepParam.lengthMismatch => c.protocol.differential && !_sp(c),
        SweepParam.clock => c.protocol.spiFamily || c.protocol == Protocol.i2c,
        SweepParam.seriesR =>
          c.protocol.spiFamily || c.protocol == Protocol.usb2 || c.protocol == Protocol.rgmii || c.protocol == Protocol.i2c,
        SweepParam.driverImpedance => c.protocol != Protocol.i2c,
        SweepParam.viaStub =>
          c.protocol != Protocol.i2c && c.pcb.elements.any((e) => e.type == ChannelElementType.via) && !_sp(c),
        SweepParam.traceLength || SweepParam.traceWidth || SweepParam.dielectricHeight => !_sp(c),
        SweepParam.pullupR => c.protocol == Protocol.i2c,
        SweepParam.clockDelay => c.protocol == Protocol.rgmii,
        _ => true,
      };

  static bool _sp(AnalysisConfig c) => c.protocol.serdes && c.serdes.useTouchstone;

  /// Current value in [c].
  double read(AnalysisConfig c) => switch (this) {
        SweepParam.traceLength => c.pcb.traceLength,
        SweepParam.traceWidth => c.pcb.traceWidth,
        SweepParam.traceSpacing => c.pcb.traceSpacing,
        SweepParam.lengthMismatch => c.pcb.lengthMismatch,
        SweepParam.seriesR => switch (c.protocol) {
            Protocol.usb2 => c.usb2.seriesR,
            Protocol.rgmii => c.rgmii.seriesR,
            Protocol.i2c => c.i2c.seriesR,
            _ => c.spiCfg.seriesR,
          },
        SweepParam.driverImpedance => switch (c.protocol) {
            Protocol.spi || Protocol.qspi => c.spiCfg.driverImpedance,
            Protocol.usb2 => c.usb2.driverImpedance,
            Protocol.rgmii => c.rgmii.driverImpedance,
            Protocol.i2c => c.i2c.rOn,
            Protocol.usb3 || Protocol.pcie || Protocol.hdmi => c.serdes.txImpedance,
          },
        SweepParam.receiverCap => switch (c.protocol) {
            Protocol.spi || Protocol.qspi => c.spiCfg.receiverCap,
            Protocol.usb2 => c.usb2.receiverCap,
            Protocol.rgmii => c.rgmii.receiverCap,
            Protocol.i2c => c.i2c.pinCap,
            Protocol.usb3 || Protocol.pcie || Protocol.hdmi => c.serdes.receiverCap,
          },
        SweepParam.clock => c.protocol == Protocol.i2c ? c.i2c.clockHz : c.spiCfg.clockHz,
        SweepParam.dielectricHeight => _refDielectric(c) == null ? 0 : c.pcb.stackup.dielectrics[_refDielectric(c)!],
        SweepParam.viaStub =>
          c.pcb.elements.firstWhere((e) => e.type == ChannelElementType.via, orElse: () => ChannelElement(type: ChannelElementType.via)).stubLength,
        SweepParam.pullupR => c.i2c.pullupR,
        SweepParam.clockDelay => c.rgmii.txClockDelay,
      };

  /// Returns a copy of [base] with this parameter set to [v].
  AnalysisConfig apply(AnalysisConfig base, double v) {
    final c = base.copy();
    switch (this) {
      case SweepParam.traceLength:
        c.pcb.traceLength = v;
        for (final e in c.pcb.elements) {
          // Keep elements at the same relative position along the route.
          if (base.pcb.traceLength > 0) e.position = e.position / base.pcb.traceLength * v;
        }
      case SweepParam.traceWidth:
        c.pcb.traceWidth = v;
      case SweepParam.traceSpacing:
        c.pcb.traceSpacing = v;
      case SweepParam.lengthMismatch:
        c.pcb.lengthMismatch = v;
      case SweepParam.seriesR:
        switch (c.protocol) {
          case Protocol.usb2:
            c.usb2.seriesR = v;
          case Protocol.rgmii:
            c.rgmii.seriesR = v;
          case Protocol.i2c:
            c.i2c.seriesR = v;
          default:
            final s = c.spiCfg;
            s.seriesR = v;
            if (!s.termination.hasSeries) {
              s.termination = s.termination.hasParallel ? TerminationScheme.seriesParallel : TerminationScheme.series;
            }
        }
      case SweepParam.driverImpedance:
        switch (c.protocol) {
          case Protocol.spi:
          case Protocol.qspi:
            c.spiCfg.driverImpedance = v;
          case Protocol.usb2:
            c.usb2.driverImpedance = v;
          case Protocol.rgmii:
            c.rgmii.driverImpedance = v;
          case Protocol.i2c:
            c.i2c.sinkCurrent = 0.4 / v;
          case Protocol.usb3:
          case Protocol.pcie:
          case Protocol.hdmi:
            c.serdes.txImpedance = v;
        }
      case SweepParam.receiverCap:
        switch (c.protocol) {
          case Protocol.spi:
          case Protocol.qspi:
            c.spiCfg.receiverCap = v;
          case Protocol.usb2:
            c.usb2.receiverCap = v;
          case Protocol.rgmii:
            c.rgmii.receiverCap = v;
          case Protocol.i2c:
            c.i2c.pinCap = v;
          case Protocol.usb3:
          case Protocol.pcie:
          case Protocol.hdmi:
            c.serdes.receiverCap = v;
        }
      case SweepParam.clock:
        if (c.protocol == Protocol.i2c) {
          c.i2c.clockHz = v;
        } else {
          c.spiCfg.clockHz = v;
        }
      case SweepParam.dielectricHeight:
        final i = _refDielectric(c);
        if (i != null) c.pcb.stackup.dielectrics[i] = v;
      case SweepParam.viaStub:
        for (final e in c.pcb.elements) {
          if (e.type == ChannelElementType.via) e.stubLength = v;
        }
      case SweepParam.pullupR:
        c.i2c.pullupR = v;
      case SweepParam.clockDelay:
        c.rgmii.txClockDelay = v;
        c.rgmii.rxClockDelay = v;
    }
    return c;
  }
}

/// Index of the dielectric between the routed layer and its nearest plane
/// (below first, else above).
int? _refDielectric(AnalysisConfig c) {
  final s = c.pcb.stackup;
  final i = s.signalLayer;
  if (i + 1 < s.layers.length && s.layers[i + 1].role.isPlane) return i;
  if (i - 1 >= 0 && s.layers[i - 1].role.isPlane) return i - 1;
  if (i + 1 < s.layers.length) return i;
  return i > 0 ? i - 1 : null;
}

/// Evenly spaced values from [from] to [to] (inclusive).
List<double> sweepValues(double from, double to, int steps) {
  if (steps <= 1) return [from];
  return List<double>.generate(steps, (k) => from + (to - from) * k / (steps - 1));
}

/// Metric ids worth comparing, most important first.
const List<String> keyMetricIds = [
  'z0',
  'zdiff',
  'zdev',
  'delay',
  'skew',
  'il',
  'overshoot',
  'undershoot',
  'rb_sclk',
  'settle',
  'su_mosi',
  'su_miso',
  'ho_miso',
  'rsd_rec',
  'cb',
  'tr',
  'tf',
  'vol',
  'thigh',
  'tsudat',
  'su_tx',
  'ho_tx',
  'su_rx',
  'ho_rx',
  'opt_delay',
  'eye_h',
  'eye_eq',
  'eye_raw',
  'eye_w',
  'eye_w_ber',
  'jitter',
  'mask_hits',
  'xt_next',
  'xt_fext',
];
