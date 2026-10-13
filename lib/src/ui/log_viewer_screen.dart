import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_log.dart';
import '../state/providers.dart';
import 'widgets.dart';

/// The recorded log, newest first, filterable by severity and searchable.
///
/// Nothing here is redacted on the way in, because nothing sensitive is ever
/// written: credentials stay in the Keystore and never reach a logger.
class LogViewerScreen extends ConsumerStatefulWidget {
  const LogViewerScreen({super.key});

  @override
  ConsumerState<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends ConsumerState<LogViewerScreen> {
  LogLevel _level = LogLevel.debug;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final log = ref.watch(logProvider);
    final entries = log.query(level: _level, search: _query);

    return Scaffold(
      appBar: AppBar(
        title: Text('Logs (${entries.length})'),
        actions: [
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: log.length == 0 ? null : () => _copy(context, log.dump()),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (value) {
              switch (value) {
                case 'clear':
                  setState(() {
                    log.clear();
                    ref.read(appLogRevisionProvider.notifier).bump();
                  });
                default:
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'clear',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.delete_outline),
                  title: Text('Clear'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'Search',
                      prefixIcon: const Icon(Icons.search, size: 18),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ),
                const SizedBox(width: 10),
                // The levels are few and fixed, so a menu beats four chips.
                PopupMenuButton<LogLevel>(
                  tooltip: 'Minimum level',
                  initialValue: _level,
                  onSelected: (value) => setState(() => _level = value),
                  itemBuilder: (context) => [
                    for (final level in LogLevel.values)
                      PopupMenuItem(
                        value: level,
                        child: Row(
                          children: [
                            Icon(
                              _level == level
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                              size: 18,
                              color: _level == level
                                  ? scheme.primary
                                  : scheme.outlineVariant,
                            ),
                            const SizedBox(width: 10),
                            Text(level.label),
                          ],
                        ),
                      ),
                  ],
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 11,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.filter_list,
                          size: 17,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _level.label,
                          style: theme.textTheme.labelMedium,
                        ),
                        Icon(
                          Icons.arrow_drop_down,
                          size: 18,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: entries.isEmpty
                ? EmptyState(
                    icon: Icons.receipt_long_outlined,
                    title: log.length == 0 ? 'Nothing logged yet' : 'No matches',
                    message: log.length == 0
                        ? 'Things worth knowing about happen here.'
                        : 'No entry matches "$_query" at ${_level.label}.',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
                    itemCount: entries.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) => _LogTile(
                      entry: entries[index],
                      onLongPress: () => _copy(context, entries[index].formatted),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _copy(BuildContext context, String text) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(
      const SnackBar(content: Text('Copied — paste it into a bug report')),
    );
  }
}

/// One log line. Monospace, because a timestamp and a level column only line
/// up if the glyphs do too.
class _LogTile extends StatelessWidget {
  const _LogTile({required this.entry, this.onLongPress});

  final LogEntry entry;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _levelColor(theme, entry.level);

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 3,
                height: 34,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          _clock(entry.at),
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11.5,
                            color: scheme(context).onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          entry.tag,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: color,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      entry.message,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static ColorScheme scheme(BuildContext context) =>
      Theme.of(context).colorScheme;

  static String _clock(DateTime at) =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}:'
      '${at.second.toString().padLeft(2, '0')}';

  static Color _levelColor(ThemeData theme, LogLevel level) =>
      switch (level) {
        LogLevel.debug => theme.colorScheme.outline,
        LogLevel.info => theme.colorScheme.primary,
        LogLevel.warn => const Color(0xFFD98324),
        LogLevel.error => theme.colorScheme.error,
      };
}