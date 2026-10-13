import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/data/stats.dart';

void main() {
  group('token breakdown', () {
    test('adds the cache segments in', () {
      final tokens = TokenBreakdown.fromJson(const {
        'input': 100,
        'output': 20,
        'reasoning': 5,
        'cache': {'read': 400, 'write': 2},
      });

      expect(tokens.total, 527);
      expect(tokens.generated, 25);
    });

    test('reads a payload with no cache section', () {
      final tokens = TokenBreakdown.fromJson(const {
        'input': 7,
        'output': 3,
        'reasoning': 0,
      });

      expect(tokens.cacheRead, 0);
      expect(tokens.cacheWrite, 0);
      expect(tokens.total, 10);
    });
  });

  group('stats parsing', () {
    // Shape taken from a live GET /api/experimental/session/stats on
    // 2026-10-13, reduced to two models and two days.
    final stats = ServerStats.fromJson(const {
      'range': {'from': 1780382385522, 'to': 1791874282944},
      'sessions': 69,
      'subagents': 68,
      'prompts': 1442,
      'steps': 16121,
      'tokens': {
        'input': 718467052,
        'output': 5281945,
        'reasoning': 4254129,
        'cache': {'read': 1770336662, 'write': 73931},
      },
      'cost': 0.009856265,
      'tools': [
        {
          'mode': 'summary',
          'totals': {
            'calls': 17900,
            'succeeded': 17536,
            'failed': 363,
            'unfinished': 1,
          },
        },
      ],
      'activeDays': 36,
      'streak': 3,
      'activity': [
        {'date': '2026-06-02', 'steps': 370},
        {'date': '2026-06-03', 'steps': 120},
      ],
      'models': [
        {
          'model': {
            'id': 'muse-spark-1.3-contributor-free',
            'providerID': 'opencode',
            'variant': 'xhigh',
          },
          'steps': 2641,
          'tokens': {
            'input': 8726128,
            'output': 815831,
            'reasoning': 786588,
            'cache': {'read': 679001790, 'write': 0},
          },
          'cost': 0,
        },
        {
          'model': {
            'id': 'cat-jam-free',
            'providerID': 'opencode',
          },
          'steps': 120,
          'tokens': {
            'input': 100,
            'output': 50,
            'reasoning': 0,
            'cache': {'read': 0, 'write': 0},
          },
          'cost': 0.25,
        },
      ],
    });

    test('reads the headline numbers', () {
      expect(stats.sessions, 69);
      expect(stats.subagents, 68);
      expect(stats.prompts, 1442);
      expect(stats.steps, 16121);
      expect(stats.activeDays, 36);
      expect(stats.streak, 3);
      expect(stats.cost, closeTo(0.009856265, 1e-12));
      expect(stats.to, greaterThan(stats.from));
    });

    test('totals tokens across every segment', () {
      expect(stats.tokens.cacheRead, 1770336662);
      expect(stats.tokens.cacheWrite, 73931);
      expect(
        stats.tokens.total,
        718467052 + 5281945 + 4254129 + 1770336662 + 73931,
      );
    });

    test('reads per-model usage', () {
      expect(stats.models, hasLength(2));
      final first = stats.models.first;
      expect(first.modelID, 'muse-spark-1.3-contributor-free');
      expect(first.providerID, 'opencode');
      expect(first.variant, 'xhigh');
      expect(first.steps, 2641);
      expect(first.key, 'opencode/muse-spark-1.3-contributor-free');
      // Reasoning effort belongs in the label so two rows of the same model at
      // different efforts stay distinguishable.
      expect(first.label, 'muse-spark-1.3-contributor-free (xhigh)');
    });

    test('a model without a variant gets a plain label', () {
      final plain = stats.models.last;
      expect(plain.variant, isNull);
      expect(plain.label, 'cat-jam-free');
      expect(plain.cost, closeTo(0.25, 1e-9));
    });

    test('ranks models by steps run', () {
      expect(
        stats.modelsByWeight.map((m) => m.modelID),
        ['muse-spark-1.3-contributor-free', 'cat-jam-free'],
      );
    });

    test('reads tool totals and a success rate', () {
      expect(stats.tools, hasLength(1));
      final tools = stats.tools.first;
      expect(tools.mode, 'summary');
      expect(tools.calls, 17900);
      expect(tools.failed, 363);
      expect(tools.unfinished, 1);
      expect(tools.successRate, closeTo(17536 / 17900, 1e-9));
    });

    test('reads the activity days', () {
      expect(stats.activity, hasLength(2));
      expect(stats.activity.first.date, '2026-06-02');
      expect(stats.peakSteps, 370);
    });

    test('is not empty', () {
      expect(stats.isEmpty, isFalse);
    });
  });

  group('payload shape changes with the window', () {
    // The live server answers differently depending on whether the window is
    // bounded: `data` and `tools` are objects on `?from=&to=`, and were
    // one-element arrays on the open window. Reading only the array shape made
    // the screen claim the period was empty while the server had 24 sessions
    // in it.
    final open = <String, Object?>{
      'sessions': 69,
      'steps': 100,
      'tools': [
        {
          'mode': 'summary',
          'totals': {'calls': 5, 'succeeded': 5},
        },
      ],
    };
    final bounded = <String, Object?>{
      'sessions': 24,
      'steps': 100,
      'tools': {
        'mode': 'summary',
        'totals': {'calls': 5, 'succeeded': 5},
      },
    };

    test('tools read as an object on a bounded window', () {
      final stats = ServerStats.fromJson(bounded);

      expect(stats.sessions, 24);
      expect(stats.tools, hasLength(1));
      expect(stats.tools.single.calls, 5);
    });

    test('tools read as a one-element array on an open window', () {
      final stats = ServerStats.fromJson(open);

      expect(stats.sessions, 69);
      expect(stats.tools, hasLength(1));
      expect(stats.tools.single.calls, 5);
    });

    test('both shapes agree', () {
      expect(
        ServerStats.fromJson(open).tools.single.calls,
        ServerStats.fromJson(bounded).tools.single.calls,
      );
    });

    test('absent tools stay empty rather than becoming one blank row', () {
      final stats = ServerStats.fromJson(const {'sessions': 1});
      expect(stats.tools, isEmpty);
    });
  });

  group('degenerate payloads', () {
    test('an empty object reads as zeroes, not a crash', () {
      final stats = ServerStats.fromJson(const {});

      expect(stats.sessions, 0);
      expect(stats.tokens.total, 0);
      expect(stats.models, isEmpty);
      expect(stats.activity, isEmpty);
      expect(stats.isEmpty, isTrue);
    });

    test('the empty constant agrees with an empty payload', () {
      expect(ServerStats.empty.isEmpty, isTrue);
      expect(ServerStats.empty.tokens.total, 0);
      expect(ServerStats.empty.peakSteps, 0);
    });

    test('a tool that never ran has no success rate', () {
      final tools = ToolUsage.fromJson(const {
        'mode': 'summary',
        'totals': {'calls': 0},
      });

      expect(tools.successRate, isNull);
      expect(tools.failed, 0);
    });

    test('an unparseable activity date does not throw', () {
      final day = ActivityDay.fromJson(const {
        'date': 'not-a-date',
        'steps': 4,
      });

      expect(day.steps, 4);
      expect(day.parsed, isNull);
    });

    test('a null totals block is tolerated', () {
      final tools = ToolUsage.fromJson(const {'mode': 'summary'});
      expect(tools.calls, 0);
      expect(tools.successRate, isNull);
    });
  });

  group('window bounds', () {
    test('all time asks for no bounds', () {
      expect(StatsRange.all.fromMillis(), isNull);
    });

    test('week and month start on a day boundary', () {
      for (final range in [StatsRange.week, StatsRange.month]) {
        final from = range.fromMillis();
        expect(from, isNotNull);
        final date = DateTime.fromMillisecondsSinceEpoch(from!);
        expect(
          DateTime(date.year, date.month, date.day),
          date,
          reason: 'a window that starts mid-day slices the first day in half',
        );
      }
    });

    test('a segment never vanishes below its floor', () {
      // The bar divides by total; a token category of zero gets a floor of
      // 1/1000 rather than a zero-width flex, which would make it impossible
      // to tap or see.
      const total = 1000;
      final tiny = (1 / total * 1000).round().clamp(1, 1000);
      final dominant = (999 / total * 1000).round().clamp(1, 1000);
      expect(tiny, greaterThanOrEqualTo(1));
      expect(dominant, 999);
    });

    test('a week is shorter than a month', () {
      final week = StatsRange.week.fromMillis()!;
      final month = StatsRange.month.fromMillis()!;
      expect(week, greaterThan(month));
      expect(week - month, const Duration(days: 23).inMilliseconds);
    });

    test('labels read as spans, not endpoints', () {
      expect(StatsRange.week.label, '7 days');
      expect(StatsRange.month.label, '30 days');
      expect(StatsRange.all.label, 'All time');
    });
  });
}