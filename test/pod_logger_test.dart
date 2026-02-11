import 'package:flutter_test/flutter_test.dart';
import 'package:metric_athlete_pod_ble/utils/pod_logger.dart';

void main() {
  group('PodLogger', () {
    setUp(() {
      PodLogger.clear();
      PodLogger.onLog = null;
    });

    test('stores log entries', () {
      PodLogger.info('ble', 'Connected');
      PodLogger.warn('sync', 'Retry needed');
      expect(PodLogger.entries.length, 2);
    });

    test('entries have correct fields', () {
      PodLogger.error('protocol', 'Parse failed', detail: 'offset 42');
      final entry = PodLogger.entries.first;
      expect(entry.level, LogLevel.error);
      expect(entry.category, 'protocol');
      expect(entry.message, 'Parse failed');
      expect(entry.detail, 'offset 42');
      expect(entry.timestamp.year, greaterThanOrEqualTo(2025));
    });

    test('ring buffer caps at 500 entries', () {
      for (int i = 0; i < 600; i++) {
        PodLogger.debug('test', 'entry $i');
      }
      expect(PodLogger.entries.length, 500);
    });

    test('clear removes all entries', () {
      PodLogger.info('a', 'test');
      PodLogger.info('b', 'test');
      PodLogger.clear();
      expect(PodLogger.entries, isEmpty);
    });

    test('entriesForCategory filters correctly', () {
      PodLogger.info('ble', 'scan started');
      PodLogger.warn('sync', 'retry');
      PodLogger.error('ble', 'disconnect');
      final bleEntries = PodLogger.entriesForCategory('ble');
      expect(bleEntries.length, 2);
      expect(bleEntries.every((e) => e.category == 'ble'), true);
    });

    test('entriesAtLevel filters by severity', () {
      PodLogger.debug('a', 'low');
      PodLogger.info('a', 'medium');
      PodLogger.warn('a', 'high');
      PodLogger.error('a', 'critical');

      final warnings = PodLogger.entriesAtLevel(LogLevel.warn);
      expect(warnings.length, 2); // warn + error
      expect(warnings.every((e) => e.level.index >= LogLevel.warn.index), true);
    });

    test('onLog callback is invoked', () {
      final received = <PodLogEntry>[];
      PodLogger.onLog = (entry) => received.add(entry);

      PodLogger.info('ble', 'test');
      expect(received.length, 1);
      expect(received.first.message, 'test');
    });

    test('toString includes all fields', () {
      PodLogger.warn('sync', 'Slow download', detail: '45%');
      final str = PodLogger.entries.first.toString();
      expect(str, contains('WARN'));
      expect(str, contains('[sync]'));
      expect(str, contains('Slow download'));
      expect(str, contains('45%'));
    });
  });
}
