/// KiCad PCB (.kicad_pcb, KiCad 6-9) import (PRD Phase 4: PCB design-tool
/// integration).
///
/// Extracted:
/// * Board stackup from (setup (stackup ...)): copper thickness, dielectric
///   thickness, epsilon_r and loss_tangent (averaged over dielectrics).
///   Inner copper layers carrying a filled zone on a GND / power net, or of
///   KiCad layer type "power", become reference planes.
/// * Per-net routing: total track length (segments and arcs), dominant
///   width and layer, layers used, via count and via drill / pad size.
/// * Differential pairs detected by name suffixes (_P/_N, +/-, P/N, _DP/_DM).
library;

import 'dart:math' as math;

import '../model/config.dart';

class KicadError implements Exception {
  KicadError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Parses an S-expression into nested lists of strings.
List<Object> parseSexpr(String text) {
  var i = 0;
  final n = text.length;
  List<Object> list() {
    final out = <Object>[];
    while (i < n) {
      final c = text[i];
      if (c == '(') {
        i++;
        out.add(list());
      } else if (c == ')') {
        i++;
        return out;
      } else if (c == '"') {
        final b = StringBuffer();
        i++;
        while (i < n && text[i] != '"') {
          if (text[i] == '\\' && i + 1 < n) {
            i++;
          }
          b.write(text[i]);
          i++;
        }
        i++;
        out.add(b.toString());
      } else if (c.trim().isEmpty) {
        i++;
      } else {
        final s = i;
        while (i < n && !'() \t\r\n"'.contains(text[i])) {
          i++;
        }
        out.add(text.substring(s, i));
      }
    }
    return out;
  }

  final top = list();
  if (top.isEmpty || top.first is! List) throw KicadError('Not an S-expression file.');
  return top.first as List<Object>;
}

String? _head(Object o) => o is List && o.isNotEmpty && o.first is String ? o.first as String : null;

Iterable<List<Object>> _children(List<Object> node, String name) sync* {
  for (final c in node) {
    if (c is List<Object> && _head(c) == name) yield c;
  }
}

List<Object>? _child(List<Object> node, String name) {
  for (final c in _children(node, name)) {
    return c;
  }
  return null;
}

String? _atom(List<Object> node, String name, [int index = 1]) {
  final c = _child(node, name);
  if (c == null || c.length <= index) return null;
  final v = c[index];
  return v is String ? v : null;
}

double? _num(List<Object> node, String name, [int index = 1]) {
  final s = _atom(node, name, index);
  return s == null ? null : double.tryParse(s);
}

class KicadNet {
  KicadNet(this.name);
  final String name;
  double length = 0; // m
  final widths = <double, double>{}; // width -> length (m)
  final layerLength = <String, double>{};
  int vias = 0;
  double viaDrill = 0;
  double viaPad = 0;
  final viaLayers = <String>{};

  double get width {
    var best = 0.0, bl = -1.0;
    widths.forEach((w, l) {
      if (l > bl) {
        bl = l;
        best = w;
      }
    });
    return best;
  }

  String? get mainLayer {
    String? best;
    var bl = -1.0;
    layerLength.forEach((k, l) {
      if (l > bl) {
        bl = l;
        best = k;
      }
    });
    return best;
  }
}

class KicadDiffPair {
  KicadDiffPair(this.base, this.p, this.n);
  final String base;
  final KicadNet p;
  final KicadNet n;
  double get mismatch => (n.length - p.length).abs();
}

class KicadBoard {
  KicadBoard({
    required this.copperNames,
    required this.stackup,
    required this.nets,
    required this.pairs,
    required this.notes,
  });

  /// KiCad copper layer names, top to bottom (aligned with stackup.layers).
  final List<String> copperNames;
  final StackupConfig? stackup;
  final Map<String, KicadNet> nets;
  final List<KicadDiffPair> pairs;
  final List<String> notes;

  /// Routed nets sorted by length (longest first).
  List<KicadNet> get routedNets =>
      nets.values.where((n) => n.length > 0).toList()..sort((a, b) => b.length.compareTo(a.length));

  int layerIndex(String name) => copperNames.indexOf(name);

