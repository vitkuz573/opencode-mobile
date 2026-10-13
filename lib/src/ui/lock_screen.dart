import 'package:flutter/material.dart';

import '../state/app_lock.dart';

/// The gate over the whole app: nothing behind it renders until the owner
/// passes one authentication ceremony.
///
/// The widget itself never touches biometrics — `onUnlock` runs the ceremony
/// and reports the verdict — so it stays testable without the plugin.
class LockScreen extends StatefulWidget {
  const LockScreen({
    super.key,
    required this.capability,
    required this.onUnlock,
    this.autoPrompt = true,
  });

  final AppLockCapability capability;

  /// Runs one ceremony. True opens the app, false shows "try again".
  final Future<bool> Function() onUnlock;

  /// Prompt once as soon as the screen appears, like every banking app does.
  final bool autoPrompt;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  bool _busy = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoPrompt) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
    }
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    final ok = await widget.onUnlock();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed = !ok;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final biometric = widget.capability == AppLockCapability.biometrics;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 40, 24, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    biometric ? Icons.fingerprint : Icons.lock_outlined,
                    size: 56,
                    color: scheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Unlock OpenCode',
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    biometric
                        ? 'Use your fingerprint to continue.'
                        : 'Enter your device PIN to continue.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  if (_busy)
                    const CircularProgressIndicator()
                  else
                    FilledButton.icon(
                      onPressed: _unlock,
                      icon: Icon(
                        biometric ? Icons.fingerprint : Icons.pin_outlined,
                      ),
                      label: const Text('Unlock'),
                    ),
                  if (_failed && !_busy) ...[
                    const SizedBox(height: 16),
                    Text(
                      // A failed ceremony is usually a cancelled one; either
                      // way the remedy is the same button.
                      'Not recognized. Try again.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.error,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
