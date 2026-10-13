import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/account_usage.dart';
import '../state/account.dart';
import 'charts.dart';
import 'widgets.dart';

/// What the opencode.ai account spent.
///
/// The source is `GET /api/v2/usage/export`, the endpoint the Console's own web
/// app uses for its usage page. It is undocumented but answers a signed-in
/// user token, so this is real account spending rather than a local guess.
class AccountUsageScreen extends ConsumerWidget {
  const AccountUsageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(accountUsageProvider);
    final range = ref.watch(accountUsageRangeProvider);
    final email = ref.watch(accountEmailProvider).value ?? '';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Account usage'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () {
              ref.invalidate(accountUsageProvider);
              ref.invalidate(accountEmailProvider);
            },
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
                for (final option in AccountUsageRange.values) ...[
                  ChoiceChip(
                    label: Text(option.label),
                    selected: range == option,
                    onSelected: (_) => ref
                        .read(accountUsageRangeProvider.notifier)
                        .select(option),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          if (email.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  email,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: usage.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (error, _) => EmptyState(
                icon: Icons.cloud_off,
                title: 'Cannot load account usage',
                message: '$error',
                action: FilledButton.tonal(
                  onPressed: () => ref.invalidate(accountUsageProvider),
                  child: const Text('Retry'),
                ),
              ),
              data: (data) => data.isEmpty
                  ? const EmptyState(
                      icon: Icons.receipt_long_outlined,
                      title: 'Nothing spent in this period',
                      message: 'No usage was recorded on the account.',
                    )
                  : _UsageBody(usage: data, fetchedAt: data.fetchedAt),
            ),
          ),
        ],
      ),
    );
  }
}

class _UsageBody extends StatelessWidget {
  const _UsageBody({required this.usage, this.fetchedAt});

