/// IBIS (I/O Buffer Information Specification) import and behavioural
/// buffer models (PRD Phase 3, Level 3).
///
/// Supported subset (IBIS 3.2+ files):
///   [Model] with Model_type, C_comp, Vinl / Vinh, [Voltage Range],
///   [Pullup], [Pulldown], [GND Clamp], [POWER Clamp], [Ramp].
/// Not used: V-T waveform tables ([Rising/Falling Waveform]), package
/// RLC, [Pin] mapping, AMI.
///
/// Driver behaviour (current into the pin, IBIS sign convention):
///   I(v, t) = Ku(t) Ipu(Vcc - v) + Kd(t) Ipd(v) + Igc(v) + Ipc(Vcc - v)
/// Ku / Kd switch linearly between 0 and 1 over the 0-100 % ramp time
/// t_ramp = (dt from [Ramp] dV/dt, 20-80 %) / 0.6, centred on the edge.
library;

import 'dart:math' as math;

import '../waveform_engine/circuit_solver.dart';

class IbisError implements Exception {
  IbisError(this.message);
  final String message;
  @override
  String toString() => message;
}

enum IbisCorner { typ, min, max }

extension IbisCornerInfo on IbisCorner {
  String get label => switch (this) {
        IbisCorner.typ => 'Typical',
        IbisCorner.min => 'Min (slow / weak)',
        IbisCorner.max => 'Max (fast / strong)',
      };
}

/// A V-I table with typ / min / max columns (missing columns copy typ).
class IvTable {
  IvTable(this.v, this.typ, this.min, this.max);
  final List<double> v;
  final List<double> typ, min, max;

  bool get isEmpty => v.isEmpty;

  List<double> col(IbisCorner c) => switch (c) {
        IbisCorner.typ => typ,
        IbisCorner.min => min,
        IbisCorner.max => max,
      };

  /// Piecewise-linear current and slope, linear extrapolation outside.
  (double, double) eval(double x, IbisCorner c) {
    final i = col(c);
    final n = v.length;
    if (n == 0) return (0, 0);
    if (n == 1) return (i[0], 0);
    var k = 1;
    if (x <= v[0]) {
      k = 1;
    } else if (x >= v[n - 1]) {
      k = n - 1;
    } else {
      var lo = 0, hi = n - 1;
      while (hi - lo > 1) {
        final mid = (lo + hi) >> 1;
        if (v[mid] <= x) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      k = hi;
    }
    final s = (i[k] - i[k - 1]) / (v[k] - v[k - 1]);
    return (i[k - 1] + s * (x - v[k - 1]), s);
  }

  Map<String, Object?> toJson() => {'v': v, 't': typ, 'n': min, 'x': max};

  static IvTable fromJson(Object? o) {
    if (o is! Map) return IvTable([], [], [], []);
    List<double> l(String k) => (o[k] as List? ?? const []).map((e) => (e as num).toDouble()).toList();
    return IvTable(l('v'), l('t'), l('n'), l('x'));
  }
}

class IbisRamp {
  const IbisRamp(this.dvR, this.dtR, this.dvF, this.dtF, this.rLoad);
  final List<double> dvR, dtR, dvF, dtF; // typ, min, max
  final double rLoad;

  Map<String, Object?> toJson() => {'dvR': dvR, 'dtR': dtR, 'dvF': dvF, 'dtF': dtF, 'rl': rLoad};
  static IbisRamp? fromJson(Object? o) {
    if (o is! Map) return null;
    List<double> l(String k) => (o[k] as List? ?? const []).map((e) => (e as num).toDouble()).toList();
    return IbisRamp(l('dvR'), l('dtR'), l('dvF'), l('dtF'), (o['rl'] as num?)?.toDouble() ?? 50);
  }
}

class IbisModel {
  IbisModel({
    required this.file,
    required this.name,
    required this.type,
    required this.vcc,
    required this.cComp,
    required this.pullup,
    required this.pulldown,
    required this.gndClamp,
    required this.powerClamp,
    required this.ramp,
    this.vinl,
    this.vinh,
  });

  final String file;
  final String name;
  final String type;

  /// [Voltage Range] typ / min / max.
  final List<double> vcc;

