import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/console.dart';
import '../state/account.dart';
import 'account_usage_screen.dart';
import 'widgets.dart';

/// opencode.ai account: sign in by device flow, then read what the workspace
/// actually offers - which models exist, with their context and output limits
/// and their price.
class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key, this.startSignIn = false});

  /// Begin the device flow as soon as the screen opens.
  ///
  /// Reached from a button that already says "sign in", asking for a second
  /// tap on another "sign in" makes the first one pointless. The explanation
  /// and the retry path stay for the case where a flow fails.
  final bool startSignIn;

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  @override
  void initState() {
    super.initState();
    if (!widget.startSignIn) return;
    // The provider resolves the stored session first; only sign out is worth
    // interrupting with a fresh code.
    ref.listenManual(accountProvider, (previous, next) {
      if (next.value is AccountSignedOut) {
        ref.read(accountProvider.notifier).signIn();
      }
    }, fireImmediately: true);
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('opencode.ai account'),
        actions: [
          account.maybeWhen(
            orElse: () => const SizedBox.shrink(),
            data: (state) => state is AccountSignedIn
                ? IconButton(
                    tooltip: 'Refresh',
                    onPressed: () => ref
                        .read(accountProvider.notifier)
                        .refresh(),
                    icon: const Icon(Icons.refresh),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
      body: account.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => EmptyState(
          icon: Icons.cloud_off,
          title: 'Could not load the account',
          message: '$error',
          action: FilledButton.tonal(
            onPressed: () => ref.invalidate(accountProvider),
            child: const Text('Retry'),
          ),
        ),
        data: (state) => switch (state) {
          AccountSignedOut() => const _SignedOut(),
          AccountAwaitingApproval(:final code, :final poll) =>
            _Awaiting(code: code, poll: poll),
          AccountSignedIn(:final workspace) => _SignedIn(workspace: workspace),
          AccountError(:final message) => _SignInError(
            message: message,
            onRetry: () => ref.read(accountProvider.notifier).signIn(),
          ),
        },
      ),
    );
  }
}

class _SignedOut extends ConsumerWidget {
  const _SignedOut();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      children: [
        Icon(
          Icons.cloud_outlined,
          size: 40,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 16),
        Text('Sign in to opencode.ai', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'Shows which models your workspace can run, with their context and '
          'output limits and what they cost.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: () => ref.read(accountProvider.notifier).signIn(),
          icon: const Icon(Icons.login),
          label: const Text('Sign in'),
        ),
        const SizedBox(height: 28),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('How it works', style: theme.textTheme.titleSmall),
                const SizedBox(height: 10),
                const _Bullet(
                  'The app shows a code and opens opencode.ai in your browser.',
                ),
                const _Bullet(
                  'You sign in there - however you already sign in, Google or '
                  'otherwise - and approve the device.',
                ),
                const _Bullet(
                  'The code is good for ten minutes and works once.',
                ),
                const SizedBox(height: 6),
                Text(
                  'Your account never touches this app: the browser handles '
                  'sign-in, and only the resulting session is stored, in the '
                  'Android keystore.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('•  ', style: theme.textTheme.bodyMedium),
          Expanded(
            child: Text(text, style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _Awaiting extends StatelessWidget {
  const _Awaiting({required this.code, required this.poll});

  final DeviceCode code;
  final Future<AccountSignedIn?> poll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 28),
          Text('Approve this device', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Open the link, sign in, pick your workspace and approve.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'CODE',
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.2,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  code.userCode,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () async {
              final uri = Uri.tryParse(code.verificationUrl);
              final messenger = ScaffoldMessenger.of(context);
              if (uri == null) {
                _showLink(messenger, code.verificationUrl);
                return;
              }
              try {
                final opened = await launchUrl(
                  uri,
                  mode: LaunchMode.externalApplication,
                );
                if (!opened) _showLink(messenger, code.verificationUrl);
              } catch (_) {
                // Nothing on the device claims the address, so fall back to
                // putting the link in the user's hands.
                _showLink(messenger, code.verificationUrl);
              }
            },
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open opencode.ai'),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: code.verificationUrl));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Link copied')),
              );
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy the link'),
          ),
          const Spacer(),
          Text(
            'Waiting for approval. The code expires in '
            '${(code.expiresInSeconds / 60).round()} minutes.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

void _showLink(ScaffoldMessengerState messenger, String url) {
  messenger.showSnackBar(
    SnackBar(
      content: Text('No browser opened. Link: $url'),
      duration: const Duration(seconds: 20),
      action: SnackBarAction(
        label: 'Copy',
        onPressed: () => Clipboard.setData(ClipboardData(text: url)),
      ),
    ),
  );
}

class _SignInError extends StatelessWidget {
  const _SignInError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.error_outline,
      title: 'Sign-in did not finish',
      message: message,
      action: FilledButton.tonal(
        onPressed: onRetry,
        child: const Text('Try again'),
      ),
    );
  }
}

class _SignedIn extends ConsumerStatefulWidget {
  const _SignedIn({required this.workspace});

