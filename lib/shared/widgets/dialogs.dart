import 'package:flutter/material.dart';

import '../../core/state/app_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/library_item.dart';

/// Asks for a name; returns null when cancelled.
Future<String?> askName(BuildContext context, {required String title, String initial = '', String label = 'Name'}) async {
  final ctrl = TextEditingController(text: initial);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: ctrl, autofocus: true, decoration: InputDecoration(labelText: label)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('OK')),
      ],
    ),
  );
  ctrl.dispose();
  return name == null || name.isEmpty ? null : name;
}

/// Bottom sheet listing library entries of [kind]; returns the chosen one.
Future<LibraryItem?> pickLibraryItem(BuildContext context, AppController c, LibraryKind kind,
    {bool Function(LibraryItem)? filter}) {
  final items = c.libraryOf(kind).where((i) => filter?.call(i) ?? true).toList();
  return showModalBottomSheet<LibraryItem>(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(kind.label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          ),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Nothing saved yet.', style: TextStyle(color: AppColors.textDim)),
            ),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final i in items)
                ListTile(
                  leading: Icon(i.builtIn ? Icons.lock_outline : Icons.bookmark_outline, size: 20),
                  title: Text(i.name),
                  subtitle: Text(i.subtitle, style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
                  onTap: () => Navigator.pop(ctx, i),
                ),
            ]),
          ),
        ]),
      ),
    ),
  );
}
