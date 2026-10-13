import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../data/models.dart';
import '../state/providers.dart';
import 'home_screen.dart';
import 'permission_sheet.dart';
import 'widgets.dart';

/// Sessions inside one project.
///
/// Grouped by day rather than one flat run: a chat list is read by "what did I
/// do today", and a hundred rows in a single column makes that impossible to
/// see without scrolling past everything.
class SessionsScreen extends ConsumerStatefulWidget {
  const SessionsScreen({
    super.key,
    required this.project,
    required this.directory,
  });

  final Project project;

  /// The directory the server scopes this project to. Every request for the
  /// list and for a new session carries it, so nothing leaks across projects.
  final String? directory;

  @override
  ConsumerState<SessionsScreen> createState() => _SessionsScreenState();
}

enum _Filter { all, running, waiting }

class _SessionsScreenState extends ConsumerState<SessionsScreen> {
  _Filter _filter = _Filter.all;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final all = ref.watch(sessionsProvider);
    final running = ref.watch(runningSessionIdsProvider);
    final pending = ref.watch(permissionInboxProvider);
    final renames = ref.watch(sessionRenamesProvider);

    // Scope to the project rather than relying on the global selection, so
    // opening a project cannot show another one's sessions.
    final scoped = all.value
        ?.where((session) => session.directory == widget.directory)
        .toList(growable: false);
    final items = _apply(scoped ?? const <SessionSummary>[], running, pending);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.project.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 1),
            Text(
              items.length == 1 ? '1 session' : '${items.length} sessions',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: const [HomeMenu()],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _newSession(context),
        icon: const Icon(Icons.add_comment_outlined),
        label: const Text('New session'),
      ),
      body: Column(
        children: [
          if (pending.isNotEmpty)
            PermissionBanner(
              requests: pending,
              onOpen: (request) => showPermissionSheet(
                context,
                request: request,
                api: ref.read(apiProvider),
                onReplied: () => ref.invalidate(permissionInboxProvider),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'Search sessions',
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
                _FilterMenu(
                  value: _filter,
                  onChanged: (value) => setState(() => _filter = value),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: all.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (error, _) => EmptyState(
                icon: Icons.cloud_off,
                title: 'Cannot load sessions',
                message: '$error',
                action: FilledButton.tonal(
                  onPressed: () => ref.invalidate(sessionsProvider),
                  child: const Text('Retry'),
                ),
              ),
              data: (_) {
                if (items.isEmpty) {
                  return EmptyState(
                    icon: Icons.forum_outlined,
                    title: scoped?.isEmpty ?? false
                        ? 'No sessions in this project yet'
                        : 'Nothing matches',
                    message: scoped?.isEmpty ?? false
                        ? 'Start one to talk to your agent from here.'
                        : 'Try a different filter or search.',
                  );
                }
                final groups = _groupByDay(items);
                return RefreshIndicator(
                  onRefresh: () async => ref.invalidate(sessionsProvider),
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                    itemCount: groups.length,
                    itemBuilder: (context, index) {
                      final group = groups[index];
                      return _DayGroup(
                        label: group.label,
                        sessions: group.sessions,
                        names: {
                          for (final session in group.sessions)
                            session.id: renames[session.id] ?? session.displayTitle,
                        },
                        running: running,
                        pending: pending,
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  List<SessionSummary> _apply(
    List<SessionSummary> sessions,
    Set<String> running,
    List<PermissionRequest> pending,
  ) {
    final needle = _query.trim().toLowerCase();
    return sessions.where((session) {
      switch (_filter) {
        case _Filter.running:
          if (!running.contains(session.id)) return false;
        case _Filter.waiting:
          if (!pending.any((p) => p.sessionId == session.id)) return false;
        case _Filter.all:
          break;
      }
      if (needle.isEmpty) return true;
      return session.displayTitle.toLowerCase().contains(needle) ||
          (session.modelId ?? '').toLowerCase().contains(needle) ||
          (session.agent ?? '').toLowerCase().contains(needle);
    }).toList(growable: false)
      ..sort((a, b) => b.updated.compareTo(a.updated));
  }

  Future<void> _newSession(BuildContext context) async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final session = await api.createSession(directory: widget.directory);
      if (!context.mounted) return;
      ref.invalidate(sessionsProvider);
      await openSession(context, session);
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not create a session: $error')),
      );
    }
  }
}

class _DayBucket {
  const _DayBucket({required this.label, required this.sessions});

  final String label;
  final List<SessionSummary> sessions;
}

List<_DayBucket> _groupByDay(List<SessionSummary> sessions) {
  final groups = <_DayBucket>[];
  var current = <SessionSummary>[];
  String? label;

  for (final session in sessions) {
    final day = _dayLabel(session.updated);
    if (label == null) {
      label = day;
    } else if (day != label) {
      groups.add(_DayBucket(label: label, sessions: current));
      current = <SessionSummary>[];
      label = day;
    }
    current.add(session);
  }
  if (current.isNotEmpty && label != null) {
    groups.add(_DayBucket(label: label, sessions: current));
  }
  return groups;
}

/// "Today", "Yesterday", then a date. Sessions carry epoch millis, and the
/// server has no timezone of its own to blame.
String _dayLabel(int epochMillis) {
  if (epochMillis == 0) return 'Unknown date';
  final date = DateTime.fromMillisecondsSinceEpoch(epochMillis);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(date.year, date.month, date.day);
  final delta = today.difference(that).inDays;
  if (delta <= 0) return 'Today';
  if (delta == 1) return 'Yesterday';
  if (delta < 7) return _weekday(date);
  if (date.year == now.year) return '${date.day} ${_month(date.month)}';
  return '${date.day} ${_month(date.month)} ${date.year}';
}

String _weekday(DateTime date) => const [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
][date.weekday - 1];

String _month(int month) => const [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
][month - 1];

class _DayGroup extends StatelessWidget {
  const _DayGroup({
    required this.label,
    required this.sessions,
    required this.names,
    required this.running,
    required this.pending,
  });

  final String label;
  final List<SessionSummary> sessions;
  final Map<String, String> names;
  final Set<String> running;
  final List<PermissionRequest> pending;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
          child: Row(
            children: [
              Text(
                label.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Divider(
                  height: 1,
                  color: theme.colorScheme.outlineVariant,
                ),
              ),
            ],
          ),
        ),
        for (final session in sessions)
          SessionTile(
            title: names[session.id] ?? session.displayTitle,
            model: session.modelId,
            agent: session.agent,
            updated: session.updated,
            cost: session.cost,
            tokens: session.tokens.total,
            isRunning: running.contains(session.id),
            needsApproval: pending.any((p) => p.sessionId == session.id),
            onTap: () => openSession(context, session),
          ),
      ],
    );
  }
}

class _FilterMenu extends StatelessWidget {
  const _FilterMenu({required this.value, required this.onChanged});

  final _Filter value;
  final ValueChanged<_Filter> onChanged;

  String get _label => switch (value) {
    _Filter.all => 'All',
    _Filter.running => 'Running',
    _Filter.waiting => 'Waiting',
  };

  IconData get _icon => switch (value) {
    _Filter.all => Icons.filter_list,
    _Filter.running => Icons.play_circle_outline,
    _Filter.waiting => Icons.gpp_maybe_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return PopupMenuButton<_Filter>(
      tooltip: 'Filter',
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final filter in _Filter.values)
          PopupMenuItem(
            value: filter,
            child: Row(
              children: [
                Icon(
                  value == filter
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: value == filter ? scheme.primary : scheme.outlineVariant,
                ),
                const SizedBox(width: 10),
                Text(switch (filter) {
                  _Filter.all => 'All',
                  _Filter.running => 'Running',
                  _Filter.waiting => 'Waiting for approval',
                }),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon, size: 17, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(_label, style: theme.textTheme.labelMedium),
            Icon(Icons.arrow_drop_down, size: 18, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}