  /// Distance between the surfaces of two copper layers (m).
  double span(int a, int b) {
    final s = stackup;
    if (s == null || a < 0 || b < 0) return 0;
    final lo = math.min(a, b), hi = math.max(a, b);
    var d = 0.0;
    for (var i = lo; i < hi; i++) {
      d += s.dielectrics[i];
      if (i != lo) d += s.layers[i].copperThickness;
    }
    return d;
  }
}

final _gndRe = RegExp(r'(^|[^A-Z])(GND|VSS|AGND|DGND|PGND|GROUND)', caseSensitive: false);
final _pwrRe = RegExp(r'(^|[^A-Z])(VCC|VDD|\+?\d+V\d*|V[0-9]|PWR|VBUS|VIN)', caseSensitive: false);

/// Parses a .kicad_pcb file.
KicadBoard parseKicadPcb(String text) {
  final root = parseSexpr(text);
  if (_head(root) != 'kicad_pcb') throw KicadError('Not a KiCad PCB file (expected "kicad_pcb").');
  const mm = 1e-3;
  final notes = <String>[];

  // Net table (KiCad <= 8: (net <id> "<name>"); KiCad 9 may name nets inline).
  final netNames = <String, String>{};
  for (final n in _children(root, 'net')) {
    if (n.length >= 3 && n[1] is String && n[2] is String) netNames[n[1] as String] = n[2] as String;
  }
  String? netOf(List<Object> item) {
    final c = _child(item, 'net');
    if (c == null || c.length < 2 || c[1] is! String) return null;
    final id = c[1] as String;
    if (c.length >= 3 && c[2] is String) return c[2] as String;
    return netNames[id] ?? id;
  }

  // Copper layer types from (layers ...).
  final layerType = <String, String>{};
  final layersNode = _child(root, 'layers');
  if (layersNode != null) {
    for (final l in layersNode.skip(1)) {
      if (l is List && l.length >= 3 && l[1] is String && (l[1] as String).endsWith('.Cu')) {
        layerType[l[1] as String] = '${l[2]}';
      }
    }
  }

  // Zones -> plane detection.
  final zoneNets = <String, Set<String>>{};
  for (final z in _children(root, 'zone')) {
    final net = _atom(z, 'net_name') ?? netOf(z) ?? '';
    final layers = <String>[];
    final l1 = _child(z, 'layer');
    if (l1 != null && l1.length > 1) layers.add('${l1[1]}');
    final ls = _child(z, 'layers');
    if (ls != null) layers.addAll(ls.skip(1).map((e) => '$e'));
    for (final l in layers) {
      zoneNets.putIfAbsent(l, () => {}).add(net);
    }
  }

  // Stackup.
  StackupConfig? stackup;
  final copperNames = <String>[];
  final setup = _child(root, 'setup');
  final st = setup == null ? null : _child(setup, 'stackup');
  if (st != null) {
    final layers = <StackupLayer>[];
    final diel = <double>[];
    var pendingDiel = 0.0;
    final ers = <double>[];
    final dfs = <double>[];
    for (final l in _children(st, 'layer')) {
      final name = l.length > 1 ? '${l[1]}' : '';
      final type = _atom(l, 'type') ?? '';
      final t = (_num(l, 'thickness') ?? 0) * mm;
      if (type == 'copper') {
        if (layers.isNotEmpty) {
          diel.add(pendingDiel > 0 ? pendingDiel : 0.1e-3);
        }
        pendingDiel = 0;
        copperNames.add(name);
        final isOuter = name == 'F.Cu' || name == 'B.Cu';
        final zn = zoneNets[name] ?? const <String>{};
        var role = LayerRole.signal;
        if (!isOuter) {
          if (layerType[name] == 'power' || zn.any((n) => _gndRe.hasMatch(n))) {
            role = zn.any((n) => _pwrRe.hasMatch(n)) && !zn.any((n) => _gndRe.hasMatch(n))
                ? LayerRole.power
                : LayerRole.ground;
          } else if (zn.any((n) => _pwrRe.hasMatch(n))) {
            role = LayerRole.power;
          }
        }
        layers.add(StackupLayer(role: role, copperThickness: t > 0 ? t : 35e-6));
      } else if (type == 'core' || type == 'prepreg' || type.contains('dielectric') || name.startsWith('dielectric')) {
        if (layers.isNotEmpty) pendingDiel += t;
        // Sub-layers: (epsilon_r x) may appear multiple times; take the first.
        final er = _num(l, 'epsilon_r');
        final df = _num(l, 'loss_tangent');
        if (er != null) ers.add(er);
        if (df != null) dfs.add(df);
      }
    }
    if (layers.length >= 2 && diel.length == layers.length - 1) {
      double avg(List<double> x, double d) => x.isEmpty ? d : x.reduce((a, b) => a + b) / x.length;
      final sig = layers.indexWhere((l) => l.role == LayerRole.signal);
      // Two-layer boards: treat the bottom layer as the reference.
      if (layers.length == 2) layers[1].role = LayerRole.ground;
      stackup = StackupConfig(
        layers: layers,
        dielectrics: diel,
        dk: double.parse(avg(ers, 4.5).toStringAsFixed(2)),
        df: double.parse(avg(dfs, 0.02).toStringAsFixed(4)),
        signalLayer: sig < 0 ? 0 : sig,
        roughnessRms: 1e-6,
      );
      if (ers.isEmpty) notes.add('Stackup has no epsilon_r; Dk 4.5 assumed.');
      if (layers.length > 2) {
        notes.add('Reference planes inferred from zone nets / layer types; check layer roles in the stackup editor.');
      }
    } else {
      notes.add('Board stackup could not be read; keep the current stackup.');
    }
  } else {
    notes.add('No (stackup) section (enable "Board stackup" in KiCad Board Setup); keep the current stackup.');
  }

  // Tracks and vias.
  final nets = <String, KicadNet>{};
  KicadNet net(String name) => nets.putIfAbsent(name, () => KicadNet(name));
  (double, double)? pt(List<Object> item, String key) {
    final c = _child(item, key);
    if (c == null || c.length < 3) return null;
    final x = double.tryParse('${c[1]}'), y = double.tryParse('${c[2]}');
    return x == null || y == null ? null : (x * mm, y * mm);
  }

  for (final item in root.whereType<List<Object>>()) {
    final h = _head(item);
    if (h != 'segment' && h != 'arc' && h != 'via') continue;
    final name = netOf(item);
    if (name == null || name.isEmpty) continue;
    final nt = net(name);
    if (h == 'via') {
      nt.vias++;
      nt.viaDrill = (_num(item, 'drill') ?? 0.3) * mm;
      nt.viaPad = (_num(item, 'size') ?? 0.6) * mm;
      final ls = _child(item, 'layers');
      if (ls != null) nt.viaLayers.addAll(ls.skip(1).map((e) => '$e'));
      continue;
    }
    final a = pt(item, 'start'), b = pt(item, 'end');
    if (a == null || b == null) continue;
    double len;
    if (h == 'arc') {
      final m = pt(item, 'mid');
      len = m == null ? _dist(a, b) : _arcLength(a, m, b);
    } else {
      len = _dist(a, b);
    }
    final w = (_num(item, 'width') ?? 0) * mm;
    final layer = _atom(item, 'layer') ?? '';
    nt.length += len;
    nt.widths[w] = (nt.widths[w] ?? 0) + len;
    nt.layerLength[layer] = (nt.layerLength[layer] ?? 0) + len;
  }

  // Differential pairs.
  final pairs = <KicadDiffPair>[];
  const suffixes = [
    ('_P', '_N'),
    ('+', '-'),
    ('_DP', '_DM'),
    ('P', 'N'),
    ('_D+', '_D-'),
  ];
  final used = <String>{};
  for (final name in nets.keys) {
    for (final (sp, sn) in suffixes) {
      if (name.endsWith(sp) && !used.contains(name)) {
        final base = name.substring(0, name.length - sp.length);
        final other = '$base$sn';
        if (nets.containsKey(other) && base.isNotEmpty) {
          pairs.add(KicadDiffPair(base, nets[name]!, nets[other]!));
          used
            ..add(name)
            ..add(other);
        }
      }
    }
  }
  return KicadBoard(copperNames: copperNames, stackup: stackup, nets: nets, pairs: pairs, notes: notes);
}

double _dist((double, double) a, (double, double) b) => math.sqrt(math.pow(a.$1 - b.$1, 2) + math.pow(a.$2 - b.$2, 2));

/// Length of the circular arc through start, mid and end.
double _arcLength((double, double) a, (double, double) m, (double, double) b) {
  final ax = a.$1, ay = a.$2, bx = m.$1, by = m.$2, cx = b.$1, cy = b.$2;
  final d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by));
  if (d.abs() < 1e-18) return _dist(a, m) + _dist(m, b);
  final ux = ((ax * ax + ay * ay) * (by - cy) + (bx * bx + by * by) * (cy - ay) + (cx * cx + cy * cy) * (ay - by)) / d;
  final uy = ((ax * ax + ay * ay) * (cx - bx) + (bx * bx + by * by) * (ax - cx) + (cx * cx + cy * cy) * (bx - ax)) / d;
  final r = math.sqrt(math.pow(ax - ux, 2) + math.pow(ay - uy, 2));
  double ang(double x, double y) => math.atan2(y - uy, x - ux);
  final a1 = ang(ax, ay), a2 = ang(bx, by), a3 = ang(cx, cy);
  double norm(double x) {
    var v = x % (2 * math.pi);
    if (v < 0) v += 2 * math.pi;
    return v;
  }

  // Sweep from a1 to a3 passing through a2.
  final ccw = norm(a3 - a1);
  final mid = norm(a2 - a1);
  final sweep = mid <= ccw ? ccw : 2 * math.pi - ccw;
  return r * sweep;
}

