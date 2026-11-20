/// Lossless JSON encoding of a [SimulationResult] so a result can cross a
/// web-worker boundary (browsers have no Dart isolates). Sample arrays are
/// sent as base64 of their raw bytes; non-finite doubles as strings.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'config.dart';
import 'result.dart';

Object _d(double x) => x.isFinite ? x : x.toString();
double _rd(Object? v) => v is num ? v.toDouble() : (double.tryParse('$v') ?? double.nan);
double? _rdn(Object? v) => v == null ? null : _rd(v);

String _f32(Float32List a) => base64Encode(a.buffer.asUint8List(a.offsetInBytes, a.lengthInBytes));
String _f64(Float64List a) => base64Encode(a.buffer.asUint8List(a.offsetInBytes, a.lengthInBytes));

Float32List _rf32(Object? s) {
  final b = base64Decode('$s');
  return Float32List.view(Uint8List.fromList(b).buffer, 0, b.length ~/ 4);
}

Float64List _rf64(Object? s) {
  final b = base64Decode('$s');
  return Float64List.view(Uint8List.fromList(b).buffer, 0, b.length ~/ 8);
}

Map<String, Object?> _eye(EyeResult e) => {
      'ui': _d(e.ui),
      'seg': _f64(e.segments),
      'pps': e.pointsPerSegment,
      'h': _d(e.eyeHeight),
      'w': _d(e.eyeWidth),
      'cross': _d(e.crossingPct),
      'jit': _d(e.jitterPkPk),
      'ideal': _d(e.idealEyeHeight),
      'vmin': _d(e.vMin),
      'vmax': _d(e.vMax),
      'label': e.traceLabel,
      'top': _d(e.eyeTop),
      'bot': _d(e.eyeBottom),
      'phase': _d(e.phaseDelay),
      'xo': _f64(e.crossingOffsets),
      if (e.maskHeight != null) 'mh': _d(e.maskHeight!),
      if (e.maskWidth != null) 'mw': _d(e.maskWidth!),
      if (e.maskHits != null) 'hits': e.maskHits,
      if (e.maskRect) 'rect': true,
      if (e.maskSamples != null) 'msamp': e.maskSamples,
      if (e.bathtubPhase != null) 'btp': _f64(e.bathtubPhase!),
      if (e.bathtubLog10Ber != null) 'btb': _f64(e.bathtubLog10Ber!),
      if (e.eyeWidthAtBer != null) 'wber': _d(e.eyeWidthAtBer!),
      if (e.targetBer != null) 'tber': _d(e.targetBer!),
    };

EyeResult _readEye(Map<String, Object?> j) {
  final e = EyeResult(
    ui: _rd(j['ui']),
    segments: _rf64(j['seg']),
    pointsPerSegment: (j['pps'] as num).toInt(),
    eyeHeight: _rd(j['h']),
    eyeWidth: _rd(j['w']),
    crossingPct: _rd(j['cross']),
    jitterPkPk: _rd(j['jit']),
    idealEyeHeight: _rd(j['ideal']),
    vMin: _rd(j['vmin']),
    vMax: _rd(j['vmax']),
    traceLabel: '${j['label']}',
    eyeTop: _rd(j['top']),
    eyeBottom: _rd(j['bot']),
    phaseDelay: _rd(j['phase']),
    crossingOffsets: _rf64(j['xo']),
  );
  e.maskHeight = _rdn(j['mh']);
  e.maskWidth = _rdn(j['mw']);
  e.maskHits = (j['hits'] as num?)?.toInt();
  e.maskRect = j['rect'] == true;
  e.maskSamples = (j['msamp'] as num?)?.toInt();
  if (j['btp'] != null) e.bathtubPhase = _rf64(j['btp']);
  if (j['btb'] != null) e.bathtubLog10Ber = _rf64(j['btb']);
  e.eyeWidthAtBer = _rdn(j['wber']);
  e.targetBer = _rdn(j['tber']);
  return e;
}

