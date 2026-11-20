/// DDR3 / DDR3L / DDR4 / LPDDR4 / LPDDR4X configuration and reference values.
///
/// The mask and timing numbers are approximate JEDEC-style reference values
/// for a quick check; every one can be overridden in the configuration.
library;

import 'dart:math' as math;

enum DdrStandard { ddr3, ddr3l, ddr4, lpddr4, lpddr4x }

/// How the DQ receiver is terminated.
enum DqTermination {
  /// SSTL: ODT centre-tapped to VDDQ/2 (DDR3).
  ctt,

  /// POD: ODT to VDDQ (DDR4).
  pod,

  /// LVSTL: ODT to VSSQ (LPDDR4/4X).
  lvstl,
}

/// Command/address topology.
enum CaTopology {
  /// Fly-by through every device, VTT termination after the last one.
  flyBy,

  /// Point to point (LPDDR4: one channel to one die), on-die CA termination.
  pointToPoint,
}

enum DdrTraining {
  /// The controller centres DQS on each byte: skew between DQ bits remains.
  perByte,

  /// Per-bit deskew: each DQ is centred individually.
  perBit,
}

extension DdrStandardInfo on DdrStandard {
  String get label => const ['DDR3', 'DDR3L', 'DDR4', 'LPDDR4', 'LPDDR4X'][index];
  bool get lp => this == DdrStandard.lpddr4 || this == DdrStandard.lpddr4x;
  bool get ddr3 => this == DdrStandard.ddr3 || this == DdrStandard.ddr3l;
  double get vddq => const [1.5, 1.35, 1.2, 1.1, 0.6][index];
  DqTermination get dqTerm => ddr3 ? DqTermination.ctt : (lp ? DqTermination.lvstl : DqTermination.pod);
  CaTopology get caTopology => lp ? CaTopology.pointToPoint : CaTopology.flyBy;

  /// Data rates (MT/s).
  List<int> get rates => switch (this) {
        DdrStandard.ddr3 || DdrStandard.ddr3l => const [800, 1066, 1333, 1600, 1866, 2133],
        DdrStandard.ddr4 => const [1600, 1866, 2133, 2400, 2666, 2933, 3200],
        _ => const [1600, 2133, 2400, 3200, 3733, 4266],
      };
  int get defaultRate => switch (this) {
        DdrStandard.ddr3 || DdrStandard.ddr3l => 1600,
        DdrStandard.ddr4 => 2400,
        _ => 3200,
      };

  /// Driver strengths (Ω) offered by the DRAM and typical controllers.
  List<double> get dramRonOptions => ddr3 ? const [34, 40] : (lp ? const [40, 48, 60, 80] : const [34, 48]);
  List<double> get ctrlRonOptions => lp ? const [40, 48, 60] : const [34, 40, 48];

  /// DRAM ODT for writes (RTT_WR / RTT_NOM / LPDDR4 DQ ODT), Ω.
  List<double> get dramOdtOptions =>
      ddr3 ? const [20, 30, 40, 60, 120] : (lp ? const [40, 48, 60, 80, 120, 240] : const [34, 40, 48, 60, 80, 120, 240]);

  /// Controller ODT for reads, Ω.
  List<double> get ctrlOdtOptions => ddr3 ? const [40, 60, 120] : (lp ? const [40, 48, 60, 80, 120] : const [34, 40, 48, 60, 80, 120]);
}

/// Reference receiver window for one signal class.
class DdrMask {
  const DdrMask(this.height, this.width, {this.setup, this.hold, required this.source});

  /// Total mask height centred on VREF (V).
  final double height;

  /// Total mask width (s).
  final double width;

  /// Setup / hold split of [width] when the spec gives one (s).
  final double? setup;
  final double? hold;
  final String source;
}

