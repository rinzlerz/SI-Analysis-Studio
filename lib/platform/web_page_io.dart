import 'package:share_plus/share_plus.dart';

import '../core/app_info.dart';

/// Base URL that share links point to.
String pageBaseUrl() => webAppUrl;

/// The URL fragment the app was opened with (web only).
String? takeLaunchFragment() => null;

/// Shares [url]; returns true when shared, false when copied to the clipboard.
Future<bool> shareUrl(String url, String subject) async {
  await SharePlus.instance.share(ShareParams(text: url, subject: subject));
  return true;
}
