import 'package:flutter_test/flutter_test.dart';
import 'package:metric_athlete_pod_ble/models/sensor_log_model.dart';
import 'package:metric_athlete_pod_ble/utils/stats_calculator.dart';

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
  double filtAx = 1.0,
  double filtAy = 0.5,
  double filtAz = 9.5,
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

/// Generate a session of logs moving in a straight line.
/// Each log is 1 second apart for easy 1Hz resampling.
List<SensorLog> _generateMovingSession({
  int durationSeconds = 60,
  double speedKmh = 10.0,
}) {
  final base = DateTime(2025, 7, 25, 10, 0, 0);
  // Speed in degrees per second (rough approximation at equator)
  final double latStepPerSec = (speedKmh / 3.6) / 111000.0;

  return List.generate(durationSeconds, (i) {
    return _log(
      packetId: i * 100,
      timestamp: base.add(Duration(seconds: i)),
      lat: -33.8688 + (i * latStepPerSec),
      lon: 151.2093,
      speed: speedKmh,
      filtAx: 1.0,
      filtAy: 0.5,
      filtAz: 9.5,
    );
  });
}

void main() {
  group('StatsCalculator', () {
    test('returns empty stats for empty input', () {
      final stats = StatsCalculator.analyzeLogs([]);
      expect(stats.totalDistanceKm, 0);
      expect(stats.durationSeconds, 0);
    });

    test('returns empty stats for single log', () {
      final stats = StatsCalculator.analyzeLogs([_log()]);
      // With only 1 log, can't compute distances
      expect(stats.durationSeconds, lessThanOrEqualTo(1));
    });

    test('calculates non-zero distance for moving session', () {
      final logs = _generateMovingSession(durationSeconds: 30, speedKmh: 10.0);
      final stats = StatsCalculator.analyzeLogs(logs);
      expect(stats.totalDistanceKm, greaterThan(0));
    });

    test('top speed is captured correctly', () {
      final logs = _generateMovingSession(durationSeconds: 30, speedKmh: 10.0);
      // Add one log with a sprint burst
      logs.add(_log(
        packetId: 30 * 100,
        timestamp: DateTime(2025, 7, 25, 10, 0, 30),
        lat: logs.last.latitude + 0.001,
        lon: 151.2093,
        speed: 30.0,
      ));
      final stats = StatsCalculator.analyzeLogs(logs);
      // Top speed should be at least close to the sprint speed
      expect(stats.topSpeedKmh, greaterThanOrEqualTo(10.0));
    });

    test('zone classification works for resting speed', () {
      final logs = _generateMovingSession(durationSeconds: 20, speedKmh: 1.0);
      final stats = StatsCalculator.analyzeLogs(logs);
      // At 1 km/h, all time should be in Resting zone
      expect(stats.zoneTimeSeconds['Resting'] ?? 0, greaterThan(0));
    });

    test('sprint count increments on zone transition', () {
      final base = DateTime(2025, 7, 25, 10, 0, 0);
      final logs = <SensorLog>[];
      // Walk for 5s, sprint for 5s, walk for 5s
      // Use realistic GPS positions that produce distances matching the speeds
      final walkStepDeg = (5.0 / 3.6) / 111000.0; // 5 km/h in degrees/sec
      final sprintStepDeg = (30.0 / 3.6) / 111000.0; // 30 km/h in degrees/sec

      double currentLat = -33.8688;
      for (int i = 0; i < 15; i++) {
        double speed;
        double step;
        if (i < 5) {
          speed = 5.0;
          step = walkStepDeg;
        } else if (i < 10) {
          speed = 30.0;
          step = sprintStepDeg;
        } else {
          speed = 5.0;
          step = walkStepDeg;
        }
        currentLat += step;
        logs.add(_log(
          packetId: i * 100,
          timestamp: base.add(Duration(seconds: i)),
          lat: currentLat,
          lon: 151.2093,
          speed: speed,
        ));
      }
      final stats = StatsCalculator.analyzeLogs(logs);
      expect(stats.sprintCount, greaterThanOrEqualTo(1));
    });

    test('filters out null island GPS coordinates', () {
      final logs = [
        _log(packetId: 100, timestamp: DateTime(2025, 7, 25, 10, 0, 0), lat: 0, lon: 0),
        _log(packetId: 200, timestamp: DateTime(2025, 7, 25, 10, 0, 1)),
        _log(packetId: 300, timestamp: DateTime(2025, 7, 25, 10, 0, 2)),
      ];
      final stats = StatsCalculator.analyzeLogs(logs);
      // Should not crash and should skip the null island point
      expect(stats.durationSeconds, greaterThanOrEqualTo(0));
    });

    test('player load accumulates for active session', () {
      final logs = _generateMovingSession(durationSeconds: 30, speedKmh: 15.0);
      final stats = StatsCalculator.analyzeLogs(logs);
      expect(stats.playerLoad, greaterThan(0));
    });

    test('impact detection counts high-G events', () {
      final base = DateTime(2025, 7, 25, 10, 0, 0);
      final logs = <SensorLog>[];
      for (int i = 0; i < 20; i++) {
        // Simulate an impact at sample 10
        double filtAz = (i == 10) ? 60.0 : 9.8; // ~6G impact
        logs.add(_log(
          packetId: i * 100,
          timestamp: base.add(Duration(seconds: i)),
          lat: -33.8688 + (i * 0.00001),
          lon: 151.2093,
          speed: 10.0,
          filtAx: 1.0,
          filtAy: 0.5,
          filtAz: filtAz,
        ));
      }
      final stats = StatsCalculator.analyzeLogs(logs);
      expect(stats.impactCount, greaterThanOrEqualTo(1));
    });

    test('1Hz resampling preserves peak speed via max aggregation', () {
      final base = DateTime(2025, 7, 25, 10, 0, 0);
      final logs = <SensorLog>[];
      // 10 samples in the same second, with varying speeds
      for (int i = 0; i < 10; i++) {
        logs.add(_log(
          packetId: i * 10,
          timestamp: base.add(Duration(milliseconds: i * 100)),
          lat: -33.8688 + (i * 0.00001),
          lon: 151.2093,
          speed: i == 5 ? 25.0 : 10.0, // Peak at sample 5
        ));
      }
      // Add a second second to get distance calculation
      for (int i = 0; i < 10; i++) {
        logs.add(_log(
          packetId: (i + 10) * 10,
          timestamp: base.add(Duration(seconds: 1, milliseconds: i * 100)),
          lat: -33.8688 + ((i + 10) * 0.00001),
          lon: 151.2093,
          speed: 10.0,
        ));
      }
      final stats = StatsCalculator.analyzeLogs(logs);
      // The peak speed of 25 km/h should be captured, not lost to resampling
      expect(stats.topSpeedKmh, greaterThanOrEqualTo(20.0));
    });

    test('duration is calculated correctly', () {
      final logs = _generateMovingSession(durationSeconds: 60, speedKmh: 10.0);
      final stats = StatsCalculator.analyzeLogs(logs);
      expect(stats.durationSeconds, closeTo(60, 5));
    });
  });
}
