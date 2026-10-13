import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../state/providers.dart';
import 'home_screen.dart';
import 'sessions_screen.dart';
import 'widgets.dart';

/// Where a connected server leads: pick a project, then its sessions.
///
/// The project used to be a dropdown sitting above a flat list of every session
/// on the server. That hid the shape of the work: which folder this is, how much
/// lives in it, and whether anything in it is running or waiting for approval.
class ProjectsScreen extends ConsumerWidget {
  const ProjectsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final connection = ref.watch(connectionProvider).value;
    final projects = ref.watch(projectsProvider);
    final sessions = ref.watch(sessionsProvider);
    final running = ref.watch(runningSessionIdsProvider);
    final pending = ref.watch(permissionInboxProvider);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(connection?.profile?.displayName ?? 'OpenCode'),
            const SizedBox(height: 1),
            Text(
              connection?.info?.version == null
                  ? 'Projects'
                  : 'Projects · server ${connection!.info!.version}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: const [HomeMenu()],
      ),
      body: projects.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => EmptyState(
          icon: Icons.cloud_off,
          title: 'Cannot load projects',
          message: '$error',
          action: FilledButton.tonal(
            onPressed: () => ref.invalidate(projectsProvider),
            child: const Text('Retry'),
          ),
        ),
        data: (items) {
          if (items.isEmpty) {
            return const EmptyState(
              icon: Icons.folder_open_outlined,
              title: 'No projects yet',
              message:
                  'A project appears once the server has a folder it can work '
                  'in. Every session lives in one.',
            );
          }

          // Counts come from the session list, so a project can say what it
          // holds instead of being a name you have to open to find out.
          final byDirectory = <String, List<SessionSummary>>{};
          for (final session in sessions.value ?? const <SessionSummary>[]) {
            final directory = session.directory;
            if (directory == null || directory.isEmpty) continue;
            byDirectory
                .putIfAbsent(directory, () => <SessionSummary>[])
                .add(session);
          }

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(projectsProvider);
              ref.invalidate(sessionsProvider);
            },
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final project = items[index];
                final inProject = byDirectory[project.scopeDirectory] ??
                    const <SessionSummary>[];
                return _ProjectCard(
                  project: project,
                  sessions: inProject.length,
                  running: inProject
                      .where((s) => running.contains(s.id))
                      .length,
                  approvals: pending
                      .where((p) => inProject.any((s) => s.id == p.sessionId))
                      .length,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SessionsScreen(
                        project: project,
                        directory: project.scopeDirectory,
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    required this.project,
    required this.sessions,
    required this.running,
    required this.approvals,
    required this.onTap,
  });

  final Project project;
  final int sessions;
  final int running;
  final int approvals;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            children: [
              Icon(Icons.folder_outlined, size: 22, color: scheme.primary),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      project.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      // The full path is only useful when the name is not.
                      project.displayName == project.canonical
                          ? project.canonical
                          : project.scopeDirectory,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (approvals > 0)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Tooltip(
                    message: '$approvals waiting for your approval',
                    child: Icon(Icons.gpp_maybe_outlined, color: Colors.orange),
                  ),
                ),
              if (running > 0)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Tooltip(
                    message: '$running running',
                    child: Icon(
                      Icons.play_circle_outline,
                      color: scheme.primary,
                    ),
                  ),
                ),
              if (sessions > 0)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(
                    '$sessions',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}