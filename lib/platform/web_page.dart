/// Browser page helpers: the page URL, the launch fragment (share links) and
/// sharing a link. Android equivalents use the published web URL and the
/// share sheet.
library;

export 'web_page_io.dart' if (dart.library.js_interop) 'web_page_web.dart';
