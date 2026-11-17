/// Opens an external link: new browser tab on the web; copies it to the
/// clipboard on Android (no browser plugin is bundled).
library;
export 'external_link_io.dart' if (dart.library.js_interop) 'external_link_web.dart';