Map<String, Object?> encodeResult(SimulationResult r) => {
      'config': r.config.toJson(),
      'dt': r.dt,
      'n': r.sampleCount,
      'traces': [
        for (final t in r.traces)
          {
            'id': t.id,
            'label': t.label,
            'group': t.group,
            'kind': t.kind.name,
            'vis': t.visibleByDefault,
            'data': _f32(t.values),
          },
      ],
      'views': r.views,
      'metrics': [for (final m in r.metrics) m.toJson()],
      'findings': [for (final f in r.findings) f.toJson()],
      'assumptions': r.assumptions,
      'imp': {
        'structure': r.impedance.structure,
        'z0': _d(r.impedance.z0),
        'zd': r.impedance.zDiff == null ? null : _d(r.impedance.zDiff!),
        'eeff': _d(r.impedance.eeff),
        'target': _d(r.impedance.target),
        'diff': r.impedance.targetIsDiff,
        'method': r.impedance.method,
        'wft': r.impedance.widthForTarget == null ? null : _d(r.impedance.widthForTarget!),
      },
      'eyes': [for (final e in r.eyes) _eye(e)],
      if (r.animation != null)
        'anim': {
          'label': r.animation!.label,
          'inc': r.animation!.incidentId,
          'refl': r.animation!.reflectedId,
          'tx': r.animation!.txId,
          'rx': r.animation!.rxId,
          'delay': _d(r.animation!.delay),
          'start': _d(r.animation!.startTime),
        },
      'ms': r.computeMillis,
      'checks': [for (final c in r.checks) c.toJson()],
    };

SimulationResult decodeResult(Map<String, Object?> j) {
  Map<String, Object?> m(Object? o) => (o as Map).cast<String, Object?>();
  final imp = m(j['imp']);
  final anim = j['anim'] == null ? null : m(j['anim']);
  return SimulationResult(
    config: AnalysisConfig.fromJson(m(j['config'])),
    dt: _rd(j['dt']),
    sampleCount: (j['n'] as num).toInt(),
    traces: [
      for (final t in (j['traces'] as List).map(m))
        WaveformTrace(
          id: '${t['id']}',
          label: '${t['label']}',
          group: '${t['group']}',
          kind: TraceKind.values.firstWhere((k) => k.name == t['kind'], orElse: () => TraceKind.other),
          visibleByDefault: t['vis'] != false,
          values: _rf32(t['data']),
        ),
    ],
    views: {
      for (final e in m(j['views']).entries) e.key: [for (final id in e.value as List) '$id'],
    },
    metrics: [for (final x in (j['metrics'] as List).map(m)) Metric.fromJson(x)],
    findings: [for (final x in (j['findings'] as List).map(m)) Finding.fromJson(x)],
    assumptions: [for (final a in j['assumptions'] as List) '$a'],
    impedance: ImpedanceSummary(
      structure: '${imp['structure']}',
      z0: _rd(imp['z0']),
      zDiff: _rdn(imp['zd']),
      eeff: _rd(imp['eeff']),
      target: _rd(imp['target']),
      targetIsDiff: imp['diff'] == true,
      method: '${imp['method']}',
      widthForTarget: _rdn(imp['wft']),
    ),
    eyes: [for (final e in (j['eyes'] as List).map(m)) _readEye(e)],
    animation: anim == null
        ? null
        : AnimationSource(
            label: '${anim['label']}',
            incidentId: '${anim['inc']}',
            reflectedId: '${anim['refl']}',
            txId: '${anim['tx']}',
            rxId: '${anim['rx']}',
            delay: _rd(anim['delay']),
            startTime: _rd(anim['start']),
          ),
    computeMillis: (j['ms'] as num).toInt(),
    checks: [
      for (final c in (j['checks'] as List).map(m))
        ComplianceCheck(
          name: '${c['name']}',
          requirement: '${c['requirement']}',
          measured: '${c['measured']}',
          pass: c['pass'] as bool?,
          source: '${c['source']}',
        ),
    ],
  );
}
