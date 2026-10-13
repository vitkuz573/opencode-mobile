import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/data/app_log.dart';

void main() {
  group('levels', () {
    test('are ordered so a threshold can be compared', () {
      expect(LogLevel.debug < LogLevel.info, isTrue);
      expect(LogLevel.info < LogLevel.warn, isTrue);
      expect(LogLevel.warn < LogLevel.error, isTrue);
    });

    test('the >= operator reads as "at least this severe"', () {
      expect(LogLevel.error >= LogLevel.info, isTrue);
      expect(LogLevel.debug >= LogLevel.info, isFalse);
      expect(LogLevel.info >= LogLevel.info, isTrue);
    });

    test('every level has a label for the picker', () {
      expect(
        LogLevel.values.map((level) => level.label),
        ['Debug', 'Info', 'Warning', 'Error'],
      );
    });
  });

  group('buffering', () {
    test('keeps what it is given', () {
      final log = AppLog(capacity: 10);
      log.info('net', 'connected');

      expect(log.length, 1);
      expect(log.entries.single.message, 'connected');
    });

    test('drops the oldest when full', () {
      // A session's event stream can outrun any buffer; an unbounded one on a
      // phone is a slow way to run out of memory.
      final log = AppLog(capacity: 3);
      for (var i = 0; i < 5; i++) {
        log.info('net', 'line $i');
      }

      expect(log.length, 3);
      expect(
        log.entries.map((e) => e.message),
        ['line 2', 'line 3', 'line 4'],
      );
    });

    test('a zero capacity logs nothing rather than throwing', () {
      final log = AppLog(capacity: 0);
      log.error('net', 'boom');
      expect(log.length, 0);
    });

    test('clear empties it', () {
      final log = AppLog();
      log.info('a', 'one');
      log.info('a', 'two');
      log.clear();

      expect(log.length, 0);
      expect(log.dump(), isEmpty);
    });
  });

  group('filtering', () {
    late AppLog log;

    setUp(() {
      log = AppLog()
        ..debug('net', 'sse payload')
        ..info('net', 'connected')
        ..warn('pairing', 'redirected')
        ..error('net', 'connect failed');
    });

    test('a threshold hides anything below it', () {
      expect(log.query(level: LogLevel.warn), hasLength(2));
      expect(log.query(level: LogLevel.error), hasLength(1));
      expect(log.query(), hasLength(4));
    });

    test('the filtered view matches the explicit getter', () {
      expect(log.query(level: LogLevel.warn), log.filtered(LogLevel.warn));
    });

    test('search covers the tag and the message', () {
      expect(log.query(search: 'pairing'), hasLength(1));
      expect(log.query(search: 'failed'), hasLength(1));
      expect(log.query(search: 'PAYLOAD'), hasLength(1),
          reason: 'search is case insensitive');
    });

    test('search and level combine', () {
      expect(log.query(level: LogLevel.error, search: 'net'), hasLength(1));
      expect(log.query(level: LogLevel.error, search: 'pairing'), isEmpty);
    });

    test('a blank or absent search returns everything at the level', () {
      expect(log.query(search: '   '), hasLength(4));
    });

    test('a search that matches nothing is empty, not everything', () {
      expect(log.query(search: 'nothing here'), isEmpty);
    });
  });

  group('formatting', () {
    test('a line carries time, level, tag and message', () {
      final entry = LogEntry(
        level: LogLevel.error,
        tag: 'net',
        message: 'connect failed',
        at: DateTime(2026, 10, 13, 9, 5, 3, 47),
      );

      expect(entry.formatted, contains('09:05:03.047'));
      expect(entry.formatted, contains('ERROR'));
      expect(entry.formatted, contains('net'));
      expect(entry.formatted, contains('connect failed'));
    });

    test('columns line up because the level is padded', () {
      final lines = [
        LogEntry(level: LogLevel.info, tag: 'net', message: 'a'),
        LogEntry(level: LogLevel.error, tag: 'net', message: 'b'),
      ].map((e) => e.formatted);

      expect(lines.first.length, lines.last.length);
    });

    test('the stamp is zero padded so a log can be read by eye', () {
      final entry = LogEntry(
        level: LogLevel.info,
        tag: 'net',
        message: 'x',
        at: DateTime(2026, 1, 2, 3, 4, 5, 6),
      );

      expect(entry.formatted, startsWith('03:04:05.006'));
    });

    test('the dump is one line per entry, newest last', () {
      final log = AppLog()
        ..info('a', 'first')
        ..info('b', 'second');

      final lines = log.dump().split('\n');
      expect(lines, hasLength(2));
      expect(lines.first, contains('first'));
      expect(lines.last, contains('second'));
    });

    test('the size reads as something a person can judge', () {
      final small = AppLog()..info('a', 'short');
      expect(small.prettySize, endsWith('B'));

      final large = AppLog();
      for (var i = 0; i < 300; i++) {
        large.info('net', 'a line of log text that adds up quickly $i');
      }
      expect(large.prettySize, endsWith('KB'));
    });

    test('an empty log has no size worth reporting', () {
      expect(AppLog().prettySize, '0 B');
    });
  });

  group('what gets logged', () {
    test('convenience helpers pick the level', () {
      final log = AppLog()
        ..debug('a', 'd')
        ..info('a', 'i')
        ..warn('a', 'w')
        ..error('a', 'e');

      expect(
        log.entries.map((e) => e.level),
        [
          LogLevel.debug,
          LogLevel.info,
          LogLevel.warn,
          LogLevel.error,
        ],
      );
    });

    test('the generic form matches the helpers', () {
      final viaHelper = AppLog()..warn('net', 'same');
      final viaGeneric = AppLog()..log(LogLevel.warn, 'net', 'same');

      expect(viaHelper.entries.single.level, viaGeneric.entries.single.level);
      expect(viaHelper.entries.single.message, viaGeneric.entries.single.message);
    });
  });
}