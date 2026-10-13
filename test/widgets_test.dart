import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/data/models.dart';
import 'package:opencode_mobile/src/ui/chat_screen.dart';
import 'package:opencode_mobile/src/ui/home_screen.dart';
import 'package:opencode_mobile/src/ui/widgets.dart';

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

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

      // A running session gets a status dot on the leading icon and is not
      // mistaken for something awaiting approval.
      expect(find.byIcon(Icons.gpp_maybe_outlined), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
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
}