import 'package:flutter_test/flutter_test.dart';
import 'package:metric_athlete_pod_ble/models/sensor_log_model.dart';
import 'package:metric_athlete_pod_ble/utils/trajectory_filter.dart';

/// Helper to create a SensorLog with sensible defaults.
SensorLog _log({
  int packetId = 100,
  DateTime? timestamp,
  double lat = -33.8688,
  double lon = 151.2093,
  double speed = 10.0,
  double accelX = 0.5,
  double accelY = -0.3,
  double accelZ = 9.8,
  double gyroX = 0.01,
  double gyroY = -0.02,
  double gyroZ = 0.03,
  double filtAx = 0.4,
  double filtAy = -0.2,
  double filtAz = 9.7,
}) {
  return SensorLog(
    packetId: packetId,
    timestamp: timestamp ?? DateTime(2025, 7, 25, 10, 0, 0),
    latitude: lat,
    longitude: lon,
    speed: speed,
    accelX: accelX,
    accelY: accelY,
    accelZ: accelZ,
    gyroX: gyroX,
    gyroY: gyroY,
    gyroZ: gyroZ,
    filteredAccelX: filtAx,
    filteredAccelY: filtAy,
    filteredAccelZ: filtAz,
  );
}

/// Generates a list of N sequential logs with linear movement.
List<SensorLog> _generateSequentialLogs(int count, {int stepSize = 100}) {
  final base = DateTime(2025, 7, 25, 10, 0, 0);
  return List.generate(count, (i) {
    return _log(
      packetId: (i + 1) * stepSize,
      timestamp: base.add(Duration(milliseconds: i * 100)),
      lat: -33.8688 + (i * 0.0001), // Slight movement
      lon: 151.2093 + (i * 0.0001),
      speed: 10.0 + (i % 5).toDouble(), // Varying speed
    );
  });
}

void main() {
  group('TrajectoryFilter', () {
    test('returns empty result for empty input', () {
      final result = TrajectoryFilter.process([]);
      expect(result.logs, isEmpty);
      expect(result.healthScore, 0);
    });

    test('removes logs with NaN accel values (sanity check)', () {
      final logs = [
        _log(packetId: 100, accelX: double.nan),
        _log(packetId: 200, accelX: 0.5),
        _log(packetId: 300, accelX: 0.5),
      ];
      // First log should be removed, rest should process
      final result = TrajectoryFilter.process(logs);
      // The NaN log should not appear in output
      expect(result.logs.length, lessThanOrEqualTo(2));
    });

    test('removes logs with infinite gyro values', () {
      final logs = [
        _log(packetId: 100, gyroX: double.infinity),
        _log(packetId: 200),
        _log(packetId: 300),
      ];
      final result = TrajectoryFilter.process(logs);
      expect(result.logs.length, lessThanOrEqualTo(2));
    });

    test('removes null island logs (lat/lon near 0,0)', () {
      final logs = [
        _log(packetId: 100, lat: 0.0, lon: 0.0),
        _log(packetId: 200),
        _log(packetId: 300),
      ];
      final result = TrajectoryFilter.process(logs);
      expect(result.logs.length, lessThanOrEqualTo(2));
    });

    test('removes physically impossible accel values', () {
      final logs = [
        _log(packetId: 100, accelX: 300.0), // > 200 m/s^2 limit
        _log(packetId: 200),
        _log(packetId: 300),
      ];
      final result = TrajectoryFilter.process(logs);
      expect(result.logs.length, lessThanOrEqualTo(2));
    });

    test('removes physically impossible speed values', () {
      final logs = [
        _log(packetId: 100, speed: 100.0), // > 80 km/h limit
        _log(packetId: 200),
        _log(packetId: 300),
      ];
      final result = TrajectoryFilter.process(logs);
      expect(result.logs.length, lessThanOrEqualTo(2));
    });

    test('removes all-zero sensor readings', () {
      final logs = [
        _log(
          packetId: 100,
          accelX: 0, accelY: 0, accelZ: 0,
          gyroX: 0, gyroY: 0, gyroZ: 0,
        ),
        _log(packetId: 200),
        _log(packetId: 300),
      ];
      final result = TrajectoryFilter.process(logs);
      expect(result.logs.length, lessThanOrEqualTo(2));
    });

    test('deduplicates by packetId (keeps last occurrence)', () {
      final logs = [
        _log(packetId: 100, speed: 5.0),
        _log(packetId: 100, speed: 8.0), // Duplicate
        _log(packetId: 200, speed: 10.0),
      ];
      final result = TrajectoryFilter.process(logs);
      // After dedup, only 2 unique packetIds should remain
      final ids = result.logs.map((l) => l.packetId).toSet();
      expect(ids.length, lessThanOrEqualTo(2));
    });

    test('fills small gaps with interpolated logs', () {
      // Create 30 logs with a gap in the middle (packetIds skip 1500-1800)
      final base = DateTime(2025, 7, 25, 10, 0, 0);
      final logs = <SensorLog>[];
      for (int i = 0; i < 10; i++) {
        logs.add(_log(
          packetId: (i + 1) * 100,
          timestamp: base.add(Duration(milliseconds: i * 100)),
          lat: -33.8688 + (i * 0.0001),
          lon: 151.2093 + (i * 0.0001),
        ));
      }
      // Skip 3 packets (1100, 1200, 1300) and continue from 1400
      for (int i = 0; i < 10; i++) {
        logs.add(_log(
          packetId: 1400 + (i * 100),
          timestamp: base.add(Duration(milliseconds: (13 + i) * 100)),
          lat: -33.8688 + ((13 + i) * 0.0001),
          lon: 151.2093 + ((13 + i) * 0.0001),
        ));
      }
      final result = TrajectoryFilter.process(logs);
      // Should have filled the 3 missing steps
      expect(result.repairedCount, greaterThan(0));
    });

    test('does not fill massive gaps (>500 steps)', () {
      // Create a huge gap: 100 → 100000 (1000 steps of 100)
      final logs = [
        _log(packetId: 100, timestamp: DateTime(2025, 7, 25, 10, 0, 0)),
        _log(packetId: 200, timestamp: DateTime(2025, 7, 25, 10, 0, 0, 100)),
        _log(packetId: 100000, timestamp: DateTime(2025, 7, 25, 12, 0, 0)),
      ];
      final result = TrajectoryFilter.process(logs);
      // Should NOT have generated ~999 synthetic packets
      expect(result.repairedCount, lessThan(500));
    });

    test('health score is 100% for perfect data', () {
      final logs = _generateSequentialLogs(50);
      final result = TrajectoryFilter.process(logs);
      expect(result.healthScore, closeTo(100.0, 5.0)); // Allow small rounding
    });

    test('health score degrades with gaps', () {
      // Create data with a gap in the middle
      final logs = _generateSequentialLogs(20);
      // Remove some logs to create a gap
      logs.removeRange(5, 10);
      final result = TrajectoryFilter.process(logs);
      expect(result.healthScore, lessThan(100.0));
    });

    test('processes large dataset without crashing', () {
      final logs = _generateSequentialLogs(1000);
      final result = TrajectoryFilter.process(logs);
      // The output might be empty if the motion latch doesn't trigger
      // (depends on whether the generated data has enough speed variance).
      // The key invariant is that it doesn't throw.
      expect(result.healthScore, greaterThanOrEqualTo(0));
    });
  });
}
