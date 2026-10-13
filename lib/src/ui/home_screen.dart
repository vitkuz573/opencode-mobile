import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../data/events.dart';
import '../data/models.dart';
import '../state/providers.dart';
import 'account_screen.dart';
import 'permission_sheet.dart';
import 'servers_screen.dart';
import 'settings_screen.dart';
import 'usage_screen.dart';
import 'widgets.dart';

/// Session list for the connected server: projects, live status, and anything
/// waiting on the user's approval.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionProvider).value;
    final sessions = ref.watch(sessionsProvider);
    final running = ref.watch(runningSessionIdsProvider);
    final renames = ref.watch(sessionRenamesProvider);
    final pending = ref.watch(permissionInboxProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(connection?.profile?.displayHost ?? 'OpenCode'),
        actions: [
          _ConnectionStatus(),
          PopupMenuButton<String>(
            onSelected: (value) => switch (value) {
              'settings' => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
              ),
              'servers' => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const ServersScreen()),
              ),
              'usage' => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const UsageScreen()),
              ),
              'account' => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const AccountScreen(),
                ),
              ),
              'disconnect' => ref
                  .read(connectionProvider.notifier)
                  .disconnect(),
              _ => null,
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'settings',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.settings_outlined),
                  title: const Text('Settings'),
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'servers',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('Servers'),
                ),
              ),
              PopupMenuItem(
                value: 'usage',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.insights_outlined),
                  title: const Text('Usage'),
                ),
              ),
              PopupMenuItem(
                value: 'account',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.cloud_outlined),
                  title: const Text('opencode.ai account'),
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'disconnect',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.logout),
                  title: const Text('Disconnect'),
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _newSession(context, ref),
        icon: const Icon(Icons.add_comment_outlined),
        label: const Text('New session'),
      ),
      body: Column(
        children: [
          if (pending.isNotEmpty)
            _PermissionBanner(
              requests: pending,
              onOpen: (request) => showPermissionSheet(
                context,
                request: request,
                api: ref.read(apiProvider),
                onReplied: () => ref.invalidate(permissionInboxProvider),
              ),
            ),
          _ProjectSelector(),
          const Divider(height: 1),
          Expanded(
            child: sessions.when(
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
              data: (items) {
                if (items.isEmpty) {
                  return const EmptyState(
                    icon: Icons.forum_outlined,
                    title: 'No sessions yet',
                    message: 'Start one to talk to your agent from here.',
                  );
                }
                final sorted = [...items]..sort(
                  (a, b) => b.updated.compareTo(a.updated),
                );
                return RefreshIndicator(
                  onRefresh: () async => ref.invalidate(sessionsProvider),
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: sorted.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final session = sorted[index];
                      final title = renames[session.id] ?? session.displayTitle;
                      return SessionTile(
                        title: title,
                        model: session.modelId,
                        agent: session.agent,
                        updated: session.updated,
                        cost: session.cost,
                        tokens: session.tokens.total,
                        isRunning: running.contains(session.id),
                        needsApproval: pending.any(
                          (p) => p.sessionId == session.id,
                        ),
                        onTap: () => openSession(
                          context,
                          SessionSummary(
                            id: session.id,
                            title: title,
                            projectId: session.projectId,
                            cost: session.cost,
                            tokens: session.tokens,
                            created: session.created,
                            updated: session.updated,
                            agent: session.agent,
                            modelId: session.modelId,
                            modelProvider: session.modelProvider,
                            directory: session.directory,
                            outcome: session.outcome,
                          ),
                        ),
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

  Future<void> _newSession(BuildContext context, WidgetRef ref) async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    final directory = ref.read(selectedDirectoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final session = await api.createSession(directory: directory);
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

class SessionTile extends StatelessWidget {
  const SessionTile({
    super.key,
    required this.title,
    required this.updated,
    required this.cost,
    required this.tokens,
    required this.isRunning,
    required this.needsApproval,
    this.model,
    this.agent,
    this.onTap,
  });

  final String title;
  final String? model;
  final String? agent;
  final int updated;
  final double cost;
  final int tokens;
  final bool isRunning;
  final bool needsApproval;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      leading: _LeadingBadge(isRunning: isRunning, needsApproval: needsApproval),
      title: Text(
        title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              formatRelativeTime(updated),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (agent != null) Pill(label: agent!, dense: true),
            if (model != null) Pill(label: model!, dense: true),
            if (tokens > 0)
              Pill(
                label: '${formatTokens(tokens)} tok',
                dense: true,
                icon: Icons.toll_outlined,
              ),
            if (cost > 0)
              Pill(label: formatCost(cost), dense: true, icon: Icons.payments_outlined),
          ],
        ),
      ),
      trailing: needsApproval
          ? const Icon(Icons.gpp_maybe_outlined, color: Colors.orange)
          : const Icon(Icons.chevron_right),
    );
  }
}

class _LeadingBadge extends StatelessWidget {
  const _LeadingBadge({required this.isRunning, required this.needsApproval});

  final bool isRunning;
  final bool needsApproval;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = needsApproval
        ? Colors.orange
        : (isRunning ? scheme.primary : scheme.outline);
    return Stack(
      alignment: Alignment.center,
      children: [
        Icon(Icons.chat_bubble_outline, color: color, size: 24),
        if (isRunning || needsApproval)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.surface, width: 1.5),
              ),
            ),
          ),
      ],
    );
  }
}

