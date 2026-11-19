import 'dart:async';
import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../remote/codex/codex_client.dart';
import '../../../state/connection_state.dart';
import '../../common/app_sheet.dart';
import '../../common/sheet_title_bar.dart';

final _codexUsageProvider = FutureProvider.autoDispose<CodexUsage>((ref) {
  final connection = ref.watch(activeConnectionProvider).asData?.value;
  if (connection == null || connection.isLocal) throw const DshProtocolException('No Codex Remote Host');
  final refresh = Timer(const Duration(minutes: 2), ref.invalidateSelf);
  ref.onDispose(refresh.cancel);
  return CodexClient(connection.client.carrier).readUsage();
});

class CodexUsageRing extends ConsumerWidget {
  const CodexUsageRing({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(_codexUsageProvider).value;
    double? used(int minutes) => usage?.windows
        .where((window) => window.bucketId == 'codex' && window.durationMinutes == minutes)
        .firstOrNull
        ?.usedPercent;
    final colors = Theme.of(context).colorScheme;
    final label = context.l10n.featuresCodexUsage;
    return IconButton(
      tooltip: label,
      onPressed: () {
        ref.invalidate(_codexUsageProvider);
        unawaited(showAppSheet<void>(context, isScrollControlled: true, builder: (_) => const _CodexUsageSheet()));
      },
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 40, height: 44),
      icon: CustomPaint(
        size: const Size.square(24),
        painter: _QuotaRingPainter(
          top: used(300),
          bottom: used(10080),
          color: colors.primary,
          track: colors.outlineVariant,
        ),
      ),
    );
  }
}

class _QuotaRingPainter extends CustomPainter {
  const _QuotaRingPainter({required this.top, required this.bottom, required this.color, required this.track});

  final double? top, bottom;
  final Color color, track;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 2.5;
    const gap = .20;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    const sweep = math.pi - 2 * gap;
    for (final (start, direction, percent) in [(math.pi + gap, 1.0, top), (math.pi - gap, -1.0, bottom)]) {
      canvas.drawArc(rect, start, direction * sweep, false, paint..color = track);
      if (percent != null && percent > 0) {
        canvas.drawArc(rect, start, direction * sweep * percent / 100, false, paint..color = color);
      }
    }
  }

  @override
  bool shouldRepaint(_QuotaRingPainter old) =>
      top != old.top || bottom != old.bottom || color != old.color || track != old.track;
}

class _CodexUsageSheet extends ConsumerWidget {
  const _CodexUsageSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final usage = ref.watch(_codexUsageProvider);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(l10n.featuresCodexUsage),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              child: switch (usage) {
                AsyncLoading() => const Center(
                  child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()),
                ),
                AsyncError(:final error) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      error is DshRemoteException && error.code == 'METHOD_NOT_ALLOWED'
                          ? l10n.featuresCodexUsageHostUpdate
                          : l10n.commonFailedTryAgain,
                    ),
                    TextButton(onPressed: () => ref.invalidate(_codexUsageProvider), child: Text(l10n.commonRetry)),
                  ],
                ),
                AsyncData(:final value) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (value.plan case final plan?)
                      Text(
                        plan.toLowerCase() == 'plus' ? 'ChatGPT Plus' : plan,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    if (value.windows.isEmpty) Text(l10n.featuresCodexUsageUnavailable),
                    for (final window in value.windows) _UsageWindow(window),
                  ],
                ),
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _UsageWindow extends StatelessWidget {
  const _UsageWindow(this.window);

  final CodexUsageWindow window;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final material = MaterialLocalizations.of(context);
    final minutes = window.durationMinutes ?? 0;
    final duration = switch (minutes) {
      <= 0 => l10n.featuresCodexUsageWindow,
      _ when minutes % 1440 == 0 => l10n.featuresCodexUsageDays('${minutes ~/ 1440}'),
      _ when minutes % 60 == 0 => l10n.featuresCodexUsageHours('${minutes ~/ 60}'),
      _ => l10n.featuresCodexUsageMinutes('$minutes'),
    };
    final remaining = l10n.featuresCodexUsageRemaining('${(100 - window.usedPercent).round()}');
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${window.name} · $duration', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Wrap(
            spacing: 12,
            runSpacing: 2,
            children: [
              Text(remaining),
              if (window.resetsAt case final time?)
                Text(
                  l10n.featuresCodexUsageReset(
                    '${material.formatCompactDate(time)} ${material.formatTimeOfDay(TimeOfDay.fromDateTime(time))}',
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
