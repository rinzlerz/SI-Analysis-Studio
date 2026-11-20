import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../core/app_info.dart';
import '../../core/state/app_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../platform/external_link.dart';
import '../../platform/simulate.dart' show simulationRunner;
import '../../shared/share_actions.dart';
import '../../platform/storage.dart' show storageDescription;
import '../../simulation/engine.dart';
import '../../shared/widgets/common.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Widget bullet(String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(padding: EdgeInsets.only(top: 6), child: Icon(Icons.circle, size: 6, color: AppColors.accent)),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 13.5))),
          ]),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Row(children: [
                SiLogo(size: 44),
                SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(appName, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
                    Text('Version $appVersion · model $simulationModelVersion',
                        style: TextStyle(color: AppColors.textDim, fontSize: 13)),
                    Text(repoUrl, style: TextStyle(color: AppColors.textDim, fontSize: 11.5)),
                  ]),
                ),
              ]),
            ),
            SectionCard(
              title: 'What it does',
              leading: const Icon(Icons.bolt),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('Enter the routing and buffer parameters of an interface as you lay it out, and SI Studio '
                    'simulates the waveforms and tells you whether the signal integrity is good, marginal or failing – '
                    'with the reason and a concrete fix.'),
                const SizedBox(height: 8),
                bullet('Protocols: ${Protocol.values.map((p) => p.label).join(', ')}.'),
                bullet('Impedance from the stackup (microstrip, stripline, coupled pairs), lossy transmission lines, '
                    'terminations, vias, AC caps, connectors and crosstalk.'),
                bullet('Time-domain waveforms, eye diagrams with equalisation, timing slack and protocol-style checks.'),
                bullet('IBIS and Touchstone import, KiCad board import, design-rule export, parameter sweeps.'),
              ]),
            ),
            SectionCard(
              title: 'Limitations – please read',
              leading: const Icon(Icons.warning_amber_rounded, color: AppColors.warning),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                bullet('Preliminary engineering analysis. Results are NOT protocol compliance and do not guarantee '
                    'that a PCB will work.'),
                bullet('Models are simplified (closed-form impedance, behavioural buffers, 2-D lines). Confirm critical '
                    'interfaces with full-wave / vendor-model simulation and measurement.'),
                bullet('Every result lists its assumptions; check them before relying on a number.'),
              ]),
            ),
            SectionCard(
              title: 'Your data',
              leading: const Icon(Icons.lock_outline),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('Analyses, settings and libraries are stored $storageDescription.'),
                if (AppController.storageUnavailable)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text('Storage is unavailable here (for example private browsing): this session is not saved.',
                        style: TextStyle(color: AppColors.warning)),
                  ),
                const SizedBox(height: 6),
                Text('Simulations run in a $simulationRunner.', style: const TextStyle(color: AppColors.textDim, fontSize: 12.5)),
                const SizedBox(height: 4),
                const Text('Use Share link or Export (JSON) on a result, or Libraries → export, to move data between devices.',
                    style: TextStyle(color: AppColors.textDim, fontSize: 12.5)),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                if (feedbackUrl.isNotEmpty)
                  FilledButton.icon(
                    onPressed: () => sendFeedback(context),
                    icon: const Icon(Icons.feedback_outlined),
                    label: const Text('Send feedback'),
                  ),
                OutlinedButton.icon(
                  onPressed: () => openExternal(kIsWeb ? releasesUrl : webAppUrl),
                  icon: const Icon(kIsWeb ? Icons.android : Icons.public),
                  label: const Text(kIsWeb ? 'Get the Android app' : 'Open the web version'),
                ),
                OutlinedButton.icon(
                  onPressed: () => showLicensePage(
                    context: context,
                    applicationName: appName,
                    applicationVersion: appVersion,
                    applicationIcon: const Padding(padding: EdgeInsets.all(8), child: SiLogo(size: 32)),
                  ),
                  icon: const Icon(Icons.article_outlined),
                  label: const Text('Open-source licences'),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
