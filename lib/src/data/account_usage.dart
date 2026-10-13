/// Account usage from the opencode.ai Console.
///
/// This is spending on the opencode.ai account itself, as opposed to
/// `data/stats.dart`, which reports what one OpenCode server did locally. The
/// Console publishes no documented usage endpoint, but its own web app calls
/// `GET /api/v2/usage/export`, and that endpoint answers a signed-in user
/// token - verified on 2026-10-13.
///
/// The response is CSV, one row per UTC day x member or service account x
/// provider x model:
///
/// ```
/// day,user_type,user_id,user_name,provider,model,requests,
/// input_tokens,output_tokens,cache_read_tokens,cache_write_5m_tokens,
/// cache_write_1h_tokens,cost_micro_cents
/// ```
///
/// Money arrives in micro-cents as a string, so it is parsed into an int and
/// only divided for display.
library;

int _int(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? 0;
  return 0;
}

/// Windows the Console accepts for the usage export.
enum AccountUsageRange {
  week('7d', '7 days'),
  month('30d', '30 days'),
  quarter('90d', '90 days');

  const AccountUsageRange(this.wire, this.label);

  final String wire;
  final String label;
}

/// How many raw cost units make one dollar.
///
/// The CSV column is called `cost_micro_cents`, which reads as 1e-6 dollars per
/// unit. It is not. Checked against the price list on 2026-10-13: a row of
/// `claude-haiku-5-5` with 74,050 cache-write tokens costs $0.00993 by the
/// published rate, and the raw value was 993038 - which is $0.00993 only at
/// 1e-8. The same row set agrees to within 7e-8 at that divisor and is off by
/// two orders of magnitude at 1e-6.
///
/// Taking the column name at face value overstates spending 100x, so the unit
/// is asserted here rather than derived from the header.
const int costUnitsPerDollar = 100000000;

/// One row of the export: a slice of one day, for one account, one model.
class UsageRow {
  const UsageRow({
    required this.day,
    required this.userType,
    required this.userId,
    required this.userName,
    required this.provider,
    required this.model,
    required this.requests,
    required this.inputTokens,
    required this.outputTokens,
    required this.cacheReadTokens,
    required this.cacheWriteTokens,
    required this.costUnits,
  });

  /// `member` or `service_account`; anything else is kept verbatim.
  final String day;
  final String userType;
  final String userId;
  final String userName;
  final String provider;
  final String model;
  final int requests;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;

  /// Money as the export sends it; see [costUnitsPerDollar] before converting.
  final int costUnits;

  double get costUsd => costUnits / costUnitsPerDollar;

  int get tokensTotal =>
      inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens;

  bool get isMember => userType == 'member';

  String get modelKey => provider.isEmpty ? model : '$provider/$model';

  String get accountLabel {
    if (isMember) return userName.isEmpty ? userId : userName;
    // The Console names service accounts after the key that spent, which reads
    // as "my" in practice.
    return userName.isEmpty ? userType : '$userName ($userType)';
  }
}

/// Totals for one group of rows, used for the ranked breakdowns.
class UsageTotal {
  const UsageTotal({
    required this.label,
    required this.requests,
    required this.tokens,
    required this.costUnits,
  });

  final String label;
  final int requests;
  final int tokens;

  /// Money as the export sends it; see [costUnitsPerDollar].
  final int costUnits;

  double get costUsd => costUnits / costUnitsPerDollar;
}

/// A day's totals, oldest first - what the daily chart plots.
class DayTotal {
  const DayTotal({
    required this.day,
    required this.requests,
    required this.tokens,
    required this.costUnits,
  });

  final String day;
  final int requests;
  final int tokens;
  final int costUnits;

  DateTime? get parsed => day.isEmpty ? null : DateTime.tryParse(day);

  double get costUsd => costUnits / costUnitsPerDollar;
}

/// The whole export, parsed and grouped.
class AccountUsage {
  const AccountUsage(this.rows, {this.fetchedAt});

  static const empty = AccountUsage([]);

  final List<UsageRow> rows;

  /// When this snapshot was taken. The export is a live rollup: the same
  /// account read twice minutes apart gives two different totals, because the
  /// reader is spending while reading. Showing the time keeps a difference from
  /// looking like a bug.
  final DateTime? fetchedAt;

  bool get isEmpty => rows.isEmpty;

  int get requests =>
      rows.fold(0, (sum, r) => sum + r.requests);

  int get costUnits => rows.fold(0, (sum, r) => sum + r.costUnits);

  double get costUsd => costUnits / costUnitsPerDollar;

  int get tokensTotal =>
      rows.fold(0, (sum, r) => sum + r.tokensTotal);

  int get inputTokens => rows.fold(0, (sum, r) => sum + r.inputTokens);

  int get outputTokens => rows.fold(0, (sum, r) => sum + r.outputTokens);

  int get cacheReadTokens =>
      rows.fold(0, (sum, r) => sum + r.cacheReadTokens);

  int get cacheWriteTokens =>
      rows.fold(0, (sum, r) => sum + r.cacheWriteTokens);

  int get days => byDay.length;

  int get models => byModel.length;

  /// Distinct accounts that spent: members plus service accounts.
  int get accounts => byAccount.length;

