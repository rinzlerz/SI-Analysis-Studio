// Browser storage: IndexedDB through dart:js_interop (no extra packages).
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../data/models/analysis_record.dart';
import '../data/models/app_settings.dart';
import '../data/models/library_item.dart';
import '../data/repositories/analysis_repository.dart';

/// Where analyses are kept on this platform (shown in About).
const String storageDescription = 'in this browser only (IndexedDB) – nothing is uploaded';

Future<AnalysisRepository> createPlatformRepository() async =>
    WebAnalysisRepository(await IdbStore.open('si_studio', 1, const ['analyses', 'library', 'settings']));

class IdbStore {
  IdbStore(this._db);
  final JSObject _db;

  static Future<IdbStore> open(String name, int version, List<String> stores) {
    final factory = globalContext.getProperty<JSObject?>('indexedDB'.toJS);
    if (factory == null) throw StateError('IndexedDB is not available in this browser.');
    final c = Completer<IdbStore>();
    final req = factory.callMethod<JSObject>('open'.toJS, name.toJS, version.toJS);
    req.setProperty(
        'onupgradeneeded'.toJS,
        ((JSObject _) {
          final db = req.getProperty<JSObject>('result'.toJS);
          final names = db.getProperty<JSObject>('objectStoreNames'.toJS);
          for (final s in stores) {
            final has = names.callMethod<JSBoolean>('contains'.toJS, s.toJS).toDart;
            if (!has) db.callMethod<JSAny?>('createObjectStore'.toJS, s.toJS, {'autoIncrement': true}.jsify());
          }
        }).toJS);
    req.setProperty(
        'onsuccess'.toJS,
        ((JSObject _) {
          if (!c.isCompleted) c.complete(IdbStore(req.getProperty<JSObject>('result'.toJS)));
        }).toJS);
    req.setProperty(
        'onerror'.toJS,
        ((JSObject _) {
          if (!c.isCompleted) c.completeError(StateError('Could not open browser storage (IndexedDB).'));
        }).toJS);
    return c.future.timeout(const Duration(seconds: 8));
  }

  JSObject _store(String name, {bool write = false}) {
    final tx = _db.callMethod<JSObject>('transaction'.toJS, name.toJS, (write ? 'readwrite' : 'readonly').toJS);
    return tx.callMethod<JSObject>('objectStore'.toJS, name.toJS);
  }

  Future<JSAny?> _await(JSObject req) {
    final c = Completer<JSAny?>();
    req.setProperty('onsuccess'.toJS, ((JSObject _) => c.complete(req.getProperty<JSAny?>('result'.toJS))).toJS);
    req.setProperty('onerror'.toJS, ((JSObject _) => c.completeError(StateError('Browser storage request failed.'))).toJS);
    return c.future;
  }

  /// All (key, JSON string) pairs of [store].
  Future<List<(int, String)>> all(String store) async {
    final s = _store(store);
    // Issue both requests in the same transaction before awaiting.
    final kf = _await(s.callMethod<JSObject>('getAllKeys'.toJS));
    final vf = _await(s.callMethod<JSObject>('getAll'.toJS));
    final keys = ((await kf).dartify() as List?) ?? const [];
    final vals = ((await vf).dartify() as List?) ?? const [];
    return [
      for (var i = 0; i < keys.length && i < vals.length; i++) ((keys[i] as num).toInt(), '${vals[i]}'),
    ];
  }

  Future<String?> get(String store, int key) async {
    final r = await _await(_store(store).callMethod<JSObject>('get'.toJS, key.toJS));
    final d = r.dartify();
    return d == null ? null : '$d';
  }

  /// Inserts (key null) or replaces; returns the key.
  Future<int> put(String store, String value, [int? key]) async {
    final s = _store(store, write: true);
    final req = key == null
        ? s.callMethod<JSObject>('add'.toJS, value.toJS)
        : s.callMethod<JSObject>('put'.toJS, value.toJS, key.toJS);
    final r = await _await(req);
    return (r.dartify() as num).toInt();
  }

  Future<void> delete(String store, int key) async {
    await _await(_store(store, write: true).callMethod<JSObject>('delete'.toJS, key.toJS));
  }
}

class WebAnalysisRepository implements AnalysisRepository {
  WebAnalysisRepository(this._idb);
  final IdbStore _idb;

  static Map<String, Object?> _row(String json, int id) =>
      {...(jsonDecode(json) as Map).cast<String, Object?>(), 'id': id};

  @override
  Future<List<AnalysisRecord>> list() async {
    final out = <AnalysisRecord>[];
    for (final (id, json) in await _idb.all('analyses')) {
      try {
        out.add(AnalysisRecord.fromRow(_row(json, id)));
      } catch (_) {
        // Skip corrupt entries rather than failing the whole history.
      }
    }
    return out..sort((a, b) => b.updated.compareTo(a.updated));
  }

  @override
  Future<AnalysisRecord> save(AnalysisRecord r) async {
    final row = r.toRow()..remove('id');
    r.id = await _idb.put('analyses', jsonEncode(row), r.id);
    return r;
  }

  @override
  Future<void> delete(int id) => _idb.delete('analyses', id);

  @override
  Future<AppSettings?> loadSettings() async {
    final s = await _idb.get('settings', 1);
    if (s == null) return null;
    try {
      return AppSettings.fromJson((jsonDecode(s) as Map).cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveSettings(AppSettings s) async {
    await _idb.put('settings', jsonEncode(s.toJson()), 1);
  }

  @override
  Future<List<LibraryItem>> listLibrary() async {
    final out = <LibraryItem>[];
    for (final (id, json) in await _idb.all('library')) {
      try {
        out.add(LibraryItem.fromRow(_row(json, id)));
      } catch (_) {}
    }
    return out..sort((a, b) => a.name.compareTo(b.name));
  }

  @override
  Future<LibraryItem> saveLibrary(LibraryItem item) async {
    final row = item.toRow()..remove('id');
    item.id = await _idb.put('library', jsonEncode(row), item.id);
    return item;
  }

  @override
  Future<void> deleteLibrary(int id) => _idb.delete('library', id);
}
