import 'package:flutter/material.dart';

import '../../core/state/app_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/analysis_record.dart';
import '../../simulation/engine.dart';
import '../../shared/export/export_service.dart';
import '../../shared/widgets/common.dart';
import '../analysis_results/results_screen.dart';
import '../compare/compare_screen.dart';
import '../library/library_screen.dart';

String formatDate(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

/// Opens a saved analysis: the engine is deterministic, so the waveforms are
/// regenerated from the stored configuration.
Future<void> openRecord(BuildContext context, AppController c, AnalysisRecord r) async {
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );
  try {
    final result = await c.rerun(r);
    nav.pop();
    await nav.push(MaterialPageRoute<void>(builder: (_) => ResultsScreen(controller: c, result: result, record: r)));
  } catch (e) {
    nav.pop();
    messenger.showSnackBar(SnackBar(content: Text('Could not open analysis: $e')));
  }
}

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _selected = <int>{};
  bool get _selecting => _selected.isNotEmpty;
  String _query = '';
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Protocol? _protocol;
  SiStatus? _status;

  List<AnalysisRecord> _filter(List<AnalysisRecord> all) => all
      .where((r) =>
          (_protocol == null || r.protocol == _protocol) &&
          (_status == null || r.status == _status) &&
          (_query.isEmpty || r.name.toLowerCase().contains(_query.toLowerCase())))
      .toList();

  Widget _filters(int total, int shown) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          decoration: InputDecoration(
            hintText: 'Search analyses',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () => setState(() {
                      _search.clear();
                      _query = '';
                    }),
                  ),
          ),
          controller: _search,
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final p in Protocol.values)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: FilterChip(
                  label: Text(p.label),
                  selected: _protocol == p,
                  onSelected: (v) => setState(() => _protocol = v ? p : null),
                ),
              ),
            const SizedBox(width: 6),
            for (final st in [SiStatus.critical, SiStatus.warning, SiStatus.good])
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: FilterChip(
                  avatar: Icon(Icons.circle, size: 10, color: AppColors.status(st)),
                  label: Text(st.label),
                  selected: _status == st,
                  onSelected: (v) => setState(() => _status = v ? st : null),
                ),
              ),
          ]),
        ),
        if (shown != total)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Showing $shown of $total', style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
          ),
      ]),
    );
  }

  void _toggle(AnalysisRecord r) {
    final id = r.id;
    if (id == null) return;
    setState(() => _selected.contains(id) ? _selected.remove(id) : _selected.add(id));
  }

  void _compare() {
    final c = widget.controller;
    final recs = c.history.where((r) => _selected.contains(r.id)).toList();
    if (recs.length < 2) return;
    setState(_selected.clear);
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => CompareScreen(controller: c, cases: [for (final r in recs) CompareCase(r.name, r.config.copy())]),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final all = controller.history;
        final items = _filter(all);
        _selected.removeWhere((id) => !items.any((r) => r.id == id));
        return Scaffold(
          appBar: AppBar(
            leading: _selecting
                ? IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_selected.clear))
                : null,
            title: Text(_selecting ? '${_selected.length} selected' : 'History'),
            actions: [
              if (_selecting)
                TextButton.icon(
                  onPressed: _selected.length >= 2 && _selected.length <= 8 ? _compare : null,
                  icon: const Icon(Icons.compare_arrows),
                  label: const Text('Compare'),
                )
              else
                IconButton(
                  tooltip: 'Libraries (stackups, drivers, IBIS, S-parameters)',
                  icon: const Icon(Icons.library_books_outlined),
                  onPressed: () => Navigator.of(context)
                      .push(MaterialPageRoute<void>(builder: (_) => LibraryScreen(controller: controller))),
                ),
            ],
          ),
          body: all.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No saved analyses yet.\nEvery generated analysis is saved here automatically.',
                        textAlign: TextAlign.center, style: TextStyle(color: AppColors.textDim)),
                  ),
                )
              : Column(children: [
                  if (all.length > 3) _filters(all.length, items.length),
                  if (!_selecting && items.length >= 2)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Text('Long-press analyses to select 2–8 of them for a side-by-side comparison.',
                          style: TextStyle(color: AppColors.textDim, fontSize: 12)),
                    ),
                  if (items.isEmpty)
                    const Expanded(
                      child: Center(
                          child: Text('No analyses match the filters.', style: TextStyle(color: AppColors.textDim))),
                    )
                  else
                    Expanded(
                      child: ListView.builder(
                        itemCount: items.length,
                        itemBuilder: (context, i) => RecordTile(
                          controller: controller,
                          record: items[i],
                          selected: _selected.contains(items[i].id),
                          onLongPress: () => _toggle(items[i]),
                          onTapOverride: _selecting ? () => _toggle(items[i]) : null,
                        ),
                      ),
                    ),
                ]),
        );
      },
    );
  }
}

class RecordTile extends StatelessWidget {
  const RecordTile({
    super.key,
    required this.controller,
    required this.record,
    this.compact = false,
    this.selected = false,
    this.onLongPress,
    this.onTapOverride,
  });
  final AppController controller;
  final AnalysisRecord record;
  final bool compact;
  final bool selected;
  final VoidCallback? onLongPress;
  final VoidCallback? onTapOverride;

  Future<void> _rename(BuildContext context) async {
    final ctrl = TextEditingController(text: record.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename analysis'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    ctrl.dispose();
    if (name != null && name.isNotEmpty) await controller.rename(record, name);
  }

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete analysis?'),
        content: Text(record.name),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.critical),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await controller.delete(record);
  }

  @override
  Widget build(BuildContext context) {
    final crit = record.findings.where((f) => f.status == SiStatus.critical).length;
    final warn = record.findings.where((f) => f.status == SiStatus.warning).length;
    return Card(
      color: selected ? AppColors.accent.withValues(alpha: 0.16) : null,
      child: ListTile(
        onTap: onTapOverride ?? () => openRecord(context, controller, record),
        onLongPress: onLongPress,
        leading: CircleAvatar(
          backgroundColor: AppColors.status(record.status).withValues(alpha: 0.18),
          child: Text(
            record.protocol.tag,
            style: TextStyle(
                color: AppColors.status(record.status),
                fontSize: record.protocol.tag.length > 4 ? 9.5 : 11,
                fontWeight: FontWeight.w700),
          ),
        ),
        title: Text(record.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
        subtitle: Text(
          '${formatDate(record.updated)} · $crit critical · $warn warning · ${record.modelVersion}',
          style: const TextStyle(fontSize: 11.5, color: AppColors.textDim),
        ),
        trailing: compact
            ? StatusChip(record.status, dense: true)
            : PopupMenuButton<String>(
                onSelected: (v) async {
                  switch (v) {
                    case 'open':
                      await openRecord(context, controller, record);
                    case 'edit':
                      controller.loadIntoDraft(record);
                    case 'rename':
                      await _rename(context);
                    case 'dup':
                      await controller.duplicate(record);
                    case 'json':
                      try {
                        await ExportService.shareJson(record);
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $e')));
                        }
                      }
                    case 'del':
                      await _delete(context);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'open', child: Text('Open results')),
                  PopupMenuItem(value: 'edit', child: Text('Load into New Analysis')),
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'dup', child: Text('Duplicate')),
                  PopupMenuItem(value: 'json', child: Text('Export JSON')),
                  PopupMenuItem(value: 'del', child: Text('Delete')),
                ],
              ),
      ),
    );
  }
}