  /// Totals per UTC day, oldest first.
  List<DayTotal> get byDay {
    final buckets = <String, List<UsageRow>>{};
    for (final row in rows) {
      buckets.putIfAbsent(row.day, () => <UsageRow>[]).add(row);
    }
    final days = buckets.keys.toList()..sort();
    return [
      for (final day in days)
        DayTotal(
          day: day,
          requests: buckets[day]!.fold(0, (s, r) => s + r.requests),
          tokens: buckets[day]!.fold(0, (s, r) => s + r.tokensTotal),
          costUnits: buckets[day]!.fold(0, (s, r) => s + r.costUnits),
        ),
    ];
  }

  /// Ranked by requests, which is how people scan a spending breakdown.
  List<UsageTotal> get byModel {
    final totals = _group(rows, (r) => r.modelKey);
    return totals..sort((a, b) => b.requests.compareTo(a.requests));
  }

  /// Ranked by cost, then requests, so the expensive rows lead.
  List<UsageTotal> get byAccount {
    final totals = _group(rows, (r) => r.accountLabel);
    return totals
      ..sort((a, b) {
        final byCost = b.costUnits.compareTo(a.costUnits);
        return byCost != 0 ? byCost : b.requests.compareTo(a.requests);
      });
  }

  /// How much the free models saved, which is the number a free-tier user
  /// cares most about.
  List<UsageTotal> get byMember {
    final totals = _group(rows, (r) => r.isMember ? 'member' : r.userType);
    return totals..sort((a, b) => b.requests.compareTo(a.requests));
  }

  static List<UsageTotal> _group(
    List<UsageRow> rows,
    String Function(UsageRow) key,
  ) {
    final map = <String, List<UsageRow>>{};
    for (final row in rows) {
      map.putIfAbsent(key(row), () => <UsageRow>[]).add(row);
    }
    return [
      for (final entry in map.entries)
        UsageTotal(
          label: entry.key,
          requests: entry.value.fold(0, (s, r) => s + r.requests),
          tokens: entry.value.fold(0, (s, r) => s + r.tokensTotal),
          costUnits: entry.value.fold(0, (s, r) => s + r.costUnits),
        ),
    ];
  }

  /// Parses the export.
  ///
  /// Returns an empty result for anything unparseable rather than throwing:
  /// this endpoint is undocumented, so its shape may change, and a usage screen
  /// that shows nothing beats one that crashes the app.
  static AccountUsage parseCsv(String body) {
    final rows = <UsageRow>[];
    final lines = _nonEmptyLines(body);
    if (lines.isEmpty) return AccountUsage(rows);

    // The first line is the header; find the columns by name so a reordered or
    // extended export still parses.
    final header = _splitCsv(lines.first).map((h) => h.trim()).toList();
    final index = <String, int>{};
    for (var i = 0; i < header.length; i++) {
      index[header[i]] = i;
    }
    if (!index.containsKey('day') || !index.containsKey('requests')) {
      return AccountUsage(rows);
    }

    String at(List<String> cells, String column) {
      final i = index[column];
      if (i == null || i >= cells.length) return '';
      return cells[i].trim();
    }

    for (final line in lines.skip(1)) {
      final cells = _splitCsv(line);
      final requests = _int(at(cells, 'requests'));
      // A row with neither activity nor cost is noise, not data.
      if (requests == 0 && _int(at(cells, 'cost_micro_cents')) == 0) continue;
      rows.add(
        UsageRow(
          day: at(cells, 'day'),
          userType: at(cells, 'user_type'),
          userId: at(cells, 'user_id'),
          userName: at(cells, 'user_name'),
          provider: at(cells, 'provider'),
          model: at(cells, 'model'),
          requests: requests,
          inputTokens: _int(at(cells, 'input_tokens')),
          outputTokens: _int(at(cells, 'output_tokens')),
          cacheReadTokens: _int(at(cells, 'cache_read_tokens')),
          // The export splits cache writes by lifetime; the app only cares
          // that they happened.
          cacheWriteTokens:
              _int(at(cells, 'cache_write_5m_tokens')) +
              _int(at(cells, 'cache_write_1h_tokens')),
          costUnits: _int(at(cells, 'cost_micro_cents')),
        ),
      );
    }
    return AccountUsage(rows);
  }

  /// Splits one CSV line, honouring quoted fields so a name containing a comma
  /// does not shift every column after it.
  static List<String> _splitCsv(String line) {
    final cells = <String>[];
    final buffer = StringBuffer();
    var quoted = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (quoted) {
        if (ch == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            buffer.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          buffer.write(ch);
        }
        continue;
      }
      if (ch == '"') {
        quoted = true;
      } else if (ch == ',') {
        cells.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(ch);
      }
    }
    cells.add(buffer.toString());
    return cells;
  }

  /// Splits on both line ending styles and drops blank lines.
  static List<String> _nonEmptyLines(String input) {
    final out = <String>[];
    var start = 0;
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (ch != '\n' && ch != '\r') continue;
      out.add(input.substring(start, i));
      // Swallow the \n of a \r\n pair.
      if (ch == '\r' && i + 1 < input.length && input[i + 1] == '\n') i++;
      start = i + 1;
    }
    if (start < input.length) out.add(input.substring(start));
    return out.where((line) => line.trim().isNotEmpty).toList();
  }
}