// Share links and the web-worker result codec.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:si_studio/core/share_link.dart';
import 'package:si_studio/simulation/engine.dart';
import 'package:si_studio/simulation/model/result_codec.dart';

void main() {
  const base = 'https://rinzlerz.github.io/SI-Analysis-Studio/';

  group('Share links', () {
    test('every protocol round-trips and reproduces the same result', () {
      for (final p in Protocol.values) {
        final c = AnalysisConfig.defaults(protocol: p);
        if (p.differential) applyTargetWidth(c);
        final link = buildShareLink(c, base, name: 'Case ${p.name}');
        expect(link.url.startsWith('$base#a='), isTrue);
        expect(link.url.length, lessThan(4000), reason: p.name);
        final back = parseShareFragment(Uri.parse(link.url).fragment)!;
        expect(back.name, 'Case ${p.name}');
        expect(back.config.protocol, p);
        expect(runAnalysis(back.config).overallStatus, runAnalysis(c).overallStatus, reason: p.name);
      }
    });

    test('edited values survive', () {
      final c = AnalysisConfig.defaults(protocol: Protocol.i2c)
        ..i2c.pullupR = 3.3e3
        ..pcb.traceLength = 0.25;
      final back = parseShareFragment(buildShareLink(c, base).url.split('#').last)!;
      expect(back.config.i2c.pullupR, 3.3e3);
      expect(back.config.pcb.traceLength, 0.25);
    });

    test('non-share fragments are ignored and damaged links are reported', () {
      expect(parseShareFragment(''), isNull);
      expect(parseShareFragment('#section'), isNull);
      expect(() => parseShareFragment('a=not-base64!!'), throwsA(isA<FormatException>()));
    });
  });

  group('Result codec (web worker)', () {
    test('results survive encode / JSON / decode', () {
      for (final p in [Protocol.spi, Protocol.pcie, Protocol.i2c]) {
        final c = AnalysisConfig.defaults(protocol: p);
        if (p.differential) applyTargetWidth(c);
        final r = runAnalysis(c);
        final d = decodeResult((jsonDecode(jsonEncode(encodeResult(r))) as Map).cast<String, Object?>());
        expect(d.traces.length, r.traces.length);
        for (var i = 0; i < r.traces.length; i++) {
          expect(d.traces[i].values.length, r.traces[i].values.length);
          expect(d.traces[i].values.last, r.traces[i].values.last);
        }
        expect(d.metrics.map((m) => m.id).toList(), r.metrics.map((m) => m.id).toList());
        expect(d.eyes.length, r.eyes.length);
        expect(d.overallStatus, r.overallStatus);
        expect(d.checks.length, r.checks.length);
        expect(d.dt, r.dt);
      }
    });
  });
}
