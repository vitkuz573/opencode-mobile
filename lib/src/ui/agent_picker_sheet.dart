import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
// Flutter has its own ConnectionState (from async.dart); this sheet only needs
// the API provider from our state layer.
import '../state/providers.dart' hide ConnectionState;
import 'widgets.dart';

/// Picks the agent a session talks to from now on.
///
/// The server offers far more agents than belong in this list: on the machine
/// this was written against, `/api/agent` returned 41 entries of which two were
/// conversation partners - the rest were hidden bookkeeping and subagents the
/// primary ones spawn. `POST /api/session/{id}/agent` accepts any string at all,
/// including ids that do not exist, so the list is built from the server's own
/// answer and filtered to primary, visible agents.
Future<void> showAgentPicker(
  BuildContext context, {
  required String sessionId,
  required String? current,
  required String? directory,
  required Future<void> Function(String agentId) onSelected,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _AgentPicker(
      sessionId: sessionId,
      current: current,
      directory: directory,
      onSelected: onSelected,
    ),
  );
}

class _AgentPicker extends ConsumerStatefulWidget {
  const _AgentPicker({
    required this.sessionId,
    required this.current,
    required this.directory,
    required this.onSelected,
  });

  final String sessionId;
  final String? current;
  final String? directory;
  final Future<void> Function(String agentId) onSelected;

  @override
  ConsumerState<_AgentPicker> createState() => _AgentPickerState();
}

class _AgentPickerState extends ConsumerState<_AgentPicker> {
  late Future<List<AgentInfo>> _agents;
  String? _busyId;

  /// Which row is ticked.
  ///
  /// Held here rather than read from `widget.current`, because the sheet lives
  /// in its own route: the chat screen updating its own state does not rebuild
  /// this widget, so the tick would stay on the agent the sheet opened with.
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.current;
    _agents = _load();
  }

  Future<List<AgentInfo>> _load() async {
    final api = ref.read(apiProvider);
    if (api == null) return const [];
    return selectableAgents(await api.agents(directory: widget.directory));
  }

  Future<void> _apply(AgentInfo agent) async {
    setState(() {
      _busyId = agent.id;
      // Move the tick immediately; the server call below can fail, and on
      // failure it goes back.
      _selectedId = agent.id;
    });
    try {
      await widget.onSelected(agent.id);
    } catch (_) {
      if (mounted) setState(() => _selectedId = widget.current);
      rethrow;
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      expand: false,
      // Two agents is a short list; letting it shrink to the content avoids a
      // half-empty sheet.
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return FutureBuilder<List<AgentInfo>>(
          future: _agents,
          builder: (context, snapshot) {
            final agents = snapshot.data ?? const <AgentInfo>[];

            if (snapshot.connectionState == ConnectionState.waiting &&
                agents.isEmpty) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError && agents.isEmpty) {
              return EmptyState(
                icon: Icons.cloud_off,
                title: 'Cannot load agents',
                message: '${snapshot.error}',
                action: FilledButton.tonal(
                  onPressed: () => setState(() => _agents = _load()),
                  child: const Text('Retry'),
                ),
              );
            }
            if (agents.isEmpty) {
              return const EmptyState(
                icon: Icons.person_off_outlined,
                title: 'No agents to choose from',
                message: 'This server exposes no conversation agents.',
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Agent', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        'The agent answers your messages. It applies from your '
                        'next message on.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.separated(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
                    itemCount: agents.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 2),
                    itemBuilder: (context, index) {
                      final agent = agents[index];
                      return _AgentRow(
                        agent: agent,
                        active: agent.id == _selectedId,
                        busy: _busyId == agent.id,
                        onTap: () => _apply(agent),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _AgentRow extends StatelessWidget {
  const _AgentRow({
    required this.agent,
    required this.active,
    required this.busy,
    required this.onTap,
  });

  final AgentInfo agent;
  final bool active;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = agent.name.isEmpty ? agent.id : agent.name;

    return Material(
      color: active
          ? scheme.primaryContainer.withValues(alpha: 0.28)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: busy || active ? null : onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: active
                                  ? FontWeight.w600
                                  : null,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Pill(label: agent.id, dense: true),
                      ],
                    ),
                    if (agent.description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        agent.description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (busy)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (active)
                Icon(Icons.check_circle, size: 20, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}