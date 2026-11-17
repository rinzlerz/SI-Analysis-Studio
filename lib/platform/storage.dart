/// Creates the platform storage: SQLite on Android / desktop, IndexedDB in
/// the browser.
library;
export 'storage_io.dart' if (dart.library.js_interop) 'storage_web.dart';
