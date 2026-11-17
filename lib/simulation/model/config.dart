/// Analysis configuration models (pure Dart, JSON-serialisable).
///
/// Every value is stored in base SI units. UI layers convert to engineering
/// display units (mil, mm, ns, pF, MHz ...).
library;

import '../common/format.dart';
import '../common/physics.dart';
import '../ibis/ibis.dart';
import '../sparams/touchstone.dart';

/// Version of the simulation model. Stored with every analysis so that saved
/// results can be traced back to the equations that produced them.
const String simulationModelVersion = 'SIM-1.3.0';

enum Protocol { usb2, usb3, pcie, hdmi, spi, qspi, i2c, rgmii }

extension ProtocolInfo on Protocol {
  String get label => switch (this) {
        Protocol.usb2 => 'USB 2.0',
        Protocol.usb3 => 'USB 3.0',
        Protocol.pcie => 'PCI Express',
        Protocol.hdmi => 'HDMI',
        Protocol.spi => 'SPI',
        Protocol.qspi => 'QSPI / Octal SPI',
        Protocol.i2c => 'I²C',
        Protocol.rgmii => 'Ethernet RGMII',
      };

  /// Short tag for compact UI (chips, avatars).
  String get tag => switch (this) {
        Protocol.usb2 => 'USB2',
        Protocol.usb3 => 'USB3',
        Protocol.pcie => 'PCIe',
        Protocol.hdmi => 'HDMI',
        Protocol.spi => 'SPI',
        Protocol.qspi => 'QSPI',
        Protocol.i2c => 'I²C',
        Protocol.rgmii => 'RGMII',
      };

  /// One-line description for protocol pickers.
  String get description => switch (this) {
        Protocol.usb2 => '90 Ω differential · HS 480 Mb/s or FS 12 Mb/s',
        Protocol.usb3 => '90 Ω differential · 5 Gb/s · de-emphasis, CTLE',
        Protocol.pcie => '85 Ω differential · Gen 1–5 · presets, CTLE, DFE',
        Protocol.hdmi => '100 Ω differential · TMDS 1.65–6 Gb/s, FRL 12 Gb/s',
        Protocol.spi => 'Single-ended · SCLK / MOSI / MISO / CS · modes 0–3',
        Protocol.qspi => 'Flash bus · x4 / x8 · SDR or DTR · read sample delay',
        Protocol.i2c => 'Open-drain · pull-up sizing · rise time · bus capacitance',
        Protocol.rgmii => 'Ethernet MAC–PHY · 125 MHz DDR · 2 ns clock delay',
      };

  /// All protocols have a working simulation model.
  bool get supported => true;

  /// High-speed serial links simulated with the SerDes model.
  bool get serdes => this == Protocol.usb3 || this == Protocol.pcie || this == Protocol.hdmi;

  bool get differential =>
      this == Protocol.usb2 || this == Protocol.usb3 || this == Protocol.pcie || this == Protocol.hdmi;

  /// Uses the SPI engine (SPI and QSPI/OSPI).
  bool get spiFamily => this == Protocol.spi || this == Protocol.qspi;
}

enum LayerRole { signal, ground, power }

extension LayerRoleInfo on LayerRole {
  String get label => switch (this) {
        LayerRole.signal => 'Signal',
        LayerRole.ground => 'GND',
        LayerRole.power => 'PWR',
      };
  bool get isPlane => this != LayerRole.signal;
}

enum TerminationScheme { none, series, parallel, acRc, seriesParallel }

extension TerminationInfo on TerminationScheme {
  String get label => switch (this) {
        TerminationScheme.none => 'None',
        TerminationScheme.series => 'Series (source)',
        TerminationScheme.parallel => 'Parallel (load to VTT)',
        TerminationScheme.acRc => 'AC / RC (load)',
        TerminationScheme.seriesParallel => 'Series + Parallel',
      };
  bool get hasSeries =>
      this == TerminationScheme.series || this == TerminationScheme.seriesParallel;
  bool get hasParallel =>
      this == TerminationScheme.parallel || this == TerminationScheme.seriesParallel;
  bool get hasAc => this == TerminationScheme.acRc;
}

enum Usb2Speed { fullSpeed, highSpeed }

extension Usb2SpeedInfo on Usb2Speed {
  String get label => this == Usb2Speed.highSpeed ? 'High-Speed (480 Mbps)' : 'Full-Speed (12 Mbps)';
  double get bitRate => this == Usb2Speed.highSpeed ? 480e6 : 12e6;
}

enum DataPattern { prbs7, alternating, custom }

extension DataPatternInfo on DataPattern {
  String get label => switch (this) {
        DataPattern.prbs7 => 'PRBS7',
        DataPattern.alternating => '1010 alternating',
        DataPattern.custom => 'Custom (hex / binary)',
      };
}

T _enum<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

double _d(Object? v, double fallback) => v is num ? v.toDouble() : fallback;
int _i(Object? v, int fallback) => v is num ? v.toInt() : fallback;
bool _b(Object? v, bool fallback) => v is bool ? v : fallback;

// ---------------------------------------------------------------------------
// PCB stackup
// ---------------------------------------------------------------------------

class StackupLayer {
  StackupLayer({required this.role, required this.copperThickness});

  LayerRole role;

  /// Copper thickness (m).
  double copperThickness;

  StackupLayer copy() => StackupLayer(role: role, copperThickness: copperThickness);

  Map<String, Object?> toJson() => {'role': role.name, 't': copperThickness};

  factory StackupLayer.fromJson(Map<String, Object?> j) => StackupLayer(
        role: _enum(LayerRole.values, j['role'], LayerRole.signal),
        copperThickness: _d(j['t'], copperOz),
      );
}

/// Simplified mobile stackup: copper layers separated by dielectrics with a
/// single (Dk, Df) material.
class StackupConfig {
  StackupConfig({
    required this.layers,
    required this.dielectrics,
    required this.dk,
    required this.df,
    required this.signalLayer,
    this.roughnessRms = 0,
  });

  /// RMS copper surface roughness (m) for the Hammerstad-Groiss conductor
  /// loss correction. 0 = smooth copper.
  double roughnessRms;

  /// Copper layers, top (L1) to bottom.
  List<StackupLayer> layers;

  /// Dielectric thickness between layer i and i+1 (m). Length = layers - 1.
  List<double> dielectrics;

  /// Relative permittivity (Dk) of the dielectric.
  double dk;

  /// Dissipation factor (Df, loss tangent).
  double df;

  /// Index of the routed signal layer in [layers].
  int signalLayer;

  int get layerCount => layers.length;

  double get totalThickness =>
      layers.fold<double>(0, (a, l) => a + l.copperThickness) +
      dielectrics.fold<double>(0, (a, d) => a + d);

  StackupConfig copy() => StackupConfig(
        layers: layers.map((l) => l.copy()).toList(),
        dielectrics: List.of(dielectrics),
        dk: dk,
        df: df,
        signalLayer: signalLayer,
        roughnessRms: roughnessRms,
      );

  Map<String, Object?> toJson() => {
        'rough': roughnessRms,
        'layers': layers.map((l) => l.toJson()).toList(),
        'dielectrics': dielectrics,
        'dk': dk,
        'df': df,
        'signalLayer': signalLayer,
      };

