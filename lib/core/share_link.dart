/// Shareable analysis links: the configuration travels in the URL fragment
/// (`#a=...`), which browsers never send to the server.
library;

import 'dart:convert';

import '../simulation/model/config.dart';

class SharedAnalysis {
  SharedAnalysis(this.config, this.name);
  final AnalysisConfig config;
  final String? name;
}

/// Result of building a link.
class ShareLink {
  ShareLink(this.url, {required this.modelsDropped});
  final String url;

  /// IBIS / Touchstone models are too large for a link and were left out.
  final bool modelsDropped;
}

const _protocolKeys = ['spi', 'usb2', 'usb3', 'pcie', 'hdmi', 'qspi', 'i2c', 'rgmii', 'ddr'];

String _key(Protocol p) => switch (p) {
      Protocol.spi => 'spi',
      Protocol.usb2 => 'usb2',
      Protocol.usb3 => 'usb3',
      Protocol.pcie => 'pcie',
      Protocol.hdmi => 'hdmi',
      Protocol.qspi => 'qspi',
      Protocol.i2c => 'i2c',
      Protocol.rgmii => 'rgmii',
      Protocol.ddr => 'ddr',
    };

/// Builds a link to [baseUrl] that reopens [c].
ShareLink buildShareLink(AnalysisConfig c, String baseUrl, {String? name}) {
  final j = c.toJson();
  final keep = _key(c.protocol);
  for (final k in _protocolKeys) {
    if (k != keep) j.remove(k);
  }
  var dropped = false;
  final p = j[keep];
  if (p is Map<String, Object?>) {
    for (final k in ['ibisDrv', 'ibisRx', 'sp']) {
      if (p.containsKey(k)) {
        p.remove(k);
        dropped = true;
      }
    }
    if (dropped) {
      p['useIbis'] = false;
      p['useSp'] = false;
    }
  }
  final payload = jsonEncode({'v': 1, if (name != null) 'n': name, 'c': j});
  final data = base64Url.encode(utf8.encode(payload)).replaceAll('=', '');
  final base = baseUrl.split('#').first;
  return ShareLink('$base#a=$data', modelsDropped: dropped);
}

/// Parses a URL fragment such as `a=...` (with or without the leading '#').
/// Returns null when the fragment is not a share link; throws
/// [FormatException] when it is one but cannot be read.
SharedAnalysis? parseShareFragment(String fragment) {
  final f = fragment.startsWith('#') ? fragment.substring(1) : fragment;
  if (!f.startsWith('a=')) return null;
  var data = f.substring(2);
  data = data.padRight((data.length + 3) ~/ 4 * 4, '=');
  try {
    final j = (jsonDecode(utf8.decode(base64Url.decode(data))) as Map).cast<String, Object?>();
    final c = AnalysisConfig.fromJson((j['c'] as Map).cast<String, Object?>());
    return SharedAnalysis(c, j['n'] as String?);
  } catch (e) {
    throw const FormatException('This analysis link is damaged or incomplete.');
  }
}
