import 'package:flutter_test/flutter_test.dart';
import 'package:metric_athlete_pod_ble/models/sensor_log_model.dart';
import 'package:metric_athlete_pod_ble/utils/session_cluster.dart';

SensorLog _log({
  int packetId = 100,
  required DateTime timestamp,
  double lat = -33.8688,
  double lon = 151.2093,
}) {
  return SensorLog(
    packetId: packetId,
    timestamp: timestamp,
    latitude: lat,
    longitude: lon,
    speed: 10.0,
    accelX: 0.5,
    accelY: -0.3,
    accelZ: 9.8,
    gyroX: 0.01,
    gyroY: -0.02,
    gyroZ: 0.03,
    filteredAccelX: 0.4,
    filteredAccelY: -0.2,
    filteredAccelZ: 9.7,
  );
}

void main() {
  group('SessionClusterer', () {
    final base = DateTime(2025, 7, 25, 10, 0, 0);

    test('returns empty for empty input', () {
      expect(SessionClusterer.cluster([]), isEmpty);
    });

    test('returns empty for single log (too short)', () {
      final result = SessionClusterer.cluster([_log(timestamp: base)]);
      expect(result, isEmpty);
    });

    test('returns empty for session shorter than 5 minutes', () {
      // 4 minutes of data
      final logs = List.generate(
        240,
        (i) => _log(packetId: i, timestamp: base.add(Duration(seconds: i))),
      );
      final result = SessionClusterer.cluster(logs);
      expect(result, isEmpty);
    });

    test('returns one cluster for continuous 6-minute session', () {
      final logs = List.generate(
        360,
        (i) => _log(packetId: i, timestamp: base.add(Duration(seconds: i))),
      );
      final result = SessionClusterer.cluster(logs);
      expect(result.length, 1);
      expect(result.first.length, 360);
    });

    test('splits into two clusters on >10-minute gap', () {
      final logs = <SensorLog>[];

      // Session 1: 6 minutes
      for (int i = 0; i < 360; i++) {
        logs.add(_log(packetId: i, timestamp: base.add(Duration(seconds: i))));
      }

      // Gap of 15 minutes, then session 2: 6 minutes
      final session2Start = base.add(const Duration(minutes: 21));
      for (int i = 0; i < 360; i++) {
        logs.add(_log(
          packetId: 1000 + i,
          timestamp: session2Start.add(Duration(seconds: i)),
        ));
      }

      final result = SessionClusterer.cluster(logs);
      expect(result.length, 2);
      expect(result[0].length, 360);
      expect(result[1].length, 360);
    });

    test('discards short session between two valid sessions', () {
      final logs = <SensorLog>[];

      // Session 1: 6 minutes (valid)
      for (int i = 0; i < 360; i++) {
        logs.add(_log(packetId: i, timestamp: base.add(Duration(seconds: i))));
      }

      // Gap, then short session: 2 minutes (invalid)
      final shortStart = base.add(const Duration(minutes: 17));
      for (int i = 0; i < 120; i++) {
        logs.add(_log(
          packetId: 500 + i,
          timestamp: shortStart.add(Duration(seconds: i)),
        ));
      }

      // Gap, then session 3: 6 minutes (valid)
      final session3Start = base.add(const Duration(minutes: 30));
      for (int i = 0; i < 360; i++) {
        logs.add(_log(
          packetId: 1000 + i,
          timestamp: session3Start.add(Duration(seconds: i)),
        ));
      }

      final result = SessionClusterer.cluster(logs);
      // Only the two valid sessions (>= 5 min) should remain
      expect(result.length, 2);
    });

    test('exactly 5-minute session is valid', () {
      // 300 seconds = 5 minutes exactly
      final logs = List.generate(
        301, // Need 301 to span from second 0 to second 300
        (i) => _log(packetId: i, timestamp: base.add(Duration(seconds: i))),
      );
      final result = SessionClusterer.cluster(logs);
      expect(result.length, 1);
    });

    test('sorts out-of-order logs before clustering', () {
      // Create logs in reverse order
      final logs = List.generate(
        360,
        (i) => _log(
          packetId: 360 - i,
          timestamp: base.add(Duration(seconds: 360 - i)),
        ),
      );

      final result = SessionClusterer.cluster(logs);
      expect(result.length, 1);
      // Verify sorted order
      for (int i = 1; i < result.first.length; i++) {
        expect(
          result.first[i].timestamp.isAfter(result.first[i - 1].timestamp) ||
              result.first[i].timestamp == result.first[i - 1].timestamp,
          true,
        );
      }
    });

    test('gap exactly at 10 minutes does not split', () {
      final logs = <SensorLog>[];
      // Session: 6 minutes, then exactly 10-minute gap, then 6 more minutes
      for (int i = 0; i < 360; i++) {
        logs.add(_log(packetId: i, timestamp: base.add(Duration(seconds: i))));
      }
      // The gap check is > 10 minutes (not >=), so exactly 10 min should NOT split
      final resumeAt = base.add(const Duration(minutes: 16)); // 6min session + 10min gap
      for (int i = 0; i < 360; i++) {
        logs.add(_log(
          packetId: 500 + i,
          timestamp: resumeAt.add(Duration(seconds: i)),
        ));
      }

      final result = SessionClusterer.cluster(logs);
      // Exactly 10 minutes uses > not >=, so should stay as one session
      expect(result.length, 1);
    });
  });
}
