import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/api.dart';
import '../data/models.dart';
import 'chat_screen.dart';

/// Shows one pending permission request and sends the answer.
///
/// The three replies mirror the server's `Permission.Reply` enum: allow once,
/// allow for the rest of the session, or refuse.
Future<void> showPermissionSheet(
  BuildContext context, {
  required PermissionRequest request,
  required OpenCodeApi? api,
  VoidCallback? onReplied,
  bool openSessionOnClose = false,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _PermissionSheet(
      request: request,
      api: api,
      onReplied: onReplied,
      openSessionOnClose: openSessionOnClose,
    ),
  );
}

class _PermissionSheet extends StatefulWidget {
  const _PermissionSheet({
    required this.request,
    required this.api,
    this.onReplied,
    required this.openSessionOnClose,
  });

  final PermissionRequest request;
  final OpenCodeApi? api;
  final VoidCallback? onReplied;
  final bool openSessionOnClose;

  @override
  State<_PermissionSheet> createState() => _PermissionSheetState();
}

class _PermissionSheetState extends State<_PermissionSheet> {
  bool _sending = false;
  String? _error;

  Future<void> _reply(PermissionReply reply) async {
    final api = widget.api;
    if (api == null) {
      setState(() => _error = 'Not connected');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await api.replyToPermission(
        widget.request.sessionId,
        widget.request.id,
        reply.name,
      );
      widget.onReplied?.call();
      if (!mounted) return;
      Navigator.of(context).pop();
      if (widget.openSessionOnClose && mounted) {
        await openSessionById(
          context,
          sessionId: widget.request.sessionId,
          title: 'Session',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final request = widget.request;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.gpp_maybe_outlined, color: Colors.orange),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    request.headline,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            if (request.message != null) ...[
              const SizedBox(height: 10),
              Text(request.message!, style: theme.textTheme.bodyMedium),
            ],
            if (request.resources.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                request.resources.join('\n'),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _sending ? null : () => _reply(PermissionReply.reject),
                    child: const Text('Deny'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _sending
                        ? null
                        : () => _reply(PermissionReply.always),
                    child: const Text('Always'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: _sending ? null : () => _reply(PermissionReply.once),
                    child: const Text('Allow once'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Center(
              child: TextButton(
                onPressed: _sending
                    ? null
                    : () {
                        Clipboard.setData(
                          ClipboardData(text: request.action),
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Action copied')),
                        );
                      },
                child: Text(request.action, style: theme.textTheme.labelSmall),
              ),
            ),
          ],
        ),
      ),
    );
  }
}