/// Approximate JEDEC-style reference values for [s] at [rate] MT/s.
({DdrMask dq, DdrMask ca}) ddrReferenceMasks(DdrStandard s, int rate) {
  final ui = 1 / (rate * 1e6);
  int idx(List<int> rs) {
    var i = 0;
    for (var k = 0; k < rs.length; k++) {
      if (rate >= rs[k]) i = k;
    }
    return i;
  }

  switch (s) {
    case DdrStandard.ddr3:
    case DdrStandard.ddr3l:
      const rs = [800, 1066, 1333, 1600, 1866, 2133];
      final i = idx(rs);
      final vac = const [0.175, 0.175, 0.150, 0.150, 0.135, 0.135][i];
      final dqW = const [225e-12, 150e-12, 115e-12, 95e-12, 85e-12, 75e-12][i];
      final tis = const [200e-12, 125e-12, 65e-12, 45e-12, 65e-12, 60e-12][i];
      final tih = const [275e-12, 200e-12, 140e-12, 120e-12, 100e-12, 95e-12][i];
      final caV = rate >= 1866 ? 0.150 : 0.175;
      return (
        dq: DdrMask(2 * vac, dqW, source: 'approx. DDR3 VIH/VIL(AC${(vac * 1e3).round()}), tDS + tDH'),
        ca: DdrMask(2 * caV, tis + tih, setup: tis, hold: tih, source: 'approx. DDR3 AC${(caV * 1e3).round()}, tIS / tIH (base)'),
      );
    case DdrStandard.ddr4:
      const rs = [1600, 1866, 2133, 2400, 2666, 2933, 3200];
      final i = idx(rs);
      final vdivw = const [0.136, 0.136, 0.136, 0.136, 0.130, 0.125, 0.110][i];
      final tdivw = (rate > 2400 ? 0.22 : 0.20) * ui;
      final tis = const [115e-12, 100e-12, 80e-12, 62e-12, 55e-12, 48e-12, 40e-12][i];
      final tih = const [140e-12, 125e-12, 105e-12, 87e-12, 80e-12, 73e-12, 65e-12][i];
      final caV = rate > 2400 ? 0.090 : 0.100;
      return (
        dq: DdrMask(vdivw, tdivw, source: 'approx. DDR4 Rx mask VdIVW / TdIVW'),
        ca: DdrMask(2 * caV, tis + tih, setup: tis, hold: tih, source: 'approx. DDR4 VIH/VIL.CA(AC${(caV * 1e3).round()}), tIS / tIH'),
      );
    case DdrStandard.lpddr4:
    case DdrStandard.lpddr4x:
      final x = s == DdrStandard.lpddr4x;
      final vd = (rate > 3200 ? 0.120 : 0.140) * (x ? 0.75 : 1);
      final caUi = 2 * ui;
      return (
        dq: DdrMask(vd, 0.22 * ui, source: 'approx. LPDDR4 Rx mask vdIVW / TdIVW'),
        ca: DdrMask((x ? 0.155 : 0.175), 0.30 * caUi, source: 'approx. LPDDR4 CA Rx mask vcIVW / TcIVW'),
      );
  }
}

class DdrConfig {
  DdrConfig({
    this.standard = DdrStandard.ddr4,
    this.rate = 2400,
    this.ctrlRon = 34,
    this.dramRon = 34,
    this.odtWrite = 48,
    this.odtRead = 48,
    this.ioCap = 1.0e-12,
    this.riseTime = 0,
    this.jitter = 0,
    this.jitterRead = 0,
    this.training = DdrTraining.perByte,
    this.devices = 4,
    this.leadIn = 50e-3,
    this.spacing = 12e-3,
    this.stub = 1.5e-3,
    this.deviceCap = 1.2e-12,
    this.caRon = 34,
    this.vttR = 39,
    this.caOdt = 60,
    this.twoT = false,
    this.caClkMismatch = 0,
    this.targetZ0 = 40,
    this.targetZdiff = 80,
    this.dqMaskV,
    this.dqMaskT,
    this.caMaskV,
    this.caSetup,
    this.caHold,
    this.perSignalLengths = false,
    Map<String, double>? signalLengths,
  }) : signalLengths = signalLengths ?? {};

  DdrStandard standard;

  /// Data rate (MT/s).
  int rate;

  /// Controller and DRAM output impedance (Ω).
  double ctrlRon;
  double dramRon;