  /// C_comp typ / min / max (F).
  final List<double> cComp;
  final IvTable pullup, pulldown, gndClamp, powerClamp;
  final IbisRamp? ramp;
  final double? vinl, vinh;

  bool get canDrive => !pullup.isEmpty && !pulldown.isEmpty && ramp != null;
  bool get isInput => type.toLowerCase().contains('input') || type.toLowerCase().startsWith('i/o');

  int _ci(IbisCorner c) => c.index;
  double vccOf(IbisCorner c) => vcc[_ci(c)];
  double cCompOf(IbisCorner c) => cComp[_ci(c)];

  /// 0-100 % switching time for rising / falling edges.
  double rampTime(IbisCorner c, {required bool rising}) {
    final r = ramp!;
    final dt = (rising ? r.dtR : r.dtF)[_ci(c)];
    return dt / 0.6;
  }

  /// Small-signal output resistance of the pulldown near 10 % of Vcc (ohm).
  double pulldownResistance(IbisCorner c) {
    final x = 0.1 * vccOf(c);
    final s = pulldown.eval(x, c).$2;
    return s > 0 ? 1 / s : double.infinity;
  }

  double pullupResistance(IbisCorner c) {
    final x = 0.1 * vccOf(c);
    final s = pullup.eval(x, c).$2; // dI/dVtable; I into pin = -V/R
    return s < 0 ? -1 / s : (s > 0 ? 1 / s : double.infinity);
  }

  Map<String, Object?> toJson() => {
        'file': file,
        'name': name,
        'type': type,
        'vcc': vcc,
        'ccomp': cComp,
        'pu': pullup.toJson(),
        'pd': pulldown.toJson(),
        'gc': gndClamp.toJson(),
        'pc': powerClamp.toJson(),
        'ramp': ramp?.toJson(),
        'vinl': vinl,
        'vinh': vinh,
      };