  factory StackupConfig.fromJson(Map<String, Object?> j) {
    final layers = (j['layers'] as List? ?? const [])
        .map((e) => StackupLayer.fromJson((e as Map).cast<String, Object?>()))
        .toList();
    final diel = (j['dielectrics'] as List? ?? const []).map((e) => _d(e, 0.2e-3)).toList();
    if (layers.length < 2 || diel.length != layers.length - 1) {
      return StackupConfig.preset(4);
    }
    return StackupConfig(
      layers: layers,
      dielectrics: diel,
      dk: _d(j['dk'], 4.2),
      df: _d(j['df'], 0.02),
      signalLayer: _i(j['signalLayer'], 0).clamp(0, layers.length - 1),
      // Analyses saved before SIM-1.1.0 had no roughness: keep them smooth.
      roughnessRms: _d(j['rough'], 0),
    );
  }

  /// Typical FR-4 stackups (approx. 1.6 mm finished thickness).
  factory StackupConfig.preset(int layerCount) => _preset(layerCount)..roughnessRms = 1.0e-6;

  static StackupConfig _preset(int layerCount) {
    const outer = copperOz * 1.4; // 1 oz base + plating ~ 1.4 mil
    const inner = copperOz; // 1 oz
    StackupLayer s(LayerRole r, double t) => StackupLayer(role: r, copperThickness: t);
    switch (layerCount) {
      case 2:
        return StackupConfig(
          layers: [s(LayerRole.signal, outer), s(LayerRole.ground, outer)],
          dielectrics: [1.51e-3],
          dk: 4.5,
          df: 0.02,
          signalLayer: 0,
        );
      case 6:
        return StackupConfig(
          layers: [
            s(LayerRole.signal, outer),
            s(LayerRole.ground, inner),
            s(LayerRole.signal, inner),
            s(LayerRole.power, inner),
            s(LayerRole.ground, inner),
            s(LayerRole.signal, outer),
          ],
          dielectrics: [0.1e-3, 0.2e-3, 0.71e-3, 0.2e-3, 0.1e-3],
          dk: 4.2,
          df: 0.02,
          signalLayer: 0,
        );
      case 8:
        return StackupConfig(
          layers: [
            s(LayerRole.signal, outer),
            s(LayerRole.ground, inner),
            s(LayerRole.signal, inner),
            s(LayerRole.ground, inner),
            s(LayerRole.power, inner),
            s(LayerRole.signal, inner),
            s(LayerRole.ground, inner),
            s(LayerRole.signal, outer),
          ],
          dielectrics: [0.1e-3, 0.15e-3, 0.15e-3, 0.3e-3, 0.15e-3, 0.15e-3, 0.1e-3],
          dk: 4.2,
          df: 0.02,
          signalLayer: 0,
        );
      case 4:
      default:
        return StackupConfig(
          layers: [
            s(LayerRole.signal, outer),
            s(LayerRole.ground, inner),
            s(LayerRole.power, inner),
            s(LayerRole.signal, outer),
          ],
          dielectrics: [0.2e-3, 1.065e-3, 0.2e-3],
          dk: 4.2,
          df: 0.02,
          signalLayer: 0,
        );
    }
  }
}


/// Differential-impedance model.
enum DiffModel { ipc2141, coupled }

extension DiffModelInfo on DiffModel {
  String get label => this == DiffModel.coupled
      ? 'Coupled-line (Kirschning-Jansen / Cohn)'
      : 'IPC-2141 approximation';
}

enum ChannelElementType { via, acCap, segment, shuntCap }

extension ChannelElementTypeInfo on ChannelElementType {
  String get label => switch (this) {
        ChannelElementType.via => 'Via (layer transition)',
        ChannelElementType.acCap => 'AC-coupling capacitor',
        ChannelElementType.segment => 'Connector / package segment',
        ChannelElementType.shuntCap => 'Shunt C (ESD / test pad)',
      };
}

/// A discontinuity placed along the route (PRD Phase 3).
class ChannelElement {
  ChannelElement({
    required this.type,
    this.position = 0,
    this.drill = 0.25e-3,
    this.pad = 0.5e-3,
    this.antipad = 0.8e-3,
    this.barrelLength = 1.0e-3,
    this.stubLength = 0.5e-3,
    this.capacitance = 100e-9,
    this.esl = 0.4e-9,
    this.padCap = 0.3e-12,
    this.z = 90,
    this.delay = 50e-12,
  });

  ChannelElementType type;

  /// Distance from the TX pin (m).
  double position;

  // Via geometry (m).
  double drill;
  double pad;
  double antipad;

  /// Barrel length between the two routed layers (m).
  double barrelLength;

  /// Unused via stub length (m); 0 = back-drilled / blind.
  double stubLength;

  /// AC-cap value or shunt capacitance (F).
  double capacitance;

  /// AC-cap equivalent series inductance (H).
  double esl;

  /// AC-cap mounting-pad capacitance (F).
  double padCap;

  /// Segment impedance (ohm; differential for differential protocols).
  double z;

  /// Segment one-way delay (s).
  double delay;

  ChannelElement copy() => ChannelElement.fromJson(toJson());

  Map<String, Object?> toJson() => {
        'type': type.name,
        'pos': position,
        'drill': drill,
        'pad': pad,
        'antipad': antipad,
        'barrel': barrelLength,
        'stub': stubLength,
        'c': capacitance,
        'esl': esl,
        'padC': padCap,
        'z': z,
        'delay': delay,
      };

  factory ChannelElement.fromJson(Map<String, Object?> j) {
    final d = ChannelElement(type: ChannelElementType.via);
    return ChannelElement(
      type: _enum(ChannelElementType.values, j['type'], ChannelElementType.via),
      position: _d(j['pos'], d.position),
      drill: _d(j['drill'], d.drill),
      pad: _d(j['pad'], d.pad),
      antipad: _d(j['antipad'], d.antipad),
      barrelLength: _d(j['barrel'], d.barrelLength),
      stubLength: _d(j['stub'], d.stubLength),
      capacitance: _d(j['c'], d.capacitance),
      esl: _d(j['esl'], d.esl),
      padCap: _d(j['padC'], d.padCap),
      z: _d(j['z'], d.z),
      delay: _d(j['delay'], d.delay),
    );
  }
}

/// Crosstalk from a parallel aggressor trace (PRD Phase 3).
class CrosstalkConfig {
  CrosstalkConfig({this.enabled = false, this.spacing = 0.3e-3, this.coupledLength = 25e-3});

  bool enabled;

  /// Edge-to-edge spacing between aggressor and victim (m).
  double spacing;

  /// Parallel (coupled) length (m).
  double coupledLength;

  Map<String, Object?> toJson() => {'on': enabled, 's': spacing, 'len': coupledLength};

  factory CrosstalkConfig.fromJson(Map<String, Object?> j) => CrosstalkConfig(
        enabled: _b(j['on'], false),
        spacing: _d(j['s'], 0.3e-3),
        coupledLength: _d(j['len'], 25e-3),
      );
}

/// Trace routing geometry on the selected signal layer.
class PcbConfig {
  PcbConfig({
    required this.stackup,
    required this.traceWidth,
    required this.traceSpacing,
    required this.traceLength,
    required this.lengthMismatch,
    this.diffModel = DiffModel.coupled,
    List<ChannelElement>? elements,
    CrosstalkConfig? crosstalk,
  })  : elements = elements ?? [],
        crosstalk = crosstalk ?? CrosstalkConfig();

  StackupConfig stackup;
  DiffModel diffModel;

  /// Discontinuities along the route, sorted by position when simulated.
  List<ChannelElement> elements;
  CrosstalkConfig crosstalk;

  /// Trace width (m).
  double traceWidth;

  /// Edge-to-edge spacing of a differential pair (m). Ignored for single-ended.
  double traceSpacing;

  /// Routed length of the (P) trace (m).
  double traceLength;

  /// Extra length of the N trace relative to P (m). Differential only.
  double lengthMismatch;

