import 'package:flutter/foundation.dart';

import '../simulation/engine.dart';

/// How simulations run on this platform (shown in About).
String get simulationRunner => 'background isolate';

Future<SimulationResult> simulatePlatform(AnalysisConfig cfg) => compute(runAnalysisFromJson, cfg.toJson());