class _ProjectSelector extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(projectsProvider);
    final selected = ref.watch(selectedDirectoryProvider);
    final theme = Theme.of(context);

    return projects.when(
      loading: () => const SizedBox(height: 48),
      error: (_, _) => const SizedBox(height: 48),
      data: (items) {
        if (items.isEmpty) return const SizedBox(height: 8);
        final directories = <String?>{
          null,
          ...items.map((p) => p.scopeDirectory),
        };
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          child: Row(
            children: [
              Icon(Icons.folder_outlined, size: 18, color: theme.colorScheme.outline),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String?>(
                    isExpanded: true,
                    value: directories.contains(selected) ? selected : null,
                    hint: const Text('All projects'),
                    items: [
                      for (final directory in directories)
                        DropdownMenuItem<String?>(
                          value: directory,
                          child: Text(
                            directory == null
                                ? 'All projects'
                                : _labelFor(items, directory),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      ref.read(selectedDirectoryProvider.notifier).select(value);
                    },
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _labelFor(List<Project> projects, String? directory) {
    if (directory == null) return 'All projects';
    for (final project in projects) {
      if (project.scopeDirectory == directory ||
          project.canonical == directory) {
        return project.displayName;
      }
    }
    return directory.split(RegExp(r'[/\\]')).last;
  }
}

class _ConnectionStatus extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(eventStatusProvider).value;
    final scheme = Theme.of(context).colorScheme;
    if (status == null) return const SizedBox(width: 8);

    final (label, color) = switch (status.status) {
      StreamStatus.live => ('live', Colors.green),
      StreamStatus.connecting => ('connecting', scheme.primary),
      StreamStatus.retrying => (
        status.attempt > 3 ? 'offline' : 'retrying',
        Colors.orange,
      ),
      StreamStatus.failed => ('offline', scheme.error),
      StreamStatus.idle => ('idle', scheme.outline),
    };
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Tooltip(
        message: status.message ?? 'Event stream: $label',
        child: StreamIndicator(label: label, color: color),
      ),
    );
  }
}

class _PermissionBanner extends StatelessWidget {
  const _PermissionBanner({required this.requests, required this.onOpen});

  final List<PermissionRequest> requests;
  final ValueChanged<PermissionRequest> onOpen;

  @override
  Widget build(BuildContext context) {
    final first = requests.first;
    return Material(
      color: Colors.orange.withValues(alpha: 0.16),
      child: ListTile(
        dense: true,
        leading: Icon(Icons.gpp_maybe_outlined, color: Colors.orange.shade800),
        title: Text(
          requests.length == 1
              ? 'Waiting for your approval'
              : '${requests.length} actions waiting for approval',
        ),
        subtitle: Text(
          first.headline +
              (first.resources.isEmpty ? '' : ' · ${first.resources.first}'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => onOpen(first),
      ),
    );
  }
}

