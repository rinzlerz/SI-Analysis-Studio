/// Stimulus (driver open-circuit voltage) generation and data patterns.
///
/// Edges are linear ramps defined by their 50 % crossing time. A ramp whose
/// 10-90 % time is tr has a 0-100 % duration of tr / 0.8.
library;

import 'dart:typed_data';

import '../model/config.dart';

class Transition {
  const Transition(this.t50, this.level);

  /// Time of the 50 % point of the edge (s).
  final double t50;

  /// Level after the transition (V).
  final double level;
}

/// Samples a piecewise-linear edge waveform.
Float64List buildStimulus({
  required double initial,
  required List<Transition> transitions,
  required double riseTime,
  required double fallTime,
  required double dt,
  required int samples,
}) {
  final out = Float64List(samples);
  final tr = transitions.toList()..sort((a, b) => a.t50.compareTo(b.t50));
  // Precompute ramps.
  final starts = Float64List(tr.length);
  final widths = Float64List(tr.length);
  final deltas = Float64List(tr.length);
  var prev = initial;
  for (var i = 0; i < tr.length; i++) {
    final d = tr[i].level - prev;
    final w = (d >= 0 ? riseTime : fallTime) / 0.8;
    deltas[i] = d;
    widths[i] = w;
    starts[i] = tr[i].t50 - w / 2;
    prev = tr[i].level;
  }
  var maxWidth = 0.0;
  for (final w in widths) {
    if (w > maxWidth) maxWidth = w;
  }
  var base = initial;
  var first = 0; // first transition not yet completed
  for (var n = 0; n < samples; n++) {
    final t = n * dt;
    while (first < tr.length && t >= starts[first] + widths[first]) {
      base += deltas[first];
      first++;
    }
    var v = base;
    for (var i = first; i < tr.length; i++) {
      if (t <= starts[i]) {
        // Ramps are sorted by 50 % time; a later ramp can only start earlier
        // by at most the widest edge.
        if (starts[i] > t + maxWidth) break;
        continue;
      }
      final x = (t - starts[i]) / widths[i];
      v += deltas[i] * (x >= 1 ? 1 : x);
    }
    out[n] = v;
  }
  return out;
}

/// PRBS7 (x^7 + x^6 + 1), seed 0x7F.
List<int> prbs7(int count) {
  var reg = 0x7F;
  final out = <int>[];
  for (var i = 0; i < count; i++) {
    final bit = ((reg >> 6) ^ (reg >> 5)) & 1;
    reg = ((reg << 1) | bit) & 0x7F;
    out.add(bit);
  }
  return out;
}

class PatternError implements Exception {
  PatternError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Parses "A5C3", "0xA5", or "0b1010" (MSB first).
List<int> parseCustomPattern(String text) {
  var s = text.trim().replaceAll(RegExp(r'[\s_]'), '');
  if (s.isEmpty) throw PatternError('Custom pattern is empty.');
  final bits = <int>[];
  if (s.toLowerCase().startsWith('0b')) {
    s = s.substring(2);
    for (final ch in s.split('')) {
      if (ch != '0' && ch != '1') throw PatternError('Invalid binary digit "$ch".');
      bits.add(ch == '1' ? 1 : 0);
    }
  } else {
    if (s.toLowerCase().startsWith('0x')) s = s.substring(2);
    for (final ch in s.split('')) {
      final v = int.tryParse(ch, radix: 16);
      if (v == null) throw PatternError('Invalid hex digit "$ch".');
      for (var b = 3; b >= 0; b--) {
        bits.add((v >> b) & 1);
      }
    }
  }
  if (bits.isEmpty) throw PatternError('Custom pattern is empty.');
  return bits;
}

/// Data bits for a simulation; repeats custom patterns to [count] bits.
List<int> patternBits(SimSettings s, int count) {
  switch (s.pattern) {
    case DataPattern.prbs7:
      return prbs7(count);
    case DataPattern.alternating:
      return List<int>.generate(count, (i) => (i + 1) & 1);
    case DataPattern.custom:
      final p = parseCustomPattern(s.customPattern);
      return List<int>.generate(count, (i) => p[i % p.length]);
  }
}
