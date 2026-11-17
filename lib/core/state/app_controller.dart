import 'package:flutter/foundation.dart';

import '../../data/models/analysis_record.dart';
import '../../data/models/app_settings.dart';
import '../../data/models/library_item.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../platform/storage.dart';
import '../../simulation/common/format.dart';
import '../../simulation/engine.dart';

/// Application state: settings, the analysis being edited, and history.
class AppController extends ChangeNotifier {
  AppController(this._repo);

  final AnalysisRepository _repo;

  AppSettings settings = AppSettings.defaults();
  List<AnalysisRecord> history = [];

  /// Saved library entries (built-ins are added by [libraryOf]).
  List<LibraryItem> library = [];
  late AnalysisConfig draft;

  /// Name of the analysis being edited (null = auto-generated).
  String? draftName;

  bool running = false;

  /// True when analyses cannot be saved (e.g. private browsing) and are kept
  /// in memory for this session only.
  static bool storageUnavailable = false;

  /// Requested bottom-navigation tab (listened to by the shell).
  final ValueNotifier<int> tab = ValueNotifier<int>(0);

  /// Bumped whenever [draft] is replaced, so editors rebuild their fields.
  int draftRevision = 0;

  static Future<AppController> create() async {
    AnalysisRepository repo;
    try {
      repo = await createPlatformRepository();
    } catch (e) {
      debugPrint('Local storage unavailable, using in-memory storage: $e');
      repo = MemoryAnalysisRepository();
      storageUnavailable = true;
    }
    final c = AppController(repo);
    await c._load();
    return c;
  }

  /// Controller backed by in-memory storage (widget tests, previews).
  static Future<AppController> inMemory() async {
    final c = AppController(MemoryAnalysisRepository());
    await c._load();
    return c;
  }

  Future<void> _load() async {
    settings = await _repo.loadSettings() ?? AppSettings.defaults();
    history = await _repo.list();
    library = await _repo.listLibrary();
    draft = _freshDraft(Protocol.spi);
  }

  AnalysisConfig _freshDraft(Protocol p) {
    final c = AnalysisConfig.defaults(protocol: p, stackup: settings.defaultStackup);
    c.thresholds = settings.thresholds.copy();
    c.applyProtocolDefaults();
    // Protocol defaults may adjust thresholds (e.g. USB 2.0 +/-15 %).
    if (!_stackupIsPreset4(settings.defaultStackup)) applyTargetWidth(c);
    return c;
  }

  bool _stackupIsPreset4(StackupConfig s) =>
      s.toJson().toString() == StackupConfig.preset(4).toJson().toString();

  void newDraft([Protocol protocol = Protocol.spi]) {
    draft = _freshDraft(protocol);
    draftName = null;
    draftRevision++;
    notifyListeners();
  }

  /// Switches protocol while keeping the PCB stackup and length.
  void setProtocol(Protocol p) {
    if (draft.protocol == p) return;
    final stack = draft.pcb.stackup.copy();
    final fresh = _freshDraft(p);
    fresh.pcb.stackup = stack;
    applyTargetWidth(fresh);
    draft = fresh;
    draftRevision++;
    notifyListeners();
  }

  void loadIntoDraft(AnalysisRecord r) {
    draft = r.config.copy();
    draftName = r.name;
    draftRevision++;
    tab.value = 1;
    notifyListeners();
  }

  /// Notifies listeners after an in-place edit of [draft].
  void touch() => notifyListeners();

  String _autoName(AnalysisConfig c) {
    final when = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${when.year}-${two(when.month)}-${two(when.day)} ${two(when.hour)}:${two(when.minute)}';
    final detail = c.protocolShortDetail;
    return '${c.protocol.label} $detail · ${mm(c.pcb.traceLength)} · $stamp';
  }

  /// Runs the current draft in a background isolate and stores it in
  /// history. Throws [SimulationError] on invalid input.
  Future<({SimulationResult result, AnalysisRecord record})> runDraft() async {
    final cfg = draft.copy();
    final blocking = validateConfig(cfg).where((i) => i.blocking).toList();
    if (blocking.isNotEmpty) {
      throw SimulationError(blocking.map((i) => '• ${i.field}: ${i.message}').join('\n'));
    }
    running = true;
    notifyListeners();
    try {
      final result = await _simulate(cfg);
      final record = AnalysisRecord.fromResult(draftName ?? _autoName(cfg), result);
      await _repo.save(record);
      history = await _repo.list();
      return (result: result, record: record);
    } finally {
      running = false;
      notifyListeners();
    }
  }

  /// Regenerates the waveforms of a saved analysis (deterministic engine).
  Future<SimulationResult> rerun(AnalysisRecord r) =>
      _simulate(r.config);

  Future<void> rename(AnalysisRecord r, String name) async {
    r.name = name;
    r.updated = DateTime.now();
    await _repo.save(r);
    history = await _repo.list();
    notifyListeners();
  }

  Future<void> duplicate(AnalysisRecord r) async {
    final copy = AnalysisRecord.fromRow(r.toRow()..remove('id'));
    copy.name = '${r.name} (copy)';
    copy.created = DateTime.now();
    copy.updated = DateTime.now();
    await _repo.save(copy);
    history = await _repo.list();
    notifyListeners();
  }

  Future<void> delete(AnalysisRecord r) async {
    if (r.id != null) await _repo.delete(r.id!);
    history = await _repo.list();
    notifyListeners();
  }

  /// Built-in plus saved entries of [kind].
  List<LibraryItem> libraryOf(LibraryKind kind) => [
        ...builtInLibrary().where((i) => i.kind == kind),
        ...library.where((i) => i.kind == kind),
      ];

  Future<LibraryItem> saveToLibrary(LibraryKind kind, String name, Map<String, Object?> data) async {
    final item = await _repo.saveLibrary(LibraryItem(kind: kind, name: name, data: data));
    library = await _repo.listLibrary();
    notifyListeners();
    return item;
  }

  Future<void> renameLibrary(LibraryItem item, String name) async {
    item.name = name;
    await _repo.saveLibrary(item);
    library = await _repo.listLibrary();
    notifyListeners();
  }

  Future<void> deleteLibrary(LibraryItem item) async {
    if (item.id != null) await _repo.deleteLibrary(item.id!);
    library = await _repo.listLibrary();
    notifyListeners();
  }

  /// Runs any configuration in a background isolate (comparisons, sweeps).
  Future<SimulationResult> runConfig(AnalysisConfig cfg) => _simulate(cfg);

  /// Runs the engine in a background isolate. Browsers have no isolates, so on
  /// the web the UI first gets two frames to show its progress state before
  /// the (usually sub-second) simulation runs on the main thread.
  static Future<SimulationResult> _simulate(AnalysisConfig cfg) async {
    if (kIsWeb) await Future<void>.delayed(const Duration(milliseconds: 40));
    return compute(runAnalysisFromJson, cfg.toJson());
  }

  /// Replaces the draft (e.g. a comparison variant opened for editing).
  void setDraft(AnalysisConfig cfg, {String? name}) {
    draft = cfg.copy();
    draftName = name;
    draftRevision++;
    tab.value = 1;
    notifyListeners();
  }

  Future<void> updateSettings(AppSettings s) async {
    settings = s.copy();
    await _repo.saveSettings(settings);
    notifyListeners();
  }
}