  PcbConfig copy() => PcbConfig(
        stackup: stackup.copy(),
        traceWidth: traceWidth,
        traceSpacing: traceSpacing,
        traceLength: traceLength,
        lengthMismatch: lengthMismatch,
        diffModel: diffModel,
        elements: elements.map((e) => e.copy()).toList(),
        crosstalk: CrosstalkConfig.fromJson(crosstalk.toJson()),
      );

  Map<String, Object?> toJson() => {
        'diffModel': diffModel.name,
        'elements': elements.map((e) => e.toJson()).toList(),
        'xtalk': crosstalk.toJson(),
        'stackup': stackup.toJson(),
        'w': traceWidth,
        's': traceSpacing,
        'len': traceLength,
        'mismatch': lengthMismatch,
      };

  factory PcbConfig.fromJson(Map<String, Object?> j) => PcbConfig(
        stackup: j['stackup'] is Map
            ? StackupConfig.fromJson((j['stackup'] as Map).cast<String, Object?>())
            : StackupConfig.preset(4),
        traceWidth: _d(j['w'], 0.2e-3),
        traceSpacing: _d(j['s'], 0.2e-3),
        traceLength: _d(j['len'], 50e-3),
        lengthMismatch: _d(j['mismatch'], 0),
        // Analyses saved before SIM-1.2.0 used the IPC-2141 approximation.
        diffModel: _enum(DiffModel.values, j['diffModel'], DiffModel.ipc2141),
        elements: (j['elements'] as List? ?? const [])
            .map((e) => ChannelElement.fromJson((e as Map).cast<String, Object?>()))
            .toList(),
        crosstalk: j['xtalk'] is Map
            ? CrosstalkConfig.fromJson((j['xtalk'] as Map).cast<String, Object?>())
            : null,
      );
}

// ---------------------------------------------------------------------------
// Protocol configurations
// ---------------------------------------------------------------------------

class SpiConfig {
  SpiConfig({
    this.clockHz = 25e6,
    this.mode = 0,
    this.voltage = 3.3,
    this.riseTime = 1e-9,
    this.fallTime = 1e-9,
    this.driverImpedance = 25,
    this.termination = TerminationScheme.series,
    this.seriesR = 22,
    this.parallelR = 50,
    this.vtt = 0,
    this.acR = 50,
    this.acC = 100e-12,
    this.receiverCap = 5e-12,
    this.receiverRin = 1e6,
    this.vihFraction = 0.7,
    this.vilFraction = 0.3,
    this.slaveTco = 6e-9,
    this.setupTime = 3e-9,
    this.holdTime = 1e-9,
    this.targetZ0 = 50,
    this.useIbis = false,
    this.ibisDriver,
    this.ibisReceiver,
    this.ibisCorner = IbisCorner.typ,
    this.ioWidth = 4,
    this.dtr = false,
    this.useDqs = false,
    this.dataClockMismatch = 0,
    this.readSampleDelay = 0,
  });

  /// QSPI / OSPI only: number of IO lines (4 or 8).
  int ioWidth;

  /// QSPI / OSPI only: double transfer rate (data on both clock edges).
  bool dtr;

  /// OSPI only: read data captured with the flash data strobe (DQS) instead
  /// of the controller clock.
  bool useDqs;

  /// QSPI / OSPI only: IO trace length minus clock trace length (m).
  double dataClockMismatch;

  /// QSPI / OSPI only: controller read-capture delay after the nominal
  /// sampling edge (s).
  double readSampleDelay;

  /// Typical quad / octal SPI NOR flash defaults (104 MHz SDR, 3.3 V).
  factory SpiConfig.qspi() => SpiConfig(
        clockHz: 104e6,
        riseTime: 0.8e-9,
        fallTime: 0.8e-9,
        driverImpedance: 30,
        seriesR: 22,
        receiverCap: 6e-12,
        slaveTco: 6e-9,
        setupTime: 2e-9,
        holdTime: 2e-9,
      );

  /// Level 3: use imported IBIS buffer models for all SPI drivers/receivers.
  bool useIbis;
  IbisModel? ibisDriver;
  IbisModel? ibisReceiver;
  IbisCorner ibisCorner;

  double clockHz;

  /// SPI mode 0..3 (CPOL = mode >> 1, CPHA = mode & 1).
  int mode;

  /// I/O supply voltage VDD (V).
  double voltage;
  double riseTime; // 10-90 %
  double fallTime; // 90-10 %
  double driverImpedance;
  TerminationScheme termination;
  double seriesR;
  double parallelR;

  /// Parallel-termination voltage (V).
  double vtt;
  double acR;
  double acC;
  double receiverCap;
  double receiverRin;
  double vihFraction;
  double vilFraction;

  /// Peripheral clock-to-output delay for MISO (s).
  double slaveTco;

  /// Receiver input setup / hold requirement (s), applied to both ends.
  double setupTime;
  double holdTime;

  /// Single-ended impedance target (ohm).
  double targetZ0;

  bool get cpol => (mode >> 1) == 1;
  bool get cpha => (mode & 1) == 1;

  SpiConfig copy() => SpiConfig.fromJson(toJson());

  Map<String, Object?> toJson() => {
        'clockHz': clockHz,
        'mode': mode,
        'voltage': voltage,
        'tr': riseTime,
        'tf': fallTime,
        'rdrv': driverImpedance,
        'term': termination.name,
        'rser': seriesR,
        'rpar': parallelR,
        'vtt': vtt,
        'acR': acR,
        'acC': acC,
        'cin': receiverCap,
        'rin': receiverRin,
        'vih': vihFraction,
        'vil': vilFraction,
        'tco': slaveTco,
        'tsu': setupTime,
        'th': holdTime,
        'z0t': targetZ0,
        'useIbis': useIbis,
        if (ibisDriver != null) 'ibisDrv': ibisDriver!.toJson(),
        if (ibisReceiver != null) 'ibisRx': ibisReceiver!.toJson(),
        'ibisCorner': ibisCorner.name,
        'io': ioWidth,
        'dtr': dtr,
        'dqs': useDqs,
        'dcm': dataClockMismatch,
        'rsd': readSampleDelay,
      };

  factory SpiConfig.fromJson(Map<String, Object?> j) {
    final d = SpiConfig();
    return SpiConfig(
      clockHz: _d(j['clockHz'], d.clockHz),
      mode: _i(j['mode'], d.mode).clamp(0, 3),
      voltage: _d(j['voltage'], d.voltage),
      riseTime: _d(j['tr'], d.riseTime),
      fallTime: _d(j['tf'], d.fallTime),
      driverImpedance: _d(j['rdrv'], d.driverImpedance),
      termination: _enum(TerminationScheme.values, j['term'], d.termination),
      seriesR: _d(j['rser'], d.seriesR),
      parallelR: _d(j['rpar'], d.parallelR),
      vtt: _d(j['vtt'], d.vtt),
      acR: _d(j['acR'], d.acR),
      acC: _d(j['acC'], d.acC),
      receiverCap: _d(j['cin'], d.receiverCap),
      receiverRin: _d(j['rin'], d.receiverRin),
      vihFraction: _d(j['vih'], d.vihFraction),
      vilFraction: _d(j['vil'], d.vilFraction),
      slaveTco: _d(j['tco'], d.slaveTco),
      setupTime: _d(j['tsu'], d.setupTime),
      holdTime: _d(j['th'], d.holdTime),
      targetZ0: _d(j['z0t'], d.targetZ0),
      useIbis: _b(j['useIbis'], false),
      ibisDriver: IbisModel.fromJson(j['ibisDrv']),
      ibisReceiver: IbisModel.fromJson(j['ibisRx']),
      ibisCorner: _enum(IbisCorner.values, j['ibisCorner'], IbisCorner.typ),
      ioWidth: _i(j['io'], 4) == 8 ? 8 : 4,
      dtr: _b(j['dtr'], false),
      useDqs: _b(j['dqs'], false),
      dataClockMismatch: _d(j['dcm'], 0),
      readSampleDelay: _d(j['rsd'], 0),
    );
  }
}

