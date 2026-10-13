import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../runtime/local_server.dart';
import '../data/pairing.dart';
import '../runtime/lan.dart';
import '../runtime/runtime_manifest.dart';
import '../state/local_server.dart';
import '../state/providers.dart';
import 'widgets.dart';

/// OpenCode running on this phone.
///
/// Reached from the servers list rather than from a menu, because it is a server
/// like any other — it just happens to live on the device in your hand, which
/// makes it the one a new user is most likely to try first.
///
/// Nothing is downloaded on the way in. The runtime is 199 MB, and a user who
/// only ever talks to their desktop should never pay for it.
class LocalServerScreen extends ConsumerWidget {
  const LocalServerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final local = ref.watch(localServerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('On this phone'),
        actions: [
          if (local.isInstalled && !local.isBusy)
            IconButton(
              tooltip: 'Runtime options',
              icon: const Icon(Icons.more_vert),
              onPressed: () => _runtimeOptions(context, ref, local),
            ),
        ],
      ),
      // A switcher that keeps the outgoing screen in the tree leaves an
      // invisible copy of it on top of the new one, still taking touches. The
      // rows that stopped responding were exactly the ones the old layout
      // covered, and the ones below it kept working. An outgoing child is
      // therefore never interactive.
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        layoutBuilder: (current, previous) => Stack(
          children: [
            for (final child in previous) IgnorePointer(child: child),
            ?current,
          ],
        ),
        child: switch (local) {
          _ when local.loading => const _CheckingView(),
          _ when local.install.running => _InstallingView(
            key: const ValueKey('install'),
            progress: local.install,
          ),
          _ when local.status.phase == LocalServerPhase.running =>
            _RunningView(key: const ValueKey('running'), local: local),
          _ when local.status.phase == LocalServerPhase.failed =>
            _FailedView(key: const ValueKey('failed'), local: local),
          _ => _IdleView(key: const ValueKey('idle'), local: local),
        },
      ),
    );
  }

  Future<void> _runtimeOptions(
    BuildContext context,
    WidgetRef ref,
    LocalServerState local,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove OpenCode from this phone?'),
        content: Text(
          'Deletes the ${local.installedVersion} runtime and everything it '
          'has done on this device. About 199 MB, back on a desk instead of in '
          'your pocket.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(localServerProvider.notifier).uninstall();
    }
  }
}

/// Shown for the moment it takes to read the device.
class _CheckingView extends StatelessWidget {
  const _CheckingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 26,
        height: 26,
        child: CircularProgressIndicator(strokeWidth: 2.4),
      ),
    );
  }
}

/// Base for the two states that both read as "installed, not serving".
class _IdleView extends ConsumerWidget {
  const _IdleView({super.key, required this.local});

  final LocalServerState local;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(localServerProvider.notifier);

    if (!local.isInstalled) {
      return _InstallPrompt(
        manifest: ref.watch(runtimeManifestProvider).value,
        version: local.latestVersion ?? 'the latest',
        onInstall: controller.install,
        error: local.install.error,
        onDismissError: controller.dismissInstallError,
      );
    }

    return _Page(
      children: [
        _StatusHero(
          icon: Icons.smartphone,
          title: 'Installed, not running',
          subtitle:
              'OpenCode ${local.installedVersion} is on this phone and is '
              'not using any battery until you start it.',
          state: _HeroState.idle,
        ),
        if (local.canUpdate)
          _UpdateBanner(
            version: local.latestVersion!,
            onUpdate: controller.install,
          ),
        _ErrorCard(error: local.install.error),
        const SizedBox(height: 8),
        _PrimaryAction(
          icon: Icons.play_arrow_rounded,
          label: 'Start the server',
          onPressed: controller.start,
        ),
        _SecondaryAction(
          label: 'What does this do?',
          onPressed: () => _explain(context),
        ),
      ],
    );
  }

  void _explain(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => const _HowItWorks(),
    );
  }
}

