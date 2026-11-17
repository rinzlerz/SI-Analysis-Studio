import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Local SQLite database (offline storage, PRD 10 / 12.3).
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const _version = 2;

  static const _libraryTable = '''
    CREATE TABLE library (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      kind TEXT NOT NULL,
      name TEXT NOT NULL,
      data TEXT NOT NULL,
      created INTEGER NOT NULL
    )
  ''';

  static Future<AppDatabase> open() async {
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dir, 'si_studio.db'),
      version: _version,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE analyses (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            protocol TEXT NOT NULL,
            created INTEGER NOT NULL,
            updated INTEGER NOT NULL,
            status TEXT NOT NULL,
            config TEXT NOT NULL,
            summary TEXT NOT NULL,
            model_version TEXT NOT NULL
          )
        ''');
        await db.execute('CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
        await db.execute(_libraryTable);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await db.execute(_libraryTable);
      },
    );
    return AppDatabase._(db);
  }
}
