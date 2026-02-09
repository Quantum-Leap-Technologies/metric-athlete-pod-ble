import 'dart:math';
import 'package:metric_athlete_pod_ble/models/sensor_log_model.dart';
import 'package:metric_athlete_pod_ble/utils/trajectory_filter.dart';
import 'package:metric_athlete_pod_ble/utils/butterworth_filter.dart';

/// Configuration for the unified filter pipeline.
///
/// Allows toggling individual stages and tuning parameters.
class FilterConfig {
  /// Enable Stage -1: sanity check (remove corrupt data).
  final bool enableSanityCheck;

  /// Enable Stage 0: gap repair via linear interpolation.
  final bool enableGapRepair;

  /// Enable Butterworth low-pass on IMU channels.
  final bool enableButterworth;

  /// Enable Kalman + RTS smoothing on GPS.
  final bool enableKalmanRts;

  /// Enable speed-based outlier rejection (from Python pipeline).
  final bool enableOutlierRejection;

  /// Butterworth cutoff frequency in Hz.
  final double butterworthCutoffHz;

  /// Butterworth sampling frequency in Hz.
  final double butterworthSamplingHz;

  /// Maximum allowed GPS jump in meters per 100ms interval.
  /// If exceeded, speed-inferred distance is used instead.
  final double maxGpsJumpMeters;

  const FilterConfig({
    this.enableSanityCheck = true,
    this.enableGapRepair = true,
    this.enableButterworth = true,
    this.enableKalmanRts = true,
    this.enableOutlierRejection = true,
    this.butterworthCutoffHz = 5.0,
    this.butterworthSamplingHz = 10.0,
    this.maxGpsJumpMeters = 1.0,
  });
}

/// Result from the unified filter pipeline.
class FilterPipelineResult {
  final List<SensorLog> logs;
  final double healthScore;
  final int originalCount;
  final int repairedCount;
  final int outliersCorrected;

  FilterPipelineResult({
    required this.logs,
    required this.healthScore,
    required this.originalCount,
    required this.repairedCount,
    required this.outliersCorrected,
  });
}

/// Unified filter pipeline orchestrating all processing stages.
///
/// Pipeline order:
/// 1. Sanity check (existing TrajectoryFilter Stage -1)
/// 2. Gap repair / linear interpolation (existing Stage 0)
/// 3. Butterworth low-pass on IMU channels (new)
/// 4. Kalman + RTS smoother on GPS (existing Stage 1-2)
/// 5. Speed-based outlier rejection (new, from Python)
///
/// Designed to run via `compute()` isolate.
class FilterPipeline {
  /// Process raw sensor logs through the full pipeline.
  ///
  /// This is a top-level static method suitable for `compute()`.
  static FilterPipelineResult process(List<SensorLog> logs) {
    return processWithConfig(logs, const FilterConfig());
  }

  /// Process with explicit configuration.
  static FilterPipelineResult processWithConfig(
      List<SensorLog> logs, FilterConfig config) {
    if (logs.isEmpty) {
      return FilterPipelineResult(
        logs: [],
        healthScore: 0,
        originalCount: 0,
        repairedCount: 0,
        outliersCorrected: 0,
      );
    }

    // Run the existing TrajectoryFilter (Stages -1, 0, 1-2)
    // It handles sanity check, gap repair, and Kalman+RTS internally
    final TrajectoryResult trajectoryResult = TrajectoryFilter.process(logs);

    List<SensorLog> processedLogs = trajectoryResult.logs;
    int outliersCorrected = 0;

    if (processedLogs.isEmpty) {
      return FilterPipelineResult(
        logs: [],
        healthScore: 0,
        originalCount: trajectoryResult.originalCount,
        repairedCount: trajectoryResult.repairedCount,
        outliersCorrected: 0,
      );
    }

    // Stage 3: Butterworth low-pass on IMU channels
    if (config.enableButterworth && processedLogs.length >= 6) {
      processedLogs = _applyButterworth(processedLogs, config);
    }

    // Stage 5: Speed-based outlier rejection
    if (config.enableOutlierRejection && processedLogs.length >= 2) {
      final result = _applyOutlierRejection(processedLogs, config);
      processedLogs = result.$1;
      outliersCorrected = result.$2;
    }

    return FilterPipelineResult(
      logs: processedLogs,
      healthScore: trajectoryResult.healthScore,
      originalCount: trajectoryResult.originalCount,
      repairedCount: trajectoryResult.repairedCount,
      outliersCorrected: outliersCorrected,
    );
  }

