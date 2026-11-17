/// Delivers exported files: share sheet on Android, browser download on the web.
library;
export 'file_saver_io.dart' if (dart.library.js_interop) 'file_saver_web.dart';