/// The first thing a user sees, and the only place the 199 MB is asked for.
///
/// It says what the download is, how big it is, and what it buys, because a
/// silent 199 MB is how an app loses trust.
class _InstallPrompt extends StatelessWidget {
  const _InstallPrompt({
    required this.manifest,
    required this.version,
    required this.onInstall,
    this.error,
    this.onDismissError,
  });

  /// The sizes come from the manifest rather than from a sentence written by
  /// hand, because the sentence would still say 199 MB after the installer
  /// changed to downloading the archives and unpacking them itself.
  final RuntimeManifest? manifest;

  final String version;
  final Future<void> Function() onInstall;
  final String? error;
  final VoidCallback? onDismissError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return _Page(
      children: [
        const SizedBox(height: 8),
        _InstallIllustration(),
        const SizedBox(height: 28),
        Text(
          'OpenCode is not on this phone yet',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Install OpenCode $version and this phone becomes an OpenCode '
          'server — a real agent with your own models, reachable from any '
          'device you like.',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 22),
        _InstallFacts(manifest: manifest),
        if (error != null) ...[
          const SizedBox(height: 18),
          _ErrorCard(error: error!),
        ],
        const SizedBox(height: 24),
        _PrimaryAction(
          icon: Icons.download_rounded,
          label: 'Install on this phone',
          onPressed: onInstall,
        ),
        const SizedBox(height: 10),
        _SecondaryAction(
          label: 'Not now',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }
}

/// The three things it gets you, and the honest size.
class _InstallFacts extends StatelessWidget {
  const _InstallFacts({this.manifest});

  final RuntimeManifest? manifest;

  static const _perks = [
    (
      Icons.bolt_rounded,
      'Your own server',
      'Sessions, projects and agents, on your own hardware.',
    ),
    (
      Icons.devices_other_rounded,
      'Reachable anywhere',
      'Pair a laptop or a second phone to it over the network.',
    ),
    (
      Icons.lock_outline_rounded,
      'Nothing leaves',
      'It runs here. The only traffic is the model calls you make.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sizes = manifest;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final perk in _perks) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(perk.$1, size: 19, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      perk.$2,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      perk.$3,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.sd_storage_outlined,
              size: 19,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                sizes == null
                    ? 'One download, about 97 MB'
                    : '${formatBytes(sizes.downloadBytes)} to download, '
                          '${formatBytes(sizes.installedBytes)} on this phone',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A phone with a server inside it, drawn rather than imported.
///
/// It carries the idea on its own: no caption is needed for the shape to say
/// "the server is on this device".
class _InstallIllustration extends StatefulWidget {
  const _InstallIllustration();

  @override
  State<_InstallIllustration> createState() => _InstallIllustrationState();
}

class _InstallIllustrationState extends State<_InstallIllustration>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) {
          final glow = 0.18 + _pulse.value * 0.22;
          return Container(
            width: 118,
            height: 118,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primary.withValues(alpha: glow),
            ),
            child: Center(
              child: Container(
                width: 78,
                height: 78,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.surface,
                  border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.45),
                    width: 1.5,
                  ),
                ),
                child: Icon(Icons.dns_rounded, size: 36, color: scheme.primary),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The download, with real numbers rather than a spinner.
class _InstallingView extends StatelessWidget {
  const _InstallingView({super.key, required this.progress});

  final InstallProgress progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final percent = (progress.fraction * 100).round();

    return _Page(
      children: [
        const SizedBox(height: 24),
        Center(
          child: SizedBox(
            width: 40,
            height: 40,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              value: progress.total > 0 ? progress.fraction : null,
            ),
          ),
        ),
        const SizedBox(height: 28),
        Text(
          progress.replacing ? 'Updating OpenCode' : 'Installing OpenCode',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          progress.total > 0
              ? '${formatBytes(progress.received)} of '
                  '${formatBytes(progress.total)}'
              : 'Starting the download',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: progress.total > 0 ? progress.fraction : null,
            minHeight: 7,
            backgroundColor: scheme.surfaceContainerHighest,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          '$percent%',
          textAlign: TextAlign.center,
          style: theme.textTheme.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 26),
        Text(
          'Every file is checked against the digest OpenCode published before '
          'it is allowed to run. A download that does not match is thrown away.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

/// Serving: the address, the password, and the three things you can do.
class _RunningView extends ConsumerStatefulWidget {
  const _RunningView({super.key, required this.local});

  final LocalServerState local;

  @override
  ConsumerState<_RunningView> createState() => _RunningViewState();
}

class _RunningViewState extends ConsumerState<_RunningView> {
  bool _passwordVisible = false;
  List<String> _lan = const [];

  @override
  void initState() {
    super.initState();
    _loadLan();
  }

  Future<void> _loadLan() async {
    final addresses = await lanAddresses();
    if (mounted) setState(() => _lan = addresses);
  }

  @override
  Widget build(BuildContext context) {
    final local = widget.local;
    final status = local.status;
    final controller = ref.read(localServerProvider.notifier);

    return _Page(
      children: [
        _StatusHero(
          icon: Icons.dns_rounded,
          title: 'Running',
          subtitle: status.pinned
              ? 'Kept alive in the background until you stop it.'
              : 'Running. It will stop if Android reclaims the app.',
          state: _HeroState.live,
        ),
        const SizedBox(height: 22),
        _ValueRow(
          label: 'Address',
          value: status.localBaseUrl ?? '—',
          icon: Icons.link_rounded,
          onCopy: status.localBaseUrl == null
              ? null
              : () => _copy(context, status.localBaseUrl!),
        ),
        const SizedBox(height: 10),
        _ValueRow(
          label: 'Password',
          value: status.password ?? '—',
          icon: Icons.password_rounded,
          obscured: !_passwordVisible,
          trailing: IconButton(
            tooltip: _passwordVisible ? 'Hide' : 'Show',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              _passwordVisible
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 19,
            ),
            onPressed: () => setState(
              () => _passwordVisible = !_passwordVisible,
            ),
          ),
          onCopy: status.password == null
              ? null
              : () => _copy(context, status.password!),
        ),
        if (_lan.isNotEmpty && status.port != null) ...[
          const SizedBox(height: 10),
          _ValueRow(
            label: 'On your network',
            value: '${_lan.first}:${status.port}',
            icon: Icons.wifi_rounded,
            onCopy: () => _copy(context, '${_lan.first}:${status.port}'),
          ),
        ],
        const SizedBox(height: 24),
        _PrimaryAction(
          icon: Icons.forum_outlined,
          label: 'Open it in the app',
          onPressed: () async {
            final profile = controller.localProfile;
            if (profile == null) return;
            final navigator = Navigator.of(context);
            final messenger = ScaffoldMessenger.of(context);
            final ok = await ref
                .read(connectionProvider.notifier)
                .connect(profile);
            if (!ok) {
              messenger.showSnackBar(
                const SnackBar(
                  content: Text('Could not connect to the local server'),
                ),
              );
              return;
            }
            // The phone's own server has a workspace; point the app at it so
            // sessions and files land there rather than in the state directory
            // the server would pick on its own.
            final workspace = controller.workspace;
            if (workspace != null) {
              ref.read(selectedDirectoryProvider.notifier).select(workspace);
            }
            // `true` tells an "Add a server" screen underneath that the work is
            // done and it should close too.
            if (navigator.canPop()) navigator.pop(true);
          },
        ),
        const SizedBox(height: 10),
        _SecondaryAction(
          label: 'Connect another device',
          icon: Icons.qr_code_2_rounded,
          onPressed: () => _publish(context, ref, local),
        ),
        const SizedBox(height: 10),
        _SecondaryAction(
          label: 'Stop the server',
          icon: Icons.stop_rounded,
          onPressed: controller.stop,
        ),
      ],
    );
  }

  Future<void> _copy(BuildContext context, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied $value'), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _publish(
    BuildContext context,
    WidgetRef ref,
    LocalServerState local,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => _PublishSheet(local: local),
    );
  }
}

/// The server refused to start, and says so in its own words.
class _FailedView extends ConsumerWidget {
  const _FailedView({super.key, required this.local});

  final LocalServerState local;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(localServerProvider.notifier);
    final output = local.status.output.trim();

    return _Page(
      children: [
        _StatusHero(
          icon: Icons.error_outline_rounded,
          title: 'The server did not start',
          subtitle: output.isEmpty
              ? 'It exited before it said why.'
              : output.split('\n').first,
          state: _HeroState.failed,
        ),
        const SizedBox(height: 22),
        if (output.isNotEmpty)
          _LogPanel(output: output),
        const SizedBox(height: 20),
        _PrimaryAction(
          icon: Icons.refresh_rounded,
          label: 'Try again',
          onPressed: controller.start,
        ),
        const SizedBox(height: 10),
        _SecondaryAction(
          label: 'Stop',
          onPressed: controller.stop,
        ),
      ],
    );
  }
}

/// A QR the other device can scan, from a pairing link or a LAN address.
class _PublishSheet extends ConsumerStatefulWidget {
  const _PublishSheet({required this.local});

  final LocalServerState local;

  @override
  ConsumerState<_PublishSheet> createState() => _PublishSheetState();
}

class _PublishSheetState extends ConsumerState<_PublishSheet> {
  late final TextEditingController _url =
      TextEditingController(text: widget.local.status.localBaseUrl ?? '');

  _PublishTarget _target = _PublishTarget.lan;
  bool _busy = false;
  String? _error;
  String? _link;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final link = _link;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Connect another device',
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                'Scan this with the OpenCode desktop app or another phone.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),

              // Two ways out, with the consequences named rather than implied.
              _TargetOption(
                icon: Icons.wifi_rounded,
                title: 'This network',
                description: 'Fast and free, but only works on this Wi-Fi.',
                selected: _target == _PublishTarget.lan,
                onTap: () => setState(() {
                  _target = _PublishTarget.lan;
                  _link = null;
                  _error = null;
                }),
              ),
              const SizedBox(height: 10),
              _TargetOption(
                icon: Icons.public_rounded,
                title: 'The internet',
                description:
                    'Opens a tunnel. Encrypted, keyed on the server password, '
                    'and reachable from anywhere.',
                selected: _target == _PublishTarget.internet,
                onTap: () => setState(() {
                  _target = _PublishTarget.internet;
                  _link = null;
                  _error = null;
                }),
              ),
              const SizedBox(height: 20),

              if (_error != null) ...[
                _ErrorCard(error: _error!),
                const SizedBox(height: 16),
              ],

              if (link != null)
                _QrPanel(link: link)
              else
                _PrimaryAction(
                  icon: Icons.qr_code_2_rounded,
                  label: _busy
                      ? 'Setting up…'
                      : (_target == _PublishTarget.internet
                            ? 'Open a tunnel and show the code'
                            : 'Show the code'),
                  busy: _busy,
                  onPressed: _busy ? null : _generate,
                ),

              const SizedBox(height: 8),
              _SecondaryAction(
                label: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _generate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final controller = ref.read(localServerProvider.notifier);
      String link;
      if (_target == _PublishTarget.internet) {
        link = await controller.pairingLink(remote: true);
      } else {
        // The server listens on loopback, so the link it prints names the
        // phone itself. A pairing code is not bound to an address, so the link
        // is rebuilt against the address the other device can actually reach.
        final port = widget.local.status.port;
        if (port == null) throw StateError('The server has no port yet');
        final printed = await controller.pairingLink(remote: false);
        final lan = preferredLanAddress(await lanAddresses());
        link = lan == null
            ? printed
            : (PairingLink.retarget(printed, 'http://$lan:$port') ?? printed);
      }
      if (!mounted) return;
      setState(() => _link = link);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

enum _PublishTarget { lan, internet }

class _QrPanel extends StatelessWidget {
  const _QrPanel({required this.link});

  final String link;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          // White behind the code whatever the theme is: scanners need the
          // quiet zone to be light, and a dark-on-dark QR scans on a good day
          // and not on a bad one.
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: QrImageView(
              data: link,
              version: QrVersions.auto,
              size: 210,
              backgroundColor: Colors.white,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: Color(0xFF000000),
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Color(0xFF000000),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Works once, expires in five minutes.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            link,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              fontSize: 11,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('How this works', style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            for (final step in const [
              (
                '1',
                'OpenCode ships no Android build',
                'The closest one is a Linux binary that needs a loader Android '
                    'does not have. The app ships that loader and starts the '
                    'real binary with it — unmodified.',
              ),
              (
                '2',
                'It listens only when you say so',
                'The server is started and stopped by hand, and held in the '
                    'background by a notification you can see.',
              ),
              (
                '3',
                'Your models, your keys',
                'The server reaches the providers you have signed in to. No '
                    'account of ours sits in the middle.',
              ),
            ]) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 12,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Text(
                      step.$1,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          step.$2,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          step.$3,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
            ],
          ],
        ),
      ),
    );
  }
}

// --- building blocks ---------------------------------------------------------

enum _HeroState { idle, live, failed }

/// The one thing to look at when the screen opens.
class _StatusHero extends StatelessWidget {
  const _StatusHero({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.state,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final _HeroState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = switch (state) {
      _HeroState.live => Colors.green.shade600,
      _HeroState.failed => scheme.error,
      _HeroState.idle => scheme.onSurfaceVariant,
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(15),
          ),
          child: Icon(icon, size: 26, color: color),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A label, a value, and the two gestures that matter on a value: read it and
/// copy it.
class _ValueRow extends StatelessWidget {
  const _ValueRow({
    required this.label,
    required this.value,
    required this.icon,
    this.obscured = false,
    this.trailing,
    this.onCopy,
  });

  final String label;
  final String value;
  final IconData icon;
  final bool obscured;
  final Widget? trailing;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 19, color: scheme.onSurfaceVariant),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  obscured ? _mask(value) : value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                    fontSize: 13.5,
                  ),
                ),
              ],
            ),
          ),
          ?trailing,
          IconButton(
            tooltip: 'Copy',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.copy_rounded, size: 18),
            onPressed: onCopy,
          ),
        ],
      ),
    );
  }

  static String _mask(String value) =>
      value.isEmpty ? '' : '•' * value.length.clamp(8, 24);
}