  /// Apply Butterworth low-pass filter to accelerometer and gyroscope channels.
  static List<SensorLog> _applyButterworth(
      List<SensorLog> logs, FilterConfig config) {
    final filter = ButterworthFilter(
      cutoffHz: config.butterworthCutoffHz,
      samplingHz: config.butterworthSamplingHz,
    );

    // Extract channels
    final accelX = logs.map((l) => l.accelX).toList();
    final accelY = logs.map((l) => l.accelY).toList();
    final accelZ = logs.map((l) => l.accelZ).toList();
    final gyroX = logs.map((l) => l.gyroX).toList();
    final gyroY = logs.map((l) => l.gyroY).toList();
    final gyroZ = logs.map((l) => l.gyroZ).toList();

    // Filter each channel
    final fAccelX = filter.filtfilt(accelX);
    final fAccelY = filter.filtfilt(accelY);
    final fAccelZ = filter.filtfilt(accelZ);
    final fGyroX = filter.filtfilt(gyroX);
    final fGyroY = filter.filtfilt(gyroY);
    final fGyroZ = filter.filtfilt(gyroZ);

    // Rebuild logs with filtered IMU data
    return List.generate(logs.length, (i) {
      return logs[i].copyWith(
        accelX: fAccelX[i],
        accelY: fAccelY[i],
        accelZ: fAccelZ[i],
        gyroX: fGyroX[i],
        gyroY: fGyroY[i],
        gyroZ: fGyroZ[i],
      );
    });
  }

  /// Speed-based outlier rejection from the Python pipeline.
  ///
  /// If the Haversine distance between consecutive points exceeds
  /// [maxGpsJumpMeters] in a single 100ms interval, replace the GPS position
  /// with the speed-inferred position.
  static (List<SensorLog>, int) _applyOutlierRejection(
      List<SensorLog> logs, FilterConfig config) {
    final List<SensorLog> corrected = [logs[0]];
    int corrections = 0;

    for (int i = 1; i < logs.length; i++) {
      final prev = corrected.last;
      final curr = logs[i];

      double distance = _haversine(
        prev.latitude, prev.longitude,
        curr.latitude, curr.longitude,
      );

      double timeDiffSec =
          curr.timestamp.difference(prev.timestamp).inMilliseconds / 1000.0;

      if (timeDiffSec > 0 &&
          timeDiffSec <= 0.15 &&
          distance > config.maxGpsJumpMeters) {
        // Use speed-inferred distance instead of GPS jump
        double avgSpeedMs =
            ((prev.speed + curr.speed) / 2.0) / 3.6; // km/h → m/s
        double expectedDist = avgSpeedMs * timeDiffSec;

        if (expectedDist < distance) {
          // Interpolate position based on expected distance
          double ratio =
              distance > 0 ? expectedDist / distance : 0;
          double newLat = prev.latitude +
              (curr.latitude - prev.latitude) * ratio;
          double newLon = prev.longitude +
              (curr.longitude - prev.longitude) * ratio;

          corrected.add(curr.copyWith(
            latitude: newLat,
            longitude: newLon,
          ));
          corrections++;
          continue;
        }
      }

      corrected.add(curr);
    }

    return (corrected, corrections);
  }

  static double _haversine(
      double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000.0;
    var dLat = (lat2 - lat1) * pi / 180;
    var dLon = (lon2 - lon1) * pi / 180;
    var a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) *
            cos(lat2 * pi / 180) *
            sin(dLon / 2) *
            sin(dLon / 2);
    var c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }
}
