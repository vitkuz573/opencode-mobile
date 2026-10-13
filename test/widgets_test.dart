import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/data/models.dart';
import 'package:opencode_mobile/src/state/account.dart';
import 'package:opencode_mobile/src/state/providers.dart';
import 'package:opencode_mobile/src/ui/chat_screen.dart';
import 'package:opencode_mobile/src/ui/connect_screen.dart';
import 'package:opencode_mobile/src/ui/home_screen.dart';
import 'package:opencode_mobile/src/ui/widgets.dart';

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// A connection that is alive in the graph but connected to nothing, so tests
/// exercise the fresh-install state without touching secure storage.
class _IdleConnection extends ConnectionController {
  @override
  Future<ConnectionState> build() async => const ConnectionState();
}

class _SignedOutAccount extends AccountController {
  @override
  Future<AccountState> build() async => const AccountSignedOut();
}

ProviderScope disconnectedHost(Widget child) => ProviderScope(
  overrides: [
    connectionProvider.overrideWith(_IdleConnection.new),
    accountProvider.overrideWith(_SignedOutAccount.new),
  ],
  child: MaterialApp(home: child),
);

void main() {
  group('formatting', () {
    test('token counts stay exact below a thousand', () {
      expect(formatTokens(0), '0');
      expect(formatTokens(999), '999');
    });

    test('token counts compact above a thousand', () {
      expect(formatTokens(1500), '1.5k');
      expect(formatTokens(42000), '42k');
      expect(formatTokens(1500000), '1.5M');
    });

    test('cost keeps precision when it is tiny', () {
      expect(formatCost(0), r'$0.00');
      expect(formatCost(0.000014805), r'$0.00001');
      expect(formatCost(1.5), r'$1.50');
    });

    test('relative time reads naturally', () {
      final now = DateTime(2026, 10, 13, 12);
      expect(
        formatRelativeTime(
          now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch,
          now: now,
        ),
        '5m ago',
      );
      expect(
        formatRelativeTime(
          now.subtract(const Duration(hours: 3)).millisecondsSinceEpoch,
          now: now,
        ),
        '3h ago',
      );
      expect(formatRelativeTime(0, now: now), isEmpty);
    });
  });

  group('SessionTile', () {
    testWidgets('shows title, model and agent', (tester) async {
      await tester.pumpWidget(
        host(
          const SessionTile(
            title: 'Refactor the parser',
            model: 'kimi-k2.6',
            agent: 'build',
            updated: 0,
            cost: 0,
            tokens: 0,
            isRunning: false,
            needsApproval: false,
          ),
        ),
      );

      expect(find.text('Refactor the parser'), findsOneWidget);
      expect(find.text('kimi-k2.6'), findsOneWidget);
      expect(find.text('build'), findsOneWidget);
    });

    testWidgets('flags a running session', (tester) async {
      await tester.pumpWidget(
        host(
          const SessionTile(
            title: 'Working',
            updated: 0,
            cost: 0,
            tokens: 0,
            isRunning: true,
            needsApproval: false,
          ),
        ),
      );

      // A running session says so in words, and is not mistaken for something
      // awaiting approval. No chevron: the whole card is the target.
      expect(find.byIcon(Icons.gpp_maybe_outlined), findsNothing);
      expect(find.text('running'), findsOneWidget);
    });

    testWidgets('surfaces a pending approval', (tester) async {
      await tester.pumpWidget(
        host(
          const SessionTile(
            title: 'Waiting',
            updated: 0,
            cost: 0,
            tokens: 0,
            isRunning: false,
            needsApproval: true,
          ),
        ),
      );

      expect(find.byIcon(Icons.gpp_maybe_outlined), findsOneWidget);
    });

    testWidgets('is tappable', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(
          SessionTile(
            title: 'Tap me',
            updated: 0,
            cost: 0,
            tokens: 0,
            isRunning: false,
            needsApproval: false,
            onTap: () => taps++,
          ),
        ),
      );

      await tester.tap(find.text('Tap me'));
      expect(taps, 1);
    });
  });

  group('message blocks', () {
    testWidgets('renders a user message right-aligned', (tester) async {
      await tester.pumpWidget(
        host(
          const MessageBlock(
            message: UserMessage(id: 'm1', created: 0, text: 'do the thing'),
          ),
        ),
      );

      expect(find.text('do the thing'), findsOneWidget);
    });

    testWidgets('renders assistant text and keeps reasoning collapsed',
        (tester) async {
      await tester.pumpWidget(
        host(
          MessageBlock(
            message: AssistantMessage(
              id: 'm2',
              created: 0,
              agent: 'build',
              modelId: 'kimi',
              parts: [
                ReasoningPart('internal monologue'),
                TextPart('Here is the answer'),
              ],
            ),
          ),
        ),
      );

      expect(find.text('Here is the answer'), findsOneWidget);
      expect(find.text('Reasoning'), findsOneWidget);
      // The reasoning body stays hidden until expanded.
      expect(find.text('internal monologue'), findsNothing);
    });

    testWidgets('renders code fences as monospace blocks', (tester) async {
      await tester.pumpWidget(
        host(
          MessageBlock(
            message: AssistantMessage(
              id: 'm3',
              created: 0,
              agent: 'build',
              modelId: 'kimi',
              parts: [TextPart('before\n\n```dart\nvoid main() {}\n```')],
            ),
          ),
        ),
      );

      expect(find.textContaining('void main() {}'), findsOneWidget);
    });

    testWidgets('renders a tool card with its status', (tester) async {
      await tester.pumpWidget(
        host(
          MessageBlock(
            message: AssistantMessage(
              id: 'm4',
              created: 0,
              agent: 'build',
              modelId: 'kimi',
              parts: [
                ToolPart(
                  id: 'toolu_1',
                  name: 'read',
                  input: const {'path': 'notes.txt'},
                  status: ToolStatus.completed,
                  output: 'hello',
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('read'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    });

    testWidgets('shows an error for a failed tool', (tester) async {
      await tester.pumpWidget(
        host(
          MessageBlock(
            message: AssistantMessage(
              id: 'm5',
              created: 0,
              agent: 'build',
              modelId: 'kimi',
              parts: [
                ToolPart(
                  id: 'toolu_2',
                  name: 'bash',
                  status: ToolStatus.error,
                  error: 'The user declined this tool call',
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('The user declined this tool call'), findsOneWidget);
    });

    testWidgets('does not crash on an unmodelled message type',
        (tester) async {
      await tester.pumpWidget(
        host(
          const MessageBlock(
            message: UnknownMessage(
              id: 'm6',
              created: 0,
              kind: 'compaction',
              raw: {},
            ),
          ),
        ),
      );

      expect(find.textContaining('compaction'), findsOneWidget);
    });
  });

  group('empty state', () {
    testWidgets('shows a title and optional action', (tester) async {
      await tester.pumpWidget(
        host(
          EmptyState(
            icon: Icons.cloud_off,
            title: 'Cannot load sessions',
            message: 'network down',
            action: FilledButton(onPressed: () {}, child: const Text('Retry')),
          ),
        ),
      );

      expect(find.text('Cannot load sessions'), findsOneWidget);
      expect(find.text('network down'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  group('HomeMenu', () {
    Future<void> openMenu(
      WidgetTester tester, {
      required bool connected,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              appBar: AppBar(actions: [HomeMenu(connected: connected)]),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Menu'));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'offers settings and servers but no connection actions when nothing '
      'is connected',
      (tester) async {
        await openMenu(tester, connected: false);

        expect(find.text('Settings'), findsOneWidget);
        expect(find.text('Servers'), findsOneWidget);
        expect(find.text('Usage'), findsNothing);
        expect(find.text('Disconnect'), findsNothing);
      },
    );

    testWidgets('offers the full menu once connected', (tester) async {
      await openMenu(tester, connected: true);

      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Servers'), findsOneWidget);
      expect(find.text('Usage'), findsOneWidget);
      expect(find.text('opencode.ai account'), findsOneWidget);
      expect(find.text('Disconnect'), findsOneWidget);
    });
  });

  group('ConnectScreen', () {
    testWidgets('reaches settings and servers with nothing saved',
        (tester) async {
      await tester.pumpWidget(
        disconnectedHost(const ConnectScreen()),
      );
      await tester.pump();

      // The menu is the only route to settings before a server exists.
      expect(find.byType(HomeMenu), findsOneWidget);
      // The server list is reachable even with nothing saved yet.
      expect(find.text('Saved'), findsOneWidget);
      expect(find.text('Manage'), findsOneWidget);
      expect(find.text('Nothing saved yet.'), findsOneWidget);

      await tester.tap(find.byTooltip('Menu'));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Servers'), findsOneWidget);
    });
  });
}