// ---------------------------------------------------------------------------
// I2C
// ---------------------------------------------------------------------------

enum I2cMode { standard, fast, fastPlus }

extension I2cModeInfo on I2cMode {
  String get label => switch (this) {
        I2cMode.standard => 'Standard-mode (100 kHz)',
        I2cMode.fast => 'Fast-mode (400 kHz)',
        I2cMode.fastPlus => 'Fast-mode Plus (1 MHz)',
      };

  // NXP UM10204 (I2C-bus specification) Table 10 limits.
  double get fMax => const [100e3, 400e3, 1e6][index];

  /// Maximum rise time, 30 % -> 70 % of VDD (s).
  double get trMax => const [1000e-9, 300e-9, 120e-9][index];

  /// Maximum fall time, 70 % -> 30 % of VDD (s).
  double get tfMax => const [300e-9, 300e-9, 120e-9][index];
  double get tLowMin => const [4.7e-6, 1.3e-6, 0.5e-6][index];
  double get tHighMin => const [4.0e-6, 0.6e-6, 0.26e-6][index];
  double get tSuDatMin => const [250e-9, 100e-9, 50e-9][index];

  /// Maximum capacitive load per bus line (F).
  double get cbMax => const [400e-12, 400e-12, 550e-12][index];

  /// Minimum sink current at VOL = 0.4 V (A).
  double get iol => const [3e-3, 3e-3, 20e-3][index];
}

class I2cConfig {
  I2cConfig({
    this.mode = I2cMode.fast,
    this.clockHz = 400e3,
    this.voltage = 3.3,
    this.pullupR = 2.2e3,
    this.pullupAtTarget = false,
    this.deviceCount = 3,
    this.pinCap = 5e-12,
    this.extraCap = 0,
    this.sinkCurrent = 3e-3,
    this.driverFallTime = 60e-9,
    this.sclLowFraction = 0.58,
    this.seriesR = 0,
    this.targetZ0 = 50,
  });

  I2cMode mode;
  double clockHz;
  double voltage;

  /// Pull-up resistor on each line (ohm).
  double pullupR;

  /// Pull-up placed at the far (target) end instead of the controller.
  bool pullupAtTarget;

  /// Number of devices on the bus, including the controller.
  int deviceCount;

  /// Input/output capacitance per device pin (F); spec maximum 10 pF.
  double pinCap;

  /// Other capacitance on the line: connectors, cable, ESD diodes (F).
  double extraCap;

  /// Driver sink current at VOL = 0.4 V (A); sets the on-resistance.
  double sinkCurrent;

  /// Driver output fall ramp, VDD -> 0 (s); 70-30 % fall ≈ 0.4 × ramp.
  double driverFallTime;

  /// Fraction of the SCL period the controller drives SCL low.
  double sclLowFraction;

  /// Optional series resistor at each device pin (ohm); 0 = none.
  double seriesR;

  /// Single-ended impedance target (informative for I2C).
  double targetZ0;

  /// Driver on-resistance from VOL = 0.4 V at the sink current.
  double get rOn => 0.4 / sinkCurrent;

  void applyModeDefaults() {
    clockHz = mode.fMax;
    sinkCurrent = mode.iol;
    switch (mode) {
      case I2cMode.standard:
        pullupR = 4.7e3;
        driverFallTime = 100e-9;
        sclLowFraction = 0.5;
      case I2cMode.fast:
        pullupR = 2.2e3;
        driverFallTime = 60e-9;
        sclLowFraction = 0.58;
      case I2cMode.fastPlus:
        pullupR = 1e3;
        driverFallTime = 50e-9;
        sclLowFraction = 0.55;
    }
  }

  I2cConfig copy() => I2cConfig.fromJson(toJson());

  Map<String, Object?> toJson() => {
        'mode': mode.name,
        'f': clockHz,
        'vdd': voltage,
        'rp': pullupR,
        'rpFar': pullupAtTarget,
        'n': deviceCount,
        'cpin': pinCap,
        'cx': extraCap,
        'iol': sinkCurrent,
        'tfd': driverFallTime,
        'low': sclLowFraction,
        'rs': seriesR,
        'z0t': targetZ0,
      };

  factory I2cConfig.fromJson(Map<String, Object?> j) {
    final d = I2cConfig();
    return I2cConfig(
      mode: _enum(I2cMode.values, j['mode'], d.mode),
      clockHz: _d(j['f'], d.clockHz),
      voltage: _d(j['vdd'], d.voltage),
      pullupR: _d(j['rp'], d.pullupR),
      pullupAtTarget: _b(j['rpFar'], d.pullupAtTarget),
      deviceCount: _i(j['n'], d.deviceCount),
      pinCap: _d(j['cpin'], d.pinCap),
      extraCap: _d(j['cx'], d.extraCap),
      sinkCurrent: _d(j['iol'], d.sinkCurrent),
      driverFallTime: _d(j['tfd'], d.driverFallTime),
      sclLowFraction: _d(j['low'], d.sclLowFraction),
      seriesR: _d(j['rs'], d.seriesR),
      targetZ0: _d(j['z0t'], d.targetZ0),
    );
  }
}

// ---------------------------------------------------------------------------
// Ethernet RGMII
// ---------------------------------------------------------------------------

enum RgmiiSpeed { g1000, m100, m10 }

extension RgmiiSpeedInfo on RgmiiSpeed {
  String get label => const ['1000 Mb/s (125 MHz DDR)', '100 Mb/s (25 MHz)', '10 Mb/s (2.5 MHz)'][index];
  double get clockHz => const [125e6, 25e6, 2.5e6][index];

  /// Data on both clock edges at 1000 Mb/s, on the rising edge otherwise.
  bool get ddr => this == RgmiiSpeed.g1000;
}

class RgmiiConfig {
  RgmiiConfig({
    this.speed = RgmiiSpeed.g1000,
    this.voltage = 2.5,
    this.riseTime = 0.5e-9,
    this.fallTime = 0.5e-9,
    this.driverImpedance = 30,
    this.seriesR = 22,
    this.receiverCap = 3e-12,
    this.txClockDelay = 2e-9,
    this.rxClockDelay = 2e-9,
    this.clockExtraLength = 0,
    this.txSkew = 0.5e-9,
    this.setupTime = 1.0e-9,
    this.holdTime = 1.0e-9,
    this.targetZ0 = 50,
  });

  RgmiiSpeed speed;
  double voltage;
  double riseTime;
  double fallTime;
  double driverImpedance;

  /// Source series resistor (ohm); 0 = none.
  double seriesR;
  double receiverCap;

  /// Clock delay added inside the MAC (TX) or PHY (RX) - "RGMII-ID" (s).
  /// 0 = no internal delay (delay must come from the PCB clock trace).
  double txClockDelay;
  double rxClockDelay;

  /// Clock trace length minus data trace length (m); positive = PCB delay.
  double clockExtraLength;

  /// Transmitter clock-to-data skew, RGMII TskewT (± s).
  double txSkew;

  /// Receiver setup / hold requirement, RGMII TsetupR / TholdR (s).
  double setupTime;
  double holdTime;
  double targetZ0;

  RgmiiConfig copy() => RgmiiConfig.fromJson(toJson());

