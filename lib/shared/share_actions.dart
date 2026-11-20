import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../core/app_info.dart';
import '../core/share_link.dart';
import '../core/state/app_controller.dart';
import '../features/analysis_results/results_screen.dart';
import '../platform/external_link.dart';
import '../platform/web_page.dart';
import '../simulation/engine.dart';

/// Shares a link that reopens [cfg] (share sheet on Android, clipboard on the web).
Future<void> shareAnalysis(BuildContext context, AnalysisConfig cfg, {String? name}) async {
  final messenger = ScaffoldMessenger.of(context);
  final link = buildShareLink(cfg, pageBaseUrl(), name: name);
  try {
    final shared = await shareUrl(link.url, 'SI Studio analysis${name == null ? '' : ' – $name'}');
    if (!shared || link.modelsDropped) {
      messenger.showSnackBar(SnackBar(
        content: Text([
          if (!shared) 'Link copied – paste it into a message or e-mail.',
          if (link.modelsDropped) 'IBIS / S-parameter models are not included in links.',
        ].join(' ')),
      ));
    }
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not share the link: $e')));
  }
}

/// Opens the feedback form, pre-filled with the app version, platform and
/// (optionally) a link to the analysis in question.
Future<void> sendFeedback(BuildContext context, {AnalysisConfig? cfg, String? name}) async {
  if (feedbackUrl.isEmpty) return;
  final messenger = ScaffoldMessenger.of(context);
  final params = <String, String>{
    'version': '$appVersion ($simulationModelVersion)',
    'platform': kIsWeb ? 'Web browser' : 'Android app',
    if (cfg != null) 'protocol': cfg.protocol.label,
    if (cfg != null) 'link': buildShareLink(cfg, webAppUrl, name: name).url,
  };
  final sep = feedbackUrl.contains('?') ? '&' : '?';
  final url = feedbackUrl.startsWith('http')
      ? '$feedbackUrl$sep${params.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&')}'
      : feedbackUrl;
  final opened = await openExternal(url);
  if (!opened) {
    messenger.showSnackBar(const SnackBar(content: Text('Feedback link copied – open it in a browser.')));
  }
}

/// Opens an analysis passed in the page URL (share link), if any.
Future<void> openLaunchShare(BuildContext context, AppController c) async {
  final fragment = takeLaunchFragment();
  if (fragment == null) return;
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  SharedAnalysis? shared;
  try {
    shared = parseShareFragment(fragment);
  } on FormatException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
    return;
  }
  if (shared == null) return;
  c.setDraft(shared.config, name: 'Shared · ${shared.name ?? shared.config.protocol.label}');
  c.tab.value = 1;
  try {
    final r = await c.runDraft();
    messenger.showSnackBar(const SnackBar(content: Text('Opened a shared analysis. Edit it in New Analysis.')));
    await nav.push(MaterialPageRoute<void>(
      builder: (_) => ResultsScreen(controller: c, result: r.result, record: r.record),
    ));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('The shared analysis could not run: $e')));
  }
}
