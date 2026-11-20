/// Web-worker entry point: compiled separately with
/// `dart compile js -O2 -o build/web/sim_worker.js lib/simulation/worker/sim_worker.dart`
/// (done by the GitHub Pages workflow). Receives `{"id", "config"}` JSON,
/// replies `{"id", "ok", "result" | "error"}` JSON.
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../engine.dart';
import '../model/result_codec.dart';

void main() {
  globalContext.setProperty(
      'onmessage'.toJS,
      ((JSObject e) {
        final req = (jsonDecode(e.getProperty<JSString>('data'.toJS).toDart) as Map).cast<String, Object?>();
        final id = req['id'];
        String reply;
        try {
          final r = runAnalysis(AnalysisConfig.fromJson((req['config'] as Map).cast<String, Object?>()));
          reply = jsonEncode({'id': id, 'ok': true, 'result': encodeResult(r)});
        } on SimulationError catch (x) {
          reply = jsonEncode({'id': id, 'ok': false, 'sim': true, 'error': x.message});
        } catch (x) {
          reply = jsonEncode({'id': id, 'ok': false, 'error': '$x'});
        }
        globalContext.callMethod<JSAny?>('postMessage'.toJS, reply.toJS);
      }).toJS);
}