  Map<String, Object?> toJson() => {
        'speed': speed.name,
        'vdd': voltage,
        'tr': riseTime,
        'tf': fallTime,
        'rdrv': driverImpedance,
        'rser': seriesR,
        'cin': receiverCap,
        'txd': txClockDelay,
        'rxd': rxClockDelay,
        'clkx': clockExtraLength,
        'skew': txSkew,
        'tsu': setupTime,
        'th': holdTime,
        'z0t': targetZ0,
      };

  factory RgmiiConfig.fromJson(Map<String, Object?> j) {
    final d = RgmiiConfig();
    return RgmiiConfig(
      speed: _enum(RgmiiSpeed.values, j['speed'], d.speed),
      voltage: _d(j['vdd'], d.voltage),
      riseTime: _d(j['tr'], d.riseTime),
      fallTime: _d(j['tf'], d.fallTime),
      driverImpedance: _d(j['rdrv'], d.driverImpedance),
      seriesR: _d(j['rser'], d.seriesR),
      receiverCap: _d(j['cin'], d.receiverCap),
      txClockDelay: _d(j['txd'], d.txClockDelay),
      rxClockDelay: _d(j['rxd'], d.rxClockDelay),
      clockExtraLength: _d(j['clkx'], d.clockExtraLength),
      txSkew: _d(j['skew'], d.txSkew),
      setupTime: _d(j['tsu'], d.setupTime),
      holdTime: _d(j['th'], d.holdTime),
      targetZ0: _d(j['z0t'], d.targetZ0),
    );
  }
}

class Usb2Config {
  Usb2Config({
    this.speed = Usb2Speed.highSpeed,
    this.riseTime = 500e-12,
    this.fallTime = 500e-12,
    this.driverImpedance = 45,
    this.seriesR = 0,
    this.rxTermEnabled = true,
    this.rxTermR = 45,
    this.receiverCap = 1.5e-12,
    this.receiverRin = 1e6,
    this.targetZdiff = 90,
  });

  Usb2Speed speed;
  double riseTime;
  double fallTime;

  /// Driver output impedance per leg (ohm). HS: 45 ohm nominal termination.
  double driverImpedance;

  /// External series resistor per leg (ohm).
  double seriesR;

  /// Receiver-side termination per leg to GND (HS on-die 45 ohm).
  bool rxTermEnabled;
  double rxTermR;
  double receiverCap; // per leg
  double receiverRin; // per leg
  double targetZdiff;

  /// Open-circuit driver voltage per leg (V).
  /// HS: 17.78 mA into 45 ohm source termination -> 0.8 V Thevenin source.
  /// FS: CMOS 3.3 V driver.
  double get sourceHigh => speed == Usb2Speed.highSpeed ? 0.8 : 3.3;

  /// Resets speed-dependent values to typical defaults.
  void applySpeedDefaults() {
    if (speed == Usb2Speed.highSpeed) {
      riseTime = 500e-12;
      fallTime = 500e-12;
      driverImpedance = 45;
      seriesR = 0;
      rxTermEnabled = true;
      rxTermR = 45;
      receiverCap = 1.5e-12;
    } else {
      riseTime = 8e-9;
      fallTime = 8e-9;
      driverImpedance = 10;
      seriesR = 27;
      rxTermEnabled = false;
      rxTermR = 45;
      receiverCap = 10e-12;
    }
  }

  Usb2Config copy() => Usb2Config.fromJson(toJson());

  Map<String, Object?> toJson() => {
        'speed': speed.name,
        'tr': riseTime,
        'tf': fallTime,
        'rdrv': driverImpedance,
        'rser': seriesR,
        'rxTermOn': rxTermEnabled,
        'rxTerm': rxTermR,
        'cin': receiverCap,
        'rin': receiverRin,
        'zdt': targetZdiff,
      };

  factory Usb2Config.fromJson(Map<String, Object?> j) {
    final d = Usb2Config();
    return Usb2Config(
      speed: _enum(Usb2Speed.values, j['speed'], d.speed),
      riseTime: _d(j['tr'], d.riseTime),
      fallTime: _d(j['tf'], d.fallTime),
      driverImpedance: _d(j['rdrv'], d.driverImpedance),
      seriesR: _d(j['rser'], d.seriesR),
      rxTermEnabled: _b(j['rxTermOn'], d.rxTermEnabled),
      rxTermR: _d(j['rxTerm'], d.rxTermR),
      receiverCap: _d(j['cin'], d.receiverCap),
      receiverRin: _d(j['rin'], d.receiverRin),
      targetZdiff: _d(j['zdt'], d.targetZdiff),
    );
  }
}

class SimSettings {
  SimSettings({
    this.numBits = 16,
    this.pattern = DataPattern.custom,
    this.customPattern = 'A5C3',
    this.timeStepTarget = 0,
    this.lossy = true,
  });

  /// Number of data bits (SPI: bits per frame; USB: line bits).
  int numBits;
  DataPattern pattern;

  /// Hex (e.g. "A5C3") or binary with 0b prefix (e.g. "0b1100").
  String customPattern;

  /// Requested time step (s); 0 = automatic (rise time / 40).
  double timeStepTarget;

  /// Include frequency-dependent conductor + dielectric loss.
  bool lossy;

  SimSettings copy() => SimSettings.fromJson(toJson());

  Map<String, Object?> toJson() => {
        'bits': numBits,
        'pattern': pattern.name,
        'custom': customPattern,
        'dt': timeStepTarget,
        'lossy': lossy,
      };

  factory SimSettings.fromJson(Map<String, Object?> j) {
    final d = SimSettings();
    return SimSettings(
      numBits: _i(j['bits'], d.numBits),
      pattern: _enum(DataPattern.values, j['pattern'], d.pattern),
      customPattern: j['custom'] is String ? j['custom'] as String : d.customPattern,
      timeStepTarget: _d(j['dt'], d.timeStepTarget),
      lossy: _b(j['lossy'], d.lossy),
    );
  }
}

/// Explicit engineering limits used to classify results (PRD 8.2).
/// Values at or below `good` are Good, up to `warn` are Warning, above are
/// Critical (inverted where noted).
class SiThresholds {
  SiThresholds({
    this.impedanceGoodPct = 10,
    this.impedanceWarnPct = 15,
    this.reflectionGood = 0.1,
    this.reflectionWarn = 0.3,
    this.overshootGoodPct = 10,
    this.overshootWarnPct = 20,
    this.ringbackWarnPctVdd = 10,
    this.skewGoodPctUi = 2,
    this.skewWarnPctUi = 5,
    this.timingWarnPctPeriod = 10,
    this.eyeHeightGoodPct = 60,
    this.eyeHeightWarnPct = 30,
    this.eyeWidthGoodPctUi = 80,
    this.eyeWidthWarnPctUi = 60,
    this.lossGoodDb = 1,
    this.lossWarnDb = 3,
    this.xtalkGoodPct = 3,
    this.xtalkWarnPct = 5,
  });

  /// Crosstalk peak as % of the aggressor swing.
  double xtalkGoodPct;
  double xtalkWarnPct;

  double impedanceGoodPct;
  double impedanceWarnPct;
  double reflectionGood;
  double reflectionWarn;
  double overshootGoodPct;
  double overshootWarnPct;

  /// Ring-back margin below this (% of VDD) is a Warning; negative is Critical.
  double ringbackWarnPctVdd;
  double skewGoodPctUi;
  double skewWarnPctUi;

  /// Setup/hold slack below this (% of SCLK period) is a Warning; < 0 Critical.
  double timingWarnPctPeriod;

  /// Eye height relative to the ideal (lossless, matched) eye. Higher is better.
  double eyeHeightGoodPct;
  double eyeHeightWarnPct;
  double eyeWidthGoodPctUi;
  double eyeWidthWarnPctUi;

