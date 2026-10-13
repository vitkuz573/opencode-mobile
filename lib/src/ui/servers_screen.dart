import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api.dart';
import '../data/pairing.dart';
import '../runtime/local_server.dart';
import '../state/local_server.dart';
import '../state/providers.dart';
import 'local_server_screen.dart';
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
    final local = ref.watch(localServerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Servers')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
        children: [
          // First, and separate from the saved servers: it is not another host
          // to connect to, it is the one already in your hand.
          _ThisPhoneCard(local: local),
          const SizedBox(height: 18),
          if (profiles.isNotEmpty) ...[
            Text(
              'Saved servers',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
          ],
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
          if (profiles.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'No saved servers yet. Add one to reach a machine on your '
                'network or through a pairing link.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
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
      floatingActionButton: FloatingActionButton.extended(
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

/// The server that is this device.
///
/// It sits above the saved servers because it is not one of them: there is
/// nothing to type, nothing to scan and nothing to go wrong. Tapping it either
/// starts what is already installed, or explains the one-time download and asks
/// for it.
class _ThisPhoneCard extends ConsumerWidget {
  const _ThisPhoneCard({required this.local});

  final LocalServerState local;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = local.status;

    final (icon, color, headline, detail) = switch (local) {
      _ when local.loading => (
        Icons.smartphone_outlined,
        scheme.onSurfaceVariant,
        'This phone',
        'Checking…',
      ),
      _ when local.install.running => (
        Icons.downloading_rounded,
        scheme.primary,
        'This phone',
        local.install.replacing
            ? 'Updating OpenCode…'
            : 'Installing OpenCode…',
      ),
      _ when status.phase == LocalServerPhase.running => (
        Icons.dns_rounded,
        Colors.green.shade600,
        'This phone',
        'Running on port ${status.port}',
      ),
      _ when status.phase == LocalServerPhase.failed => (
        Icons.error_outline_rounded,
        scheme.error,
        'This phone',
        'Did not start — tap for the reason',
      ),
      _ when !local.isInstalled => (
        Icons.smartphone_outlined,
        scheme.onSurfaceVariant,
        'This phone',
        'Run OpenCode on this device',
      ),
      _ when local.canUpdate => (
        Icons.upgrade_rounded,
        scheme.tertiary,
        'This phone',
        'OpenCode ${local.latestVersion} is available',
      ),
      _ => (
        Icons.smartphone_outlined,
        scheme.onSurfaceVariant,
        'This phone',
        'OpenCode ${local.installedVersion} installed, not running',
      ),
    };

    return Material(
      color: scheme.primaryContainer.withValues(alpha: 0.28),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const LocalServerScreen()),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      headline,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
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

/// Explains why there are no fields when "On this phone" is chosen.
///
/// An empty form looks broken. This says the address and the password are
/// already known, which is the whole point of the mode.
class _PhoneNote extends StatelessWidget {
  const _PhoneNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lock_open_rounded, size: 18, color: scheme.primary),
              const SizedBox(width: 10),
              Text(
                'Nothing to type',
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'The address is this device, and the password is whatever the '
            'server printed when it started. Both are already known here.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
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

/// One of the two ways to authenticate, shown as a card rather than a segment
/// so the choice carries its consequences.
class _ModeOption extends StatelessWidget {
  const _ModeOption({
    required this.icon,
    required this.title,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: selected
          ? scheme.primaryContainer.withValues(alpha: 0.35)
          : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          // A hairline instead of a filled block: the selected state is a
          // change of emphasis, not a change of kind.
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? scheme.primary : Colors.transparent,
              width: 1.5,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Row(
            children: [
              Icon(
                icon,
                size: 22,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 20,
                color: selected ? scheme.primary : scheme.outlineVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stacks the fields with consistent spacing.
///
/// No shared surface: each field carries its own border, and putting bordered
/// fields inside a filled group is what produced the nesting before.
class _FieldGroup extends StatelessWidget {
  const _FieldGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          children[i],
        ],
      ],
    );
  }
}

class _SoftField extends StatelessWidget {
  const _SoftField({
    required this.controller,
    required this.label,
    this.hint,
    this.icon,
    this.obscure = false,
    this.keyboardType,
    this.minLines = 1,
    this.maxLines = 1,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final IconData? icon;
  final bool obscure;
  final TextInputType? keyboardType;
  final int minLines;
  final int maxLines;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Without a visible edge a text field stops looking like something you can
    // tap, so the border is kept and only the theme's fill-plus-outline
    // doubling is dropped.
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboardType,
        autocorrect: false,
        enableSuggestions: !obscure,
        minLines: minLines,
        maxLines: maxLines,
        onChanged: onChanged,
        style: const TextStyle(fontSize: 15),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          hintStyle: TextStyle(color: scheme.onSurfaceVariant),
          prefixIcon: icon == null ? null : Icon(icon, size: 19),
          prefixIconColor: scheme.onSurfaceVariant,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 16,
          ),
        ),
      ),
    );
  }
}

/// The action, pinned out of the scroll area so it stays reachable.
class _SubmitBar extends StatelessWidget {
  const _SubmitBar({
    required this.busy,
    required this.label,
    required this.onPressed,
  });

  final bool busy;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: FilledButton.icon(
            onPressed: onPressed,
            icon: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            label: Text(label),
          ),
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
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
              style: TextStyle(color: scheme.onErrorContainer, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

/// Sentinel meaning "let the user paste the link themselves".
const _manual = '<paste a different link>';

/// Adds a server: password or pairing link, the two ways a phone is trusted.
class AddServerScreen extends ConsumerStatefulWidget {
  const AddServerScreen({super.key, this.prefill});

  /// An address to start from, e.g. when re-connecting to a known host.
  final String? prefill;

  @override
  ConsumerState<AddServerScreen> createState() => _AddServerScreenState();
}

enum _Mode { password, phone, pairing }

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
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          // Two ways to be trusted, each with what it actually costs the user.
          // A segmented button gave the choice a name and nothing else, so the
          // cards carry the decision.
          _ModeOption(
            icon: Icons.key_outlined,
            title: 'Password',
            description: 'The password printed when the server started.',
            selected: _mode == _Mode.password,
            onTap: () => setState(() => _mode = _Mode.password),
          ),
          const SizedBox(height: 10),
          _ModeOption(
            icon: Icons.smartphone_outlined,
            title: 'On this phone',
            description: _phoneHint(ref.watch(localServerProvider)),
            selected: _mode == _Mode.phone,
            onTap: _openLocalServer,
          ),
          const SizedBox(height: 10),
          _ModeOption(
            icon: Icons.qr_code_2_outlined,
            title: 'Pairing link',
            description: 'Works from anywhere and expires in five minutes.',
            selected: _mode == _Mode.pairing,
            onTap: () => setState(() => _mode = _Mode.pairing),
          ),
          const SizedBox(height: 24),

          if (_error != null) ...[
            _ErrorCard(message: _error!),
            const SizedBox(height: 20),
          ],

          if (_mode == _Mode.password)
            _FieldGroup(
              children: [
                _SoftField(
                  controller: _url,
                  label: 'Server address',
                  hint: '192.168.1.5:4096',
                  icon: Icons.lan_outlined,
                  keyboardType: TextInputType.url,
                  onChanged: (_) => setState(() {}),
                ),
                // Shows what will actually be stored, because the typed value
                // is usually a bare host and the saved one carries a scheme.
                if (_url.text.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                    child: Row(
                      children: [
                        Icon(
                          Icons.arrow_forward,
                          size: 13,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            ServerProfile.normalizeBaseUrl(
                              _url.text.trim(),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                _SoftField(
                  controller: _password,
                  label: 'Password',
                  icon: Icons.password_outlined,
                  obscure: true,
                ),
              ],
            )
          else if (_mode == _Mode.pairing)
            _FieldGroup(
              children: [
                _SoftField(
                  controller: _link,
                  label: 'Pairing link',
                  hint: 'https://host/auth/connect/…',
                  icon: Icons.link,
                  minLines: 2,
                  maxLines: 4,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _scanQr,
                    icon: const Icon(Icons.qr_code_scanner, size: 18),
                    label: const Text('Scan the QR code'),
                  ),
                ),
              ],
            )
          else
            const _PhoneNote(),

          const SizedBox(height: 18),

          // Last, because it is the only optional field: the name is garnish
          // for the list, the address and the secret are what connect. The
          // phone's own server is already named.
          if (_mode != _Mode.phone) ...[
            _SoftField(
              controller: _label,
              label: 'Name',
              hint: 'Optional — Work, home, VPS',
              icon: Icons.label_outline,
            ),
            const SizedBox(height: 10),
          ],
          Text(
            'Saved servers are matched by address, so adding the same host '
            'again replaces the stored one.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      // Pinned to the bottom: a form that floats in the middle of an empty
      // screen looks unfinished and puts the action a thumb's width out of
      // reach on a tall form.
      bottomNavigationBar: _SubmitBar(
        busy: _busy,
        label: _busy
            ? 'Connecting…'
            : switch (_mode) {
                _Mode.phone => 'Set up the phone server',
                _Mode.pairing => 'Add and connect',
                _Mode.password => 'Add and connect',
              },
        onPressed: _busy ? null : _submit,
      ),
    );
  }

  /// The line under "On this phone", which is a status rather than a
  /// description: what it says depends on whether the runtime is there yet.
  String _phoneHint(LocalServerState local) {
    if (local.loading) return 'Checking what is installed…';
    if (local.install.running) {
      return local.install.replacing
          ? 'Updating OpenCode…'
          : 'Installing OpenCode…';
    }
    if (local.status.phase == LocalServerPhase.running) {
      return 'Running on port ${local.status.port}.';
    }
    if (!local.isInstalled) {
      final manifest = ref.read(runtimeManifestProvider).value;
      return manifest == null
          ? 'Not installed.'
          : 'Not installed. ${formatBytes(manifest.downloadBytes)} to download.';
    }
    if (local.canUpdate) {
      return 'OpenCode ${local.latestVersion} is available.';
    }
    return 'OpenCode ${local.installedVersion} is installed.';
  }

  /// Leaves this screen for the phone-server page, which owns the install, the
  /// start, and the credentials.
  Future<void> _openLocalServer() async {
    final navigator = Navigator.of(context);
    final added = await navigator.push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => const LocalServerScreen(),
      ),
    );
    if (added == true && mounted) {
      navigator.pop();
    }
  }

  Future<void> _scanQr() async {
    final messenger = ScaffoldMessenger.of(context);
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const _QrScannerRoute()),
    );
    if (raw == null || !mounted) return;

    final found = PairingLink.all(raw);
    if (found.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('That QR code is not an OpenCode pairing link'),
        ),
      );
      return;
    }

    // `opencode pair` prints one link per reachable address and encodes only
    // the first into the QR, which is usually loopback. On a phone that address
    // is the phone, so picking it silently would fail with a confusing error.
    final chosen = await _chooseTarget(found.first);
    if (chosen == null || !mounted) return;
    _link.text = chosen;
    setState(() {});
  }

  /// Asks which address to use when the payload is not usable as printed.
  ///
  /// Returns null when the user backs out.
  Future<String?> _chooseTarget(String link) async {
    final reachable = PairingLink.all(_link.text).where(
      (candidate) => !PairingLink.isLoopback(candidate),
    );
    final options = <({String label, String link, bool ok})>[
      for (final candidate in reachable)
        (label: _hostLabel(candidate), link: candidate, ok: true),
    ];

    // Same code, different host: works for any address the phone has reached.
    for (final host in await ref.read(remoteHostsProvider.future)) {
      final retargeted = PairingLink.retarget(link, host);
      if (retargeted == null) continue;
      if (options.any((o) => o.link == retargeted)) continue;
      options.add((label: _hostLabel(retargeted), link: retargeted, ok: true));
    }

    if (options.isEmpty) {
      return _explainLoopback(link);
    }
    if (!PairingLink.isLoopback(link)) return link;
    if (!mounted) return null;

    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text(
                  'That QR points at the phone',
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  'The code it carries also works on another address. Pick one '
                  'this phone can reach.',
                  style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final option in options)
                ListTile(
                  leading: Icon(Icons.dns_outlined, color: scheme.primary),
                  title: Text(option.label),
                  onTap: () => Navigator.of(sheetContext).pop(option.link),
                ),
              ListTile(
                leading: Icon(Icons.edit_outlined, color: scheme.onSurfaceVariant),
                title: const Text('Paste a different link'),
                onTap: () => Navigator.of(sheetContext).pop(_manual),
              ),
            ],
          ),
        );
      },
    );
    return choice == _manual ? null : choice;
  }

  /// Nothing to offer: say what happened and leave the field for typing.
  Future<String?> _explainLoopback(String link) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('That QR points at the phone'),
        content: Text(
          'It carries a code for ${PairingLink.hostOf(link)}, which on a phone '
          'is the phone itself. Run `opencode pair --remote` on the host and '
          'paste the remote link instead.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return null;
  }

  String _hostLabel(String link) {
    final host = PairingLink.hostOf(link);
    final scheme = Uri.tryParse(link)?.scheme ?? 'http';
    return host == null ? link : '$scheme://$host';
  }

  Future<void> _submit() async {
    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(connectionProvider.notifier);
    final navigator = Navigator.of(context);
    final label = _label.text.trim();

    // The phone's own server has no fields: the app knows its address and can
    // start it, so there is nothing here to fill in.
    if (_mode == _Mode.phone) {
      await _openLocalServer();
      return;
    }

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
        var raw = _link.text.trim();
        if (raw.isEmpty) {
          setState(() => _error = 'Paste the link printed by `opencode pair`');
          return;
        }
        // Pasting the whole `opencode pair` output brings both links, and the
        // first one is loopback. Ask which to use before spending the code:
        // it is single use, so a wrong guess costs the user a new pairing run.
        final first = PairingLink.tryParse(raw);
        final needsChoice = PairingLink.all(raw).length > 1 ||
            (first != null && PairingLink.isLoopback(first));
        if (needsChoice && first != null) {
          final chosen = await _chooseTarget(first);
          if (chosen == null || !mounted) return;
          raw = chosen;
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