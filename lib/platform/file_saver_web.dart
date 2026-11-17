import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

/// True when exports are downloaded (web) instead of shared.
const bool exportsDownload = true;

/// Downloads each file through the browser.
Future<void> saveFiles(Map<String, (Uint8List, String)> files, String subject) async {
  for (final e in files.entries) {
    _download(e.key, e.value.$1, e.value.$2);
    // Browsers may drop rapid consecutive downloads.
    if (files.length > 1) await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}

void _download(String fileName, Uint8List bytes, String mime) {
  final blob = globalContext
      .getProperty<JSFunction>('Blob'.toJS)
      .callAsConstructor<JSObject>(<JSAny?>[bytes.toJS].toJS, {'type': mime}.jsify());
  final urlApi = globalContext.getProperty<JSObject>('URL'.toJS);
  final url = urlApi.callMethod<JSString>('createObjectURL'.toJS, blob);
  final doc = globalContext.getProperty<JSObject>('document'.toJS);
  final a = doc.callMethod<JSObject>('createElement'.toJS, 'a'.toJS);
  a.setProperty('href'.toJS, url);
  a.setProperty('download'.toJS, fileName.toJS);
  final body = doc.getProperty<JSObject>('body'.toJS);
  body.callMethod<JSAny?>('appendChild'.toJS, a);
  a.callMethod<JSAny?>('click'.toJS);
  body.callMethod<JSAny?>('removeChild'.toJS, a);
  Timer(const Duration(seconds: 60), () => urlApi.callMethod<JSAny?>('revokeObjectURL'.toJS, url));
}