  /// Line insertion loss at Nyquist (dB, magnitude).
  double lossGoodDb;
  double lossWarnDb;

  SiThresholds copy() => SiThresholds.fromJson(toJson());

  Map<String, Object?> toJson() => {
        'zGood': impedanceGoodPct,
        'zWarn': impedanceWarnPct,
        'gGood': reflectionGood,
        'gWarn': reflectionWarn,
        'osGood': overshootGoodPct,
        'osWarn': overshootWarnPct,
        'rbWarn': ringbackWarnPctVdd,
        'skGood': skewGoodPctUi,
        'skWarn': skewWarnPctUi,
        'tmWarn': timingWarnPctPeriod,
        'ehGood': eyeHeightGoodPct,
        'ehWarn': eyeHeightWarnPct,
        'ewGood': eyeWidthGoodPctUi,
        'ewWarn': eyeWidthWarnPctUi,
        'ilGood': lossGoodDb,
        'ilWarn': lossWarnDb,
        'xtGood': xtalkGoodPct,
        'xtWarn': xtalkWarnPct,
      };

  factory SiThresholds.fromJson(Map<String, Object?> j) {
    final d = SiThresholds();
    return SiThresholds(
      impedanceGoodPct: _d(j['zGood'], d.impedanceGoodPct),
      impedanceWarnPct: _d(j['zWarn'], d.impedanceWarnPct),
      reflectionGood: _d(j['gGood'], d.reflectionGood),
      reflectionWarn: _d(j['gWarn'], d.reflectionWarn),
      overshootGoodPct: _d(j['osGood'], d.overshootGoodPct),
      overshootWarnPct: _d(j['osWarn'], d.overshootWarnPct),
      ringbackWarnPctVdd: _d(j['rbWarn'], d.ringbackWarnPctVdd),
      skewGoodPctUi: _d(j['skGood'], d.skewGoodPctUi),
      skewWarnPctUi: _d(j['skWarn'], d.skewWarnPctUi),
      timingWarnPctPeriod: _d(j['tmWarn'], d.timingWarnPctPeriod),
      eyeHeightGoodPct: _d(j['ehGood'], d.eyeHeightGoodPct),
      eyeHeightWarnPct: _d(j['ehWarn'], d.eyeHeightWarnPct),
      eyeWidthGoodPctUi: _d(j['ewGood'], d.eyeWidthGoodPctUi),
      eyeWidthWarnPctUi: _d(j['ewWarn'], d.eyeWidthWarnPctUi),
      lossGoodDb: _d(j['ilGood'], d.lossGoodDb),
      lossWarnDb: _d(j['ilWarn'], d.lossWarnDb),
      xtalkGoodPct: _d(j['xtGood'], d.xtalkGoodPct),
      xtalkWarnPct: _d(j['xtWarn'], d.xtalkWarnPct),
    );
  }
}

// ---------------------------------------------------------------------------
// High-speed SerDes (USB 3.0, PCIe)
// ---------------------------------------------------------------------------

enum PcieGen { gen1, gen2, gen3, gen4, gen5 }

extension PcieGenInfo on PcieGen {
  String get label => 'Gen ${index + 1}';
  double get rate => const [2.5e9, 5e9, 8e9, 16e9, 32e9][index];
  String get encoding => index < 2 ? '8b/10b' : '128b/130b';

  /// Gen3+ use TX presets and receiver CTLE + DFE.
  bool get usesPresets => index >= 2;

  /// Reference receiver lane-to-lane skew tolerance (s), PCIe base spec
  /// L_RX-SKEW (verify against the spec revision you design to).
  double get laneSkewLimit => const [20e-9, 8e-9, 6e-9, 5e-9, 5e-9][index];
}

enum HdmiMode { tmds165, tmds340, tmds600, frl12 }

extension HdmiModeInfo on HdmiMode {
  String get label => const [
        'TMDS 1.65 Gb/s (HDMI 1.0–1.2)',
        'TMDS 3.4 Gb/s (HDMI 1.4)',
        'TMDS 6 Gb/s (HDMI 2.0)',
        'FRL 12 Gb/s (HDMI 2.1)',
      ][index];
  double get rate => const [1.65e9, 3.4e9, 6e9, 12e9][index];
  String get encoding => this == HdmiMode.frl12 ? '16b/18b' : '8b/10b TMDS';

  /// Data lanes: 3 TMDS data pairs (+ TMDS clock) or 4 FRL lanes.
  int get lanes => this == HdmiMode.frl12 ? 4 : 3;

  /// Typical sink inter-pair skew tolerance (s): 0.2 Tcharacter + 1.78 ns for
  /// TMDS (HDMI 1.4), and a 5 ns deskew budget for FRL - reference values.
  double get laneSkewLimit => this == HdmiMode.frl12 ? 5e-9 : 0.2 * 10 / rate + 1.78e-9;
}

/// PCIe Gen3+ transmitter presets: (preshoot dB, de-emphasis dB).
const List<(double, double)> pciePresets = [
  (0.0, -6.0), // P0
  (0.0, -3.5), // P1
  (0.0, -4.4), // P2
  (0.0, -2.5), // P3
  (0.0, 0.0), // P4
  (1.9, 0.0), // P5
  (2.5, 0.0), // P6
  (3.5, -6.0), // P7
  (3.5, -3.5), // P8
  (3.5, 0.0), // P9
  (0.0, -9.5), // P10
];

/// Configuration shared by the USB 3.0 and PCIe SerDes models.
class SerdesConfig {
  SerdesConfig({
    this.gen = PcieGen.gen3,
    this.lanes = 1,
    this.laneMismatch = 0,
    this.riseTime = 35e-12,
    this.txSwingPp = 1.0,
    this.txImpedance = 50,
    this.rxTermination = 50,
    this.receiverCap = 0.3e-12,
    this.deEmphasisDb = -3.5,
    this.preset = 7,
    this.ctleEnabled = true,
    this.ctleAuto = true,
    this.ctleDcGainDb = -6,
    this.dfeTaps = 1,
    this.rjRms = 0,
    this.maskHeight = 25e-3,
    this.maskWidthUi = 0.3,
    this.targetZdiff = 85,
    this.useTouchstone = false,
    this.sparams,
    this.hdmiMode = HdmiMode.tmds340,
  });

  /// HDMI link rate (ignored for USB 3.0 / PCIe).
  HdmiMode hdmiMode;

  /// Use an imported Touchstone channel instead of the PCB trace model.
  bool useTouchstone;
  ChannelSParams? sparams;

  /// PCIe generation (ignored for USB 3.0).
  PcieGen gen;
  int lanes;

  /// Longest-minus-shortest lane length (m) for lane-to-lane skew.
  double laneMismatch;
  double riseTime; // 10-90 %

  /// Launched differential peak-to-peak swing into a matched load (V).
  double txSwingPp;

  /// Transmitter output impedance per leg (ohm).
  double txImpedance;

  /// Receiver termination per leg to AC ground (ohm).
  double rxTermination;
  double receiverCap; // per leg

  /// De-emphasis (dB, <= 0) for USB 3.0 / PCIe Gen1-2.
  double deEmphasisDb;

  /// TX preset P0..P10 for PCIe Gen3+.
  int preset;
  bool ctleEnabled;

  /// Choose the CTLE DC gain that maximises the eye.
  bool ctleAuto;
  double ctleDcGainDb;
  int dfeTaps;

  /// User-supplied random jitter (s rms); 0 = not included.
  double rjRms;

  /// Reference receiver eye minimums used for classification.
  double maskHeight;
  double maskWidthUi;
  double targetZdiff;

