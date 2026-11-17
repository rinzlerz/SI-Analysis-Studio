import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/state/app_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/library_item.dart';
import '../../shared/export/export_service.dart';
import '../../shared/files/file_loader.dart';
import '../../shared/widgets/dialogs.dart';
import '../../simulation/engine.dart';
import '../../simulation/ibis/ibis.dart';
import '../../simulation/sparams/touchstone.dart';

/// Reusable libraries (PRD Phase 4): stackups, driver/receiver presets,
/// IBIS models and S-parameter channels.
class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: LibraryKind.values.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Libraries'),
          actions: [
            IconButton(
              tooltip: 'Import library entry (.json)',
              icon: const Icon(Icons.file_open_outlined),
              onPressed: () => _import(context),
            ),
          ],
          bottom: TabBar(
            isScrollable: true,
            tabs: [for (final k in LibraryKind.values) Tab(text: k.label)],
          ),
        ),
        body: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => TabBarView(children: [
            for (final k in LibraryKind.values) _KindList(controller: controller, kind: k),
          ]),
        ),
      ),
    );
  }

  Future<void> _import(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final f = await pickTextFile(['json']);
      if (f == null) return;
      final item = LibraryItem.fromExportJson((jsonDecode(f.text) as Map).cast<String, Object?>());
      if (item == null) throw const FormatException('Not an SI Studio library file.');
      await controller.saveToLibrary(item.kind, item.name, item.data);
      messenger.showSnackBar(SnackBar(content: Text('Imported "${item.name}" into ${item.kind.label}.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }
}

class _KindList extends StatelessWidget {
  const _KindList({required this.controller, required this.kind});
  final AppController controller;
  final LibraryKind kind;

  String _hint() => switch (kind) {
        LibraryKind.stackup => 'Save stackups from the New Analysis stackup editor ("Save to library").',
        LibraryKind.driver => 'Save driver/receiver settings from New Analysis section D ("Save preset").',
        LibraryKind.ibis => 'Load an .ibs file here or save the selected IBIS models from section D.',
        LibraryKind.sparam => 'Load a .s2p/.s4p file here or save the loaded channel from section B.',
      };

  Future<void> _use(BuildContext context, LibraryItem i) async {
    final c = controller;
    final d = c.draft;
    String msg;
    switch (i.kind) {
      case LibraryKind.stackup:
        d.pcb.stackup = StackupConfig.fromJson(i.data);
        msg = 'Stackup "${i.name}" applied to the current analysis.';
      case LibraryKind.driver:
        msg = applyDriverPreset(d, i.data)
            ? 'Preset "${i.name}" applied.'
            : 'This preset is for another protocol (${i.subtitle}).';
      case LibraryKind.ibis:
        final m = IbisModel.fromJson(i.data);
        if (!d.protocol.spiFamily || m == null) {
          msg = 'IBIS models are used by SPI and QSPI analyses.';
        } else {
          final sp = d.spiCfg;
          if (m.canDrive) {
            sp.ibisDriver = m;
          } else {
            sp.ibisReceiver = m;
          }
          sp.ibisReceiver ??= m;
          sp.useIbis = true;
          msg = 'IBIS model "${m.name}" set as ${m.canDrive ? 'driver' : 'receiver'}.';
        }
      case LibraryKind.sparam:
        final s = ChannelSParams.fromJson(i.data);
        if (!d.protocol.serdes || s == null) {
          msg = 'S-parameter channels are used by USB 3.0 / PCIe analyses.';
        } else {
          d.serdes.sparams = s;
          d.serdes.useTouchstone = true;
          msg = 'Channel "${s.name}" applied.';
        }
    }
    c.draftRevision++;
    c.touch();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _addFile(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (kind == LibraryKind.ibis) {
        final f = await pickTextFile(['ibs']);
        if (f == null) return;
        final models = parseIbis(f.text, file: f.name);
        for (final m in models) {
          await controller.saveToLibrary(LibraryKind.ibis, '${m.name} (${f.name})', m.toJson());
        }
        messenger.showSnackBar(SnackBar(content: Text('Saved ${models.length} model(s) from ${f.name}.')));
      } else if (kind == LibraryKind.sparam) {
        final f = await pickTextFile(['s2p', 's4p']);
        if (f == null) return;
        final sp = parseTouchstone(f.text, ports: f.name.toLowerCase().endsWith('.s4p') ? 4 : 2, name: f.name);
        await controller.saveToLibrary(LibraryKind.sparam, f.name, sp.toJson());
        messenger.showSnackBar(SnackBar(content: Text('Saved ${f.name}.')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not load: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = controller.libraryOf(kind);
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(_hint(), style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
      ),
      if (kind == LibraryKind.ibis || kind == LibraryKind.sparam)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _addFile(context),
              icon: const Icon(Icons.upload_file),
              label: Text(kind == LibraryKind.ibis ? 'Add .ibs file' : 'Add .s2p / .s4p file'),
            ),
          ),
        ),
      for (final i in items)
        Card(
          child: ListTile(
            leading: Icon(i.builtIn ? Icons.lock_outline : Icons.bookmark_outline),
            title: Text(i.name),
            subtitle: Text(i.subtitle, style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
            onTap: () => _use(context, i),
            trailing: PopupMenuButton<String>(
              onSelected: (v) async {
                switch (v) {
                  case 'use':
                    await _use(context, i);
                  case 'rename':
                    final n = await askName(context, title: 'Rename', initial: i.name);
                    if (n != null) await controller.renameLibrary(i, n);
                  case 'copy':
                    await controller.saveToLibrary(i.kind, '${i.name} (copy)', Map.of(i.data));
                  case 'export':
                    await ExportService.shareText('${i.name}.json',
                        const JsonEncoder.withIndent('  ').convert(i.toExportJson()), 'application/json');
                  case 'delete':
                    await controller.deleteLibrary(i);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'use', child: Text('Use in current analysis')),
                if (!i.builtIn) const PopupMenuItem(value: 'rename', child: Text('Rename')),
                const PopupMenuItem(value: 'copy', child: Text('Save a copy')),
                const PopupMenuItem(value: 'export', child: Text('Export (.json)')),
                if (!i.builtIn) const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ),
        ),
    ]);
  }
}