  static IbisModel? fromJson(Object? o) {
    if (o is! Map) return null;
    final j = o.cast<String, Object?>();
    List<double> l(String k) => (j[k] as List? ?? const []).map((e) => (e as num).toDouble()).toList();
    final vcc = l('vcc');
    if (vcc.length != 3) return null;
    return IbisModel(
      file: '${j['file'] ?? ''}',
      name: '${j['name'] ?? ''}',
      type: '${j['type'] ?? ''}',
      vcc: vcc,
      cComp: l('ccomp').length == 3 ? l('ccomp') : [0, 0, 0],
      pullup: IvTable.fromJson(j['pu']),
      pulldown: IvTable.fromJson(j['pd']),
      gndClamp: IvTable.fromJson(j['gc']),
      powerClamp: IvTable.fromJson(j['pc']),
      ramp: IbisRamp.fromJson(j['ramp']),
      vinl: (j['vinl'] as num?)?.toDouble(),
      vinh: (j['vinh'] as num?)?.toDouble(),
    );
  }
}

/// Parses an IBIS number with optional scale suffix and unit ("2.5pF",
/// "-10mA", "1.2V", "3.3e-1"). Returns null for "NA".
double? parseIbisNumber(String s) {
  final t = s.trim();
  if (t.isEmpty || t.toUpperCase() == 'NA') return null;
  final m = RegExp(r'^([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)([a-zA-Z]*)').firstMatch(t);
  if (m == null) return null;
  final base = double.parse(m.group(1)!);
  final suf = m.group(2)!;
  if (suf.isEmpty) return base;
  const scale = {'T': 1e12, 'G': 1e9, 'M': 1e6, 'k': 1e3, 'K': 1e3, 'm': 1e-3, 'u': 1e-6, 'n': 1e-9, 'p': 1e-12, 'f': 1e-15};
  final f = scale[suf[0]];
  // A bare unit (e.g. "V", "A", "F", "s") has no scale.
  return f == null ? base : base * f;
}

List<double> _triple(List<String> tok) {
  final v = tok.map(parseIbisNumber).toList();
  final typ = v.isNotEmpty ? v[0] : null;
  if (typ == null) throw IbisError('Missing typical value.');
  return [typ, v.length > 1 && v[1] != null ? v[1]! : typ, v.length > 2 && v[2] != null ? v[2]! : typ];
}

/// Parses all [Model] sections of an IBIS file.
List<IbisModel> parseIbis(String text, {String file = 'model.ibs'}) {
  var comment = '|';
  final models = <IbisModel>[];
  String? name;
  var type = '';
  List<double>? vcc;
  var cComp = [0.0, 0.0, 0.0];
  double? vinl, vinh;
  final tables = <String, List<List<double>>>{};
  String? table;
  final rampVals = <String, List<String>>{};
  var rLoad = 50.0;
  var inRamp = false;

  void finish() {
    if (name == null) return;
    IvTable t(String k) {
      final rows = tables[k] ?? const [];
      final sorted = [...rows]..sort((a, b) => a[0].compareTo(b[0]));
      return IvTable([for (final r in sorted) r[0]], [for (final r in sorted) r[1]], [for (final r in sorted) r[2]],
          [for (final r in sorted) r[3]]);
    }

    IbisRamp? ramp;
    final r = rampVals['dv/dt_r'], f = rampVals['dv/dt_f'];
    if (r != null && f != null) {
      List<double> dv(List<String> v) => _triple([for (final x in v) x.split('/').first]);
      List<double> dtt(List<String> v) =>
          _triple([for (final x in v) x.contains('/') ? x.split('/')[1] : 'NA']);
      ramp = IbisRamp(dv(r), dtt(r), dv(f), dtt(f), rLoad);
    }
    if (vcc != null) {
      models.add(IbisModel(
        file: file,
        name: name!,
        type: type,
        vcc: vcc!,
        cComp: cComp,
        pullup: t('pullup'),
        pulldown: t('pulldown'),
        gndClamp: t('gnd clamp'),
        powerClamp: t('power clamp'),
        ramp: ramp,
        vinl: vinl,
        vinh: vinh,
      ));
    }
    name = null;
    type = '';
    vcc = null;
    cComp = [0.0, 0.0, 0.0];
    vinl = null;
    vinh = null;
    tables.clear();
    rampVals.clear();
    table = null;
    inRamp = false;
    rLoad = 50;
  }

  for (var raw in text.split(RegExp(r'\r?\n'))) {
    final ci = raw.indexOf(comment);
    if (ci >= 0) raw = raw.substring(0, ci);
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('[')) {
      final end = line.indexOf(']');
      if (end < 0) continue;
      final kw = line.substring(1, end).trim().toLowerCase().replaceAll('_', ' ');
      final rest = line.substring(end + 1).trim();
      table = null;
      inRamp = false;
      switch (kw) {
        case 'comment char':
          if (rest.isNotEmpty) comment = rest[0];
        case 'model':
          finish();
          name = rest.split(RegExp(r'\s+')).first;
        case 'voltage range':
          if (name != null) vcc = _triple(rest.split(RegExp(r'\s+')));
        case 'pullup':
        case 'pulldown':
        case 'gnd clamp':
        case 'power clamp':
          if (name != null) {
            table = kw;
            tables[kw] = [];
          }
        case 'ramp':
          inRamp = name != null;
        case 'end':
          finish();
        default:
          if (kw != 'model spec' && kw != 'temperature range' && kw != 'pullup reference' &&
              kw != 'pulldown reference' && kw != 'gnd clamp reference' && kw != 'power clamp reference') {
            // Other keywords end the current model's sub-sections only.
          }
          if (kw == 'component' || kw == 'model selector') finish();
      }
      continue;
    }
    if (name == null) continue;
    final tok = line.split(RegExp(r'[\s=]+')).where((e) => e.isNotEmpty).toList();
    final key = tok.first.toLowerCase();
    if (key == 'model_type' && tok.length > 1) {
      type = tok[1];
      continue;
    }
    if (key == 'c_comp' && tok.length > 1) {
      cComp = _triple(tok.sublist(1));
      continue;
    }
    if (key == 'vinl' && tok.length > 1) {
      vinl = parseIbisNumber(tok[1]);
      continue;
    }
    if (key == 'vinh' && tok.length > 1) {
      vinh = parseIbisNumber(tok[1]);
      continue;
    }
    if (inRamp) {
      if (key == 'dv/dt_r' || key == 'dv/dt_f') rampVals[key] = tok.sublist(1);
      if (key == 'r_load' && tok.length > 1) rLoad = parseIbisNumber(tok[1]) ?? 50;
      continue;
    }
    if (table != null) {
      final vals = tok.map(parseIbisNumber).toList();
      if (vals.isEmpty || vals[0] == null || vals.length < 2 || vals[1] == null) continue;
      final typ = vals[1]!;
      tables[table]!.add([
        vals[0]!,
        typ,
        vals.length > 2 && vals[2] != null ? vals[2]! : typ,
        vals.length > 3 && vals[3] != null ? vals[3]! : typ,
      ]);
    }
  }
  finish();
  if (models.isEmpty) throw IbisError('No [Model] with a [Voltage Range] found in $file.');
  return models;
}

