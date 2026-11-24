import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:metric_athlete_pod_ble/models/sensor_log_model.dart';
import 'package:metric_athlete_pod_ble/utils/trajectory_filter.dart';

const double _metersPerDegreeLat = 111195.0;
const double _startLat = -26.0;
const double _startLon = 28.0;
final DateTime _start = DateTime(2026, 11, 13, 10);

double _lonOffsetDegrees(double metersEast) =>
    metersEast / (_metersPerDegreeLat * cos(_startLat * pi / 180));

/// One 10 Hz record. [eastM]/[northM] are metres from the start point.
/// The accelerometer swings so the filter sees real motion when [moving].
SensorLog _record(
  int index, {
  required double eastM,
  required double northM,
  required double speedKmh,
  bool moving = true,
  DateTime? timestamp,
  double? latitude,
  double? longitude,
}) {
  final swing = moving ? 4.0 * sin(index * 0.7) : 0.0;
  return SensorLog(
    packetId: 1000000 + index * 100,
    timestamp: timestamp ?? _start.add(Duration(milliseconds: index * 100)),
    latitude: latitude ?? _startLat + northM / _metersPerDegreeLat,
    longitude: longitude ?? _startLon + _lonOffsetDegrees(eastM),
    speed: speedKmh,
    accelX: 0.1,
    accelY: 0.1,
    accelZ: 9.81 + swing,
    gyroX: 0.01,
    gyroY: 0.01,
    gyroZ: 0.01,
    filteredAccelX: 0.0,
    filteredAccelY: 0.0,
    filteredAccelZ: 9.81 + swing,
  );
}

double _haversineMeters(SensorLog a, SensorLog b) {
  final dLat = (b.latitude - a.latitude) * pi / 180;
  final dLon = (b.longitude - a.longitude) * pi / 180;
  final h =
      pow(sin(dLat / 2), 2) +
      cos(a.latitude * pi / 180) *
          cos(b.latitude * pi / 180) *
          pow(sin(dLon / 2), 2);
  return 2 * 6371000.0 * asin(sqrt(h));
}

double _trackMeters(List<SensorLog> logs) {
  var total = 0.0;
  for (var i = 1; i < logs.length; i++) {
    total += _haversineMeters(logs[i - 1], logs[i]);
  }
  return total;
}

double _speedTimeMeters(List<SensorLog> logs) {
  var total = 0.0;
  for (var i = 1; i < logs.length; i++) {
    final seconds =
        logs[i].timestamp.difference(logs[i - 1].timestamp).inMilliseconds /
        1000.0;
    total += logs[i].speed / 3.6 * seconds;
  }
  return total;
}

double _maxAcceleration(List<SensorLog> logs) {
  var maxAccel = 0.0;
  for (var i = 1; i < logs.length; i++) {
    final seconds =
        logs[i].timestamp.difference(logs[i - 1].timestamp).inMilliseconds /
        1000.0;
    final accel = (logs[i].speed - logs[i - 1].speed).abs() / 3.6 / seconds;
    maxAccel = max(maxAccel, accel);
  }
  return maxAccel;
}

/// Athlete walking east at [speedMs] for [seconds], one record per 0.1 s.
/// [positionEveryRecords] > 1 holds the reported GPS position between updates.
List<SensorLog> _walk({
  required double seconds,
  double speedMs = 2.0,
  int positionEveryRecords = 1,
  bool oneSecondTimestamps = false,
}) {
  final count = (seconds * 10).round();
  return List.generate(count, (i) {
    final fixIndex = i - i % positionEveryRecords;
    return _record(
      i,
      eastM: speedMs * fixIndex / 10.0,
      northM: 0,
      speedKmh: speedMs * 3.6,
      timestamp:
          oneSecondTimestamps
              ? _start.add(Duration(seconds: i ~/ 10))
              : null,
    );
  });
}

/// The distance the raw positions describe when joined in order.
double _rawTrackMeters(List<SensorLog> raw) => _trackMeters(raw);