/// Applies an imported net (or pair) to [cfg]: stackup, routed layer,
/// width, length, P/N mismatch, spacing (not in the file – kept) and vias.
List<String> applyKicadNet(AnalysisConfig cfg, KicadBoard board, {KicadNet? net, KicadDiffPair? pair, bool useStackup = true}) {
  final out = <String>[];
  if (useStackup && board.stackup != null) {
    cfg.pcb.stackup = board.stackup!.copy();
    out.add('Stackup: ${board.stackup!.layerCount} layers, Dk ${board.stackup!.dk}, Df ${board.stackup!.df}.');
  }
  final main = pair?.p ?? net;
  if (main == null) return out;
  final layerName = main.mainLayer;
  final li = layerName == null ? -1 : board.layerIndex(layerName);
  if (li >= 0 && li < cfg.pcb.stackup.layers.length) {
    cfg.pcb.stackup.layers[li].role = LayerRole.signal;
    cfg.pcb.stackup.signalLayer = li;
    out.add('Routed layer: $layerName.');
  }
  if (main.width > 0) cfg.pcb.traceWidth = main.width;
  if (pair != null) {
    cfg.pcb.traceLength = math.min(pair.p.length, pair.n.length);
    cfg.pcb.lengthMismatch = pair.mismatch;
    out.add('Pair ${pair.base}: P ${(pair.p.length * 1e3).toStringAsFixed(2)} mm, '
        'N ${(pair.n.length * 1e3).toStringAsFixed(2)} mm (spacing not stored in the board file – check it).');
  } else {
    cfg.pcb.traceLength = main.length;
    out.add('Net ${main.name}: ${(main.length * 1e3).toStringAsFixed(2)} mm, width ${(main.width * 1e3).toStringAsFixed(3)} mm.');
  }
  // Vias, evenly spaced (their positions along the route are not resolved).
  cfg.pcb.elements.removeWhere((e) => e.type == ChannelElementType.via);
  if (main.vias > 0 && board.stackup != null) {
    final routed = main.layerLength.keys.map(board.layerIndex).where((i) => i >= 0).toList()..sort();
    final top = routed.isEmpty ? 0 : routed.first;
    final bottom = routed.isEmpty ? board.copperNames.length - 1 : routed.last;
    final through = main.viaLayers.contains('F.Cu') && main.viaLayers.contains('B.Cu') ||
        main.viaLayers.contains('*.Cu');
    final barrel = math.max(0.05e-3, board.span(top, bottom));
    // Through via: the longer unused end of the barrel acts as the stub.
    final stub = through ? math.max(board.span(bottom, board.copperNames.length - 1), board.span(0, top)) : 0.0;
    final count = main.vias;
    for (var k = 0; k < count; k++) {
      cfg.pcb.elements.add(ChannelElement(
        type: ChannelElementType.via,
        position: cfg.pcb.traceLength * (k + 1) / (count + 1),
        drill: main.viaDrill,
        pad: main.viaPad,
        antipad: main.viaPad + 0.3e-3,
        barrelLength: barrel,
        stubLength: stub,
      ));
    }
    out.add('${main.vias} via(s): barrel ${(barrel * 1e3).toStringAsFixed(2)} mm, stub ${(stub * 1e3).toStringAsFixed(2)} mm, '
        'antipad assumed pad + 0.3 mm; placed evenly along the route.');
  }
  return out;
}
