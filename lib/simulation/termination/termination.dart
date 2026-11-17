/// Termination and end-network models.
///
/// Source end (port 1):  Vs(t) --[R_driver + R_series]-- node1 --> line
/// Load end   (port 2):  line --> node2 with, to ground/VTT:
///     R_in   (receiver input resistance, to GND)
///     C_in   (receiver input capacitance, to GND)
///     R_term (parallel termination to VTT)               [optional]
///     R_ac + C_ac in series to GND (AC / RC termination) [optional]
///
/// Supported schemes: none, series (source), parallel (load), AC/RC (load),
/// series + parallel.
library;

import '../common/physics.dart';
import '../model/config.dart';
import '../reflection/reflection.dart';

class SourceEnd {
  const SourceEnd({required this.rDriver, this.rSeries = 0});

  final double rDriver;
  final double rSeries;

  double get rTotal => rDriver + rSeries;
}

class LoadEnd {
  const LoadEnd({
    this.rIn = double.infinity,
    this.cIn = 0,
    this.rTerm = double.infinity,
    this.vtt = 0,
    this.rAc = double.infinity,
    this.cAc = 0,
  });

  final double rIn;
  final double cIn;
  final double rTerm;
  final double vtt;
  final double rAc;
  final double cAc;

  bool get hasAc => cAc > 0 && rAc.isFinite;

  /// High-frequency resistive load seen by the line (capacitors as shorts
  /// for the AC branch, receiver capacitance ignored).
  double get rHighFrequency {
    var r = parallel(rIn, rTerm);
    if (hasAc) r = parallel(r, rAc);
    return r;
  }

  /// DC resistance of the load (AC branch open).
  double get rDc => parallel(rIn, rTerm);
}

/// Builds the end networks for a single-ended CMOS link from an SPI config.
({SourceEnd source, LoadEnd load}) spiEnds(SpiConfig c) {
  final scheme = c.termination;
  return (
    source: SourceEnd(
      rDriver: c.driverImpedance,
      rSeries: scheme.hasSeries ? c.seriesR : 0,
    ),
    load: LoadEnd(
      rIn: c.receiverRin,
      cIn: c.receiverCap,
      rTerm: scheme.hasParallel ? c.parallelR : double.infinity,
      vtt: c.vtt,
      rAc: scheme.hasAc ? c.acR : double.infinity,
      cAc: scheme.hasAc ? c.acC : 0,
    ),
  );
}

/// End networks of one leg of a USB 2.0 pair.
({SourceEnd source, LoadEnd load}) usb2LegEnds(Usb2Config c) => (
      source: SourceEnd(rDriver: c.driverImpedance, rSeries: c.seriesR),
      load: LoadEnd(
        rIn: c.receiverRin,
        cIn: c.receiverCap,
        rTerm: c.rxTermEnabled ? c.rxTermR : double.infinity,
        vtt: 0,
      ),
    );

/// DC operating voltage at the (lossless) line for a source level [vs].
double dcLineVoltage(double vs, SourceEnd s, LoadEnd l) {
  final gs = 1 / s.rTotal;
  final gr = l.rIn.isFinite ? 1 / l.rIn : 0.0;
  final gt = l.rTerm.isFinite ? 1 / l.rTerm : 0.0;
  return (vs * gs + l.vtt * gt) / (gs + gr + gt);
}

double sourceReflection(SourceEnd s, double z0) => reflectionCoefficient(s.rTotal, z0);

double loadReflection(LoadEnd l, double z0) =>
    reflectionCoefficient(l.rHighFrequency, z0);
