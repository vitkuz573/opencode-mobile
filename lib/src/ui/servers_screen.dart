import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api.dart';
import '../data/pairing.dart';
import '../state/providers.dart';
import 'qr_scanner_screen.dart';
import 'widgets.dart';

/// Saved servers: name them, switch between them, forget them.
///
/// A server is identified by its address, so there is one entry per host
/// whatever credential it uses. Connecting again with a different password
/// replaces the stored one rather than piling up duplicates the user then has
/// to clean up.
class ServersScreen extends ConsumerWidget {
  const ServersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final connection = ref.watch(connectionProvider).value;
    final profiles = ref
        .read(connectionProvider.notifier)
        .orderedProfiles();
    final activeUrl = connection?.profile?.baseUrl;
    final busy = connection?.phase == ConnectionPhase.connecting;

    return Scaffold(
      appBar: AppBar(title: const Text('Servers')),
      body: profiles.isEmpty
          ? ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
              children: [
                EmptyState(
                  icon: Icons.dns_outlined,
                  title: 'No servers yet',
                  message: 'Add one to get started.',
                  action: FilledButton.icon(
                    onPressed: () => _addServer(context),
                    icon: const Icon(Icons.add),
                    label: const Text('Add a server'),
                  ),
                ),
              ],
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
              children: [
                for (final profile in profiles)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _ServerCard(
                      profile: profile,
                      active: profile.baseUrl == activeUrl,
                      busy: busy,
                      onConnect: () => _connect(context, ref, profile),
                      onRename: () => _rename(context, ref, profile),
                      onDefault: () =>
                          ref.read(connectionProvider.notifier).setDefault(profile),
                      onForget: () => _forget(context, ref, profile),
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  'Servers are matched by address. Connecting again with a '
                  'different password replaces the stored one.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
      floatingActionButton: profiles.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _addServer(context),
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            ),
    );
  }

  Future<void> _addServer(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AddServerScreen()),
    );
  }

  Future<void> _connect(
    BuildContext context,
    WidgetRef ref,
    ServerProfile profile,
  ) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await ref
        .read(connectionProvider.notifier)
        .connect(profile);
    if (!ok) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            ref.read(connectionProvider).value?.error ?? 'Could not connect',
          ),
        ),
      );
      return;
    }
    navigator.pop();
  }

  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    ServerProfile profile,
  ) async {
    final controller = TextEditingController(text: profile.label);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Name this server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              profile.displayHost,
              style: TextStyle(
                color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                hintText: 'Work, home, VPS…',
              ),
              onSubmitted: (value) =>
                  Navigator.of(dialogContext).pop(value),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    await ref.read(connectionProvider.notifier).rename(profile, result);
  }

  Future<void> _forget(
    BuildContext context,
    WidgetRef ref,
    ServerProfile profile,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Forget this server?'),
        content: Text(
          'The stored credentials for ${profile.displayHost} are deleted. '
          'You can add it again at any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(connectionProvider.notifier).forget(profile);
  }
}

