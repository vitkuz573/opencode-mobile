import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/account.dart';
import '../state/app_lock.dart';
import '../state/providers.dart';
import 'account_screen.dart';
import 'log_viewer_screen.dart';

/// Everything that is not part of a task: the account, the app lock,
/// diagnostics and what this build is.
///
/// Deliberately nothing about servers: there can be many of them, so
/// anything per-server lives on the server's own card in the server list.
/// Settings that named one server were a lie the moment a second was saved.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final log = ref.watch(logProvider);
    ref.watch(appLogRevisionProvider);
    final signedIn = ref.watch(accountProvider).value is AccountSignedIn;
    final lock = ref.watch(appLockProvider).value ?? const AppLockState();
    final lockCapability = ref.watch(appLockCapabilityProvider).value;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const _SectionLabel('Account'),
          _Card(
            children: [
              _Row(
                icon: signedIn
                    ? Icons.cloud_done_outlined
                    : Icons.cloud_outlined,
                title: 'opencode.ai account',
                subtitle: signedIn
                    ? 'Signed in — workspace models and spending'
                    : 'Not signed in',
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AccountScreen(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),

          const _SectionLabel('Security'),
          _Card(
            children: [
              _Row(
                icon: Icons.fingerprint,
                title: 'App lock',
                subtitle: lock.enabled
                    ? switch (lockCapability) {
                        AppLockCapability.biometrics =>
                          'Fingerprint or device PIN',
                        AppLockCapability.deviceCredential => 'Device PIN',
                        _ => 'On',
                      }
                    : 'Off',
                trailing: Switch.adaptive(
                  value: lock.enabled,
                  onChanged: lock.busy
                      ? null
                      : (value) => _toggleAppLock(context, ref, value),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),

          const _SectionLabel('Diagnostics'),
          _Card(
            children: [
              _Row(
                icon: Icons.receipt_long_outlined,
                title: 'Logs',
                subtitle: log.length == 0
                    ? 'Nothing recorded yet'
                    : '${log.length} entries · ${log.prettySize}',
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const LogViewerScreen(),
                  ),
                ),
              ),
              if (log.length > 0) ...[
                const _Divider(),
                _Row(
                  icon: Icons.delete_outline,
                  title: 'Clear log',
                  subtitle: 'Removes the recorded entries',
                  onTap: () {
                    log.clear();
                    ref.read(appLogRevisionProvider.notifier).bump();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Log cleared')),
                    );
                  },
                ),
              ],
            ],
          ),
          const SizedBox(height: 22),

          const _SectionLabel('About'),
          _Card(
            children: [
              _Row(
                icon: Icons.info_outline,
                title: 'Version',
                subtitle: '1.0.0 (1)',
              ),
              const _Divider(),
              _Row(
                icon: Icons.apps_outlined,
                title: 'Package',
                subtitle: 'dev.vitkuz573.opencodemobile',
              ),
            ],
          ),
          const SizedBox(height: 18),

          // Required of any third-party client that uses the name: say plainly
          // who built it, near the bottom where settings usually go unread.
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.groups_outlined, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Not built by the OpenCode team and not affiliated with '
                    'them. Independent client for a server you run yourself.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Flips the app lock after proving it is the owner. A refusal is either "no
/// biometrics or PIN on this device" (enabling) or "not recognized"
/// (either way); the switch stays where it was.
Future<void> _toggleAppLock(
  BuildContext context,
  WidgetRef ref,
  bool value,
) async {
  final ok = await ref.read(appLockProvider.notifier).setEnabled(value);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          value
              ? 'Could not turn on the app lock: no fingerprint or PIN '
                  'set up on this device'
              : 'Not recognized. The app lock stays on.',
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          letterSpacing: 1.1,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// A grouped block. Rows inside it separate themselves, so a section reads as
/// one object rather than a stack of cards.
class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Divider(
      height: 1,
      thickness: 1,
      indent: 56,
      color: scheme.outlineVariant.withValues(alpha: 0.5),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Row(
          children: [
            Icon(icon, size: 21, color: scheme.onSurfaceVariant),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}
