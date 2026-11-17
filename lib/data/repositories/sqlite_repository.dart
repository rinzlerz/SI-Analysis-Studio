import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../local_database/app_database.dart';
import '../models/analysis_record.dart';
import '../models/app_settings.dart';
import '../models/library_item.dart';
import 'analysis_repository.dart';

class SqliteAnalysisRepository implements AnalysisRepository {
  SqliteAnalysisRepository(this._db);
  final AppDatabase _db;

  Database get db => _db.db;

  @override
  Future<List<AnalysisRecord>> list() async {
    final rows = await db.query('analyses', orderBy: 'updated DESC');
    final out = <AnalysisRecord>[];
    for (final r in rows) {
      try {
        out.add(AnalysisRecord.fromRow(r));
      } catch (_) {
        // Skip corrupt rows rather than failing the whole history.
      }
    }
    return out;
  }

  @override
  Future<AnalysisRecord> save(AnalysisRecord r) async {
    if (r.id == null) {
      r.id = await db.insert('analyses', r.toRow());
    } else {
      await db.update('analyses', r.toRow(), where: 'id = ?', whereArgs: [r.id]);
    }
    return r;
  }

  @override
  Future<void> delete(int id) async {
    await db.delete('analyses', where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<AppSettings?> loadSettings() async {
    final rows = await db.query('settings', where: 'key = ?', whereArgs: ['app']);
    if (rows.isEmpty) return null;
    try {
      return AppSettings.fromJson((jsonDecode('${rows.first['value']}') as Map).cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<LibraryItem>> listLibrary() async {
    final rows = await db.query('library', orderBy: 'name');
    final out = <LibraryItem>[];
    for (final r in rows) {
      try {
        out.add(LibraryItem.fromRow(r));
      } catch (_) {}
    }
    return out;
  }

  @override
  Future<LibraryItem> saveLibrary(LibraryItem item) async {
    if (item.id == null) {
      item.id = await db.insert('library', item.toRow());
    } else {
      await db.update('library', item.toRow(), where: 'id = ?', whereArgs: [item.id]);
    }
    return item;
  }

  @override
  Future<void> deleteLibrary(int id) async {
    await db.delete('library', where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> saveSettings(AppSettings s) async {
    await db.insert('settings', {'key': 'app', 'value': jsonEncode(s.toJson())},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

