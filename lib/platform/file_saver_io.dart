import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// True when exports are downloaded (web) instead of shared.
const bool exportsDownload = false;

/// Writes [files] (name -> (bytes, mime)) to the temp folder and opens the
/// share sheet.
Future<void> saveFiles(Map<String, (Uint8List, String)> files, String subject) async {
  final dir = await getTemporaryDirectory();
  final xs = <XFile>[];
  for (final e in files.entries) {
    final f = File(p.join(dir.path, e.key));
    await f.writeAsBytes(e.value.$1, flush: true);
    xs.add(XFile(f.path, mimeType: e.value.$2));
  }
  await SharePlus.instance.share(ShareParams(files: xs, subject: subject));
}