  SerdesConfig copy() => SerdesConfig.fromJson(toJson());

  /// Typical defaults for USB 3.0 Gen 1 (5 Gb/s).
  factory SerdesConfig.usb3() => SerdesConfig(
        riseTime: 50e-12,
        txSwingPp: 1.0,
        deEmphasisDb: -3.5,
        ctleEnabled: true,
        dfeTaps: 0,
        maskHeight: 100e-3,
        maskWidthUi: 0.34,
        targetZdiff: 90,
      );

  /// Typical HDMI defaults for the given link rate.
  factory SerdesConfig.hdmi([HdmiMode mode = HdmiMode.tmds340]) => SerdesConfig(hdmiMode: mode)..applyHdmiDefaults();

  /// Applies rate-specific HDMI defaults. TMDS is DC-coupled and sink-
  /// terminated (50 ohm to 3.3 V); eye minimums are approximate references.
  void applyHdmiDefaults() {
    final i = hdmiMode.index;
    lanes = hdmiMode.lanes;
    riseTime = const [150e-12, 75e-12, 42e-12, 25e-12][i];
    txSwingPp = 1.0;
    txImpedance = 50;
    rxTermination = 50;
    receiverCap = 0.5e-12;
    deEmphasisDb = 0;
    ctleEnabled = i >= 2;
    ctleAuto = true;
    dfeTaps = i == 3 ? 2 : 0;
    maskHeight = const [150e-3, 150e-3, 150e-3, 60e-3][i];
    maskWidthUi = const [0.6, 0.6, 0.6, 0.4][i];
    targetZdiff = 100;
  }

  /// Applies generation-specific PCIe defaults.
  void applyGenDefaults() {
    riseTime = const [100e-12, 50e-12, 35e-12, 18e-12, 10e-12][gen.index];
    deEmphasisDb = gen == PcieGen.gen2 ? -6.0 : -3.5;
    preset = 7;
    ctleEnabled = gen.usesPresets;
    ctleAuto = true;
    dfeTaps = const [0, 0, 1, 2, 3][gen.index];
    maskHeight = const [175e-3, 100e-3, 25e-3, 15e-3, 15e-3][gen.index];
    maskWidthUi = const [0.4, 0.4, 0.3, 0.3, 0.3][gen.index];
    targetZdiff = 85;
  }

  Map<String, Object?> toJson() => {
        'gen': gen.name,
        'lanes': lanes,
        'laneMm': laneMismatch,
        'tr': riseTime,
        'swing': txSwingPp,
        'ztx': txImpedance,
        'zrx': rxTermination,
        'cin': receiverCap,
        'deemph': deEmphasisDb,
        'preset': preset,
        'ctle': ctleEnabled,
        'ctleAuto': ctleAuto,
        'ctleDc': ctleDcGainDb,
        'dfe': dfeTaps,
        'rj': rjRms,
        'maskH': maskHeight,
        'maskW': maskWidthUi,
        'zdt': targetZdiff,
        'useSp': useTouchstone,
        if (sparams != null) 'sp': sparams!.toJson(),
        'hdmi': hdmiMode.name,
      };

  factory SerdesConfig.fromJson(Map<String, Object?> j) {
    final d = SerdesConfig();
    return SerdesConfig(
      gen: _enum(PcieGen.values, j['gen'], d.gen),
      lanes: _i(j['lanes'], d.lanes),
      laneMismatch: _d(j['laneMm'], d.laneMismatch),
      riseTime: _d(j['tr'], d.riseTime),
      txSwingPp: _d(j['swing'], d.txSwingPp),
      txImpedance: _d(j['ztx'], d.txImpedance),
      rxTermination: _d(j['zrx'], d.rxTermination),
      receiverCap: _d(j['cin'], d.receiverCap),
      deEmphasisDb: _d(j['deemph'], d.deEmphasisDb),
      preset: _i(j['preset'], d.preset).clamp(0, 10),
      ctleEnabled: _b(j['ctle'], d.ctleEnabled),
      ctleAuto: _b(j['ctleAuto'], d.ctleAuto),
      ctleDcGainDb: _d(j['ctleDc'], d.ctleDcGainDb),
      dfeTaps: _i(j['dfe'], d.dfeTaps),
      rjRms: _d(j['rj'], d.rjRms),
      maskHeight: _d(j['maskH'], d.maskHeight),
      maskWidthUi: _d(j['maskW'], d.maskWidthUi),
      targetZdiff: _d(j['zdt'], d.targetZdiff),
      useTouchstone: _b(j['useSp'], false),
      sparams: ChannelSParams.fromJson(j['sp']),
      hdmiMode: _enum(HdmiMode.values, j['hdmi'], HdmiMode.tmds340),
    );
  }
}

/// Complete, reproducible description of one analysis.
class AnalysisConfig {
  AnalysisConfig({
    required this.protocol,
    required this.pcb,
    required this.spi,
    required this.usb2,
    required this.sim,
    required this.thresholds,
    SerdesConfig? usb3,
    SerdesConfig? pcie,
    SerdesConfig? hdmi,
    SpiConfig? qspi,
    I2cConfig? i2c,
    RgmiiConfig? rgmii,
  })  : usb3 = usb3 ?? SerdesConfig.usb3(),
        pcie = pcie ?? (SerdesConfig()..applyGenDefaults()),
        hdmi = hdmi ?? SerdesConfig.hdmi(),
        qspi = qspi ?? SpiConfig.qspi(),
        i2c = i2c ?? I2cConfig(),
        rgmii = rgmii ?? RgmiiConfig();

  Protocol protocol;
  PcbConfig pcb;
  SpiConfig spi;
  Usb2Config usb2;
  SerdesConfig usb3;
  SerdesConfig pcie;
  SerdesConfig hdmi;
  SpiConfig qspi;
  I2cConfig i2c;
  RgmiiConfig rgmii;

  /// SerDes settings of the selected protocol (USB 3.0, PCIe or HDMI).
  SerdesConfig get serdes => switch (protocol) {
        Protocol.pcie => pcie,
        Protocol.hdmi => hdmi,
        _ => usb3,
      };

  /// SPI-engine settings of the selected protocol (SPI or QSPI/OSPI).
  SpiConfig get spiCfg => protocol == Protocol.qspi ? qspi : spi;

  /// Bit rate of the selected SerDes protocol (b/s).
  double get serdesRate => switch (protocol) {
        Protocol.pcie => pcie.gen.rate,
        Protocol.hdmi => hdmi.hdmiMode.rate,
        _ => 5e9,
      };

  /// Impedance target of the selected protocol (single-ended or differential).
  double get targetImpedance => switch (protocol) {
        Protocol.spi => spi.targetZ0,
        Protocol.qspi => qspi.targetZ0,
        Protocol.i2c => i2c.targetZ0,
        Protocol.rgmii => rgmii.targetZ0,
        Protocol.usb2 => usb2.targetZdiff,
        Protocol.usb3 => usb3.targetZdiff,
        Protocol.pcie => pcie.targetZdiff,
        Protocol.hdmi => hdmi.targetZdiff,
      };
  SimSettings sim;
  SiThresholds thresholds;

