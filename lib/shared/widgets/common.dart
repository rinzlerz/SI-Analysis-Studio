import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../simulation/model/result.dart';

/// Collapsible card section used throughout the configuration and results.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.leading,
    this.initiallyExpanded = true,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget child;
  final bool initiallyExpanded;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          maintainState: true,
          leading: leading,
          trailing: trailing,
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.2)),
          subtitle: subtitle == null
              ? null
              : Text(subtitle!, style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          children: [child],
        ),
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key, this.dense = false});
  final SiStatus status;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.status(status);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 10, vertical: dense ? 2 : 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.withValues(alpha: 0.6)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(
          switch (status) {
            SiStatus.good => Icons.check_circle,
            SiStatus.warning => Icons.warning_amber_rounded,
            SiStatus.critical => Icons.error,
            SiStatus.info => Icons.info_outline,
          },
          size: dense ? 12 : 15,
          color: c,
        ),
        const SizedBox(width: 4),
        Text(status.label,
            style: TextStyle(color: c, fontSize: dense ? 11 : 13, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

class LevelBadge extends StatelessWidget {
  const LevelBadge(this.level, {super.key});
  final ModelLevel level;

  @override
  Widget build(BuildContext context) {
    final c = switch (level) {
      ModelLevel.analytical => AppColors.traces[3],
      ModelLevel.behavioral => AppColors.traces[2],
      ModelLevel.advanced => AppColors.traces[4],
    };
    return Tooltip(
      message: switch (level) {
        ModelLevel.analytical => 'Level 1 – analytical closed-form calculation',
        ModelLevel.behavioral => 'Level 2 – behavioural time-domain simulation',
        ModelLevel.advanced => 'Level 3 – advanced models (IBIS, S-parameters, crosstalk, vias, mask/BER)',
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: c.withValues(alpha: 0.7)),
        ),
        child: Text(level.short, style: TextStyle(color: c, fontSize: 10, fontWeight: FontWeight.w700)),
      ),
    );
  }
}

/// Small key/value row for summaries.
class KeyValue extends StatelessWidget {
  const KeyValue(this.k, this.v, {super.key});
  final String k;
  final String v;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(flex: 5, child: Text(k, style: const TextStyle(color: AppColors.textDim, fontSize: 13))),
        Expanded(flex: 6, child: Text(v, style: kNumStyle.copyWith(fontSize: 13))),
      ]),
    );
  }
}

/// SI Studio logo glyph (a ringing edge).
class SiLogo extends StatelessWidget {
  const SiLogo({super.key, this.size = 40});
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size(size * 1.6, size), painter: _LogoPainter());
}

class _LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final r = RRect.fromRectAndRadius(Offset.zero & s, Radius.circular(s.height * 0.18));
    canvas.drawRRect(r, Paint()..color = AppColors.surfaceHigh);
    canvas.drawRRect(
        r,
        Paint()
          ..color = AppColors.outline
          ..style = PaintingStyle.stroke);
    final h = s.height;
    final w = s.width;
    final path = Path()
      ..moveTo(w * 0.08, h * 0.75)
      ..lineTo(w * 0.30, h * 0.75)
      ..lineTo(w * 0.36, h * 0.18);
    // Damped ringing around the high level.
    for (var i = 1; i <= 48; i++) {
      final t = i / 48;
      final y = 0.3 - 0.12 * math.exp(-4 * t) * math.cos(6 * math.pi * t);
      path.lineTo(w * (0.36 + 0.56 * t), h * y);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = AppColors.traces[0]
          ..style = PaintingStyle.stroke
          ..strokeWidth = h * 0.06
          ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
