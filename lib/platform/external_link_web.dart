import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Returns true when the link was opened; false when it was copied instead.
Future<bool> openExternal(String url) async {
  globalContext.callMethod<JSAny?>('open'.toJS, url.toJS, '_blank'.toJS, 'noopener'.toJS);
  return true;
}
