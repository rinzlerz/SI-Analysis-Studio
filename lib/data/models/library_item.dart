import 'dart:convert';

import '../../simulation/ibis/ibis.dart';
import '../../simulation/model/config.dart';
import '../../simulation/sparams/touchstone.dart';

/// Reusable library entries (PRD Phase 4).
enum LibraryKind { stackup, driver, ibis, sparam }

extension LibraryKindInfo on LibraryKind {
  String get label => switch (this) {
        LibraryKind.stackup => 'PCB stackups',
        LibraryKind.driver => 'Driver / receiver presets',
        LibraryKind.ibis => 'IBIS models',
        LibraryKind.sparam => 'S-parameter channels',
      };
}

class LibraryItem {
  LibraryItem({this.id, required this.kind, required this.name, required this.data, DateTime? created, this.builtIn = false})
      : created = created ?? DateTime.now();

  int? id;
  final LibraryKind kind;
  String name;
  final Map<String, Object?> data;
  final DateTime created;
  final bool builtIn;

  String get subtitle => switch (kind) {
        LibraryKind.stackup => () {
            final s = StackupConfig.fromJson(data);
            return '${s.layerCount} layers · ${(s.totalThickness * 1e3).toStringAsFixed(2)} mm · Dk ${s.dk} · Df ${s.df}';
          }(),
        LibraryKind.driver => 'For ${Protocol.values.firstWhere((p) => p.name == data['protocol'], orElse: () => Protocol.spi).label}',
        LibraryKind.ibis => () {
            final m = IbisModel.fromJson(data);
            return m == null ? '' : '${m.type} · ${m.vcc.first} V · ${m.file}';
          }(),
        LibraryKind.sparam => () {
            final s = ChannelSParams.fromJson(data);
            return s == null ? '' : '${s.ports}-port · ${s.freq.length} pts · up to ${(s.fMax / 1e9).toStringAsFixed(1)} GHz';
          }(),
      };

  Map<String, Object?> toRow() => {
        if (id != null) 'id': id,
        'kind': kind.name,
        'name': name,
        'data': jsonEncode(data),
        'created': created.millisecondsSinceEpoch,
      };

  factory LibraryItem.fromRow(Map<String, Object?> r) => LibraryItem(
        id: r['id'] as int?,
        kind: LibraryKind.values.firstWhere((k) => k.name == r['kind'], orElse: () => LibraryKind.stackup),
        name: '${r['name']}',
        data: (jsonDecode('${r['data']}') as Map).cast<String, Object?>(),
        created: DateTime.fromMillisecondsSinceEpoch((r['created'] as num?)?.toInt() ?? 0),
      );

  Map<String, Object?> toExportJson() => {'app': 'SI Studio library', 'kind': kind.name, 'name': name, 'data': data};

  static LibraryItem? fromExportJson(Map<String, Object?> j) {
    if (j['app'] != 'SI Studio library' || j['data'] is! Map) return null;
    return LibraryItem(
      kind: LibraryKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => LibraryKind.stackup),
      name: '${j['name']}',
      data: (j['data'] as Map).cast<String, Object?>(),
    );
  }
}

// ---------------------------------------------------------------------------
// Driver / receiver presets: only the buffer-related fields are captured.
// ---------------------------------------------------------------------------