class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner({required this.version, required this.onUpdate});

  final String version;
  final Future<void> Function({bool updating}) onUpdate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.upgrade_rounded, size: 19, color: scheme.onTertiaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'OpenCode $version is available',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onTertiaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: () => onUpdate(updating: true),
            child: const Text('Update'),
          ),
        ],
      ),
    );
  }
}

class _TargetOption extends StatelessWidget {
  const _TargetOption({
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
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? scheme.primary : Colors.transparent,
              width: 1.5,
            ),
          ),
          padding: const EdgeInsets.all(14),
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
                        height: 1.35,
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

/// The process's own words, in something a person can read.
class _LogPanel extends StatelessWidget {
  const _LogPanel({required this.output});

  final String output;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SelectableText(
        output,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11.5,
          height: 1.45,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({
    required this.icon,
    required this.label,
    this.onPressed,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final Future<void> Function()? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: FilledButton.icon(
        onPressed: busy ? null : onPressed,
        icon: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon, size: 20),
        label: Text(label, style: const TextStyle(fontSize: 15.5)),
      ),
    );
  }
}

class _SecondaryAction extends StatelessWidget {
  const _SecondaryAction({required this.label, this.icon, this.onPressed});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final button = TextButton(
      onPressed: onPressed,
      child: Text(label),
    );
    if (icon == null) return button;
    return SizedBox(
      height: 44,
      child: TextButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.error});

  /// Null when there is nothing wrong, so a caller can pass one straight
  /// through instead of guarding the call site.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final message = error;
    if (message == null || message.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
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

/// Scrolls, and keeps its content off the system bars.
class _Page extends StatelessWidget {
  const _Page({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: children,
    );
  }
}