/// The opencode.ai account lives beside the servers rather than behind a menu
/// item on the home screen: signing in is part of setting the app up, not a
/// chore buried one level down.
class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.profile,
    required this.active,
    required this.busy,
    required this.onConnect,
    required this.onRename,
    required this.onDefault,
    required this.onForget,
  });

  final ServerProfile profile;
  final bool active;
  final bool busy;
  final VoidCallback onConnect;
  final VoidCallback onRename;
  final VoidCallback onDefault;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: active
          ? scheme.primaryContainer.withValues(alpha: 0.28)
          : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: busy || active ? null : onConnect,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                active ? Icons.cloud_done_outlined : Icons.dns_outlined,
                size: 22,
                color: active ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      profile.displayHost,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Pill(
                          label: profile.authMode == AuthMode.basic
                              ? 'password'
                              : 'paired',
                          dense: true,
                          icon: profile.authMode == AuthMode.basic
                              ? Icons.key_outlined
                              : Icons.link,
                        ),
                        if (profile.version.isNotEmpty)
                          Pill(label: profile.version, dense: true),
                        if (profile.lastUsedAt > 0)
                          Text(
                            formatRelativeTime(profile.lastUsedAt),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Server options',
                onSelected: (value) => switch (value) {
                  'rename' => onRename(),
                  'default' => onDefault(),
                  'forget' => onForget(),
                  _ => null,
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'rename',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.edit_outlined),
                      title: Text('Rename'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'default',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.star_outline),
                      title: Text('Open on launch'),
                    ),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'forget',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_outline),
                      title: Text('Forget'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Adds a server: password or pairing link, the two ways a phone is trusted.
class AddServerScreen extends ConsumerStatefulWidget {
  const AddServerScreen({super.key, this.prefill});

  /// An address to start from, e.g. when re-connecting to a known host.
  final String? prefill;

  @override
  ConsumerState<AddServerScreen> createState() => _AddServerScreenState();
}

enum _Mode { password, pairing }

class _AddServerScreenState extends ConsumerState<AddServerScreen> {
  late final TextEditingController _url = TextEditingController(
    text: widget.prefill ?? '',
  );
  final _password = TextEditingController();
  final _label = TextEditingController();
  final _link = TextEditingController();
  _Mode _mode = _Mode.password;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _password.dispose();
    _label.dispose();
    _link.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Add a server')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          SegmentedButton<_Mode>(
            segments: const [
              ButtonSegment(
                value: _Mode.password,
                label: Text('Password'),
                icon: Icon(Icons.key, size: 16),
              ),
              ButtonSegment(
                value: _Mode.pairing,
                label: Text('Pairing link'),
                icon: Icon(Icons.qr_code, size: 16),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (selection) =>
                setState(() => _mode = selection.first),
          ),
          const SizedBox(height: 20),

          if (_error != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.error_outline,
                    color: theme.colorScheme.onErrorContainer,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          TextField(
            controller: _label,
            decoration: const InputDecoration(
              labelText: 'Name (optional)',
              hintText: 'Work, home, VPS…',
              prefixIcon: Icon(Icons.label_outline),
            ),
          ),
          const SizedBox(height: 16),

          if (_mode == _Mode.password) ...[
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Server address',
                hintText: '10.0.2.2:4096',
                prefixIcon: Icon(Icons.lan_outlined),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _password,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Server password',
                helperText: 'Printed by `opencode serve` on startup',
                prefixIcon: Icon(Icons.password_outlined),
              ),
              onSubmitted: (_) => _submit(),
            ),
          ] else ...[
            TextField(
              controller: _link,
              autocorrect: false,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Pairing link',
                hintText: 'https://host/auth/connect/…',
                helperText: 'Run `opencode pair` on the host and paste the '
                    'link, or scan its QR code',
                prefixIcon: Icon(Icons.link),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _scanQr,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan the QR code instead'),
            ),
          ],

          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _busy ? null : _submit,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            label: Text(_busy ? 'Connecting…' : 'Add and connect'),
          ),
        ],
      ),
    );
  }

  Future<void> _scanQr() async {
    final messenger = ScaffoldMessenger.of(context);
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const _QrScannerRoute()),
    );
    if (raw == null || !mounted) return;

    final link = PairingLink.tryParse(raw);
    if (link == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('That QR code is not an OpenCode pairing link'),
        ),
      );
      return;
    }
    _link.text = link;
  }

  Future<void> _submit() async {
    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(connectionProvider.notifier);
    final navigator = Navigator.of(context);
    final label = _label.text.trim();

    ServerProfile? profile;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      if (_mode == _Mode.password) {
        final url = _url.text.trim();
        final password = _password.text;
        if (url.isEmpty) {
          setState(() => _error = 'Enter the server address');
          return;
        }
        if (password.isEmpty) {
          setState(() => _error = 'Enter the server password');
          return;
        }
        profile = ServerProfile.basic(
          baseUrl: url,
          password: password,
          label: label,
        );
      } else {
        final raw = _link.text.trim();
        if (raw.isEmpty) {
          setState(() => _error = 'Paste the link printed by `opencode pair`');
          return;
        }
        final hosts = await ref.read(remoteHostsProvider.future);
        final redeemed = await OpenCodeApi.redeemPairingLink(
          raw,
          fallbackHosts: hosts,
        );
        if (refundedHostNote(raw, redeemed.baseUrl)) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                'The link pointed at a loopback address, so it was redeemed '
                'on ${ServerProfile.normalizeBaseUrl(redeemed.baseUrl)}.',
              ),
            ),
          );
        }
        profile = ServerProfile.cookie(
          baseUrl: redeemed.baseUrl,
          cookie: redeemed.cookie,
          label: label,
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }

    final target = profile;
    final ok = await controller.connect(target);
    if (!mounted) return;
    if (!ok) {
      setState(
        () => _error = ref.read(connectionProvider).value?.error ??
            'Could not connect',
      );
      return;
    }
    // Keep the name the user typed: a successful reconnect carries a profile
    // without one, and the list would silently drop it.
    await controller.rename(target, label);
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text('Added ${target.displayName}')),
    );
    navigator.pop();
  }
}

/// True when a pairing link named a loopback host but was redeemed elsewhere.
bool refundedHostNote(String original, String redeemedBaseUrl) {
  final originalHost = PairingLink.hostOf(original);
  final redeemedHost = PairingLink.hostOf(redeemedBaseUrl);
  return originalHost != null &&
      redeemedHost != null &&
      originalHost != redeemedHost;
}

/// Small indirection so the scanner stays an implementation detail of this
/// screen rather than a dependency of the list.
class _QrScannerRoute extends StatelessWidget {
  const _QrScannerRoute();

  @override
  Widget build(BuildContext context) {
    return QrScannerScreen(
      onScanned: (value) => Navigator.of(context).pop(value),
    );
  }
}