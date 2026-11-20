import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../simulation/engine.dart';
import '../simulation/model/result_codec.dart';

final _runner = _WorkerRunner();

/// How simulations run on this platform (shown in About).
String get simulationRunner => _runner.broken ? 'main thread (worker unavailable)' : 'background web worker';

Future<SimulationResult> simulatePlatform(AnalysisConfig cfg) => _runner.run(cfg);

class _WorkerRunner {
  JSObject? _worker;
  bool broken = false;
  int _next = 0;
  final _pending = <int, (Completer<SimulationResult>, AnalysisConfig)>{};

  Future<SimulationResult> run(AnalysisConfig cfg) {
    if (!broken) {
      try {
        _ensure();
      } catch (_) {
        broken = true;
      }
    }
    if (broken) return _mainThread(cfg);
    final id = _next++;
    final c = Completer<SimulationResult>();
    _pending[id] = (c, cfg);
    _worker!.callMethod<JSAny?>('postMessage'.toJS, jsonEncode({'id': id, 'config': cfg.toJson()}).toJS);
    return c.future;
  }

  void _ensure() {
    if (_worker != null) return;
    final w = globalContext.getProperty<JSFunction>('Worker'.toJS).callAsConstructor<JSObject>('sim_worker.js'.toJS);
    w.setProperty(
        'onmessage'.toJS,
        ((JSObject e) {
          final reply = (jsonDecode(e.getProperty<JSString>('data'.toJS).toDart) as Map).cast<String, Object?>();
          final entry = _pending.remove((reply['id'] as num).toInt());
          if (entry == null) return;
          final (c, _) = entry;
          if (reply['ok'] == true) {
            try {
              c.complete(decodeResult((reply['result'] as Map).cast<String, Object?>()));
            } catch (x) {
              c.completeError(SimulationError('Could not read the simulation result: $x'));
            }
          } else {
            c.completeError(reply['sim'] == true ? SimulationError('${reply['error']}') : StateError('${reply['error']}'));
          }
        }).toJS);
    w.setProperty(
        'onerror'.toJS,
        ((JSObject e) {
          // Worker script missing or failed to start: run on the main thread.
          e.callMethod<JSAny?>('preventDefault'.toJS);
          broken = true;
          _worker?.callMethod<JSAny?>('terminate'.toJS);
          _worker = null;
          final waiting = Map.of(_pending);
          _pending.clear();
          for (final (c, cfg) in waiting.values) {
            c.complete(_mainThread(cfg));
          }
        }).toJS);
    _worker = w;
  }

  static Future<SimulationResult> _mainThread(AnalysisConfig cfg) async {
    // Give the UI two frames to show its progress state first.
    await Future<void>.delayed(const Duration(milliseconds: 40));
    return runAnalysis(cfg.copy());
  }
}
