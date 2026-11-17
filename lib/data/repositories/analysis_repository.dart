import '../models/analysis_record.dart';
import '../models/app_settings.dart';
import '../models/library_item.dart';

/// Storage interface: SQLite on Android, IndexedDB in the browser, memory as
/// a fallback (widget tests, private browsing).
abstract class AnalysisRepository {
  Future<List<AnalysisRecord>> list();
  Future<AnalysisRecord> save(AnalysisRecord r);
  Future<void> delete(int id);
  Future<AppSettings?> loadSettings();
  Future<void> saveSettings(AppSettings s);
  Future<List<LibraryItem>> listLibrary();
  Future<LibraryItem> saveLibrary(LibraryItem item);
  Future<void> deleteLibrary(int id);
}

class MemoryAnalysisRepository implements AnalysisRepository {
  final _items = <AnalysisRecord>[];
  AppSettings? _settings;
  var _next = 1;

  @override
  Future<List<AnalysisRecord>> list() async =>
      List.of(_items)..sort((a, b) => b.updated.compareTo(a.updated));

  @override
  Future<AnalysisRecord> save(AnalysisRecord r) async {
    if (r.id == null) {
      r.id = _next++;
      _items.add(r);
    } else {
      final i = _items.indexWhere((x) => x.id == r.id);
      if (i >= 0) _items[i] = r;
    }
    return r;
  }

  @override
  Future<void> delete(int id) async => _items.removeWhere((x) => x.id == id);

  @override
  Future<AppSettings?> loadSettings() async => _settings?.copy();

  @override
  Future<void> saveSettings(AppSettings s) async => _settings = s.copy();

  final _lib = <LibraryItem>[];
  var _libNext = 1;

  @override
  Future<List<LibraryItem>> listLibrary() async => List.of(_lib)..sort((a, b) => a.name.compareTo(b.name));

  @override
  Future<LibraryItem> saveLibrary(LibraryItem item) async {
    if (item.id == null) {
      item.id = _libNext++;
      _lib.add(item);
    } else {
      final i = _lib.indexWhere((x) => x.id == item.id);
      if (i >= 0) _lib[i] = item;
    }
    return item;
  }

  @override
  Future<void> deleteLibrary(int id) async => _lib.removeWhere((x) => x.id == id);
}
