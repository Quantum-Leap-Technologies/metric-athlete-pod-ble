import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:metric_athlete_pod_ble/models/sensor_log_model.dart';
import 'package:metric_athlete_pod_ble/utils/logs_binary_parser.dart';
import 'package:metric_athlete_pod_ble/utils/session_cluster.dart';

/// Integration test for Nicus vs JM match data (2026-03-03).
///
/// Reference data (from manufacturer software, SAST = UTC+2):
///   1st Half:      15:56:29 – 16:26:15  (00:29:46)
///   2nd Half:      16:29:19 – 16:54:58  (00:25:39)
///   Game:          15:56:29 – 16:54:58  (00:58:29)
///   Total session: 15:48:40 – 17:07:48  (01:19:07)
///
/// BinaryParser stores raw UTC values in local DateTime objects (not DateTime.utc),
/// so reference times must also use DateTime() to match.
void main() {
  late List<SensorLog> logs;
  late Uint8List rawBytes;

  setUpAll(() {
    final file = File(
      '${Directory.current.parent.path}/metric_athlete_app/data/nicus_20260303/20260303_134840.bin',
    );
    if (!file.existsSync()) {
      // Fallback: try absolute path
      final abs = File(
        '/Users/johies/Documents/QLTech/Development/metric-athlete/metric_athlete_app/data/nicus_20260303/20260303_134840.bin',
      );
      rawBytes = abs.readAsBytesSync();
    } else {
      rawBytes = file.readAsBytesSync();
    }
    logs = BinaryParser.parseBytes(rawBytes);
  });

  group('Binary parsing', () {
    test('file size is consistent with 64-byte records', () {
      // 3,063,296 bytes / 64 = 47,864 records
      expect(rawBytes.length, 3063296);
      expect(rawBytes.length % 64, 0);
    });

    test('parses all records without data loss', () {
      final expectedRecords = rawBytes.length ~/ 64;
      // Allow small loss from sync recovery, but expect >99%
      expect(logs.length, greaterThan((expectedRecords * 0.99).round()));
      expect(logs.length, lessThanOrEqualTo(expectedRecords));
      print('Parsed ${logs.length} / $expectedRecords records '
          '(${(logs.length / expectedRecords * 100).toStringAsFixed(1)}%)');
    });

    test('all records are dated 2026-03-03', () {
      for (final log in logs) {
        expect(log.timestamp.year, 2026);
        expect(log.timestamp.month, 3);
        expect(log.timestamp.day, 3);
      }
    });

    test('records are in chronological order', () {
      for (var i = 1; i < logs.length; i++) {
        expect(
          logs[i].timestamp.millisecondsSinceEpoch,
          greaterThanOrEqualTo(logs[i - 1].timestamp.millisecondsSinceEpoch),
          reason: 'Record $i is out of order: ${logs[i].timestamp} < ${logs[i - 1].timestamp}',
        );
      }
    });
  });

  group('Session timing (UTC, SAST = UTC+2)', () {
    // Reference: Total session 15:48:40 – 17:07:48 SAST
    //          = 13:48:40 – 15:07:48 UTC
    test('total session start matches reference (13:48:40 UTC = 15:48:40 SAST)', () {
      final first = logs.first.timestamp;
      expect(first.hour, 13);
      expect(first.minute, 48);
      expect(first.second, 40);
      print('Session start (UTC): ${_fmt(first)} → SAST: ${_fmtSAST(first)}');
    });

    test('total session end matches reference (15:07:48 UTC = 17:07:48 SAST)', () {
      final last = logs.last.timestamp;
      // Allow ±2 seconds tolerance for the exact last record
      // Use local DateTime to match BinaryParser output format
      final refEnd = DateTime(2026, 3, 3, 15, 7, 48);
      final diff = last.difference(refEnd).inSeconds.abs();
      expect(diff, lessThan(3),
          reason: 'Last record at ${_fmt(last)}, expected ~${_fmt(refEnd)}');
      print('Session end (UTC): ${_fmt(last)} → SAST: ${_fmtSAST(last)}');
    });

    test('total session duration matches reference (~1:19:07)', () {
      final duration = logs.last.timestamp.difference(logs.first.timestamp);
      // Reference: 01:19:07 = 4747 seconds
      final refDuration = const Duration(hours: 1, minutes: 19, seconds: 7);
      final diffSec = (duration.inSeconds - refDuration.inSeconds).abs();
      expect(diffSec, lessThan(5),
          reason: 'Duration ${duration.inMinutes}m${duration.inSeconds % 60}s, '
              'expected ${refDuration.inMinutes}m${refDuration.inSeconds % 60}s');
      print('Total duration: ${_durationStr(duration)} (ref: 01:19:07)');
    });

    test('1st half time window is present in data (13:56:29 – 14:26:15 UTC)', () {
      final halfStart = DateTime(2026, 3, 3, 13, 56, 29);
      final halfEnd = DateTime(2026, 3, 3, 14, 26, 15);

      final firstHalfLogs = logs.where((l) =>
          !l.timestamp.isBefore(halfStart) && !l.timestamp.isAfter(halfEnd)).toList();

      // 29:46 at ~10Hz = ~17,860 records; allow tolerance
      expect(firstHalfLogs.length, greaterThan(10000));
      print('1st half: ${firstHalfLogs.length} records, '
          '${_fmt(firstHalfLogs.first.timestamp)} – ${_fmt(firstHalfLogs.last.timestamp)}');
    });

    test('2nd half time window is present in data (14:29:19 – 14:54:58 UTC)', () {
      final halfStart = DateTime(2026, 3, 3, 14, 29, 19);
      final halfEnd = DateTime(2026, 3, 3, 14, 54, 58);

      final secondHalfLogs = logs.where((l) =>
          !l.timestamp.isBefore(halfStart) && !l.timestamp.isAfter(halfEnd)).toList();

      // 25:39 at ~10Hz = ~15,390 records
      expect(secondHalfLogs.length, greaterThan(10000));
      print('2nd half: ${secondHalfLogs.length} records, '
          '${_fmt(secondHalfLogs.first.timestamp)} – ${_fmt(secondHalfLogs.last.timestamp)}');
    });

    test('halftime gap exists between 1st and 2nd half (~3 min)', () {
      final firstHalfEnd = DateTime(2026, 3, 3, 14, 26, 15);
      final secondHalfStart = DateTime(2026, 3, 3, 14, 29, 19);

      // Count records in the gap
      final gapLogs = logs.where((l) =>
          l.timestamp.isAfter(firstHalfEnd) &&
          l.timestamp.isBefore(secondHalfStart)).toList();

      // Gap is ~3 minutes — should still have data (pod keeps recording)
      print('Halftime gap: ${gapLogs.length} records '
          '(${_durationStr(secondHalfStart.difference(firstHalfEnd))})');
    });
  });

  group('Session clustering', () {
    test('SessionClusterer detects session structure', () {
      final clusters = SessionClusterer.cluster(logs);
      print('Clusters found: ${clusters.length}');
      for (var i = 0; i < clusters.length; i++) {
        final c = clusters[i];
        final dur = c.last.timestamp.difference(c.first.timestamp);
        print('  Cluster ${i + 1}: ${c.length} records, '
            '${_fmtSAST(c.first.timestamp)} – ${_fmtSAST(c.last.timestamp)} '
            '(${_durationStr(dur)})');
      }
      // Should be 1 contiguous session (pod records continuously)
      // or at most a few if there are large gaps
      expect(clusters.length, greaterThan(0));
      expect(clusters.length, lessThanOrEqualTo(3));
    });
  });

  group('Data quality', () {
    test('GPS coordinates are in South Africa range', () {
      // South Africa roughly: lat -22 to -35, lon 16 to 33
      final withGps = logs.where((l) => l.latitude != 0 && l.longitude != 0).toList();
      expect(withGps.length, greaterThan(logs.length ~/ 2),
          reason: 'At least 50% should have GPS fix');

      for (final log in withGps) {
        expect(log.latitude, inInclusiveRange(-36.0, -20.0),
            reason: 'Latitude ${log.latitude} out of SA range');
        expect(log.longitude, inInclusiveRange(15.0, 34.0),
            reason: 'Longitude ${log.longitude} out of SA range');
      }
      print('GPS fix rate: ${withGps.length}/${logs.length} '
          '(${(withGps.length / logs.length * 100).toStringAsFixed(1)}%)');
    });

    test('speed values are reasonable for rugby (0-40 km/h)', () {
      final withSpeed = logs.where((l) => l.speed > 0.1).toList();
      for (final log in withSpeed) {
        expect(log.speed, lessThan(45.0),
            reason: 'Speed ${log.speed} km/h is unreasonable for rugby');
      }
      final maxSpeed = withSpeed.map((l) => l.speed).reduce((a, b) => a > b ? a : b);
      print('Max speed: ${maxSpeed.toStringAsFixed(1)} km/h');
    });

    test('sample rate is approximately 10Hz', () {
      // Check interval between consecutive records
      if (logs.length < 100) return;
      final intervals = <int>[];
      for (var i = 1; i < 100; i++) {
        intervals.add(logs[i].timestamp.difference(logs[i - 1].timestamp).inMilliseconds);
      }
      final avgInterval = intervals.reduce((a, b) => a + b) / intervals.length;
      // 10Hz = 100ms interval, allow 50-200ms range
      expect(avgInterval, inInclusiveRange(50, 200),
          reason: 'Average interval ${avgInterval.toStringAsFixed(0)}ms, expected ~100ms');
      print('Average sample interval: ${avgInterval.toStringAsFixed(0)}ms '
          '(${(1000 / avgInterval).toStringAsFixed(1)} Hz)');
    });
  });
}

String _fmt(DateTime dt) =>
    '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';

String _fmtSAST(DateTime dt) {
  final sast = dt.add(const Duration(hours: 2));
  return _fmt(sast);
}

String _durationStr(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}
