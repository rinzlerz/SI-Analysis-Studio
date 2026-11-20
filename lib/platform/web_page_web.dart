import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/services.dart';

/// Base URL that share links point to: this page (works on any host).
String pageBaseUrl() => Uri.base.toString().split('#').first;

/// Returns the launch fragment once and removes it from the address bar.
String? takeLaunchFragment() {
  final f = Uri.base.fragment;
  if (f.isEmpty) return null;
  try {
    final loc = globalContext.getProperty<JSObject>('location'.toJS);
    final path = '${loc.getProperty<JSString>('pathname'.toJS).toDart}${loc.getProperty<JSString>('search'.toJS).toDart}';
    globalContext
        .getProperty<JSObject>('history'.toJS)
        .callMethod<JSAny?>('replaceState'.toJS, null, ''.toJS, path.toJS);
  } catch (_) {}
  return f;
}

/// Shares [url]; returns true when shared, false when copied to the clipboard.
Future<bool> shareUrl(String url, String subject) async {
  await Clipboard.setData(ClipboardData(text: url));
  return false;
}