  /// One-line summary of the protocol settings (names, subtitles, reports).
  String get protocolDetail => switch (protocol) {
        Protocol.spi => '${eng(spi.clockHz, 'Hz')} · Mode ${spi.mode} · ${spi.voltage} V',
        Protocol.qspi => '${qspi.ioWidth == 8 ? 'Octal' : 'Quad'} ${qspi.dtr ? 'DTR' : 'SDR'} · '
            '${eng(qspi.clockHz, 'Hz')} · ${qspi.voltage} V',
        Protocol.i2c => '${i2c.mode.label.split(' (').first} · ${eng(i2c.clockHz, 'Hz')} · '
            'Rp ${ohm(i2c.pullupR)} · ${i2c.deviceCount} devices',
        Protocol.rgmii => '${rgmii.speed.label.split(' (').first} · ${rgmii.voltage} V · '
            'delay TX ${eng(rgmii.txClockDelay, 's')} / RX ${eng(rgmii.rxClockDelay, 's')}',
        Protocol.usb2 => usb2.speed.label,
        Protocol.usb3 => 'SuperSpeed 5 Gb/s · 90 Ω',
        Protocol.pcie => '${pcie.gen.label} · ${eng(pcie.gen.rate, 'T/s')} · x${pcie.lanes}',
        Protocol.hdmi => '${hdmi.hdmiMode.label} · 100 Ω',
      };

  /// Short detail used in automatic analysis names.
  String get protocolShortDetail => switch (protocol) {
        Protocol.spi => eng(spi.clockHz, 'Hz'),
        Protocol.qspi => '${eng(qspi.clockHz, 'Hz')} ${qspi.dtr ? 'DTR' : 'SDR'}',
        Protocol.i2c => eng(i2c.clockHz, 'Hz'),
        Protocol.rgmii => rgmii.speed.label.split(' (').first,
        Protocol.usb2 => usb2.speed == Usb2Speed.highSpeed ? 'HS' : 'FS',
        Protocol.usb3 => '5 Gb/s',
        Protocol.pcie => '${pcie.gen.label} x${pcie.lanes}',
        Protocol.hdmi => eng(hdmi.hdmiMode.rate, 'b/s'),
      };

  factory AnalysisConfig.defaults({Protocol protocol = Protocol.spi, StackupConfig? stackup}) {
    final cfg = AnalysisConfig(
      protocol: protocol,
      pcb: PcbConfig(
        stackup: stackup?.copy() ?? StackupConfig.preset(4),
        traceWidth: 0.2e-3,
        traceSpacing: 0.2e-3,
        traceLength: 100e-3,
        lengthMismatch: 0,
      ),
      spi: SpiConfig(),
      usb2: Usb2Config(),
      sim: SimSettings(),
      thresholds: SiThresholds(),
    );
    cfg.applyProtocolDefaults();
    return cfg;
  }

  /// Protocol-specific defaults for routing and simulation settings.
  void applyProtocolDefaults() {
    switch (protocol) {
      case Protocol.usb2:
        pcb.traceWidth = 0.3e-3; // ~90 ohm diff on the 4-layer preset
        pcb.traceSpacing = 0.2e-3;
        pcb.traceLength = 50e-3;
        sim.pattern = DataPattern.prbs7;
        sim.numBits = 127;
        thresholds.impedanceGoodPct = 10;
        thresholds.impedanceWarnPct = 15; // USB 2.0: 90 ohm +/-15 %
      case Protocol.spi:
      case Protocol.qspi:
        pcb.traceWidth = 0.35e-3; // ~50 ohm on the 4-layer preset
        pcb.traceLength = protocol == Protocol.qspi ? 40e-3 : 100e-3;
        sim.pattern = DataPattern.custom;
        sim.customPattern = 'A5C3';
        sim.numBits = 16;
        thresholds.impedanceGoodPct = 10;
        thresholds.impedanceWarnPct = 20;
      case Protocol.i2c:
        pcb.traceWidth = 0.2e-3;
        pcb.traceLength = 150e-3;
        sim.pattern = DataPattern.custom;
        sim.customPattern = 'A5';
        sim.numBits = 9;
        sim.lossy = false;
        // Impedance is not critical on a slow open-drain bus.
        thresholds.impedanceGoodPct = 30;
        thresholds.impedanceWarnPct = 50;
      case Protocol.rgmii:
        pcb.traceWidth = 0.35e-3;
        pcb.traceLength = 50e-3;
        sim.pattern = DataPattern.prbs7;
        sim.numBits = 32;
        thresholds.impedanceGoodPct = 10;
        thresholds.impedanceWarnPct = 20;
      case Protocol.usb3:
      case Protocol.pcie:
      case Protocol.hdmi:
        pcb.traceWidth = protocol == Protocol.hdmi ? 0.15e-3 : 0.2e-3;
        pcb.traceSpacing = 0.2e-3;
        pcb.traceLength = switch (protocol) { Protocol.usb3 => 150e-3, Protocol.hdmi => 100e-3, _ => 200e-3 };
        sim.pattern = DataPattern.prbs7;
        sim.numBits = 127;
        thresholds.impedanceGoodPct = 10;
        thresholds.impedanceWarnPct = 15;
        thresholds.skewGoodPctUi = 5;
        thresholds.skewWarnPctUi = 10;
        applySerdesLossLimits();
    }
  }

  /// Trace-only insertion-loss guidelines at Nyquist by data rate. Full
  /// channel budgets (packages, connectors, add-in card) are larger, e.g.
  /// about 22 / 28 / 36 dB for PCIe Gen3 / 4 / 5.
  void applySerdesLossLimits() {
    if (protocol == Protocol.hdmi) {
      // Board-trace guideline (the cable takes most of the HDMI budget).
      thresholds.lossGoodDb = const [2.0, 3.0, 4.0, 6.0][hdmi.hdmiMode.index];
      thresholds.lossWarnDb = const [4.0, 5.0, 7.0, 10.0][hdmi.hdmiMode.index];
      return;
    }
    final idx = protocol == Protocol.pcie ? pcie.gen.index : 1;
    thresholds.lossGoodDb = const [6.0, 6.0, 10.0, 14.0, 18.0][idx];
    thresholds.lossWarnDb = const [10.0, 10.0, 16.0, 20.0, 26.0][idx];
  }

  AnalysisConfig copy() => AnalysisConfig.fromJson(toJson());

  Map<String, Object?> toJson() => {
        'modelVersion': simulationModelVersion,
        'protocol': protocol.name,
        'pcb': pcb.toJson(),
        'spi': spi.toJson(),
        'usb2': usb2.toJson(),
        'usb3': usb3.toJson(),
        'pcie': pcie.toJson(),
        'hdmi': hdmi.toJson(),
        'qspi': qspi.toJson(),
        'i2c': i2c.toJson(),
        'rgmii': rgmii.toJson(),
        'sim': sim.toJson(),
        'thresholds': thresholds.toJson(),
      };

  factory AnalysisConfig.fromJson(Map<String, Object?> j) {
    Map<String, Object?> m(String k) =>
        j[k] is Map ? (j[k] as Map).cast<String, Object?>() : <String, Object?>{};
    return AnalysisConfig(
      protocol: _enum(Protocol.values, j['protocol'], Protocol.spi),
      pcb: PcbConfig.fromJson(m('pcb')),
      spi: SpiConfig.fromJson(m('spi')),
      usb2: Usb2Config.fromJson(m('usb2')),
      usb3: j['usb3'] is Map ? SerdesConfig.fromJson(m('usb3')) : null,
      pcie: j['pcie'] is Map ? SerdesConfig.fromJson(m('pcie')) : null,
      hdmi: j['hdmi'] is Map ? SerdesConfig.fromJson(m('hdmi')) : null,
      qspi: j['qspi'] is Map ? SpiConfig.fromJson(m('qspi')) : null,
      i2c: j['i2c'] is Map ? I2cConfig.fromJson(m('i2c')) : null,
      rgmii: j['rgmii'] is Map ? RgmiiConfig.fromJson(m('rgmii')) : null,
      sim: SimSettings.fromJson(m('sim')),
      thresholds: SiThresholds.fromJson(m('thresholds')),
    );
  }
}