  final Workspace workspace;

  @override
  ConsumerState<_SignedIn> createState() => _SignedInState();
}

class _SignedInState extends ConsumerState<_SignedIn> {
  String _query = '';
  bool _freeOnly = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final workspace = widget.workspace;

    var models = workspace.models;
    if (_freeOnly) models = models.where((m) => m.isFree).toList();
    if (_query.trim().isNotEmpty) {
      final q = _query.trim().toLowerCase();
      models = models
          .where(
            (m) =>
                m.name.toLowerCase().contains(q) ||
                m.key.toLowerCase().contains(q) ||
                m.family.toLowerCase().contains(q),
          )
          .toList();
    }
    models = [...models]..sort(
      (a, b) {
        final byProvider = a.providerID.compareTo(b.providerID);
        if (byProvider != 0) return byProvider;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      },
    );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.check_circle,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    // No account name: the Console exposes no identity endpoint
                    // to a user token, and the workspace id is an internal
                    // handle rather than something worth reading.
                    child: Text(
                      'Signed in',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        ref.read(accountProvider.notifier).signOut(),
                    child: const Text('Sign out'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${workspace.models.length} models · '
                '${workspace.providerCount} providers · '
                '${workspace.freeCount} free',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AccountUsageScreen(),
                  ),
                ),
                icon: const Icon(Icons.insights_outlined, size: 18),
                label: const Text('Account usage'),
              ),
              const SizedBox(height: 16),
              TextField(
                decoration: const InputDecoration(
                  hintText: 'Search models',
                  prefixIcon: Icon(Icons.search, size: 18),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  FilterChip(
                    label: const Text('Free only'),
                    selected: _freeOnly,
                    onSelected: (value) =>
                        setState(() => _freeOnly = value),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: models.isEmpty
              ? const EmptyState(
                  icon: Icons.search_off,
                  title: 'Nothing matches',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: models.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) =>
                      _ModelRow(model: models[index]),
                ),
        ),
      ],
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.model});

  final WorkspaceModel model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final limits = <String>[
      if (model.contextLimit > 0)
        '${formatTokens(model.contextLimit)} context',
      if (model.outputLimit > 0)
        '${formatTokens(model.outputLimit)} out',
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            model.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Pill(label: model.providerID, dense: true),
              for (final limit in limits)
                Pill(label: limit, dense: true, icon: Icons.straighten),
              if (model.isFree)
                Pill(
                  label: 'free',
                  dense: true,
                  color: Colors.green,
                  icon: Icons.sell_outlined,
                )
              else ...[
                if (model.costIn != null)
                  Pill(
                    label: '\$${model.costIn!.toStringAsFixed(2)} in',
                    dense: true,
                    icon: Icons.payments_outlined,
                  ),
                if (model.costOut != null)
                  Pill(
                    label: '\$${model.costOut!.toStringAsFixed(2)} out',
                    dense: true,
                    icon: Icons.payments_outlined,
                  ),
              ],
            ],
          ),
          if (model.family.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                model.family,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}