import 'package:flutter/material.dart';

/// Formats token counts the way an IDE would: exact below a thousand, then
/// compact. Exactness matters here — people budget against these numbers.
String formatTokens(int value) {
  if (value >= 1000000) {
    final millions = value / 1000000;
    return '${millions.toStringAsFixed(millions >= 10 ? 0 : 1)}M';
  }
  if (value >= 1000) {
    final thousands = value / 1000;
    return '${thousands.toStringAsFixed(thousands >= 10 ? 0 : 1)}k';
  }
  return '$value';
}

String formatCost(double usd) {
  if (usd == 0) return r'$0.00';
  if (usd < 0.01) return '\$${usd.toStringAsFixed(5)}';
  return '\$${usd.toStringAsFixed(2)}';
}

/// Formats a byte count for a download.
///
/// Decimal units, because that is what a mobile network plan and every app
/// store in the world counts in. Saying "199 MB" when a file is 205 655 248
/// bytes is the expectation people already have; saying "195.9 MiB" reads like
/// the vendor is being clever.
String formatBytes(int bytes) {
  if (bytes < 1000) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var value = bytes / 1000;
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return '${value >= 100 ? value.toStringAsFixed(0) : value.toStringAsFixed(1)} '
      '${units[unit]}';
}

String formatRelativeTime(int epochMillis, {DateTime? now}) {
  if (epochMillis == 0) return '';
  final reference = now ?? DateTime.now();
  final delta = reference.difference(
    DateTime.fromMillisecondsSinceEpoch(epochMillis),
  );
  if (delta.isNegative || delta.inMinutes < 1) return 'just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
  if (delta.inHours < 24) return '${delta.inHours}h ago';
  if (delta.inDays < 7) return '${delta.inDays}d ago';
  final date = DateTime.fromMillisecondsSinceEpoch(epochMillis);
  return '${date.day}/${date.month}';
}

/// Small pill used for models, agents and status.
class Pill extends StatelessWidget {
  const Pill({
    super.key,
    required this.label,
    this.icon,
    this.color,
    this.dense = false,
  });

  final String label;
  final IconData? icon;
  final Color? color;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final effective = color ?? scheme.onSurfaceVariant;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 8,
        vertical: dense ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: effective.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: dense ? 11 : 13, color: effective),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: (dense
                    ? Theme.of(context).textTheme.labelSmall
                    : Theme.of(context).textTheme.labelMedium)
                ?.copyWith(color: effective),
          ),
        ],
      ),
    );
  }
}

/// Live/retrying/offline indicator for the SSE connection.
class StreamIndicator extends StatelessWidget {
  const StreamIndicator({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Pill(label: label, color: color, icon: Icons.circle, dense: true);
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: theme.colorScheme.outline),
            const SizedBox(height: 14),
            Text(title, style: theme.textTheme.titleMedium),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 18), action!],
          ],
        ),
      ),
    );
  }
}