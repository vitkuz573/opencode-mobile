/// Typed view models for `GET /api/experimental/session/stats`.
///
/// This is the server's own accounting of what happened on it: tokens spent,
/// steps run, days active. It is not the opencode.ai account balance - the
/// Console API exposes no usage or credit endpoint at all, so anything about
/// money on the account side stays in the web console. What this gives is real
/// consumption measured by the machine running the sessions.
///
/// Field names mirror `tool/openapi.json`.
library;

Map<String, Object?> _map(Object? v) =>
    v is Map ? v.cast<String, Object?>() : const <String, Object?>{};

List<Object?> _list(Object? v) => v is List ? v : const <Object?>[];

String? _str(Object? v) => v is String ? v : null;

int _int(Object? v) => v is num ? v.toInt() : 0;

/// Tool totals arrive as a bare object on a bounded window and as a one-element
/// array on an open one, so both are read.
List<ToolUsage> _tools(Object? value) {
  if (value is Map) {
    return [ToolUsage.fromJson(value.cast<String, Object?>())];
  }
  return _list(value)
      .map((e) => ToolUsage.fromJson(_map(e)))
      .toList(growable: false);
}

double _double(Object? v) => v is num ? v.toDouble() : 0;

/// Token counts split the way the server bills them.
class TokenBreakdown {
  const TokenBreakdown({
    required this.input,
    required this.output,
    required this.reasoning,
    required this.cacheRead,
    required this.cacheWrite,
  });

  factory TokenBreakdown.fromJson(Map<String, Object?> json) {
    final cache = _map(json['cache']);
    return TokenBreakdown(
      input: _int(json['input']),
      output: _int(json['output']),
      reasoning: _int(json['reasoning']),
      cacheRead: _int(cache['read']),
      cacheWrite: _int(cache['write']),
    );
  }

  final int input;
  final int output;
  final int reasoning;
  final int cacheRead;
  final int cacheWrite;

  /// Everything that went over the wire, cache included.
  int get total =>
      input + output + reasoning + cacheRead + cacheWrite;

  /// Only what was actually generated, which is the number people mean by
  /// "how much did the model write".
  int get generated => output + reasoning;
}

/// Steps run with one model, optionally at one reasoning effort.
class ModelUsage {
  const ModelUsage({
    required this.modelID,
    required this.providerID,
    required this.variant,
    required this.steps,
    required this.tokens,
    required this.cost,
  });

  factory ModelUsage.fromJson(Map<String, Object?> json) {
    final model = _map(json['model']);
    return ModelUsage(
      modelID: _str(model['id']) ?? '',
      providerID: _str(model['providerID']) ?? '',
      variant: _str(model['variant']),
      steps: _int(json['steps']),
      tokens: TokenBreakdown.fromJson(_map(json['tokens'])),
      cost: _double(json['cost']),
    );
  }

  final String modelID;
  final String providerID;
  final String? variant;
  final int steps;
  final TokenBreakdown tokens;
  final double cost;

  String get key => '$providerID/$modelID';

  String get label => variant == null || variant!.isEmpty ? modelID : '$modelID ($variant)';
}

/// Tool calls, aggregated the way the server aggregates them.
class ToolUsage {
  const ToolUsage({
    required this.mode,
    required this.calls,
    required this.succeeded,
    required this.failed,
    required this.unfinished,
  });

  factory ToolUsage.fromJson(Map<String, Object?> json) {
    final totals = _map(json['totals']);
    return ToolUsage(
      mode: _str(json['mode']) ?? 'summary',
      calls: _int(totals['calls']),
      succeeded: _int(totals['succeeded']),
      failed: _int(totals['failed']),
      unfinished: _int(totals['unfinished']),
    );
  }

  final String mode;
  final int calls;
  final int succeeded;
  final int failed;
  final int unfinished;