  /// DRAM ODT during writes and controller ODT during reads (Ω).
  double odtWrite;
  double odtRead;

  /// DQ / DQS pin capacitance at each end (F).
  double ioCap;

  /// Driver 20–80 % edge time (s); 0 = automatic (≈ 0.3 UI).
  double riseTime;

  /// Controller transmitter jitter for writes (DCD + RJ + crosstalk
  /// allowance), subtracted from the eye width, pk-pk (s); 0 = automatic
  /// (0.2 UI).
  double jitter;

  /// DRAM output uncertainty for reads (≈ 1 − tQH), pk-pk (s); 0 = automatic
  /// (0.25 UI).
  double jitterRead;
  DdrTraining training;

  // ---- Command / address --------------------------------------------------
  /// DRAM devices on the CA bus (fly-by) or dies per channel (LPDDR4).
  int devices;

  /// Controller to first device (m).
  double leadIn;

  /// Between devices along the fly-by (m).
  double spacing;

  /// Via + breakout from the main line to each device ball (m).
  double stub;

  /// CA input capacitance per device, package included (F).
  double deviceCap;
  double caRon;

  /// Fly-by termination to VTT after the last device (Ω).
  double vttR;

  /// LPDDR4 on-die CA termination (Ω, to VSSQ).
  double caOdt;

  /// DDR3/DDR4 2T command timing (CA held for two clocks).
  bool twoT;

  /// CA trace length minus CLK trace length (m).
  double caClkMismatch;

  double targetZ0;
  double targetZdiff;

  /// Overrides of the reference masks (null = reference value).
  double? dqMaskV;
  double? dqMaskT;
  double? caMaskV;
  double? caSetup;
  double? caHold;

  /// Byte-lane lengths (DQ0–7, DM, DQS) – see bus_lengths.dart.
  bool perSignalLengths;
  Map<String, double> signalLengths;

  double get vddq => standard.vddq;
  double get ui => 1 / (rate * 1e6);
  double get tck => 2 * ui;

  /// CA bit time: SDR at the clock rate (×2 in 2T mode).
  double get caUi => tck * (twoT && !standard.lp ? 2 : 1);
  double get edge => riseTime > 0 ? riseTime : (0.3 * ui).clamp(60e-12, 400e-12);
  double get jitterWrite => jitter > 0 ? jitter : 0.20 * ui;
  double get jitterReadPp => jitterRead > 0 ? jitterRead : 0.25 * ui;

  ({DdrMask dq, DdrMask ca}) get referenceMasks => ddrReferenceMasks(standard, rate);

  DdrMask get dqMask {
    final r = referenceMasks.dq;
    if (dqMaskV == null && dqMaskT == null) return r;
    return DdrMask(dqMaskV ?? r.height, dqMaskT ?? r.width, source: 'user-defined');
  }

  DdrMask get caMask {
    final r = referenceMasks.ca;
    if (caMaskV == null && caSetup == null && caHold == null) return r;
    final su = caSetup ?? r.setup ?? r.width / 2;
    final ho = caHold ?? r.hold ?? r.width / 2;
    return DdrMask(caMaskV ?? r.height, su + ho, setup: su, hold: ho, source: 'user-defined');
  }

  /// Applies typical values for [standard] (rate, drive, ODT, CA topology).
  void applyStandardDefaults() {
    final s = standard;
    rate = s.defaultRate;
    switch (s) {
      case DdrStandard.ddr3:
      case DdrStandard.ddr3l:
        ctrlRon = 40;
        dramRon = 34;
        odtWrite = 60;
        odtRead = 60;
        ioCap = 1.4e-12;
        devices = 4;
        deviceCap = 1.5e-12;
        caRon = 40;
        vttR = 39;
        targetZ0 = 40;
        targetZdiff = 80;
      case DdrStandard.ddr4:
        ctrlRon = 34;
        dramRon = 34;
        odtWrite = 48;
        odtRead = 48;
        ioCap = 1.0e-12;
        devices = 4;
        deviceCap = 1.2e-12;
        caRon = 34;
        vttR = 39;
        targetZ0 = 40;
        targetZdiff = 80;
      case DdrStandard.lpddr4:
      case DdrStandard.lpddr4x:
        ctrlRon = 40;
        dramRon = 40;
        odtWrite = 60;
        odtRead = 60;
        ioCap = 0.8e-12;
        devices = 1;
        deviceCap = 0.9e-12;
        caRon = 40;
        caOdt = 80;
        twoT = false;
        targetZ0 = 40;
        targetZdiff = 80;
    }
    leadIn = s.lp ? 30e-3 : 50e-3;
    dqMaskV = dqMaskT = caMaskV = caSetup = caHold = null;
  }

