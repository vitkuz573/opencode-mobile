/// In-memory log the user can read, filter and share from inside the app.
///
/// `debugPrint` is the right tool while developing and the wrong one here: its
/// output is gone by the time a user can describe a problem, and it never
/// reaches them. Anything worth reporting to a bug has to be somewhere the
/// person holding the phone can get at.
///
/// Secrets do not go in. Credentials live in the Keystore and are never passed
/// to a logger; the only host-level detail recorded is an address the person
/// typed themselves.
library;

import 'dart:collection';

/// Severity, ordered so a threshold can be compared numerically.
enum LogLevel {
  debug(0, 'Debug'),
  info(1, 'Info'),
  warn(2, 'Warning'),
  error(3, 'Error');

  const LogLevel(this.rank, this.label);

  final int rank;
  final String label;

  bool operator >=(LogLevel other) => rank >= other.rank;

  bool operator <(LogLevel other) => rank < other.rank;

  bool operator >(LogLevel other) => rank > other.rank;
}

/// One line in the log.
class LogEntry {
  LogEntry({
    required this.level,
    required this.tag,
    required this.message,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  final LogLevel level;
  final String tag;
  final String message;
  final DateTime at;

  /// One line: `14:03:22.481  INFO  api  200 GET /api/session`
  String get formatted =>
      '${_two(at.hour)}:${_two(at.minute)}:${_two(at.second)}.'
      '${at.millisecond.toString().padLeft(3, '0')}  '
      '${level.label.toUpperCase().padRight(5)}  '
      '${tag.padRight(8)}  $message';

  static String _two(int value) => value.toString().padLeft(2, '0');

  @override
  String toString() => formatted;
}

/// A bounded, newest-first log.
///
/// Bounded because a session's event stream can produce thousands of lines and
/// an unbounded buffer on a phone is a slow way to run out of memory.
class AppLog {
  AppLog({this.capacity = 500});

  final int capacity;
  final ListQueue<LogEntry> _entries = ListQueue();

  List<LogEntry> get entries => List.unmodifiable(_entries);

  int get length => _entries.length;

  /// Entries at or above [level], newest first.
  List<LogEntry> filtered(LogLevel level) =>
      _entries.where((entry) => entry.level >= level).toList(growable: false);

  /// Newest first, and filtered by [level] and a case-insensitive [search]
  /// over the tag and the message.
  List<LogEntry> query({
    LogLevel level = LogLevel.debug,
    String search = '',
  }) {
    final needle = search.trim().toLowerCase();
    return _entries.where((entry) {
      if (!(entry.level >= level)) return false;
      if (needle.isEmpty) return true;
      return entry.tag.toLowerCase().contains(needle) ||
          entry.message.toLowerCase().contains(needle);
    }).toList(growable: false);
  }

  void add(LogEntry entry) {
    if (capacity <= 0) return;
    _entries.addLast(entry);
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
  }

  void log(
    LogLevel level,
    String tag,
    String message,
  ) => add(LogEntry(level: level, tag: tag, message: message));

  void debug(String tag, String message) => log(LogLevel.debug, tag, message);

  void info(String tag, String message) => log(LogLevel.info, tag, message);

  void warn(String tag, String message) => log(LogLevel.warn, tag, message);

  void error(String tag, String message) =>
      log(LogLevel.error, tag, message);

  void clear() => _entries.clear();

  /// The whole log as one block of text, for sharing in a bug report.
  String dump() =>
      _entries.map((entry) => entry.formatted).join('\n');

  /// Approximate on-disk size if the log were written out, shown in settings.
  String get prettySize {
    final bytes = dump().length;
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}