  /// Share of calls that finished cleanly, or null when nothing ran.
  double? get successRate =>
      calls == 0 ? null : succeeded / calls;
}

/// Steps run on one calendar day.
class ActivityDay {
  const ActivityDay({required this.date, required this.steps});

  /// A day the server reported, e.g. `2026-06-02`.
  factory ActivityDay.fromJson(Map<String, Object?> json) =>
      ActivityDay(
        date: _str(json['date']) ?? '',
        steps: _int(json['steps']),
      );

  final String date;
  final int steps;

  DateTime? get parsed =>
      date.isEmpty ? null : DateTime.tryParse(date);
}

/// The whole payload. The endpoint answers with a single-element list; the
/// client unwraps it so callers get the object directly.
class ServerStats {
  const ServerStats({
    required this.from,
    required this.to,
    required this.sessions,
    required this.subagents,
    required this.prompts,
    required this.steps,
    required this.tokens,
    required this.cost,
    required this.activeDays,
    required this.streak,
    required this.activity,
    required this.models,
    required this.tools,
  });

  /// An empty result, so the UI can render zeroes instead of nothing.
  static const empty = ServerStats(
    from: 0,
    to: 0,
    sessions: 0,
    subagents: 0,
    prompts: 0,
    steps: 0,
    tokens: TokenBreakdown(
      input: 0,
      output: 0,
      reasoning: 0,
      cacheRead: 0,
      cacheWrite: 0,
    ),
    cost: 0,
    activeDays: 0,
    streak: 0,
    activity: [],
    models: [],
    tools: [],
  );

  factory ServerStats.fromJson(Map<String, Object?> json) {
    final range = _map(json['range']);
    return ServerStats(
      from: _int(range['from']),
      to: _int(range['to']),
      sessions: _int(json['sessions']),
      subagents: _int(json['subagents']),
      prompts: _int(json['prompts']),
      steps: _int(json['steps']),
      tokens: TokenBreakdown.fromJson(_map(json['tokens'])),
      cost: _double(json['cost']),
      activeDays: _int(json['activeDays']),
      streak: _int(json['streak']),
      activity: _list(json['activity'])
          .map((e) => ActivityDay.fromJson(_map(e)))
          .toList(growable: false),
      models: _list(json['models'])
          .map((e) => ModelUsage.fromJson(_map(e)))
          .toList(growable: false),
      tools: _tools(json['tools']),
    );
  }

  final int from;
  final int to;
  final int sessions;
  final int subagents;
  final int prompts;
  final int steps;
  final TokenBreakdown tokens;
  final double cost;
  final int activeDays;
  final int streak;
  final List<ActivityDay> activity;
  final List<ModelUsage> models;
  final List<ToolUsage> tools;

  bool get isEmpty => sessions == 0 && prompts == 0 && steps == 0;

  /// Models ordered the way someone reviewing spending wants them: most steps
  /// first, which is also roughly most tokens first.
  List<ModelUsage> get modelsByWeight {
    final sorted = [...models]
      ..sort((a, b) => b.steps.compareTo(a.steps));
    return sorted;
  }

  /// The busiest day in the range, for scaling the activity bars.
  int get peakSteps {
    var peak = 0;
    for (final day in activity) {
      if (day.steps > peak) peak = day.steps;
    }
    return peak;
  }
}

/// Window to report on. `all` leaves the bounds off and lets the server use
/// everything it has.
enum StatsRange {
  week('7 days'),
  month('30 days'),
  all('All time');

  const StatsRange(this.label);

  final String label;

  /// Start of the window, or null for everything.
  int? fromMillis() {
    final days = switch (this) {
      StatsRange.week => 7,
      StatsRange.month => 30,
      StatsRange.all => null,
    };
    if (days == null) return null;
    final end = DateTime.now();
    return DateTime(
      end.year,
      end.month,
      end.day,
    ).subtract(Duration(days: days - 1)).millisecondsSinceEpoch;
  }
}