Map<String, Object?> driverPresetFrom(AnalysisConfig c) {
  final out = <String, Object?>{'protocol': c.protocol.name};
  switch (c.protocol) {
    case Protocol.spi:
    case Protocol.qspi:
      final p = c.spiCfg.toJson();
      for (final k in ['voltage', 'tr', 'tf', 'rdrv', 'term', 'rser', 'rpar', 'vtt', 'acR', 'acC', 'cin', 'rin', 'vih', 'vil', 'tco', 'tsu', 'th', 'useIbis', 'ibisDrv', 'ibisRx', 'ibisCorner', 'rsd']) {
        if (p.containsKey(k)) out[k] = p[k];
      }
    case Protocol.i2c:
      final p = c.i2c.toJson();
      for (final k in ['vdd', 'rp', 'rpFar', 'cpin', 'iol', 'tfd', 'low', 'rs']) {
        out[k] = p[k];
      }
    case Protocol.rgmii:
      final p = c.rgmii.toJson();
      for (final k in ['vdd', 'tr', 'tf', 'rdrv', 'rser', 'cin', 'txd', 'rxd', 'skew', 'tsu', 'th']) {
        out[k] = p[k];
      }
    case Protocol.usb2:
      final p = c.usb2.toJson();
      for (final k in ['tr', 'tf', 'rdrv', 'rser', 'rxTermOn', 'rxTerm', 'cin', 'rin']) {
        out[k] = p[k];
      }
    case Protocol.ddr:
      final p = c.ddr.toJson();
      for (final k in ['std', 'ronC', 'ronD', 'odtW', 'odtR', 'cio', 'tr', 'jit', 'train', 'cdev', 'ronCa', 'vtt', 'odtCa']) {
        if (p.containsKey(k)) out[k] = p[k];
      }
    case Protocol.usb3:
    case Protocol.pcie:
    case Protocol.hdmi:
      final p = c.serdes.toJson();
      for (final k in ['tr', 'swing', 'ztx', 'zrx', 'cin', 'deemph', 'preset', 'ctle', 'ctleAuto', 'ctleDc', 'dfe', 'rj']) {
        out[k] = p[k];
      }
  }
  return out;
}

/// Applies a driver preset; returns false when it targets another protocol.
bool applyDriverPreset(AnalysisConfig c, Map<String, Object?> d) {
  if (d['protocol'] != c.protocol.name) return false;
  switch (c.protocol) {
    case Protocol.spi:
      c.spi = SpiConfig.fromJson({...c.spi.toJson(), ...d});
    case Protocol.qspi:
      c.qspi = SpiConfig.fromJson({...c.qspi.toJson(), ...d});
    case Protocol.i2c:
      c.i2c = I2cConfig.fromJson({...c.i2c.toJson(), ...d});
    case Protocol.rgmii:
      c.rgmii = RgmiiConfig.fromJson({...c.rgmii.toJson(), ...d});
    case Protocol.hdmi:
      c.hdmi = SerdesConfig.fromJson({...c.hdmi.toJson(), ...d});
    case Protocol.usb2:
      c.usb2 = Usb2Config.fromJson({...c.usb2.toJson(), ...d});
    case Protocol.ddr:
      c.ddr = DdrConfig.fromJson({...c.ddr.toJson(), ...d});
    case Protocol.usb3:
      c.usb3 = SerdesConfig.fromJson({...c.usb3.toJson(), ...d});
    case Protocol.pcie:
      c.pcie = SerdesConfig.fromJson({...c.pcie.toJson(), ...d});
  }
  return true;
}

/// Built-in library entries (generic, editable copies can be saved).
List<LibraryItem> builtInLibrary() => [
      for (final n in [2, 4, 6, 8])
        LibraryItem(
          kind: LibraryKind.stackup,
          name: 'Typical FR-4 $n-layer 1.6 mm',
          data: StackupConfig.preset(n).toJson(),
          builtIn: true,
        ),
      LibraryItem(
        kind: LibraryKind.driver,
        name: 'Generic 3.3 V CMOS (25 Ω, 1 ns)',
        builtIn: true,
        data: {'protocol': 'spi', 'voltage': 3.3, 'tr': 1e-9, 'tf': 1e-9, 'rdrv': 25.0, 'cin': 5e-12, 'rin': 1e6, 'vih': 0.7, 'vil': 0.3, 'useIbis': false},
      ),
      LibraryItem(
        kind: LibraryKind.driver,
        name: 'Generic fast 1.8 V CMOS (40 Ω, 0.5 ns)',
        builtIn: true,
        data: {'protocol': 'spi', 'voltage': 1.8, 'tr': 0.5e-9, 'tf': 0.5e-9, 'rdrv': 40.0, 'cin': 3e-12, 'rin': 1e6, 'vih': 0.65, 'vil': 0.35, 'useIbis': false},
      ),
      LibraryItem(
        kind: LibraryKind.driver,
        name: 'Generic slow MCU GPIO 3.3 V (50 Ω, 3 ns)',
        builtIn: true,
        data: {'protocol': 'spi', 'voltage': 3.3, 'tr': 3e-9, 'tf': 3e-9, 'rdrv': 50.0, 'cin': 8e-12, 'rin': 1e6, 'vih': 0.7, 'vil': 0.3, 'useIbis': false},
      ),
    ];
