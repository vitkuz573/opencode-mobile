import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/account.dart';
import '../state/providers.dart';
import 'account_screen.dart';
import 'servers_screen.dart';

/// Shown when nothing is connected.
///
/// The form for adding a server lives in [AddServerScreen]; this screen is only
/// the way in, so that connecting and managing saved servers stay separate
/// jobs instead of one long form with a list stapled underneath.
class ConnectScreen extends ConsumerWidget {
  const ConnectScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final connection = ref.watch(connectionProvider).value;
    final profiles = ref
        .read(connectionProvider.notifier)
        .orderedProfiles();
    final signedIn = ref.watch(accountProvider).value is AccountSignedIn;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 40, 24, 32),
              children: [
                Icon(
                  Icons.terminal,
                  size: 40,
                  color: scheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'Connect to OpenCode',
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 6),
                Text(
                  'Point the app at a running server.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),

                if (connection?.error != null) ...[
                  const SizedBox(height: 24),
                  _ErrorBanner(message: connection!.error!),
                ],

                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const AddServerScreen(),
                    ),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('Add a server'),
                ),

                const SizedBox(height: 16),
                // Signing in to opencode.ai is independent of any server, and
                // this is the first screen an unauthenticated user sees, so the
                // option has to be here rather than behind the home menu.
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          const AccountScreen(startSignIn: true),
                    ),
                  ),
                  icon: Icon(
                    signedIn ? Icons.cloud_done_outlined : Icons.cloud_outlined,
                    size: 18,
                  ),
                  label: Text(
                    signedIn
                        ? 'opencode.ai account — signed in'
                        : 'Sign in to opencode.ai',
                  ),
                ),

                if (profiles.isNotEmpty) ...[
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Saved',
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const ServersScreen(),
                          ),
                        ),
                        child: const Text('Manage'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  for (final profile in profiles.take(3))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.dns_outlined),
                      title: Text(profile.displayName),
                      subtitle: Text(profile.displayHost),
                      onTap: () =>
                          ref.read(connectionProvider.notifier).connect(profile),
                    ),
                  if (profiles.length > 3)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'and ${profiles.length - 3} more',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],

                const SizedBox(height: 28),
                _HelpCard(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: scheme.onErrorContainer, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _HelpCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.help_outline,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'How do I reach my server?',
                  style: theme.textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 10),
            const _Step(
              '1',
              'Run `opencode serve` on the host machine and copy the password.',
            ),
            const _Step(
              '2',
              'Pairing is easier: `opencode pair` prints a link and a QR code '
                  'that work from anywhere.',
            ),
            const _Step(
              '3',
              'Over USB, `adb reverse tcp:4096 tcp:4096` makes the host '
                  'reachable at 127.0.0.1.',
            ),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: () =>
                  Clipboard.setData(const ClipboardData(text: 'opencode pair')),
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy `opencode pair`'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.index, this.text);

  final String index;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 10,
            backgroundColor: theme.colorScheme.secondaryContainer,
            child: Text(
              index,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}