/// One logic transition for an IBIS driver.
class LogicEdge {
  const LogicEdge(this.t50, this.high);
  final double t50;
  final bool high;
}

/// IBIS output buffer as a nonlinear circuit device.
class IbisDriverDevice implements NonlinearDevice {
  IbisDriverDevice({
    required this.node,
    required this.model,
    required this.corner,
    required this.initialHigh,
    required List<LogicEdge> edges,
  })  : edges = [...edges]..sort((a, b) => a.t50.compareTo(b.t50)),
        _vcc = model.vccOf(corner),
        _tr = model.rampTime(corner, rising: true),
        _tf = model.rampTime(corner, rising: false);

  @override
  final int node;
  final IbisModel model;
  final IbisCorner corner;
  final bool initialHigh;
  final List<LogicEdge> edges;
  final double _vcc, _tr, _tf;
  int _cursor = 0;

  /// Pull-up weight Ku at time t (Kd = 1 - Ku).
  double _ku(double t) {
    while (_cursor > 0 && edges[_cursor - 1].t50 + _width(_cursor - 1) / 2 > t) {
      _cursor--;
    }
    while (_cursor < edges.length && edges[_cursor].t50 + _width(_cursor) / 2 <= t) {
      _cursor++;
    }
    final state = _cursor == 0 ? initialHigh : edges[_cursor - 1].high;
    var ku = state ? 1.0 : 0.0;
    if (_cursor < edges.length) {
      final e = edges[_cursor];
      final w = _width(_cursor);
      final start = e.t50 - w / 2;
      if (t > start && e.high != state) {
        final x = ((t - start) / w).clamp(0.0, 1.0);
        ku = e.high ? x : 1 - x;
      }
    }
    return ku;
  }

  double _width(int i) => edges[i].high ? _tr : _tf;

  @override
  bool active(double t) {
    for (var i = math.max(0, _cursor - 1); i < edges.length && i <= _cursor + 1; i++) {
      final w = _width(i);
      if (t >= edges[i].t50 - w / 2 && t <= edges[i].t50 + w / 2) return true;
    }
    return false;
  }

  @override
  (double, double) eval(double v, double t) {
    final ku = _ku(t);
    final kd = 1 - ku;
    final pu = model.pullup.eval(_vcc - v, corner);
    final pd = model.pulldown.eval(v, corner);
    final gc = model.gndClamp.eval(v, corner);
    final pc = model.powerClamp.eval(_vcc - v, corner);
    final i = ku * pu.$1 + kd * pd.$1 + gc.$1 + pc.$1;
    final di = -ku * pu.$2 + kd * pd.$2 + gc.$2 - pc.$2;
    return (i, di);
  }
}

/// IBIS input buffer (clamp diodes only; C_comp is added as a capacitor).
class IbisReceiverDevice implements NonlinearDevice {
  IbisReceiverDevice({required this.node, required this.model, required this.corner}) : _vcc = model.vccOf(corner);

  @override
  final int node;
  final IbisModel model;
  final IbisCorner corner;
  final double _vcc;

  @override
  bool active(double t) => false;

  @override
  (double, double) eval(double v, double t) {
    final gc = model.gndClamp.eval(v, corner);
    final pc = model.powerClamp.eval(_vcc - v, corner);
    return (gc.$1 + pc.$1, gc.$2 - pc.$2);
  }
}
