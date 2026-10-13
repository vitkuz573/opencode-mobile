import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui/chat_screen.dart';
import 'ui/connect_screen.dart';
import 'ui/home_screen.dart';
import 'ui/lock_screen.dart';
import 'data/models.dart';
import 'state/app_lock.dart';
import 'state/providers.dart';

void main() {
  runApp(const ProviderScope(child: OpenCodeApp()));
}

class OpenCodeApp extends StatelessWidget {
  const OpenCodeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenCode Mobile',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const RootGate(),
    );
  }
}

/// Switches between the lock screen, the connect screen and the session list.
/// Routing lives in one place so "am I connected?" is never answered twice,
/// and "may I look?" is never answered anywhere else.
class RootGate extends ConsumerStatefulWidget {
  const RootGate({super.key});

  @override
  ConsumerState<RootGate> createState() => _RootGateState();
}

class _RootGateState extends ConsumerState<RootGate>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A phone left on a desk must not stay open: backgrounding relocks.
    // Inactive counts, because the OS can hide us without a full pause.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      ref.read(appLockProvider.notifier).lock();
    }
  }

  @override
  Widget build(BuildContext context) {
    final lockAsync = ref.watch(appLockProvider);
    // The lock starts closed: while its persisted switch is still loading,
    // nothing behind it renders, not even for a frame.
    if (lockAsync.isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final lock = lockAsync.value ?? const AppLockState();
    if (lock.enabled && !lock.unlocked) {
      return LockScreen(
        capability:
            ref.watch(appLockCapabilityProvider).value ??
            AppLockCapability.none,
        onUnlock: () => ref
            .read(appLockProvider.notifier)
            .authenticateNow(reason: 'Unlock OpenCode'),
      );
    }

    final connection = ref.watch(connectionProvider);

    return connection.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (error, _) => _BootError(
        message: '$error',
        onRetry: () => ref.invalidate(connectionProvider),
      ),
      data: (state) => state.isConnected
          ? const HomeScreen()
          : const ConnectScreen(),
    );
  }
}

class _BootError extends StatelessWidget {
  const _BootError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40),
              const SizedBox(height: 16),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shared Material 3 theming. Two densities, one accent, no gradients: the app
/// is a tool, and legibility beats decoration.
ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF3B7DD8),
    brightness: brightness,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: scheme.surfaceTint,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      filled: true,
    ),
  );
}

/// Opens a session. Centralised so the transition is identical everywhere.
Future<void> openSession(
  BuildContext context,
  SessionSummary session,
) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ChatScreen(
        sessionId: session.id,
        title: session.displayTitle,
        directory: session.directory,
        model: session.modelId == null
            ? null
            : ModelRef(
                id: session.modelId!,
                providerID: session.modelProvider ?? 'opencode',
                variant: session.modelVariant,
              ),
        agent: session.agent,
      ),
    ),
  );
}