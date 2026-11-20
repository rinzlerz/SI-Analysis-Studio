import 'package:flutter/material.dart';

import '../../core/state/app_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../simulation/engine.dart';
import '../../shared/widgets/common.dart';
import '../../core/app_info.dart';
import '../../shared/share_actions.dart';
import '../about/about_screen.dart';
import '../history/history_screen.dart';
import 'examples.dart';
import '../integration/integration_dialogs.dart';
import '../library/library_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final recent = controller.history.take(5).toList();
        return Scaffold(
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 8, 8),
                  child: Row(children: [
                    const SiLogo(size: 44),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('SI Studio', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, letterSpacing: 0.3)),
                        Text('Quick signal-integrity analysis for PCB layout',
                            style: TextStyle(color: AppColors.textDim, fontSize: 13)),
                      ]),
                    ),
                    if (feedbackUrl.isNotEmpty)
                      IconButton(
                        tooltip: 'Send feedback',
                        icon: const Icon(Icons.feedback_outlined),
                        onPressed: () => sendFeedback(context),
                      ),
                    IconButton(
                      tooltip: 'About, limitations and privacy',
                      icon: const Icon(Icons.info_outline),
                      onPressed: () =>
                          Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AboutScreen())),
                    ),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: SizedBox(
                    height: 54,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: Colors.black,
                        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                      icon: const Icon(Icons.add_chart),
                      label: const Text('New Analysis'),
                      onPressed: () {
                        controller.newDraft(controller.draft.protocol);
                        controller.tab.value = 1;
                      },
                    ),
                  ),
                ),
                const _Heading('Supported protocols'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final p in Protocol.values) _ProtocolCard(protocol: p, controller: controller),
                  ]),
                ),
                if (controller.history.isEmpty)
                  Card(
                    color: AppColors.accent.withValues(alpha: 0.08),
                    child: const ListTile(
                      leading: Icon(Icons.waving_hand_outlined, color: AppColors.accent),
                      title: Text('New here?'),
                      subtitle: Text('Tap an example below to see a full analysis in one step, or start a New Analysis '
                          'with your own layout values.'),
                    ),
                  ),
                const _Heading('Try an example'),
                SizedBox(
                  height: 132,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (final e in exampleAnalyses)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: SizedBox(
                            width: 220,
                            child: Material(
                              color: AppColors.surface,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                                side: const BorderSide(color: AppColors.outline),
                              ),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(10),
                                onTap: controller.running ? null : () => runExample(context, controller, e),
                                child: Padding(
                                  padding: const EdgeInsets.all(10),
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Row(children: [
                                      Icon(e.icon, color: AppColors.accent, size: 20),
                                      const SizedBox(width: 6),
                                      Text(e.protocol.tag,
                                          style: const TextStyle(color: AppColors.textDim, fontSize: 11, fontWeight: FontWeight.w700)),
                                    ]),
                                    const SizedBox(height: 6),
                                    Text(e.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                                    const SizedBox(height: 2),
                                    Expanded(
                                      child: Text(e.description,
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(color: AppColors.textDim, fontSize: 11.5)),
                                    ),
                                  ]),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const _Heading('Tools'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    _ToolTile(
                      icon: Icons.developer_board,
                      title: 'Import from KiCad',
                      desc: 'Take stackup, length & vias from a .kicad_pcb',
                      onTap: () async {
                        controller.tab.value = 1;
                        await importFromKicad(context, controller);
                      },
                    ),
                    _ToolTile(
                      icon: Icons.stacked_line_chart,
                      title: 'Parameter sweep',
                      desc: 'Vary one input of the current analysis',
                      onTap: () => startSweep(context, controller),
                    ),
                    _ToolTile(
                      icon: Icons.compare_arrows,
                      title: 'Compare analyses',
                      desc: 'Long-press 2–8 entries in History',
                      onTap: () => controller.tab.value = 2,
                    ),
                    _ToolTile(
                      icon: Icons.library_books_outlined,
                      title: 'Libraries',
                      desc: 'Stackups, drivers, IBIS, S-parameters',
                      onTap: () => Navigator.of(context)
                          .push(MaterialPageRoute<void>(builder: (_) => LibraryScreen(controller: controller))),
                    ),
                  ]),
                ),
                const _Heading('Recent analyses'),
                if (recent.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text('Run your first analysis to see it here.', style: TextStyle(color: AppColors.textDim)),
                  )
                else
                  for (final r in recent) RecordTile(controller: controller, record: r, compact: true),
                if (controller.history.length > 5)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => controller.tab.value = 2,
                      child: const Text('All analyses →'),
                    ),
                  ),
                const _Heading('Modelling levels'),
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Row(children: [LevelBadge(ModelLevel.analytical), SizedBox(width: 8), Expanded(child: Text('Impedance, delay, reflection coefficients, loss estimates'))]),
                      SizedBox(height: 6),
                      Row(children: [LevelBadge(ModelLevel.behavioral), SizedBox(width: 8), Expanded(child: Text('Time-domain lines: reflections, ringing, overshoot, loss, timing, eye'))]),
                      SizedBox(height: 6),
                      Row(children: [LevelBadge(ModelLevel.advanced), SizedBox(width: 8), Expanded(child: Text('IBIS buffers, S-parameter channels, crosstalk, vias/AC caps/connectors, eye mask & bathtub'))]),
                      SizedBox(height: 8),
                      Text('Preliminary analysis only – no protocol-compliance claims. Runs fully offline.',
                          style: TextStyle(color: AppColors.textDim, fontSize: 12)),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
        child: Text(text.toUpperCase(),
            style: const TextStyle(color: AppColors.textDim, fontSize: 12, letterSpacing: 1.2, fontWeight: FontWeight.w600)),
      );
}

class _ProtocolCard extends StatelessWidget {
  const _ProtocolCard({required this.protocol, required this.controller});
  final Protocol protocol;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final ok = protocol.supported;
    final desc = protocol.description;
    return SizedBox(
      width: 168,
      child: Material(
        color: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: ok ? AppColors.accent.withValues(alpha: 0.5) : AppColors.outline),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: ok
              ? () {
                  controller.newDraft(protocol);
                  controller.tab.value = 1;
                }
              : null,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(protocol.label,
                  style: TextStyle(fontWeight: FontWeight.w700, color: ok ? AppColors.text : AppColors.textDim)),
              const SizedBox(height: 4),
              Text(desc, style: const TextStyle(color: AppColors.textDim, fontSize: 11.5)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({required this.icon, required this.title, required this.desc, required this.onTap});
  final IconData icon;
  final String title;
  final String desc;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 168,
      child: Material(
        color: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: AppColors.outline),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon, color: AppColors.accent, size: 22),
              const SizedBox(height: 6),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(desc, style: const TextStyle(color: AppColors.textDim, fontSize: 11.5)),
            ]),
          ),
        ),
      ),
    );
  }
}
