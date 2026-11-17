import 'package:flutter/services.dart';

/// Returns true when the link was opened; false when it was copied instead.
Future<bool> openExternal(String url) async {
  await Clipboard.setData(ClipboardData(text: url));
  return false;
}
