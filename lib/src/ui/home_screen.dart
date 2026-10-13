import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../state/providers.dart';
import 'account_screen.dart';
import 'form_sheet.dart';
import 'permission_sheet.dart';
import 'projects_screen.dart';
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
    final pending = ref.watch(permissionInboxProvider);
    final forms = ref.watch(formInboxProvider);

    return Scaffold(
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
          if (forms.isNotEmpty)
            FormBanner(
              requests: forms,
              onOpen: (request) => showFormSheet(
                context,
                request: request,
                api: ref.read(apiProvider),
                directory: null,
                onReplied: () => ref.invalidate(formInboxProvider),
              ),
            ),
          Expanded(
            child: const ProjectsScreen(),
          ),
        ],
      ),
    );
  }
}

/// The overflow menu, shared by every screen that has the same header.
class HomeMenu extends ConsumerWidget {
  const HomeMenu({super.key, this.connected = true});

  /// Whether a server is connected.
  ///
  /// Usage and "Disconnect" are actions on a live connection, so they are left
  /// out before one exists. Settings, Servers and the account all work with
  /// nothing connected, and they are the only routes to them: the connect
  /// screen used to carry no menu at all, which meant a fresh install could not
  /// open settings until a server had been added and connected.
  final bool connected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      tooltip: 'Menu',
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
          MaterialPageRoute<void>(builder: (_) => const AccountScreen()),
        ),
        'disconnect' => ref.read(connectionProvider.notifier).disconnect(),
        _ => null,
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'settings',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.settings_outlined),
            title: Text('Settings'),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'servers',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.dns_outlined),
            title: Text('Servers'),
          ),
        ),
        if (connected) ...[
          const PopupMenuItem(
            value: 'usage',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.insights_outlined),
              title: Text('Usage'),
            ),
          ),
          const PopupMenuItem(
            value: 'account',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.cloud_outlined),
              title: Text('opencode.ai account'),
            ),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: 'disconnect',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.logout),
              title: Text('Disconnect'),
            ),
          ),
        ],
      ],
    );
  }
}

/// One session in a list.
///
/// A card rather than a bare `ListTile`: the state matters more than the title
/// here, and a running session or one waiting on an approval has to be visible
/// before the text is read. The status is a coloured edge rather than a badge,
/// which used to compete with the title for the same attention.
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
    final scheme = theme.colorScheme;
    final accent = needsApproval
        ? Colors.orange
        : (isRunning ? scheme.primary : scheme.outlineVariant);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The status edge. Empty width when nothing is happening, so
                // idle sessions line up with each other.
                if (isRunning || needsApproval)
                  Container(width: 3, color: accent),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  fontWeight: FontWeight.w500,
                                  height: 1.3,
                                ),
                              ),
                            ),
                            if (needsApproval) ...[
                              const SizedBox(width: 8),
                              Tooltip(
                                message: 'Waiting for your approval',
                                child: Icon(
                                  Icons.gpp_maybe_outlined,
                                  size: 19,
                                  color: Colors.orange,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Text(
                              formatRelativeTime(updated),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            if (isRunning) ...[
                              const SizedBox(width: 8),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 9,
                                    height: 9,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.6,
                                      color: scheme.primary,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    'running',
                                    style: theme.textTheme.labelSmall
                                        ?.copyWith(color: scheme.primary),
                                  ),
                                ],
                              ),
                            ],
                            const Spacer(),
                            if (agent != null && agent!.isNotEmpty)
                              Pill(label: agent!, dense: true),
                            if (model != null && model!.isNotEmpty)
                              Pill(label: model!, dense: true),
                            if (tokens > 0)
                              Padding(
                                padding: const EdgeInsets.only(left: 6),
                                child: Text(
                                  formatTokens(tokens),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            if (cost > 0)
                              Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: Text(
                                  formatCost(cost),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
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

/// A strip above the list when something is waiting on the user. Shown on
/// every screen that lists sessions, so a pending approval is never hidden
/// behind having navigated somewhere.
class PermissionBanner extends StatelessWidget {  const PermissionBanner({
    super.key,
    required this.requests,
    required this.onOpen,
  });

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

/// The same strip for interactive forms: the agent waits on answers, so an
/// unanswered form stalls the session exactly like an unanswered permission.
class FormBanner extends StatelessWidget {
  const FormBanner({super.key, required this.requests, required this.onOpen});

  final List<FormRequest> requests;
  final ValueChanged<FormRequest> onOpen;

  @override
  Widget build(BuildContext context) {
    final first = requests.first;
    return Material(
      color: Colors.orange.withValues(alpha: 0.16),
      child: ListTile(
        dense: true,
        leading: Icon(Icons.quiz_outlined, color: Colors.orange.shade800),
        title: Text(
          requests.length == 1
              ? 'A question needs your answers'
              : '${requests.length} questions need your answers',
        ),
        subtitle: Text(
          first.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => onOpen(first),
      ),
    );
  }
}

