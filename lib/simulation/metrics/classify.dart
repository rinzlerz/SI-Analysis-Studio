/// Threshold classification helpers (PRD 8.2: explicit thresholds only).
library;

import '../model/result.dart';

/// Larger values are worse: <= good -> Good, <= warn -> Warning, else Critical.
SiStatus classifyHigherWorse(double value, double good, double warn) {
  if (value.isNaN) return SiStatus.info;
  if (value <= good) return SiStatus.good;
  if (value <= warn) return SiStatus.warning;
  return SiStatus.critical;
}

/// Smaller values are worse: >= good -> Good, >= warn -> Warning, else Critical.
SiStatus classifyLowerWorse(double value, double good, double warn) {
  if (value.isNaN) return SiStatus.info;
  if (value >= good) return SiStatus.good;
  if (value >= warn) return SiStatus.warning;
  return SiStatus.critical;
}

/// Slack-style metric: < 0 Critical, < warn Warning, else Good.
SiStatus classifySlack(double slack, double warn) {
  if (slack.isNaN) return SiStatus.info;
  if (slack < 0) return SiStatus.critical;
  if (slack < warn) return SiStatus.warning;
  return SiStatus.good;
}
