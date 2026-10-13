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

/// Fields sitting on one shared surface, with no border of their own.
///
/// The app theme fills every field *and* outlines it, so a stack of boxes
/// read as nesting rather than as one form.
class _FieldGroup extends StatelessWidget {
  const _FieldGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: children),
      ),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
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
          prefixIcon: icon == null ? null : Icon(icon, size: 19),
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          isDense: true,
          contentPadding: EdgeInsets.symmetric(vertical: 14),
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
          else
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
            ),

          const SizedBox(height: 18),

          // Last, because it is the only optional field: the name is garnish
          // for the list, the address and the secret are what connect.
          _SoftField(
            controller: _label,
            label: 'Name',
            hint: 'Optional — Work, home, VPS',
            icon: Icons.label_outline,
          ),
          const SizedBox(height: 10),
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
        label: _busy ? 'Connecting…' : 'Add and connect',
        onPressed: _busy ? null : _submit,
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