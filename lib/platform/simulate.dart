/// Runs the simulation engine off the UI thread: a Dart isolate on Android,
/// a web worker (sim_worker.js) in the browser, falling back to the main
/// thread when the worker is unavailable (e.g. `flutter run -d chrome`).
library;

export 'simulate_io.dart' if (dart.library.js_interop) 'simulate_web.dart';