void main() {
  group('TrajectoryFilter distance', () {
    test('held GPS reading keeps the distance and the speed', () {
      // One new position every 5 s (50 records) at 2 m/s.
      final raw = _walk(seconds: 120, positionEveryRecords: 50);
      final result = TrajectoryFilter.process(raw).logs;

      expect(result.length, raw.length);
      expect(
        _trackMeters(result),
        greaterThanOrEqualTo(0.9 * _rawTrackMeters(raw)),
      );
      expect(
        _speedTimeMeters(result),
        greaterThanOrEqualTo(0.9 * _speedTimeMeters(raw)),
      );
      expect(_maxAcceleration(result), lessThan(6.0));
    });

    test('1-second timestamps do not change the distance', () {
      final raw = _walk(seconds: 60, oneSecondTimestamps: true);
      final result = TrajectoryFilter.process(raw).logs;

      const truth = 2.0 * 59.9;
      expect(_trackMeters(result), closeTo(truth, truth * 0.03));
    });

    test('slow movement before sustained motion is kept', () {
      // 0.5 m/s is below the 3 km/h motion threshold for the whole recording.
      final raw = _walk(seconds: 120, speedMs: 0.5);
      final result = TrajectoryFilter.process(raw).logs;

      expect(result.length, raw.length);
      expect(
        _trackMeters(result),
        greaterThanOrEqualTo(0.9 * _rawTrackMeters(raw)),
      );
    });
  });

  group('TrajectoryFilter glitch protection', () {
    double cleanTrack(List<SensorLog> raw) =>
        _trackMeters(TrajectoryFilter.process(raw).logs);

    List<SensorLog> walkWithFixes(
      List<SensorLog> base,
      int from,
      int to,
      SensorLog Function(SensorLog) glitch,
    ) => [
      for (var i = 0; i < base.length; i++)
        i >= from && i < to ? glitch(base[i]) : base[i],
    ];

    test('a position that jumps away and back adds nothing', () {
      final base = _walk(seconds: 60);
      final clean = cleanTrack(base);
      for (final jumpMeters in [200.0, 26000.0]) {
        final glitched = walkWithFixes(
          base,
          300,
          315,
          (log) => log.copyWith(
            latitude: log.latitude + jumpMeters / _metersPerDegreeLat,
          ),
        );
        expect(
          _trackMeters(TrajectoryFilter.process(glitched).logs),
          closeTo(clean, clean * 0.02),
          reason: 'jump of $jumpMeters m',
        );
      }
    });

    test('a bad first fix is dropped without a bridging jump', () {
      final base = _walk(seconds: 120);
      for (final badRecords in [10, 20]) {
        final glitched = walkWithFixes(
          base,
          0,
          badRecords,
          (log) => log.copyWith(
            latitude: log.latitude + 500.0 / _metersPerDegreeLat,
          ),
        );
        final truth = 2.0 * (base.length - badRecords) / 10.0;
        expect(
          _trackMeters(TrajectoryFilter.process(glitched).logs),
          closeTo(truth, truth * 0.03),
          reason: '$badRecords bad records at the start',
        );
      }
    });

    test('a burst of wrong fixes in a steady run adds only the true track', () {
      final base = _walk(seconds: 180);
      final clean = cleanTrack(base);
      // 20 s, 266 m off, then the pod is back on the track.
      final glitched = walkWithFixes(
        base,
        600,
        800,
        (log) => log.copyWith(
          latitude: log.latitude + 266.0 / _metersPerDegreeLat,
        ),
      );
      expect(
        _trackMeters(TrajectoryFilter.process(glitched).logs),
        closeTo(clean, 5.0),
      );
    });

    test('a (0,0) or out-of-range coordinate adds no jump', () {
      final base = _walk(seconds: 60);
      final clean = cleanTrack(base);
      final badFixes = <SensorLog Function(SensorLog)>[
        (log) => log.copyWith(latitude: 0.0, longitude: 0.0),
        (log) => log.copyWith(latitude: 95.0, longitude: 200.0),
        (log) => log.copyWith(latitude: double.nan),
      ];
      for (final bad in badFixes) {
        final glitched = walkWithFixes(base, 300, 303, bad);
        final result = TrajectoryFilter.process(glitched).logs;
        expect(_trackMeters(result), closeTo(clean, clean * 0.02));
      }
    });

    test('three minutes standing still gives about 0 m and 0 speed', () {
      final random = Random(7);
      var driftEast = 0.0;
      var driftNorth = 0.0;
      final raw = List.generate(1800, (i) {
        driftEast = 0.995 * driftEast + random.nextDouble() * 0.2 - 0.1;
        driftNorth = 0.995 * driftNorth + random.nextDouble() * 0.2 - 0.1;
        return _record(
          i,
          eastM: driftEast + random.nextDouble() - 0.5,
          northM: driftNorth + random.nextDouble() - 0.5,
          speedKmh: 0.0,
          moving: false,
        );
      });

      final result = TrajectoryFilter.process(raw).logs;

      expect(result.length, raw.length);
      expect(_trackMeters(result), lessThan(15.0));
      expect(result.every((log) => log.speed == 0.0), isTrue);
    });

    test('a pod handled while standing still does not drift', () {
      final random = Random(11);
      final raw = List.generate(1800, (i) {
        final base = _record(
          i,
          eastM: random.nextDouble() - 0.5,
          northM: random.nextDouble() - 0.5,
          speedKmh: 0.0,
          moving: false,
        );
        return base.copyWith(
          filteredAccelX: (random.nextDouble() - 0.5) * 60,
          filteredAccelY: (random.nextDouble() - 0.5) * 60,
        );
      });

      final result = TrajectoryFilter.process(raw).logs;

      expect(_trackMeters(result), lessThan(15.0));
    });
  });
}
