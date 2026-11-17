import 'dart:convert';

import 'package:file_picker/file_picker.dart';

/// Picks a text file (IBIS, Touchstone) with the system file picker.
/// Returns null when cancelled. Throws [FormatException] for a wrong type.
Future<({String name, String text})?> pickTextFile(List<String> extensions) async {
  final res = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
  if (res == null || res.files.isEmpty) return null;
  final f = res.files.single;
  final name = f.name;
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  if (!extensions.contains(ext)) {
    throw FormatException('Expected a ${extensions.map((e) => '.$e').join(' / ')} file, got "$name".');
  }
  // withData: true returns the bytes on every platform (Android and web).
  final bytes = f.bytes;
  if (bytes == null) throw const FormatException('Could not read the selected file.');
  String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    text = latin1.decode(bytes);
  }
  return (name: name, text: text);
}