  final AccountUsage usage;
  final DateTime? fetchedAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
      children: [
        _SpendCard(usage: usage, fetchedAt: fetchedAt),
        const SizedBox(height: 28),
        Text('Requests per day', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Newest on the right · ${usage.days} days',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 14),
        _DailyChart(days: usage.byDay),
        const SizedBox(height: 30),
        Text('Tokens', style: theme.textTheme.titleSmall),
        const SizedBox(height: 14),
        _TokenBreakdown(usage: usage),
        const SizedBox(height: 30),
        Text('By model', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Ranked by requests. The bar is share of the busiest model.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 14),
        ..._ranked(
          usage.byModel,
          valueOf: (t) => formatTokens(t.tokens),
          sublabelOf: (t) => '${t.requests} req',
          color: scheme.primary,
          top: 8,
          scheme: scheme,
        ),
        const SizedBox(height: 18),
        Text('By account', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Members and service accounts, ranked by cost.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 14),
        ..._ranked(
          usage.byAccount,
          valueOf: (t) => formatCost(t.costUsd),
          sublabelOf: (t) => formatTokens(t.tokens),
          color: scheme.tertiary,
          top: 8,
          scheme: scheme,
        ),
        const SizedBox(height: 18),
        ..._freeTierNote(usage, scheme, theme),
      ],
    );
  }

  /// Ranked rows, with a line for "and N more" when the list is long.
  List<Widget> _ranked(
    List<UsageTotal> totals, {
    required String Function(UsageTotal) valueOf,
    required String Function(UsageTotal) sublabelOf,
    required Color color,
    required int top,
    required ColorScheme scheme,
  }) {
    if (totals.isEmpty) {
      return [
        Text(
          'Nothing recorded.',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      ];
    }
    final peak = totals.first.requests == 0
        ? 1
        : totals.first.requests;
    final shown = totals.take(top).toList();
    final widgets = <Widget>[
      for (var i = 0; i < shown.length; i++)
        RankedBar(
          label: shown[i].label,
          sublabel: sublabelOf(shown[i]),
          value: valueOf(shown[i]),
          fraction: shown[i].requests / peak,
          color: color,
          emphasis: i == 0,
        ),
    ];
    final rest = totals.length - shown.length;
    if (rest > 0) {
      widgets.add(
        Text(
          'and $rest more',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
        ),
      );
    }
    return widgets;
  }

  List<Widget> _freeTierNote(
    AccountUsage usage,
    ColorScheme scheme,
    ThemeData theme,
  ) {
    final free = usage.byModel
        .where((m) => m.label.contains('-free') && m.costUnits == 0)
        .toList();
    if (free.isEmpty) return const [];
    final requests = free.fold<int>(0, (s, m) => s + m.requests);
    final share = requests / (usage.requests == 0 ? 1 : usage.requests);
    return [
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.savings_outlined, size: 20, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${(share * 100).toStringAsFixed(share > 0.999 ? 0 : 1)}% '
                    'of requests were free',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${free.length} free models handled '
                    '${formatTokens(requests)} requests at no cost.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ];
  }
}

/// The headline: what it cost, against what was generated.
class _SpendCard extends StatelessWidget {
  const _SpendCard({required this.usage, this.fetchedAt});

  final AccountUsage usage;
  final DateTime? fetchedAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        formatCost(usage.costUsd),
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: scheme.primary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'spent on the account',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      formatTokens(usage.requests),
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'requests',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 14),
            Row(
              children: [
                _Mini(label: 'Days', value: '${usage.days}'),
                _Mini(label: 'Models', value: '${usage.models}'),
                _Mini(label: 'Accounts', value: '${usage.accounts}'),
                _Mini(
                  label: 'Avg / req',
                  value: usage.requests == 0
                      ? '-'
                      : formatCost(usage.costUsd / usage.requests),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Mini extends StatelessWidget {
  const _Mini({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Requests per day as bars: every day is discrete and comparable, which an
/// area chart would blur away.
class _DailyChart extends StatelessWidget {
  const _DailyChart({required this.days});

  final List<DayTotal> days;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final peak = days.fold<int>(0, (m, d) => d.requests > m ? d.requests : m);
    final busiest = days.isEmpty
        ? null
        : days.reduce((a, b) => a.requests >= b.requests ? a : b);
    // A window can be all cost and no requests; in that case show the money,
    // which is the number that actually moved.
    final byCost = peak == 0;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Spread the days across whatever width there is, so a short window
        // fills the frame instead of huddling at one edge. Only when there are
        // more days than fit does it fall back to a fixed slot and scroll.
        const minSlot = 7.0;
        final fits = days.isNotEmpty &&
            days.length * minSlot <= constraints.maxWidth;
        final slot = days.isEmpty
            ? minSlot
            : fits
            ? constraints.maxWidth / days.length
            : minSlot;

        return ChartFrame(
          baselineLabel: byCost
              ? 'Daily spend, busiest day ${formatCost(busiest?.costUsd ?? 0)}'
              : 'Busiest day ${formatTokens(busiest?.requests ?? 0)} requests',
          // Labels only make sense while the bars stay put. Once the chart
          // scrolls, a fixed set of dates under a moving plot would lie.
          axisLabels: fits ? _axisLabels(days) : const [],
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: fits,
            physics: fits
                ? const NeverScrollableScrollPhysics()
                : const ClampingScrollPhysics(),
            child: SizedBox(
              width: math.max(days.length * slot, constraints.maxWidth),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final day in days)
                    Builder(
                      builder: (context) {
                        final fraction = byCost
                            ? day.costUnits / _peakCost(days)
                            : (peak == 0 ? 0.0 : day.requests / peak);
                        return Tooltip(
                          message:
                              '${day.day}: '
                              '${formatTokens(day.requests)} req · '
                              '${formatCost(day.costUsd)}',
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 1),
                            child: Container(
                              width: math.max(2, slot - 2),
                              // A day with nothing still needs a visible
                              // mark, or the axis looks broken.
                              height: math.max(3, 100 * fraction),
                              decoration: BoxDecoration(
                                color: scheme.primary.withValues(
                                  alpha: 0.35 + 0.65 * fraction,
                                ),
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(2),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static int _peakCost(List<DayTotal> days) {
    final peak = days.fold<int>(0, (m, d) => d.costUnits > m ? d.costUnits : m);
    return peak == 0 ? 1 : peak;
  }

  /// First, middle and last date only: a label under every bar is noise.
  static List<String> _axisLabels(List<DayTotal> days) {
    if (days.isEmpty) return const [];
    if (days.length <= 3) {
      return days.map((d) => _short(d.parsed)).toList();
    }
    return [
      _short(days.first.parsed),
      _short(days[days.length ~/ 2].parsed),
      _short(days.last.parsed),
    ];
  }

  static String _short(DateTime? date) =>
      date == null ? '' : '${date.day}/${date.month}';
}

/// Token composition as a ring, with the totals spelled out beside it.
class _TokenBreakdown extends StatelessWidget {
  const _TokenBreakdown({required this.usage});

  final AccountUsage usage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final parts = <({String label, int value, Color color})>[
      (
        label: 'cached read',
        value: usage.cacheReadTokens,
        color: scheme.primary,
      ),
      (label: 'input', value: usage.inputTokens, color: scheme.tertiary),
      (label: 'output', value: usage.outputTokens, color: scheme.secondary),
      (
        label: 'cached write',
        value: usage.cacheWriteTokens,
        color: scheme.outline,
      ),
    ];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        DonutChart(
          slices: [
            for (final part in parts)
              DonutSlice(value: part.value.toDouble(), color: part.color),
          ],
          center: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                formatTokens(usage.tokensTotal),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'total',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final part in parts)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: part.color,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          part.label,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatTokens(part.value),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}