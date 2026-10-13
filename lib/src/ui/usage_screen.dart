import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/stats.dart';
// Flutter has its own ConnectionState (from async.dart); this screen only needs
// providers from our state layer.
import '../state/providers.dart' hide ConnectionState;
import 'widgets.dart';

/// What this server has been doing: tokens, steps, days active and cost.
///
/// This is the server's own accounting. It is deliberately not called "account
/// usage": the opencode.ai Console API exposes no usage, credit or invoice
/// endpoint for a signed-in user, so anything about the account balance lives
/// in the web console only. What is here is real consumption, measured by the
/// machine that ran the sessions.
class UsageScreen extends ConsumerWidget {
  const UsageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(usageProvider);
    final range = ref.watch(usageRangeProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Usage'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => ref.invalidate(usageProvider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: Row(
              children: [
                for (final option in StatsRange.values) ...[
                  ChoiceChip(
                    label: Text(option.label),
                    selected: range == option,
                    onSelected: (_) => ref
                        .read(usageRangeProvider.notifier)
                        .select(option),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: stats.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (error, _) => EmptyState(
                icon: Icons.cloud_off,
                title: 'Cannot load usage',
                message: '$error',
                action: FilledButton.tonal(
                  onPressed: () => ref.invalidate(usageProvider),
                  child: const Text('Retry'),
                ),
              ),
              data: (data) {
                if (data.isEmpty) {
                  return const EmptyState(
                    icon: Icons.insights_outlined,
                    title: 'Nothing in this period',
                    message: 'No sessions ran here yet.',
                  );
                }
                return _Body(stats: data);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.stats});

  final ServerStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        _Headline(stats: stats),
        const SizedBox(height: 20),
        Text('Tokens', style: theme.textTheme.titleSmall),
        const SizedBox(height: 10),
        _TokenBars(tokens: stats.tokens),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: _Stat(
                label: 'Sessions',
                value: '${stats.sessions}',
                hint: stats.subagents > 0
                    ? '${stats.subagents} subagent runs'
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _Stat(
                label: 'Prompts',
                value: '${stats.prompts}',
                hint: '${stats.steps} steps',
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _Stat(
                label: 'Active days',
                value: '${stats.activeDays}',
                hint: stats.streak > 1 ? '${stats.streak}-day streak' : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _Stat(
                label: 'Cost',
                value: formatCost(stats.cost),
                hint: 'billed by the server',
              ),
            ),
          ],
        ),
        if (stats.activity.isNotEmpty) ...[
          const SizedBox(height: 28),
          Text('Activity', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Steps per day, newest at the right.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          _ActivityChart(days: stats.activity),
        ],
        if (stats.models.isNotEmpty) ...[
          const SizedBox(height: 28),
          Text('Models', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Ranked by steps run.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          ...stats.modelsByWeight.map((m) => _ModelUsageRow(usage: m)),
        ],
        if (stats.tools.isNotEmpty) ...[
          const SizedBox(height: 28),
          Text('Tools', style: theme.textTheme.titleSmall),
          const SizedBox(height: 12),
          ...stats.tools.map((t) => _ToolRow(usage: t)),
        ],
        const SizedBox(height: 24),
        Text(
          'Measured by this server, over ${_window(stats)}. Account balance and '
          'invoices are only available in the opencode.ai web console.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  String _window(ServerStats stats) {
    if (stats.from <= 0 || stats.to <= 0) return 'all recorded history';
    final start = DateTime.fromMillisecondsSinceEpoch(stats.from);
    final end = DateTime.fromMillisecondsSinceEpoch(stats.to);
    return '${start.day}/${start.month} - ${end.day}/${end.month}';
  }
}

class _Headline extends StatelessWidget {
  const _Headline({required this.stats});

  final ServerStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              formatTokens(stats.tokens.total),
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'tokens processed',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              formatCost(stats.cost),
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'spent on models',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Token counts as one stacked bar: cached reads dominate the total, so showing
/// them as a separate segment keeps the generated part readable.
class _TokenBars extends StatelessWidget {
  const _TokenBars({required this.tokens});

  final TokenBreakdown tokens;

  static const _cache = Color(0xFF6B7A99);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = tokens.total;
    if (total == 0) {
      return Text(
        'No tokens recorded.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    final parts = <({String label, int value, Color color})>[
      (label: 'cached read', value: tokens.cacheRead, color: _cache),
      (
        label: 'input',
        value: tokens.input,
        color: theme.colorScheme.primary,
      ),
      (
        label: 'output',
        value: tokens.output,
        color: theme.colorScheme.tertiary,
      ),
      (
        label: 'reasoning',
        value: tokens.reasoning,
        color: theme.colorScheme.secondary,
      ),
      (
        label: 'cached write',
        value: tokens.cacheWrite,
        color: theme.colorScheme.outline,
      ),
    ].where((p) => p.value > 0).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 10,
            child: Row(
              // Without stretch the segments get their height from their
              // children, and a childless ColoredBox is zero tall: the bar
              // occupied space but drew nothing.
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final part in parts)
                  Expanded(
                    // Flex is an int; a part too small to show gets 1/1000th of
                    // the bar rather than vanishing.
                    flex: (part.value / total * 1000).round().clamp(1, 1000),
                    child: ColoredBox(color: part.color),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 14,
          runSpacing: 8,
          children: [
            for (final part in parts)
              _Legend(label: part.label, value: part.value, color: part.color),
          ],
        ),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          formatTokens(value),
          style: theme.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.hint});

  final String label;
  final String value;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 2),
            Text(
              hint!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Steps per day. Plain bars rather than a chart library: one number per day,
/// no axes to get wrong.
class _ActivityChart extends StatelessWidget {
  const _ActivityChart({required this.days});

  final List<ActivityDay> days;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final peak = days.fold<int>(0, (m, d) => d.steps > m ? d.steps : m);
    if (peak == 0) return const SizedBox.shrink();

    // A very long history would otherwise become a smear; cap the width and
    // let it scroll.
    const barSlot = 7.0;
    final width = (days.length * barSlot).clamp(0.0, 4000.0);

    return SizedBox(
      height: 92,
      child: Scrollbar(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: true,
          child: SizedBox(
            width: width,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final day in days)
                  Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Tooltip(
                      message:
                          '${day.date}: ${day.steps} steps',
                      child: Container(
                        width: barSlot - 3,
                        // A day with steps must stay visible even when it is a
                        // sliver against the peak.
                        height: (6 + 62 * day.steps / peak).clamp(6.0, 68.0),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.45 + 0.55 * day.steps / peak,
                          ),
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModelUsageRow extends StatelessWidget {
  const _ModelUsageRow({required this.usage});

  final ModelUsage usage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            usage.modelID,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Pill(label: usage.providerID, dense: true),
              if (usage.variant != null && usage.variant!.isNotEmpty)
                Pill(label: usage.variant!, dense: true),
              Pill(label: '${usage.steps} steps', dense: true),
              Pill(
                label: '${formatTokens(usage.tokens.total)} tok',
                dense: true,
              ),
              if (usage.cost > 0)
                Pill(
                  label: formatCost(usage.cost),
                  dense: true,
                  icon: Icons.payments_outlined,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ToolRow extends StatelessWidget {
  const _ToolRow({required this.usage});

  final ToolUsage usage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rate = usage.successRate;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  usage.mode == 'summary' ? 'All tools' : usage.mode,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
              if (rate != null)
                Text(
                  '${(rate * 100).toStringAsFixed(rate > 0.999 ? 0 : 1)}% ok',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: rate > 0.99 ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${usage.calls} calls · ${usage.failed} failed'
            '${usage.unfinished > 0 ? ' · ${usage.unfinished} unfinished' : ''}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}