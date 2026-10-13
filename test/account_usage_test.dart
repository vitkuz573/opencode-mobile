import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/data/account_usage.dart';

void main() {
  // Real capture of GET /api/v2/usage/export?range=30d on 2026-10-13, the
  // first four rows exactly as the Console sent them.
  const header =
      'day,user_type,user_id,user_name,provider,model,requests,'
      'input_tokens,output_tokens,cache_read_tokens,cache_write_5m_tokens,'
      'cache_write_1h_tokens,cost_micro_cents';

  const csv = '$header\n'
      '2026-10-13,member,acc_01EXAMPLEACCOUNT00001,someone@example.com,'
      'opencode-go,muse-spark-1.3-contributor,419,1240760,115009,232647170,0,0,61237207\n'
      '2026-10-13,service_account,svcacct_01EXAMPLESERVICEACC1,my,'
      'opencode-go,claude-haiku-5-5,10,36,608,36651,74050,0,993038\n'
      '2026-10-12,member,acc_01EXAMPLEACCOUNT00001,someone@example.com,'
      'opencode-go,deepseek-v4.1-flash,0,10,0,0,0,0,5000000';

  group('csv parsing', () {
    final usage = AccountUsage.parseCsv(csv);

    test('reads every row', () {
      expect(usage.rows, hasLength(3));
      expect(usage.isEmpty, isFalse);
    });

    test('reads the columns of a member row', () {
      final row = usage.rows.first;
      expect(row.day, '2026-10-13');
      expect(row.userType, 'member');
      expect(row.userId, 'acc_01EXAMPLEACCOUNT00001');
      expect(row.userName, 'someone@example.com');
      expect(row.provider, 'opencode-go');
      expect(row.model, 'muse-spark-1.3-contributor');
      expect(row.requests, 419);
      expect(row.inputTokens, 1240760);
      expect(row.outputTokens, 115009);
      expect(row.cacheReadTokens, 232647170);
      expect(row.costUnits, 61237207);
      expect(row.isMember, isTrue);
      expect(row.modelKey, 'opencode-go/muse-spark-1.3-contributor');
      expect(row.accountLabel, 'someone@example.com');
    });

    test('a service account row is not a member', () {
      final row = usage.rows[1];
      expect(row.isMember, isFalse);
      expect(row.userType, 'service_account');
      expect(row.cacheWriteTokens, 74050, reason: 'both write tiers add up');
      expect(row.accountLabel, 'my (service_account)');
    });

    test('a row is kept even with no requests but real spend', () {
      // Free-tier usage can cost nothing and do nothing; dropping such rows
      // would silently lose days from the chart.
      final row = usage.rows[2];
      expect(row.requests, 0);
      expect(row.costUnits, 5000000);
      expect(row.tokensTotal, 10);
    });

    test('a fully empty row is dropped', () {
      const withJunk = '$header\n'
          '2026-10-13,member,acc_1,a@b.c,opencode-go,x,0,0,0,0,0,0,0';
      final parsed = AccountUsage.parseCsv(withJunk);
      expect(parsed.rows, isEmpty);
      expect(parsed.isEmpty, isTrue);
    });

    test('tolerates windows line endings and a trailing newline', () {
      final crlf = AccountUsage.parseCsv(csv.replaceAll('\n', '\r\n'));
      expect(crlf.rows, hasLength(3));
      expect(crlf.requests, 429);
    });

    test('handles quoted fields containing commas', () {
      const quoted = '$header\n'
          '2026-10-13,member,acc_1,"Lastname, First",opencode-go,x,5,1,1,1,0,0,100';
      final parsed = AccountUsage.parseCsv(quoted);
      expect(parsed.rows.single.userName, 'Lastname, First');
      expect(parsed.rows.single.requests, 5);
      expect(parsed.rows.single.costUnits, 100);
    });

    test('an escaped quote inside a field survives', () {
      const quoted = '$header\n'
          '2026-10-13,member,acc_1,"a ""b"" c",opencode-go,x,5,1,1,1,0,0,100';
      final parsed = AccountUsage.parseCsv(quoted);
      expect(parsed.rows.single.userName, 'a "b" c');
    });

    test('reordered columns still parse by name', () {
      const reordered =
          'requests,day,cost_micro_cents,user_type,user_id,user_name,provider,'
          'model,input_tokens,output_tokens,cache_read_tokens,'
          'cache_write_5m_tokens,cache_write_1h_tokens\n'
          '7,2026-10-13,250,member,acc_1,a@b.c,opencode-go,x,10,20,30,1,2';
      final parsed = AccountUsage.parseCsv(reordered);
      final row = parsed.rows.single;
      expect(row.requests, 7);
      expect(row.costUnits, 250);
      expect(row.cacheWriteTokens, 3);
    });

    test('garbage yields an empty result rather than throwing', () {
      expect(AccountUsage.parseCsv('').isEmpty, isTrue);
      expect(AccountUsage.parseCsv('not,a,csv').isEmpty, isTrue);
      expect(
        AccountUsage.parseCsv('unrelated,header\n1,2').isEmpty,
        isTrue,
        reason: 'no day/requests columns means this is not the export',
      );
    });
  });

  group('totals', () {
    final usage = AccountUsage.parseCsv(csv);

    test('sum requests, tokens and money across rows', () {
      expect(usage.requests, 429);
      expect(usage.costUnits, 61237207 + 993038 + 5000000);
      expect(usage.costUsd, closeTo(0.67230245, 1e-9));
      expect(usage.inputTokens, 1240760 + 36 + 10);
      expect(usage.outputTokens, 115009 + 608);
      expect(usage.cacheReadTokens, 232647170 + 36651);
      expect(usage.cacheWriteTokens, 74050);
    });

    test('a token row totals every segment', () {
      final row = usage.rows.first;
      expect(
        row.tokensTotal,
        row.inputTokens + row.outputTokens + row.cacheReadTokens,
      );
    });

    test('the cost column is 1e-8 dollars despite its name', () {
      // `cost_micro_cents` reads as 1e-6 per unit, which would make this
      // $0.99 for 74,050 cache-write tokens on a model priced at $0.125 per
      // million. The price list says $0.00993, which is the raw value at 1e-8.
      // Taking the header at face value overstated the bill 100x.
      const cacheWriteRow = '2026-10-13,service_account,svcacct_1,my,'
          'opencode-go,claude-haiku-5-5,10,36,608,36651,74050,0,993038';

      final parsed = AccountUsage.parseCsv(
        '$header\n$cacheWriteRow',
      );

      const priceCacheWrite = 0.125;
      const priceCacheRead = 0.01;
      const priceInput = 0;
      const priceOutput = 0.5;
      final expectedUsd =
          (36 / 1e6 * priceInput) +
          (608 / 1e6 * priceOutput) +
          (36651 / 1e6 * priceCacheRead) +
          (74050 / 1e6 * priceCacheWrite);

      expect(costUnitsPerDollar, 100000000);
      expect(
        parsed.rows.single.costUsd,
        closeTo(expectedUsd, 1e-5),
        reason: 'must agree with the published price list',
      );
      // And explicitly not the 1e-6 reading.
      expect(
        parsed.rows.single.costUsd,
        isNot(closeTo(parsed.rows.single.costUnits / 1e6, 1e-3)),
      );
    });

    test('a dollar is a hundred million units, not a million', () {
      expect(costUnitsPerDollar, isNot(1000000));
      expect(100000000 / costUnitsPerDollar, 1.0);
    });
  });

  group('grouping', () {
    final usage = AccountUsage.parseCsv(csv);

    test('days come out oldest first', () {
      expect(usage.byDay.map((d) => d.day), [
        '2026-10-12',
        '2026-10-13',
      ]);
    });

    test('a day folds its rows together', () {
      final today = usage.byDay.last;
      expect(today.requests, 429);
      expect(today.costUnits, 61237207 + 993038);
    });

    test('day counts and parsable dates', () {
      expect(usage.days, 2);
      expect(usage.byDay.last.parsed, DateTime(2026, 10, 13));
    });

    test('models rank by requests', () {
      final models = usage.byModel;
      expect(models.first.label, 'opencode-go/muse-spark-1.3-contributor');
      expect(models.first.requests, 419);
      expect(models.last.label, 'opencode-go/deepseek-v4.1-flash');
    });

    test('accounts rank by cost, not requests', () {
      // The zero-request row still cost the most, and sorting by requests
      // would have buried it.
      final accounts = usage.byAccount;
      expect(accounts.first.label, 'someone@example.com');
      expect(accounts.first.costUsd, closeTo(0.66237207, 1e-9));
      expect(accounts.last.label, 'my (service_account)');
    });

    test('members and service accounts are counted apart', () {
      final kinds = usage.byMember;
      expect(kinds.map((k) => k.label), containsAll(['member', 'service_account']));
      expect(kinds.first.label, 'member');
    });

    test('counts of distinct things', () {
      expect(usage.models, 3);
      expect(usage.accounts, 2);
    });

    test('a snapshot carries when it was taken', () {
      final stamp = DateTime(2026, 10, 13, 12, 30);
      final snap = AccountUsage(const [], fetchedAt: stamp);

      expect(snap.fetchedAt, stamp);
      expect(AccountUsage.empty.fetchedAt, isNull);
    });

    test('the empty constant is safe to render', () {
      const empty = AccountUsage.empty;
      expect(empty.isEmpty, isTrue);
      expect(empty.requests, 0);
      expect(empty.costUsd, 0);
      expect(empty.byDay, isEmpty);
      expect(empty.byModel, isEmpty);
      expect(empty.byAccount, isEmpty);
    });
  });

  group('range', () {
    test('carries the wire value the Console expects', () {
      expect(AccountUsageRange.week.wire, '7d');
      expect(AccountUsageRange.month.wire, '30d');
      expect(AccountUsageRange.quarter.wire, '90d');
    });

    test('labels read as spans', () {
      expect(AccountUsageRange.quarter.label, '90 days');
    });
  });
}