  DdrConfig copy() => DdrConfig.fromJson(toJson());

  Map<String, Object?> toJson() => {
        'std': standard.name,
        'rate': rate,
        'ronC': ctrlRon,
        'ronD': dramRon,
        'odtW': odtWrite,
        'odtR': odtRead,
        'cio': ioCap,
        'tr': riseTime,
        'jit': jitter,
        'jitR': jitterRead,
        'train': training.name,
        'dev': devices,
        'lead': leadIn,
        'pitch': spacing,
        'stub': stub,
        'cdev': deviceCap,
        'ronCa': caRon,
        'vtt': vttR,
        'odtCa': caOdt,
        '2t': twoT,
        'cacm': caClkMismatch,
        'z0t': targetZ0,
        'zdt': targetZdiff,
        if (dqMaskV != null) 'mDqV': dqMaskV,
        if (dqMaskT != null) 'mDqT': dqMaskT,
        if (caMaskV != null) 'mCaV': caMaskV,
        if (caSetup != null) 'mCaS': caSetup,
        if (caHold != null) 'mCaH': caHold,
        if (perSignalLengths) 'perSig': true,
        if (signalLengths.isNotEmpty) 'lens': {...signalLengths},
      };

  factory DdrConfig.fromJson(Map<String, Object?> j) {
    double d(String k, double f) => j[k] is num && (j[k] as num).isFinite ? (j[k] as num).toDouble() : f;
    double? o(String k) => j[k] is num && (j[k] as num).isFinite ? (j[k] as num).toDouble() : null;
    T e<T extends Enum>(List<T> v, String k, T f) => v.firstWhere((x) => x.name == j[k], orElse: () => f);
    final def = DdrConfig();
    final std = e(DdrStandard.values, 'std', def.standard);
    return DdrConfig(
      standard: std,
      rate: j['rate'] is num ? (j['rate'] as num).toInt() : std.defaultRate,
      ctrlRon: d('ronC', def.ctrlRon),
      dramRon: d('ronD', def.dramRon),
      odtWrite: d('odtW', def.odtWrite),
      odtRead: d('odtR', def.odtRead),
      ioCap: d('cio', def.ioCap),
      riseTime: d('tr', 0),
      jitter: d('jit', 0),
      jitterRead: d('jitR', 0),
      training: e(DdrTraining.values, 'train', DdrTraining.perByte),
      devices: j['dev'] is num ? math.max(1, (j['dev'] as num).toInt()) : def.devices,
      leadIn: d('lead', def.leadIn),
      spacing: d('pitch', def.spacing),
      stub: d('stub', def.stub),
      deviceCap: d('cdev', def.deviceCap),
      caRon: d('ronCa', def.caRon),
      vttR: d('vtt', def.vttR),
      caOdt: d('odtCa', def.caOdt),
      twoT: j['2t'] == true,
      caClkMismatch: d('cacm', 0),
      targetZ0: d('z0t', def.targetZ0),
      targetZdiff: d('zdt', def.targetZdiff),
      dqMaskV: o('mDqV'),
      dqMaskT: o('mDqT'),
      caMaskV: o('mCaV'),
      caSetup: o('mCaS'),
      caHold: o('mCaH'),
      perSignalLengths: j['perSig'] == true,
      signalLengths: {
        if (j['lens'] is Map)
          for (final en in (j['lens'] as Map).entries)
            if (en.key is String && en.value is num) en.key as String: (en.value as num).toDouble(),
      },
    );
  }
}
